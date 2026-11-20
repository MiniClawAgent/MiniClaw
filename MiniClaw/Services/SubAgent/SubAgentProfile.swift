import Foundation

/// 子代理角色（profile）：一个 Markdown 文件 = 一个子代理的人设。
/// 文件格式（与技能/规则同款 frontmatter 风格）：
/// ```
/// ---
/// name: 调研专员
/// description: 查资料、多源对比、事实核查，适合"帮我研究/对比/查证"类任务
/// read_only: false
/// ---
///
/// （正文 = 子代理的完整系统提示词，reasonix 原则：profile body becomes the full child system prompt）
/// ```
/// 文件放 `MiniClawRoot/subagent-profiles/`，用户可自建/编辑；内置样例随 App 同步。
struct SubAgentProfile: Identifiable, Equatable {
    /// 文件名（不含 .md），同时也是 dispatch-subagent 的 `profile` 参数值。
    let name: String
    /// frontmatter `name`（显示名，子代理卡片/UI 展示用）。
    let displayName: String
    /// frontmatter `description`（给父模型看：决定何时选这个角色）。
    let summary: String
    /// 正文：子代理的完整系统提示词。
    let systemPrompt: String

    var id: String { name }

    /// 解析一个 profile 文件内容；frontmatter 缺失/未闭合时回退（文件名即 name）。
    static func parse(fileName: String, content: String) -> SubAgentProfile? {
        // 去 UTF-8 BOM（部分编辑器保存时写入，会让 hasPrefix("---") 静默失败）。
        var raw = content
        if raw.hasPrefix("\u{FEFF}") {
            raw = String(raw.dropFirst())
        }
        var body = raw
        var displayName = fileName
        var summary = ""

        if raw.hasPrefix("---") {
            if let end = raw.range(of: "\n---", options: .literal) {
                let fmStart = raw.index(raw.startIndex, offsetBy: 3)
                let fmText = String(raw[fmStart..<end.lowerBound])
                body = String(raw[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                for line in fmText.split(separator: "\n") {
                    let parts = line.split(separator: ":", maxSplits: 1)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "name": displayName = parts[1]
                    case "description": summary = parts[1]
                    default: break
                    }
                }
            } else {
                // 以 --- 开头但未闭合：剥掉首行，剩余视为正文（frontmatter 字段不生效）。
                if let nl = raw.firstIndex(of: "\n") {
                    body = String(raw[raw.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    body = ""
                }
            }
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SubAgentProfile(name: fileName, displayName: displayName,
                               summary: summary, systemPrompt: trimmed)
    }
}
