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
    /// [2026-09-15 缓存治本] 已经**发给过模型**的易变段快照文本。
    ///
    /// 快照落点分两处，且都必须保证「请求序列 = 上一轮 + 尾巴」这个前缀缓存前提：
    /// 1. 本轮开局：快照由 `run()` 拼进本轮 user 消息正文尾部（并经 `onTurnAPISuffixComposed`
    ///    由主会话落盘、下一轮逐字回放），这里记下它的值；
    /// 2. 轮内变化（`skill_load` 后正文进入易变段）：**在消息流末尾追加一条新的快照消息**，
    ///    绝不改写已有字节——改写会让本轮已发出的前缀全部作废。
    /// 轮内变化不落盘：下一轮的快照会重新包含已加载技能正文（`loadedSkillBodies` 按会话累积）。
    private var lastDeliveredVolatile: String = ""
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
    /// [2026-09-06 Mac 闪退修复] pendingToolExecutions 的访问锁。三类线程并发读写：
    /// 参数流式 delegate 线程（upsertStreamingToolExecution）、并行工具的多个
    /// Task.detached（executeTool 挂载/removeValue）
    /// ——Dictionary 并发写触发 COW 缓冲撕裂 → EXC_BAD_ACCESS（iPhone 窗口窄
    /// 未炸，Mac Designed-for-iPad 首次踩中）。NSLock 不可重入：锁内只做字典
    /// 取/写，emitToolExecutionBegin / beginExecution 等回调一律在锁外。
    private let pendingToolExecutionsLock = NSLock()

    /// 同步 helper（async 上下文禁直接调 NSLock.lock，经同步方法规避）：
    /// 取已有挂载或创建新执行上下文；返回 mounted=true 表示本次新建（需上抛 begin 事件）。
    private func mountPendingToolExecution(_ tc: ToolCall, name: String, startedAt: Date) -> (exec: ToolExecution, mounted: Bool) {
        pendingToolExecutionsLock.lock()
        defer { pendingToolExecutionsLock.unlock() }
        if let pending = pendingToolExecutions[tc.id] {
            return (pending, false)
        }
        let exec = ToolExecution(name: name, callID: tc.id, startedAt: startedAt)
        pendingToolExecutions[tc.id] = exec
        return (exec, true)
    }

    private func removePendingToolExecution(_ callID: String) {
        pendingToolExecutionsLock.lock()
        defer { pendingToolExecutionsLock.unlock() }
        pendingToolExecutions.removeValue(forKey: callID)
    }
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

    /// 空正文自愈已用轮数（2026-09-09）：思考完没给正文就直接 finish 时，
    /// 注入一次提示要求给出正文回答，最多 1 轮，防止「思考 3K + 空白 + 已完成」。
    private var emptyReplyRecoveryRounds: Int = 0

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

    /// [2026-09-07 HTTP 413 防线] 上下文中「工具注入的图片」最多保留张数。
    /// 真机实测：两张 1568px PNG 截图的 base64（各 ~1.6MB）即触发服务商
    /// 413 Payload Too Large；配合 apple-image 的 JPEG 降采样，3 张 ~750KB 安全。
    private static let maxInjectedToolImages = 3

    /// 注入图片超预算时，把最早的图片消息降级为文本占位（图片从上下文移除）。
    /// 以 name == "tool_image" 标识注入消息，不会误伤用户自带附件；
    /// 降级时校验消息内确有图片，防 compaction 索引错位误伤。
    private static func enforceToolImageBudget(messages: inout [ChatCompletionMessage]) {
        func isInjectedImage(_ m: ChatCompletionMessage) -> Bool {
            guard m.role == "user", m.name == "tool_image",
                  case .parts(let parts)? = m.content else { return false }
            // image_url（data URI 内联）与 file（Files API file_id）两类注入均计入预算
            return parts.contains { p in
                switch p {
                case .imageURL: return true
                case .file(_, let fileId, _): return fileId?.hasPrefix("file-api-") == true
                default: return false
                }
            }
        }
        var excess = messages.filter { isInjectedImage($0) }.count - maxInjectedToolImages
        guard excess > 0 else { return }
        for i in messages.indices where excess > 0 {
            guard isInjectedImage(messages[i]),
                  case .parts(let parts)? = messages[i].content else { continue }
            let kept = parts.compactMap { p -> ContentPart? in
                if case .imageURL = p { return nil }
                if case .file = p { return nil }  // file_id 引用移除（远端文件随 30 天过期自动清理）
                return p
            }
            let note = String(localized: "loop_tool_image_downgraded")
            messages[i].content = .parts(kept + [.text(note)])
            excess -= 1
        }
        AppLogger.shared.info("[RemoteHost] 注入图片超预算，已降级最早的工具截图", category: "RemoteHost")
    }
    /// 当前任务所属会话（检查点落盘文件名 key）。
    private var sessionID: UUID? = nil
    /// [2026-09-15 OpenAI 官方合规] 会话级路由粘性键（官方 Cookbook《Prompt Caching 201》§4.4）。
    /// 主引擎自身的请求、压缩回放调用、以及它派出的**所有子代理**共用同一个 key ⇒ 更可能落到
    /// 同一台推理机，从而复用同一份前缀缓存（子代理与主代理共享 L0 前缀，分散路由会各自冷写）。
    /// 由 `configure(sessionID:)` 取会话 id 生成；子引擎在创建处显式继承父引擎的值。
    private(set) var promptCacheKey: String?

    /// 本轮 run 的 history 对应的 session 消息 id（与 history 参数一一对应），
    /// 自动压缩成功时据此定位锚点消息，写回 session 持久层。
    private var historySourceIDs: [UUID] = []
    /// 暂停/恢复时续写的助手气泡 ID（恢复时写回同一气泡，避免第二个回复气泡）。
    private var streamingMessageID: UUID? = nil

    /// [2026-09-15 速度口径修正] 单次模型调用的生成窗口锚点：**首个生成 token → 末个生成 token**。
    ///
    /// 旧口径（run 级「正文首末字」）的分母只覆盖正文、还会把中间的工具调用/等待间隔算进去，
    /// 而分子是整轮所有迭代的 output tokens（含 reasoning）⇒ 分子分母不同源，真机实测虚高到 1373.8 tok/s。
    /// 现按业界标准（AWS AI on EKS《Key Metrics for Benchmarking LLMs》：ITL/TPOT = generation_time ÷
    /// (output_tokens − 1)，**明确排除 TTFT**）改为：窗口 = 单次调用内首个 delta → 末个 delta，
    /// 分子 = 该次调用的 output tokens；reasoning 也算生成 token（DeepSeek 的 completion_tokens 本就含它），
    /// 两端同源。每次调用（含重试）重新计时，跨调用不累加、不平均。
    private var callFirstDeltaAt: Date? = nil
    private var callLastDeltaAt: Date? = nil
    /// 最近一次上报用量所用的 modelId（供全局统计 key 复用）。
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
    /// [2026-09-15 缓存治本] 本轮 user 消息的**易变段后缀已确定**时回调（仅主会话设置）。
    ///
    /// 引擎是本轮请求字节的**唯一生产者**（见 `run()` 把后缀拼进 user 消息），主会话据此把它
    /// 连同附件提示段一起落盘为 `ChatMessage.apiContextSuffix`，下一轮 `buildHistory` 逐字回放
    /// ⇒ 请求序列保持「上一轮 + 尾巴」的纯追加结构。**不要在调用方另行拼一遍**：两处各拼一次
    /// 只要有一字节差异就会重新打断前缀缓存。
    var onTurnAPISuffixComposed: ((String) -> Void)?
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
        // 工具派发统一（2026-09-09）：子代理编排工具注册进 router，与其余工具同一条
        // schema（activity 注入）/执行/生命周期管线。子引擎共享父 router，contains 幂等；
        // 可见性由 buildToolSchemas 按角色/深度过滤，编排逻辑经 ToolEngineScope 回呼本引擎。
        if !toolRouter.contains(DispatchSubagentTool.toolName) {
            toolRouter.register(DispatchSubagentTool())
        }
        if !toolRouter.contains(CloseSubagentTool.toolName) {
            toolRouter.register(CloseSubagentTool())
        }
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

    /// 子代理编排工具名（单一事实源在 Tools/CloseSubagentTool.swift 的工具类）。
    private static let subagentToolName = DispatchSubagentTool.toolName
    private static let closeSubagentToolName = CloseSubagentTool.toolName

    func configure(routingPlan: ModelRoutingPlan) {
        self.routingPlan = routingPlan
    }

    /// 内部只读访问器：供 SubagentEngineBag 按子代理 id（= 子引擎会话 id）定位取消（P5）。
    var runtimeSessionID: UUID? { sessionID }

    /// 绑定当前任务身份：会话 ID（检查点落盘 key）与正在续写的助手气泡 ID。
    func configure(sessionID: UUID, streamingMessageID: UUID?) {
        self.sessionID = sessionID
        self.streamingMessageID = streamingMessageID
        // [2026-09-15 OpenAI 官方合规] 路由粘性键 = 会话 id（官方 Prompt Caching §4.4：
        // 按会话分组最贴合本 App 的形态——一个会话就是一条共享前缀的对话）。
        self.promptCacheKey = sessionID.uuidString
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

    /// 重算 system 易变段 = 基础易变段（ChatView 传入的挂载列表 + 时间戳）+ 本会话已加载技能正文
    /// （技能正文插在尾部「子代理段」**之前**，见下）。
    /// 已加载技能正文由 `SkillManager` 按会话隔离维护，随 `skill_load` 调用累积。
    ///
    /// [2026-09-15 缓存治本] 本函数**只做纯计算**，不再改写任何已发出的消息字节。
    /// 旧实现把结果写进 system 的 `volatileSuffix`，由适配器把易变段临时拼到请求末尾；
    /// 那条路径让请求序列失去「请求 N+1 = 请求 N + 尾巴」的嵌套结构，使服务端前缀缓存
    /// 只能命中静态前块（真机实证：命中恒为 sys+tools、历史逐轮 0 命中）。
    /// 现在的落点：本轮开局由 `run()` 把快照拼进 user 消息（并经 `onTurnAPISuffixComposed`
    /// 落盘、下一轮逐字回放）；轮内变化由 `deliverVolatileDeltaIfNeeded()` 在消息流**末尾追加**新快照。
    private func rebuildVolatile() async {
        let skills = await SkillManager.shared.loadedSkillBodies(for: sessionID)
        // 技能正文插在「子代理段」**之前**（2026-09-11）：该段（铁律 + 存活子代理短码）
        // 是易变段里变化最频繁的一节，且短码须与铁律相邻才便于取用，故必须恒定收尾。
        // 切分点 = SubAgentGuide.ironRule：与构造侧共用同一常量，任何一侧都不得复制字面量。
        let combined: String
        if skills.isEmpty {
            // 无技能正文：逐字节沿用构造侧结果，不让任何分隔符漂移扰动缓存
            //（本函数每轮 run / resume 都会走，属高频路径）。
            combined = baseVolatile
        } else if let range = baseVolatile.range(of: SubAgentGuide.ironRule) {
            // head 末尾已含构造侧 join 的 "\n\n" 连接符，故此处只需为 skills 补后置分隔符。
            let head = String(baseVolatile[..<range.lowerBound])
            let tail = String(baseVolatile[range.lowerBound...])
            combined = head + skills + "\n\n" + tail
        } else {
            // 标记缺失（构造侧未注入子代理段 / 两侧失步）：退回「技能正文追加到末尾」。
            // 不静默降级——记 warning 让失步可见，同时保证技能正文绝不丢。
            AppLogger.shared.warn(
                "[Volatile] 子代理段标记缺失，技能正文退回追加到易变段末尾",
                category: "Cache", subsystem: "Context")
            combined = [baseVolatile, skills].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        self.systemVolatile = combined
    }

    /// 轮内易变段变化 → **在消息流末尾追加**一条新的快照消息（纯追加，绝不改写已有字节）。
    ///
    /// 触发场景：`skill_load` 之后技能正文进入易变段，而本轮开局落盘的那份快照不含它。
    /// 旧实现直接改写 system 的 `volatileSuffix`（因为它本来就被临时拼在末尾，所以"就地改写"看着无害）；
    /// 现在快照已经是**已发出字节的一部分**，改写等于把本轮所有请求的前缀作废 ⇒ 必须追加。
    /// 追加位置在整批工具消息之后，不影响 `assistant(tool_calls) → tool…` 的紧邻性。
    /// 文本出参用 `APIContextSuffix.volatile`（与落盘快照同一构造点），保证格式一致。
    private func deliverVolatileDeltaIfNeeded() async {
        await rebuildVolatile()
        guard systemVolatile != lastDeliveredVolatile else { return }
        let suffix = APIContextSuffix.volatile(systemVolatile)
        guard !suffix.isEmpty else { return }
        messages.append(ChatCompletionMessage(role: "user", content: suffix))
        lastDeliveredVolatile = systemVolatile
        AppLogger.shared.info(
            "[Volatile] 轮内易变段变化 → 末尾追加快照消息（bytes=\(suffix.count)），已发前缀保持不变",
            category: "Cache", subsystem: "Context")
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
            // 主线程投递：onError 的消费方（AgentRunService）在闭包内使用
            // MainActor.assumeIsolated，若这里在非主线程直接调用即 fatalError。
            deliverOnMain { [weak self] in self?.onError?(AgentError.notConfigured) }
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

        // 速度锚点按「单次模型调用」计时（见 callFirstDeltaAt / callLastDeltaAt），
        // 这里只需清掉跨 run 残留，避免上一轮的值被当成本轮样本。
        callFirstDeltaAt = nil
        callLastDeltaAt = nil
        lastReportedModelId = ""

        // 后台任务挂钩：开始 Live Activity（若「后台运行」开启）。
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

        // 基础消息：system（**只放稳定段**）+ 历史 + 用户本轮输入。
        // [2026-09-15 缓存治本] 本轮「易变段快照」拼在本轮 user 消息**正文尾部**（不再是 system
        // 上由适配器临时追加的尾部消息），并回调主会话把它落盘、下一轮逐字回放——请求序列因此
        // 保持「上一轮 + 尾巴」的纯追加结构，服务端前缀缓存才能覆盖历史。
        await rebuildVolatile()
        let turnSuffix = APIContextSuffix.volatile(systemVolatile)
        // 记为"已送达"，使轮内 `deliverVolatileDeltaIfNeeded()` 只在易变段**真的变化**时才追加快照。
        lastDeliveredVolatile = systemVolatile
        // [2026-09-15 缓存治本·只增量、不重复] 若历史里最后一条 user 消息已经携带**逐字相同**的快照，
        // 本轮就不再重复追加一份：模型仍能从历史读到它，请求保持纯追加结构，而快照不会随轮次
        // 线性累积（否则 20 轮会话会攒下 20 份内容几乎一样的快照，白白吃上下文窗口，还会提前触发
        // 压缩——而压缩本身按官方说明必然打断缓存）。
        // 只有易变段**真的变化**（整点/记忆更新/子代理增减/挂载变化…）才产生一条新的增量。
        let lastUserText = history.last(where: { $0.role == "user" })?.content?.asText
        let alreadyInContext = turnSuffix.isEmpty || (lastUserText?.hasSuffix(turnSuffix) ?? false)
        let effectiveSuffix = alreadyInContext ? "" : turnSuffix
        // 先回调落盘再发请求：即使本轮请求失败/被取消，后缀也已经与将要发出的字节一致。
        if !effectiveSuffix.isEmpty { onTurnAPISuffixComposed?(effectiveSuffix) }
        messages = []
        if !systemStable.isEmpty {
            messages.append(ChatCompletionMessage(role: "system", content: systemStable))
        }
        messages.append(contentsOf: history)
        messages.append(ChatCompletionMessage(role: "user", messageContent: LLMClient.buildUserContent(text: userMessage + effectiveSuffix, attachments: attachments)))

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
    /// 补齐"有 tool_calls 但缺 tool 响应"的悬空消息（恢复检查点时使用）。
    private func repairDanglingToolCalls(in task: inout AgentTask) {
        guard let lastAssistantIndex = task.messages.lastIndex(where: { $0.role == "assistant" }),
              let calls = task.messages[lastAssistantIndex].toolCalls, !calls.isEmpty else { return }
        let responded = Set(task.messages[(lastAssistantIndex + 1)...].compactMap { $0.toolCallID })
        let dangling = calls.filter { !responded.contains($0.id) }
        guard !dangling.isEmpty else { return }
        for call in dangling {
            task.messages.append(ChatCompletionMessage(
                role: "tool",
                content: String(localized: "loop_tool_interrupted_on_resume"),
                toolCallID: call.id,
                name: call.function.name
            ))
        }
        AppLogger.shared.warning(
            "[Resume] repaired dangling tool_calls count=\(dangling.count)",
            category: "Agent", subsystem: "AgentLoop")
    }

    func resume(_ task: AgentTask) async {
        // 局部可变副本：恢复前需要修补悬空的 tool_calls（见 repairDanglingToolCalls）。
        var task = task
        guard let routingPlan, !routingPlan.endpoints.isEmpty else {
            // 主线程投递：onError 的消费方（AgentRunService）在闭包内使用
            // MainActor.assumeIsolated，若这里在非主线程直接调用即 fatalError。
            deliverOnMain { [weak self] in self?.onError?(AgentError.notConfigured) }
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

        // [P0-4 兜底] 旧版本可能在工具执行前落盘，尾部留下裸 `assistant(tool_calls)`。
        // 冷恢复逐字重放会缺 tool 响应 → 端点 400。进入循环前先补齐。
        repairDanglingToolCalls(in: &task)

        await state.configureRunning()

        callFirstDeltaAt = nil
        callLastDeltaAt = nil
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
        // [2026-09-15 OpenAI 官方合规·指令恒定] 检查点里的 system 是**当时**那份 stable；
        // 若期间规则/技能/角色/人格有变，恢复后这一轮会与后续所有轮次（都用当前 stable）分叉 ⇒
        // 官方 §5「Changes to instructions or system prompts」式的整段 miss。
        // 统一对齐成当前 stable，使恢复轮与后续轮次的 system 逐字节一致（另有 volatileSuffix 的
        // 旧值一并清空——快照已改为写在 user 消息里，不再走 system 的易变字段）。
        if !systemStable.isEmpty {
            if let sysIdx = messages.firstIndex(where: { $0.role == "system" || $0.role == "developer" }) {
                messages[sysIdx].content = .text(systemStable)
                messages[sysIdx].volatileSuffix = nil
            } else {
                messages.insert(ChatCompletionMessage(role: "system", content: systemStable), at: 0)
            }
        }
        // 检查点里可能不含本会话已加载技能正文（易变段，每轮重拼）：刷新易变段补回，保证恢复后模型仍看得到技能指令。
        await rebuildVolatile()
        // [2026-09-15 缓存治本] 检查点里的 messages 已含此前发出去的快照/增量（正文都在 content 里），
        // 因此把当前值记为"已送达"，避免恢复瞬间多追加一条重复快照。
        lastDeliveredVolatile = systemVolatile
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
        // 前缀缓存按「最长公共前缀」匹配。工具定义是当前请求里最大的一块
        // （真机 ≈12000 tok），因此**随角色变化的工具必须排在最后**：
        // 若它们按字母序夹在共享工具中间（如 close/read_subagent_result），
        // 其后所有工具定义都会落在不同的前缀上，主代理与子代理之间、子代理
        // 彼此之间的缓存复用全部失效。置尾后差异只影响末尾一小段。
        let routerSchemas = toolRouter.allSchemas().filter { !toolNameExclusions.contains($0.function.name) }
        // 可见性过滤（单一来源）：受限后台引擎（复盘/整理，isSubagentEngine=true 且 depth=0）
        // 不见 dispatch/close，保持"仅 memory 工具"的受限设计；子代理引擎按深度放行 dispatch。
        var visibleSchemas = routerSchemas
        if !AgentLoopHelpers.canDispatchSubagents(subagentEngine: isSubagentEngine, depth: subagentDepth) {
            visibleSchemas = visibleSchemas.filter { $0.function.name != Self.subagentToolName }
        }
        if isSubagentEngine {
            // 子代理不能关闭同级/父级，隔离原则同 read_subagent_result。
            visibleSchemas = visibleSchemas.filter { $0.function.name != Self.closeSubagentToolName }
        }
        var toolSchemas = visibleSchemas
            .filter { !Self.roleSpecificToolNames.contains($0.function.name) }
            .sorted { $0.function.name < $1.function.name }
        toolSchemas.append(contentsOf: visibleSchemas
            .filter { Self.roleSpecificToolNames.contains($0.function.name) }
            .sorted { $0.function.name < $1.function.name })
        return toolSchemas
    }

    /// 是否注入随引擎角色/深度变化的工具（排在最末尾，见 buildToolSchemas 说明）：
    /// 子代理读取（父引擎职责）与两个子代理编排工具（按角色/深度增删）。
    private static let roleSpecificToolNames: Set<String> = [
        "read_subagent_result",
        DispatchSubagentTool.toolName,
        CloseSubagentTool.toolName,
    ]

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
            // 本轮实际服务的端点（供工具图片注入判定输入模态；见工具消息组装处）
            var servedEndpoint: ModelRouteEndpoint? = nil
            // 本轮停止原因（来自 LLMClient 的 finish_reason / stop_reason），用于伪完成兜底。
            var lastFinishReason: String? = nil
            while endpointIndex < routingPlan.endpoints.count && !passSucceeded {
                guard await !state.isCancelled() else { return }
                let endpoint = routingPlan.endpoints[endpointIndex]
                servedEndpoint = endpoint
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
                    providerType: endpoint.providerType,
                    // [2026-09-15 OpenAI 官方合规] 会话级路由粘性键（官方 Prompt Caching §4.4）。
                    promptCacheKey: promptCacheKey
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
                    // [2026-09-15 速度口径修正·修 bug] **每次调用**（含每次重试）都必须重置生成窗口。
                    // 只在 run 起点重置是不够的：一轮回复里有 N 次模型调用（工具循环迭代），窗口会从
                    // 本轮首个 token 起单调增长 —— 真机实测 windowMs 1953ms → 68129ms 一路拉长、
                    // 速度被稀释到几 tok/s；而首次调用（窗口真正独立）实测 301 tok/s，才是正确量级。
                    callFirstDeltaAt = nil
                    callLastDeltaAt = nil

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
                                // [2026-09-15 速度口径修正] 正文 delta = 生成 token，打进本次调用的窗口。
                                self?.markCallDelta()
                                self?.emitToken(token)
                            },
                            onToolCall: { toolCall in
                                collectedToolCalls.append(toolCall)
                            },
                            onToolCallStreaming: { [weak self] callID, name, partialArgs, bytes in
                                // [2026-09-15 速度口径修正] 工具参数流式增量同样是模型生成的 token
                                //（计入 completion_tokens），必须进窗口；否则"纯工具轮"的调用量不到速度。
                                self?.markCallDelta()
                                self?.upsertStreamingToolExecution(callID: callID, name: name, partialArgs: partialArgs, bytes: bytes)
                            },
                            onReasoning: { [weak self] piece in
                                streamedReasoning += piece
                                // 思考 delta 同样是模型生成 token（DeepSeek 的 completion_tokens 含它），
                                // 必须一起进窗口，否则分子分母口径不同源（旧实现的病根）。
                                self?.markCallDelta()
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
                    // 重置本次调用的生成窗口：被丢弃的半截输出不计入速度样本。
                    callFirstDeltaAt = nil
                    callLastDeltaAt = nil
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
                    // [2026-09-15 速度口径修正] 本次调用的输出速度样本：
                    // **优先用到达端窗口**（适配器 GenerationTimingProbe 在 URLSession 委托队列打的时间戳，
                    // 反映真实生成过程）；拿不到时才回退到本引擎的消费端锚点（会被流缓冲压缩、精度较低，
                    // 但好过直接显示「—」）。日志里用 src= 标明这一笔用的是哪一路，便于真机核对。
                    let arrival = llmClient.lastOutputWindow
                    let speed = Self.outputSpeedSample(outputTokens: outputTokens,
                                                       arrival: arrival,
                                                       fallbackFirst: callFirstDeltaAt,
                                                       completedAt: Date())
                    // 注意：不在消息里重复写 [Speed]（AppLogger 已经输出 `[INFO] [Speed] …`）。
                    // 字段与 DSH `dsh-session-stats` 一一对应：ttft / decode / tps(=tokens÷decode)。
                    AppLogger.shared.info(
                        "\(endpoint.modelName) output=\(speed.outputTokens) ttftMs=\(speed.ttftMs.map { String(Int($0.rounded())) } ?? "—") decodeMs=\(speed.decodeMs.map { String(Int($0.rounded())) } ?? "—") tps=\(speed.tps.map { String(format: "%.1f", $0) } ?? "—") (\(speed.note), src=\(arrival != nil ? "arrival" : "fallback"))",
                        category: "Speed", subsystem: "TokenUsage")
                    emitTokenUsage(
                        endpoint.modelId,
                        inputTokens,
                        outputTokens,
                        cachedRead: cachedReadTokens,
                        cachedWrite: cachedWriteTokens,
                        ttftMs: speed.ttftMs,
                        decodeMs: speed.decodeMs
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
                // dispatch/close_subagent 已随工具派发统一注册进 router（2026-09-09），
                // registeredNames.contains 即可判定；保留名字比对仅为兼容旧检查点重放。
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
                   (fr == "length" || fr == "max_tokens"),
                   !streamedText.isEmpty || !streamedReasoning.isEmpty {
                    // 长度截断续写：把半截回复入栈再注入续写提示，最多 3 轮。
                    // [2026-09-09] 条件加上 reasoning 非空：思考型模型（DeepSeek 等）
                    // 的 reasoning 也消耗输出预算 —— 思考写满 max_tokens 时正文为空，
                    // 旧条件 `!streamedText.isEmpty` 会跳过续写直接"已完成"，
                    // 表现为「深度思考 3K 后正文消失、任务提前结束」（真机实证）。
                    messages.append(ChatCompletionMessage(role: "assistant", content: streamedText.isEmpty ? nil : streamedText, reasoningContent: streamedReasoning.isEmpty ? nil : streamedReasoning))
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
                } else if streamedText.isEmpty, !streamedReasoning.isEmpty,
                          emptyReplyRecoveryRounds < 1 {
                    // [2026-09-09] 空正文兜底：思考完没给正文就直接 finish（length
                    // 之外的 finish_reason 也会发生，如 stop）。注入一次提示要求
                    // 给出正文回答，最多 1 轮 —— 否则用户看到「思考 3K + 空白 +
                    // 已完成」，回复凭空消失。
                    emptyReplyRecoveryRounds += 1
                    messages.append(ChatCompletionMessage(role: "assistant", content: nil, reasoningContent: streamedReasoning))
                    messages.append(ChatCompletionMessage(role: "user", content: String(localized: "sys_empty_reply_continue")))
                    AppLogger.shared.warn(String(localized: "loop_empty_reply_recover"), category: "Agent", subsystem: "AgentLoop")
                    continue
                }
            }

            if validToolCalls.isEmpty && invalidToolCalls.isEmpty {
                consecutiveInvalidToolRounds = 0
                // [2026-09-11 根因修复] 纯文本收尾（含并入排队消息的续跑）此前从不把
                // 最终 assistant 回复写回 messages：主会话每轮从 SessionStore 重建
                // 历史不受影响，但子代理复用依赖 engine.messages 续接上下文
                // （runSubagent 终态持久化 history = child.messages），缺失导致复用
                // 请求出现**连续 user 消息**，模型回退作答旧任务——2026-09-11 三轮
                // 复用实测：第2轮乙、第3轮甲乙丙全部返回第1轮旧结果；[Cache指纹]
                // hist 每轮仅 +1 条（全 user、零 assistant）实锤。
                messages.append(ChatCompletionMessage(
                    role: "assistant",
                    content: streamedText.isEmpty ? nil : streamedText,
                    reasoningContent: streamedReasoning.isEmpty ? nil : streamedReasoning
                ))
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

            // [P0-4] 检查点不能在工具执行**之前**落盘：那时尾消息是裸 `assistant(tool_calls)`，
            // 冷恢复逐字重放会缺 tool 响应 → 端点 400，且重试耗尽后任务不可挽回。
            // 因此：无工具调用的轮次（尾消息是 assistant 文本）可立刻存档；
            // 有工具调用的轮次推迟到「整批 tool 消息落盘之后」（见下方 saveCheckpoint）。
            let checkpointDeferred = !validToolCalls.isEmpty
            if sessionID != nil, !checkpointDeferred {
                let pending = await state.pendingInputs()
                await saveCheckpoint(status: .running, pendingInputs: pending)
            }

            // [P0-3] 无效工具调用：不写入 assistant.tool_calls（避免空名进入请求），
            // 改为追加一条 user 备注提醒模型。但**必须等 tool 结果全部落盘之后**再追加——
            // 否则「同一轮既有合法工具又有无效工具」时顺序会变成
            // assistant(tool_calls) → user(备注) → tool，打断紧邻关系，端点直接 400。
            var invalidToolNote: ChatCompletionMessage?
            if !invalidToolCalls.isEmpty {
                let names = invalidToolCalls.map { $0.function.name.isEmpty ? String(localized: "empty_name") : $0.function.name }.joined(separator: "、")
                let note = String(format: String(localized: "loop_invalid_tool_hint"), invalidToolCalls.count, names)
                invalidToolNote = ChatCompletionMessage(role: "user", content: note)
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
            // skill_load 可能在本批次内改变了本会话已加载技能集合：刷新易变段。
            // [2026-09-15 缓存治本] 这里**只做重算**；真正的"让下一步请求看到新正文"由下方
            // 整批工具消息落盘后的 `deliverVolatileDeltaIfNeeded()` 以追加方式完成
            // （此处若 append 会把 user 消息夹进 tool_calls 与其结果之间 → 端点 400）。
            await rebuildVolatile()

            var trippedFailureCircuit: (name: String, result: ToolResult)?
            // [2026-09-11] 工具产出图片的合成 user 消息**先收集、不在循环内插入**：
            // 同一批次有多个 tool call 时，循环内插入会把 user 消息夹在两条 tool 消息之间，
            // 打断 `assistant(tool_calls) → tool…` 的紧邻关系 → 端点直接 400
            // （与同日「收敛提示」那处同类，真机已有实证）。整批 tool 消息落盘后统一追加。
            var pendingToolImageMessages: [ChatCompletionMessage] = []
            for (tc, result) in executed {
                let toolMsg = ChatCompletionMessage(
                    role: "tool",
                    content: result.text,
                    toolCallID: tc.id,
                    name: tc.function.name
                )
                messages.append(toolMsg)

                // [2026-09-07 工具图片注入] apple-image 等工具产出的 base64 图片，
                // 按当前端点的图片输入能力分流：支持 → 追加合成 user 消息（image_url
                // part，与用户附件同一条编码路径），视觉模型原生看图；不支持 → 不注入，
                // apple-vision OCR 文本兜底（纯文本模型行为与历史一致）。
                // Chat Completions 的 tool 消息不支持图片内容，合成 user 消息是各兼容
                // 端点的通用做法。**消息先入 pendingToolImageMessages，整批 tool 消息
                // 落盘后再统一追加**（见循环前说明），避免打断 tool_calls 的紧邻关系。
                if let servedEndpoint, servedEndpoint.supportsImageInput,
                   let b64 = result.data?["base64"] as? String,
                   let mime = result.data?["mime_type"] as? String, mime.hasPrefix("image/"),
                   let jpegData = Data(base64Encoded: b64) {
                    let hint = String(localized: "loop_tool_image_injected")

                    // 按官方文档分流（DeepSeek 视觉指南）：
                    // ① DeepSeek 端点 → Files API 上传拿 file_id，以 {"type":"file"}
                    //    块引用——不占 48MiB 请求体、不受 32MiB 单图内联限制
                    //    （官方对"请求体会超限"场景的推荐做法，HTTP 413 官方解法）；
                    // ② 其他端点 → image_url data URI 内联（OpenAI 兼容标准格式，
                    //    配 JPEG 降采样与注入预算）。
                    // 两者失败互相回退；预算（最多 3 张）在整批追加后统一执行。
                    var injected = false
                    if servedEndpoint.providerType == .deepSeek,
                       let baseURL = URL(string: servedEndpoint.url).map({ $0.absoluteString }),
                       let fileId = try? await DeepSeekFilesClient.uploadJPEG(
                           baseURL: baseURL, apiKey: servedEndpoint.apiKey, jpeg: jpegData) {
                        pendingToolImageMessages.append(ChatCompletionMessage(
                            role: "user",
                            messageContent: .parts([
                                .text(hint),
                                .file(fileData: nil, fileId: fileId, filename: "miniclaw-screenshot.jpg")
                            ]),
                            name: "tool_image"
                        ))
                        injected = true
                    }
                    if !injected {
                        pendingToolImageMessages.append(ChatCompletionMessage(
                            role: "user",
                            messageContent: .parts([
                                .text(hint),
                                .imageURL(url: "data:\(mime);base64,\(b64)", detail: "auto")
                            ]),
                            name: "tool_image"
                        ))
                    }
                }

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

            // 整批 tool 消息落盘后，再统一追加本轮收集到的工具图片消息（见循环前说明），
            // 并一次性执行注入预算——上下文中工具图片最多保留 3 张（HTTP 413 防线）。
            // 预算函数按 `name == "tool_image"` 扫全数组，只依赖最终状态，与调用时机无关。
            if !pendingToolImageMessages.isEmpty {
                messages.append(contentsOf: pendingToolImageMessages)
                Self.enforceToolImageBudget(messages: &messages)
            }

            // [2026-09-15 缓存治本] 易变段轮内变化（skill_load 注入技能正文）→ 在**整批工具消息之后**
            // 末尾追加快照消息。位置必须在这里：夹在 `assistant(tool_calls)` 与其 `tool` 结果之间会被
            // 端点判 400（同上一条纪律），而**改写**已有字节则会让本轮已发出的前缀全部作废。
            // 备注排在整批 tool 消息之后（P0-3），随后补上本轮检查点（P0-4）。
            if let invalidToolNote {
                messages.append(invalidToolNote)
            }
            if sessionID != nil, checkpointDeferred {
                let pending = await state.pendingInputs()
                await saveCheckpoint(status: .running, pendingInputs: pending)
            }

            await deliverVolatileDeltaIfNeeded()

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

            // ─── 提示注入（必须晚于本轮**全部工具结果**落盘）───
            // 协议铁律：`assistant(tool_calls)` 之后必须紧跟它每一个 `tool_call_id` 的
            // `tool` 响应消息。下面两条提示都是 role=user，若在工具结果之前 append，就会把
            // 这组紧邻关系打断 → 端点直接 400。真机实证（2026-09-11）：
            //   23:08:01.678 收敛提示注入 → 23:08:01.689 请求发起 → 23:08:02.462 status=400
            //   「An assistant message with 'tool_calls' must be followed by tool messages
            //    responding to each 'tool_call_id'. (insufficient tool messages following
            //    tool_calls message)」→ agent 当场停止。
            // 放在此处还有一层好处：上面两条早退路径（暂停 / 失败熔断）直接 return，
            // 正在终止的轮次不再注入提示。

            // 空转断路器警告（warn 级，仅提示不终止）
            if let reason = breakerWarnReason {
                AppLogger.shared.warn(String(format: String(localized: "loop_idle_warning"), reason), category: "Agent", subsystem: "AgentLoop")
                messages.append(ChatCompletionMessage(
                    role: "user",
                    content: String(format: String(localized: "loop_idle_system_hint"), reason)
                ))
            }

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

    /// 记录一次「模型生成了 token」的时刻（正文与思考都算：两者都是模型生成的 token）。
    private func markCallDelta() {
        let now = Date()
        if callFirstDeltaAt == nil { callFirstDeltaAt = now }
        callLastDeltaAt = now
    }

    /// 单次调用的输出速度样本：保留**原始三元组**（output token 数 / 生成窗口 / 结果），
    /// 供日志与 UI 共用——先把原始值落下来，再谈换算，避免又出现"分子分母不同源还看不出来"。
    /// [2026-09-15 DSH 对齐] 单步速度样本，字段与 `dsh-session-stats` 投影一一对应：
    /// - `ttftMs`：请求交给 URLSession → 首个**生成 token**（正文/思考/工具参数 delta）到达；
    /// - `decodeMs`：首个生成 token → **本步完成**（DSH 用 `completedTime − firstTokenTime`，
    ///   这里取 usage 结算时刻）；
    /// - `outputTokens`：本步 output tokens。
    /// 三者齐备才算有效样本（DSH 原注："counting only steps that carry both"）。
    private struct OutputSpeedSample {
        let outputTokens: Int
        let ttftMs: Double?
        let decodeMs: Double?
        var valid: Bool { ttftMs != nil && decodeMs != nil && outputTokens > 0 }
        /// 仅诊断/日志用：本步速率（tokens ÷ decodeMs），**不是**聚合展示值
        ///（聚合展示 = ΣdecodeTokens ÷ ΣdecodeMs，由 TokenUsageTracker 累计）。
        var tps: Double? {
            guard let decodeMs, decodeMs > 0, outputTokens > 0 else { return nil }
            return Double(outputTokens) / (decodeMs / 1000)
        }
        let note: String
    }

    /// 计算单步速度样本。时间锚点优先用**到达端**（`LLMClient.lastOutputWindow`，由
    /// `GenerationTimingProbe` 在 URLSession 委托队列打点）；拿不到到达端锚点时 `ttftMs` 记 nil
    /// （没有请求发起时刻就测不出首 token 延迟）⇒ 该步不计入聚合 —— 与 DSH「只统计同时带窗口与
    /// 词元数的步」一致，而不是用消费端锚点硬凑一个数。
    private static func outputSpeedSample(outputTokens: Int,
                                          arrival: LLMClient.OutputTimingWindow?,
                                          fallbackFirst: Date?,
                                          completedAt: Date) -> OutputSpeedSample {
        guard let first = arrival?.first ?? fallbackFirst else {
            return OutputSpeedSample(outputTokens: outputTokens, ttftMs: nil, decodeMs: nil, note: "无 delta 时间戳")
        }
        let decodeMs = completedAt.timeIntervalSince(first) * 1000
        guard let startedAt = arrival?.requestStartedAt else {
            return OutputSpeedSample(outputTokens: outputTokens, ttftMs: nil, decodeMs: decodeMs,
                                     note: "无请求发起时刻(消费端回退)")
        }
        let ttftMs = first.timeIntervalSince(startedAt) * 1000
        guard outputTokens > 0, decodeMs > 0 else {
            return OutputSpeedSample(outputTokens: outputTokens, ttftMs: ttftMs, decodeMs: decodeMs, note: "窗口或词元为 0")
        }
        return OutputSpeedSample(outputTokens: outputTokens, ttftMs: ttftMs, decodeMs: decodeMs, note: "ok")
    }

    private func emitTokenUsage(_ modelId: String, _ input: Int, _ output: Int, cachedRead: Int = 0, cachedWrite: Int = 0, ttftMs: Double? = nil, decodeMs: Double? = nil) {
        lastReportedModelId = modelId
        // 主引擎：顺带刷新 Live Activity 时间戳。
        if !isSubagentEngine {
            let sid = sessionID?.uuidString
            Task { await BackgroundTaskController.shared.agentDidUpdateTime(sessionID: sid) }
        }
        guard let onTokenUsage else { return }
        // 单轮调用的 词元 用量 + **本步的**速度样本（ttft / decode）一并上报；
        // 聚合由 `TokenUsageTracker` 按 DSH 口径（ΣdecodeTokens ÷ ΣdecodeMs）累计，这里不做任何换算。
        let report = TokenUsageReport(
            modelId: modelId,
            input: input,
            output: output,
            cachedRead: cachedRead,
            cachedWrite: cachedWrite,
            ttftMs: ttftMs,
            decodeMs: decodeMs,
            agentLoops: iterations
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
        var mounted = false
        pendingToolExecutionsLock.lock()
        if let pending = pendingToolExecutions[callID] {
            exec = pending
        } else {
            exec = ToolExecution(name: name, callID: callID)
            pendingToolExecutions[callID] = exec
            mounted = true
        }
        pendingToolExecutionsLock.unlock()
        if mounted { emitToolExecutionBegin(exec) }
        exec.appendArgsDelta(partialArgs)
    }

    /// 上抛执行上下文（直接引用架构的单一挂载点）。
    private func emitToolExecutionBegin(_ exec: ToolExecution) {
        guard let onToolExecutionBegin else { return }
        deliverOnMain { onToolExecutionBegin(exec) }
    }

    private func emitComplete(replyText: String) {
        // [2026-09-15 速度口径修正] 输出速度改为「单次调用」口径，已在各次 emitTokenUsage 上报，
        // 不再在 run 结束时结算「正文首末字跨度」（旧口径分子分母不同源）。
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
        // run 结束（出错）：输出速度已在各次 emitTokenUsage 按「单次调用」口径上报，此处无需再结算。
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
        // run 中断：输出速度已在各次 emitTokenUsage 按「单次调用」口径上报，此处无需再结算。
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
    ///
    /// [2026-09-15 OpenAI 官方合规·避免 naive truncation] 官方 Prompt Caching 把
    /// 「Naive truncation from hitting the models' context window」明确列为低命中原因：
    /// 「每轮只砍掉最旧一条」会让**历史的开头每轮都变** ⇒ 前缀从第一条起整段失效。
    /// 官方对同一问题（Realtime 的上下文裁剪）给的解法是 `truncation: retention_ratio` ——
    /// **一次性砍掉一大块**，换取更长的稳定期。此处照此办理：一旦确实需要裁剪，就按
    /// `trimRetentionRatio` 多留出余量，使后续若干轮不再触发裁剪。
    /// 代价与官方文档所述一致：单次会多丢一些旧历史。
    private static let trimRetentionRatio = 0.7

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

        /// 从最新往前收集到 `limit` 为止；tool_call 与其 tool 结果必须整对保留。
        /// 返回是否发生了裁剪（未裁剪 = 全部正文消息都留下来了）。
        func select(limit: Int) -> (kept: [ChatCompletionMessage], trimmed: Bool) {
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
                   used + cost > limit,
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
            let bodyCount = messages.filter { $0.role != "system" && $0.role != "developer" }.count
            return (result.reversed().map { $0 }, result.count < bodyCount)
        }

        // 第一趟按真实预算收集：**没触发裁剪就直接返回**（绝大多数轮次走这条，前缀不受影响）。
        var picked = select(limit: budget)
        if picked.trimmed {
            // 已触发裁剪 ⇒ 一次多留余量（retention ratio），避免「每轮砍一条」反复打断前缀。
            picked = select(limit: max(1_000, Int(Double(budget) * Self.trimRetentionRatio)))
            AppLogger.shared.info(
                "[Trim] 硬裁剪按官方 retention-ratio 思路一次性大步长（\(Self.trimRetentionRatio)）：保留正文 \(picked.kept.count) 条，避免每轮微调前缀",
                category: "Cache", subsystem: "Context")
        }

        var final = picked.kept
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
        // /compact 标志同为会话级（pendingManualCompact，2026-09-08）：空闲预约也生效。
        let (forceCompress, cooldownOK, turn) = await MainActor.run {
            guard let sid = sessionID else { return (false, true, 0) }
            let flag = AppState.shared.pendingManualCompact.remove(sid) != nil
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
                await MainActor.run {
                    AppState.shared.sessionLastCompressionTurn[sid] = turn
                    // 预约已被消费但压缩失败（对话过短/摘要为空）：同步移除"已预约压缩"
                    // 横幅，避免横幅挂着却永远不会执行（2026-09-08）。
                    if let session = SessionManager.shared.session(id: sid) {
                        let scheduledText = String(localized: "compact_scheduled_indicator")
                        session.messages.removeAll { $0.role == .system && $0.content == scheduledText }
                    }
                }
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
            // /compact 预约横幅功成身退（2026-09-08）：压缩已完成，移除"已预约压缩"提示，
            // 完成态由下方插入的"已自动压缩"横幅承担（否则两条语义矛盾横幅常驻）。
            let scheduledText = String(localized: "compact_scheduled_indicator")
            session.messages.removeAll { $0.role == .system && $0.content == scheduledText }
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
                providerType: endpoint.providerType,
                // [2026-09-15 OpenAI 官方合规] 压缩调用**回放同一前缀**，用同一 key 才能落到同一台
                // 推理机、复用已缓存前缀（否则路由分散会让这次回放白付全价）。
                promptCacheKey: promptCacheKey
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
    /// 对当前会话的子代理做大小写不敏感前缀匹配，唯一命中才返回
    /// （多命中/零命中返回 nil，让模型收到明确错误而非误关）。
    /// 批量关闭（subagent_ids）复用本函数逐个解析。
    ///
    /// 2026-09-10 治本：**解析源必须与注入给模型的「当前会话的子代理」清单同源**
    /// ——此前读 `SubagentStore.avatars`（UI 头像卡片），而清单来自
    /// `SubagentRuntimeRegistry`，两者数据可能不一致：清单里有、卡片里没有时
    /// 短码恒解析失败，模型看着清单反复关、次次报「需要有效的 subagent_id」
    /// （三子代理测试实证：5 次调用全失败直至熔断）。Registry 带 lock 且是幂等
    /// 关闭的唯一依据（remove 后即解析不到 → 自然报「已关闭，无需重复」）。
    @MainActor
    private func prefixResolveSubagentToken(_ token: String, sessionID: UUID) async -> UUID? {
        let short = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard short.count >= 4, UUID(uuidString: token) == nil else { return nil }
        let matches = SubagentRuntimeRegistry.shared.allRecords(for: sessionID)
            .filter { $0.id.uuidString.lowercased().hasPrefix(short) }
            .map(\.id)
        if matches.count == 1 { return matches[0] }
        // [2026-09-11 跨启动水合] Registry MISS ≠ 子代理不存在：Store 的卡片/对话
        // 持久且 UI 常驻，历史里的旧短码据此水合回 Registry（否则 MISS → 静默新建，
        // 同一子代理每轮变成不同新实例——2026-09-11 三轮复测实锤）。唯一前缀匹配才水合。
        guard matches.isEmpty,
              let rec = await SubagentRuntimeRegistry.rehydrateFromStore(sessionID: sessionID, subagentIDToken: short) else { return nil }
        SubagentRuntimeRegistry.shared.upsert(sessionID: sessionID, record: rec)
        AppLogger.shared.info(
            "[SubagentDispatch] token=\(short) → 自 Store 水合 \(rec.id.uuidString.prefix(8))（跨启动续接）",
            category: "Agent", subsystem: "Subagent")
        return rec.id
    }

    private func executeTool(_ tc: ToolCall) async -> ToolResult {
        let rawName = tc.function.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 防御：name 为空或未注册时直接返回明确错误，不抛异常导致循环中断
        guard !rawName.isEmpty else {
            AppLogger.shared.error(String(format: String(localized: "loop_empty_fn_rejected"), tc.id), category: "Agent", subsystem: "ToolRouter")
            return ToolResult(success: false, text: String(localized: "err_tool_call_no_name"))
        }
        // [ToolForensics] 取证（唐唐 2026-09-05，只进 Xcode 控制台不进 App 日志）：
        // 覆盖 shell_execute 与两个子代理编排工具。
        if rawName == "shell_execute" || rawName == Self.subagentToolName || rawName == Self.closeSubagentToolName {
            NSLog("[ToolForensics] name=%@ callID=%@ rawArgs=%@", rawName, tc.id, tc.function.arguments)
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
        (exec, isNewExecution) = mountPendingToolExecution(tc, name: rawName, startedAt: startedAt)
        // 参数定稿必须在挂载之前：子代理转发（child.onToolExecutionBegin）会读
        // exec.argsJSON 构造 ToolCallEvent，挂载时参数为空会导致工具卡参数显示空白。
        // 主线不受影响（参数流式期已挂载，挂载侧只读 position，参数由 block 实时刷新）。
        exec.beginExecution(argsJSON: tc.function.arguments)
        if isNewExecution {
            emitToolExecutionBegin(exec)
        }

        // ── 带超时可取消的工具执行：默认单工具 120s，长时编排工具（dispatch_subagent）不限时 ──
        // 工具与超时竞速 + 用户取消/暂停三方竞争，任一触发立即返回。
        // [Fix 2026-08-11 并发工具崩溃] execTask 按 callID 注册进 ToolTaskBag
        // （NSLock 保护），确保 pause/cancel 能取消真正的工作（枚举全部 in-flight）。
        // 关键修复：工具的真实同步逻辑（图片 OCR/分类、文件读取、记忆落盘等）原本随
        // executeTool 所在的 MainActor 上下文在主线程执行，遇到重工具会把主线程夯 30~50s，
        // 被 iOS 看门狗强杀（见崩溃日志 MAIN THREAD BLOCKED 39.9s/51.6s）。
        // 改为 detached 任务，让工具体在后台线程跑；引擎内部所有 UI 回调统一经
        // deliverOnMain（main.async，FIFO）回到主线程，不影响界面刷新，也不再同步等待主线程。
        let toolTimeout = toolRouter.executionTimeout(for: rawName)
        let execTask: Task<ToolResult, Never> = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                return ToolResult(success: false, text: String(localized: "err_engine_released"))
            }
            // 若 pause/cancel 在 Task 创建与赋值之间触发，此处快速退出。
            guard !Task.isCancelled else {
                return ToolResult(success: false, text: String(localized: "err_user_paused_cancelled"))
            }
            // 在闭包内重建参数，避免捕获外部非 Sendable 的 [String:Any]。
            // [P2-7] 参数 JSON 非法时**不能**降级成空字典：那样模型只会收到
            // "缺少 path/command"，于是原样重发同一段坏 JSON，两次同签名失败即触发熔断。
            // 直接把"参数不是合法 JSON"回给模型，它才有机会改正。
            let parsedArgs = tc.function.arguments.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            guard let innerArgs = parsedArgs else {
                return ToolResult(
                    success: false,
                    text: String(format: String(localized: "loop_bad_tool_arguments"), rawName, String(tc.function.arguments.prefix(200)))
                )
            }
            do {
                // 引擎作用域：引擎保留工具（dispatch/close_subagent）经 ToolEngineScope
                // 解析当前执行引擎（router 被父子引擎共享，不能靠固定 weak 引用）。
                // 浏览器作用域：子代理引擎用自身 subID（独立浏览器上下文），主引擎回落父会话。
                let browserScope = self.isSubagentEngine ? self.sessionID : nil
                // 过程流上报通道：TaskLocal 注入的 reporter 直达执行上下文，
                // appendOutputLine 内部做行缓冲 + 节流 + 回主线程写 block。
                let reporter: @Sendable (String) -> Void = { line in
                    exec.appendOutputLine(line)
                }
                return try await ToolEngineScope.$box.withValue(EngineBox(self)) {
                    try await ToolProgressScope.$reporter.withValue(reporter) {
                        try await EngineBrowserScope.$sessionID.withValue(browserScope) {
                            try await self.toolRouter.execute(name: rawName, parameters: innerArgs)
                        }
                    }
                }
            } catch {
                if Task.isCancelled {
                    return ToolResult(success: false, text: String(format: String(localized: "loop_tool_interrupted"), rawName))
                }
                return ToolResult(success: false, text: "Error: \(error.localizedDescription)")
            }
        }
        // [Fix 2026-08-11 并发工具崩溃] 按 callID 注册到集合(NSLock 保护):
        // 并发工具各自写自己的槽位,不再竞争单一共享属性;pause/cancel 枚举全部取消。
        toolExecutionTasks.insert(tc.id, task: execTask)
        // [Fix 2026-11-12 I-02] 超时不再用 withTaskGroup 与工具竞速：
        // group 退出前会隐式 await 所有子任务，而工具可能挂死在不可取消的
        // withCheckedContinuation 上（HomeKit/Location/HealthKit…）⇒ 即使超时分支
        // 先返回，executeTool 也永不返回。改为「超时先定稿并取消工具任务」：
        // 超时结果立即返回；工具侧自带超时的兜底另行按 ISSUES I-02 收口。
        let result: ToolResult
        if let toolTimeout {
            result = await withCancellableTimeout(
                seconds: toolTimeout,
                onTimeout: {
                    execTask.cancel()
                    return ToolResult(
                        success: false,
                        text: String(format: String(localized: "loop_tool_timeout"), rawName)
                    )
                },
                work: { await execTask.value }
            )
        } else {
            result = await execTask.value
        }
        toolExecutionTasks.remove(tc.id)

        let duration = Date().timeIntervalSince(startedAt)
        exec.finish(result, duration: duration)
        // 执行已落定，出表：一个 callID 只执行一次，注册表仅用于「参数流式期 → 执行期」
        // 的上下文传递，留着会让长会话多轮循环持续累积（引擎销毁前不释放）。
        // 执行已落定，出表：一个 callID 只执行一次，注册表仅用于「参数流式期 → 执行期」
        // 的上下文传递，留着会让长会话多轮循环持续累积（引擎销毁前不释放）。
        removePendingToolExecution(tc.id)
        AppLogger.shared.crisisMark("TOOL DONE: \(rawName) (\(Int(duration * 1000))ms)")
        return result
    }

    // MARK: - 子代理派发

    private func emitSubagentEvent(_ event: SubagentEvent) {
        guard let onSubagentEvent else { return }
        deliverOnMain { onSubagentEvent(event) }
    }

    /// 派发子代理（DispatchSubagentTool 经 ToolRouter 统一管线执行后回呼至此）。
    /// 复用同一套循环与模型路由，但使用独立的上下文与受约束的工具清单；
    /// 结束后把子代理最终回答作为父循环的工具结果回传。
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
    func dispatchSubagent(args: [String: Any]) async -> ToolResult {
        // 硬深度守卫：不依赖 schema 过滤（模型可能幻觉直调），执行前校验深度上限，
        // 触顶直接返回错误结果（模型收到明确提示），杜绝无限递归派发。
        guard AgentLoopHelpers.canDispatchSubagents(subagentEngine: isSubagentEngine, depth: subagentDepth) else {
            return ToolResult(success: false, text: String(format: String(localized: "loop_subagent_depth_error"), AgentLoopHelpers.maxSubagentDepth))
        }
        guard let parentPlan = routingPlan else {
            return ToolResult(success: false, text: String(localized: "err_subagent_no_route"))
        }
        let childPlan = subagentRoutingPlan ?? parentPlan

        let specs = AgentSubagentParsing.parseSubagentSpecs(from: args)
        guard !specs.isEmpty else {
            return ToolResult(success: false, text: String(localized: "err_dispatch_need_task"))
        }

        let parentSessionID = self.sessionID ?? UUID()

        // 复用标识兜底解析（2026-09-10）：清单只展示 8 位短码、close_subagent 也按短码解析，
        // 而 dispatch 的 subagent_id 原先只认完整 UUID（解析失败即静默新建）——三处口径
        // 不一致导致「照抄短码续派 = 新建子代理」，模型观察到"返回的 id 是全新的"。
        // 统一走与 close 同一套前缀规则（Registry 单一事实源）。
        var resolvedSpecs = specs
        for i in resolvedSpecs.indices where resolvedSpecs[i].reuseID == nil {
            guard let token = resolvedSpecs[i].reuseToken else { continue }
            let hit = await prefixResolveSubagentToken(token, sessionID: parentSessionID)
            resolvedSpecs[i] = resolvedSpecs[i].withReuseID(hit)
            // [2026-09-11 降噪] 命中复用是正常路径 → info（不镜像控制台）；
            // 只有解析失败（MISS=新建）才值得 WARN 提醒短码/UUID 口径不一致。
            if let hit {
                AppLogger.shared.info(
                    "[SubagentDispatch] reuse token=\(token) → \(hit.uuidString.prefix(8))",
                    category: "Agent", subsystem: "Subagent"
                )
            } else {
                AppLogger.shared.warn(
                    "[SubagentDispatch] reuse token=\(token) → MISS(新建)",
                    category: "Agent", subsystem: "Subagent"
                )
            }
        }

        // 单任务：保持既有串行路径（无并发开销、事件顺序与旧版一致）。
        if resolvedSpecs.count == 1 {
            let r = await runSubagent(spec: resolvedSpecs[0], parentSessionID: parentSessionID, plan: childPlan)
            return ToolResult(success: true, text: r.rendered)
        }

        // 并行多任务（P2-4）：受 maxParallelSubagents 限制，超出部分截断并在结果里说明。
        let limited = Array(resolvedSpecs.prefix(maxParallelSubagents))
        let dropped = resolvedSpecs.count - limited.count
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
            text += String(format: String(localized: "loop_parallel_dropped"), resolvedSpecs.count, maxParallelSubagents, dropped)
        }
        return ToolResult(success: true, text: text)
    }

    /// 关闭子代理（CloseSubagentTool 经 ToolRouter 统一管线执行后回呼至此）。
    /// 仅父引擎可调（schema 已按角色过滤；执行级再兜底一次——
    /// 子代理可能幻觉直调，若放行会误删兄弟子代理并销毁其浏览器上下文）。
    /// 支持批量：subagent_id 单个 / subagent_ids 数组，逐个关闭并汇总结果。
    func closeSubagents(args: [String: Any]) async -> ToolResult {
        guard !isSubagentEngine else {
            return ToolResult(success: false, text: String(localized: "err_subagent_no_close_perm"))
        }
        guard let parentSID = sessionID else {
            return ToolResult(success: false, text: String(localized: "err_engine_no_session"))
        }
        // 收集待关闭目标（去重保序；单个/批量/混用皆可）。
        let tokens = CloseSubagentTool.parseSubagentTokens(args)
        guard !tokens.isEmpty else {
            // 失败文案附带存活清单（2026-09-05）：此前通用错误让模型以为格式错误，
            // 对已关闭的子代理反复重试直至熔断——附上清单即打破循环。
            // 2026-09-10：清单源改用 SubagentRuntimeRegistry，与提示词注入的
            // 「当前会话的子代理」清单、与短码解析源三者同源（此前用 Store 头像卡片，
            // 与清单不一致时清单里有的 id 解析不到，模型陷入重试循环）。
            let live = SubagentRuntimeRegistry.shared.allRecords(for: parentSID)
                .map { "`\($0.id.uuidString.prefix(8))`（\($0.info.name)）" }
                .joined(separator: "、")
            let text = live.isEmpty
                ? String(localized: "err_close_subagent_need_id") + "\n" + String(localized: "err_close_subagent_none")
                : String(localized: "err_close_subagent_need_id") + "\n" + String(format: String(localized: "err_close_subagent_live_list"), live)
            return ToolResult(success: false, text: text)
        }
        // 逐个解析 + 关闭：精确 UUID 优先，短码按当前会话唯一前缀匹配。
        var okCount = 0
        var failCount = 0
        var lines: [String] = []
        // 诊断（2026-09-10 三子代理测试）：一次性打印三方数据，用于判定
        // 「清单/解析/存在性」三处是否已同源——此前短码全解析失败的根因靠它定位。
        AppLogger.shared.warn(
            "[SubagentClose] sid=\(parentSID.uuidString.prefix(8)) tokens=\(tokens.joined(separator: ",")) "
            + "registry=\(SubagentRuntimeRegistry.shared.allRecords(for: parentSID).count) "
            + "cards=\(await MainActor.run { SubagentStore.shared.avatars(for: parentSID).count })",
            category: "Agent", subsystem: "Subagent"
        )
        for token in tokens {
            let id: UUID?
            if let exact = UUID(uuidString: token) {
                id = exact
            } else {
                id = await prefixResolveSubagentToken(token, sessionID: parentSID)
            }
            guard let subagentID = id else {
                // 2026-09-10：短码未命中时先查「最近关闭」——核实性重复关闭（模型对
                // 刚关闭的 id 再 close 一次确认）此前落到这里，收到「需要有效的
                // subagent_id」的误导错误，模型只能编故事解释（三子代理测试安排实证）。
                if let closedID = SubagentRuntimeRegistry.shared.recentlyClosedID(for: parentSID, token: token) {
                    okCount += 1
                    lines.append("✅ " + String(format: String(localized: "subagent_already_closed"), closedID.uuidString))
                    continue
                }
                failCount += 1
                lines.append("❌ \(token): " + String(localized: "err_close_subagent_need_id"))
                continue
            }
            let (closed, alreadyClosed, text) = await SubagentLifecycle.close(sessionID: parentSID, subagentID: subagentID, cancel: { [weak self] id in
                self?.cancelSubagent(subagentID: id)
            })
            // 幂等语义：alreadyClosed（目标本就处于已关闭态）同样算「目标达成」。
            if closed || alreadyClosed { okCount += 1 } else { failCount += 1 }
            lines.append("\(closed || alreadyClosed ? "✅" : "❌") \(text)")
        }
        // 格式符为 %1$d/%2$d —— 必须传 Int（2026-09-10 修复：此前传 String，
        // 指针低 32 位被当整数打印，模型看到「1245914821 成功」这类垃圾数字，
        // 无法判断成败进而反复重试直至熔断；且属 UB，可崩溃）。
        let header = String(format: String(localized: "close_batch_summary"), okCount, failCount)
        // 部分成功也算成功：已关闭的信息对模型有用，全失败才判失败。
        return ToolResult(success: failCount < tokens.count, text: header + "\n" + lines.joined(separator: "\n"))
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

        // 预热信号按端点区分：缓存是服务商账号维度的，不同 modelId 各自预热。
        let warmKey = plan.endpoints.first?.modelId ?? "default"
        child.onToken = { [weak self] piece in
            collector.append(piece)
            // 首个 token = 本轮请求已被服务端处理，共享前缀大概率已写入缓存
            // → 放行其余并行子代理（见 SubagentWarmupGate）。
            Task { await SubagentWarmupGate.shared.markWarm(endpointKey: warmKey) }
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
            // 预热信号补位：子代理首轮可能直接调工具、一个文本 token 都不出，
            // 此时 onToken 不触发，等待者只能等满超时。工具调用同样说明请求
            // 已被服务端处理 → 共享前缀已写入，可放行其余并行子代理。
            Task { await SubagentWarmupGate.shared.markWarm(endpointKey: warmKey) }
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
        //
        // 并行错峰：缓存写入有秒级延迟，一批子代理同时发起会各自冷写共享前缀。
        // 第一个立即跑并负责预热，其余等首个 token（或超时）后放行。
        await SubagentWarmupGate.shared.enter(endpointKey: warmKey)
        await child.run(userMessage: task, history: baseHistory, forceThinkingLevel: childThinking)

        activeSubagents.remove(child)
        // 本子代理结束：若它是预热者，释放领导权（已 warm 的会保留 warmUntil）。
        await SubagentWarmupGate.shared.relinquishLead(endpointKey: warmKey)

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
        // close/dispatch 的可见性由 buildToolSchemas 按 isSubagentEngine/深度统一过滤（单一来源）。
        child.configure(routingPlan: routingPlan)
        child.configure(subagentRoutingPlan: subagentRoutingPlan)
        if let sampling { child.configure(sampling: sampling) }
        let childDepth = subagentDepth + 1
        child.subagentDepth = childDepth
        let canDispatchDeeper = childDepth < AgentLoopHelpers.maxSubagentDepth
        // P2-4：深度触顶由 buildToolSchemas 的 canDispatchSubagents 统一判定（硬上限），
        // 这里不再用 toolNameExclusions 控制派发权限（避免双份逻辑漂移）。
        let profile = SubAgentProfileStore.shared.profile(named: profileName)
        // 前缀分层（2026-09-06 子代理缓存命中治理）：
        //   [共享前缀 L0] → [角色人设 profile] → [静态机制段]  ‖  [易变：focus/深度]
        // L0 与主代理逐字节一致 → 主/子、子/子共享同一段 KV 缓存前缀；
        // focus 与深度是实例信息，必须沉到 volatile，否则每个子代理前缀都不同。
        let systemPrompt = [
            AgentPromptCore.sharedPrefix,
            profile.systemPrompt,
            AgentLoopHelpers.subagentStaticRules
        ].joined(separator: "\n\n")
        let volatile = AgentLoopHelpers.subagentInstanceSection(
            focus: focus,depth: childDepth,canDispatchDeeper: canDispatchDeeper)
        child.setSystemPrompt(stable: systemPrompt,volatile: volatile)
        child.configure(sessionID: subID, streamingMessageID: nil)
        // [2026-09-15 OpenAI 官方合规] 子代理**继承父会话的路由粘性键**：子代理与主代理共享 L0
        // 前缀，只有落到同一台推理机才能复用那份缓存（各自换 key 会把共享前缀拆散到不同机器）。
        child.promptCacheKey = promptCacheKey
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
