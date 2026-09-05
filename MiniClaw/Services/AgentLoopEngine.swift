import Foundation

// MARK: - Agent Loop Engine

final class AgentLoopEngine: ObservableObject, @unchecked Sendable {
    private let toolRouter: ToolRouter
    private var routingPlan: ModelRoutingPlan?
    /// system prompt 拆成稳定段与易变段，分开放置以配合各家提示词缓存：
    /// - systemStable：人格/规则/技能/工具说明/记忆等不随请求变化的内容（进入缓存前缀）。
    /// - systemVolatile：时间戳环境段 + 动态挂载列表（每轮重新生成，置于缓存前缀之后）。
    private var systemStable: String = ""
    private var systemVolatile: String = ""
    /// system 易变段的「基础部分」（来自 ChatView：动态挂载列表 + 时间戳环境段）。
    /// 与「本会话已加载技能正文」分离存放，便于 rebuildVolatile() 在 skill_load 后增量重算易变段，
    /// 而不必重新走 ChatView.buildSystemPrompt（后者含磁盘 IO 与挂载扫描）。
    private var baseVolatile: String = ""
    /// 深度思考等级覆盖：nil=跟随模型/组默认，有值=强制开启到该档位（"low"/"medium"/"high"/"xhigh"/"max"）。
    /// 由 run(forceThinkingLevel:) 写入，runLoop + emitReasoning 内读取。
    private var forceThinkingOverride: String?
    private var activeRequestTask: URLSessionDataTask?
    /// 当前正在执行的工具 Task 集合（供 cancel/pause 中断挂起的工具调用）。
    /// [Fix 2026-08-11 并发工具崩溃·参考实现] 原 `toolExecutionTask: Any?` 是
    /// 单批并发执行的工具上限（批内并发、批间串行）：模型一次返回大量调用时，
    /// 全量 fan-out 会同时 fork 等量 iSH 进程并推高峰值内存。
    static let maxConcurrentTools = 10

    /// 单一共享可变属性——并发工具(executeToolsConcurrently 的 withTaskGroup)同时写
    /// 1925/1927 行,主线程 pause/cancel 同时读写,ARC 引用计数竞争 → swift_release_dealloc
    /// 崩溃(用户实证:两个 shell 并发执行时偶发)。改为 NSLock 保护的按 callID 集合
    /// (照 SubagentEngineBag 范式),每个工具写自己的槽位,暂停/取消枚举全部取消——
    /// 与 iSH 执行协调器(actor 持有 in-flight 集合)同构。
    private let toolExecutionTasks = ToolTaskBag()
    /// 直接引用架构的执行注册表：参数流式期（pending）→ 执行期（active）。
    /// ToolExecution 内持 AssistantBlock 引用，执行逻辑直接写 block，
    /// 经 @Published 驱动指示器与浮层实时刷新——无事件转换层、无 id 配对。
    private var pendingToolExecutions: [String: ToolExecution] = [:]
    private var activeToolExecutions: [String: ToolExecution] = [:]
    private let state = EngineState()

    /// 循环权威上下文（system + 历史 + 已完成回合 + 本轮已收文本）。
    /// `run()` 首次构建，`resume()` 从检查点载入；暂停时整体快照落盘。
    private var messages: [ChatCompletionMessage] = []
    /// 恢复时继续使用的候选端点索引（避免每轮跳回主模型）。
    private var activeEndpointIndex: Int = 0
    /// 循环迭代计数（熔断 / 安全阀延续）。
    private var iterations: Int = 0

    /// 本次 run 内的模型调用序号（缓存诊断日志用）。
    private var modelCallSeq: Int = 0
    /// 失败工具调用连续计数（熔断用，恢复时重置）。
    private var failedToolCallCounts: [String: Int] = [:]
    /// 连续无效工具调用轮数（熔断用）。
    private var consecutiveInvalidToolRounds: Int = 0
    /// 长度截断续写轮数（finish_reason=length 时自动续写，最多 3 轮）。
    private var lengthContinuationRounds: Int = 0
    /// 缺工具调用自愈轮数（finish_reason=tool_calls 但本轮回传 0 个有效工具调用，最多 1 轮）。
    private var missingToolRecoveryRounds: Int = 0

    // MARK: - Runaway 防护（工具循环断路器）
    /// 工具空转断路器：多策略检测「同工具同参数反复调用却无进展 / 轮询恒未完成」，
    /// 在到达 iOS 看门狗阈值前主动终止。
    private let toolLoopBreaker = ToolLoopBreaker()

    // MARK: - 检索收敛预算（2026-08-06）
    /// 自上次「向用户输出文本」以来的工具调用次数：
    /// 检索型任务若连续调用工具但始终不给用户输出，说明在无收敛地扩大搜索
    /// （案例：多平台查招标公告 30+ 次浏览器调用未收尾）。达到阈值后注入收敛提示。
    private var toolCallsSinceOutput = 0
    /// 本轮任务是否已注入过收敛提示（只注入一次，避免重复刷屏）。
    private var convergenceHintInjected = false
    /// 连续工具调用无用户输出的阈值（检索类任务的收敛预算）。
    private static let convergenceToolCallBudget = 12
    /// 当前任务所属会话（检查点落盘文件名 key）。
    private var sessionID: UUID? = nil
    /// 本轮 run 的 history 对应的 session 消息 id（与 history 参数一一对应），
    /// 自动压缩成功时据此定位锚点消息，写回 session 持久层。
    private var historySourceIDs: [UUID] = []
    /// 暂停/恢复时续写的助手气泡 ID（恢复时写回同一气泡，避免第二个回复气泡）。
    private var streamingMessageID: UUID? = nil

    /// 输出流式阶段的时间锚点（用于计算平均输出速度）。
    /// 仅记录「正文（body）」首/末字符时间，不含思考（reasoning）与工具/等待间隔；
    /// 按单次 run 重置（见 run()/resume()），并在 run 结束时统一结算一次。
    private var outputStreamStart: Date? = nil
    private var outputStreamEnd: Date = Date()
    /// 最近一次上报用量所用的 modelId，供结算正文耗时的报告复用（避免污染全局统计的 key）。
    private var lastReportedModelId: String = ""

    var onToken: ((String) -> Void)?
    /// 思考过程（reasoning）流：仅当模型支持深度思考（supportsDeepThinking）时由 LLMClient 上抛。
    /// 第二个参数 `iteration` 为当前「模型调用轮次」（引擎 `iterations`，1-based），
    /// 供上层把思考按轮次切片、穿插展示（而非全部堆在回复顶部）。
    var onReasoning: ((String, Int) -> Void)?
    /// 统一重试参数：任何可重试错误（RetryPolicy.retryable）自动重试 5 次 × 3s。
    /// 用户语义（2026-08-08）：一切非主动中断的错误走同一套重试；fatal 类直接报错。
    private let maxRetries = 5
    private let retryInterval: TimeInterval = 3
    /// 每次成功 LLM 调用的真实/估算用量上报（聚合为 TokenUsageReport）。
    var onTokenUsage: ((TokenUsageReport) -> Void)?
    /// 当前会话的「上下文占用快照」：口径 = 真正发出的那一份请求
    /// （system 稳定段 + 易变段 + 工具 schema 定义 + 历史 + 本轮输入 + 多模态），
    /// 与压缩阈值严格同源（快照里带 compactThreshold）。有服务商真值时 measured=true。
    /// 引擎同时写入 `ContextUsageStore`，UI 可直接读取，不依赖回调时序。
    var onContextUsage: ((ContextUsageSnapshot) -> Void)?
    var onRouteChange: ((String) -> Void)?
    /// 工具执行开始（直接引用架构）：上抛执行上下文（内持 AssistantBlock 引用），
    /// 宿主负责把 block 挂进消息流并分配位置/顺序；此后一切更新由执行逻辑直写 block。
    var onToolExecutionBegin: ((ToolExecution) -> Void)?
    var onComplete: (() -> Void)?
    /// 整轮正常完成时最后一段模型答复（最终轮 streamedText，见 emitComplete）。
    /// 工具循环的中间过程叙述不在此列；未正常完成时为空字符串。
    private(set) var finalReplyText: String = ""
    var onError: ((Error) -> Void)?
    /// 统一重试状态回调：retryable 错误进入重试循环时上抛（指示器计数/展开错误信息），
    /// 耗尽时上抛 exhausted（最终失败）。UI 据此显示/移除重试指示器。
    var onRetryState: ((RetryState) -> Void)?
    /// 软暂停落地回调：引擎在安全点把上下文快照为 `.paused` 后触发，
    /// 让上层把运行时标记为「已暂停」并保留它以便恢复（不移除 runtime）。
    var onPaused: (() -> Void)?
    /// 中断落地回调：智能体因异常/警告（网络失败、工具熔断、无效工具连续失败等）
    /// 未返回有效内容而终止时触发，让上层把本条回复标记为「已中断」而非「已完成」。
    var onInterrupted: (() -> Void)?
    /// 子代理生命周期事件回调，驱动会话页上方圆形图标。
    var onSubagentEvent: ((SubagentEvent) -> Void)?
    /// 本引擎剔除的工具名集合（子代理剔除 dispatch_subagent 防止自我递归）。
    private var toolNameExclusions: Set<String> = []
    /// 当前活跃的子代理引擎引用（用户取消父循环时一并取消子代理）。
    /// P2-4 起支持并行派发，故改为数组：一次 dispatch 可能同时跑多个子代理。
    private let activeSubagents = SubagentEngineBag()
    /// 标记本引擎为「子代理引擎」：子代理运行时不另拉起 Live Activity、不污染父 LA 进度。
    var isSubagentEngine: Bool = false

    // MARK: - P1-3 / P2-4 子代理编排配置

    /// 子代理委派模型池（P1-3）：非 nil 时子引擎走这个路由计划，否则沿用父引擎的 `routingPlan`。
    /// 由 ChatView 在注册引擎时从 `AppState.resolveSubagentRoutingPlan()` 注入。
    private var subagentRoutingPlan: ModelRoutingPlan?
    /// 本引擎在子代理树中的深度：主引擎 = 0，其派出的子代理 = 1，依此类推（P2-4 多层编排）。
    private(set) var subagentDepth: Int = 0
    /// 单次 dispatch_subagent 允许并行派发的子代理数量上限（默认 4，设置 → 智能体 → 子代理 可调 1-4）。
    /// 引擎每轮回复重建（见 run() 注释），init 时在主线程快照设置值，避免后台线程裸读
    /// SettingsStore 与设置页写竞争（2026-08-14 崩溃修复：后台读 + 主线程写 → COW 悬垂）。
    private let subagentMaxConcurrentSnapshot: Int
    private var maxParallelSubagents: Int {
        max(1, min(4, subagentMaxConcurrentSnapshot))
    }
    /// 全局并行子代理上限（跨多次 dispatch、跨层级累计，防模型失控堆积，P8）。
    /// 与单次上限同源（同一用户设置），并发数 = 用户设置的 maxConcurrent。
    private var maxGlobalParallelSubagents: Int { maxParallelSubagents }
    /// 全局活跃子代理槽位计数（线程安全，含后代层级的子代理）。
    private static let subagentSlotCounter = SubagentSlotCounter()

    func configure(subagentRoutingPlan: ModelRoutingPlan?) {
        self.subagentRoutingPlan = subagentRoutingPlan
    }

    init(toolRouter: ToolRouter) {
        self.toolRouter = toolRouter
        self.subagentMaxConcurrentSnapshot = SettingsStore.shared.settings.subagent.maxConcurrent
        // 后台宽限期耗尽：取消正在跑的工具，让主循环在下一安全点干净挂起（对齐 过期处理器）。
        bgExpiryObserver = NotificationCenter.default.addObserver(
            forName: BackgroundTaskCoordinator.didExpireNotification,
            object: nil, queue: .main
        ) { _ in
            // 后台宽限期耗尽：仅置挂起标记，让循环在 runLoop() 顶部的 waitIfSuspended()
            // 安全点自然停住。**故意不取消正在执行的工具**——工具是独立 Task.detached，
            // 可脱离循环继续跑；取消它会导致工具返回「执行被用户中断」假错误，智能体误判工具
            // 失败而放弃任务（见浏览器工具被中断后 智能体直接总结不续做的 bug）。循环已在
            // 安全点响应 suspended 标记，此处强杀工具只会制造假错误，故移除。
        }
    }

    deinit {
        if let o = bgExpiryObserver {
            NotificationCenter.default.removeObserver(o)
            bgExpiryObserver = nil
        }
    }

    /// 后台宽限期耗尽通知的观察者令牌；持有以保证观察在引擎存活期间持续生效。
    private var bgExpiryObserver: NSObjectProtocol?

    // MARK: - 子代理

    /// 子代理调度保留工具名：模型可主动调用以派发子代理；由引擎拦截处理，不进入 toolRouter。
    private static let subagentToolName = "dispatch_subagent"
    private static let closeSubagentToolName = "close_subagent"

    /// 注入给模型的子代理调度工具 schema（让模型知道可以派发子代理）。
    /// profile 参数的角色列表由 SubAgentProfileStore 动态生成（用户可自建角色）。
    private func makeSubagentToolSchema() -> ToolSchema {
        let profileList = SubAgentProfileStore.shared.allSummaries()
            .map { "- `\($0.name)`：\($0.displayName)（\($0.summary)）" }
            .joined(separator: "\n")
        let profileDescription = profileList.isEmpty
            ? String(localized: "param_subagent_role_default")
            : String(format: String(localized: "loop_subagent_roles"), profileList)
        return ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: Self.subagentToolName,
                description: String(localized: "dispatch_subagent_tool_desc"),
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "task": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subtask_desc_independent")),
                        "focus": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subagent_focus_label")),
                        "profile": JSONSchema.JSONProperty(type: "string", description: profileDescription),
                        "subagent_id": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subagent_id_reuse")),
                        "tasks": JSONSchema.JSONProperty(
                            type: "array",
                            description: String(format: String(localized: "loop_parallel_tasks_desc"), maxParallelSubagents),
                            items: JSONSchema(
                                type: "object",
                                properties: [
                                    "task": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subtask_desc")),
                                    "focus": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_focus_label")),
                                    "profile": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subagent_role_inherit")),
                                    "subagent_id": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_reuse_subagent_id"))
                                ],
                                required: ["task"]
                            )
                        )
                    ],
                    required: []
                )
            )
        )
    }

    /// 关闭子代理工具 schema（D 方案）：让模型能主动关闭不再需要的子代理。
    /// schema 声明来自 Tools/CloseSubagentTool.swift（工具声明与其它 智能体工具同放 Tools/）。
    private func makeCloseSubagentToolSchema() -> ToolSchema {
        ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: Self.closeSubagentToolName,
                description: String(localized: "close_subagent_tool_desc"),
                parameters: CloseSubagentTool.schema
            )
        )
    }

    func configure(routingPlan: ModelRoutingPlan) {
        self.routingPlan = routingPlan
    }

    /// 内部只读访问器：供 SubagentEngineBag 按子代理 id（= 子引擎会话 id）定位取消（P5）。
    var runtimeSessionID: UUID? { sessionID }

    /// 绑定当前任务身份：会话 ID（检查点落盘 key）与正在续写的助手气泡 ID。
    func configure(sessionID: UUID, streamingMessageID: UUID?) {
        self.sessionID = sessionID
        self.streamingMessageID = streamingMessageID
    }
    private var sampling: SamplingConfig?

    func configure(sampling: SamplingConfig) {
        self.sampling = sampling
    }

    /// 压缩冷却：距上次压缩不足该轮数则跳过，避免重复压缩抖动。
    /// 轮次计数存 AppState（会话级、跨引擎存活）；引擎实例每轮重建，放实例内会随重建失效。
    private let compressionCooldownTurns: Int = 3

    /// 本轮 run 的工具 schema 快照。工具定义是每次请求的固定开销（可达数千 词元），
    /// 估算上下文时必须计入，否则系统性低估（旧实现的主要漏算源）。
    private var activeToolSchemas: [ToolSchema] = []
    /// 真值校准器：用服务商回传的 prompt_tokens 校准本地估算。
    private let contextCalibrator = ContextCalibrator()
    /// 最近一次服务商回传的真实 prompt_tokens（0 = 本会话尚无真值）。
    private var lastMeasuredPromptTokens: Int = 0

    /// 注入 system prompt 的稳定段与易变段。易变段由 LLMClient 在构造请求时拼到末尾
    /// （OpenAI/Gemini 拼回 system 末尾；Anthropic 作为独立 system block 置于 cache_control 断点之后），
    /// 从而不污染缓存前缀。
    func setSystemPrompt(stable: String, volatile: String) {
        self.systemStable = stable
        self.baseVolatile = volatile
        self.systemVolatile = volatile
    }

    /// 重算 system 易变段 = 基础易变段（ChatView 传入的挂载列表 + 时间戳）+ 本会话已加载技能正文。
    /// 已加载技能正文由 `SkillManager` 按会话隔离维护，随 `skill_load` 调用累积；
    /// 注入到缓存断点之后的易变段，绝不进入缓存前缀，故对 KV 缓存命中率零影响。
    /// 同时刷新 `self.systemVolatile` 与 messages 中 system 消息的 `volatileSuffix`，
    /// 使同一次 run / resume 内、skill_load 之后的后续模型调用立即看到技能正文。
    private func rebuildVolatile() async {
        let skills = await SkillManager.shared.loadedSkillBodies(for: sessionID)
        let combined = [baseVolatile, skills].filter { !$0.isEmpty }.joined(separator: "\n\n")
        self.systemVolatile = combined
        if let idx = messages.firstIndex(where: { $0.role == "system" }) {
            messages[idx].volatileSuffix = combined
        }
    }

    // MARK: - 控制接口（主线程调用，fire-and-forget 写入 actor）

    /// 取消（硬性终止）：彻底中止循环，不可恢复。用于回复中停止与工具中断。
    /// 同时清除检查点文件，避免残留误导下次进入会话的冷恢复。
    func cancel() {
        Task { await state.cancel() }
        if let sid = sessionID { AgentTaskStore.shared.clear(sessionID: sid) }
        activeRequestTask?.cancel()
        activeRequestTask = nil
        // 一并取消正在执行的工具调用（解决工具挂起时点停止无响应的问题）。
        // [Fix 2026-08-11 并发工具崩溃] 枚举取消全部 in-flight 工具 Task
        // （stopCurrentCommand 语义:一次停止 = 取消整个批次）。
        toolExecutionTasks.drain().forEach { $0.cancel() }
        // 一并取消正在运行的子代理，避免父循环停止后子代理仍在后台空跑（并行派发时全部取消）。
        activeSubagents.drain().forEach { $0.cancel() }
        // 手动停止：实时活动右上角状态图标切到「已停止」（避免停滞在「回复中」）。
        if !isSubagentEngine {
            Task { @MainActor in BackgroundTaskController.shared.agentDidStop(sessionID: sessionID?.uuidString) }
        }
    }

    /// 软暂停（可恢复）：只置「暂停请求」，不立即杀循环。
    /// - 流式进行中：立即取消当前网络请求，已收文本在下个安全点快照为 `.paused`；
    ///   未收完的半截 tool_call 不会被 `onToolCall` 发出（LLMClient 仅定稿时回调），自然丢弃。
    /// - 工具执行中：取消工具执行 Task，工具快速失败后循环在安全点②落地为 `.paused`。
    /// - 子代理：一并取消（P2），避免父会话暂停后子代理继续空跑烧 token、恢复后结果丢失。
    func pause() {
        Task { await state.requestPause() }
        activeRequestTask?.cancel()
        activeRequestTask = nil
        // 取消正在执行的工具，让 executeTool 的 withTaskGroup 快速返回取消结果，
        // 随后循环在安全点②检测到 pauseRequested 并落地为 .paused。
        // [Fix 2026-08-11 并发工具崩溃] 枚举取消全部 in-flight 工具 Task。
        toolExecutionTasks.drain().forEach { $0.cancel() }
        // 一并取消正在运行的子代理（与 cancel() 同策略，P2）。
        activeSubagents.drain().forEach { $0.cancel() }
    }

    /// 仅取消正在执行的工具 Task（不清除检查点、不取消整个循环）。
    /// 供后台宽限期耗尽时优雅挂起循环使用：让当前工具快速失败，循环在下一安全点干净停住。
    // MARK: - 主循环

    // MARK: - 启动 / 恢复入口

    /// 首次启动：从 userMessage + history 构建上下文，进入循环。
    /// attachments：本轮用户输入附带的本地附件路径（已按模型输入模态过滤），
    /// 用于把图片 / 音频 / 文档作为多模态内容发送给模型。
    func run(
        userMessage: String,
        history: [ChatCompletionMessage],
        historySourceIDs: [UUID] = [],
        attachments: [String] = [],
        forceThinkingLevel: String? = nil
    ) async {
        self.forceThinkingOverride = forceThinkingLevel
        self.historySourceIDs = historySourceIDs
        guard let routingPlan, !routingPlan.endpoints.isEmpty else {
            onError?(AgentError.notConfigured)
            return
        }

        // 尊重已请求的暂停：用户在引擎启动前（preparationTask 的 MCP 注册/buildSystemPrompt 期间）
        // 可能已点了暂停——此时 configureRunning() 会清掉暂停标志，导致"暂停被吞"（回复照常开始）。
        // 先落地暂停（不写检查点，resume 找不到检查点时会走 stopGeneration 硬停止兜底），
        // 而不是忽略用户意图。
        if await state.isPausedRequested() {
            await state.clearPause()
            await state.markStopped()
            emitPaused()
            return
        }

        await state.configureRunning()

        // 输出速度计时锚点按「单次 run（一条用户消息的一轮回复）」重置，
        // 避免跨 run 泄漏；本轮耗时在 run 结束时统一结算一次（见 emitRunOutputDuration）。
        outputStreamStart = nil
        outputStreamEnd = Date()
        lastReportedModelId = ""

        // 后台任务挂钩：开始 Live Activity / 定位保活（若「后台运行」开启）。
        // 子代理引擎不另拉起 Live Activity（避免与主 LA 冲突，由父引擎统一展示）。
        let bgSid = self.sessionID
        if !isSubagentEngine {
            Task { @MainActor in
                let session = bgSid.flatMap { SessionManager.shared.session(id: $0) }
                let title = session?.title ?? "MiniClaw"
                let icon = session?.iconName ?? ChatSession.defaultIcon
                BackgroundTaskController.shared.agentDidStart(sessionID: bgSid?.uuidString, title: title, icon: icon)
            }
        }

        iterations = 0
        failedToolCallCounts = [:]
        consecutiveInvalidToolRounds = 0
        lengthContinuationRounds = 0
        missingToolRecoveryRounds = 0
        activeEndpointIndex = 0
        // Runaway 防护状态重置(墙钟已移除,见 run 循环说明;仅保留空转断路器)
        toolLoopBreaker.reset()
        // 检索收敛预算重置
        toolCallsSinceOutput = 0
        convergenceHintInjected = false

        // 基础消息：system（稳定段，易变段经 volatileSuffix 随请求拼到缓存前缀之后）+ 历史 + 用户本轮输入
        // 先刷新易变段：把本会话已加载技能正文注入（缓存前缀不变，命中率不受影响）。
        await rebuildVolatile()
        messages = []
        if !systemStable.isEmpty {
            var systemMessage = ChatCompletionMessage(role: "system", content: systemStable)
            systemMessage.volatileSuffix = systemVolatile
            messages.append(systemMessage)
        }
        messages.append(contentsOf: history)
        messages.append(ChatCompletionMessage(role: "user", messageContent: LLMClient.buildUserContent(text: userMessage, attachments: attachments)))

        // 会话前上下文占用检查：达到分档阈值先用 LLM 压缩旧历史，
        // 避免单轮直接超出模型上下文窗口导致截断或报错。压缩失败则静默跳过、照常继续。
        // 含冷却（短窗口内不重复压缩）与 /compact 强制触发。
        // 估算前先备好工具 schema——工具定义是每次请求的固定开销，必须计入占用。
        activeToolSchemas = buildToolSchemas()
        if let primaryEndpoint = routingPlan.endpoints.first {
            messages = await applyPreRunCompression(messages, endpoint: primaryEndpoint)
        }

        await runLoop()
    }

    /// 从检查点恢复：直接载入 `task.messages` 重放上下文，开一个全新 Loop。
    /// 与 `run` 不同，不重新拼 system/history（检查点已含全部上下文）。
    func resume(_ task: AgentTask) async {
        guard let routingPlan, !routingPlan.endpoints.isEmpty else {
            onError?(AgentError.notConfigured)
            return
        }

        // 立即把检查点从「未完成」态翻成 .running 写盘：无论用户点「继续」（.paused）
        // 还是被 kill 后 recoverIfNeeded 自动续跑（.interrupted / .running），恢复即视为
        // 「进行中」。首页橙环徽标基于 .paused/.interrupted 计算，翻成 .running 后下次
        // reloadSessions 立即消失，不必等第一轮跑完。注意：仅翻这两个「可续跑」的未完成态，
        // 不动 completed/failed/cancelled 等终态。
        if task.status == .paused || task.status == .interrupted {
            var promoted = task
            promoted.status = .running
            AgentTaskStore.shared.save(promoted)
        }

        await state.configureRunning()

        // 恢复也是一次新 run：重置输出速度计时锚点（暂停期间不计入正文耗时）。
        outputStreamStart = nil
        outputStreamEnd = Date()
        lastReportedModelId = ""

        // 后台任务挂钩：恢复时也视作一次 Agent 运行开始。
        let bgSid = self.sessionID
        if !isSubagentEngine {
            Task { @MainActor in
                let session = bgSid.flatMap { SessionManager.shared.session(id: $0) }
                let title = session?.title ?? "MiniClaw"
                let icon = session?.iconName ?? ChatSession.defaultIcon
                BackgroundTaskController.shared.agentDidStart(sessionID: bgSid?.uuidString, title: title, icon: icon)
            }
        }

        // 恢复队列输入（检查点里的；resume 时不依赖外部参数）
        for input in task.pendingUserInputs { await state.enqueue(input) }
        messages = task.messages
        // 检查点里可能不含本会话已加载技能正文（易变段，每轮重拼）：刷新易变段补回，保证恢复后模型仍看得到技能指令。
        await rebuildVolatile()
        activeEndpointIndex = task.activeEndpointIndex
        iterations = task.loopIteration
        // 熔断计数跨恢复重置（v1 简化：恢复即重新推导）
        failedToolCallCounts = [:]
        consecutiveInvalidToolRounds = 0
        lengthContinuationRounds = 0
        missingToolRecoveryRounds = 0
        toolLoopBreaker.reset()
        // 检索收敛预算重置（resume 与 run 同规则）
        toolCallsSinceOutput = 0
        convergenceHintInjected = false

        await runLoop()
    }

    // MARK: - 主循环

    /// 构造本引擎的工具清单（ToolSchema 即 OpenAI tools 线格式，直接透传）。
    /// 剔除本引擎禁止的工具名（子代理剔除 dispatch_subagent 防止自我递归），
    /// 并在父引擎上注入子代理调度工具，让模型可以主动派发子代理。
    /// 抽成方法是为了让 run() 里的「发送前上下文估算」也能算上工具定义开销。
    private func buildToolSchemas() -> [ToolSchema] {
        var toolSchemas = toolRouter.allSchemas().filter { !toolNameExclusions.contains($0.function.name) }
        // 追加子代理调度工具：仅当本引擎有权派发时（主引擎恒有；子代理引擎未触顶时有），
        // 复盘/整理等受限后台引擎（isSubagentEngine=true）不注入，保持"仅 memory 工具"的受限设计。
        if AgentLoopHelpers.canDispatchSubagents(subagentEngine: isSubagentEngine, depth: subagentDepth),
           !toolNameExclusions.contains(Self.subagentToolName) {
            toolSchemas.append(makeSubagentToolSchema())
        }
        // 关闭工具：父引擎注入；子代理引擎剔除（子代理不能关闭同级/父级，隔离原则同 read_subagent_result）。
        if !isSubagentEngine, !toolNameExclusions.contains(Self.closeSubagentToolName) {
            toolSchemas.append(makeCloseSubagentToolSchema())
        }
        // 按 function.name 升序确定性排序：工具列表顺序每轮必须完全一致，否则 tools 的缓存断点
        // 前缀逐轮变化 → 提示词缓存命中率归零。工具顺序对模型行为无影响，排序安全。
        return toolSchemas.sorted { $0.function.name < $1.function.name }
    }

    private func runLoop() async {
        guard let routingPlan else { return }
        let toolSchemas = buildToolSchemas()
        activeToolSchemas = toolSchemas
        let tools = toolSchemas.isEmpty ? nil : toolSchemas

        // 后台任务生命周期（对齐 ）：仅主引擎持有系统后台任务，
        // 避免单例 token 冲突；子代理运行在主循环的保护范围内。
        // 宽限期耗尽的取消逻辑通过 BackgroundTaskCoordinator.didExpireNotification 触发，
        // 让循环在下一安全点干净停住而非被系统强杀（审核红线）。
        if !isSubagentEngine {
            await BackgroundTaskCoordinator.shared.begin()
        }
        defer {
            if !isSubagentEngine {
                BackgroundTaskCoordinator.shared.end()
            }
        }

        while true {
            // 安全点 0（后台）：后台宽限期耗尽被挂起时，停在此处直到回前台再续跑，
            // 对齐 waitIfBackgroundSuspended()。必须在可挂起的安全点调用。
            if !isSubagentEngine {
                await BackgroundTaskCoordinator.shared.waitIfSuspended()
            }
            // 安全点①：循环顶部检查暂停（覆盖「上一轮刚完成、下一轮尚未开始」时请求暂停）。
            // 此时 messages 已是上一轮完整后的状态，直接快照即可。
            if await state.isPausedRequested() {
                let pending = await state.pendingInputs()
                await state.clearPause()
                await saveCheckpoint(status: .paused, pendingInputs: pending)
                await state.markStopped()
                emitPaused()
                return
            }
            guard await state.keepRunning() else { break }
            iterations += 1
            // 安全阀：避免模型不断调工具导致无限循环
            if iterations > 50 {
                AppLogger.shared.error(String(format: String(localized: "loop_infinite_safety"), iterations), category: "Agent", subsystem: "AgentLoop")
                break
            }

            // 本轮请求：收集 tool_call 与已流式输出的文本
            var collectedToolCalls: [ToolCall] = []
            var streamedText = ""
            // 本轮思考过程累积:DeepSeek 官方要求带工具的后续请求必须回传 reasoning_content,
            // 其余厂商由适配器基类在构造请求体时剥离,这里统一带上无副作用。
            var streamedReasoning = ""
            var passError: Error?
            var endpointIndex = activeEndpointIndex
            var passSucceeded = false
            // 本轮停止原因（来自 LLMClient 的 finish_reason / stop_reason），用于伪完成兜底。
            var lastFinishReason: String? = nil
            while endpointIndex < routingPlan.endpoints.count && !passSucceeded {
                guard await !state.isCancelled() else { return }
                let endpoint = routingPlan.endpoints[endpointIndex]
                AppLogger.shared.info(String(format: String(localized: "loop_router_candidate"), endpointIndex + 1, routingPlan.endpoints.count, endpoint.modelName))
                let llmClient = LLMClient(
                    endpointURL: endpoint.url,
                    apiKey: endpoint.apiKey,
                    format: endpoint.format,
                    usesAzureAPIKey: endpoint.usesAzureAPIKey,
                    organizationId: endpoint.organizationId.isEmpty ? nil : endpoint.organizationId,
                    projectId: endpoint.projectId.isEmpty ? nil : endpoint.projectId,
                    clientRequestId: UUID(),
                    customHeaders: endpoint.customHeaders,
                    providerType: endpoint.providerType
                )
                let requestMessages = limitMessages(messages, endpoint: endpoint)
                // 2026-08-31 缓存命中诊断：对实际发出的请求计算前缀指纹并与上一轮对比。
                // sys/tools 任一哈希变化 = 前缀在历史之前就断了；hist 首差异定位到具体消息。
                // 指纹存 AgentRunService 单例（引擎每轮重建，跨轮对比必须跨实例存活）。
                modelCallSeq += 1
                let cacheFP = CachePrefixFingerprint(messages: requestMessages, tools: tools)
                let cacheSessionKey = (sessionID.map { String($0.uuidString.prefix(8)) } ?? "anon") + (isSubagentEngine ? "-sub" : "")
                let cacheDiff = await MainActor.run {
                    AgentRunService.shared.recordCachePrefixFingerprint(sessionKey: cacheSessionKey, cacheFP)
                }
                let cacheBD = ContextUsageEstimator.breakdown(messages: requestMessages, tools: tools)
                AppLogger.shared.info(
                    "[Cache指纹] #\(modelCallSeq) \(endpoint.modelName) sys=\(cacheFP.system)/约\(cacheBD.system)tok tools=\(cacheFP.toolsHash)/约\(cacheBD.tools)tok hist=\(cacheFP.history.count)条/约\(cacheBD.history)tok 对比上轮:\(cacheDiff)",
                    category: "Cache", subsystem: "Context"
                )
                // 重试瞬时网络错误（退后台 / 网络抖动导致连接中断、超时、空响应）。
                // 仅当本轮「尚未产生任何输出」时重试，避免把半截内容重复拼接给用户。
                var capturedUsage: (input: Int, output: Int, cachedRead: Int, cachedWrite: Int)? = nil
                var capturedFinishReason: String? = nil
                var retryCount = 0
                retryLoop: while true {
                    passError = nil
                    capturedUsage = nil

                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let task = llmClient.streamChat(
                            model: endpoint.modelId,
                            messages: requestMessages,
                            tools: tools,
                            maxTokens: endpoint.maxOutputTokens,
                            reasoningEffort: AgentLoopHelpers.effectiveReasoningEffort(endpoint: endpoint, forceThinkingLevel: forceThinkingOverride),
                            thinkingLevel: forceThinkingOverride,
                            topP: sampling?.topP,
                            frequencyPenalty: sampling?.frequencyPenalty,
                            presencePenalty: sampling?.presencePenalty,
                            seed: sampling?.seed,
                            responseFormat: sampling?.responseFormat,
                            parallelToolCalls: sampling?.parallelToolCalls,
                            onToken: { [weak self] token in
                                streamedText += token
                                self?.emitToken(token)
                            },
                            onToolCall: { toolCall in
                                collectedToolCalls.append(toolCall)
                            },
                            onToolCallStreaming: { [weak self] callID, name, partialArgs, bytes in
                                self?.upsertStreamingToolExecution(callID: callID, name: name, partialArgs: partialArgs, bytes: bytes)
                            },
                            onReasoning: { [weak self] piece in
                                streamedReasoning += piece
                                self?.emitReasoning(piece)
                            },
                            onUsage: { input, output, cachedRead, cachedWrite in
                                capturedUsage = (input: input, output: output, cachedRead: cachedRead, cachedWrite: cachedWrite)
                            },
                            onFinishReason: { capturedFinishReason = $0 },
                            onComplete: { result in
                                if case .failure(let error) = result {
                                    passError = error
                                }
                                continuation.resume()
                            }
                        )
                        activeRequestTask = task
                    }
                    activeRequestTask = nil

                    // 暂停优先于错误 / 失败处理：用户请求暂停时即使本轮被取消也按软暂停处理。
                    if await state.isPausedRequested() {
                        if !streamedText.isEmpty {
                            messages.append(ChatCompletionMessage(role: "assistant", content: streamedText, reasoningContent: streamedReasoning.isEmpty ? nil : streamedReasoning))
                        }
                        let pending = await state.pendingInputs()
                        await state.clearPause()
                        await saveCheckpoint(status: .paused, pendingInputs: pending)
                        await state.markStopped()
                        emitPaused()
                        return
                    }
                    if await state.isCancelled() {
                        return
                    }

                    if passError == nil { break retryLoop }

                    // 统一重试机制：任何可重试错误（非 fatal、非用户主动中断）
                    // 自动重试 5 次 × 3s，丢弃半截输出重新完整生成（用户已确认）。
                    guard let lastErr = passError else { break retryLoop }
                    if RetryPolicy.isFatal(lastErr) {
                        // 必错（认证/请求构造/端点不存在等）：不重试、不显示指示器，直接失败。
                        break retryLoop
                    }
                    if retryCount >= maxRetries {
                        // 重试次数耗尽：上抛最终失败状态，指示器展示最终错误，不再自动重试。
                        emitRetryState(RetryState(phase: .exhausted, attempt: retryCount, total: maxRetries, lastError: lastErr))
                        break retryLoop
                    }
                    retryCount += 1
                    emitRetryState(RetryState(phase: .retrying, attempt: retryCount, total: maxRetries, lastError: lastErr))
                    // 丢弃半截输出：重试 = 重新生成（UI 侧由 onRetryState 同步清空已显示内容）。
                    streamedText = ""
                    streamedReasoning = ""
                    collectedToolCalls.removeAll()
                    // 重置输出计时：被丢弃的半截输出不计入平均输出速度统计。
                    outputStreamStart = nil
                    // 退后台期间网络请求无法运行，先等回到前台再重试。
                    let reached = await waitUntilActive(timeoutSeconds: 30)
                    let pausedNow = await state.isPausedRequested()
                    let cancelledNow = await state.isCancelled()
                    if reached, !pausedNow, !cancelledNow {
                        AppLogger.shared.warn(String(format: String(localized: "loop_retry_notice"), retryCount, maxRetries, lastErr.localizedDescription), category: "Agent", subsystem: "AgentLoop")
                        do {
                            // 等待 3s 或手动重试信号（点击指示器重试按钮立即重试）。
                            try await waitRetryInterval()
                        } catch {
                            break retryLoop
                        }
                        continue retryLoop
                    }
                    // 没等到前台或已被暂停 / 取消 → 终止重试，按失败处理。
                    if await state.isPausedRequested() {
                        if !streamedText.isEmpty {
                            messages.append(ChatCompletionMessage(role: "assistant", content: streamedText, reasoningContent: streamedReasoning.isEmpty ? nil : streamedReasoning))
                        }
                        let pending = await state.pendingInputs()
                        await state.clearPause()
                        await saveCheckpoint(status: .paused, pendingInputs: pending)
                        await state.markStopped()
                        emitPaused()
                        return
                    }
                    if await state.isCancelled() { return }
                    break retryLoop
                }

                // 暂停优先于错误/失败处理：用户请求暂停时，即使本轮被取消（passError 非 nil），
                // 也按「软暂停」处理，用已收文本做检查点，而不是当成失败。
                if await state.isPausedRequested() {
                    // 仅把本轮已收文本作为 assistant 消息补入上下文（无 tool_call；
                    // 未收完的半截 tool_call 不会被 onToolCall 发出，自然丢弃）。
                    if !streamedText.isEmpty {
                        messages.append(ChatCompletionMessage(role: "assistant", content: streamedText, reasoningContent: streamedReasoning.isEmpty ? nil : streamedReasoning))
                    }
                    let pending = await state.pendingInputs()
                    await state.clearPause()
                    await saveCheckpoint(status: .paused, pendingInputs: pending)
                    await state.markStopped()
                    emitPaused()
                    return
                }
                if await state.isCancelled() {
                    return
                }

                if passError == nil {
                    passSucceeded = true
                    activeEndpointIndex = endpointIndex
                    // 记录本轮停止原因（供下方伪完成兜底判断截断 / 缺工具）。
                    lastFinishReason = capturedFinishReason
                    // 记录本次调用的 词元 用量（服务商上报优先，否则本地估算）。
                    let inputTokens: Int
                    let outputTokens: Int
                    let cachedReadTokens: Int
                    let cachedWriteTokens: Int
                    // 同一份请求的本地估算（口径 = 真正发出的切片 + 工具 schema），
                    // 既用于无 usage 时兜底，也用于拿到真值后校准估算器。
                    let requestBreakdown = ContextUsageEstimator.breakdown(
                        messages: requestMessages,
                        tools: tools
                    )
                    if let usage = capturedUsage {
                        inputTokens = usage.input
                        outputTokens = usage.output
                        cachedReadTokens = usage.cachedRead
                        cachedWriteTokens = usage.cachedWrite
                        // 2026-08-31 缓存命中诊断：与 [Cache指纹] 日志配对使用——
                        // 指纹告诉你前缀哪段变了，命中量告诉你服务商实际复用了多少。
                        if usage.input > 0 {
                            let hitPct = String(format: "%.1f", Double(usage.cachedRead) / Double(usage.input) * 100)
                            AppLogger.shared.info(
                                "[Cache命中] #\(modelCallSeq) \(endpoint.modelName) prompt=\(usage.input) 命中=\(usage.cachedRead)(\(hitPct)%) 写入=\(usage.cachedWrite)",
                                category: "Cache", subsystem: "Context"
                            )
                        }
                        // 真值优先：服务商回传的 prompt_tokens 就是本次请求的真实上下文占用。
                        // 用它校准本地估算器，并直接驱动 UI 占用（measured=true）。
                        if usage.input > 0 {
                            lastMeasuredPromptTokens = usage.input
                            contextCalibrator.calibrate(measured: usage.input, estimated: requestBreakdown.total)
                            publishContextUsage(
                                tokens: usage.input,
                                endpoint: endpoint,
                                measured: true,
                                breakdown: AgentLoopHelpers.scale(requestBreakdown, to: usage.input)
                            )
                        }
                    } else {
                        inputTokens = contextCalibrator.adjust(requestBreakdown.total)
                        outputTokens = ContextUsageEstimator.estimate(text: streamedText)
                        cachedReadTokens = 0
                        cachedWriteTokens = 0
                        // 无真值格式：用校准后的估算刷新占用，避免圆环停在上一轮。
                        publishContextUsage(
                            tokens: inputTokens,
                            endpoint: endpoint,
                            measured: false,
                            breakdown: AgentLoopHelpers.scale(requestBreakdown, to: inputTokens)
                        )
                    }
                    emitTokenUsage(
                        endpoint.modelId,
                        inputTokens,
                        outputTokens,
                        cachedRead: cachedReadTokens,
                        cachedWrite: cachedWriteTokens
                    )
                } else if let error = passError,
                          streamedText.isEmpty,
                          collectedToolCalls.isEmpty,
                          shouldTryNextEndpoint(after: error, fallbackStrategy: endpoint.fallbackStrategy),
                          endpointIndex + 1 < routingPlan.endpoints.count {
                    AppLogger.shared.info(String(format: String(localized: "loop_router_fallback"), endpoint.fallbackStrategy, error.localizedDescription))
                    AppLogger.shared.warn(String(format: String(localized: "loop_model_fallback"), endpoint.fallbackStrategy, error.localizedDescription), category: "Agent", subsystem: "ModelRouter")
                    endpointIndex += 1
                    emitRouteChange(routingPlan.endpoints[endpointIndex].displayName)
                } else {
                    break
                }
            }

            if await state.isCancelled() {
                return
            }

            if let error = passError, !passSucceeded {
                await state.markStopped()
                AppLogger.shared.error(String(format: String(localized: "loop_model_final_failed"), error.localizedDescription), category: "Agent", subsystem: "AgentLoop")
                if let sid = sessionID { AgentTaskStore.shared.clear(sessionID: sid) }
                emitError(error)
                return
            }

            // 本轮没有「有效」工具调用（且也没有无效的）→ 这就是一次「草稿回答」边界。
            // 检查队列：若还有后续用户消息（如回复消息1期间发来的消息2），
            // 把消息2并入同一连续生成（与消息1一起处理），继续循环；否则结束。
            // 注：若只有「无效」工具调用（空名/未知），不算结束，下方会追加备注让模型重试。
            let registeredNames = toolRouter.allToolNames()
            var validToolCalls: [ToolCall] = []
            var invalidToolCalls: [ToolCall] = []
            for tc in collectedToolCalls {
                let n = tc.function.name.trimmingCharacters(in: .whitespacesAndNewlines)
                // 引擎保留工具 dispatch_subagent / close_subagent 不注册于 toolRouter，
                // 由引擎拦截执行（buildToolSchemas 注入 schema、executeTool 分发），视为有效。
                // close_subagent 此前漏列 → 父引擎提供的该工具调用恒被判无效、两轮熔断，从未成功执行。
                if !n.isEmpty && (registeredNames.contains(n) || n == Self.subagentToolName || n == Self.closeSubagentToolName) {
                    validToolCalls.append(tc)
                } else {
                    invalidToolCalls.append(tc)
                }
            }

            // ——— 伪完成兜底———
            // 仅在「本轮回传 0 个工具调用」时介入，避免干扰正常的工具调用流：
            // 1) 长度截断续写：finish_reason 为 length(OpenAI) / max_tokens(Anthropic/Gemini) 表示被 max_tokens 截断，
            //    把半截回复作为 assistant 消息入栈，再注入续写提示，最多续 3 轮。
            // 2) 缺工具自愈：finish_reason 为 tool_calls 但本轮回传 0 个有效工具调用（流格式漏发/残缺），
            //    注入一次自愈提示，最多 1 轮，避免直接空转。
            if validToolCalls.isEmpty && invalidToolCalls.isEmpty {
                if let fr = lastFinishReason,
                   (fr == "length" || fr == "max_tokens"), !streamedText.isEmpty {
                    // 长度截断续写：把半截回复入栈再注入续写提示，最多 3 轮。
                    messages.append(ChatCompletionMessage(role: "assistant", content: streamedText, reasoningContent: streamedReasoning.isEmpty ? nil : streamedReasoning))
                    lengthContinuationRounds += 1
                    if lengthContinuationRounds <= 3 {
                        messages.append(ChatCompletionMessage(role: "user", content: String(localized: "continue_reply_hint")))
                        AppLogger.shared.warn(String(format: String(localized: "loop_reply_continuation"), fr, lengthContinuationRounds), category: "Agent", subsystem: "AgentLoop")
                        continue
                    }
                    AppLogger.shared.warn(String(localized: "loop_continuation_limit"), category: "Agent", subsystem: "AgentLoop")
                } else if let fr = lastFinishReason, fr == "tool_calls" {
                    // 缺工具自愈：意图调工具但流格式漏发有效 tool_call，注入一次自愈提示，最多 1 轮。
                    messages.append(ChatCompletionMessage(role: "assistant", content: streamedText.isEmpty ? nil : streamedText))
                    missingToolRecoveryRounds += 1
                    if missingToolRecoveryRounds <= 1 {
                        messages.append(ChatCompletionMessage(role: "user", content: String(localized: "sys_tool_calls_mismatch")))
                        AppLogger.shared.warn(String(format: String(localized: "loop_missing_tool_recover"), missingToolRecoveryRounds), category: "Agent", subsystem: "AgentLoop")
                        continue
                    }
                    AppLogger.shared.warn(String(localized: "tool_call_recovery_limited"), category: "Agent", subsystem: "AgentLoop")
                }
            }

            if validToolCalls.isEmpty && invalidToolCalls.isEmpty {
                consecutiveInvalidToolRounds = 0
                if let next = await state.takeNextInput() {
                    messages.append(ChatCompletionMessage(role: "user", content: next))
                    continue
                }
                // 正常完成 → 清除检查点文件（不再需要恢复）
                if let sid = sessionID { AgentTaskStore.shared.clear(sessionID: sid) }
                await state.markStopped()
                emitComplete(replyText: streamedText)
                return
            }

            if invalidToolCalls.isEmpty {
                consecutiveInvalidToolRounds = 0
            } else {
                consecutiveInvalidToolRounds += 1
            }

            // 连续两轮只收到空名/未知工具时立即熔断。call id 每轮都会变化，不能按 id 计数；
            // 这是服务端流格式残缺/不兼容，不应继续追加备注无限请求模型。
            if validToolCalls.isEmpty && consecutiveInvalidToolRounds >= 2 {
                let names = invalidToolCalls.map { $0.function.name.isEmpty ? String(localized: "empty_name") : $0.function.name }.joined(separator: "、")
                let visibleMessage = String(format: String(localized: "loop_unrecognized_tools"), names)
                AppLogger.shared.error(String(format: String(localized: "loop_invalid_tool_fuse"), consecutiveInvalidToolRounds, names), category: "Agent", subsystem: "AgentLoop")
                emitToken(visibleMessage)
                if let sid = sessionID { AgentTaskStore.shared.clear(sessionID: sid) }
                await state.markStopped()
                emitInterrupted()
                return
            }

            // 把本轮 assistant（含有效 tool_calls 与流式文本）追加进上下文。
            // 仅有效工具调用进入 tool_calls，避免把空名/未知工具发给 API 触发非法请求。
            // reasoningContent:DeepSeek 官方要求带 tools 的后续请求必须回传(否则 400);
            // 其余厂商由适配器基类在构造请求体时剥离。
            let assistantMsg = ChatCompletionMessage(
                role: "assistant",
                content: streamedText.isEmpty ? nil : streamedText,
                toolCalls: validToolCalls.isEmpty ? nil : validToolCalls,
                reasoningContent: streamedReasoning.isEmpty ? nil : streamedReasoning
            )
            messages.append(assistantMsg)

            // 每完成一轮 → 落盘检查点（status .running），支撑 App 被杀后的冷恢复。
            if sessionID != nil {
                let pending = await state.pendingInputs()
                await saveCheckpoint(status: .running, pendingInputs: pending)
            }

            // 无效工具调用：不写入 assistant.tool_calls（避免空名进入 API 请求），
            // 改为追加一条 user 备注，让模型知道并重新发起正确调用或改用文字回答。
            if !invalidToolCalls.isEmpty {
                let names = invalidToolCalls.map { $0.function.name.isEmpty ? String(localized: "empty_name") : $0.function.name }.joined(separator: "、")
                let note = String(format: String(localized: "loop_invalid_tool_hint"), invalidToolCalls.count, names)
                messages.append(ChatCompletionMessage(role: "user", content: note))
                AppLogger.shared.warn(String(format: String(localized: "loop_invalid_tool_note"), names), category: "Agent", subsystem: "AgentLoop")
            }

            // 仅为有效工具调用执行并追加 tool 结果，下一轮继续问模型。
            // 独立工具并发执行（缩短多工具轮次的墙钟时间），
            // 结果按原始调用顺序串行回写（Phase C），保证 tool_call ↔ tool 消息配对不乱。
            let executed = await executeToolsConcurrently(validToolCalls)

            // ─── Runaway 防护（工具空转断路器）───
            // 说明:单轮回复不再设总墙钟上限。
            // 长任务(多轮 browser/file_write/shell 等)是合法场景,总墙钟只会误伤(真实案例:
            // 生成招标文件 8 轮 browser + 10 轮 file_write 被 300s 硬砍)。
            // 防挂死职责由更精确的机制各自承担:
            //   - LLM 网络挂起 → URLSession 30s/120s 超时 + 引擎重试链(2 次 + fallback,累计 ~7 分钟封顶);
            //   - 工具卡死 → 各工具自带超时(browser 20s / shell 120s 等);
            //   - 工具循环失控 → 50 轮上限 + 下方空转断路器。
            var breakerBreakReason: String?
            var breakerWarnReason: String?
            for (tc, result) in executed {
                switch toolLoopBreaker.observe(
                    toolName: tc.function.name,
                    argumentsJSON: tc.function.arguments,
                    resultText: result.text,
                    success: result.success
                ) {
                case .none:
                    break
                case .warn(let reason):
                    breakerWarnReason = reason
                case .break(let reason):
                    breakerBreakReason = reason
                }
            }
            if let reason = breakerBreakReason {
                AppLogger.shared.error(String(format: String(localized: "loop_idle_circuit"), reason), category: "Agent", subsystem: "AgentLoop")
                let visibleMessage = String(format: String(localized: "loop_idle_loop"), reason)
                emitToken(visibleMessage)
                if let sid = sessionID { AgentTaskStore.shared.clear(sessionID: sid) }
                await state.markStopped()
                emitInterrupted()
                return
            }
            if let reason = breakerWarnReason {
                AppLogger.shared.warn(String(format: String(localized: "loop_idle_warning"), reason), category: "Agent", subsystem: "AgentLoop")
                messages.append(ChatCompletionMessage(
                    role: "user",
                    content: String(format: String(localized: "loop_idle_system_hint"), reason)
                ))
            }

            // skill_load 可能在本批次内改变了本会话已加载技能集合：刷新易变段，
            // 使下一轮模型调用在 system 易变段看到新加载的技能正文（缓存前缀不受影响）。
            await rebuildVolatile()

            // ─── 检索收敛预算（任务级空转防护）───
            // 连续工具调用达到阈值仍无用户可见输出 → 注入一次收敛提示（不强制终止，
            // 由模型自行总结收尾），避免「多平台反复搜索永不收尾」（招标查询案例 30+ 轮）。
            if !executed.isEmpty {
                toolCallsSinceOutput += executed.count
            }
            if toolCallsSinceOutput >= Self.convergenceToolCallBudget, !convergenceHintInjected {
                convergenceHintInjected = true
                let hint = String(format: String(localized: "loop_no_output_hint"), toolCallsSinceOutput)
                    + String(localized: "search_give_up_hint")
                    + String(localized: "read_subagent_result_suffix")
                    + String(localized: "ask_user_hint")
                messages.append(ChatCompletionMessage(role: "user", content: hint))
                AppLogger.shared.warn(String(format: String(localized: "loop_search_converge"), toolCallsSinceOutput), category: "Agent", subsystem: "AgentLoop")
            }

            var trippedFailureCircuit: (name: String, result: ToolResult)?
            for (tc, result) in executed {
                let toolMsg = ChatCompletionMessage(
                    role: "tool",
                    content: result.text,
                    toolCallID: tc.id,
                    name: tc.function.name
                )
                messages.append(toolMsg)

                let signature = toolFailureSignature(tc)
                if result.success {
                    failedToolCallCounts[signature] = nil
                } else {
                    let count = (failedToolCallCounts[signature] ?? 0) + 1
                    failedToolCallCounts[signature] = count
                    if count >= 2 {
                        trippedFailureCircuit = (tc.function.name, result)
                        AppLogger.shared.error(String(format: String(localized: "loop_repeat_fail_fuse"), tc.function.name, count), category: "Agent", subsystem: "AgentLoop")
                        break
                    }
                }
            }

            // 安全点②：本轮工具结果已落库、上下文完整后，若请求暂停 → 落地为 .paused。
            if await state.isPausedRequested() {
                let pending = await state.pendingInputs()
                await state.clearPause()
                await saveCheckpoint(status: .paused, pendingInputs: pending)
                await state.markStopped()
                emitPaused()
                return
            }

            if let tripped = trippedFailureCircuit {
                let visibleMessage = String(format: String(localized: "loop_tool_fail_fuse"), tripped.name, tripped.result.text)
                emitToken(visibleMessage)
                if let sid = sessionID { AgentTaskStore.shared.clear(sessionID: sid) }
                await state.markStopped()
                emitInterrupted()
                return
            }
        }

        await state.markStopped()
        // 轮间被取消（父 cancel/pause drain 子代理）时不再补发虚假的迭代上限错误，
        // 终态由 runSubagent 按取消标记发 cancelled（B1 复查遗留 nit）。
        if await state.isCancelled() { return }
        emitError(AgentError.iterationLimitReached)
    }

    // MARK: - 主线程回调投递（统一出口）

    /// 所有 UI 回调的唯一投递通道：一律 `DispatchQueue.main.async` 入队，**绝不**使用 `main.sync`。
    ///
    /// 为什么禁用 `main.sync`：
    /// 1. 流式输出是逐 词元 回调的。用 `main.sync` 意味着后台流式线程**每收一个 词元 就同步等待
    ///    主线程调度一轮**——主线程越忙、后台越慢，后台线程又被钉死，是 watchdog 卡死链条的一环；
    /// 2. 只要主线程在任意位置同步等待这条后台线程，`main.sync` 立刻构成经典死锁；
    /// 3. main queue 是串行 FIFO，`async` 的提交顺序即执行顺序，**顺序语义完全保留**，无副作用。
    ///
    /// 这里刻意**不做** `if Thread.isMainThread { 直接执行 }` 短路：那会让主线程上的调用插队到
    /// 已入队的回调之前，导致 token 与 complete/toolResult 乱序。统一入队才有确定性顺序。
    private func deliverOnMain(_ work: @escaping () -> Void) {
        nonisolated(unsafe) let work = work
        DispatchQueue.main.async { work() }
    }

    /// 上抛重试状态给 UI（主线程投递）。
    private func emitRetryState(_ state: RetryState) {
        guard let onRetryState else { return }
        deliverOnMain { onRetryState(state) }
    }

    /// 等待重试间隔：3s 自动到期，或 UI 点击「立即重试」提前结束（100ms 轮询粒度）。
    /// 取消（引擎停止）时抛 CancellationError 由调用方终止重试循环。
    private func waitRetryInterval() async throws {
        let deadline = Date().addingTimeInterval(retryInterval)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            // 手动立即重试（UI 按钮）
            if await state.consumeRetryNow() { return }
            // 用户停止 / 暂停：立即终止等待（调用方 catch 后走原有暂停/取消处理）。
            let cancelled = await state.isCancelled()
            let paused = await state.isPausedRequested()
            if cancelled || paused {
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// UI 手动重试入口：点击重试指示器按钮调用，立即结束当前 3s 等待。
    /// 标志存入 EngineState actor，与等待循环（可能运行在后台线程）无竞争；
    /// configureRunning 会清残留，跨 run 不串扰。
    func requestImmediateRetry() {
        Task { await state.requestRetryNow() }
    }

    private func emitToken(_ token: String) {
        if outputStreamStart == nil { outputStreamStart = Date() }
        outputStreamEnd = Date()
        // 有文本输出 = 正在给用户反馈 → 检索收敛预算清零（允许新一轮工具推进）。
        toolCallsSinceOutput = 0
        guard let onToken else { return }
        deliverOnMain { onToken(token) }
    }

    private func emitReasoning(_ piece: String) {
        // 思考被显式关闭（forceThinkingOverride == "off"）时不展示、也不落盘；
        // nil 表示「跟随模型默认」——思考模型默认开启，此时反而要展示思考过程。
        // 原因：部分「推理模型」（DeepSeek-R1 / QwQ 等）即使请求不要求思考，
        // 也会在流式响应里下发 reasoning_content；OpenAI o 系列省略 reasoning_effort
        // 时也默认开启思考。此处拦截 "off"，保证「关闭思考」开关真正生效（不再有可见的思考过程）。
        guard forceThinkingOverride != "off" else { return }
        guard let onReasoning else { return }
        // 透传当前迭代轮次，供上层按轮次切片（iterations 在每轮 streamChat 前已自增）。
        let iteration = iterations
        deliverOnMain { onReasoning(piece, iteration) }
    }

    private func emitTokenUsage(_ modelId: String, _ input: Int, _ output: Int, cachedRead: Int = 0, cachedWrite: Int = 0) {
        lastReportedModelId = modelId
        // 主引擎：顺带刷新 Live Activity 时间戳。
        if !isSubagentEngine {
            let sid = sessionID?.uuidString
            Task { await BackgroundTaskController.shared.agentDidUpdateTime(sessionID: sid) }
        }
        guard let onTokenUsage else { return }
        // 单轮调用的 词元 用量照常上报；正文耗时（outputDurationMs）不在此处累加——
        // 否则每个 agent 循环迭代都会把「首字符→当前末字符」的整段跨度重复计入，
        // 把中间的工具调用/等待时间也算进输出速度，导致数值失真。
        // 正文耗时统一在 run 结束时由 emitRunOutputDuration() 结算一次。
        let report = TokenUsageReport(
            modelId: modelId,
            input: input,
            output: output,
            cachedRead: cachedRead,
            cachedWrite: cachedWrite,
            outputDurationMs: 0,
            agentLoops: iterations
        )
        deliverOnMain { onTokenUsage(report) }
    }

    /// run 结束时结算一次「正文输出速度」耗时：仅统计从正文（body）第一个字
    /// 到最后一个字的时间跨度，不含思考过程、工具调用与等待间隔。
    /// 只上报 duration（词元 数已在各轮 emitTokenUsage 累计），避免重复计入。
    private func emitRunOutputDuration() {
        // 本轮没有任何正文输出（例如只产生工具调用）则不结算耗时。
        guard let start = outputStreamStart else { return }
        let runSpanMs = max(1, outputStreamEnd.timeIntervalSince(start) * 1000)
        guard let onTokenUsage else { return }
        let report = TokenUsageReport(
            modelId: lastReportedModelId,
            input: 0,
            output: 0,
            cachedRead: 0,
            cachedWrite: 0,
            outputDurationMs: runSpanMs,
            agentLoops: 0
        )
        deliverOnMain { onTokenUsage(report) }
    }

    private func emitRouteChange(_ modelName: String) {
        guard let onRouteChange else { return }
        deliverOnMain { onRouteChange(modelName) }
    }

    /// 参数流式增量：占位执行上下文 upsert（首个增量创建并挂载，后续增量追加）。
    private func upsertStreamingToolExecution(callID: String, name: String, partialArgs: String, bytes: Int) {
        guard !isSubagentEngine else { return } // 子代理详情页走 SubagentEvent 事件流，无主会话 block
        let exec: ToolExecution
        if let pending = pendingToolExecutions[callID] {
            exec = pending
        } else {
            exec = ToolExecution(name: name, callID: callID)
            pendingToolExecutions[callID] = exec
            emitToolExecutionBegin(exec)
        }
        exec.appendArgsDelta(partialArgs)
    }

    /// 上抛执行上下文（直接引用架构的单一挂载点）。
    private func emitToolExecutionBegin(_ exec: ToolExecution) {
        guard let onToolExecutionBegin else { return }
        deliverOnMain { onToolExecutionBegin(exec) }
    }

    private func emitComplete(replyText: String) {
        // run 结束：结算一次正文输出速度耗时（首字→末字，不含思考/工具/等待）。
        emitRunOutputDuration()
        // 记录最终轮答复文本（工具循环结束后最后一轮的 streamedText）：
        // 首页列表摘要以此为准，避免显示整轮拼接 content 开头的过程叙述（见 ChatMessage.previewText）。
        finalReplyText = replyText
        if !isSubagentEngine {
            Task { @MainActor in
                await BackgroundTaskController.shared.agentDidFinish(
                    sessionID: sessionID?.uuidString,
                    success: true,
                    lastReply: replyText
                )
                // 若 智能体在过程中更新了会话标题/图标，这里回传最新元信息。
                if let sid = sessionID?.uuidString {
                    BackgroundTaskController.shared.agentDidUpdateSession(sessionID: sid)
                }
            }
        }
        guard let onComplete else { return }
        deliverOnMain { onComplete() }
    }

    private func emitError(_ error: Error) {
        // run 结束（出错）：若本轮已输出部分正文，仍结算其正文耗时。
        emitRunOutputDuration()
        if !isSubagentEngine {
            Task { @MainActor in await BackgroundTaskController.shared.agentDidFinish(sessionID: sessionID?.uuidString, success: false) }
        }
        guard let onError else { return }
        deliverOnMain { onError(error) }
    }

    private func emitPaused() {
        // 暂停不结算：run 仍会继续（恢复后重放），耗时留给恢复后的 run 统一结算。
        if !isSubagentEngine {
            Task { @MainActor in BackgroundTaskController.shared.agentDidPause(sessionID: sessionID?.uuidString) }
        }
        guard let onPaused else { return }
        deliverOnMain { onPaused() }
    }

    private func emitInterrupted() {
        // run 中断：结算已输出正文的耗时。
        emitRunOutputDuration()
        if !isSubagentEngine {
            Task { @MainActor in BackgroundTaskController.shared.agentDidInterrupt(sessionID: sessionID?.uuidString) }
        }
        guard let onInterrupted else { return }
        deliverOnMain { onInterrupted() }
    }

    /// 落盘检查点（整个 `messages` 上下文 + 端点/队列/迭代状态）。
    /// - `status == .running`：每轮完成后写，支撑 App 被杀后的冷恢复；
    /// - `status == .paused`：用户暂停的安全点写，等待恢复重放；
    /// 落盘检查点。调用方必须在 async 上下文。
    /// - 活跃性不变量：已取消/已停止（keepRunning == false）的引擎禁止写入检查点——
    ///   否则 cancel() 先 clear、后台循环后写，会在磁盘残留 .running 检查点，
    ///   下次进入会话被 recoverIfNeeded 当作「被中断的任务」自动续跑（已取消的回复"复活"）。
    /// - 终态（完成/失败/取消）由调用方直接 `AgentTaskStore.clear`，不调用本方法。
    /// - 子代理 / 复盘等后台引擎（`isSubagentEngine == true`）**不写**检查点：
    ///   它们若复用真实会话的 sessionID，会把后台对话写进 `AgentTaskStore[真实sessionID]`，
    ///   被 `ChatView.recoverIfNeeded` 误当作「用户会话的待恢复任务」重建重放，导致后台消息冒泡到对话框。
    private func saveCheckpoint(status: AgentTaskStatus, pendingInputs: [String]) async {
        guard !isSubagentEngine else { return }
        guard let sid = sessionID else { return }
        guard await state.keepRunning() else {
            AppLogger.shared.info(String(format: String(localized: "loop_checkpoint_skipped"), status.rawValue), category: "Agent", subsystem: "Checkpoint")
            return
        }
        let task = AgentTask(
            id: sid,
            sessionID: sid,
            status: status,
            messages: messages,
            activeEndpointIndex: activeEndpointIndex,
            pendingUserInputs: pendingInputs,
            loopIteration: iterations,
            assistantMessageID: streamingMessageID,
            updatedAt: Date()
        )
        AgentTaskStore.shared.save(task)
    }

    // MARK: - 词元 估算（统一委托 ContextUsageEstimator，口径含工具 schema 与多模态）

    /// 硬裁剪：即便压缩失败/来不及压缩，也不能把超出窗口的上下文发出去。
    /// 预算取 `ContextPolicy.hardTrimBudget`（窗口扣掉输出预留与安全边际），
    /// 并先扣除 system 与工具 schema 的固定开销，剩余额度从尾部保留完整消息，
    /// 避免截断工具调用 JSON 或拆散 tool_call / tool_result 配对。
    private func limitMessages(
        _ messages: [ChatCompletionMessage],
        endpoint: ModelRouteEndpoint
    ) -> [ChatCompletionMessage] {
        let policy = ContextPolicy(window: endpoint.contextLimitTokens, reservedOutputTokens: endpoint.maxOutputTokens ?? 0)
        guard policy.hardTrimBudget > 0 else { return messages }

        let systemMessages = messages.filter { $0.role == "system" || $0.role == "developer" }
        let systemTokens = systemMessages.reduce(0) { partial, message in
            let parts = ContextUsageEstimator.estimate(message: message)
            return partial + parts.text + parts.media + ContextUsageEstimator.perMessageOverhead
        }
        let toolTokens = ContextUsageEstimator.estimate(tools: activeToolSchemas.isEmpty ? nil : activeToolSchemas)
        // system 与工具定义无法裁剪，先扣掉；至少给正文留 1000 token 的活动空间。
        let budget = max(1_000, policy.hardTrimBudget - systemTokens - toolTokens)

        var result: [ChatCompletionMessage] = []
        var used = 0
        var toolCallIDsToInclude = Set<String>()
        var isCollectingToolExchange = false

        for message in messages.reversed() {
            if message.role == "system" || message.role == "developer" { continue }
            let belongsToToolExchange = message.role == "tool" ||
                (message.role == "assistant" && !(message.toolCalls?.isEmpty ?? true))
            let parts = ContextUsageEstimator.estimate(message: message)
            let cost = parts.text + parts.media + ContextUsageEstimator.perMessageOverhead

            if !result.isEmpty,
               used + cost > budget,
               !isCollectingToolExchange,
               !belongsToToolExchange {
                break
            }

            result.append(message)
            used += cost
            if message.role == "tool", let toolCallID = message.toolCallID {
                toolCallIDsToInclude.insert(toolCallID)
                isCollectingToolExchange = true
            } else if message.role == "assistant", let calls = message.toolCalls {
                let callIDs = Set(calls.map(\.id))
                if !toolCallIDsToInclude.isDisjoint(with: callIDs) {
                    isCollectingToolExchange = false
                    toolCallIDsToInclude.subtract(callIDs)
                }
            }
        }

        var final = result.reversed().map { $0 }
        // system / developer 消息始终保留在最前（顺序与原始一致）。
        if !systemMessages.isEmpty {
            final.insert(contentsOf: systemMessages, at: 0)
        }
        return final
    }

    // MARK: - 上下文占用与压缩（分档阈值 + 真值优先）

    /// 计算「即将发送的那一份请求」的上下文占用明细。
    /// 口径 = limitMessages 裁剪后的实际切片 + 工具 schema 定义 + system 易变段 + 多模态。
    private func currentContextBreakdown(
        _ messages: [ChatCompletionMessage],
        endpoint: ModelRouteEndpoint
    ) -> ContextUsageBreakdown {
        let effective = limitMessages(messages, endpoint: endpoint)
        return ContextUsageEstimator.breakdown(
            messages: effective,
            tools: activeToolSchemas.isEmpty ? nil : activeToolSchemas
        )
    }

    /// 发布上下文占用快照：写入 `ContextUsageStore`（UI 数据源）并触发回调。
    /// 子代理引擎不写主会话占用，避免污染父会话的圆环。
    private func publishContextUsage(
        tokens: Int,
        endpoint: ModelRouteEndpoint,
        measured: Bool,
        breakdown: ContextUsageBreakdown
    ) {
        guard !isSubagentEngine else { return }
        let policy = ContextPolicy(window: endpoint.contextLimitTokens, reservedOutputTokens: endpoint.maxOutputTokens ?? 0)
        let snapshot = ContextUsageSnapshot(
            tokens: tokens,
            window: endpoint.contextLimitTokens,
            compactThreshold: policy.compactThreshold,
            measured: measured,
            breakdown: breakdown,
            updatedAt: Date()
        )
        let sid = sessionID
        DispatchQueue.main.async { [weak self] in
            if let sid { ContextUsageStore.shared.update(snapshot, for: sid) }
            self?.onContextUsage?(snapshot)
        }
    }

    /// 会话前压缩决策：综合「分档阈值 + 冷却 + /compact 强制」决定是否压缩。
    /// 占用量取 `max(校准后的估算, 上一轮服务商真值)`——真值权威，但新增消息只有估算能覆盖，
    /// 取大值可避免「刚被真值校准过就低估新增内容」而漏压。
    private func applyPreRunCompression(_ messages: [ChatCompletionMessage], endpoint: ModelRouteEndpoint) async -> [ChatCompletionMessage] {
        // 会话级冷却读取 + /compact 强制标志消费（主线程；引擎在后台线程运行）。
        // 轮次计数与上次压缩轮次均存 AppState（跨引擎存活）：引擎实例每轮重建，
        // 冷却若放引擎内会随重建失效，长会话几乎每轮触发压缩（2026-08-13 修复）。
        let (forceCompress, cooldownOK, turn) = await MainActor.run {
            guard let sid = sessionID else { return (false, true, 0) }
            let runtime = AppState.shared.chatRuntimes[sid]
            let flag = runtime?.requestCompression ?? false
            if flag { runtime?.requestCompression = false }
            let turn = (AppState.shared.sessionCompressionTurn[sid] ?? 0) + 1
            AppState.shared.sessionCompressionTurn[sid] = turn
            let last = AppState.shared.sessionLastCompressionTurn[sid] ?? -100
            return (flag, turn - last >= compressionCooldownTurns, turn)
        }
        let policy = ContextPolicy(window: endpoint.contextLimitTokens, reservedOutputTokens: endpoint.maxOutputTokens ?? 0)

        let rawBreakdown = currentContextBreakdown(messages, endpoint: endpoint)
        let calibrated = contextCalibrator.adjust(rawBreakdown.total)
        let tokens = max(calibrated, lastMeasuredPromptTokens)
        publishContextUsage(
            tokens: tokens,
            endpoint: endpoint,
            measured: false,
            breakdown: AgentLoopHelpers.scale(rawBreakdown, to: tokens)
        )

        // 窗口未配置（0）时无法判断占用，不自动压缩（仅 /compact 强制可用）。
        let overThreshold = policy.shouldCompact(tokens: tokens)

        guard forceCompress || (overThreshold && cooldownOK) else { return messages }

        let percent = policy.window > 0 ? Int((Double(tokens) / Double(policy.window) * 100).rounded()) : 0
        AppLogger.shared.info(
            "上下文占用 \(tokens) tok（窗口 \(policy.window)，\(percent)%，阈值 \(policy.compactThreshold)）触发压缩（force=\(forceCompress), 冷却OK=\(cooldownOK), 校准因子=\(String(format: "%.2f", contextCalibrator.currentFactor))）",
            category: "Agent",
            subsystem: "Context"
        )
        guard let compressed = await compressHistory(messages, endpoint: endpoint, modelId: endpoint.modelId) else {
            AppLogger.shared.warn("自动压缩失败（空摘要或对话过短），跳过压缩", category: "Agent", subsystem: "Context")
            // 失败也进入冷却（恢复原语义），避免每轮超阈值都重试烧 token（2026-08-13 review）。
            if let sid = sessionID {
                await MainActor.run { AppState.shared.sessionLastCompressionTurn[sid] = turn }
            }
            return messages
        }
        // 摘要/锚点写回 session 持久层（与手动折叠同一机制，buildHistory 消费），
        // 使自动压缩跨轮、跨重启生效；冷却轮次同时写回（仅成功才进入冷却）。
        await persistAutoCompression(anchorID: compressed.anchorID, summary: compressed.summary, turn: turn)
        // 压缩后立刻重算并上报，用户能直接看到圆环回落。
        // 真值基线在压缩后已失效（历史被替换为摘要），清零等待下一轮真实 usage 重建。
        lastMeasuredPromptTokens = 0
        let afterBreakdown = currentContextBreakdown(compressed.messages, endpoint: endpoint)
        let afterTokens = contextCalibrator.adjust(afterBreakdown.total)
        publishContextUsage(
            tokens: afterTokens,
            endpoint: endpoint,
            measured: false,
            breakdown: AgentLoopHelpers.scale(afterBreakdown, to: afterTokens)
        )
        return compressed.messages
    }

    /// 自动压缩成功后持久化：冷却轮次写回 + 摘要/锚点写 session + 插入「已自动压缩」指示器消息。
    /// 与手动折叠共用 compactAnchorID/compactSummary 机制（buildHistory 消费：锚点之上丢弃、
    /// 摘要作 system 置 history 首位），跨轮、跨重启生效。
    /// 指示器消息为 system 角色，被 buildHistory 的 user/assistant 过滤剔除，不进 API 上下文。
    private func persistAutoCompression(anchorID: UUID?, summary: String, turn: Int) async {
        guard let sid = sessionID else { return }
        await MainActor.run {
            AppState.shared.sessionLastCompressionTurn[sid] = turn
            // 仅当能定位锚点时写回 session（主会话引擎才有 historySourceIDs）；
            // 子代理/复盘/记忆整理引擎无锚点，只更新冷却，不污染主会话的压缩状态。
            guard let anchorID else { return }
            guard let session = SessionManager.shared.session(id: sid), !summary.isEmpty else { return }
            session.compactAnchorID = anchorID
            session.compactSummary = summary
            if let idx = session.messages.firstIndex(where: { $0.id == anchorID }) {
                let indicator = ChatMessage(role: .system, content: String(localized: "auto_compact_indicator"))
                indicator.session = session
                // UI 按 createdAt 排序(Bridge/消息列表),createdAt 设为锚点消息前一刻,
                // 指示器显示在锚点上方而非会话末尾(2026-08-13 review)。
                indicator.createdAt = session.messages[idx].createdAt.addingTimeInterval(-0.001)
                session.messages.insert(indicator, at: idx)
            }
            session.updatedAt = Date()
            SessionManager.shared.persist(session)
            AppLogger.shared.info(
                "自动压缩已持久化:锚点=\(anchorID.uuidString),摘要前 60 字=\(String(summary.prefix(60)))",
                category: "Agent", subsystem: "Context"
            )
        }
    }

    /// 在 user 消息边界切分历史：保留最近一段完整对话，其余交给 LLM 压缩为摘要。
    /// 切分点选在倒数第二个 user 消息，确保最近一轮（含 tool_use/tool_result 配对）完整保留、不被拆散。
    /// 返回压缩后的消息流 + 锚点（= 切分点对应的 session 消息 id，供持久化写回）+ 摘要文本；
    /// 对话过短或摘要为空时返回 nil（上层跳过压缩）。
    private func compressHistory(
        _ messages: [ChatCompletionMessage],
        endpoint: ModelRouteEndpoint,
        modelId: String
    ) async -> (messages: [ChatCompletionMessage], anchorID: UUID?, summary: String)? {
        // systemMsg 只取真正的稳定段,排除历史摘要 system 消息(header 前缀)——否则
        // systemStable 为空且已有摘要时,摘要会被当 systemMsg 吞掉,压缩结果出现两条摘要(2026-08-13 review)。
        let header = String(localized: "history_summary_header")
        let systemMsg = messages.first { $0.role == "system" && !($0.content?.asText ?? "").hasPrefix(header) }
        let rest = Array(messages.dropFirst()) // 去掉最前的 system（若存在）
        let userIndices = rest.indices.filter { rest[$0].role == "user" }
        // 至少 2 个 user 消息才能切出「旧历史 + 最近一段」；否则对话太短，不压缩。
        guard userIndices.count >= 2 else { return nil }
        let splitAt = userIndices[userIndices.count - 2]
        let toSummarize = Array(rest[..<splitAt])
        let recent = Array(rest[splitAt...])
        guard !toSummarize.isEmpty else { return nil }

        // 2026-08-31 缓存感知压缩（对齐 dsh）：摘要请求逐字回放主请求前缀
        // （system 稳定段 + 工具 schema + 被压缩区原始消息），压缩指令作为唯一新增
        // user 消息追加在末尾——摘要调用本身命中服务端热前缀缓存，只对指令与
        // 摘要输出付全价。此前「扁平化文本 + 全新 system」的请求 0% 命中。
        let rules = (await SettingsStore.shared.snapshot()).memory.compressionRules
        let summary = await requestSummary(
            toSummarize: toSummarize,
            systemStableText: systemMsg?.content?.asText ?? "",
            compressionRules: rules,
            endpoint: endpoint,
            modelId: modelId
        )
        guard !summary.isEmpty else {
            AppLogger.shared.warn(String(localized: "err_compress_empty"), category: "Agent", subsystem: "Context")
            return nil
        }

        var result: [ChatCompletionMessage] = []
        if let systemMsg { result.append(systemMsg) }
        result.append(ChatCompletionMessage(
            role: "system",
            content: String(localized: "history_summary_header") + summary
        ))
        result.append(contentsOf: recent)
        // 锚点 = 切分点消息在 history 中的对应 session 消息。
        // 注意 rest 可能以「历史摘要 system 消息」开头（二次压缩 / 手动折叠后，buildHistory 置 history 首位），
        // 该消息无对应 session 消息，锚点索引须相应偏移 1，否则 compactAnchorID 逐轮漂移（2026-08-13 review）。
        let summaryOffset = (rest.first?.role == "system" && (rest.first?.content?.asText ?? "").hasPrefix(header)) ? 1 : 0
        let anchorIdx = splitAt - summaryOffset
        let anchorID: UUID? = anchorIdx >= 0 && anchorIdx < historySourceIDs.count ? historySourceIDs[anchorIdx] : nil
        return (result, anchorID, summary)
    }

    /// 压缩指令尾部（唯一新增的 user 消息）：消息体（被压缩区）已逐字回放在它之前，
    /// 指令只负责说明任务。这样摘要请求的前缀与主请求逐字节一致，可命中服务端热缓存。
    private func buildSummaryInstructionTail(compressionRules: String) -> String {
        var instruction = String(localized: "compress_prompt_zh")
        let customRules = compressionRules
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !customRules.isEmpty {
            instruction += String(format: String(localized: "loop_extra_compress"), customRules)
        }
        return instruction
    }

    /// 调用 LLM 生成一次性的历史摘要（非流式展示，仅收集结果文本）。
    /// 复用现有 endpoint 与 providerType，压缩失败时返回空串交由上层跳过。
    /// 复用 activeRequestTask 以便用户取消时可中断压缩请求。
    ///
    /// 2026-08-31 缓存感知压缩：请求 = system 稳定段 + 被压缩区消息逐字回放 +
    /// 压缩指令尾部（唯一新增 user 消息），并携带与主请求同款的工具 schema——
    /// 前缀与主请求逐字节一致，命中服务端热前缀缓存。
    private func requestSummary(
        toSummarize: [ChatCompletionMessage],
        systemStableText: String,
        compressionRules: String,
        endpoint: ModelRouteEndpoint,
        modelId: String
    ) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let client = LLMClient(
                endpointURL: endpoint.url,
                apiKey: endpoint.apiKey,
                format: endpoint.format,
                usesAzureAPIKey: endpoint.usesAzureAPIKey,
                organizationId: endpoint.organizationId.isEmpty ? nil : endpoint.organizationId,
                projectId: endpoint.projectId.isEmpty ? nil : endpoint.projectId,
                clientRequestId: UUID(),
                customHeaders: endpoint.customHeaders,
                providerType: endpoint.providerType
            )
            var summaryText = ""
            var summarizeMessages: [ChatCompletionMessage] = []
            if !systemStableText.isEmpty {
                summarizeMessages.append(ChatCompletionMessage(role: "system", content: systemStableText))
            }
            summarizeMessages.append(contentsOf: toSummarize)
            summarizeMessages.append(ChatCompletionMessage(
                role: "user",
                content: buildSummaryInstructionTail(compressionRules: compressionRules)
            ))
            let task = client.streamChat(
                model: modelId,
                messages: summarizeMessages,
                tools: activeToolSchemas.isEmpty ? nil : activeToolSchemas,
                onToken: { piece in summaryText += piece },
                onToolCall: { _ in },
                onUsage: { _, _, _, _ in },
                onFinishReason: { _ in },
                onComplete: { result in
                    if case .failure = result { cont.resume(returning: "") }
                    else { cont.resume(returning: summaryText) }
                }
            )
            activeRequestTask = task
        }
    }

    private func shouldTryNextEndpoint(after error: Error, fallbackStrategy: String) -> Bool {
        guard fallbackStrategy == "limited" else { return true }
        if let llmError = error as? LLMError {
            switch llmError {
            case .invalidResponse(let statusCode):
                // limited 只处理明确的客户端拒绝；超时、限流和服务端短暂错误留给 always。
                return (400...499).contains(statusCode) && statusCode != 408 && statusCode != 429
            case .rateLimited:
                return false
            case .providerRejected:
                return true
            case .encodingFailed, .decodingFailed, .noData, .streamTruncated:
                return false
            }
        }
        return false
    }

    /// 等待 App 回到前台（最多 timeoutSeconds）。期间若被暂停 / 取消则返回 false。
    /// 退后台期间 URLSession 数据任务无法运行，网络瞬时错误的重试必须等到前台才发起。
    private func waitUntilActive(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().timeIntervalSince1970 + timeoutSeconds
        while Date().timeIntervalSince1970 < deadline {
            if ScenePhaseMonitor.shared.isActive { return true }
            let paused = await state.isPausedRequested()
            let cancelled = await state.isCancelled()
            if paused || cancelled { return false }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return false
            }
        }
        return ScenePhaseMonitor.shared.isActive
    }


    /// 失败工具调用的稳定签名。忽略只用于 UI 展示的 activity，避免模型仅改描述文案就绕过熔断。
    private func toolFailureSignature(_ tc: ToolCall) -> String {
        guard let data = tc.function.arguments.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return tc.function.name + "\n" + tc.function.arguments
        }
        object["activity"] = nil
        guard let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: normalized, encoding: .utf8) else {
            return tc.function.name + "\n" + tc.function.arguments
        }
        return tc.function.name + "\n" + text
    }

    /// 解析参数、执行工具，并通过 UI 回调通知。
    /// 并发执行多个独立工具调用，再按原始调用顺序返回结果。
    /// 受 sampling.parallelToolCalls 控制：显式 false 时退回串行，避免共享资源（如 shell 单例）竞态；
    /// 其余情况（默认）并发执行以缩短多工具轮次的墙钟时间。回写顺序始终与模型给出的 tool_calls 一致。
    private func executeToolsConcurrently(_ calls: [ToolCall]) async -> [(ToolCall, ToolResult)] {
        // 确认开关快照：后台线程不裸读 SettingsStore（2026-08-13 竞争修复）。
        let confirmEnabled = await MainActor.run { SettingsStore.shared.settings.defaults.confirmBeforeToolCall }
        // 确认开启时强制串行：同一时刻只有一个待确认项，避免并发请求抢占单一确认槽。
        guard calls.count > 1,
              sampling?.parallelToolCalls ?? true,
              !confirmEnabled
        else {
            var seq: [(ToolCall, ToolResult)] = []
            for tc in calls {
                // 每个串行工具执行前检查取消/暂停，避免已请求停止时仍继续跑工具。
                let cancelled = await state.isCancelled()
                let paused = await state.isPausedRequested()
                if cancelled || paused { break }
                seq.append((tc, await executeTool(tc)))
            }
            return seq
        }
        // 2026-08-12 修复:模型可能返回重复 tool_call id,Dictionary(uniqueKeysWithValues:)
        // 遇重复 key 直接 fatalError 崩溃(全维度审计高危项)。改用 uniquingKeysWith 保留首次出现顺序。
        var order: [String: Int] = [:]
        for (offset, call) in calls.enumerated() {
            if order[call.id] == nil { order[call.id] = offset }
        }
        var collected: [(ToolCall, ToolResult)] = []
        // 分批并发（批内并发、批间串行），上限 maxConcurrentTools。
        for start in stride(from: 0, to: calls.count, by: Self.maxConcurrentTools) {
            let batch = Array(calls[start..<min(start + Self.maxConcurrentTools, calls.count)])
            collected += await withTaskGroup(of: (ToolCall, ToolResult).self) { group in
                for tc in batch {
                    group.addTask { (tc, await self.executeTool(tc)) }
                }
                var out: [(ToolCall, ToolResult)] = []
                for await pair in group { out.append(pair) }
                return out
            }
        }
        return collected.sorted { (order[$0.0.id] ?? 0) < (order[$1.0.id] ?? 0) }
    }

    /// 把工具调用的原始参数 JSON 转成一句话人类可读的操作摘要，供确认框展示
    /// （不展示完整命令，用户想看细节可在会话内的工具指示器里查看）。
    private func operationSummary(toolName: String, arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(format: String(localized: "loop_calling_tool"), toolName)
        }
        let lower = toolName.lowercased()
        let pick: (String...) -> String? = { keys in
            for k in keys {
                if let v = dict[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        // 浏览器 / 网络
        if lower.contains("browser") || lower.contains("web") || lower.contains("search") || lower.contains("url") {
            if let q = pick("query", "search", "keyword", "q") { return String(format: String(localized: "loop_searching"), String(q.prefix(24))) }
            if let u = pick("url", "link", "href") {
                if let host = URL(string: u)?.host { return String(format: String(localized: "loop_opening"), host) }
                return String(format: String(localized: "loop_opening"), String(u.prefix(24)))
            }
        }
        // 终端 / 命令执行
        if let c = pick("command", "cmd", "code", "script", "expression") { return String(format: String(localized: "loop_executing"), String(c.prefix(24))) }
        // 文件读取 / 写入 / 编辑
        if let p = pick("path", "file", "filename", "file_path", "target") {
            let verb = lower.contains("read") ? String(localized: "read_action") : (lower.contains("write") || lower.contains("edit") || lower.contains("create")) ? String(localized: "write_action") : String(localized: "files")
            return "\(verb) \(String(p.prefix(28)))"
        }
        // 通用：取第一个有意义的字符串字段
        for (_, v) in dict {
            if let s = v as? String, !s.isEmpty { return String(format: String(localized: "loop_calling_tool_detail"), toolName, String(s.prefix(24))) }
        }
        return String(format: String(localized: "loop_calling_tool"), toolName)
    }

    /// 短码解析：清单只展示 UUID 前 8 位，模型照抄短码关闭是高频路径——
    /// 对当前会话的子代理卡片做大小写不敏感前缀匹配，唯一命中才返回
    /// （多命中/零命中返回 nil，让模型收到明确错误而非误关）。
    @MainActor
    private func prefixResolveSubagentID(_ args: [String: Any], sessionID: UUID) -> UUID? {
        guard let s = args["subagent_id"] as? String else { return nil }
        let short = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard short.count >= 4, UUID(uuidString: s) == nil else { return nil }
        let matches = SubagentStore.shared.avatars(for: sessionID)
            .filter { $0.id.uuidString.lowercased().hasPrefix(short) }
            .map(\.id)
        return matches.count == 1 ? matches[0] : nil
    }

    /// 拦截早退类工具（dispatch/close_subagent）的执行生命周期补全：
    /// 与通用路径一致地挂载占位 → 参数定稿 → 结果落定，让工具卡正常显示
    /// 状态流转与耗时（2026-09-05 修复：此前早退绕过挂载，卡片回落
    /// .shellTool(command:"") 空壳且状态永不收口）。
    private func finalizeInterceptedToolExec(_ tc: ToolCall, result: ToolResult, startedAt: Date) {
        let exec: ToolExecution
        if let pending = pendingToolExecutions[tc.id] {
            exec = pending
        } else {
            exec = ToolExecution(name: tc.function.name, callID: tc.id, startedAt: startedAt)
            pendingToolExecutions[tc.id] = exec
            emitToolExecutionBegin(exec)
        }
        exec.beginExecution(argsJSON: tc.function.arguments)
        exec.finish(result, duration: Date().timeIntervalSince(startedAt))
    }

    private func executeTool(_ tc: ToolCall) async -> ToolResult {
        let rawName = tc.function.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 防御：name 为空或未注册时直接返回明确错误，不抛异常导致循环中断
        guard !rawName.isEmpty else {
            AppLogger.shared.error(String(format: String(localized: "loop_empty_fn_rejected"), tc.id), category: "Agent", subsystem: "ToolRouter")
            return ToolResult(success: false, text: String(localized: "err_tool_call_no_name"))
        }
        // [ToolForensics] 取证（唐唐 2026-09-05，只进 Xcode 控制台不进 App 日志）：
        // 前移到拦截之前，覆盖 shell_execute / dispatch_subagent / close_subagent 三者。
        if rawName == "shell_execute" || rawName == Self.subagentToolName || rawName == Self.closeSubagentToolName {
            NSLog("[ToolForensics] name=%@ callID=%@ rawArgs=%@", rawName, tc.id, tc.function.arguments)
        }
        let interceptedStartedAt = Date()
        // 子代理调度：拦截保留工具名，派生子代理并同步等待其返回，作为本工具结果回传父循环。
        // 硬深度守卫：不依赖 schema 剔除（模型可能幻觉输出旧工具名），执行前校验深度上限，
        // 触顶直接返回错误结果（模型收到明确提示），杜绝无限递归派发。
        if rawName == Self.subagentToolName {
            // 子代理恒可用（无用户总开关）；此处仅做深度递归守卫
            //（模型幻觉直调时兜底，schema 剔除 + 引导段已控制常规路径）。
            guard AgentLoopHelpers.canDispatchSubagents(subagentEngine: isSubagentEngine, depth: subagentDepth) else {
                let result = ToolResult(success: false, text: String(format: String(localized: "loop_subagent_depth_error"), AgentLoopHelpers.maxSubagentDepth))
                finalizeInterceptedToolExec(tc, result: result, startedAt: interceptedStartedAt)
                return result
            }
            let result = await spawnSubagent(toolCall: tc)
            finalizeInterceptedToolExec(tc, result: result, startedAt: interceptedStartedAt)
            return result
        }
        // 关闭子代理：仅父引擎可调（schema 已剔除子代理引擎；执行级再兜底一次——
        // 子代理可能幻觉直调旧工具名，若放行会误删兄弟子代理并销毁其浏览器上下文）。
        if rawName == Self.closeSubagentToolName {
            guard !isSubagentEngine else {
                let result = ToolResult(success: false, text: String(localized: "err_subagent_no_close_perm"))
                finalizeInterceptedToolExec(tc, result: result, startedAt: interceptedStartedAt)
                return result
            }
            let closeArgs: [String: Any] = (try? JSONSerialization.jsonObject(
                with: Data(tc.function.arguments.utf8)
            ) as? [String: Any]) ?? [:]
            guard let parentSID = sessionID else {
                let result = ToolResult(success: false, text: String(localized: "err_engine_no_session"))
                finalizeInterceptedToolExec(tc, result: result, startedAt: interceptedStartedAt)
                return result
            }
            // 精确 UUID 优先；失败则按前缀对当前会话子代理卡片唯一匹配
            // （系统提示词清单只展示 8 位短码，模型照抄短码关闭是高频路径，2026-09-05）。
            let subagentID: UUID?
            if let exact = CloseSubagentTool.parseSubagentID(closeArgs) {
                subagentID = exact
            } else {
                subagentID = await prefixResolveSubagentID(closeArgs, sessionID: parentSID)
            }
            guard let subagentID else {
                // 失败文案附带存活清单（2026-09-05）：此前通用错误让模型以为格式错误，
                // 对已关闭的子代理反复重试直至熔断——附上清单即打破循环。
                let live = await MainActor.run {
                    SubagentStore.shared.avatars(for: parentSID)
                        .map { "`\($0.id.uuidString.prefix(8))`（\($0.name)）" }
                        .joined(separator: "、")
                }
                let text = live.isEmpty
                    ? String(localized: "err_close_subagent_need_id") + "\n" + String(localized: "err_close_subagent_none")
                    : String(localized: "err_close_subagent_need_id") + "\n" + String(format: String(localized: "err_close_subagent_live_list"), live)
                let result = ToolResult(success: false, text: text)
                finalizeInterceptedToolExec(tc, result: result, startedAt: interceptedStartedAt)
                return result
            }
            let (ok, text) = await SubagentLifecycle.close(sessionID: parentSID, subagentID: subagentID, cancel: { [weak self] id in
                self?.cancelSubagent(subagentID: id)
            })
            let result = ToolResult(success: ok, text: ok ? text : "Info: \(text)")
            finalizeInterceptedToolExec(tc, result: result, startedAt: interceptedStartedAt)
            return result
        }
        // 预检查：若 name 不在已注册工具列表中，立即返回错误并提示具体名称
        let registeredNames = toolRouter.allToolNames()
        guard registeredNames.contains(rawName) else {
            AppLogger.shared.error("工具调用失败：未知工具「\(rawName)」（已注册工具：\(registeredNames.joined(separator: ", "))）", category: "Agent", subsystem: "ToolRouter")
            // 按类别分组列出可用工具，帮助模型快速定位正确工具名
            let sortedNames = registeredNames.sorted()
            let toolList = sortedNames.joined(separator: "、")
            return ToolResult(success: false, text: String(format: String(localized: "loop_unknown_tool"), rawName, toolList))
        }

        // ── 工具调用前确认：开启时在执行前请求用户批准 ──
        // 「允许本次会话」授权的会话跳过确认，直接执行；其他会话走全局设置规则。
        // 后台引擎（复盘/子代理，isSubagentEngine=true）不弹确认框：它们以随机 UUID 运行，
        // 弹窗会显示「未知会话」且无人归因，永久挂起。用户对主会话的授权语义上已继承。
        let sid = self.sessionID ?? UUID()
        // 先查该会话是否已获「允许本次会话」授权（避免弹确认框）；需在主线程访问单例。
        // 确认开关同帧取主线程快照（2026-08-13 竞争修复：后台线程不裸读 SettingsStore）。
        let (autoApproved, confirmEnabled) = await MainActor.run {
            (ToolConfirmationBridge.shared.isAutoApproved(sessionID: sid),
             SettingsStore.shared.settings.defaults.confirmBeforeToolCall)
        }
        if !isSubagentEngine, confirmEnabled, !autoApproved {
            let title = await MainActor.run { SessionManager.shared.session(id: sid)?.title ?? String(localized: "unknown_session") }
            let approved = await ToolConfirmationBridge.shared.request(
                toolName: rawName,
                summary: operationSummary(toolName: rawName, arguments: tc.function.arguments),
                sessionID: sid,
                sessionTitle: title
            )
            if !approved {
                AppLogger.shared.info(String(format: String(localized: "loop_tool_rejected"), rawName), category: "Agent", subsystem: "ToolRouter")
                return ToolResult(success: false, text: String(format: String(localized: "loop_tool_rejected_error"), rawName))
            }
        }

        // 后台 Live Activity 进度更新：进入真实执行阶段时刷新（子代理引擎不污染父 LA）。
        if !isSubagentEngine {
            Task { @MainActor in
                await BackgroundTaskController.shared.agentDidProgress(String(format: String(localized: "loop_calling_tool_colon"), rawName), sessionID: sessionID?.uuidString)
            }
        }

        // ── 取消/暂停快速路径：执行前先检查，避免进入可能挂起的工具 ──
        if await state.isCancelled() {
            return ToolResult(success: false, text: String(localized: "err_user_cancelled"))
        }
        if await state.isPausedRequested() {
            return ToolResult(success: false, text: String(localized: "err_user_paused"))
        }

        let startedAt = Date()
        // 危机定位标记：同步落盘（不依赖异步队列），卡死时日志里最后一条 ENTER 即指出卡在哪个工具。
        AppLogger.shared.crisisMark("TOOL ENTER: \(rawName)")
        // 直接引用架构：取/建执行上下文并挂载。参数流式期已挂载的命中注册表直接复用；
        // 非流式（无参数增量）场景在此首次创建。beginExecution 使参数定稿、状态转 running。
        let exec: ToolExecution
        let isNewExecution: Bool
        if let pending = pendingToolExecutions[tc.id] {
            exec = pending
            isNewExecution = false
        } else {
            exec = ToolExecution(name: rawName, callID: tc.id, startedAt: startedAt)
            isNewExecution = true
        }
        // 参数定稿必须在挂载之前：子代理转发（child.onToolExecutionBegin）会读
        // exec.argsJSON 构造 ToolCallEvent，挂载时参数为空会导致工具卡参数显示空白。
        // 主线不受影响（参数流式期已挂载，挂载侧只读 position，参数由 block 实时刷新）。
        exec.beginExecution(argsJSON: tc.function.arguments)
        if isNewExecution {
            pendingToolExecutions[tc.id] = exec
            emitToolExecutionBegin(exec)
        }

        // ── 带超时可取消的工具执行：单个工具最长 120 秒 ──
        // 工具与 120s 超时竞速 + 用户取消/暂停三方竞争，任一触发立即返回。
        // [Fix 2026-08-11 并发工具崩溃] execTask 按 callID 注册进 ToolTaskBag
        // （NSLock 保护），确保 pause/cancel 能取消真正的工作（枚举全部 in-flight）。
        // 关键修复：工具的真实同步逻辑（图片 OCR/分类、文件读取、记忆落盘等）原本随
        // executeTool 所在的 MainActor 上下文在主线程执行，遇到重工具会把主线程夯 30~50s，
        // 被 iOS 看门狗强杀（见崩溃日志 MAIN THREAD BLOCKED 39.9s/51.6s）。
        // 改为 detached 任务，让工具体在后台线程跑；引擎内部所有 UI 回调统一经
        // deliverOnMain（main.async，FIFO）回到主线程，不影响界面刷新，也不再同步等待主线程。
        let execTask: Task<ToolResult, Never> = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                return ToolResult(success: false, text: String(localized: "err_engine_released"))
            }
            // 若 pause/cancel 在 Task 创建与赋值之间触发，此处快速退出。
            guard !Task.isCancelled else {
                return ToolResult(success: false, text: String(localized: "err_user_paused_cancelled"))
            }

            do {
                return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask { [weak self] in
                    guard let self else {
                        return ToolResult(success: false, text: String(localized: "err_engine_released"))
                    }
                    // 在闭包内重建参数，避免捕获外部非 Sendable 的 [String:Any]。
                    let innerArgs: [String: Any]
                    if let data = tc.function.arguments.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        innerArgs = parsed
                    } else {
                        innerArgs = [:]
                    }
                    do {
                        // 浏览器作用域：子代理引擎用自身 subID（独立浏览器上下文），主引擎回落父会话。
                        let browserScope = self.isSubagentEngine ? self.sessionID : nil
                        // 过程流上报通道：TaskLocal 注入的 reporter 直达执行上下文，
                        // appendOutputLine 内部做行缓冲 + 节流 + 回主线程写 block。
                        let reporter: @Sendable (String) -> Void = { line in
                            exec.appendOutputLine(line)
                        }
                        return try await ToolProgressScope.$reporter.withValue(reporter) {
                            try await EngineBrowserScope.$sessionID.withValue(browserScope) {
                                try await self.toolRouter.execute(name: rawName, parameters: innerArgs)
                            }
                        }
                    } catch {
                        return ToolResult(success: false, text: "Error: \(error.localizedDescription)")
                    }
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: 120_000_000_000)
                        return ToolResult(success: false, text: String(format: String(localized: "loop_tool_timeout"), rawName))
                    } catch {
                        // CancellationError → pause/cancel 触发，立即返回"中断"而非等工具跑完。
                        return ToolResult(success: false, text: String(format: String(localized: "loop_tool_interrupted"), rawName))
                    }
                }
                // 取第一个完成的结果（工具完成/失败 / 超时 / 用户取消），随后 cancelAll()
                // 取消竞速中的另一个子任务。注意：withTaskGroup 默认会等待**所有**子任务结束才返回，
                // 若不在拿到首个结果后立即取消，120s 睡眠任务会拖住 group 直到超时，导致工具早已返回
                // 却要等满 120s 循环才拿到结果（表现为"模型硬等到 120 秒限制才继续回复"）。
                guard let first = try await group.next() else {
                    group.cancelAll()
                    return ToolResult(success: false, text: String(localized: "err_tool_abnormal_interrupt"))
                }
                group.cancelAll()
                return first
            }
            } catch {
                return ToolResult(success: false, text: String(localized: "err_tool_interrupted"))
            }
        }
        // [Fix 2026-08-11 并发工具崩溃] 按 callID 注册到集合(NSLock 保护):
        // 并发工具各自写自己的槽位,不再竞争单一共享属性;pause/cancel 枚举全部取消。
        toolExecutionTasks.insert(tc.id, task: execTask)
        let result = await execTask.value
        toolExecutionTasks.remove(tc.id)

        let duration = Date().timeIntervalSince(startedAt)
        exec.finish(result, duration: duration)
        // 执行已落定，出表：一个 callID 只执行一次，注册表仅用于「参数流式期 → 执行期」
        // 的上下文传递，留着会让长会话多轮循环持续累积（引擎销毁前不释放）。
        pendingToolExecutions.removeValue(forKey: tc.id)
        AppLogger.shared.crisisMark("TOOL DONE: \(rawName) (\(Int(duration * 1000))ms)")
        return result
    }

    // MARK: - 子代理派发

    private func emitSubagentEvent(_ event: SubagentEvent) {
        guard let onSubagentEvent else { return }
        deliverOnMain { onSubagentEvent(event) }
    }

    /// 派生子代理：复用同一套循环与模型路由，
    /// 但使用独立的上下文与受约束的工具清单；结束后把子代理最终回答作为父循环的工具结果回传。
    ///
    /// 支持三种形态：
    /// 1. **单任务**（`task`）：串行执行，行为与既有版本一致。
    /// 2. **并行多任务**（`tasks` 数组，P2-4）：同时派多个互不依赖的子代理，全部完成后合并结果回传。
    /// 3. **多层**（P2-4）：深度未达 `maxSubagentDepth` 的子代理仍持有 dispatch_subagent，可继续往下派。
    ///
    /// 支持**复用同一子代理**：若 `subagent_id` 命中已存在的子代理，则把新任务
    /// 作为下一轮 user 消息接续其已有上下文（保留历史），而非新建。
    ///
    /// 模型选择（P1-3）：优先使用「子代理模型」槽位（`subagentRoutingPlan`），未配置时沿用父引擎路由。
    private func spawnSubagent(toolCall tc: ToolCall) async -> ToolResult {
        guard let parentPlan = routingPlan else {
            return ToolResult(success: false, text: String(localized: "err_subagent_no_route"))
        }
        let childPlan = subagentRoutingPlan ?? parentPlan

        let args: [String: Any]
        if let data = tc.function.arguments.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else { args = [:] }

        let specs = AgentSubagentParsing.parseSubagentSpecs(from: args)
        guard !specs.isEmpty else {
            return ToolResult(success: false, text: String(localized: "err_dispatch_need_task"))
        }

        let parentSessionID = self.sessionID ?? UUID()

        // 单任务：保持既有串行路径（无并发开销、事件顺序与旧版一致）。
        if specs.count == 1 {
            let r = await runSubagent(spec: specs[0], parentSessionID: parentSessionID, plan: childPlan)
            return ToolResult(success: true, text: r.rendered)
        }

        // 并行多任务（P2-4）：受 maxParallelSubagents 限制，超出部分截断并在结果里说明。
        let limited = Array(specs.prefix(maxParallelSubagents))
        let dropped = specs.count - limited.count
        let results: [SubagentRunResult] = await withTaskGroup(of: (Int, SubagentRunResult).self) { group in
            for (idx, spec) in limited.enumerated() {
                group.addTask { [weak self] in
                    guard let self else {
                        return (idx, SubagentRunResult(id: UUID(), name: String(localized: "subagents"), body: String(localized: "engine_released"), ok: false))
                    }
                    let r = await self.runSubagent(spec: spec, parentSessionID: parentSessionID, plan: childPlan)
                    return (idx, r)
                }
            }
            var collected: [(Int, SubagentRunResult)] = []
            for await item in group { collected.append(item) }
            // 按派发顺序还原，保证回传给模型的结果顺序稳定（并行完成顺序不可控）。
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var text = String(format: String(localized: "loop_parallel_all_done"), limited.count)
        text += results.map(\.rendered).joined(separator: "\n\n")
        if dropped > 0 {
            text += String(format: String(localized: "loop_parallel_dropped"), specs.count, maxParallelSubagents, dropped)
        }
        return ToolResult(success: true, text: text)
    }

    /// 执行单个子代理（新建或复用），并把生命周期事件抛给 UI。
    private func runSubagent(spec: SubagentTaskSpec, parentSessionID: UUID, plan: ModelRoutingPlan) async -> SubagentRunResult {
        // 全局并行上限（P8）：跨多次 dispatch / 跨层级累计，防模型失控堆积同时打满服务商。
        guard Self.subagentSlotCounter.acquire(limit: maxGlobalParallelSubagents) else {
            return SubagentRunResult(
                id: UUID(),
                name: String(localized: "subagents"),
                body: String(format: String(localized: "loop_parallel_global_limit"), maxGlobalParallelSubagents),
                ok: false
            )
        }
        defer { Self.subagentSlotCounter.release() }
        let task = spec.task
        // 子代理思考档位（参考 reasonix subagent_effort 思路，设置 → 智能体 → 子代理）：
        // follow=不强制（模型默认） / off=关闭思考 / low / high。
        // 派发时就确定：模型信息（含思考强度）在启动即展示，不等运行结束。
        // 主线程快照读取（后台裸读 SettingsStore 竞争修复，2026-08-14）。
        let subagentThinking = await MainActor.run { SettingsStore.shared.settings.subagent.thinking }
        let childThinking: String? = {
            switch subagentThinking {
            case "off": return "off"
            case "low": return "low"
            case "high": return "high"
            default: return nil
            }
        }()
        let subID: UUID
        let subName: String
        let child: AgentLoopEngine
        let baseFocus: String?
        let baseHistory: [ChatCompletionMessage]
        // 复用分支的原始角色（落盘时保持人设；非复用为 nil）。
        let recProfile: String?

        if let reuseID = spec.reuseID,
           let rec = SubagentRuntimeRegistry.shared.record(for: parentSessionID, subagentID: reuseID) {
            subID = rec.id
            subName = rec.info.name
            baseFocus = rec.focus
            baseHistory = rec.history
            recProfile = rec.profile
            // 复用路径：优先沿用本次 profile，未传则保持该子代理原有角色（人设不漂移）。
            let reuseProfile = spec.profile ?? rec.profile
            // 重建子引擎（不长期持有活实例），用已积累历史续接上下文。
            child = makeSubagentChild(subID: subID, focus: baseFocus, routingPlan: plan, profileName: reuseProfile)
            emitSubagentEvent(.taskAdded(rec.info, task))
        } else {
            subID = UUID()
            // 会话页胶囊卡/详情页名称只保留任务名称，不带「子代理·」前缀
            // （唐唐 2026-09-05 要求；结果文本由 loop_subagent_prefix 自带 [子代理 …] 标签）。
            subName = (spec.focus?.isEmpty == false) ? spec.focus! : String(localized: "subagents")
            baseFocus = spec.focus
            baseHistory = []
            recProfile = nil
            child = makeSubagentChild(subID: subID, focus: spec.focus, routingPlan: plan, profileName: spec.profile)
            let info = SubagentInfo(id: subID, name: subName, task: task)
            emitSubagentEvent(.started(info))
            SubagentRuntimeRegistry.shared.upsert(sessionID: parentSessionID, record: SubagentRuntimeRecord(id: subID, info: info, focus: spec.focus, profile: spec.profile, history: [], status: .running))
        }

        let info = SubagentInfo(id: subID, name: subName, task: task)
        // 派发即写入头部模型信息（与主会话标题区「分组·模型名」样式一致，思考强度放最后）：
        // 模型 = 路由首候选端点（分组·模型名，直接选模型则只有模型名）；思考强度 = 本次实际档位。
        let modelDisplay: String = {
            guard let ep = plan.endpoints.first else { return "" }
            if let g = ep.groupName, !g.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(g)·\(ep.modelName)"
            }
            return ep.modelName
        }()
        let thinkingDisplay: String = {
            switch childThinking {
            case "off": return String(localized: "no_thinking")
            case "low": return String(localized: "level_low")
            case "high": return String(localized: "high")
            default: return String(localized: "default")
            }
        }()
        if !modelDisplay.isEmpty {
            let sid = parentSessionID
            Task { @MainActor in
                SubagentStore.shared.updateModelInfo(sessionID: sid, info: info,
                                                     modelDisplay: modelDisplay,
                                                     thinkingDisplay: thinkingDisplay)
            }
        }

        // 熔断/工具连续失败等打断路径会触发 onInterrupted，先行发 cancelled（终态互斥，P3）。
        child.onInterrupted = { [weak self] in
            self?.emitSubagentEvent(.cancelled(info))
        }

        activeSubagents.add(child)

        // 并行运行时多个子代理各自累积文本，用 actor 隔离的收集器避免数据竞争。
        let collector = SubagentAnswerCollector()
        /// 工具调用 / 思考段穿插用的全局时间线序号（与主线 ChatView.nextTimelineOrder 同语义）。
        let order = SubagentTimelineCounter()

        child.onToken = { [weak self] piece in
            collector.append(piece)
            self?.emitSubagentEvent(.token(info, piece))
        }
        child.onError = { [weak self] err in
            self?.emitSubagentEvent(.error(info, err.localizedDescription))
        }
        // 直接引用架构：父引擎监听子引擎的单一挂载点转发工具事件（与主线同构）。
        // 子引擎 isSubagentEngine=true 不走主会话 block 注册表，工具 exec 只在
        // executeTool 首次创建并挂载 → 此处即「工具开始执行」时机（等价旧 onToolCall）。
        child.onToolExecutionBegin = { [weak self] exec in
            guard let self else { return }
            let argsStr: String
            if let data = exec.argsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
               let s = String(data: pretty, encoding: .utf8) {
                argsStr = s
            } else {
                argsStr = exec.argsJSON
            }
            let event = ToolCallEvent(
                name: exec.name,
                callID: exec.callID,
                arguments: argsStr,
                timestamp: exec.startedAt,
                position: 0,
                timelineOrder: order.next()
            )
            self.emitSubagentEvent(.toolCall(info, event))
            // 结果落定：exec 内持 onFinish 同步回调（等价旧 onToolResult）。
            exec.onFinish = { [weak self] result, duration in
                self?.emitSubagentEvent(.toolResult(info, exec.name, exec.callID, result.text, result.success, duration))
            }
        }
        child.onReasoning = { [weak self] text, index in
            self?.emitSubagentEvent(.reasoning(info, text, index, order.next()))
        }

        // 子代理思考档位（参考 reasonix subagent_effort 思路，设置 → 智能体 → 子代理）：
        // 已在派发处确定（runSubagent 开头），此处只应用。
        await child.run(userMessage: task, history: baseHistory, forceThinkingLevel: childThinking)

        activeSubagents.remove(child)

        let cancelled = await child.state.isCancelled()
        // 落盘最新历史（剔除 system），供下次复用接续上下文；终态状态一并写入（清单展示用）。
        // 用 updateIfPresent：若期间该子代理已被 close_subagent 关闭（记录已删），不重建——
        // 防止「关闭后记录复活」竞态（关闭的语义 = 彻底移除，终态不得把它带回来）。
        let updatedHistory = child.messages.filter { $0.role != "system" }
        SubagentRuntimeRegistry.shared.updateIfPresent(sessionID: parentSessionID, record: SubagentRuntimeRecord(
            id: subID, info: info, focus: baseFocus, profile: spec.profile ?? recProfile,
            history: updatedHistory, status: cancelled ? .cancelled : .completed
        ))
        emitSubagentEvent(cancelled ? .cancelled(info) : .finished(info))

        let summary = collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return SubagentRunResult(id: subID, name: subName, body: summary.isEmpty ? String(localized: "subagent_no_content") : summary, ok: !summary.isEmpty)
    }

    /// 构造一个子代理子引擎（方案 C：不长期持有活实例，复用前重建并用历史续接上下文）。
    /// P2-4：按深度决定是否继续放行 dispatch_subagent，实现受控的多层编排。
    /// profile：子代理角色名（nil/未知 → general）。人设来自 profile 正文（完整系统提示词），
    /// 机制约束（深度/聚焦/自包含总结）由 subagentEngineSuffix 拼接。
    private func makeSubagentChild(subID: UUID, focus: String?, routingPlan: ModelRoutingPlan, profileName: String?) -> AgentLoopEngine {
        let child = AgentLoopEngine(toolRouter: toolRouter)
        child.isSubagentEngine = true
        // 子代理引擎剔除 read_subagent_result：子代理结果读取是父代理的职责，
        // 子代理间不应互相窥探（含并行/进行中的子代理），保持隔离。
        child.toolNameExclusions.insert("read_subagent_result")
        // 子代理不能关闭同级/父级子代理（隔离原则；schema 同步不注入 close_subagent）。
        child.toolNameExclusions.insert(Self.closeSubagentToolName)
        child.configure(routingPlan: routingPlan)
        child.configure(subagentRoutingPlan: subagentRoutingPlan)
        if let sampling { child.configure(sampling: sampling) }
        let childDepth = subagentDepth + 1
        child.subagentDepth = childDepth
        let canDispatchDeeper = childDepth < AgentLoopHelpers.maxSubagentDepth
        // P2-4：深度触顶由 buildToolSchemas 的 canDispatchSubagents 统一判定（硬上限），
        // 这里不再用 toolNameExclusions 控制派发权限（避免双份逻辑漂移）。
        let profile = SubAgentProfileStore.shared.profile(named: profileName)
        let systemPrompt = profile.systemPrompt + "\n\n"
            + AgentLoopHelpers.subagentEngineSuffix(focus: focus, depth: childDepth, canDispatchDeeper: canDispatchDeeper)
        child.setSystemPrompt(stable: systemPrompt, volatile: "")
        child.configure(sessionID: subID, streamingMessageID: nil)
        // 子代理 usage 转发到父引擎统计（P6）：TokenUsageTracker 只绑主引擎，
        // 不转发则子代理消耗在用量/费用统计里系统性缺失。
        child.onTokenUsage = { [weak self] report in
            self?.onTokenUsage?(report)
        }
        return child
    }

    /// 取消指定子代理（用户删除卡片时调用，P5）。命中后发取消终态事件。
    func cancelSubagent(subagentID: UUID) {
        guard activeSubagents.cancel(id: subagentID) else { return }
        if let sid = sessionID,
           let rec = SubagentRuntimeRegistry.shared.record(for: sid, subagentID: subagentID) {
            emitSubagentEvent(.cancelled(rec.info))
        }
    }

}

// MARK: - 子代理运行期类型

/// 全局子代理槽位计数（线程安全，跨多次 dispatch / 跨层级累计，P8）。
/// 包装成 @unchecked Sendable 类以通过 Swift 6 非隔离全局状态检查。
private final class SubagentSlotCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func acquire(limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }
    func release() {
        lock.lock(); defer { lock.unlock() }
        count = max(0, count - 1)
    }
}
