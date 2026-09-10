import Foundation

/// 子代理生命周期管理（关闭等跨组件操作收口）。
/// 按用户纪律归入 `Services/SubAgent/` 文件夹：子代理相关的配置与方法统一在此维护。
/// 被 `close_subagent` 工具（引擎保留工具）与 UI 长按删除共用，两条路径行为一致。
enum SubagentLifecycle {

    /// 关闭一个子代理：取消运行中的引擎 → 移除复用记录（防「关闭后又复用」）→
    /// 移除对话与头像卡片（SubagentStore 落盘）。返回给模型的提示文本。
    ///   - sessionID: 父会话 id（SubagentStore 按会话隔离）。
    ///   - subagentID: 要关闭的子代理 id。
    ///   - cancel: 取消运行中子代理的闭包（引擎侧传引擎自身；UI 侧经 ChatSessionRuntime 转发）。
    /// - Returns: (closed 本次执行了关闭, alreadyClosed 目标本就处于已关闭态, text 提示文本)。
    ///   alreadyClosed 与 closed 对调用方（引擎）同为「目标达成」——核实性重复关闭
    ///   不应计为失败（2026-09-10：此前返回 (false, 已关闭)，引擎汇总成 ❌，
    ///   模型看到「0 成功 9 失败」只能编故事解释）。
    @MainActor
    static func close(sessionID: UUID, subagentID: UUID, cancel: ((UUID) -> Void)? = nil) -> (closed: Bool, alreadyClosed: Bool, text: String) {
        // 1. 取消仍在运行的子代理引擎（幂等：未运行则无操作），并发出取消终态事件。
        cancel?(subagentID)
        // 2. 判定存在性（必须在 remove 之前）：以 SubagentRuntimeRegistry 为准——
        // 2026-09-10 治本：此前以 SubagentStore 头像卡片为准，而清单/短码解析只读
        // Registry，卡片缺失时「确实存在且已真正关闭」却返回 (false, 已关闭)，
        // 与模型的观感完全相反（三子代理测试实证）。Registry 是存活子代理的单一事实源。
        let existed = SubagentRuntimeRegistry.shared.record(for: sessionID, subagentID: subagentID) != nil
        // 3. 移除复用记录：关闭后该 id 不可再复用（复用查询回落新建，语义自然）。
        SubagentRuntimeRegistry.shared.remove(sessionID: sessionID, subagentID: subagentID)

        // 4. 移除头像卡片 + 对话（落盘 subagent_store.json），与用户长按删除同一方法。
        SubagentStore.shared.removeSubagent(sessionID: sessionID, subagentID: subagentID)

        // 5. 释放该子代理独占的浏览器上下文（独立标签组，防止残留占资源）。
        BrowserContextManager.shared.destroy(sessionID: subagentID)

        if existed {
            return (true, false, String(format: String(localized: "subagent_closed_msg"), subagentID.uuidString))
        } else {
            return (false, true, String(format: String(localized: "subagent_already_closed"), subagentID.uuidString))
        }
    }
}
