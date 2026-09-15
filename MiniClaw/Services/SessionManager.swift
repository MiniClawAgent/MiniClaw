import Foundation

/// 会话持久化管理器。iOS16 适配(2026-08-12):持久层经 SQLite 单库存储
/// (`Documents/MiniClaw/sessions/miniclaw.db`,sessions/messages 两表,见 SQLiteStore)。
/// 内存持有全量会话(@Published),所有读写经主线程;磁盘写由 SQLiteStore 串行队列落库。
@MainActor
final class SessionManager: ObservableObject {
    /// 主线程单例。
    private nonisolated(unsafe) static var _shared: SessionManager?
    static var shared: SessionManager {
        if let existing = _shared { return existing }
        let instance = SessionManager()
        _shared = instance
        return instance
    }

    /// 内存全量会话(启动 load() 后可用;变更点先改数组再手动 objectWillChange.send(),
    /// 保证订阅者 reload 时读到的是已变更后的新数组——消灭 @Published willSet 旧快照竞态,
    /// 2026-08-12 治本)。
    private(set) var sessions: [ChatSession] = []

    private let ioQueue = DispatchQueue(label: "MiniClaw.SessionManager.io")

    // MARK: - 启动加载

    /// 启动加载完成信号（2026-09-05 主线程治理）：load() 异步化后，
    /// 快捷指令/深链等同步依赖方在读取会话前 await 本等待（超时兜底 3s）。
    public private(set) var isLoaded = false
    private var isLoading = false

    /// 等待启动加载完成（异步 load 的同步依赖方用；超时兜底防永久挂起）。
    func waitForLoaded(timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isLoaded && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 启动时全量加载(自 SQLite 单库)。
    /// **异步化（2026-09-05 主线程治理）**：SQLite 读 + 全部消息 JSON 解码曾在主线程
    /// 同步执行，11 个会话时启动主线程冻结 4s+（系统看门狗击杀码 400 的直接前奏）。
    /// 改为后台加载，完成后经 @Published 刷新；幂等（重复调用不重复加载）。
    /// 加载窗口期新建的会话合并保留，不被异步加载覆盖。
    func load() {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        ioQueue.async { [weak self] in
            let loaded = SQLiteStore.shared.loadSessions()
            Task { @MainActor in
                guard let self else { return }
                // 合并：加载窗口期新建的会话（库内没有）保留，避免被覆盖丢失
                let loadedIDs = Set(loaded.map(\.id))
                let createdDuringLoad = self.sessions.filter { !loadedIDs.contains($0.id) }
                self.sessions = createdDuringLoad + loaded
                self.isLoaded = true
                self.isLoading = false
                self.objectWillChange.send()
                AppLogger.shared.info(String(format: String(localized: "sessionmanager_loaded"), loaded.count), category: "Session")
            }
        }
    }

    /// 写盘(SQLite 串行落库)。failure 时由 SQLiteStore 记录日志(不静默)。
    func persist(_ session: ChatSession) {
        // 主线程提取值类型行快照(避免非 Sendable 对象进异步闭包),后台队列落库。
        let rows = SQLiteStore.SessionPersistRows.extract(from: session)
        ioQueue.async {
            SQLiteStore.shared.saveSessionRows(rows)
        }
    }

    /// 同步写盘(2026-08-12 治本):暂停/终态等"写完才安全"的时机使用。
    /// 异步写会被"暂停后立刻退出 App"丢掉(ioQueue 未执行),导致重启后
    /// 只剩用户消息——暂停/终态是数据完整性关键点,必须等落库完成再返回。
    func persistSynchronously(_ session: ChatSession) {
        let rows = SQLiteStore.SessionPersistRows.extract(from: session)
        ioQueue.sync {
            SQLiteStore.shared.saveSessionRows(rows)
        }
    }

    // MARK: - CRUD(保持原方法签名)

    func createSession(title: String = String(localized: "new_chat_title"), model: String = String(localized: "not_configured"), agentName: String = "MiniClaw", source: String = "app") -> ChatSession? {
        let session = ChatSession(
            title: title,
            modelName: model,
            agentName: agentName,
            source: source
        )
        sessions.insert(session, at: 0)
        objectWillChange.send()
        persist(session)

        // 建立会话专属隔离目录（事务的一部分）：
        // Documents/MiniClaw-Sessions/<uuid>/{workspace,attachments,browser,offloads}
        SessionFileRouter.shared.ensureHostDirs(for: session.id)

        return session
    }

    /// 会话销毁统一入口：终止运行中引擎 + 移除运行时 + 清检查点 + 清排队/草稿。
    func teardownSession(id: UUID) {
        if let runtime = AppState.shared.chatRuntimes[id] {
            runtime.engine.cancel()
        }
        AppState.shared.chatRuntimes[id] = nil
        AgentTaskStore.shared.clear(sessionID: id)
        PendingMessageStore.shared.save([], for: id)
        PendingMessageStore.shared.clearDraft(for: id)
    }

    // MARK: - 会话文件隔离目录

    func ensureSessionHostDirs(for id: UUID) {
        SessionFileRouter.shared.ensureHostDirs(for: id)
    }

    func sessionHostDirectory(id: UUID) -> URL {
        SessionFileRouter.shared.sessionHostDirectory(for: id)
    }

    @discardableResult
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
        persist(session)
        return message
    }

    func deleteSession(_ session: ChatSession) {
        let sid = session.id
        teardownSession(id: sid)
        sessions.removeAll { $0.id == sid }
        objectWillChange.send()
        // 与 deleteSession(id:) 一致:SQLite 删除走 ioQueue 与写入同队列 FIFO(2026-08-12 修复)。
        ioQueue.async {
            SQLiteStore.shared.deleteSessionRows(id: sid)
        }
        SessionFileRouter.shared.unregister(sessionID: sid)
        SubagentRuntimeRegistry.shared.clear(sessionID: sid)
        Task { @MainActor in
            BrowserEngineAdapter.shared.destroySession(sid)
            for sub in SubagentStore.shared.avatars(for: sid) {
                BrowserEngineAdapter.shared.destroySession(sub.id)
            }
        }
        SubagentStore.shared.clearSession(sid)
        ContextUsageStore.shared.clear(sessionID: sid)
        TokenUsageTracker.clearSession(sessionID: sid)
        ToolConfirmationBridge.shared.revokeSession(sessionID: sid)
        BackgroundTaskController.shared.endSessionActivity(sessionID: sid.uuidString)
    }

    func updateSessionTitle(_ session: ChatSession, title: String) {
        session.title = title
        session.titleIsPlaceholder = false
        session.updatedAt = Date()
        persist(session)
    }

    func searchMessages(keyword: String, in sessions: [ChatSession]) -> [ChatMessage] {
        sessions.flatMap { $0.messages }.filter {
            $0.content.localizedCaseInsensitiveContains(keyword)
        }
    }

    func getRecentSessions(limit: Int = 20) -> [ChatSession] {
        Array(sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    // MARK: - 供 MiniClaw-sessions-cli 使用的 CRUD

    func allSessions() -> [ChatSession] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func session(id: UUID) -> ChatSession? {
        sessions.first { $0.id == id }
    }

    @discardableResult
    func deleteSession(id: UUID) -> Bool {
        guard session(id: id) != nil else { return false }
        teardownSession(id: id)
        sessions.removeAll { $0.id == id }
        objectWillChange.send()
        // SQLite 删除与 createSession/persist 的写入走同一串行队列(FIFO,2026-08-12 修复):
        // 快速「新建→立即返回」时,删除必然排在异步 INSERT 之后执行,不会残留「幽灵空会话行」
        // (此前同步删除可能先于异步 INSERT,空行被重新插回,下次启动 load() 时幽灵会话复现)。
        let sid = id
        ioQueue.async {
            SQLiteStore.shared.deleteSessionRows(id: sid)
        }
        SessionFileRouter.shared.unregister(sessionID: id)
        SubagentRuntimeRegistry.shared.clear(sessionID: id)
        Task { @MainActor in
            BrowserEngineAdapter.shared.destroySession(id)
            for sub in SubagentStore.shared.avatars(for: id) {
                BrowserEngineAdapter.shared.destroySession(sub.id)
            }
        }
        SubagentStore.shared.clearSession(id)
        ContextUsageStore.shared.clear(sessionID: id)
        TokenUsageTracker.clearSession(sessionID: id)
        ToolConfirmationBridge.shared.revokeSession(sessionID: id)
        BackgroundTaskController.shared.endSessionActivity(sessionID: id.uuidString)
        return true
    }

    func updateSession(id: UUID,
                       title: String? = nil,
                       model: String? = nil,
                       agentName: String? = nil,
                       status: String? = nil,
                       icon: String? = nil,
                       iconColor: String? = nil,
                       isPinned: Bool? = nil) -> Bool {
        guard let s = session(id: id) else { return false }
        if let title { s.title = title }
        if let model { s.modelName = model }
        if let agentName { s.agentName = agentName }
        if let status, let st = SessionStatus(rawValue: status) { s.status = st }
        if let icon { s.icon = icon.isEmpty ? nil : icon }
        if let iconColor { s.iconColor = iconColor.isEmpty ? nil : iconColor }
        if let isPinned { s.isPinned = isPinned }
        // 2026-08-13 修复:仅当本次不是「只改置顶」时才刷新 updatedAt——Pin 是置顶操作,
        // 不应改变"最后回复完成时间"(首页时间显示)。此前无条件 updatedAt=Date() 导致
        // 一置顶时间就重算成"现在"。
        let isPinOnly = (isPinned != nil) && title == nil && model == nil
            && agentName == nil && status == nil && icon == nil && iconColor == nil
        if !isPinOnly {
            s.updatedAt = Date()
        }
        persist(s)
        // 通知首页列表重载(2026-08-12 修复):updateSession 是标题/图标等成员变更的统一出口,
        // 成员对象改值不触发数组 willSet,需手动广播。
        objectWillChange.send()
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
        persist(s)
        return true
    }

    func searchAllMessages(keyword: String) -> [(sessionTitle: String, message: ChatMessage)] {
        allSessions().flatMap { s in
            s.messages
                .filter { $0.content.localizedCaseInsensitiveContains(keyword) }
                .map { (sessionTitle: s.title, message: $0) }
        }
    }

    /// 删除会话内的消息(替代原 ChatView 的 modelContext.delete)。
    func removeMessage(_ msg: ChatMessage, from session: ChatSession) {
        session.messages.removeAll { $0.id == msg.id }
        session.updatedAt = Date()
        persist(session)
    }

    /// 移除会话内全部消息(替代原 ChatView 的批量 delete)。
    func removeAllMessages(from session: ChatSession) {
        session.messages.removeAll()
        session.updatedAt = Date()
        persist(session)
    }
}
