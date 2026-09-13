import Foundation
import Combine

/// 排队中的用户消息：智能体回复进行中用户继续发送的内容先进此队列，以虚线气泡展示，
/// 待当前回复完成后按 FIFO 逐条转为真实消息并触发新一轮回复。
///
/// 需 `Codable`：整个队列会作为单一真源落盘到 `PendingMessageStore`，
/// 使排队消息在杀后台 / 退出会话 / App 重启后仍能恢复（`id` 亦持久化，保证按 id 删除/提升不串）。
struct PendingUserMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    /// 随消息一起入队的附件（本地文件路径数组，指向 attachments/ 目录内的副本）。
    /// 新字段：旧磁盘数据无此 key 时由自定义解码回退为空数组，保证向后兼容。
    var attachments: [String] = []
    /// 若为技能指令（/技能名）入队，记录技能名以在出队时一次性注入 system prompt。
    var skillName: String? = nil
    /// 深链派任务（P1-4 x-callback-url）携带的回跳地址：本消息出队并触发回复后，
    /// 由该轮引擎终态（onComplete/onError/onInterrupted）回调对应 x-success / x-error。
    /// 入队时不立即回跳，而是绑定到真正处理这条消息的那一轮运行（避免前序消息跑完误触发）。
    var dlXSuccess: URL? = nil
    var dlXError: URL? = nil

    /// 仅当携带了 x-callback 地址时返回非 nil，供出队时传给 startAgentResponse。
    var deepLinkCallback: (xSuccess: URL?, xError: URL?)? {
        guard dlXSuccess != nil || dlXError != nil else { return nil }
        return (dlXSuccess, dlXError)
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, attachments, skillName, dlXSuccess, dlXError
    }

    init(text: String, attachments: [String] = [], skillName: String? = nil,
         dlXSuccess: URL? = nil, dlXError: URL? = nil) {
        self.id = UUID()
        self.text = text
        self.attachments = attachments
        self.skillName = skillName
        self.dlXSuccess = dlXSuccess
        self.dlXError = dlXError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
        skillName = try c.decodeIfPresent(String.self, forKey: .skillName)
        // decodeIfPresent：升级前落盘的队列无此二键，硬 decode 会让整个排队队列静默丢失。
        dlXSuccess = try c.decodeIfPresent(URL.self, forKey: .dlXSuccess)
        dlXError = try c.decodeIfPresent(URL.self, forKey: .dlXError)
    }
}

/// 会话级运行时：持有某个会话正在进行的 `AgentLoopEngine` 与流式缓冲区。
///
/// 它存活于 `AppState.chatRuntimes`（key = session.id），生命周期与「一次 智能体回复」绑定：
/// 开始回复时创建并登记，回复完成 / 出错 / 用户停止时从字典移除。
///
/// 之所以把这些状态从 `ChatView` 的 `@State` 提升到这里，是为了解决：
/// 用户在 智能体回复过程中返回首页再回到该会话 → `ChatView` 实例被销毁重建、`@State` 清空，
/// 导致「响应中」状态丢失、无法停止那个仍在后台运行的引擎。
/// 现在 `ChatView` 重建后可直接从 `AppState` 认领同一个运行时，实现无缝接管。
@MainActor
final class ChatSessionRuntime: ObservableObject, @MainActor Identifiable {
    /// 所属会话 ID（同时用作 `AppState.chatRuntimes` 的 key）
    let sessionID: UUID
    /// 正在执行本轮回复的引擎（`ChatView` 通过它执行 `cancel()`）
    let engine: AgentLoopEngine

    /// 取消指定子代理（转发到引擎，P5：删除卡片时同步停止运行中的子代理）。
    func cancelSubagent(subagentID: UUID) {
        engine.cancelSubagent(subagentID: subagentID)
    }
    /// 当前正在流式输出的助手消息 ID（nil 表示无活跃流）
    @Published var streamingMessageID: UUID?
    /// 统一重试状态（非 nil = 显示重试指示器）：retrying 进行中 / exhausted 最终失败。
    /// 首个成功输出 词元 到达时由 AgentRunService 清空。
    @Published var retryState: RetryState?
    /// 流式文本缓冲区（引用类型，跨 `ChatView` 重建存活）
    @Published var streamingContent: String = ""
    /// 节流缓冲：每个 词元 先追加进 `pendingText`，由 ~100ms 定时器批量提交到
    /// `streamingContent`，把「每 词元 一次主线程重绘」降到约 10fps，消除流式期卡顿。
    @Published var pendingText: String = ""
    /// 节流调度标志：避免每个 词元 都起一个 sleep 任务，仅在一个批次窗口内起一次。
    private var flushScheduled = false
    /// 直接引用架构的执行注册表（挂载顺序即展示顺序）；
    /// ToolExecution 内持 AssistantBlock 引用，UI 经 @ObservedObject block 自驱动刷新。
    @Published var streamingToolExecutions: [ToolExecution] = []
    private var streamingToolOrders: [String: Double] = [:]

    /// 挂载执行上下文（幂等：同 callID 只挂一次）。
    func registerStreamingToolExecution(_ exec: ToolExecution, order: Double) {
        guard streamingToolExecutions.first(where: { $0.callID == exec.callID }) == nil else { return }
        streamingToolExecutions.append(exec)
        streamingToolOrders[exec.callID] = order
    }

    /// 执行的展示顺序（挂载时分配）。
    func order(for callID: String) -> Double {
        streamingToolOrders[callID] ?? 0
    }

    /// 流式执行转持久化事件（position/timelineOrder 取挂载时分配的值）。
    /// 落盘与渲染的唯一转换入口——各处不得自行 map，避免漏改或顺序口径不一致。
    var streamingToolEvents: [ToolCallEvent] {
        streamingToolExecutions.map { exec in
            exec.toEvent(position: exec.position, timelineOrder: Int(order(for: exec.callID)))
        }
    }
    /// 流式过程中的分段思考过程（reasoning）缓冲区（引用类型，跨 `ChatView` 重建存活）。
    /// 按引擎迭代轮次（iterations）切片，每段独立展示、穿插在正文/工具之间。
    /// 仅用于实时展示，不写入磁盘、不回灌上下文。
    @Published var streamingReasoningSegments: [ReasoningSegment] = []
    /// 思考（reasoning）节流缓冲：每个 reasoning 词元 先按迭代轮次追加进这里，
    /// 由与正文共享的 ~100ms 调度窗口批量刷入 `streamingReasoningSegments`，把每 词元 一次的重绘降到约 10fps。
    private var pendingReasoning: [(piece: String, iteration: Int)] = []
    /// 全局时间线序号计数器：每次创建新的思考段或工具调用时递增，
    /// 用于渲染时按真实发生顺序交错排列（而非按 position 堆叠）。
    @Published var nextTimelineOrder: Int = 1

    // MARK: - 轮次安全锚点（2026-09-09 重试保内容）
    //
    /// 「最近安全点」快照：每个工具开始挂载时记录。重试 / 最终失败时回滚到该锚点
    /// —— **已完成轮次的内容（历史正文/思考/工具）全部保留**，只丢弃当前轮的
    /// 半截输出。此前重试清空整个 runtime 状态：HTTP 402/网络错误重试 5 次全挂
    /// → 中断前所有 loop 内容从 UI 和落盘里一起消失（真机实证 onError 落盘
    /// content=23字，只剩错误提示文案）。
    struct RoundAnchor {
        let contentCount: Int     // streamingContent 保留前缀长度
        let order: Int            // nextTimelineOrder 回滚值（锚点后号段可复用）
        let segmentCount: Int     // 保留前 N 个思考段
        let toolCount: Int        // 保留前 N 个工具执行
    }
    private var roundAnchor: RoundAnchor?

    /// 在每个工具开始挂载前调用：此刻之前的所有流式内容（历史轮 + 本轮已流出
    /// 正文/思考）都已安全 —— 本轮重试只丢弃锚点之后的半截输出。
    func markRoundSafePoint() {
        commitStreamBuffer()
        commitReasoningBuffer()
        // [2026-09-13 轮次分隔符] 轮次边界：下一段正文前插一个空行（见 `needsRoundSeparator`）。
        // 每次工具挂载前都会调本函数 ⇒ 同一轮内多次调用是幂等的（只置位一次）。
        needsRoundSeparator = true
        roundAnchor = RoundAnchor(
            contentCount: streamingContent.count,
            order: nextTimelineOrder,
            segmentCount: streamingReasoningSegments.count,
            toolCount: streamingToolExecutions.count)
    }

    /// 回滚到最近安全点：截断当前轮半截输出（正文截断回锚点长度、移除锚点后的
    /// 思考段/工具执行），保留全部已完成轮次内容。无锚点时不做任何事。
    func rollbackToRoundSafePoint() {
        commitStreamBuffer()
        commitReasoningBuffer()
        // [2026-09-13 轮次分隔符] 回滚后重试的那一段仍然处于"轮次边界"⇒ 重新置位，
        // 否则重试成功的正文会直接接在被截断的内容后面（同一处粘连问题的另一种形态）。
        // 无锚点分支把 `streamingContent` 清空 ⇒ 消费时 `isEmpty` 成立、自然不插。
        needsRoundSeparator = true
        guard let a = roundAnchor else {
            // [2026-09-11 审计修复] 首个工具挂载前 = 没有任何「已安全」内容：
            // 首轮流式半截失败必须整段丢弃，否则重试成功后新 token 接在半截之后
            // 重复落盘（引擎侧 streamedText 已清、runtime 侧未清的口径分裂）。
            streamingContent = ""
            streamingReasoningSegments.removeAll()
            streamingToolExecutions.removeAll()
            streamingToolOrders.removeAll()
            nextTimelineOrder = 1
            pendingText = ""
            pendingReasoning.removeAll()
            return
        }
        if streamingContent.count > a.contentCount {
            streamingContent = String(streamingContent.prefix(a.contentCount))
        }
        if streamingReasoningSegments.count > a.segmentCount {
            streamingReasoningSegments.removeLast(streamingReasoningSegments.count - a.segmentCount)
        }
        if streamingToolExecutions.count > a.toolCount {
            streamingToolExecutions.removeLast(streamingToolExecutions.count - a.toolCount)
        }
        nextTimelineOrder = a.order
        pendingText = ""
        pendingReasoning.removeAll()
    }
    /// 是否正在响应（驱动输入栏「发送/停止」切换，跨重建保持准确）
    @Published var isResponding: Bool = false
    /// 是否处于「已暂停」状态（软暂停，可恢复）。
    /// 暂停时 `isResponding` 为 false，但 runtime 不移除（保留以便恢复）。
    @Published var isPaused: Bool = false

    // MARK: - 任务总耗时计时（2026-08-08 用户定）

    /// 已结算秒数（暂停/重试期间累积在此，段累计模型）。
    @Published var taskAccumulated: Double = 0
    /// 当前计时段起点（非 nil = 正在计时；Date 差值计算，App 进后台计时照常走）。
    @Published var taskSegmentStartAt: Date?
    /// 断点恢复（App 被杀冷启动续跑）的任务：起点不可靠，终态不结算、不显示耗时。
    @Published var taskTimingInvalid = false

    /// 开始/继续计时（幂等：已在计时则不动）。
    func taskStartOrResume() {
        if taskSegmentStartAt == nil { taskSegmentStartAt = Date() }
    }

    /// 暂停计时（停止/重试/软暂停时调用；暂停期间不计）。
    func taskPause() {
        guard let s = taskSegmentStartAt else { return }
        taskAccumulated += Date().timeIntervalSince(s)
        taskSegmentStartAt = nil
    }

    /// 当前累计耗时（秒）。
    func taskElapsedNow() -> Double {
        taskAccumulated + (taskSegmentStartAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// 结算终态耗时并清零计时状态（幂等：重复调用返回已清零后的 0，调用方用 if nil 保护）。
    func taskSettle() -> Double {
        let e = taskElapsedNow()
        taskAccumulated = 0
        taskSegmentStartAt = nil
        return e
    }
    /// 冷启动恢复暂停态时的 MCP 动态工具准备任务。
    /// 用户过快点击「继续」时，恢复流程会先等待此任务，避免 `resume()` 早于工具注册。
    var mcpPreparationTask: Task<Void, Never>?
    // /compact 手动压缩标志已挪至 AppState.pendingManualCompact（2026-09-08：
    // runtime 仅在回复期间存在，空闲会话取不到 → 预约丢失；会话级字典跨 runtime 存活）。

    var id: UUID { sessionID }

    init(sessionID: UUID, engine: AgentLoopEngine) {
        self.sessionID = sessionID
        self.engine = engine
    }

    // MARK: - 流式节流（词元 合并）

    /// 缓冲一个文本 词元（纯追加），由共享的 ~100ms 调度窗口批量刷入 `streamingContent`。
    /// 用「一个调度窗口只起一个 sleep 任务」实现 ~100ms 防抖，把每 词元 一次的重绘降到约 10fps。
    func bufferToken(_ piece: String) {
        pendingText += piece
        scheduleFlush()
    }

    /// 缓冲一个思考（reasoning）词元：按迭代轮次记录，由共享的 ~100ms 调度窗口批量刷入
    /// `streamingReasoningSegments`，消除「每 词元 一次整段重绘 + 每 词元 全量重解析 Markdown」卡顿。
    /// 与正文共用同一调度窗口，避免各起一套定时器。
    func bufferReasoningToken(_ piece: String, iteration: Int) {
        pendingReasoning.append((piece, iteration))
        scheduleFlush()
    }

    /// 轮次边界是否需要「下一段正文前插一个空行」。由 `markRoundSafePoint()` /
    /// `rollbackToRoundSafePoint()` 置位、由 `commitStreamBuffer()` 消费（见那里的说明）。
    private var needsRoundSeparator = false

    /// 一个调度窗口内只起一个 sleep 任务；触发时同时刷正文与思考缓冲（约 10fps）。
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.flushScheduled = false
            self?.commitReasoningBuffer()   // 先刷思考：position 在正文提交前记录，避免偏移
            self?.commitStreamBuffer()      // 后刷正文
        }
    }

    /// 把缓冲文本提交到流式内容（节流任务触发，或收尾/暂停前手动调用保证不丢尾包）。
    func commitStreamBuffer() {
        guard !pendingText.isEmpty else { return }
        // [2026-09-13 轮次分隔符] 跨轮次的首段正文前插一个空行。
        // 多轮 iteration 的 token 是**裸 `+=`** 进同一个 `streamingContent`，全链路没有任何分隔符
        // ⇒ 真机上「上一轮的收尾」与「下一轮的开头」会粘成一句话（实测样本：
        // `…要哪个说一声就行～照片已经下好了，就是这两张 👇`），工具轮之间的旁白同样被粘成一长串。
        // 只插一次、且仅在已有内容时插（首轮不插，避免正文以空行开头）。
        if needsRoundSeparator {
            needsRoundSeparator = false
            if !streamingContent.isEmpty { streamingContent += "\n\n" }
        }
        streamingContent += pendingText
        pendingText = ""
    }

    /// 把缓冲的思考 词元 提交到分段思考：命中已存在段则追加文本，否则以「当前正文长度」为锚点新建段。
    /// 在 ~100ms 窗口内合并多个 词元，仅触发一次 `streamingReasoningSegments` 赋值与一次 Markdown 重解析。
    func commitReasoningBuffer() {
        guard !pendingReasoning.isEmpty else { return }
        var segments = streamingReasoningSegments
        for (piece, iteration) in pendingReasoning {
            if let idx = segments.firstIndex(where: { $0.index == iteration }) {
                segments[idx].text += piece
            } else {
                // 锚点 = 已提交正文 + 未提交缓冲 = 模型真实流式位置。
                // 只用 streamingContent.count 会在轮次边界竞态下偏早：上一轮尾包还在
                // pendingText 里时下一轮思考先到（flush 先思考后正文），锚点落进上一轮
                // 回复内部 → buildBlocks 把思考块插进上一轮回复中间，且随落盘固化。
                // 本轮正常场景（思考先于本轮正文到达）不受影响：锚点时刻缓冲里只有上一轮尾巴。
                let pos = streamingContent.count + pendingText.count
                let order = nextTimelineOrder
                nextTimelineOrder += 1
                segments.append(ReasoningSegment(index: iteration, text: piece, position: pos, timelineOrder: order))
            }
        }
        streamingReasoningSegments = segments
        pendingReasoning.removeAll()
    }
}

// MARK: - 子代理轻量卡片（仅驱动会话页上方悬浮头像，避免每次 token 都驱动主视图重绘）

/// 子代理悬浮头像的轻量信息：圆形图标 + 名称 + 状态。
/// 注意：仅含 id/name/status，**不含**流式对话内容——流式内容放在独立的
/// `SubagentConversation`（`@Observable` 类）里，只被详情页观察，
/// 从而把「子代理每收到一个 令牌」的刷新隔离在详情页，主聊天页不再随之重绘（防卡顿）。
struct SubagentCard: Identifiable, Codable {
    let id: UUID
    let name: String
    var status: SubagentStatus
}

enum SubagentStatus: String, Codable { case running, error, completed, cancelled }

// MARK: - 子代理对话模型（详情页）

/// 子代理对话中的单条消息（用于「智能体 ↔ 子代理」详情页展示）。
/// 数据结构与主会话页的 `ChatMessage` 对齐：`.task` 映射为 `.user`（绿色气泡），
/// `.response` 映射为 `.assistant`（无背景、含工具调用与分段思考），由详情页复用 `MessageBubbleView` 渲染。
/// 声明为 `@Observable` 类：流式追加 词元 / 工具调用时只刷新对应这一行，而非整段列表。
final class SubagentMsg: ObservableObject, Identifiable, Codable {
    let id: UUID
    /// 角色：`.task` = 主 智能体分配给子代理的任务；`.response` = 子代理的回复。
    let role: SubagentMsgRole
    @Published var text: String
    /// 是否仍在流式输出（用于底部状态行显示「回复中」）。
    @Published var isStreaming: Bool
    /// 子代理回复中穿插的工具调用事件（与主线 `MessageBubbleView` 的 `ToolCallCardView` 完全一致）。
    @Published var toolCalls: [ToolCallEvent] = []
    /// 分段思考过程（按 agent loop 迭代切片，穿插在正文/工具调用之间）。
    @Published var reasoningSegments: [ReasoningSegment] = []
    /// 该回复是否因异常/中断而提前结束（渲染为「已中断」红色状态，与主线一致）。
    @Published var wasInterrupted: Bool = false

    init(role: SubagentMsgRole, text: String, isStreaming: Bool) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, isStreaming, toolCalls, reasoningSegments, wasInterrupted
    }

    required init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(SubagentMsgRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        isStreaming = try c.decode(Bool.self, forKey: .isStreaming)
        toolCalls = try c.decode([ToolCallEvent].self, forKey: .toolCalls)
        reasoningSegments = try c.decode([ReasoningSegment].self, forKey: .reasoningSegments)
        wasInterrupted = try c.decode(Bool.self, forKey: .wasInterrupted)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encode(reasoningSegments, forKey: .reasoningSegments)
        try c.encode(wasInterrupted, forKey: .wasInterrupted)
    }
}

enum SubagentMsgRole: String, Codable { case task, response }

/// 单个子代理的完整对话（任务 + 回复），跨主回复轮次持续存在（头像常驻）。
/// `@Observable` 类：详情页只观察它，主聊天页不观察，隔离流式刷新。
final class SubagentConversation: ObservableObject, Identifiable, Codable {
    let id: UUID
    let name: String
    @Published var status: SubagentStatus
    /// 智能体 ↔ 子代理的对话（任务 + 回复），按发生顺序追加。
    @Published var messages: [SubagentMsg] = []
    /// 子代理实际使用的模型显示（分组·模型，如「DeepSeek·deepseek-v4-pro」；未运行完为空）。
    @Published var modelDisplay: String = ""
    /// 子代理思考强度显示（无思考/低/高/默认；未运行完为空）。
    @Published var thinkingDisplay: String = ""

    init(id: UUID, name: String, status: SubagentStatus) {
        self.id = id
        self.name = name
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, messages, modelDisplay, thinkingDisplay
    }

    required init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(SubagentStatus.self, forKey: .status)
        messages = try c.decode([SubagentMsg].self, forKey: .messages)
        // 兼容旧数据：新字段缺键时保持空串（头部未显示模型信息）。
        modelDisplay = try c.decodeIfPresent(String.self, forKey: .modelDisplay) ?? ""
        thinkingDisplay = try c.decodeIfPresent(String.self, forKey: .thinkingDisplay) ?? ""
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(messages, forKey: .messages)
        try c.encode(modelDisplay, forKey: .modelDisplay)
        try c.encode(thinkingDisplay, forKey: .thinkingDisplay)
    }
}
