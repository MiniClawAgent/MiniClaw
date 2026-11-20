import Foundation

/// 子代理使用引导文案：注入主引擎 system prompt 的 stable 段。
/// 万能助手定位：不限定编程，面向查证/写作/规划等通用复杂任务。
enum SubAgentGuide {
    /// 固定引导段（profile 列表由调用方动态拼入，见 `withProfiles`）。i18n：整段经 String(localized:) 查 String Catalog。
    static var usageGuide: String {
        String(localized: "subagent_usage_guide")
    }

    /// 动态拼接角色列表后的完整引导段（stable 段注入用）。
    /// 子代理恒可用：角色列表来自 SubAgentProfileStore（含内置 subagents 插件与用户导入包）。
    static func guideWithProfiles() -> String {
        let summaries = SubAgentProfileStore.shared.allSummaries()
        let list = summaries.isEmpty
            ? String(localized: "general_assistant_role")
            : summaries.map { "- \($0.displayName)（`\($0.name)`）：\($0.summary)" }.joined(separator: "\n")
        return usageGuide + String(localized: "available_subagent_roles") + list
    }

    /// 子代理操作铁律（**无条件**注入易变段的最末「子代理段」）。
    /// 它防的是「回复文本里声称已派发/已关闭」的假执行——与是否存在存活子代理无关，
    /// 故不能跟着下面的存活清单一起被条件带上。
    ///
    /// 它同时是该「子代理段」的**起始标记**：`AgentLoopEngine.rebuildVolatile()` 在
    /// `skill-load` 之后重排易变段时按它把技能正文插到本段之前，使子代理段（含
    /// `close-subagent` 要用的短码）恒定保持在易变段最末。
    /// 构造侧与重排侧**共用此常量**——任何一侧都不得自行复制字面量，否则两侧失步。
    static let ironRule = "**子代理操作铁律：** 派发子代理**只能**通过 `dispatch-subagent` 工具；关闭子代理**只能**通过 `close-subagent` 工具。在回复文本中声称「已派发/已关闭」**不会产生任何实际效果**——没有对应工具调用，子代理不会被创建或关闭。"

    /// 「当前会话的子代理」清单段（A 方案：注入易变段，缓存断点之后）。
    /// 让主 智能体每轮都「看见」本会话已存在的子代理（身份 + 角色 + 聚焦 + 状态 + 最近任务），
    /// 从而真实复用（续派同一 subagent_id）与按需关闭（close-subagent），而非每轮盲派新建。
    /// 记录来自 SubagentRuntimeRegistry（跨轮次/跨重启存活）；无子代理时返回 nil（不注入）。
    static func liveSubagentsSection(records: [SubagentRuntimeRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let lines = records.map { rec -> String in
            let idShort = String(rec.id.uuidString.prefix(8))
            let role = rec.profile.map { String(format: String(localized: "subagent_role_label"), $0) } ?? String(localized: "role_general")
            let focus = (rec.focus?.isEmpty == false) ? String(format: String(localized: "subagent_focus_label"), rec.focus!) : nil
            let task = rec.info.task.isEmpty ? nil : String(format: String(localized: "subagent_recent_task"), String(rec.info.task.prefix(60)))
            let status: String
            switch rec.status {
            case .running: status = String(localized: "status_running")
            case .error: status = String(localized: "error_title")
            case .completed: status = String(localized: "completed")
            case .cancelled: status = String(localized: "cancelled")
            }
            let parts = ["- `\(idShort)`（\(rec.info.name)）", role, focus, String(format: String(localized: "subagent_status_label"), status), task]
                .compactMap { $0 }.joined(separator: " · ")
            return parts
        }
        return """
        ### 当前会话的子代理
        以下子代理已存在，可复用（dispatch-subagent 传 subagent_id 续派）或关闭（close-subagent）；id 支持列表中的 8 位短码：
        \(lines.joined(separator: "\n"))
        """
    }
}
