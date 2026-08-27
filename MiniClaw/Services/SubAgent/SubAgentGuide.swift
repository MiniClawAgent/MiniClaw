import Foundation

/// 子代理使用引导文案：注入主引擎 system prompt 的 stable 段。
/// 万能助手定位：不限定编程，面向查证/写作/规划等通用复杂任务。
enum SubAgentGuide {
    /// 固定引导段（profile 列表由调用方动态拼入，见 `withProfiles`）。i18n：整段走 L10n。
    static var usageGuide: String {
        L10n.l("subagent_usage_guide")
    }

    /// 动态拼接角色列表后的完整引导段（stable 段注入用）。
    /// 子代理恒可用：角色列表来自 SubAgentProfileStore（含内置 subagents 插件与用户导入包）。
    static func guideWithProfiles() -> String {
        let summaries = SubAgentProfileStore.shared.allSummaries()
        let list = summaries.isEmpty
            ? L10n.l("general_assistant_role")
            : summaries.map { "- \($0.displayName)（`\($0.name)`）：\($0.summary)" }.joined(separator: "\n")
        return usageGuide + L10n.l("available_subagent_roles") + list
    }

    /// 「当前会话的子代理」清单段（A 方案：注入易变段，缓存断点之后）。
    /// 让主 智能体每轮都「看见」本会话已存在的子代理（身份 + 角色 + 聚焦 + 状态 + 最近任务），
    /// 从而真实复用（续派同一 subagent_id）与按需关闭（close_subagent），而非每轮盲派新建。
    /// 记录来自 SubagentRuntimeRegistry（跨轮次/跨重启存活）；无子代理时返回 nil（不注入）。
    static func liveSubagentsSection(records: [SubagentRuntimeRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let lines = records.map { rec -> String in
            let idShort = String(rec.id.uuidString.prefix(8))
            let role = rec.profile.map { String(format: L10n.l("subagent_role_label"), $0) } ?? L10n.l("role_general")
            let focus = (rec.focus?.isEmpty == false) ? String(format: L10n.l("subagent_focus_label"), rec.focus!) : nil
            let task = rec.info.task.isEmpty ? nil : String(format: L10n.l("subagent_recent_task"), String(rec.info.task.prefix(60)))
            let status: String
            switch rec.status {
            case .running: status = L10n.l("status_running")
            case .error: status = L10n.l("error_title")
            case .completed: status = L10n.l("completed")
            case .cancelled: status = L10n.l("cancelled")
            }
            let parts = ["- `\(idShort)`（\(rec.info.name)）", role, focus, String(format: L10n.l("subagent_status_label"), status), task]
                .compactMap { $0 }.joined(separator: " · ")
            return parts
        }
        return """
        ### 当前会话的子代理
        以下子代理已存在，可复用（用完整 subagent_id 续派）或关闭（close_subagent）：
        \(lines.joined(separator: "\n"))
        """
    }
}
