import Foundation

// MARK: - Markdown Parser

/// 聊天消息 Markdown 手写解析器（2026-08 自 MarkdownContentView 提取）：
/// 纯函数解析，不依赖实例状态 / 设置，可安全在后台线程执行。
enum MarkdownParser {
    /// 纯函数（不读实例状态/设置）：可安全在后台线程解析（2026-08-07 流式卡顿优化）。
    nonisolated static func parseMarkdown(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var id = 0
        var buffer = ""
        var inCodeBlock = false
        var codeLanguage = ""
        var codeContent = ""
        var codeFenceChar: Character = "`"   // 围栏字符（``` 或 ~~~），闭合须同字符（2026-08-08 补齐）

        // 引用式链接定义收集（2026-08-08 补齐）：`[ref]: url` 定义行不渲染，
        // 正文中 `[text][ref]` / `[ref][]` 在文本块产出时替换为显式链接。
        var linkRefs: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = t.firstMatch(of: /^\[([^\]]+)\]:\s*(\S+)/) {
                linkRefs[String(m.1).lowercased()] = String(m.2)
            }
        }

        var pendingBulletItems: [(text: String, indent: Int)] = []
        var pendingOrderedItems: [(text: String, indent: Int, start: Int)] = []
        var pendingTaskItems: [(isCompleted: Bool, content: String, indent: Int)] = []

        func flushPendingLists() {
            if !pendingBulletItems.isEmpty {
                id += 1
                blocks.append(.bulletList(items: pendingBulletItems.map(\.text), indent: pendingBulletItems[0].indent, id: id))
                pendingBulletItems = []
            }
            if !pendingOrderedItems.isEmpty {
                id += 1
                blocks.append(.orderedList(items: pendingOrderedItems.map(\.text), indent: pendingOrderedItems[0].indent, start: pendingOrderedItems[0].start, id: id))
                pendingOrderedItems = []
            }
            if !pendingTaskItems.isEmpty {
                id += 1
                blocks.append(.taskList(items: pendingTaskItems.map { (isCompleted: $0.isCompleted, content: $0.content) }, indent: pendingTaskItems[0].indent, id: id))
                pendingTaskItems = []
            }
        }

        func flushTextBuffer() {
            let content = buffer.trimmingCharacters(in: .newlines)
            if !content.isEmpty {
                id += 1
                blocks.append(.text(content: content, id: id))
            }
            buffer = ""
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // ── 代码块（``` 或 ~~~ 围栏；闭合须同字符）──
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushTextBuffer()
                flushPendingLists()
                if inCodeBlock {
                    if codeFenceChar == trimmed.first {
                        id += 1
                        blocks.append(
                            .codeBlock(
                                language: codeLanguage,
                                content: codeContent.trimmingCharacters(in: .newlines),
                                id: id
                            )
                        )
                        codeContent = ""
                        codeLanguage = ""
                        inCodeBlock = false
                    } else {
                        // 异字符围栏（如 ~~~ 里嵌 ```）：按内容行处理
                        codeContent += line + "\n"
                    }
                } else {
                    codeFenceChar = trimmed.first ?? "`"
                    codeLanguage = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
                index += 1
                continue
            }
            if inCodeBlock {
                codeContent += line + "\n"
                index += 1
                continue
            }

            // ── 空行 ──
            if trimmed.isEmpty {
                flushTextBuffer()
                flushPendingLists()
                index += 1
                continue
            }

            // ── 表格 ──
            if index + 1 < lines.count,
               isTableRow(trimmed),
               isTableSeparator(lines[index + 1]) {
                flushTextBuffer()
                flushPendingLists()

                let headers = parseTableCells(trimmed)
                let alignments = parseTableAlignments(lines[index + 1], columnCount: headers.count)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, isTableRow(candidate) else { break }
                    rows.append(normalizeTableRow(parseTableCells(candidate), columnCount: headers.count))
                    index += 1
                }

                id += 1
                blocks.append(.table(headers: headers, rows: rows, alignments: alignments, id: id))
                continue
            }


            // ── Setext 标题（2026-08-08 补齐）：下一行为 === 或 --- 时，本行变标题 ──
            // 2026-08-11 修复:检测前排除 ATX 标题(# 开头)与列表 marker 行,
            // 否则 `# 标题\n---` 被误当 H2 且 --- 消失、`- 项\n---` 列表项变 H2。
            if index + 1 < lines.count, !trimmed.hasPrefix("#"), !isListMarkerLine(trimmed) {
                let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if !nextTrimmed.isEmpty, nextTrimmed.allSatisfy({ $0 == "=" }) {
                    flushTextBuffer()
                    flushPendingLists()
                    id += 1
                    blocks.append(.heading(level: 1, content: trimmed, id: id))
                    index += 2
                    continue
                }
                if nextTrimmed.count >= 3, nextTrimmed.allSatisfy({ $0 == "-" }) {
                    // 与表格分隔行区分：表格检查已先行（表头行 + 分隔行）；此处仅当本行不是表头
                    flushTextBuffer()
                    flushPendingLists()
                    id += 1
                    blocks.append(.heading(level: 2, content: trimmed, id: id))
                    index += 2
                    continue
                }
            }

            // ── 标题 H1-H6 ──
            if let heading = parseHeading(trimmed) {
                flushTextBuffer()
                flushPendingLists()
                id += 1
                blocks.append(.heading(level: heading.level, content: heading.content, id: id))
                index += 1
                continue
            }

            // ── 分隔线 ──
            if isThematicBreak(trimmed) {
                flushTextBuffer()
                flushPendingLists()
                id += 1
                blocks.append(.thematicBreak(id: id))
                index += 1
                continue
            }

            // ── 任务列表，必须先于普通无序列表识别（支持嵌套缩进，2026-08-08 补齐）──
            if let task = parseTaskItem(trimmed) {
                flushTextBuffer()
                if !pendingBulletItems.isEmpty || !pendingOrderedItems.isEmpty {
                    flushPendingLists()
                }
                if !pendingTaskItems.isEmpty, pendingTaskItems[0].indent != task.indent {
                    flushPendingLists()
                }
                pendingTaskItems.append((task.isCompleted, task.content, task.indent))
                index += 1
                continue
            }

            // ── 无序列表（支持缩进嵌套）──
            if let item = parseBulletItem(trimmed) {
                flushTextBuffer()
                // 缩进必须用原始行计算（trimmed 已去掉前导空格，恒为 0）；
                // 空格数折算成层级（2~9 空格 = 1 级），层级变化才拆块、同层连续行不拆。
                let indent = Self.indentLevel(Self.leadingWhitespaceCount(line))
                if !pendingBulletItems.isEmpty, pendingBulletItems[0].indent != indent {
                    flushPendingLists()
                }
                if !pendingOrderedItems.isEmpty || !pendingTaskItems.isEmpty {
                    flushPendingLists()
                }
                pendingBulletItems.append((item, indent))
                index += 1
                continue
            }

            // ── 有序列表（支持缩进嵌套 + 保留起始数字，2026-08-08 补齐）──
            if let parsed = parseOrderedItem(trimmed) {
                flushTextBuffer()
                // 同上：空格数折算成层级，层级变化才拆块
                let indent = Self.indentLevel(Self.leadingWhitespaceCount(line))
                if !pendingOrderedItems.isEmpty, pendingOrderedItems[0].indent != indent {
                    flushPendingLists()
                }
                if !pendingBulletItems.isEmpty || !pendingTaskItems.isEmpty {
                    flushPendingLists()
                }
                pendingOrderedItems.append((parsed.content, indent, parsed.start))
                index += 1
                continue
            }

            // ── 连续引用合并为一个块（含 CommonMark 续行：无 > 前缀的后续行也并入，2026-08-08 补齐）──
            if parseBlockquote(trimmed) != nil {
                flushTextBuffer()
                flushPendingLists()
                var quoteLines: [String] = []
                var inQuote = true
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    if let quote = parseBlockquote(l) {
                        quoteLines.append(quote)
                        index += 1
                        continue
                    }
                    // 续行：非空、非块语法开头、非引用定义行 → 并入引用（CommonMark 引用续行语义）
                    if inQuote, !l.isEmpty,
                       !l.hasPrefix("#"), !l.hasPrefix("```"), !l.hasPrefix("~~~"),
                       l.firstMatch(of: /^[-*+]\s+/) == nil,
                       l.firstMatch(of: /^\d+\.\s+/) == nil,
                       l.firstMatch(of: /^\[.*\]:\s*\S+/) == nil,
                       l.firstMatch(of: /^[=]+$/) == nil, l.firstMatch(of: /^-{3,}$/) == nil {
                        quoteLines.append(l)
                        index += 1
                        continue
                    }
                    inQuote = false
                    break
                }
                id += 1
                blocks.append(.blockquote(content: quoteLines.joined(separator: "\n"), id: id))
                continue
            }

            // ── 图片 / 视频 / 音频 ![]() ——
            if let m = parseMediaLine(trimmed) {
                flushTextBuffer()
                flushPendingLists()
                id += 1
                switch m.type {
                case .image: blocks.append(.image(alt: m.alt, url: m.url, id: id))
                case .video: blocks.append(.video(alt: m.alt, url: m.url, id: id))
                case .audio: blocks.append(.audio(alt: m.alt, url: m.url, id: id))
                case .code, .pdf, .office, .html, .file:
                    blocks.append(.file(alt: m.alt, url: m.url, fileType: m.type, id: id))
                }
                index += 1
                continue
            }

            // ── 防御性：普通链接指向媒体文件时自动提升为内联渲染 ──
            // 智能体可能输出 [文件名](miniclaw://...png) 而非 ![](miniclaw://...png)。
            // 检测文本行中是否只含一个 markdown 链接且 URL 以媒体扩展名结尾，
            // 若是则提升为对应媒体块（图片/视频/音频/文档），避免灰框或「不支持的 URL」。
            if let m = parseMediaLinkInText(trimmed) {
                flushTextBuffer()
                flushPendingLists()
                id += 1
                switch m.type {
                case .image: blocks.append(.image(alt: m.alt, url: m.url, id: id))
                case .video: blocks.append(.video(alt: m.alt, url: m.url, id: id))
                case .audio: blocks.append(.audio(alt: m.alt, url: m.url, id: id))
                case .code, .pdf, .office, .html, .file:
                    blocks.append(.file(alt: m.alt, url: m.url, fileType: m.type, id: id))
                }
                index += 1
                continue
            }

            // ── 普通文本（含：引用定义行跳过 / 列表续行并入 / 缩进代码块）──
            // 引用定义行：不渲染（已在进入循环前收集）
            if trimmed.firstMatch(of: /^\[.*\]:\s*\S+/) != nil {
                index += 1
                continue
            }
            // 列表续行（2026-08-08 补齐）：列表进行中，无 marker 但缩进 ≥2 的普通行并入最后一项
            let ws = Self.leadingWhitespaceCount(line)
            if !pendingBulletItems.isEmpty || !pendingOrderedItems.isEmpty || !pendingTaskItems.isEmpty {
                if ws >= 2, trimmed.firstMatch(of: /^\[.*\]:\s*\S+/) == nil {
                    if !pendingBulletItems.isEmpty {
                        pendingBulletItems[pendingBulletItems.count - 1].text += "\n" + trimmed
                    } else if !pendingOrderedItems.isEmpty {
                        pendingOrderedItems[pendingOrderedItems.count - 1].text += "\n" + trimmed
                    } else if !pendingTaskItems.isEmpty {
                        pendingTaskItems[pendingTaskItems.count - 1].content += "\n" + trimmed
                    }
                    index += 1
                    continue
                }
            }
            // 缩进代码块（2026-08-08 补齐）：行首 ≥4 空格且不在任何列表/块上下文中 → 代码块
            if ws >= 4, pendingBulletItems.isEmpty, pendingOrderedItems.isEmpty, pendingTaskItems.isEmpty, buffer.isEmpty {
                flushPendingLists()
                var codeLines: [String] = []
                while index < lines.count {
                    let l = lines[index]
                    if Self.leadingWhitespaceCount(l) >= 4 {
                        codeLines.append(String(l.dropFirst(4)))
                        index += 1
                    } else if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        // 空行：若后续仍是缩进行则继续（CommonMark 缩进代码块允许内部空行）
                        var lookahead = index + 1
                        var found = false
                        while lookahead < lines.count {
                            let la = lines[lookahead]
                            if la.trimmingCharacters(in: .whitespaces).isEmpty { lookahead += 1; continue }
                            found = Self.leadingWhitespaceCount(la) >= 4
                            break
                        }
                        if found {
                            codeLines.append("")
                            index += 1
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                id += 1
                blocks.append(.codeBlock(language: "", content: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines), id: id))
                continue
            }
            flushPendingLists()
            // 引用式链接替换（2026-08-08 补齐）：[text][ref] → [text](url)；[ref][] → [text](url)
            let lineBuf = linkRefs.isEmpty ? line : Self.applyLinkRefs(line, refs: linkRefs)
            buffer += lineBuf + "\n"
            index += 1
        }

        flushTextBuffer()
        flushPendingLists()
        if inCodeBlock {
            id += 1
            blocks.append(
                .codeBlock(
                    language: codeLanguage,
                    content: codeContent.trimmingCharacters(in: .newlines),
                    id: id
                )
            )
        }

        return blocks
    }

    // MARK: - 行级解析辅助

    private nonisolated static func parseHeading(_ line: String) -> (level: Int, content: String)? {
        guard let match = line.firstMatch(of: /^(#{1,6})\s+(.+)/) else { return nil }
        let level = match.1.count
        // 2026-08-08 补齐：剥离尾随闭合 #（`# foo #` → `foo`）
        var content = String(match.2).trimmingCharacters(in: .whitespaces)
        if let closing = content.firstMatch(of: /(?:\s*#+\s*)$/) {
            content = String(content.dropLast(closing.0.count)).trimmingCharacters(in: .whitespaces)
        }
        return (level, content)
    }

    /// 2026-08-11 新增:行是否列表 marker(任务/无序/有序),供 Setext 标题检测
    /// 排除列表行(`- 项\n---` 不应被误判为 H2)。
    private nonisolated static func isListMarkerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if parseTaskItem(trimmed) != nil { return true }
        if parseBulletItem(trimmed) != nil { return true }
        if parseOrderedItem(trimmed) != nil { return true }
        return false
    }

    private nonisolated static func parseTaskItem(_ line: String) -> (isCompleted: Bool, content: String, indent: Int)? {
        guard let match = line.firstMatch(of: /^\s{0,7}[-*+]\s+\[([ xX])\]\s+(.+)/) else { return nil }
        let marker = String(match.1).lowercased()
        // 任务列表嵌套（2026-08-08 补齐）：行首空格折算层级，与普通列表同口径
        let ws = Self.leadingWhitespaceCount(line)
        return (marker == "x", String(match.2), Self.indentLevel(ws))
    }


    /// 引用式链接替换（2026-08-08 补齐）：`[text][ref]` → `[text](url)`、`[ref][]` → `[ref](url)`。
    /// 不处理单独 `[ref]`（避免误伤普通文本方括号）。ref 大小写不敏感（CommonMark）。
    private nonisolated static func applyLinkRefs(_ line: String, refs: [String: String]) -> String {
        var result = line
        // 先替换 `[ref][]` 短形式（CommonMark：文本与引用名相同），再替换 `[text][ref]`。
        // ref 需转义正则元字符（如 v1.2 的 `.`）；输出不带尖括号（防 normalizeBareURLs 二次处理）。
        for (ref, url) in refs {
            _ = ref
            // 2026-08-11 修复:原正则 `\[ref\]\[\]\]` 无捕获组,模板 `$1` 替换成空串
            // → [text][] 链接文字丢失显示为空白链接。加捕获组保留文本。
            result = result.replacingOccurrences(
                of: "\\[([^\\[\\]]+)\\]\\[\\]",
                with: "[$1](\(url))",
                options: .regularExpression
            )
        }
        for (ref, url) in refs {
            let escaped = NSRegularExpression.escapedPattern(for: ref)
            result = result.replacingOccurrences(
                of: "\\[([^\\[\\]]+)\\]\\[\(escaped)\\]",
                with: "[$1](\(url))",
                options: .regularExpression
            )
        }
        return result
    }

    /// 行首空白（空格）计数：列表嵌套层级依据（tab 按 2 格计）。
    private nonisolated static func leadingWhitespaceCount(_ s: String) -> Int {
        var count = 0
        for ch in s {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 2 }
            else { break }
        }
        return count
    }

    /// 缩进空格数 → 嵌套层级（单一事实来源，解析/渲染共用）：
    /// 0~1 空格 = 顶层；2~9 空格 = 1 级；10~17 = 2 级；每 8 空格升一级。
    /// markdown 惯例 2~4 空格即 1 级嵌套，直接把空格数当层级会把缩进放大成离谱空白。
    private nonisolated static func indentLevel(_ spaces: Int) -> Int {
        guard spaces >= 2 else { return 0 }
        return (spaces - 2) / 8 + 1
    }

    private nonisolated static func parseBulletItem(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^[-*+]\s+(.+)/) else { return nil }
        return String(match.1)
    }

    private nonisolated static func parseOrderedItem(_ line: String) -> (start: Int, content: String)? {
        guard let match = line.firstMatch(of: /^(\d+)\.\s+(.+)/) else { return nil }
        // 2026-08-08 补齐：保留原始起始数字（`3.` 开头则从 3 编号）
        return (Int(match.1) ?? 1, String(match.2))
    }

    private nonisolated static func parseBlockquote(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^>\s?(.*)/) else { return nil }
        return String(match.1)
    }


    private nonisolated static func parseMediaLine(_ line: String) -> (alt: String, url: String, type: MediaType)? {
        guard let match = line.firstMatch(of: /^[\s]*!\[(.*?)\]\(([^\s)]+)\)[\s.,;:]*$/) else { return nil }
        let alt = String(match.1)
        let url = String(match.2)
        // 统一扩展名判定（图片/视频/音频/代码/PDF/Office/HTML，见 classifyMediaType）；
        // 未识别的扩展名（epub/zip/mobi 等）按「通用文件」处理，不再误判为图片——
        // epub 曾因此被 UIImage 加载失败、展示成灰框+路径文本。
        return (alt, url, classifyMediaType(url) ?? .file)
    }

    /// 媒体类型判定（单一事实来源）：根据 URL 扩展名分类；nil = 未识别的通用文件。
    /// 类型判定的**单一事实来源**：parseMediaLine / parseMediaLinkInText / FilePreviewView
    /// 共用，避免多处扩展名列表漂移。先剥离查询参数 / fragment 再取扩展名
    /// （URL 可能带 ?x=1 等后缀）。
    nonisolated static func classifyMediaType(_ urlString: String) -> MediaType? {
        let cleaned = urlString.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "#", maxSplits: 1)[0]
        let ext = cleaned.components(separatedBy: ".").last?.lowercased() ?? ""
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "heic", "heif":
            return .image
        case "mp4", "mov", "webm", "m4v":
            return .video
        case "mp3", "wav", "ogg", "m4a", "aac":
            return .audio
        case "py", "json", "md", "txt", "yaml", "yml", "toml", "xml", "csv", "sh", "swift", "js", "ts", "css", "log",
             "ini", "conf", "env", "properties", "plist", "sql", "go", "rs", "java", "c", "h", "cpp", "hpp", "cc",
             "kt", "rb", "php", "pl", "lua", "r", "dart", "gradle", "bat", "ps1", "vue", "svelte", "scss", "less",
             "jsonc", "ipynb":
            return .code
        case "pdf":
            return .pdf
        case "docx", "xlsx", "pptx", "doc", "xls", "ppt":
            return .office
        case "html", "htm":
            return .html
        default:
            return nil
        }
    }

    /// 防御性检测：文本行中的普通 markdown 链接 `[alt](url)` 若 URL 以媒体扩展名结尾，
    /// 则提升为媒体块。仅匹配「整行（去首尾空白后）就是一个链接」的场景，避免误匹配
    /// 正常段落中夹杂的文件链接。
    private nonisolated static func parseMediaLinkInText(_ line: String) -> (alt: String, url: String, type: MediaType)? {
        // 匹配 [alt](url) 形式（无 ! 前缀），URL 不含空格和右括号
        guard let match = line.firstMatch(of: /^[\s]*\[(.*?)\]\(([^\s)]+)\)[\s.,;:]*$/) else { return nil }
        let alt = String(match.1)
        let url = String(match.2)
        // 仅对已知媒体扩展名提升（与 parseMediaLine 共用 classifyMediaType 单一实现）
        guard let type = classifyMediaType(url) else { return nil }
        return (alt, url, type)
    }

    private nonisolated static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let marker = compact.first else { return false }
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private nonisolated static func isTableRow(_ line: String) -> Bool {
        parseTableCells(line).count >= 2
    }

    private nonisolated static func isTableSeparator(_ line: String) -> Bool {
        let cells = parseTableCells(line.trimmingCharacters(in: .whitespaces))
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.replacingOccurrences(of: " ", with: "")
            // 2026-08-08 放宽：GFM 允许 ≥1 个 `-`（`|-|` 合法），`:---:` 对齐保留
            return compact.firstMatch(of: /^:?-+:?$/) != nil
        }
    }

    /// 从分隔行（`| :--- | :---: | ---: |`）解析每列对齐方式。
    /// `:---` = leading, `:---:` = center, `---:` = trailing, `---` = leading（默认）。
    private nonisolated static func parseTableAlignments(_ line: String, columnCount: Int) -> [ColumnAlignment] {
        let cells = parseTableCells(line.trimmingCharacters(in: .whitespaces))
        var result: [ColumnAlignment] = []
        for cell in cells.prefix(columnCount) {
            let compact = cell.replacingOccurrences(of: " ", with: "")
            let hasLeadingColon = compact.hasPrefix(":")
            let hasTrailingColon = compact.hasSuffix(":")
            if hasLeadingColon && hasTrailingColon {
                result.append(.center)
            } else if hasTrailingColon {
                result.append(.trailing)
            } else {
                result.append(.leading)
            }
        }
        // 补齐到 columnCount（分隔行不足列数时默认 leading）
        while result.count < columnCount { result.append(.leading) }
        return result
    }

    private nonisolated static func parseTableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }

        var cells: [String] = []
        var current = ""
        var isEscaped = false
        var isInCode = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                current.append(character)
                continue
            }
            if character == "`" {
                isInCode.toggle()
                current.append(character)
                continue
            }
            if character == "|" && !isInCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private nonisolated static func normalizeTableRow(_ row: [String], columnCount: Int) -> [String] {
        if row.count == columnCount { return row }
        if row.count > columnCount { return Array(row.prefix(columnCount)) }
        return row + Array(repeating: "", count: columnCount - row.count)
    }

}
