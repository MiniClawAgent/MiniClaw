import Foundation
import SwiftUI

/// Agent 运行服务层（2026-08-07 批次2：引擎管线服务化）。
///
/// 目标：让「消费深链/快捷指令任务 → 启动引擎」不依赖 ChatView（UI）也能执行——
/// 对齐参考实现的服务层派发，实现快捷指令 headless 后台运行。
///
/// 迁移节奏（每步构建验证）：
/// - Step A：工具路由 / 历史构建 / 附件过滤 / MCP 注册（本文件起步内容）
/// - Step B：system prompt 构建（buildSystemPrompt + 缓存）
/// - Step C：引擎装配（buildEngine 回调全量，UI 专属钩子走 uiHooks）
/// - Step D：startRun 主体（原 ChatView.startAgentResponse 服务层版）
///
/// 所有方法 @MainActor：与 ChatView 原实现同隔离域，行为不变。
@MainActor
final class AgentRunService {

    static let shared = AgentRunService()
    private init() {}

    /// UI 专属钩子（无 UI 后台执行时传 nil；ChatView 传 onContextUsage 驱动上下文圆环）。
    struct UIHooks {
        var onContextUsage: (ContextUsageSnapshot) -> Void
    }

    // MARK: - 工具路由（单一事实来源：主会话引擎 / 上下文估算共用）

    /// 装配本轮可用的 Agent 工具（与 ChatView 原 buildToolRouter 完全一致）。
    func buildToolRouter(sessionID: UUID) -> ToolRouter {
        let toolRouter = ToolRouter()
        // 4.1 Agent 原生工具
        toolRouter.register(FileReadTool(currentSessionID: sessionID))
        toolRouter.register(ListDirTool(currentSessionID: sessionID))
        toolRouter.register(FileWriteTool(currentSessionID: sessionID))
        toolRouter.register(FileEditTool(currentSessionID: sessionID))
        toolRouter.register(ReadImageTool(currentSessionID: sessionID))
        toolRouter.register(VisionAnalyzeTool(currentSessionID: sessionID))
        toolRouter.register(ReadDocumentTool(currentSessionID: sessionID))
        toolRouter.register(MemoryWriteTool())
        toolRouter.register(MemoryGetTool())
        toolRouter.register(ShellExecuteTool(currentSessionID: sessionID))
        toolRouter.register(BrowserTool(currentSessionID: sessionID))
        // 4.2 Apple 原生框架工具
        // 只注册已经接入的工具。尚未实现、执行时固定返回「尚未接入」的占位工具
        // 不能暴露给模型，否则模型可能在收到失败结果后重复调用，形成无限工具循环。
        toolRouter.register(AppleClipboardTool())
        toolRouter.register(AppleDeviceTool())
        toolRouter.register(AppleNLPTool())
        toolRouter.register(AppleNotificationTool())
        toolRouter.register(AppleOpenTool())
        toolRouter.register(SafariOpenTool())
        toolRouter.register(AppleSpeakTool())
        // 4.3 MiniClaw 基础设施工具
        toolRouter.register(ConfigTool())
        toolRouter.register(SessionsTool(currentSessionID: sessionID))
        toolRouter.register(MiniClawOpenTool(currentSessionID: sessionID))
        toolRouter.register(MiniClawModelUseTool())
        toolRouter.register(MiniClawBrowserUseTool(currentSessionID: sessionID))
        toolRouter.register(MiniClawDebugTool(currentSessionID: sessionID))
        // 4.4 渐进式技能加载工具（按需读入技能正文，避免每轮全量注入）
        toolRouter.register(SkillLoadTool(currentSessionID: sessionID))
        // 4.5 子代理结果分页读取（dispatch_subagent 只回有界预览，本工具读完整回答）
        toolRouter.register(ReadSubagentResultTool(currentSessionID: sessionID))
        return toolRouter
    }

    /// 发现已启用远端 MCP Server 的工具，并在本轮引擎开始前动态注册。
    /// 单个 Server 失败只更新其健康状态，不阻断本地工具和其他 MCP Server。
    func registerRemoteMCPTools(in toolRouter: ToolRouter, sessionID: UUID) async {
        let store = MCPConfigStore.shared
        let session = SessionManager.shared.session(id: sessionID)
        let disabled = session?.disabledMCPServerIDs ?? []
        let servers = store.servers.filter { $0.isEnabled && !disabled.contains($0.id) }
        // 并行发现（2026-08-07 效率优化）：MCP 服务器互不依赖，串行连接时首轮请求要等
        // 所有服务器耗时之和（最慢的拖累全部）；并行后等待时间 = 最慢单台。
        // 状态读取/写入仍在主线程（markConnecting/bearerToken/updateDiscovery 线程敏感），
        // TaskGroup 闭包只做网络发现。
        var snapshots: [(server: MCPServerConfig, token: String?)] = []
        for server in servers {
            store.markConnecting(id: server.id)
            snapshots.append((server, store.bearerToken(for: server.id)))
        }
        var results: [UUID: Result<[RemoteMCPTool], Error>] = [:]
        await withTaskGroup(of: (UUID, Result<[RemoteMCPTool], Error>).self) { group in
            for snapshot in snapshots {
                group.addTask {
                    do {
                        let tools = try await MCPToolDiscoveryCache.shared.tools(
                            for: snapshot.server,
                            bearerToken: snapshot.token
                        )
                        return (snapshot.server.id, .success(tools))
                    } catch {
                        return (snapshot.server.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                results[id] = result
            }
        }
        for server in servers {
            switch results[server.id] {
            case .success(let tools):
                tools.forEach(toolRouter.register)
                store.updateDiscovery(id: server.id, toolCount: tools.count, error: nil)
            case .failure(let error):
                store.updateDiscovery(id: server.id, toolCount: 0, error: error)
                AppLogger.shared.error(
                    String(format: L10n.l("agent_mcp_discover_failed"), server.name, error.localizedDescription),
                    category: "MCP"
                )
            case nil:
                break
            }
        }
    }

    // MARK: - 会话历史

    /// 从会话历史构建发送给模型的 `history`（排除当前轮 user / 本轮 assistant 气泡，
    /// 且过滤掉 tool 角色消息——工具配对存在于引擎的检查点，不在此重建）。
    /// 返回 history 消息及与之一一对应的 session 消息 id（供引擎自动压缩时定位锚点）。
    func buildHistory(session: ChatSession, userMessageID: UUID, responseMessageID: UUID)
        -> (messages: [ChatCompletionMessage], sourceIDs: [UUID]) {
        let maxHistoryMessages = SettingsStore.shared.settings.session.maxContextMessages
        let sorted = session.messages
            .filter { $0.id != userMessageID && $0.id != responseMessageID }
            .filter { $0.role == .user || ($0.role == .assistant && !$0.content.isEmpty) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt < $1.createdAt
            }
        // 2026-08-13「折叠上方」:锚点之上的历史已压缩为摘要——锚点之前消息丢弃,
        // 摘要作为 system 消息置于 history 首位(会话可见结构不变,仅 API 上下文变化)。
        var effective = Array(sorted)
        var prefixSummary: String? = nil
        if let anchorID = session.compactAnchorID,
           let summary = session.compactSummary, !summary.isEmpty,
           let idx = effective.firstIndex(where: { $0.id == anchorID }) {
            prefixSummary = summary
            effective = Array(effective[idx...])
        }
        let historyMessages = effective.suffix(maxHistoryMessages)
        var history: [ChatCompletionMessage] = []
        if let summary = prefixSummary {
            history.append(ChatCompletionMessage(role: "system", content: L10n.l("history_summary_header") + summary))
        }
        for m in historyMessages {
            let role = m.role == .user ? "user" : "assistant"
            var content = m.content
            // 被用户中途打断/停止、或出错的回复：明确标注其不完整且已终止，
            // 避免模型把历史里半截的 assistant 内容当成「需要续写」的对象，
            // 从而略过用户最新消息（如强制发送的队列消息2）继续补全消息1。
            // 软暂停→继续的回复不会被打此标记（onPaused 不置 wasStopped/wasInterrupted），故不受影响。
            if m.role == .assistant, m.wasStopped == true || m.wasInterrupted {
                content += L10n.l("sys_interrupted_reply_hint")
            }
            // 2026-08-12 修复:思考内容不回灌上下文(与 ChatMessage 纪律注释一致)。
            // 历史 assistant 消息只取 content;当前轮内模型需要的 reasoning_content
            // 由 AgentLoopEngine 在 loop 内实时回传(DeepSeek 带 tools 请求要求),
            // 跨轮历史不回灌——避免历史思考文本持续占用 token 并影响后续输出。
            history.append(ChatCompletionMessage(role: role, content: content))
        }
        return (messages: history, sourceIDs: historyMessages.map(\.id))
    }

    // MARK: - 附件过滤

    /// 按端点输入模态能力过滤附件路径：不支持的模态直接剔除，返回被剔除的文件名。
    /// 纯文本模型（四个输入模态全关）会剔除全部附件——附件仍随消息气泡展示，
    /// 但不会编码进请求体，避免服务端 4xx 或静默截断。
    /// 返回三元组：(允许的路径列表, 被剔除的文件名列表, 被剔除的完整路径列表)
    static func filterAttachments(
        _ paths: [String],
        endpoint: ModelRouteEndpoint
    ) -> (allowed: [String], droppedNames: [String], droppedPaths: [String]) {
        guard !paths.isEmpty else { return ([], [], []) }
        var allowed: [String] = []
        var droppedNames: [String] = []
        var droppedPaths: [String] = []
        for path in paths {
            let kind = AttachmentKind.from(ext: (path as NSString).pathExtension)
            let supported: Bool
            switch kind {
            case .image:    supported = endpoint.supportsImageInput
            // 文档不再作为独立输入模态：统一经 read_document 工具读取，不入原生请求体。
            case .document: supported = false
            case .audio:    supported = endpoint.supportsAudioInput
            case .video:    supported = endpoint.supportsVideoInput
            }
            if supported {
                allowed.append(path)
            } else {
                droppedNames.append((path as NSString).lastPathComponent)
                droppedPaths.append(path)
            }
        }
        return (allowed, droppedNames, droppedPaths)
    }

// MARK: - 引擎装配（Step B：自 ChatView.buildEngine 迁入，服务层无 UI 亦可装配）

    /// 装配一个全新的 `AgentLoopEngine` + `ChatSessionRuntime`，并接好全部回调（服务层版，UI 钩子经 uiHooks）。
    /// 启动（全新回复）与恢复（冷启动重放开检查点）共用。
    func buildEngine(session: ChatSession, assistantMessage: ChatMessage, routingPlan: ModelRoutingPlan, deepLinkCallback: (xSuccess: URL?, xError: URL?)? = nil, uiHooks: UIHooks? = nil) -> (AgentLoopEngine, ChatSessionRuntime, ToolRouter) {
        let toolRouter = AgentRunService.shared.buildToolRouter(sessionID: session.id)
        let engine = AgentLoopEngine(toolRouter: toolRouter)
        engine.configure(routingPlan: routingPlan)
        // P1-3：子代理委派模型池。未配置「子代理模型」槽位时为 nil，子引擎沿用主路由（旧行为）。
        engine.configure(subagentRoutingPlan: AppState.shared.resolveSubagentRoutingPlan())
        // 绑定任务身份（检查点落盘 key + 续写气泡 ID）
        engine.configure(sessionID: session.id, streamingMessageID: assistantMessage.id)

        // 会话级运行时：登记到 AppState，让引擎与流式缓冲区脱离 ChatView 的生命周期。
        // 回调统一写入 runtime（引用类型，跨视图重建存活）+ 实时落盘到 assistantMessage，
        // 因此返回首页再回来时新建的 ChatView 能直接认领它、继续刷新并保留停止能力。
        // 回调对 runtime 用弱引用避免 runtime↔engine↔closure 循环；appState 在终态时移除
        // runtime，此前始终强持有它，保证完成/出错回调仍能正常触发。
        let runtime = ChatSessionRuntime(sessionID: session.id, engine: engine)
        runtime.streamingMessageID = assistantMessage.id
        // 任务总耗时：用户发送消息即开始计时（段起点；暂停/重试会暂停它）。
        runtime.taskStartOrResume()

        let responseMessageID = assistantMessage.id
        let sessionID = session.id

        engine.onToken = { [weak runtime] token in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else { return }
                // 成功收到首个输出 词元 = 重试已成功：移除重试指示器。
                if runtime.retryState != nil {
                    runtime.retryState = nil
                    // 重试期间不计时，恢复输出即继续计时。
                    runtime.taskStartOrResume()
                }
                // 画中画启动时机(用户定 2026-08-08):AI 第一步行动(思考/回复)即开启,无需退后台。
                // ensure 幂等:开关未开/无运行任务/已显示时自动跳过。
                TaskPipController.shared.ensurePipIfRunning()
                // PiP 悬浮窗实时进度：显示「生成中: 已生成文本前缀」(节流在 TaskPipController 内)
                let preview = String(runtime.streamingContent.prefix(30))
                TaskPipController.shared.updateProgress(
                    sessionID: sessionID.uuidString,
                    text: preview.isEmpty ? L10n.l("generating_ellipsis") : String(format: L10n.l("generating_format"), preview)
                )
                // 节流：词元 先入缓冲，由 ~100ms 定时器批量刷入 streamingContent（约 10fps），
                // 不再每 token 触发整页重绘；也不再每 令牌 写持久化对象（统一在终态落盘，见 onComplete 等）。
                runtime.bufferToken(token)
            }
        }
        engine.onReasoning = { [weak runtime] piece, iteration in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else { return }
                // 重试成功后可能先出思考/工具调用（无文本 词元）→ 同样视为已恢复,清除指示器。
                if runtime.retryState != nil {
                    runtime.retryState = nil
                    runtime.taskStartOrResume()
                }
                // 画中画启动时机(用户定 2026-08-08):AI 第一步行动(思考/回复)即开启
                TaskPipController.shared.ensurePipIfRunning()
                // PiP 悬浮窗实时进度：深度思考阶段
                TaskPipController.shared.updateProgress(sessionID: sessionID.uuidString, text: L10n.l("deep_thinking_ellipsis"))
                // 空/纯空白思考不产生垃圾段（多步 agent 循环里模型可能发空 reasoning_content 事件）。
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                // 节流：reasoning 词元 先入缓冲，由 ~100ms 定时器批量刷入 streamingReasoningSegments（约 10fps），
                // 不再每 词元 触发整段重绘 + 全量重解析 Markdown；也不再每 令牌 写持久化对象
                // （统一在终态落盘，见 onComplete/onError/onInterrupted/onPaused），消除展开态卡顿。
                runtime.bufferReasoningToken(piece, iteration: iteration)
            }
        }
        engine.onContextUsage = { snapshot in
            MainActor.assumeIsolated {
                // 与引擎压缩判定严格同源的上下文占用快照（含窗口、阈值、明细、真值标记）：
                // 圆环走到刻度线变红那一刻 == 引擎判定 shouldCompact、将压缩历史。
                uiHooks?.onContextUsage(snapshot)
            }
        }
        engine.onTokenUsage = { report in
            // emitTokenUsage 已确保在主线程投递；直接落盘统计（全局 + 会话级）。
            TokenUsageTracker.record(
                modelId: report.modelId,
                input: report.input,
                output: report.output,
                cachedRead: report.cachedRead,
                cachedWrite: report.cachedWrite
            )
            TokenUsageTracker.recordSession(
                sessionID: session.id,
                modelId: report.modelId,
                input: report.input,
                output: report.output,
                cachedRead: report.cachedRead,
                cachedWrite: report.cachedWrite,
                agentLoops: report.agentLoops,
                outputDurationMs: report.outputDurationMs
            )
            // 上下文圆环占比由 engine.onContextUsage 单独驱动（与压缩判定同源），
            // 圆环已不再展示缓存数字，此处只做用量统计落盘。
        }
        engine.onRouteChange = { [session, weak runtime] modelName in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else { return }
                session.modelName = modelName
            }
        }
        engine.onToolCall = { [weak runtime] name, callID, args, startedAt in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else { return }
                // 重试成功后首个输出是工具调用（无文本 词元）→ 同样视为已恢复,清除指示器。
                if runtime.retryState != nil {
                    runtime.retryState = nil
                    runtime.taskStartOrResume()
                }
                let argsStr: String
                if let data = try? JSONSerialization.data(withJSONObject: args, options: .prettyPrinted),
                   let str = String(data: data, encoding: .utf8) {
                    argsStr = str
                } else {
                    argsStr = "\(args)"
                }
                let pos = runtime.streamingContent.count
                let order = runtime.nextTimelineOrder
                runtime.nextTimelineOrder += 1
                runtime.streamingToolCalls.append(
                    ToolCallEvent(
                        name: name,
                        callID: callID,
                        arguments: argsStr,
                        timestamp: startedAt,
                        position: pos,
                        timelineOrder: order
                    )
                )
            }
        }
        engine.onToolResult = { [weak runtime] name, callID, result, duration in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else { return }
                // 按模型调用 id 精确配对（源头修复 2026-08-08）：并发同名工具（如多个 browser）
                // 若按 name+空槽匹配，先完成的结果会填进「最后一个空槽」导致结果串台。
                if let idx = runtime.streamingToolCalls.firstIndex(where: { $0.callID == callID }) {
                    runtime.streamingToolCalls[idx].resultText = result.text
                    runtime.streamingToolCalls[idx].success = result.success
                    runtime.streamingToolCalls[idx].duration = duration
                }
            }
        }
        engine.onComplete = { [weak engine, session, assistantMessage, weak runtime] in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else {
                    // 终态兜底(2026-08-12 修复)：guard 失败(runtime 已释放/被替换,如 /clear、
                    // Siri 取消等"丢弃运行时但不写终态"的路径)时,若该会话已无其他存活引擎,
                    // 仍写回终态——否则 status 永久卡 .running,首页图标转圈不停。
                    Self.terminalFallback(session: session, sessionID: sessionID, status: .completed)
                    return
                }
                // 兜底：整轮完成时清除残留的重试指示器（正常完成路径不应再显示）。
                runtime.retryState = nil
                // 所有流事件由 engine 串行同步投递到 MainActor，完成事件不会越过尾 token。
                // 先提交节流缓冲，确保最后 <100ms 的尾包不丢，再统一落盘最终正文。
                runtime.commitStreamBuffer()
                runtime.commitReasoningBuffer()
                assistantMessage.content = runtime.streamingContent
                // 任务总耗时：最终回复落盘时结算（含暂停/重试排除后的净时长）。
                if !runtime.taskTimingInvalid, assistantMessage.taskElapsedSeconds == nil {
                    assistantMessage.taskElapsedSeconds = runtime.taskSettle()
                }
                // 最终轮答复文本（区别于 content 拼接全文）：首页列表摘要优先用它。
                if let finalText = engine?.finalReplyText, !finalText.isEmpty {
                    assistantMessage.previewText = finalText
                }
                assistantMessage.reasoningSegments = runtime.streamingReasoningSegments
                assistantMessage.reasoning = runtime.streamingReasoningSegments.map { $0.text }.joined(separator: "\n\n")
                assistantMessage.isStreaming = false
                if !runtime.streamingToolCalls.isEmpty {
                    assistantMessage.toolCalls = runtime.streamingToolCalls
                }
                session.status = .completed
                session.updatedAt = Date()
                runtime.isResponding = false
                runtime.isPaused = false
                AppLogger.shared.info(String(format: L10n.l("agent_persist_oncomplete"), assistantMessage.content.count, assistantMessage.toolCalls.count, assistantMessage.reasoningSegments.count, assistantMessage.taskElapsedSeconds ?? -1), category: "Agent", subsystem: "Persist")
                AppState.shared?.chatRuntimes[sessionID] = nil
                // P1-4 升级：整轮 Agent 跑完（成功）后才回跳 x-success，并把回复文本交给等待中的快捷指令。
                if let cb = deepLinkCallback { AppState.shared?.fireDeepLinkSuccess(cb.xSuccess, replyText: assistantMessage.content) }
                // 终态清检查点（2026-08-08 修复）：任务结束即不再保留 .running 检查点，
                // 否则回会话页 recoverIfNeeded 误判为「中断续跑」→ 重建空 runtime 遮蔽落盘数据 + 引擎误重跑。
                AgentTaskStore.shared.clear(sessionID: session.id)
                // 方案A：终态落盘，进程被杀后回复文本/状态不丢，消除「空气泡」隐患。
                SessionManager.shared.persist(session)
                // iOS 27+ LongRunningIntent 官方路径：performBackgroundTask 轮询此信号作为「完成上报」。
                AppState.shared?.markIntentEngineFinished(sessionID: sessionID, result: .success(assistantMessage.content))
            }
        }
        engine.onRetryState = { [weak runtime] state in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else { return }
                switch state.phase {
                case .retrying:
                    // 重试不算任务耗时：暂停计时，恢复输出时继续。
                    runtime.taskPause()
                    // 丢弃半截输出，重新完整生成：清空已显示内容与上下文占位。
                    runtime.pendingText = ""
                    runtime.streamingContent = ""
                    runtime.streamingToolCalls = []
                    runtime.streamingReasoningSegments = []
                    runtime.nextTimelineOrder = 1
                    assistantMessage.content = ""
                    assistantMessage.reasoning = ""
                    assistantMessage.reasoningSegments = []
                    assistantMessage.toolCalls = []
                    // 显示重试指示器（计数/可展开错误信息/手动重试按钮）
                    runtime.retryState = state
                case .exhausted:
                    // 次数耗尽：指示器转为最终失败态（保留错误详情，不再自动重试）。
                    runtime.retryState = state
                }
            }
        }
        engine.onError = { [session, assistantMessage, weak runtime] error in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else {
                    Self.terminalFallback(session: session, sessionID: sessionID, status: .error)
                    return
                }
                runtime.commitStreamBuffer()
                runtime.commitReasoningBuffer()
                // 重试耗尽（统一重试机制）：onError 紧随 exhausted 状态在同一 runloop 触发并
                // 移除 runtime → 指示器消失，错误信息必须由文本承载，确保用户可见最终错误。
                runtime.streamingContent += String(format: L10n.l("n_n_request_failed"), error.localizedDescription)
                assistantMessage.content = runtime.streamingContent
                AppLogger.shared.info(String(format: L10n.l("agent_persist_onerror"), assistantMessage.content.count, assistantMessage.toolCalls.count, assistantMessage.reasoningSegments.count), category: "Agent", subsystem: "Persist")
                // 失败也是终态：结算耗时（if nil 防用户停止路径已结算）。
                if !runtime.taskTimingInvalid, assistantMessage.taskElapsedSeconds == nil {
                    assistantMessage.taskElapsedSeconds = runtime.taskSettle()
                }
                assistantMessage.reasoningSegments = runtime.streamingReasoningSegments
                assistantMessage.reasoning = runtime.streamingReasoningSegments.map { $0.text }.joined(separator: "\n\n")
                assistantMessage.isStreaming = false
                assistantMessage.wasInterrupted = true
                if !runtime.streamingToolCalls.isEmpty {
                    assistantMessage.toolCalls = runtime.streamingToolCalls
                }
                session.status = .error
                session.updatedAt = Date()
                runtime.isResponding = false
                runtime.isPaused = false
                AppState.shared?.chatRuntimes[sessionID] = nil
                // P1-4 升级：整轮 Agent 出错后才回跳 x-error。
                if let cb = deepLinkCallback { AppState.shared?.fireDeepLinkError(cb.xError) }
                // 终态清检查点（与 onComplete 一致，见其注释）。
                AgentTaskStore.shared.clear(sessionID: session.id)
                // 方案A：出错终态同样落盘。
                SessionManager.shared.persist(session)
                AppState.shared?.markIntentEngineFinished(sessionID: sessionID, result: .failure(AppState.DeepLinkAgentError.failed))
            }
        }
        // 软暂停在安全点落地后触发：把运行时标记为「已暂停」并保留（不移除），
        // 输入栏据此从「暂停」切到「继续」，用户点继续时调用 resumeGeneration() 重放检查点。
        engine.onPaused = { [session, assistantMessage, weak runtime] in
            MainActor.assumeIsolated {
                runtime?.taskPause() // 暂停期间不计任务耗时，继续时 resume 恢复计时
                runtime?.commitStreamBuffer()
                runtime?.commitReasoningBuffer()
                // 暂停即落盘一次当前已产出内容，保证被杀后台/崩溃后可从 message.content / reasoning 恢复。
                if let rt = runtime {
                    assistantMessage.content = rt.streamingContent
                    assistantMessage.reasoningSegments = rt.streamingReasoningSegments
                    assistantMessage.reasoning = rt.streamingReasoningSegments.map { $0.text }.joined(separator: "\n\n")
                    // 2026-08-12 治本:暂停必须与终态一样补全消息——工具调用一并落盘,
                    // 否则重启后"暂停前的工具使用"全部丢失。
                    assistantMessage.toolCalls = rt.streamingToolCalls
                }
                assistantMessage.isStreaming = false
                // 2026-08-12 治本:消息级暂停标志落盘,重启后指示器据此恢复。
                assistantMessage.isPaused = true
                runtime?.isPaused = true
                runtime?.isResponding = false
                // 2026-08-12 治本:暂停如实写 status(.paused),首页行(@ObservedObject 订阅)
                // 立即停止转圈,不再依赖 reload 时序;@Published statusRaw 自动驱动刷新。
                session.status = .paused
                session.updatedAt = Date()
                // 暂停落盘必须同步完成——异步写会被"暂停后立刻退出 App"丢掉,
                // 导致重启后只剩用户消息(2026-08-12 治本,同步变体与 AgentTaskStore 一致)。
                SessionManager.shared.persistSynchronously(session)
            }
        }
        // 中断（无有效内容）：网络失败 / 工具熔断 / 无效工具连续失败等，明确标记为「已中断」，
        // 不再误标为「已完成」，让用户在气泡底部看到明确的失败状态。
        // 子代理生命周期事件：写入会话级 SubagentStore（头像常驻、对话跨轮次保留）。
        // 轻量头像卡片只在此处启动/出错时变化，流式 词元 只写 SubagentConversation，
        // 因此主聊天页不会因子代理流式输出而重绘（防卡顿）。
        engine.onSubagentEvent = { event in
            MainActor.assumeIsolated {
                let sid = session.id
                switch event {
                case .started(let info):
                    SubagentStore.shared.startSubagent(sessionID: sid, info: info)
                case .taskAdded(let info, let task):
                    SubagentStore.shared.addTask(sessionID: sid, info: info, task: task)
                case .token(let info, let piece):
                    SubagentStore.shared.appendToken(sessionID: sid, info: info, piece: piece)
                case .toolCall(let info, let event):
                    SubagentStore.shared.appendToolCall(sessionID: sid, info: info, event: event)
                case .toolResult(let info, let name, let callID, let resultText, let success, let duration):
                    SubagentStore.shared.appendToolResult(sessionID: sid, info: info, callID: callID, name: name, resultText: resultText, success: success, duration: duration)
                case .reasoning(let info, let text, let index, let order):
                    SubagentStore.shared.appendReasoning(sessionID: sid, info: info, text: text, index: index, timelineOrder: order)
                case .error(let info, let desc):
                    SubagentStore.shared.markError(sessionID: sid, info: info, desc: desc)
                case .cancelled(let info):
                    // 取消/中断终态：卡片与详情置「已取消」（P3）。
                    SubagentStore.shared.markCancelled(sessionID: sid, subagentID: info.id)
                case .finished(let info):
                    // 保留头像与对话不移除：子代理完成后头像持续可见，用户可随时回看。
                    SubagentStore.shared.finishSubagent(sessionID: sid, info: info)
                }
            }
        }
        engine.onInterrupted = { [session, assistantMessage, weak runtime] in
            MainActor.assumeIsolated {
                guard let runtime, runtime.streamingMessageID == responseMessageID else {
                    Self.terminalFallback(session: session, sessionID: sessionID, status: .error)
                    return
                }
                runtime.commitStreamBuffer()
                runtime.commitReasoningBuffer()
                assistantMessage.content = runtime.streamingContent
                // 中断也是终态：结算耗时（用户停止路径可能已结算）。
                if !runtime.taskTimingInvalid, assistantMessage.taskElapsedSeconds == nil {
                    assistantMessage.taskElapsedSeconds = runtime.taskSettle()
                }
                AppLogger.shared.info(String(format: L10n.l("agent_persist_oninterrupted"), assistantMessage.content.count, assistantMessage.toolCalls.count, assistantMessage.reasoningSegments.count), category: "Agent", subsystem: "Persist")
                assistantMessage.reasoningSegments = runtime.streamingReasoningSegments
                assistantMessage.reasoning = runtime.streamingReasoningSegments.map { $0.text }.joined(separator: "\n\n")
                assistantMessage.isStreaming = false
                assistantMessage.wasInterrupted = true
                if !runtime.streamingToolCalls.isEmpty {
                    assistantMessage.toolCalls = runtime.streamingToolCalls
                }
                session.status = .error
                session.updatedAt = Date()
                runtime.isResponding = false
                runtime.isPaused = false
                AppState.shared?.chatRuntimes[sessionID] = nil
                // P1-4 升级：整轮 Agent 被中断（无有效内容 / 工具熔断等）后回跳 x-error。
                if let cb = deepLinkCallback { AppState.shared?.fireDeepLinkError(cb.xError) }
                // 终态清检查点（与 onComplete 一致，见其注释）。
                AgentTaskStore.shared.clear(sessionID: session.id)
                // 方案A：中断终态落盘，保证半截回复（若有）也被持久化。
                SessionManager.shared.persist(session)
                AppState.shared?.drainPendingQueueIfNeeded(sessionID: sessionID)
                AppState.shared?.markIntentEngineFinished(sessionID: sessionID, result: .failure(AppState.DeepLinkAgentError.failed))
            }
        }
        return (engine, runtime, toolRouter)
    }

// MARK: - System Prompt（Step C：自 ChatView 迁入，服务层无 UI 亦可构建）

    /// 后台队列异步读取文本文件，避免主线程同步 IO 卡顿。
    /// 对齐原则：重 IO 一律 async 化——`withCheckedContinuation` 把阻塞的
    /// `String(contentsOf:)` 卸载到全局队列，主线程在 `await` 期间完全让出。
    func readText(_ url: URL) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: try? String(contentsOf: url, encoding: .utf8))
            }
        }
    }

    /// 会话级 system stable 快照：首轮构建一次并缓存；同会话后续轮次（恢复/重试）复用 stable，
    /// volatile（时间戳/挂载列表）每轮重生成。
    /// 目的：会话中记忆变化（agent 用 memory_write 写记忆 / 退出会话后的记忆总结）不会改写
    /// 本会话的 system 前缀 → 各家提示词缓存（Anthropic 断点 / DeepSeek 自动前缀）不被破坏。
    /// extraSkillName 非 nil（技能注入）时强制重建（技能内容进入 stable）。
    /// 服务层持有缓存（原 ChatView @State 迁入）：类实例跨调用存活，UI 重建不丢缓存。
    /// stable prompt 按会话缓存（2026-08-07 字典化：原单槽在多引擎并发——
    /// 主会话/子代理/复盘引擎——互相覆盖，缓存命中率下降导致每轮重复构建）。
    /// 上限 20 个会话，超出删最旧（字典无序，用首元素近似淘汰，量小无碍）。
    private var stablePromptCache: [UUID: String] = [:]

    func buildSystemPromptCached(with toolRouter: ToolRouter, extraSkillName: String? = nil, sessionID: UUID) async -> (stable: String, volatile: String) {
        if extraSkillName == nil, let stable = stablePromptCache[sessionID] {
            let (_, volatile) = await buildSystemPrompt(with: toolRouter, sessionID: sessionID)
            return (stable, volatile)
        }
        let built = await buildSystemPrompt(with: toolRouter, extraSkillName: extraSkillName, sessionID: sessionID)
        // 技能注入轮(extraSkillName 非 nil)不写缓存:「本轮强制使用」的技能是一次性注入,
        // 固化进缓存会让技能指令泄漏到会话后续所有轮次(用户无感知的行为回归)。
        if extraSkillName == nil {
            if stablePromptCache.count >= 20, let first = stablePromptCache.keys.first {
                stablePromptCache.removeValue(forKey: first)
            }
            stablePromptCache[sessionID] = built.stable
        }
        return built
    }

}
