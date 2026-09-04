import Foundation

// MARK: - Bashism 检测器（自研，不依赖第三方源码）
//
// 目的：智能体生成的 shell 命令常含 bash 特有语法（数组/[[ ]]/进程替换等），
// 而执行器是 busybox ash（iSH Alpine）。检测命中后由调用方决定：
//   - bash 可用（已按需安装）→ 用 bash -lc 包装执行；
//   - 否则 → 原样执行并在结果附 system-reminder 提醒模型改写。
//
// 设计约束（防误报与 DoS）：
//   - 按行扫描，忽略 # 注释、单引号字符串、heredoc 段；
//   - 单行长度 > 4000 字符直接跳过该行；
//   - 全程 50ms 熔断：超时即视为「未命中」（fail-open，宁可漏检不可拖慢执行）。

/// 检测结果：命中的规则名（可多个）与首个命中行的摘录。
struct BashismHit: Equatable {
    let rule: String
    let sampleLine: String
}

enum BashismDetector {
    /// 规则表：正则 → 规则名。匹配即命中。
    /// 覆盖 busybox ash 不支持、bash 支持的高频语法（自研归纳，2026-08）。
    /// 预编译为 static let（逐行重新编译会超 50ms 熔断，大命令上静默失效）。
    private static let rules: [(regex: NSRegularExpression, name: String)] = [
        // 双中括号条件（ash 不支持）
        (Self.compile(#"\[\[[^]]*\]\]"#), String(localized: "bashism_double_bracket")),
        // 数组赋值 arr=(a b c)（排除命令替换 $(...) 与子 shell 的误匹配：要求标识符后紧跟 =(）
        (Self.compile(#"\b[A-Za-z_][A-Za-z0-9_]*=\(\s*[^)]"#), String(localized: "bashism_array_assign")),
        // 数组下标 ${arr[0]}
        (Self.compile(#"\$\{[A-Za-z_][A-Za-z0-9_]*\[[0-9]+\]"#), String(localized: "bashism_array_index")),
        // source 命令（POSIX 应写 . file）
        (Self.compile(#"^\s*source\s+\S"#), String(localized: "bashism_source")),
        // function 关键字定义
        (Self.compile(#"^\s*function\s+[A-Za-z_][A-Za-z0-9_]*\s*\("#), String(localized: "bashism_function")),
        // here-string <<<
        (Self.compile(#"<<<"#), "here-string <<<"),
        // 进程替换 <( ... )
        (Self.compile(#"<\([^)]*\)"#), String(localized: "bashism_proc_sub")),
        // &> 与 &>> 重定向
        (Self.compile(#"&\s*>|&>>"#), String(localized: "bashism_redirect")),
        // 子串/大小写展开 ${var:offset} ${var^^} ${var,,} ${var~}
        (Self.compile(#"\$\{[A-Za-z_][A-Za-z0-9_]*:[0-9]+|\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,|~~)"#), String(localized: "bashism_var_expand")),
        // 间接展开 ${!var}
        (Self.compile(#"\$\{![A-Za-z_]"#), String(localized: "bashism_indirect")),
        // declare/typeset -a（显式数组声明）
        (Self.compile(#"^\s*(declare|typeset)\s+-a\b"#), String(localized: "bashism_declare")),
        // printf -v / mapfile / readarray / coproc / select
        (Self.compile(#"^\s*printf\s+-v\b"#), "printf -v"),
        (Self.compile(#"^\s*(mapfile|readarray)\b"#), "mapfile/readarray"),
        (Self.compile(#"^\s*coproc\b"#), "coproc"),
        (Self.compile(#"^\s*select\s+\S+\s+in\b"#), String(localized: "bashism_select")),
        // let 算术
        (Self.compile(#"^\s*let\s+\S"#), String(localized: "bashism_let")),
    ]

    private static func compile(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// 单行长度上限（防超长行拖慢正则）。
    private static let maxLineLength = 4000
    /// 总耗时熔断（秒）。fail-open：超时返回未命中。
    private static let timeBudget: TimeInterval = 0.05

    /// 检测命令是否含 bash 特有语法。
    /// - Returns: 命中列表（空 = 未命中）。fail-open：异常/超时也返回空。
    static func detect(_ command: String) -> [BashismHit] {
        let start = Date()
        var hits: [BashismHit] = []

        // 剥离 heredoc 段（<<EOF ... EOF）：避免把 heredoc 内容当命令检测。
        let withoutHeredocs = stripHeredocs(command)
        let lines = withoutHeredocs.split(separator: "\n", omittingEmptySubsequences: false)

        for rawLine in lines {
            // 熔断检查
            if Date().timeIntervalSince(start) > timeBudget { return [] }
            var line = String(rawLine)
            if line.count > maxLineLength { continue }

            // 忽略注释行（行首 #）
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }

            // 剥离单引号字符串（'...'），双引号内保留（语法仍可能出现在其中，且防误报收益小）
            line = stripSingleQuoted(line)

            for (regex, name) in rules {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    // 去重：同一规则只记一次
                    if !hits.contains(where: { $0.rule == name }) {
                        hits.append(BashismHit(rule: name, sampleLine: String(trimmed.prefix(120))))
                    }
                }
            }
        }
        return hits
    }

    /// 剥离单引号字符串段（'...'），并感知双引号（双引号内的 ' 不切换状态，
    /// 避免 "it's ok" 这类英文文本把整行剥空导致漏检）。
    private static func stripSingleQuoted(_ line: String) -> String {
        var result = ""
        var inSingle = false
        var inDouble = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\\", !inSingle {
                // 转义：跳过下一个字符（双引号内 \' 是字面量）
                let next = line.index(after: i)
                if next < line.endIndex {
                    result.append(ch)
                    result.append(line[next])
                    i = line.index(after: next)
                    continue
                }
            }
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle { result.append(ch) }
            i = line.index(after: i)
        }
        return result
    }

    /// 剥离 heredoc 段：<<EOF / <<'EOF' / <<-EOF / <<"EOF" ... 终止行。
    /// 位置感知扫描：字符串/注释内的 << 不视为 heredoc 开始（避免 echo '<<EOF' 误开），
    /// 同时正确识别带引号的标记（正则预剥离方案会漏检 <<'EOF'）。
    private static func stripHeredocs(_ command: String) -> String {
        var lines: [String] = []
        var inHeredoc = false
        var marker = ""
        for raw in command.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inHeredoc {
                if trimmed == marker { inHeredoc = false }
                continue
            }
            lines.append(line)
            if let m = heredocMarker(in: line) {
                marker = m
                inHeredoc = true
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 在行内定位 heredoc 开始标记（位置感知：跳过单/双引号字符串与转义）。
    /// - Returns: heredoc 标记名（如 EOF）；行内无双小于号或全在引号内时返回 nil。
    private static func heredocMarker(in line: String) -> String? {
        // 整行注释（# 开头）不可能有 heredoc 开始；否则 # comment <<EOF 会误开并吞掉后续行
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return nil }
        let chars = Array(line)
        var i = 0
        var inSingle = false
        var inDouble = false
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" && !inSingle {
                i += 2  // 转义：跳过下一字符
                continue
            }
            if ch == "'" && !inDouble { inSingle.toggle(); i += 1; continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); i += 1; continue }
            // 非引号上下文里的 <<
            if !inSingle && !inDouble && ch == "<" && i + 1 < chars.count && chars[i + 1] == "<" {
                var j = i + 2
                // 可选 -（<<- 允许 Tab 缩进终止行）
                if j < chars.count && chars[j] == "-" { j += 1 }
                // 可选引号 <<'EOF' / <<"EOF"
                var quote: Character?
                if j < chars.count && (chars[j] == "'" || chars[j] == "\"") {
                    quote = chars[j]
                    j += 1
                }
                // 标记名
                var name = ""
                while j < chars.count, chars[j].isLetter || (chars[j].isNumber && !name.isEmpty) || chars[j] == "_" {
                    name.append(chars[j])
                    j += 1
                }
                // 带引号形式要求闭合引号
                if let q = quote {
                    if j < chars.count, chars[j] == q, !name.isEmpty {
                        return name
                    }
                } else if !name.isEmpty {
                    return name
                }
            }
            i += 1
        }
        return nil
    }
}
