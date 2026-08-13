import Foundation

/// 会话后「复盘分身」：在用户离开会话或 App 进入后台时，跑一次受限 Agent，
/// 把用户画像 / 偏好 / 近况沉淀进长期记忆，并为本次会话生成一句摘要存进 `ChatSession.summary`。
///
/// 触发：ChatView.onDisappear 与 MiniClawApp 的 scenePhase=.background。
/// 收敛策略：同一会话短窗口内只跑一次；无新消息或正在回复时跳过。
final class SessionReviewService: @unchecked Sendable {
    static let shared = SessionReviewService()

    private let running = NSLockedSet<UUID>()

    func schedule(sessionID: UUID) {
        guard running.insert(sessionID) else { return }
        Task.detached(priority: .background) { [weak self] in
            defer { self?.running.remove(sessionID) }
            await self?.runReview(sessionID: sessionID)
        }
    }

    private func runReview(sessionID: UUID) async {
        // 设置快照：后台线程不裸读 SettingsStore（2026-08-13 竞争修复）。
        let settings = await SettingsStore.shared.snapshot()
        // 「启用记忆」总开关关闭时跳过复盘：不写记忆、不消耗后台模型。
        guard settings.memory.isEnabled else { return }
        // 主线程收集所需数据
        struct ReviewInput: @unchecked Sendable {
            let session: ChatSession
            let history: [ChatCompletionMessage]
            let endpoint: ModelRouteEndpoint
            let messageCount: Int
        }

        let input = await MainActor.run { () -> ReviewInput? in
            guard let session = SessionManager.shared.session(id: sessionID) else { return nil }
            let messageCount = session.messages.count
            guard messageCount > 0 else { return nil }
            // 正在回复则不抢跑（避免与主引擎争用）
            if AppState.shared.chatRuntimes[sessionID]?.isResponding == true { return nil }
            // 无新内容则跳过：已复盘条数持久化在会话模型上（重启后依然生效，
            // 避免「重新进入旧会话又复盘一次」的重复消耗）。
            if session.reviewedMessageCount >= messageCount { return nil }

            // 复盘属后台任务：固定走副模型端点（未配置副模型时回退主模型）。
            // 复盘模型不再可单独调整，直接反映「模型分组」里副模型的选择。
            guard let endpoint = AppState.shared.resolveBackgroundModelEndpoint() else { return nil }

            let history = Self.buildHistory(from: session)
            return ReviewInput(session: session, history: history, endpoint: endpoint, messageCount: messageCount)
        }

        guard let input else { return }

        // 构建受限 Agent（仅 memory_write / memory_get）
        let toolRouter = ToolRouter()
        toolRouter.register(MemoryWriteTool(bypassConfirmation: true))
        toolRouter.register(MemoryGetTool())

        let engine = AgentLoopEngine(toolRouter: toolRouter)
        engine.configure(routingPlan: ModelRoutingPlan(endpoints: [input.endpoint], usesModelGroups: false))
        // 使用独立的运行时 ID（不复用真实会话 sessionID），避免复盘引擎写出的检查点污染
        // `AgentTaskStore[真实sessionID]`，被 ChatView.recoverIfNeeded 误当作用户会话草稿而把后台消息渲染进对话框。
        engine.configure(sessionID: UUID(), streamingMessageID: nil)
        engine.isSubagentEngine = true
        engine.setSystemPrompt(stable: Self.reviewSystemPrompt, volatile: "")

        var summaryBuffer = ""
        engine.onToken = { piece in summaryBuffer += piece }
        engine.onTokenUsage = { _ in }   // 复盘用量不计入用户统计

        let instruction = """
        请按以下步骤完成：
        1. 先调用 memory_get 了解已有记忆，避免重复写入。
        2. 阅读上面的对话，按 system prompt 的「写入分级规则」沉淀记忆：
           - 仅长期价值内容写入 long_term：用户明确要求记住的事项、跨会话稳定的偏好/习惯/项目约定/技术决策、反复出现的行为模式、待跟进事项。
           - 单次搜索/浏览/查询、临时任务、当天问答、过程性进展，一律写入 daily，严禁写进 long_term。
           严禁把单次事件推断为用户长期画像（例如「今天搜了新闻」≠「用户长期关注新闻」；「今天查了一个报错」≠「常踩此坑」）。除非该主题在多次会话中反复出现。
           严禁写入密码、API Key、Token 等敏感信息。
        3. 最后单独输出一行，格式严格为：[SUMMARY] 一句话中文摘要本次会话的核心主题与进展。
        """

        await engine.run(userMessage: instruction, history: input.history)

        let summary = Self.parseSummary(from: summaryBuffer)
        await MainActor.run {
            input.session.summary = summary
            // 复盘进度持久化到会话模型：重启后不再对旧内容重复复盘。
            input.session.reviewedMessageCount = input.messageCount
            SessionManager.shared.persist(input.session)
        }
        AppLogger.shared.info("会话复盘完成（\(sessionID.uuidString.prefix(8))），摘要：\(summary.prefix(40))", category: "Memory")

        // 复盘刚往长期记忆追加过内容，顺势做一次条件式整理（受开关/冷却/体量阈值三重门禁）。
        MemoryConsolidator.shared.consolidateIfNeeded()
    }

    // MARK: - 辅助

    private static let reviewSystemPrompt = """
    你是 MiniClaw 的记忆沉淀助手。你只能通过 memory_write 写入记忆、通过 memory_get 检索记忆，不能使用其它任何工具。
    你的任务：阅读对话，把值得长期保留的内容写入记忆，并输出一句中文会话摘要。

    【写入分级规则 —— 必须严格遵守】
    - 只有以下情况才写入 long_term（MEMORY.md，跨会话长期保留）：
      1. 用户明确说「记住 / 记一下 / 以后都…」这类长期记忆指令；
      2. 跨会话仍稳定成立的用户偏好、习惯、工作流、项目约定、技术决策与理由；
      3. 反复出现的行为模式（多个会话都出现，而非单次）；
      4. 未完成的待跟进事项、长期任务清单。
    - 以下情况一律只写入 daily（当日过程性记忆，不进 long_term）：
      1. 单次搜索 / 浏览 / 查询的内容（新闻、资讯、价格、临时资料）；
      2. 当天的临时任务、问答、一次性的工具执行结果；
      3. 过程性进展播报、当天的待办；
      4. 用户随手看的内容——不得据此推断「用户长期偏好 X」。
    - 严禁把单次事件推断为用户长期画像。例如：用户今天搜了一条新闻 ≠ 用户「关注新闻」；
      用户今天查了一个报错 ≠ 用户「常踩这个坑」。除非该主题在多次会话中反复出现。
    - 严禁写入密码、API Key、Token 等敏感信息。
    - 不要输出与任务无关的解释。
    """

    /// 把会话消息转为引擎历史（取最近若干条，角色映射 user/assistant）。
    private static func buildHistory(from session: ChatSession, maxMessages: Int = 40) -> [ChatCompletionMessage] {
        let msgs = session.messages
            .filter { $0.role == .user || ($0.role == .assistant && !$0.content.isEmpty) }
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(maxMessages)
        return msgs.map { m in
            let role = m.role == .user ? "user" : "assistant"
            return ChatCompletionMessage(role: role, content: m.content)
        }
    }

    /// 从模型输出中解析 [SUMMARY] 后的摘要；模型未按格式输出时返回空串
    /// （不写污染——退化取末尾片段可能把记忆正文当摘要存进首页列表）。
    private static func parseSummary(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "[SUMMARY]") {
            let after = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { return String(after.prefix(300)) }
        }
        // 容错：某些模型可能输出「摘要：xxx」形式。
        if let range = trimmed.range(of: "摘要：") ?? trimmed.range(of: "摘要:") {
            let after = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { return String(after.prefix(300)) }
        }
        return ""
    }
}

/// 极简线程安全集合（复盘并发去重用）。
final class NSLockedSet<T: Hashable>: @unchecked Sendable {
    private var set = Set<T>()
    private let lock = NSLock()
    func insert(_ item: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if set.contains(item) { return false }
        set.insert(item); return true
    }
    func remove(_ item: T) {
        lock.lock(); defer { lock.unlock() }
        set.remove(item)
    }
}
