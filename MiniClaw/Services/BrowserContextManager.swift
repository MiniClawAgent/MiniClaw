import Foundation
import WebKit

/// 会话 → 浏览器上下文映射管理器。
/// 每个 ChatSession 拥有独立的 BrowserContext（标签页/进程池隔离），
/// 但 Cookie/Storage 全局共享一份**持久化**存储（方案 A，用户 2026-08-05 拍板）：
/// 手动浏览与 智能体浏览登录态互通，且跨启动保留（原 nonPersistent 每次重启全丢）。
@MainActor
final class BrowserContextManager {
    static let shared = BrowserContextManager()

    /// 全局共享的持久化 dataStore（固定 identifier）：cookie/localStorage 落盘保存。
    /// WKWebsiteDataStore(forIdentifier:) 官方 API（iOS 9+），数据存于 App 沙盒，
    /// 按 identifier 隔离；固定 ID 保证跨启动指向同一份数据。
    static let sharedDataStore: WKWebsiteDataStore = {
        let fixedID = UUID(uuidString: "B0A1E57C-0000-4000-8000-00000000CAFE")!
        return WKWebsiteDataStore(forIdentifier: fixedID)
    }()

    private var contexts: [UUID: BrowserContext] = [:]

    /// 获取指定会话的浏览器上下文；不存在则自动创建。
    func context(for sessionID: UUID) -> BrowserContext {
        if let ctx = contexts[sessionID] { return ctx }
        let ctx = BrowserContext(dataStore: Self.sharedDataStore)
        contexts[sessionID] = ctx
        return ctx
    }

    /// 销毁指定会话的浏览器上下文（退出会话 / 删除会话时调用）
    func destroy(sessionID: UUID) {
        contexts.removeValue(forKey: sessionID)
    }

    /// 当前激活的上下文（由 BrowserController 设置）
    var activeContext: BrowserContext?
}
