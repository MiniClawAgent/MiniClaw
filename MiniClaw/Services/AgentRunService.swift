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
    private func readText(_ url: URL) async -> String? {
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

    func buildSystemPrompt(with toolRouter: ToolRouter, extraSkillName: String? = nil, sessionID: UUID) async -> (stable: String, volatile: String) {
        // 危机标记而非普通 info：本函数曾是主线程同步 IO 的重灾区，
        // 一旦再次卡死，看门狗报告首屏能直接指出「最后执行点：PROMPT BUILD ENTER」。
        AppLogger.shared.crisisMark("PROMPT BUILD ENTER")
        defer { AppLogger.shared.crisisMark("PROMPT BUILD DONE") }
        let fs = FileSystemManager.shared
        // bundle 规则/技能/角色样例同步已移后台(线程治理 P0)：
        // 首轮 prompt 构建前等同步完成，避免读到空/旧版规则目录。
        await fs.waitForBundledSync()
        var stableParts: [String] = []      // 稳定段：置于前缀，进入 KV 缓存
        var volatileParts: [String] = []    // 易变段：置于末尾，不参与前缀匹配

        // 1. 人格定义（SOUL.md 全部内容，保证在灵魂里修改后能完全生效）；异步读，不阻塞主线程。
        if let raw = await readText(fs.memoryDir.appendingPathComponent("SOUL.md")),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stableParts.append(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 2. 项目规则（递归扫描 rules/*.md）；逐文件异步读取，避免主线程同步 IO。
        let ruleURLs = fs.ruleMarkdownFiles()
        var ruleSections: [String] = []
        for fileURL in ruleURLs {
            guard let raw = await readText(fileURL),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let relativePath = fileURL.path.replacingOccurrences(
                of: fs.rulesDir.path + "/",
                with: ""
            )
            ruleSections.append(String(format: L10n.l("agent_rules_file_inject"), relativePath, raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if !ruleSections.isEmpty {
            stableParts.append(L10n.l("project_rules_header") + ruleSections.joined(separator: "\n\n"))
        }

        // 2.5 已启用技能（渐进式加载：仅常驻 name + description 元数据；正文由 skill_load 工具按需加载）
        let skillMeta = await SkillManager.shared.enabledSkillMetadata()
        if !skillMeta.isEmpty {
            stableParts.append(L10n.l("enabled_skills_header") + skillMeta + L10n.l("skills_hint_load"))
        }

        // 2.6 本次一次性强制使用的技能（/技能名 触发）：无论该技能是否启用，都临时注入其正文，
        // 让 智能体在本轮直接按该技能执行。注意：放在「已启用技能」之后，优先级更高。
        if let name = extraSkillName, let body = await SkillManager.shared.skillBody(named: name),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stableParts.append("""
            ## 本轮强制使用的技能：\(name)
            下面是用户通过「/\(name)」指令要求本轮必须使用的技能正文。请严格遵循其指令完成本次任务，\
            并在需要时引用同目录下的 references/、scripts/、assets/ 等。
            \(body)
            """)
        }

        // 3. 工具能力描述
        stableParts.append("""
        ## 工具系统
        你有完整的工具系统，包括文件读写、浏览器、Apple 原生框架（日历/提醒/剪贴板/设备信息/语音/NLP等）、配置管理、会话管理等。每个工具都有明确的 name 和 parameters schema，在需要时直接调用。

        ⚠️ **工具调用铁律（必须遵守）：**
        - 你**只能**调用「可用工具」列表中明确列出的工具名（见下方 ## 可用工具），绝对禁止编造、猜测或使用列表中不存在的任何工具名。
        - 如果需要的功能不在已有工具范围内，用文字回答用户并说明限制，不要尝试调用不存在的工具。
        - 每次调用前必须核对工具名是否在列表中。常见错误示例：不要调用 `查询今日科技新闻` / `web_search` / `联网搜索` 等不存在的工具——这些都不在你的工具列表中。

        执行约束：
        - 所有文件路径必须是 `/var/MiniClaw/...` 绝对路径；拒绝目录穿越和二进制文本读取
        - 创建/覆写文件用 `file_write`；修改已有文件用 `file_edit`
        - 也可用 shell 命令（echo / heredoc / printf 重定向）写文件；含转义字符或多行内容建议优先用 `file_write` 以避免 BusyBox ash 转义差异
        - Agent 可写 attachments/workspace/shared/skills；offloads 仅 shell 自动写，browser 仅浏览器自动写
        - rules（含 rules/GLOBAL.md）为 App 托管的只读规则目录；memory/MEMORY.md 与每日记忆可由 memory_write 读写；SOUL.md 仅 Settings 可写；mounts 对 Agent 只读
        - 工具调用超时 120 秒
        - 最多 50 轮工具循环，防止无限循环
        """)

        // 4. 文件系统布局
        stableParts.append("""
        ## 文件系统（/var/MiniClaw/）
        ```
        /var/MiniClaw/
        ├── attachments/    图片/音频/视频附件 (png/jpg/gif/webp/mp3/m4a/wav/mp4/mov/m4v)
        ├── workspace/      临时工作区
        ├── shared/         共享数据
        ├── offloads/       大文件转存 (shell_execute 输出超阈值时)
        ├── browser/        浏览器截图 (screenshot_<ts>.jpg)
        ├── memory/         记忆系统
        │   ├── SOUL.md     人设定义
        │   ├── MEMORY.md   长期记忆（用户与 AI 可读写）
        │   └── YYYY-MM-DD.md  每日记忆
        ├── rules/          自动注入的项目规则 (Markdown，App 托管只读)
        │   └── GLOBAL.md   全局规则
        ├── skills/         技能（技能格式 格式：每个技能一个子目录，含 SKILL.md）
        │   └── <skill-name>/
        │       ├── SKILL.md       必需：frontmatter(name/description) + 指令正文
        │       ├── scripts/       可选：可执行脚本
        │       ├── references/    可选：按需加载的参考文档
        │       ├── assets/        可选：模板/资源
        │       └── evals/         可选：evals/evals.json 测试用例
        └── mounts/         外部挂载（默认只读，可在「设置 → 挂载」开启允许写入）
        ```

        目录写入策略：
        - attachments/、workspace/、offloads/、browser/ 为**当前会话独享**（每个会话独立命名空间，互不可见）；Agent 的 file_write/file_edit/file_read/list_dir/read_image 与 Shell 命令均落在本会话目录下
        - shared/：Agent file_write、Shell 可写；跨会话共享、持久
        - offloads/：仅 Shell 自动写；可清理
        - browser/：仅浏览器截图/下载自动写；可清理
        - memory/SOUL.md：仅 Settings 可写；永久
        - memory/MEMORY.md：长期记忆；用户可编辑，AI 仅通过 memory_write 读写；永久
        - memory/YYYY-MM-DD.md：每日记忆；仅 memory_write 追加；永久
        - rules/（含 GLOBAL.md）：App 启动时从 Bundle 同步；自动注入；Agent 只读
        - skills/：每个子目录是一个技能（技能格式 格式），含 SKILL.md（frontmatter name/description）；Agent file_write、Shell 可写；启用后正文自动注入 prompt；永久
        - mounts/：Agent 只读（除非在「设置 → 挂载」中开启该文件夹的「允许写入」）；跟随系统挂载；写入经软件自带文件管理系统落盘到外部真实文件夹
        """)

        stableParts.append("""
        ## miniclaw:// 内部链接
        - `miniclaw://attachments/...`、`workspace/...`、`shared/...`、`browser/...`、`offloads/...`、`memory/...`、`rules/...` 映射到对应本地文件
        - `miniclaw://settings/<path>` 跳转设置；`miniclaw://open_terminal?init_command=...` 打开终端
        - 非 ASCII 路径必须百分号编码；路径含空格时也必须百分号编码（空格→%20）
        - `miniclaw://` 不可传入 browser 工具
        - **向用户展示文件/媒体**：必须使用「独占一行」的图片语法（以 `!` 开头），前端会自动内联渲染并支持点击预览；普通链接 `[文件名](miniclaw://...)` 不会被内联渲染，仅作可点击链接：
          - 图片：`![](miniclaw://browser/截图.png)`
          - 视频：`![](miniclaw://browser/视频.mp4)`
          - 音频：`![](miniclaw://browser/语音.m4a)`
          - 文档（pdf/word/excel/ppt/代码等）：`![](miniclaw://shared/报告.pdf)`
        - 仅当希望用户点击后跳转到文档查看器时才用普通链接 `[文件名](miniclaw://...)`；不要把媒体/文件写成普通链接，否则用户看不到内容。
        """)

        stableParts.append("""
        ## 文件搜索策略
        按以下顺序搜索用户文件：
        1. `/var/MiniClaw/attachments/` 与 `/var/MiniClaw/workspace/`
        2. `/var/MiniClaw/shared/`
        3. `/var/MiniClaw/mounts/*/`
        4. 不扫描 iSH 的 `/etc`、`/usr` 等系统目录
        通过 `shell_execute` 递归搜索使用 `find /var/MiniClaw/... -name '*.ext'`，不要使用 BusyBox ash 不支持的 globstar `**`。
        """)

        // 5. 可用工具列表 —— 已移至下方 volatile 段:会话中 MCP 服务器可能增减工具,
        // 留在稳定前缀会导致工具变化时整段缓存失效;移到 volatile 后工具清单每轮更新
        // 但不触碰前缀(工具 schema 本身经 tools: 参数权威下发)。

        // 6. 环境变量 —— 已移至下方 volatile 段:设置页修改 envVars/隐私模式不破坏前缀。

        // 7. 内存系统
        stableParts.append("""
        ## 记忆系统
        - 长期记忆唯一文件：`memory/MEMORY.md`（App 沙盒内，由 memory_write 读写）
        - 保存长期记忆时调用 `memory_write`，必须指定 `target: "long_term"`
          - 追加一条：默认 `mode: "append"`（或显式），传 `content`
          - 整体重写：`mode: "replace"`，传 `content`
          - **定点修改某一行**（例如在已有事实后追加并列项）：`mode: "edit"`，传 `old_string`（要被替换的原文）和 `new_string`（替换后的文本）
        - 保存今日过程性记忆时调用 `memory_write`，指定 `target: "daily"`；`mode: "append"`（默认，传 content）或 `mode: "edit"`（传 old_string/new_string）
        - 用 `memory_get` 搜索记忆；`scope: "long_term"` 只搜索 MEMORY.md，`daily` 只搜索今日，`all` 搜索全部记忆
        - `GLOBAL.md` 位于 rules/，是全局规则文件，禁止用作记忆或写入目标
        - ⚠️ 修改记忆**只能**用 `memory_write`；禁止对 `memory/` 目录使用 `file_edit` / `file_write`（会被写入门禁拒绝）
        - 查看和编辑长期记忆：设置 → 记忆 → 长期记忆
        - 查看每日记忆：设置 → 记忆 → 每日记忆
        """)

        // 8. 子代理使用指南（stable：角色列表与角色文件同频，属稳定内容，进缓存前缀）
        stableParts.append(SubAgentGuide.guideWithProfiles())
        // 记忆内容会随会话复盘被 memory_write 改写，属于「易变内容」，若留在稳定前缀会导致
        // 每次记忆更新后整段缓存失效、命中率归零，故必须放在断点之后。

        // === 易变段开始：以下内容置于 system prompt 末尾，避免污染 KV 缓存前缀 ===

        // 3.5 可用工具列表(会话中 MCP 工具可增减,每轮更新;schema 权威在 tools: 参数)
        // 追加引擎保留工具 dispatch_subagent：它由引擎拦截执行（不在 toolRouter 注册表），
        // 但必须出现在白名单里，否则「列表外禁止调用」铁律会让模型判定该工具不可用（子代理从不触发的根因）。
        // 用户关闭子代理时不追加（引擎侧同步不注入 schema，保持一致）。
        var toolNames = toolRouter.allToolNames()
        if SettingsStore.shared.settings.subagent.enabled {
            toolNames.append("dispatch_subagent")
            toolNames.append("close_subagent")
        }
        toolNames.sort()
        // 3.4.5 当前会话的子代理清单（A 方案：让 智能体每轮「看见」可复用/可关闭的子代理）。
        // 数据来自 SubagentRuntimeRegistry（跨轮次/跨重启存活）；无子代理时不注入。
        // 属易变内容（随子代理增删变化），放缓存断点之后，不进前缀。
        // 与白名单一致：用户关闭子代理功能时不注入（否则模型看到清单却无工具，诱发幻觉调用）。
        let liveSubagentRecords = SubagentRuntimeRegistry.shared.allRecords(for: sessionID)
        if SettingsStore.shared.settings.subagent.enabled,
           let liveSection = SubAgentGuide.liveSubagentsSection(records: liveSubagentRecords) {
            volatileParts.append(liveSection)
        }
        volatileParts.append("""
        ## 可用工具 (\(toolNames.count) 个) — 完整列表如下，仅可调用此处列出的工具名
        \(toolNames.map { "- `\($0)`" }.joined(separator: "\n"))

        **再次强调：** 上方列表是你唯一可用的工具。没有「搜索」「新闻」「联网」「查询」等通用工具。如需浏览网页请用 `browser` 工具；如需执行命令请用 `shell_execute`；其他需求请用文字回答。
        """)

        // 3.5.1 环境变量(设置页可改,不进前缀)
        let privacyMode = SettingsStore.shared.settings.envvarsPrivacyMode
        let envVars = SettingsStore.shared.settings.envvars
        var envSection = L10n.l("env_vars_header")
        if envVars.isEmpty {
            envSection += L10n.l("no_env_vars_header")
        } else {
            envSection += L10n.l("env_vars_available")
            for v in envVars where !v.key.isEmpty {
                envSection += "- `\(v.key)`\n"
            }
        }
        envSection += "隐私模式: " + (privacyMode ? L10n.l("enable_mask_label") : L10n.l("close"))
        volatileParts.append(envSection)

        // 3.6 已挂载的外部文件夹（动态注入，让 智能体知道具体可访问的挂载名与路径）
        let mounted = MountStore.shared.list().filter { $0.isMounted }
        if !mounted.isEmpty {
            let mountLines = mounted.map { "  - `\($0.path)/`（\($0.isWritable ? "可写" : "只读")）" }.joined(separator: "\n")
            let firstPath = mounted.first!.path
            volatileParts.append("""
            ## 已挂载的外部文件夹
            以下文件夹是用户在「设置 → 挂载」中挂载的外部目录，可通过文件系统工具（`list_dir` / `file_read` / `file_write` / `file_edit`）或 `shell_execute` 两种方式访问：
            \(mountLines)

            读取挂载内容的方式：
            1. 若想知道当前挂载了哪些外部文件夹，先 `list_dir` 路径 `/var/MiniClaw/mounts/`，会返回挂载名列表；
            2. 再用 `list_dir`，path 设为某个挂载目录，例如 `\(firstPath)/`，查看里面有哪些文件；
            3. 读取具体文件用 `file_read`，path 设为 `/var/MiniClaw/mounts/<name>/<子路径>`。

            写入挂载内容：
            - 标注「可写」的挂载可用 `file_write` / `file_edit` 把内容写到外部真实文件夹（真实落盘，不是拷贝）；
            - 标注「只读」的挂载写入会被拒绝并提示「该挂载为只读」；如需写入请在「设置 → 挂载」开启该文件夹的「允许写入」开关。
            """)
        }

        // 9.5 其它会话最近要点（跨对话近况摘要）：受「记忆开关」守卫，置于 volatile 段以免污染 KV 缓存前缀
        if let crossSection = crossSessionSummarySection(excluding: sessionID) {
            volatileParts.append(crossSection)
        }

        // 8. 长期记忆 + 9. 近期记忆（受「记忆开关」守卫；关闭时不注入）。
        // 记忆内容会随会话复盘被 memory_write 改写，属于「易变内容」，必须放在 volatile 段
        // （缓存断点之后），否则每次记忆更新都会让稳定前缀失效、缓存命中率归零。
        if SettingsStore.shared.settings.memory.isEnabled {
            if let longTermSection = await longTermMemorySection(fs: fs, sessionID: sessionID) {
                volatileParts.append(longTermSection)
            }

            // 9. 近期记忆（今日 + 昨日）；getRecentMemory 内部同步读 2 个文件，卸载到后台执行避免主线程阻塞。
            let recentMemory = await Task.detached(priority: .userInitiated) { MemoryManager.shared.getRecentMemory(days: 2) }.value
            if !recentMemory.isEmpty {
                volatileParts.append(String(format: L10n.l("agent_recent_memory_inject"), recentMemory))
            }
        }

        // 每条新用户消息生成一次；不自动注入设备名称、标识、电量等非必要信息。
        // 时间戳最易变，必须放在 system prompt 最末尾（volatile 段），让前面的稳定段能够命中缓存。
        volatileParts.append(currentEnvironmentPromptSection())

        return (
            stable: stableParts.joined(separator: "\n\n"),
            volatile: volatileParts.joined(separator: "\n\n")
        )
    }

    /// 长期记忆注入段：向量检索可用时注入相关片段（省 词元），否则全文兜底（现状行为）。
    /// - 检索 query 用「当前会话最新一条用户消息」：它最贴近用户此刻意图，比多句拼接更稳定
    ///   （拼接会引入历史噪音，embedding 对长 query 的召回精度反而下降），成本也最低。
    /// - 注入片段时附「完整记忆可用 memory_get 查询」，缓解「模型看不到未召回全文」的副作用。
    /// - 检索无命中时回落全文：不注入会让模型完全失去长期记忆，属功能退化。
    private func longTermMemorySection(fs: FileSystemManager, sessionID: UUID) async -> String? {
        // 向量检索可用（用户开了向量开关 + embedding 端点探测成功）→ 片段注入
        if SettingsStore.shared.settings.memory.embeddingEnabled,
           await MemoryIndexer.shared.isEmbeddingAvailable() {
            let query = latestUserMessageText(sessionID: sessionID) ?? ""
            if !query.isEmpty {
                let fragments = await MemoryIndexer.shared.search(keyword: query, scope: .longTerm, topK: 8)
                if !fragments.isEmpty {
                    return L10n.l("long_term_memory_fragments")
                        + fragments.joined(separator: "\n\n")
                        + L10n.l("agent_memory_get_hint")
                }
            }
            // 检索无命中 → 回落全文兜底
        }
        // 全文注入（默认路径 / 兜底路径）
        if let memory = await readText(fs.memoryDir.appendingPathComponent("MEMORY.md")),
           !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           memory.trimmingCharacters(in: .whitespacesAndNewlines) != FileSystemManager.defaultMemoryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) {
            return String(format: L10n.l("agent_long_term_memory_inject"), memory.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// 当前会话最新一条用户消息文本（检索 query 用）；无用户消息时返回 nil。
    private func latestUserMessageText(sessionID: UUID) -> String? {
        guard let session = SessionManager.shared.session(id: sessionID) else { return nil }
        guard let text = session.messages.last(where: { $0.role == .user })?.content else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 其它会话最近要点（跨对话近况摘要）：受「启用记忆」总开关守卫，置于 volatile 段。
    func crossSessionSummarySection(excluding sessionID: UUID) -> String? {
        guard SettingsStore.shared.settings.memory.isEnabled else { return nil }
        let others = SessionManager.shared.allSessions()
            .filter { $0.id != sessionID }
            .compactMap { s -> (String, Date)? in
                guard let sum = s.summary, !sum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return (sum, s.updatedAt)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        guard !others.isEmpty else { return nil }
        return L10n.l("other_sessions_recent_points") + others.map { "- \($0.0)" }.joined(separator: "\n")
    }

// MARK: - 环境快照（Step C：自 ChatView 迁入）

    /// 为本轮对话生成一次隐私最小化的本机环境快照。

// MARK: - 环境快照（Step C：自 ChatView 迁入）

    func currentEnvironmentPromptSection(now: Date = Date()) -> String {
        let timeZone = TimeZone.autoupdatingCurrent
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let locale = Locale.autoupdatingCurrent

        let localFormatter = DateFormatter()
        localFormatter.calendar = calendar
        localFormatter.locale = locale
        localFormatter.timeZone = timeZone
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = calendar
        weekdayFormatter.locale = locale
        weekdayFormatter.timeZone = timeZone
        weekdayFormatter.dateFormat = "EEEE"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone
        isoFormatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]

        let offsetSeconds = timeZone.secondsFromGMT(for: now)
        let offsetSign = offsetSeconds >= 0 ? "+" : "-"
        let absoluteOffset = abs(offsetSeconds)
        let offsetHours = absoluteOffset / 3_600
        let offsetMinutes = (absoluteOffset % 3_600) / 60
        let utcOffset = String(format: "%@%02d:%02d", offsetSign, offsetHours, offsetMinutes)

        let languageCode = locale.language.languageCode?.identifier ?? L10n.l("unknown")
        let regionCode = locale.region?.identifier ?? L10n.l("unknown")
        let calendarIdentifier = String(describing: calendar.identifier)

        return """
        ## 当前运行环境
        - 当前本地时间：\(localFormatter.string(from: now))
        - ISO 8601 时间：\(isoFormatter.string(from: now))
        - 当前时区：\(timeZone.identifier)（UTC\(utcOffset)）
        - 当前星期：\(weekdayFormatter.string(from: now))
        - 系统语言与地区：\(languageCode)-\(regionCode)
        - 日历系统：\(calendarIdentifier)

        涉及“今天、明天、昨天、现在、稍后”等相对日期或时间时，必须以上述本地时间和时区为准。该信息是本轮开始时的设备环境快照；如需在长时间工具执行后确认精确到秒的最新时间，应重新获取可靠时间信息。
        """
    }

    // MARK: - 启动一轮回复（服务层派发核心：ChatView.startAgentResponse 后半段迁入）

    /// 从会话设置构造采样配置：新建回复与恢复路径共用，保证采样参数同源。
    func samplingConfig() -> AgentLoopEngine.SamplingConfig {
        let sessionSettings = SettingsStore.shared.settings.session
        return AgentLoopEngine.SamplingConfig(
            topP: sessionSettings.topP,
            frequencyPenalty: sessionSettings.frequencyPenalty,
            presencePenalty: sessionSettings.presencePenalty,
            seed: sessionSettings.seed,
            parallelToolCalls: sessionSettings.parallelToolCalls,
            responseFormat: sessionSettings.responseFormat == "text" ? nil : ResponseFormat(type: sessionSettings.responseFormat)
        )
    }

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
            AppLogger.shared.info(L10n.l("intent_engine_about_to_run"), category: "Intent")
            await engine.run(userMessage: enrichedInput, history: builtHistory.messages,
                             historySourceIDs: builtHistory.sourceIDs, attachments: resolvedAttachments,
                             forceThinkingLevel: thinkingLevel)
        }
        runtime.mcpPreparationTask = preparationTask
        return (engine, runtime)
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
        let prompt = L10n.l("compress_prompt_zh") + lines.joined(separator: "\n")
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
                    ChatCompletionMessage(role: "system", content: L10n.l("compress_prompt")),
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
        let isPlaceholder = session.title == L10n.l("new_chat_title") || session.title.isEmpty || session.title == L10n.l("deep_link_task")
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
    private static func terminalFallback(session: ChatSession, sessionID: UUID, status: SessionStatus) {
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
    1. 一句简短的中文会话标题（不超过 10 个汉字，提炼核心意图，不要原样照抄整句话）；
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
    {"title":"会话标题","icon":"sf_symbol_name","iconColor":"#FF6B6B"}
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
        if t.count > 20 { t = String(t.prefix(20)) }
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
