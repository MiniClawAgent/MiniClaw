import Foundation
import SwiftData

/// 会话执行层：负责 send / retry 的「执行」语义。
///
/// 方案1（直接读模拟器 SQLite）边界说明：
/// CLI 只做**入队 + 状态标记**，真正的 Agent 推理由 MiniClaw App 在打开该会话时执行；
/// 这里不拉起 LLMClient / AgentLoopEngine，以避免把 App 专属的 ToolRouter / 运行时耦合进 CLI。
///
/// 无头执行扩展点见 `runHeadless`（方案3 / 后续启用）。
final class AgentRuntime {
    let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    /// 向会话追加一条用户消息并标记为待执行（enqueue）。
    func send(ref: String?, text: String?) -> String {
        guard let ref, let uuid = UUID(uuidString: ref) else {
            return fail("send 需要有效的会话 id")
        }
        guard let text, !text.isEmpty else {
            return fail("send 需要 --text <内容>")
        }
        guard store.appendMessage(sessionID: uuid, role: "user", content: text) else {
            return fail("未找到会话 \(ref)")
        }
        _ = store.setStatus(id: uuid, status: "running")

        // 若标题仍为默认且这是首条消息，用其内容生成标题（对齐 App 的 autoGenerateTitle）。
        if let s = store.session(id: uuid),
           (s.title == "新会话" || s.title.isEmpty),
           s.messages.count <= 1 {
            let title = String(text.prefix(40)).replacingOccurrences(of: "\n", with: " ")
            store.renameSession(id: uuid, title: title)
        }

        return prettyJSON([
            "id": ref,
            "action": "send",
            "status": "running",
            "note": "已入队；Agent 推理由 MiniClaw App 在打开会话时执行（方案1 边界）"
        ])
    }

    /// 把失败/中断的会话重新标记为待执行。
    func retry(ref: String?) -> String {
        guard let ref, let uuid = UUID(uuidString: ref) else {
            return fail("retry 需要有效的会话 id")
        }
        guard store.session(id: uuid) != nil else {
            return fail("未找到会话 \(ref)")
        }
        _ = store.setStatus(id: uuid, status: "running")
        return prettyJSON([
            "id": ref,
            "action": "retry",
            "status": "running",
            "note": "已重新标记为待执行；由 MiniClaw App 接续执行"
        ])
    }

    // MARK: - 无头执行扩展点（方案3 / 后续）

    /// 真正在 CLI 内跑 Agent 并回写结果的可行路径：
    /// 复用 AgentLoopEngine + ModelRoutingPlan + 一个 CLI 本地 ToolRouter，
    /// 用 ProviderFileStore 载入服务商配置构造路由计划，把 assistant/tool 消息持久化回 SessionStore。
    /// 当前 方案1 不启用，以避免引入 AppState / SettingsStore 等 App 专属耦合。
    func runHeadless(ref: String) {
        // 预留：func runHeadless(ref:) -> String { ... }
    }
}
