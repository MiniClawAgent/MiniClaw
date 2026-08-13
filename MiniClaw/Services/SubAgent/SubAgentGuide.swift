import Foundation

/// 子代理使用引导文案：注入主引擎 system prompt 的 stable 段。
/// 万能助手定位：不限定编程，面向查证/写作/规划等通用复杂任务。
enum SubAgentGuide {
    /// 固定引导段（profile 列表由调用方动态拼入，见 `withProfiles`）。
    static let usageGuide = """
    ## 子代理使用指南

    当任务满足以下任一条件时，**优先**调用 `dispatch_subagent` 派发子代理并行/独立处理，而不是自己一步步做完：

    - 任务需要**多轮查证、多来源对比**（如"帮我查一下 X 和 Y 的区别/哪个好"）；
    - 任务可以**拆成互不依赖的几块**（如"分别调研 A、B、C 三件事"）——用 `tasks` 数组一次并行派发；
    - 任务会**占据大量上下文**（如长文写作、长篇资料整理），隔离到子代理可保持主上下文聚焦；
    - 用户明确要求"认真研究 / 仔细对比 / 详细规划 / 写一份完整报告"。

    规则：
    - 通过 `profile` 参数选择最合适的角色（见下方角色列表）；不传则用默认「通用助手」。
    - 每个子代理会独立使用工具完成任务并返回自包含总结；需要完整内容时调用 `read_subagent_result` 分页读取。
    - 子代理最多嵌套 2 层、全局同时运行不超过 4 个；达到上限时按返回提示等待或自行完成。
    - **复用**：每个子代理都有稳定的 `subagent_id`（见下方「当前会话的子代理」清单）。后续任务若与某子代理
      相关，用 `dispatch_subagent` 的 `subagent_id` 参数续派**同一个**子代理（它保留之前的角色与上下文），
      不要每次都新建——子代理是可持续对话的独立工作伙伴，不是一次性工具。
    - **关闭**：某子代理的任务已彻底完成、后续不再需要时，调用 `close_subagent` 关闭它——
      其会话与头像将一并移除，释放上下文；关闭后不可再复用（如再需要，重新派发新建即可）。
    - 简单任务**不要**派发子代理——它有额外开销，只有上述复杂场景才值得。
    """

    /// 动态拼接角色列表后的完整引导段（stable 段注入用）。
    /// 用户关闭子代理（设置 → 智能体 → 子代理）时，返回禁用说明——模型必须知道
    /// 子代理不可用，避免继续尝试派发（配合引擎侧 schema 剔除与执行守卫）。
    static func guideWithProfiles() -> String {
        guard SettingsStore.shared.settings.subagent.enabled else {
            return """
            ## 子代理使用指南

            ⚠️ **子代理已被用户关闭**（设置 → 智能体 → 子代理）。

            你**不能**调用 `dispatch_subagent`，也不要想办法绕过。请直接使用你手上的工具完成任务；任务量大时拆成多轮逐步完成即可。
            """
        }
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
