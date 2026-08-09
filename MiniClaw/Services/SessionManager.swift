import Foundation
import SwiftData

@MainActor
@Observable
final class SessionManager {
    /// 主线程单例：由 HomeView 在入口处通过 configure(with:) 注入 SwiftData ModelContext，
    /// 之后可在 Agent Loop / Tools 中安全访问（所有方法均 MainActor 隔离）。
    private nonisolated(unsafe) static var _shared: SessionManager?
    static var shared: SessionManager {
        if let existing = _shared { return existing }
        let instance = SessionManager()
        _shared = instance
        return instance
    }

    private var modelContext: ModelContext?

    func configure(with context: ModelContext) {
        self.modelContext = context
    }

    func createSession(title: String = "新会话", model: String = "未配置", agentName: String = "MiniClaw", source: String = "app") -> ChatSession? {
        guard let context = modelContext else { return nil }

        let session = ChatSession(
            title: title,
            modelName: model,
            agentName: agentName,
            source: source
        )
        context.insert(session)
        try? context.save()

        // 建立会话专属隔离目录（事务的一部分）：
        // Documents/MiniClaw/Sessions/<uuid>/{workspace,attachments,browser,offloads}
        // 供 iSH 侧按 fs_context 路由 /var/MiniClaw/<subdir> 使用。
        SessionFileRouter.shared.ensureHostDirs(for: session.id)

        return session
    }

    /// 会话销毁统一入口：终止运行中引擎 + 移除运行时 + 清检查点 + 清排队/草稿。
    /// 此前删除会话不触碰 `AppState.chatRuntimes`/检查点/排队文件，导致运行中引擎幽灵续跑
    /// （回调写已删除对象、Live Activity 继续更新）、暂停态 runtime 永久泄漏、磁盘残留孤儿文件。
    /// 所有删除路径必须经此收敛（生命周期唯一入口）。
    func teardownSession(id: UUID) {
        // 1. 终止该会话仍在运行的引擎（含子代理）
        if let runtime = AppState.shared.chatRuntimes[id] {
            runtime.engine.cancel()
        }
        // 2. 移除运行时（暂停态也不例外——会话已删，runtime 无意义）
        AppState.shared.chatRuntimes[id] = nil
        // 3. 清检查点（防止残留 .running 被下次进入误恢复）
        AgentTaskStore.shared.clear(sessionID: id)
        // 4. 清排队消息与输入草稿的磁盘残留
        PendingMessageStore.shared.save([], for: id)
        PendingMessageStore.shared.clearDraft(for: id)
    }

    // MARK: - 会话文件隔离目录

    /// 确保该会话的宿主隔离目录树存在（若已存在则无操作）。
    func ensureSessionHostDirs(for id: UUID) {
        SessionFileRouter.shared.ensureHostDirs(for: id)
    }

    /// 该会话的宿主根目录（Swift 侧工具直接读写附件 / 产物用）。
    func sessionHostDirectory(id: UUID) -> URL {
        SessionFileRouter.shared.sessionHostDirectory(for: id)
    }

    func addMessage(to session: ChatSession, role: MessageRole, content: String,
                    attachments: [String] = [], toolCallName: String? = nil,
                    toolCallResult: String? = nil) -> ChatMessage {
        let message = ChatMessage(
            role: role,
            content: content,
            attachments: attachments,
            toolCallName: toolCallName,
            toolCallResult: toolCallResult
        )
        message.session = session
        session.messages.append(message)
        session.updatedAt = Date()
        try? modelContext?.save()

        return message
    }

    func deleteSession(_ session: ChatSession) {
        let sid = session.id
        teardownSession(id: sid)
        modelContext?.delete(session)
        try? modelContext?.save()
        // 清理会话隔离资源：注销 fsContext 映射 + 删除 Sessions/<uuid>/ 宿主目录
        SessionFileRouter.shared.unregister(sessionID: sid)
        // 顺手清掉该会话的子代理运行期注册表（复用状态不再需要）。
        SubagentRuntimeRegistry.shared.clear(sessionID: sid)
        // 销毁该会话与各子代理的浏览器上下文（独立标签组不残留）。
        Task { @MainActor in
            BrowserContextManager.shared.destroy(sessionID: sid)
            for sub in SubagentStore.shared.avatars(for: sid) {
                BrowserContextManager.shared.destroy(sessionID: sub.id)
            }
        }
        // 级联清理该会话的子代理头像卡片与对话（磁盘 + 内存，P1）。
        SubagentStore.shared.clearSession(sid)
        ContextUsageStore.shared.clear(sessionID: sid)
        // 撤销该会话的「允许本次会话」授权，避免泄漏到后续新建的同 ID 会话。
        ToolConfirmationBridge.shared.revokeSession(sessionID: sid)
        // 关闭该会话残留的 Live Activity（会话级生命周期随会话删除而终止）。
        BackgroundTaskController.shared.endSessionActivity(sessionID: sid.uuidString)
    }

    func updateSessionTitle(_ session: ChatSession, title: String) {
        session.title = title
        session.titleIsPlaceholder = false
        session.updatedAt = Date()
        try? modelContext?.save()
    }

    func searchMessages(keyword: String, in sessions: [ChatSession]) -> [ChatMessage] {
        sessions.flatMap { $0.messages }.filter {
            $0.content.localizedCaseInsensitiveContains(keyword)
        }
    }

    func getRecentSessions(limit: Int = 20) -> [ChatSession] {
        guard let context = modelContext else { return [] }

        var descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 供 MiniClaw-sessions-cli 使用的 CRUD

    func allSessions() -> [ChatSession] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func session(id: UUID) -> ChatSession? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    func deleteSession(id: UUID) -> Bool {
        guard let s = session(id: id) else { return false }
        teardownSession(id: id)
        modelContext?.delete(s)
        try? modelContext?.save()
        // 清理会话隔离资源：注销 fsContext 映射 + 删除 Sessions/<uuid>/ 宿主目录
        SessionFileRouter.shared.unregister(sessionID: id)
        // 顺手清掉该会话的子代理运行期注册表（复用状态不再需要）。
        SubagentRuntimeRegistry.shared.clear(sessionID: id)
        // 销毁该会话与各子代理的浏览器上下文（独立标签组不残留；与 deleteSession(_:) 一致）。
        Task { @MainActor in
            BrowserContextManager.shared.destroy(sessionID: id)
            for sub in SubagentStore.shared.avatars(for: id) {
                BrowserContextManager.shared.destroy(sessionID: sub.id)
            }
        }
        // 级联清理该会话的子代理头像卡片与对话（磁盘 + 内存，P1）。
        SubagentStore.shared.clearSession(id)
        ContextUsageStore.shared.clear(sessionID: id)
        // 撤销该会话的「允许本次会话」授权，避免泄漏到后续新建的同 ID 会话。
        ToolConfirmationBridge.shared.revokeSession(sessionID: id)
        // 关闭该会话残留的 Live Activity（会话级生命周期随会话删除而终止）。
        BackgroundTaskController.shared.endSessionActivity(sessionID: id.uuidString)
        return true
    }

    func updateSession(id: UUID,
                       title: String? = nil,
                       model: String? = nil,
                       agentName: String? = nil,
                       status: String? = nil,
                       icon: String? = nil,
                       iconColor: String? = nil) -> Bool {
        guard let s = session(id: id) else { return false }
        if let title { s.title = title }
        if let model { s.modelName = model }
        if let agentName { s.agentName = agentName }
        if let status, let st = SessionStatus(rawValue: status) { s.status = st }
        if let icon { s.icon = icon.isEmpty ? nil : icon }
        if let iconColor { s.iconColor = iconColor.isEmpty ? nil : iconColor }
        s.updatedAt = Date()
        try? modelContext?.save()
        // 标题/图标/配色任一变更即回传：刷新该会话 Live Activity（统一变更出口）。
        if title != nil || icon != nil || iconColor != nil {
            BackgroundTaskController.shared.agentDidUpdateSession(sessionID: id.uuidString)
        }
        return true
    }

    @discardableResult
    func appendMessage(sessionId: UUID, role: String = "user", content: String) -> Bool {
        guard let s = session(id: sessionId) else { return false }
        let r = MessageRole(rawValue: role) ?? .user
        let msg = ChatMessage(role: r, content: content)
        msg.session = s
        s.messages.append(msg)
        s.updatedAt = Date()
        try? modelContext?.save()
        return true
    }

    func searchAllMessages(keyword: String) -> [(sessionTitle: String, message: ChatMessage)] {
        allSessions().flatMap { s in
            s.messages
                .filter { $0.content.localizedCaseInsensitiveContains(keyword) }
                .map { (sessionTitle: s.title, message: $0) }
        }
    }
}
