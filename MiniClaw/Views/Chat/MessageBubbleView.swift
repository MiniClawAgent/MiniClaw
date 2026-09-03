import SwiftUI


struct MessageBubbleView: View {
    let message: ChatMessage

    // 显式 init：避免参数较多时 Swift 类型检查器在调用处推断超时（"unable to type-check"）。
    init(
        message: ChatMessage,
        liveContent: String? = nil,
        liveReasoningSegments: [ReasoningSegment]? = nil,
        liveToolCalls: [ToolCallEvent]? = nil,
        liveIsStreaming: Bool? = nil,
        liveIsPaused: Bool? = nil,
        agentName: String = "MiniClaw",
        showThinking: Bool = true,
        onOpenURL: ((URL) -> Void)? = nil,
        onImageTap: ((URL) -> Void)? = nil,
        sessionID: UUID? = nil,
        runtime: ChatSessionRuntime? = nil,
        onStreamContentGrown: (() -> Void)? = nil,
        expandedReasoning: Set<Int> = [],
        onToggleReasoning: ((Int) -> Void)? = nil,
        expandedTools: Set<UUID> = [],
        onToggleTool: ((UUID) -> Void)? = nil,
        expandedError: Bool = false,
        onToggleError: (() -> Void)? = nil
    ) {
        self.message = message
        self.liveContent = liveContent
        self.liveReasoningSegments = liveReasoningSegments
        self.liveToolCalls = liveToolCalls
        self.liveIsStreaming = liveIsStreaming
        self.liveIsPaused = liveIsPaused
        self.agentName = agentName
        self.showThinking = showThinking
        self.onOpenURL = onOpenURL
        self.onImageTap = onImageTap
        self.sessionID = sessionID
        self.runtime = runtime
        self.onStreamContentGrown = onStreamContentGrown
        self.expandedReasoning = expandedReasoning
        self.onToggleReasoning = onToggleReasoning
        self.expandedTools = expandedTools
        self.onToggleTool = onToggleTool
        self.expandedError = expandedError
        self.onToggleError = onToggleError
    }

    /// 流式输出覆盖（仅当前正在流式的消息非 nil，来自 ChatView 的 @State 缓冲区）。
    var liveContent: String? = nil
    var liveReasoningSegments: [ReasoningSegment]? = nil
    /// 是否显示思考过程（受全局「显示思考过程」开关控制；由 ChatView 传入）。
    var showThinking: Bool = true
    var liveToolCalls: [ToolCallEvent]? = nil
    var liveIsStreaming: Bool? = nil
    /// 软暂停标志（仅本轮流式消息从 ChatView 透传 runtime.isPaused；其他消息为 nil，
    /// 使气泡底部状态从「回复中」切换为「已暂停」）。
    var liveIsPaused: Bool? = nil
    /// 智能体回复显示的名字，关联到 AppState.agentName（即 SOUL.md 的 name），默认 MiniClaw 防止空白
    var agentName: String = "MiniClaw"
    /// 链接点击回调（非 .md 的 URL 走内置浏览器）
    var onOpenURL: ((URL) -> Void)? = nil
    /// 图片点击回调 → 全屏查看
    var onImageTap: ((URL) -> Void)? = nil
    /// 所属会话 ID：用于把「attachments/<name>」相对路径解析为当前会话目录下的真实文件。
    var sessionID: UUID? = nil
    /// 当前会话的流式运行时（来自 ChatView）。仅当 `message.id == runtime.streamingMessageID`
    /// 时本气泡在 body 内读取流式字段，从而每个 词元 只重绘这「一条」气泡，历史消息零重绘。
    /// 子代理详情页不传 runtime，走 `liveContent` 直传路径（各自独立 @Observable，互不影响）。
    var runtime: ChatSessionRuntime? = nil

    /// 流式「回复中」指示器的呼吸灯状态（true=暗淡,false=亮;1s 往复循环）。
    @State private var replyDotDimmed = false

    /// 流式期间「内容行数增长」上报（滚动跟随用，按行计算：行数不增不触发）。
    var onStreamContentGrown: (() -> Void)? = nil

    /// 受控展开状态（2026-08-09 提升到 ChatView，供 cell 高度缓存 key 使用）：
    /// 本消息内已展开的思考段 index 集合（多条思考段各自独立，2026-08-09 修复
    /// 「点一个全展开」）、工具卡展开集合（按工具调用 id）、错误详情是否展开。
    var expandedReasoning: Set<Int> = []
    /// 用户手动点过的思考段（开源参考实现 thinkingUserToggled）：流式自动展开/自动折叠失效
    @State var reasoningUserToggled: Set<Int> = []
    var onToggleReasoning: ((Int) -> Void)? = nil
    var expandedTools: Set<UUID> = []
    var onToggleTool: ((UUID) -> Void)? = nil
    var expandedError: Bool = false
    var onToggleError: (() -> Void)? = nil

    /// 是否「本气泡正在流式」（用于关闭流式期动画、决定读取 runtime）。
    private var isThisMessageStreaming: Bool {
        if let runtime, runtime.streamingMessageID == message.id { return true }
        return liveIsStreaming ?? message.isStreaming
    }

    /// 实际使用的 content：显式 liveContent（子代理）> runtime 流式 > 已落盘 message.content
    private var effectiveContent: String {
        if let liveContent { return liveContent }
        if let runtime, runtime.streamingMessageID == message.id { return runtime.streamingContent }
        return message.content
    }
    /// 实际使用的 isStreaming（流式覆盖优先）
    private var effectiveIsStreaming: Bool {
        if let ls = liveIsStreaming { return ls }
        if let runtime, runtime.streamingMessageID == message.id { return true }
        return message.isStreaming
    }
    /// 实际使用的 isPaused（仅流式消息由 runtime 透传；默认 false）
    private var effectiveIsPaused: Bool {
        if let lp = liveIsPaused { return lp }
        if let runtime, runtime.streamingMessageID == message.id { return runtime.isPaused }
        return false
    }
    /// 实际使用的 toolCalls：显式 liveToolCalls > runtime 流式 > 已落盘 message.toolCalls
    private var effectiveToolCalls: [ToolCallEvent] {
        if let live = liveToolCalls, !live.isEmpty { return live }
        if let runtime, runtime.streamingMessageID == message.id {
            return runtime.streamingToolEvents
        }
        return message.toolCalls
    }
    /// 实际使用的分段思考：显式 live > runtime 流式 > 已落盘 reasoningSegments > 旧单串 reasoning。
    /// 旧消息只有单字符串 `reasoning` 时，兜底成一个 `position: 0` 的单段，保持原「顶部折叠块」体验。
    /// 过滤空/纯空白段：多步 agent 循环里模型可能发空 `reasoning_content` 事件，避免渲染出「空思考指示器」。
    private var effectiveReasoningSegments: [ReasoningSegment] {
        let nonEmpty: ([ReasoningSegment]) -> [ReasoningSegment] = { segs in
            segs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let live = liveReasoningSegments, !live.isEmpty { return nonEmpty(live) }
        if let runtime, runtime.streamingMessageID == message.id,
           !runtime.streamingReasoningSegments.isEmpty { return nonEmpty(runtime.streamingReasoningSegments) }
        if !message.reasoningSegments.isEmpty { return nonEmpty(message.reasoningSegments) }
        if let r = message.reasoning, !r.isEmpty {
            return [ReasoningSegment(index: 1, text: r, position: 0)]
        }
        return []
    }

    /// 估算行数：正文按「约 40 字符/行」折算 + 换行数，思考段/工具卡各按自身行数折算。
    /// 仅流式气泡参与（非流式时恒为 0，onChange 不触发）。
    /// iOS16 兼容:onChange 单参版本需要缓存上一个值检测增长。
    @State private var lastStreamRowEstimate: Int = 0
    private var streamRowEstimate: Int {
        guard isThisMessageStreaming else { return 0 }
        let text = effectiveContent
        var rows = text.count / 40 + text.filter { $0 == "\n" }.count + 1
        if showThinking {
            rows += effectiveReasoningSegments.reduce(0) { $0 + max(1, $1.text.count / 40) }
        }
        rows += effectiveToolCalls.count * 2
        return rows
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userMessageView
            case .assistant:
                assistantMessageView
            case .tool:
                toolMessageView
            case .system:
                systemMessageView
            }
        }
        // 流式输出期间关闭动画：避免每个 词元 追加/工具卡出现被动画化，进一步消除抖动。
        .transaction { t in
            if isThisMessageStreaming { t.animation = nil }
        }
        // 滚动跟随按行计算：本气泡「估算行数」增长时才上报（思考段展开/工具卡出现/正文增长都会
        // 增加行数）。行数估算便宜（字符数/宽度折算 + 换行数），不随内容做整页重算，也不逐词上报。
        // iOS16 兼容:onChange 单参 + @State 缓存上一个估算值(语义等价)。
        .onChange(of: streamRowEstimate) { new in
            if new > lastStreamRowEstimate { onStreamContentGrown?() }
            lastStreamRowEstimate = new
        }
    }

    // MARK: - User Message

    private var userMessageView: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                // 用户发出的附件（图片缩略图 / 文件卡片）展示在气泡上方
                if !message.attachments.isEmpty {
                    userAttachmentGallery
                }
                if !message.content.isEmpty {
                    MarkdownContentView(content: message.content, isStreaming: false, onOpenURL: onOpenURL, onImageTap: onImageTap, sessionID: sessionID)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        // 开源参考实现对齐(2026-08-09):tertiarySystemFill 灰底 + primary 文字(原绿色 #A9EA7A)
                        .background(Color(.tertiarySystemFill))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// 用户消息附件画廊：图片按等比缩小、靠右显示在文本上方；非图片显示文件卡片。
    /// 每条附件独占一行并整体靠右对齐（VStack alignment: .trailing），避免网格把首项顶到左侧。
    private var userAttachmentGallery: some View {
        let paths = message.attachments
        return VStack(alignment: .trailing, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                AttachmentCell(path: path, onImageTap: onImageTap, sessionID: sessionID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Assistant Message

    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                assistantAvatar
                Text(agentName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.top, 4)

            // 统一重试指示器：重试中 / 重试失败显示在 AI 正文位置（正文此时为空）。
            // 首个成功输出 词元 到达时 runtime.retryState 被清空，指示器自动消失。
            if let rs = runtime?.retryState, isThisMessageStreaming {
                RetryCardView(state: rs, isExpanded: expandedError, onToggle: onToggleError) {
                    runtime?.engine.requestImmediateRetry()
                }
            }

            // 正文 + 工具调用 + 分段思考，按 `position` 穿插渲染（不再全部堆在顶部）。
            // 每段思考独立可折叠；showThinking 关闭时移除思考段。
            let items = interleavedRenderItems()
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        switch item {
                        case .text(let text):
                            MarkdownContentView(content: text, isStreaming: effectiveIsStreaming, onOpenURL: onOpenURL, onImageTap: onImageTap, sessionID: sessionID)
                        case .tool(let ev):
                            ToolCallCardView(event: ev,
                                             isExpanded: expandedTools.contains(ev.id),
                                             onToggle: { onToggleTool?(ev.id) })
                        case .reasoning(let seg):
                            ReasoningBlockView(
                                text: seg.text,
                                isStreaming: effectiveIsStreaming && seg.index == currentReasoningIteration,
                                isExpanded: expandedReasoning.contains(seg.index),
                                isUserToggled: reasoningUserToggled.contains(seg.index),
                                onToggle: { onToggleReasoning?(seg.index) },
                                onUserToggle: { reasoningUserToggled.insert(seg.index) }
                            )
                        }
                    }
                }
            } else if !effectiveContent.isEmpty {
                MarkdownContentView(content: effectiveContent, isStreaming: effectiveIsStreaming, onOpenURL: onOpenURL, onImageTap: onImageTap, sessionID: sessionID)
            }

            // 状态始终放在本条 智能体回复的最下方；尚无正文/工具时则自然紧跟头像显示。
            assistantReplyStatus
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 渲染侧调试日志节流器（2026-08-08）：流式 10fps 下每帧打日志会刷爆，1s 最多一条。
    private static let renderLogGate = RenderLogGate()
    private final class RenderLogGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastAt: Date = .distantPast
        func shouldLog() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            guard now.timeIntervalSince(lastAt) >= 1 else { return false }
            lastAt = now
            return true
        }
    }

    /// 块级拆分规划（2026-08-09）：把「正文 + 工具调用 + 思考段」按真实发生时间线穿插为段数组。
    /// - 主排序 timelineOrder（发生顺序），position 仅决定文本片段切分位置；
    /// - showThinking 关闭时不包含思考段；旧数据无 timelineOrder 降级按 position 排序。
    static func assistantSegments(content: String, toolCalls: [ToolCallEvent], reasoningSegments: [ReasoningSegment], showThinking: Bool) -> [AssistantSegment] {
        let events = toolCalls
        let segments = showThinking ? reasoningSegments : []
        guard !events.isEmpty || !segments.isEmpty else {
            return content.isEmpty ? [] : [.text(content)]
        }

        struct TimelineEntry {
            let position: Int
            let timelineOrder: Int
            let item: AssistantSegment
        }

        var timeline: [TimelineEntry] = []

        for seg in segments {
            timeline.append(TimelineEntry(
                position: seg.position,
                timelineOrder: seg.timelineOrder,
                item: .reasoning(seg)
            ))
        }
        for ev in events {
            timeline.append(TimelineEntry(
                position: ev.position,
                timelineOrder: ev.timelineOrder,
                item: .tool(ev)
            ))
        }

        let hasValidTimeline = timeline.contains { $0.timelineOrder > 0 }
        if hasValidTimeline {
            timeline.sort { $0.timelineOrder < $1.timelineOrder ||
                          ($0.timelineOrder == $1.timelineOrder && $0.position < $1.position) }
        } else {
            timeline.sort { $0.position < $1.position }
        }

        var result: [AssistantSegment] = []
        var textCursor = 0

        for entry in timeline {
            let entryPos = min(max(entry.position, 0), content.count)
            if entryPos > textCursor {
                let startIdx = content.index(content.startIndex, offsetBy: textCursor)
                let endIdx = content.index(content.startIndex, offsetBy: entryPos)
                result.append(.text(String(content[startIdx..<endIdx])))
            }
            result.append(entry.item)
            textCursor = entryPos
        }

        if textCursor < content.count {
            let startIdx = content.index(content.startIndex, offsetBy: textCursor)
            result.append(.text(String(content[startIdx..<content.endIndex])))
        }

        return result
    }

    /// 消息级路径的穿插渲染（流式消息/简单消息用）：静态规划 + 渲染侧日志。
    private func interleavedRenderItems() -> [AssistantSegment] {
        let content = effectiveContent
        let events = effectiveToolCalls
        let segments = showThinking ? effectiveReasoningSegments : []

        if Self.renderLogGate.shouldLog() {
            let src = liveContent != nil ? "liveContent" : (runtime?.streamingMessageID == message.id ? "runtime流式" : "message.content落盘")
        }

        return Self.assistantSegments(content: content, toolCalls: events, reasoningSegments: effectiveReasoningSegments, showThinking: showThinking)
    }

    /// 当前正在流式的最新一段思考序号（用于让它显示「思考中」蓝色、其余段显示已完成绿色）。
    private var currentReasoningIteration: Int {
        effectiveReasoningSegments.map { $0.index }.max() ?? 0
    }

    /// 智能体回复状态指示器（底部状态行）：
    /// - 流式进行中：一律显示「回复中」（含深度思考阶段，底部状态行不再单独区分「思考中」；
    ///   各思考段的内容指示器由 ReasoningBlockView 折叠块单独呈现）。
    /// - 已结束：无论思考型还是普通回复，均显示绿色 ✅「已完成」（与下载完成指示器同色）。
    /// - 可展开的思考指示器（ReasoningBlockView）另用灯泡 +「深度思考」呈现，思考结束变绿。
    /// - 已暂停 / 已停止 / 已中断 三态优先于上述。
    @ViewBuilder
    /// 状态行（块级拆分后由独立 AssistantStatusRow 承载；消息级路径保留实例方法兼容）。
    private var assistantReplyStatus: some View {
        AssistantStatusRow(
            wasStopped: message.wasStopped ?? false,
            wasInterrupted: message.wasInterrupted,
            taskElapsedSeconds: message.taskElapsedSeconds,
            isStreaming: effectiveIsStreaming,
            isPaused: effectiveIsPaused,
            replyDotDimmed: replyDotDimmed
        )
    }

    // MARK: - Tool Message

    private var toolMessageView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.adjustable")
                        .font(.caption)
                    Text(message.toolCallName ?? L10n.l("tool_calls"))
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
                if let result = message.toolCallResult, !result.isEmpty {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - System Message

    private var systemMessageView: some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Assistant Avatar

    private var assistantAvatar: some View {
        // 2026-08-10 用户要求:星星改为 emoji ✨(原 sparkles SF 符号 + 暖金渐变)。
        Text("✨")
            .font(.system(size: 18))
    }
}

// MARK: - 深度思考折叠块（开源参考实现对齐 2026-08-09）
// 规格:折叠=蓝色卡片(背景 blue 6%、圆角 12、描边 blue 15% 0.5pt),
// 头部 14pt 图标 + 13pt semibold 蓝标题 + 流式 mini spinner + 11pt 字符数 + chevron,
// padding h12/v10,折叠高≈40pt;展开=内嵌 ScrollView 上限 300pt,13pt/行距3,
// 尾部 8000 字符窗口;流式自动展开(默认)、结束自动折叠,用户手动后尊重(开源参考实现
// thinkingUserToggled 语义,状态由外层持有以跨 cell 复用保留)。

