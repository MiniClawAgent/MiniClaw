import Foundation

/// 工具参数流式解析：从未收完的部分 JSON 中提取「主参数」的部分字符串值。
/// 方法借鉴 OpenMinis（SSE 增量上抛 + 部分值提取），实现为 MiniClaw 自有代码。
/// 用途：AI 正在生成 file_write 的 content / file_edit 的 old_string / shell 的 command
/// 等长参数时，卡片实时显示已生成的部分，而不是等到参数完整才一次性出现。
enum ToolStreamingParser {

    /// 各工具的「主参数」：流式展示时优先显示它的已生成部分。
    private static let primaryKeys: [String: [String]] = [
        "shell_execute": ["command"],
        "file_write": ["content", "path"],
        "file_edit": ["old_string", "new_string"],
        "file_read": ["path"],
        "memory_write": ["content"],
        "browser_use": ["action", "url"],
    ]

    /// 提取主参数的部分字符串值；无法提取（主参数未开始生成等）返回 nil。
    static func primaryPartialValue(name: String, partialJSON: String) -> String? {
        let keys = primaryKeys[name] ?? []
        for key in keys {
            if let v = partialStringValue(key, from: partialJSON) {
                return v
            }
        }
        // 兜底：主参数未开始时显示已生成的参数名/字节数提示由调用方处理。
        return nil
    }

    /// 从部分 JSON 提取 `"key": "value…` 的 value 已到达部分。
    /// 处理三种状态：键已出现值未开始（返回 ""）、值收集中（返回已到达部分，含转义还原）、
    /// 值已完整（返回完整值）。
    static func partialStringValue(_ key: String, from partialJSON: String) -> String? {
        // 定位 "key" 的引号位置（容忍空白差异）。
        let patterns = ["\"\(key)\"", "\"\(key)\" "]
        var searchRange = partialJSON.startIndex..<partialJSON.endIndex
        var keyRange: Range<String.Index>? = nil
        for pat in patterns {
            if let r = partialJSON.range(of: pat, range: searchRange) {
                keyRange = r
                break
            }
        }
        guard let kr = keyRange else { return nil }

        // 从 key 结束向后找值的开引号（跳过 : 与空白）。
        var i = kr.upperBound
        var sawColon = false
        while i < partialJSON.endIndex {
            let ch = partialJSON[i]
            if ch == ":" { sawColon = true }
            else if sawColon, ch == "\"" {
                // 值的开引号找到，收集到末尾或未转义的闭引号。
                var out = ""
                var j = partialJSON.index(after: i)
                while j < partialJSON.endIndex {
                    let c = partialJSON[j]
                    if c == "\\" {
                        // 转义序列：还原常见转义（尾部截半的转义序列直接丢弃）。
                        let next = partialJSON.index(after: j)
                        if next >= partialJSON.endIndex { return out }
                        let esc = String(partialJSON[next])
                        switch esc {
                        case "n": out += "\n"
                        case "t": out += "\t"
                        case "\"": out += "\""
                        case "\\": out += "\\"
                        default: out += esc
                        }
                        j = partialJSON.index(after: next)
                        continue
                    }
                    if c == "\"" {
                        return out // 值完整闭合
                    }
                    out.append(c)
                    j = partialJSON.index(after: j)
                }
                return out // 值仍在流式生成中（JSON 未闭合）
            }
            i = partialJSON.index(after: i)
        }
        return nil
    }
}
