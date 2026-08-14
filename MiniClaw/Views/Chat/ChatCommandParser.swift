import SwiftUI

/// 聊天输入斜杠命令解析（2026-08 提取：与 ChatView 状态解耦，纯逻辑可单测）。
enum ChatCommandParser {

    /// 可用的思考强度档位（固定列表，与 normalizedThinkingLevel 对齐）。
    static let thinkingLevels: [(id: String, label: String)] = [
        ("low", L10n.l("level_low")), ("medium", L10n.l("level_medium")), ("high", L10n.l("high")), ("xhigh", L10n.l("very_high")), ("max", L10n.l("level_extreme"))
    ]


    /// 档位 id → 中文标签。
    static let thinkingLevelLabels: [String: String] = [
        "low": L10n.l("level_low"), "medium": L10n.l("level_medium"), "high": L10n.l("high"), "xhigh": L10n.l("very_high"), "max": L10n.l("level_extreme")
    ]


    /// 解析「/技能名」指令：若输入以 `/` 开头且首个分词匹配某个已加载技能，
    /// 返回 (技能名, 后续任务文本)；否则返回 nil（视为普通消息或内置命令）。
    @MainActor
    static func parseSkillCommand(_ raw: String) -> (skill: String, task: String)? {
        guard raw.hasPrefix("/") else { return nil }
        let body = String(raw.dropFirst())
        let comps = body.split(separator: " ", maxSplits: 1)
        guard let first = comps.first, !first.isEmpty else { return nil }
        let name = String(first)
        guard SkillManager.shared.skillNames().contains(name) else { return nil }
        let task = comps.count > 1 ? String(comps[1]).trimmingCharacters(in: .whitespaces) : ""
        return (name, task)
    }


    /// 从输入文本匹配内置（非技能）斜杠命令。命中返回对应命令项，否则返回 nil。
    /// 仅匹配 `SlashCommandOverlay.defaultCommands`，技能命令由 parseSkillCommand 处理。
    static func builtinCommand(matching raw: String) -> SlashCommandItem? {
        guard raw.hasPrefix("/") else { return nil }
        let body = String(raw.dropFirst())
        return SlashCommandOverlay.defaultCommands.first { cmd in
            body == cmd.id || body.hasPrefix(cmd.id + " ")
        }
    }
}
