import Foundation

/// 子代理生命周期管理（关闭等跨组件操作收口）。
/// 按用户纪律归入 `Services/SubAgent/` 文件夹：子代理相关的配置与方法统一在此维护。
/// 被 `close_subagent` 工具（引擎保留工具）与 UI 长按删除共用，两条路径行为一致。
enum SubagentLifecycle {

    /// 关闭一个子代理：取消运行中的引擎 → 移除复用记录（防「关闭后又复用」）→
    /// 移除对话与头像卡片（SubagentStore 落盘）。返回给模型的提示文本。
    /// - Parameters:
    ///   - sessionID: 父会话 id（SubagentStore 按会话隔离）。
    ///   - subagentID: 要关闭的子代理 id。
    ///   - cancel: 取消运行中子代理的闭包（引擎侧传引擎自身；UI 侧经 ChatSessionRuntime 转发）。
    /// - Returns: (成功与否, 给模型的提示文本)。
    @MainActor
    static func close(sessionID: UUID, subagentID: UUID, cancel: ((UUID) -> Void)? = nil) -> (ok: Bool, text: String) {
        // 1. 取消仍在运行的子代理引擎（幂等：未运行则无操作），并发出取消终态事件。
        cancel?(subagentID)
        // 2. 移除复用记录：关闭后该 id 不可再复用（复用查询回落新建，语义自然）。
        SubagentRuntimeRegistry.shared.remove(sessionID: sessionID, subagentID: subagentID)

        // 3. 移除头像卡片 + 对话（落盘 subagent_store.json），与用户长按删除同一方法。
        // 存在性以头像卡片为准（卡片与对话在 startSubagent 同步创建；卡片更能代表「用户可见」）。
        let existed = SubagentStore.shared.avatars(for: sessionID).contains { $0.id == subagentID }
        SubagentStore.shared.removeSubagent(sessionID: sessionID, subagentID: subagentID)

        // 4. 释放该子代理独占的浏览器上下文（独立标签组，防止残留占资源）。
        BrowserContextManager.shared.destroy(sessionID: subagentID)

        if existed {
            return (true, "子代理（id: \(subagentID.uuidString)）已关闭：其会话与头像已移除，上下文已释放。")
        } else {
            return (false, "该子代理（id: \(subagentID.uuidString)）不存在或已关闭，无需重复关闭。")
        }
    }
}
