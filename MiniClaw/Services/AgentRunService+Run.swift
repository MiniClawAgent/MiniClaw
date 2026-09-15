import Foundation
import SwiftUI

/// AgentRunService 的回复启动 / 标题生成职责（2026-08 拆分：按职责分文件，语义不变）。
extension AgentRunService {

    /// 启动一轮完整回复（人工发送与无 UI 派发共用）。
    /// 前置（调用方负责）：路由解析、附件过滤与 hints 注入、userMessage 已落库。
    /// - Parameters:
    ///   - enrichedInput: 可能已含附件 hints 的用户输入
    ///   - allowedAttachments: 已按模态过滤的附件相对路径（"attachments/<name>"）
    /// - Returns: nil 表示会话未持久化（调用方回跳 x-error）。
    @discardableResult
    func startRun(
        session: ChatSession,
        enrichedInput: String,
        userMessageID: UUID,
        routingPlan: ModelRoutingPlan,
        allowedAttachments: [String],
        injectedSkill: String?,
        thinkingLevel: String?,
        deepLinkCallback: (xSuccess: URL?, xError: URL?)?,
        uiHooks: UIHooks?
    ) -> (engine: AgentLoopEngine, runtime: ChatSessionRuntime)? {
        guard SessionManager.shared.session(id: session.id) != nil else {
            // 会话未注册到 SessionManager（未走 createSession 创建）时 startRun 静默失败 →
            // 表现为"发送消息无 AI 回复"。危机日志便于第一时间定位此类路径违规。
            AppLogger.shared.crisisMark("startRun REJECTED: session \(session.id) not registered in SessionManager (createSession missing)")
            return nil
        }

        session.status = .running
        session.modelName = routingPlan.endpoints.first?.displayName ?? session.modelName

        // 丢弃可能残留的上一轮检查点，确保全新启动（避免从旧上下文恢复）。
        AgentTaskStore.shared.clear(sessionID: session.id)

        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        assistantMessage.session = session
        // 确保 createdAt 严格晚于用户消息，避免同毫秒导致 ForEach 排序错乱
        assistantMessage.createdAt = Date(timeIntervalSinceNow: 0.001)
        session.messages.append(assistantMessage)

        let (engine, runtime, toolRouter) = buildEngine(
            session: session,
            assistantMessage: assistantMessage,
            routingPlan: routingPlan,
            deepLinkCallback: deepLinkCallback,
            uiHooks: uiHooks
        )
        runtime.isResponding = true
        AppState.shared?.chatRuntimes[session.id] = runtime
        // 深链任务由本会话消费并成功启动（已创建运行时）：清除待派发任务。
        if let dlTask = AppState.shared?.pendingDeepLinkTask, dlTask.targetSessionID == session.id {
            AppState.shared?.pendingDeepLinkTask = nil
        }

        let builtHistory = buildHistory(session: session, userMessageID: userMessageID, responseMessageID: assistantMessage.id)

        let preparationTask = Task { @MainActor in
            await registerRemoteMCPTools(in: toolRouter, sessionID: session.id)
            guard !Task.isCancelled,
                  AppState.shared?.chatRuntimes[session.id] === runtime else { return }
            // MCP 动态工具注册完成后再冻结 system prompt 与本轮 tools schema。
            let (stable, volatile) = await buildSystemPromptCached(with: toolRouter, extraSkillName: injectedSkill, sessionID: session.id)
            engine.setSystemPrompt(stable: stable, volatile: volatile)
            engine.configure(sampling: samplingConfig())
            runtime.mcpPreparationTask = nil
            // [2026-09-15 缓存治本] 引擎把本轮易变段快照拼进 user 消息后回调这里，由本会话把它
            // （连同附件提示段）落盘成 `apiContextSuffix`，下一轮 `buildHistory` 逐字回放 ⇒
            // 请求序列保持「上一轮 + 尾巴」纯追加，前缀缓存可覆盖历史。
            // 引擎是这些字节的唯一生产者，这里只负责记录，不另行拼装。
            engine.onTurnAPISuffixComposed = { suffix in
                Task { @MainActor in
                    AgentRunService.shared.recordAPIContextSuffix(
                        session: session, userMessageID: userMessageID,
                        enrichedInput: enrichedInput, engineSuffix: suffix)
                }
            }
            // 把会话相对路径（"attachments/<name>"）解析为绝对路径再传给 Agent/工具。
            // message.attachments 存相对路径是为了持久化抗容器 UUID 变化，
            // 但工具层（iSH shell / VisionAnalyzer）需要绝对路径才能读取文件。
            let resolvedAttachments = allowedAttachments.map { path -> String in
                if (path as NSString).isAbsolutePath { return path }
                let sessionDir = SessionFileRouter.shared.sessionHostDirectory(for: session.id)
                return sessionDir.appendingPathComponent(path).path
            }
            // headless 派发信号：引擎即将开始 run（网络请求在途、agentDidStart 保活已续），
            // intent.perform 等待此信号后返回，避免「perform 已返回但引擎还没启动」的窗口。
            AppState.shared?.intentEngineStartedSessions.insert(session.id)
            AppLogger.shared.info(String(localized: "intent_engine_about_to_run"), category: "Intent")
            await engine.run(userMessage: enrichedInput, history: builtHistory.messages,
                             historySourceIDs: builtHistory.sourceIDs, attachments: resolvedAttachments,
                             forceThinkingLevel: thinkingLevel)
        }
        runtime.mcpPreparationTask = preparationTask
        return (engine, runtime)
    }

    // MARK: - 易变段快照落盘（2026-09-15 缓存治本）

    /// 把**引擎实际拼进本轮请求**的易变段后缀记录下来，落盘为 `ChatMessage.apiContextSuffix`。
    ///
    /// 不变量：发送正文（引擎拼的）与历史回放（`buildHistory` 读的）必须逐字节一致，
    /// 因此这里只做"记录 + 落盘"，**绝不另行拼装**后缀（两处各拼一次，只要差一字节就会
    /// 重新打断前缀缓存）。
    /// - 落盘的后缀 = [调用方注入的附件提示段] + [引擎给的易变段后缀]；附件提示虽是
    ///   `enrichedInput` 相对落盘 `content` 的增量，但为保持字节一致必须一起回放。
    /// - 易变段已不再挂到 system 的 `volatileSuffix`：那条路径把快照临时拼在请求末尾且不落盘，
    ///   使请求序列失去「上一轮 + 尾巴」的嵌套结构，前缀缓存只能命中静态前块。
    func recordAPIContextSuffix(
        session: ChatSession,
        userMessageID: UUID,
        enrichedInput: String,
        engineSuffix: String
    ) {
        guard let idx = session.messages.firstIndex(where: { $0.id == userMessageID }) else {
            // 不应发生（调用方前置要求 userMessage 已落库）：留下危机标记便于定位。
            AppLogger.shared.crisisMark("recordAPIContextSuffix: user message \(userMessageID) 未落库")
            return
        }
        let content = session.messages[idx].content
        var suffix = ""
        if enrichedInput.hasPrefix(content) {
            suffix = String(enrichedInput.dropFirst(content.count))
        } else {
            AppLogger.shared.warn(
                "[CacheSuffix] enrichedInput 不以落盘正文开头，附件提示段将不入后缀（本轮缓存退化）",
                category: "Cache", subsystem: "Context")
        }
        suffix += engineSuffix
        session.messages[idx].apiContextSuffix = suffix.isEmpty ? nil : suffix
        SessionManager.shared.persist(session)
    }

// MARK: - 智能体会话标题生成（2026-08-07 自 ChatView 迁入：UI 与 headless 共用）


    // MARK: - 智能体标题生成（后台）

    /// 首条消息后于后台异步用 LLM 精炼会话标题：不阻塞主对话，完成后若标题仍是本地占位
    /// （用户未手动改过）才回写；调用失败则保留占位标题，不影响正常使用。
    /// 首条用户消息后触发 智能体标题生成（UI 与 headless 派发共用）。
    /// 占位标题判定收敛：新会话 / 空 / 「深链任务」都视为占位（深链快捷指令创建
    /// 的会话同样参与自动命名，不再永远叫「深链任务」）。
    /// 「折叠上方」:生成锚点消息之前上下文的摘要(后台模型端点,失败返回 nil)。
    /// 会话可见结构不变,仅 API 上下文用摘要替代(配合 buildHistory 的锚点应用)。
    func generateCompactionSummary(session: ChatSession, anchorMessageID: UUID) async -> String? {
        guard AppState.shared?.hasConfiguredModel == true,
              let endpoint = AppState.shared?.resolveBackgroundModelEndpoint() else { return nil }
        let sorted = session.messages.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
        guard let idx = sorted.firstIndex(where: { $0.id == anchorMessageID }), idx > 0 else { return nil }
        var lines: [String] = []
        for m in sorted[..<idx] {
            if m.role == .user || (m.role == .assistant && !m.content.isEmpty) {
                lines.append("[\(m.role == .user ? "user" : "assistant")] " + m.content)
            }
        }
        guard !lines.isEmpty else { return nil }
        // 指令置于文本之后（compress_prompt_zh 现为「压缩上面的对话」语义，2026-08-31 统一）。
        let prompt = lines.joined(separator: "\n") + "\n\n" + String(localized: "compress_prompt_zh")
        let client = LLMClient(
            endpointURL: endpoint.url, apiKey: endpoint.apiKey, format: endpoint.format,
            usesAzureAPIKey: endpoint.usesAzureAPIKey, customHeaders: endpoint.customHeaders,
            providerType: endpoint.providerType
        )
        var summary = ""
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            _ = client.streamChat(
                model: endpoint.modelId,
                messages: [
                    ChatCompletionMessage(role: "system", content: String(localized: "compress_prompt")),
                    ChatCompletionMessage(role: "user", content: prompt)
                ],
                onToken: { summary += $0 },
                onToolCall: { _ in },
                onUsage: { _, _, _, _ in },
                onFinishReason: { _ in },
                onComplete: { _ in cont.resume() }
            )
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func generateAITitleIfNeeded(session: ChatSession, firstUserText: String) {
        let sessionSettings = SettingsStore.shared.settings.session
        let isPlaceholder = session.title == String(localized: "new_chat_title") || session.title.isEmpty || session.title == String(localized: "deep_link_task")
        guard sessionSettings.autoGenerateTitle, isPlaceholder,
              session.messages.filter({ $0.role == .user }).count == 1 else { return }
        let derived = firstUserText.replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
        let placeholder = String(derived.prefix(40))
        session.title = placeholder
        session.titleIsPlaceholder = true
        generateAITitleInBackground(session: session, firstUserText: firstUserText, placeholder: placeholder)
    }

    private func generateAITitleInBackground(session: ChatSession, firstUserText: String, placeholder: String) {
        // 标题/图标生成属后台任务：优先副模型端点，避免与主会话争抢并发/限流。
        guard AppState.shared?.hasConfiguredModel == true,
              let endpoint = AppState.shared?.resolveBackgroundModelEndpoint() else { return }

        let sessionID = session.id
        let systemPrompt = Self.titleGenerationSystemPrompt

        // 线程治理（2026-08-09）：网络请求 + 逐 token 累积移出主线程（Task.detached）；
        // 回主线程仅做一次 modelContext.save + Live Activity 回传（SwiftData 模型主线程隔离）。
        Task.detached(priority: .userInitiated) {
            let client = LLMClient(
                endpointURL: endpoint.url,
                apiKey: endpoint.apiKey,
                format: endpoint.format,
                usesAzureAPIKey: endpoint.usesAzureAPIKey,
                customHeaders: endpoint.customHeaders,
                providerType: endpoint.providerType
            )
            var accumulated = ""
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                _ = client.streamChat(
                    model: endpoint.modelId,
                    messages: [
                        ChatCompletionMessage(role: "system", content: systemPrompt),
                        ChatCompletionMessage(role: "user", content: firstUserText)
                    ],
                    onToken: { accumulated += $0 },
                    onToolCall: { _ in },
                    onUsage: { _, _, _, _ in },
                    onFinishReason: { _ in },
                    onComplete: { _ in continuation.resume() }
                )
            }
            let (polished, icon, iconColor) = Self.parseTitleIcon(accumulated)
            guard !polished.isEmpty, polished != placeholder else { return }
            await MainActor.run {
                // 用 ID 重新抓取避免依赖视图生命周期。
                guard let session = SessionManager.shared.session(id: sessionID) else { return }
                guard session.title == placeholder else { return }
                session.title = polished
                session.titleIsPlaceholder = false
                // 一并写入 智能体选定的图标（无效 symbol 名会在渲染层回退为默认图标）。
                // 配色：归一化 + 拒绝纯黑/纯白；非法或黑/白则不写入，渲染层按会话 ID 走「多样兜底色」而非单一蓝。
                if let icon, Self.isValidSFSymbol(icon) { session.icon = icon }
                if let iconColor, let clean = sanitizeSessionIconColor(iconColor) { session.iconColor = clean }
                session.updatedAt = Date()
                SessionManager.shared.persist(session)
                // 标题/图标/配色变更通知首页重载(2026-08-12 修复):成员对象原地改值不触发
                // 数组 willSet,必须手动发 objectWillChange,首页才会重读并重排(updatedAt 置顶)。
                SessionManager.shared.objectWillChange.send()
                // 标题/图标变更回传：运行中刷新 Live Activity 的会话标题与图标（否则锁屏/灵动岛一直显示旧值）。
                BackgroundTaskController.shared.agentDidUpdateSession(sessionID: sessionID.uuidString)
            }
        }
    }

    /// 终态兜底(2026-08-12 修复):终态回调(onComplete/onError/onInterrupted)的 guard 失败
    /// (runtime 已释放/被替换,如 /clear、Siri 取消等"丢弃运行时但不写终态"的路径)时,
    /// 若该会话已无其他存活引擎拥有,仍写回终态——否则 session.status 永久卡 .running,
    /// 首页图标(RotatingRing)转圈不停。有存活 runtime 时跳过(避免误杀新引擎的回调)。
    static func terminalFallback(session: ChatSession, sessionID: UUID, status: SessionStatus) {
        guard AppState.shared?.chatRuntimes[sessionID] == nil,
              session.status == .running || session.status == .retrying else { return }
        session.status = status
        session.updatedAt = Date()
        AgentTaskStore.shared.clear(sessionID: sessionID)
        SessionManager.shared.persist(session)
        AppLogger.shared.info("终态兜底:会话 \(sessionID) 无存活 runtime,status→\(status.rawValue)",
                              category: "Agent", subsystem: "Persist")
    }

    private static let titleGenerationSystemPrompt = """
    你是会话标题、图标与配色生成器。请根据用户的第一条消息，生成：
    1. 一句简短的中文会话标题（**不超过 10 个字**，提炼核心意图，不要原样照抄整句话；会话页标题栏空间有限，超长会被截断）;
    2. 一个能代表该会话主题的 SF Symbols 图标名称（仅用英文小写与点号）。请结合对话主题选取恰当的图形，并尽量让不同会话之间的图标彼此区分、风格多样——不要总是使用同一批固定图标，也不要照搬下面示例，需因地制宜。
       参考维度（仅举例，务必按主题变通）：
       - 写作 / 文档：pencil.line、book.fill、doc.text.fill
       - 技术 / 代码：cpu、terminal.fill、gear、wrench.and.screwdriver
       - 创意 / 设计：paintbrush.fill、lightbulb.fill、wand.and.stars
       - 生活 / 日常：cart、heart.fill、calendar、leaf
       - 数据 / 图表：chart.bar.fill、magnifyingglass、function
    3. 图标配色 iconColor：一个与会话主题 / 情绪相匹配、有辨识度且对比足够的颜色。除纯黑（#000000）与纯白（#FFFFFF）不可用（在深浅背景下会看不见）外，其他任何颜色都可以——红橙黄绿青蓝紫等鲜艳色系皆可，请尽量为每个会话选用不同的颜色，避免所有会话都长一个色。可输出十六进制（如 #FF6B6B）、rgb()（如 rgb(255,107,107)）或 hsl()（如 hsl(210,80%,60%)）任意形式。

    图标背景将自动取 iconColor 的 0.12 透明度，前景符号使用 iconColor 本身。
    只输出一个 JSON 对象，严格使用如下格式，不要输出任何其他文字、也不要使用代码围栏：
                    {"title":"\(String(localized: "title_gen_placeholder"))","icon":"sf_symbol_name","iconColor":"#FF6B6B"}
    """

    nonisolated private static func sanitizeTitle(_ raw: String) -> String {
        var t = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉可能的前导 "标题：" / "Title: " 等非标题内容
        if let range = t.range(of: "："), range.upperBound < t.endIndex {
            let after = String(t[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty, after.count < t.count { t = after }
        }
        // [2026-09-14 唐唐指定：提示词 8→10 字，硬兜底 8→12 字]
        // 两者的**刻意差值**：prompt 要 10 字，硬上限给到 12 字 —— 模型偶尔多写一两个字时
        // 不必立刻砍（砍在词中间会读不通），只有明显越界才截断。这是"模型不守 prompt 字数
        // 约束时的最终兜底"。
        // ⚠️ 原文写"与应用会话页标题栏防护（principalSafe）同口径"，但**全库已无 principalSafe**
        // （grep 仅命中这条注释本身）⇒ 那个耦合早已不存在，注释在此改正，避免后人按不存在的
        // 约束去调数字。真实情况：显示层对**正式标题**不做任何字数截断（只有占位标题会截断，
        // 见 `ChatView.headerTitle`）。
        if t.count > 12 { t = String(t.prefix(12)) }
        return t
    }

    /// 从 LLM 输出中解析「标题 + 图标 + 配色」。期望 JSON：
    /// `{"title":"...","icon":"...","iconColor":"#FF6B6B"}`。
    /// 若解析失败，title 回退到对原文做 sanitize，图标与配色返回 nil（保持默认）。
    nonisolated private static func parseTitleIcon(_ raw: String) -> (title: String, icon: String?, iconColor: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉模型偶尔附加的 ```json ... ``` 代码围栏
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let lastFence = text.lastIndex(of: "`") {
                text = String(text[..<lastFence])
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (Self.sanitizeTitle(raw), nil, nil)
        }
        let title = (obj["title"] as? String).map { Self.sanitizeTitle($0) } ?? Self.sanitizeTitle(raw)
        let icon = obj["icon"] as? String
        let iconColor = obj["iconColor"] as? String
        return (title, icon, iconColor)
    }

    /// 校验一个名字是否是真实存在的 SF Symbol（iOS 用 UIKit 精确判断；
    /// 无 UIKit 环境做宽松兜底，避免 macOS CLI 共享编译时崩溃）。
    nonisolated private static func isValidSFSymbol(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #else
        return !name.isEmpty && name.count <= 60 && !name.contains(" ")
        #endif
    }

}
