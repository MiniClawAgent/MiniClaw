import SwiftUI

/// 消息穿插段（2026-08-09 块级拆分）：正文片段 / 工具调用卡 / 思考段。
enum AssistantSegment {
    case text(String)
    case tool(ToolCallEvent)
    case reasoning(ReasoningSegment)
}

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
        if let runtime, runtime.streamingMessageID == message.id { return runtime.streamingToolCalls }
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
        .onChange(of: streamRowEstimate) { old, new in
            if new > old { onStreamContentGrown?() }
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
            AppLogger.shared.info("[Render] msg=\(message.id.uuidString.prefix(8)) source=\(src) content=\(content.count)字 tools=\(events.count)pos=\(events.map { String($0.position) }.joined(separator: ",")) reasoning=\(segments.count)pos=\(segments.map { String($0.position) }.joined(separator: ",")) isStreaming=\(effectiveIsStreaming) wasStopped=\(message.wasStopped ?? false) wasInterrupted=\(message.wasInterrupted) taskElapsed=\(message.taskElapsedSeconds ?? -1)", category: "Agent", subsystem: "Render")
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
                    Text(message.toolCallName ?? L10n.tr("工具调用"))
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

struct ReasoningBlockView: View {
    let text: String
    let isStreaming: Bool
    /// 受控展开状态（2026-08-09 提升到外层：展开状态须进 cell 高度缓存 key，
    /// 否则展开后 cell 高度不更新 → 内容溢出叠加/超出面板）。
    let isExpanded: Bool
    /// 用户是否手动操作过（开源参考实现 thinkingUserToggled）：手动后流式自动
    /// 展开/结束自动折叠全部失效。消息级路径由 MessageBubbleView @State 持有
    /// （cell 复用重建会重置，低风险：仅影响「流式中手动折叠后自动展开」的意图保持）；
    /// 块级路径仅承载非流式消息，无自动逻辑，默认 false。
    var isUserToggled: Bool = false
    var onToggle: (() -> Void)? = nil
    /// 用户手动点击回调（外层在此标记 isUserToggled）
    var onUserToggle: (() -> Void)? = nil

    /// 尾部窗口（开源参考实现 8000 字符，防超长思考渲染卡死 UI）
    private let windowSize = 8000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // 展开/折叠即时切换、无动画（2026-08-09：动画化 hosting 内容高度会让
                // flow layout 逐帧重排/塌陷；高度一步到位，由外层触发 cell 重配）。
                onUserToggle?()
                onToggle?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.blue)
                    Text(L10n.tr("深度思考"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.blue)
                    }
                    if !text.isEmpty {
                        Text(charCountText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.blue.opacity(0.6))
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.blue.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !text.isEmpty {
                // 展开内容：内嵌 ScrollView 上限 300pt（开源参考实现），超长只渲染尾部窗口
                let window = windowedText
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if window.isTruncated {
                            Text(L10n.tr("仅显示后 \(window.shownK)K 字符(共 \(window.totalK)K 字符)"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                        }
                        Text(window.content)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(.tertiaryLabel))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.blue.opacity(0.15), lineWidth: 0.5)
        )
        // 2026-08-10 用户要求:思考块默认折叠、永不自动展开。
        // 仅保留「流式结束自动折叠」(用户手动展开过则尊重用户选择)。
        .onChange(of: isStreaming) { streaming in
            if !streaming, !isUserToggled, isExpanded {
                onToggle?()
            }
        }
        .onAppear {
            // 不再自动展开(用户要求默认折叠)
        }
    }

    private var charCountText: String {
        let c = text.count
        return c > 1000 ? "\(c / 1000)K" : "\(c)"
    }

    /// 尾部 8000 字符窗口；截断起点若落在行中则从下一行开始（避免切断中间行）
    private var windowedText: (content: String, isTruncated: Bool, shownK: Int, totalK: Int) {
        let total = text.count
        guard total > windowSize else { return (text, false, 0, 0) }
        var start = text.index(text.startIndex, offsetBy: total - windowSize)
        if start != text.startIndex {
            let prev = text.index(before: start)
            if text[prev] != "\n", let nl = text[start...].firstIndex(of: "\n") {
                start = text.index(after: nl)
            }
        }
        return (String(text[start...]), true, windowSize / 1000, total / 1000)
    }
}

// MARK: - 工具调用卡片（pill 风格）

/// 统一重试指示器：AI 输出位置显示「自动重试进行中 / 重试失败」。
/// 参考工具指示器骨架（灰底圆角 + 0.5pt 描边），但错误详情区更长（多行完整展示）；
/// 右侧为「立即重试」按钮——点击立即重试（重置 3s 计时），不点击保持自动重试频率。
/// 重试次数耗尽后按钮禁用，指示器保留最终错误。
struct RetryCardView: View {
    let state: RetryState
    /// 受控展开状态（2026-08-09 与思考块同机制）。
    var isExpanded: Bool = false
    var onToggle: (() -> Void)? = nil
    /// 手动立即重试（转发到 engine.requestImmediateRetry）
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if state.phase == .retrying {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(format: L10n.tr("正在重试（%@/%@）"), "\(state.attempt)", "\(state.total)"))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Text(L10n.tr("重试失败"))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                Spacer()

                // 右侧重试按钮：点击立即重试；次数耗尽后禁用。
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(state.canRetry ? Color.accentColor : Color(.systemGray3))
                }
                .disabled(!state.canRetry)
                .buttonStyle(.plain)

                // 展开 / 收起错误详情（2026-08-09：同样去掉动画，与思考块同机制）
                Button {
                    onToggle?()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
            }

            // 错误详情：多行完整展示（比工具指示器长），可选中复制。
            if isExpanded {
                Text(state.lastError.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
    }
}

struct ToolCallCardView: View {
    let event: ToolCallEvent
    /// 受控展开状态（2026-08-09 与思考块同机制，按工具调用 id 索引）。
    let isExpanded: Bool
    var onToggle: (() -> Void)? = nil

    private var downloadTracker: DownloadProgressTracker { .shared }

    private var isPending: Bool { event.resultText.isEmpty && !event.wasInterrupted }

    /// 是否为本卡片专属的下载进度显示
    private var isMyDownload: Bool {
        guard event.name == "browser" || event.name == "miniclaw-browser-use" else { return false }
        // 仅「fetch」action 才是下载
        return event.arguments.contains("\"fetch\"")
    }

    /// 正在下载中（本卡片是当前执行下载的工具）
    private var isDownloading: Bool {
        isPending && isMyDownload && downloadTracker.isActive
    }

    /// 下载已完成（从持久化的 event 数据判定，重启不丢失）
    private var isDownloadDone: Bool {
        isMyDownload && !isPending && event.success && !event.wasInterrupted
    }

    /// pill 背景色
    private var pillBackground: some View {
        Group {
            if isDownloading {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color(.systemGray5)
                        Color(red: 0.098, green: 0.549, blue: 0.996).opacity(0.15)
                            .frame(width: geo.size.width * downloadTracker.progress)
                    }
                }
            } else if isDownloadDone {
                Color.green.opacity(0.12)
            } else {
                Color(.systemGray6)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isDownloading)
    }

    private var stateColor: Color {
        if event.wasInterrupted { return .orange }
        if isPending { return .secondary }
        return event.success ? .green : .red
    }

    private var formattedDuration: String {
        guard let duration = event.duration else { return "--" }
        if duration < 0.1 { return "<0.1s" }
        return String(format: "%.1fs", duration)
    }

    /// SF Symbols 图标 + 可读描述
    private func toolDisplayInfo() -> (symbol: String, label: String) {
        let name = event.name
        let args = event.arguments
        let activity = extractJSONField(args, field: "activity")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activity, !activity.isEmpty {
            return (toolSymbol(for: name), activity)
        }
        switch name {
        case "file_read":
            if args.contains("path") {
                let path = extractJSONField(args, field: "path") ?? ""
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return ("doc.text", filename.isEmpty ? L10n.tr("读取文件") : String(format: L10n.tr("读取 %@"), filename))
            }
            return ("doc.text", L10n.tr("读取文件"))
        case "file_write":
            if args.contains("path") {
                let path = extractJSONField(args, field: "path") ?? ""
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return ("square.and.pencil", filename.isEmpty ? L10n.tr("写入文件") : String(format: L10n.tr("写入 %@"), filename))
            }
            return ("square.and.pencil", L10n.tr("写入文件"))
        case "file_edit": return ("pencil.and.outline", L10n.tr("编辑文件"))
        case "browser", "miniclaw-browser-use":
            if let activity, !activity.isEmpty {
                return ("globe", activity)
            }
            let action = extractJSONField(args, field: "action")
            let url = extractJSONField(args, field: "url") ?? extractJSONField(args, field: "params.url")
            let selector = extractJSONField(args, field: "selector") ?? extractJSONField(args, field: "params.selector")
            switch action {
            case "navigate", "new_tab":
                let host = url.flatMap { URL(string: $0)?.host } ?? url ?? L10n.tr("网页")
                return ("globe", String(format: L10n.tr("打开 %@"), host))
            case "screenshot": return ("camera.viewfinder", L10n.tr("截取当前网页"))
            case "get_text": return ("doc.plaintext", selector.map { String(format: L10n.tr("读取 %@ 内容"), $0) } ?? L10n.tr("读取网页内容"))
            case "get_readable": return ("text.book.closed", L10n.tr("读取网页正文"))
            case "get_page_info": return ("info.circle", L10n.tr("查看页面信息"))
            case "get_backbone": return ("point.3.connected.trianglepath.dotted", L10n.tr("分析网页结构"))
            case "click": return ("hand.tap", selector.map { String(format: L10n.tr("点击 %@"), $0) } ?? L10n.tr("点击网页元素"))
            case "type": return ("keyboard", L10n.tr("在网页中输入"))
            case "scroll": return ("scroll", L10n.tr("浏览页面内容"))
            case "scroll_and_collect": return ("arrow.down.doc", L10n.tr("收集页面列表"))
            case "find_elements": return ("scope", L10n.tr("查找网页元素"))
            case "fetch": return ("arrow.down.circle", L10n.tr("下载网页资源"))
            case "list_tabs": return ("rectangle.on.rectangle", L10n.tr("查看浏览器标签"))
            case "close_tab": return ("xmark.square", L10n.tr("关闭浏览器标签"))
            case "wait_for_dom_stable": return ("hourglass", L10n.tr("等待网页加载"))
            default: return ("globe", L10n.tr("处理网页内容"))
            }
        case "shell_execute": return ("terminal", L10n.tr("执行命令"))
        case "memory_write": return ("brain.head.profile", L10n.tr("写入记忆"))
        case "memory_get": return ("magnifyingglass", L10n.tr("搜索记忆"))
        case "read_image": return ("photo", L10n.tr("读取图片"))
        case "apple-calendar": return ("calendar", L10n.tr("日历操作"))
        case "apple-reminders": return ("checklist", L10n.tr("提醒事项"))
        case "apple-weather": return ("cloud.sun", L10n.tr("查询天气"))
        case "apple-speak": return ("speaker.wave.2", L10n.tr("朗读文本"))
        case "apple-speech": return ("mic", L10n.tr("语音识别"))
        case "apple-clipboard": return ("doc.on.clipboard", L10n.tr("剪贴板操作"))
        case "apple-device": return ("iphone", L10n.tr("设备信息"))
        case "apple-nlp": return ("text.alignleft", L10n.tr("文本分析"))
        case "apple-open": return ("arrow.up.forward.app", L10n.tr("打开链接"))
        case "apple-notification": return ("bell", L10n.tr("发送通知"))
        case "apple-location": return ("location", L10n.tr("定位服务"))
        case "apple-maps": return ("map", L10n.tr("地图搜索"))
        case "miniclaw_config": return ("gearshape", L10n.tr("配置管理"))
        case "sessions_cli": return ("bubble.left.and.bubble.right", L10n.tr("会话管理"))
        case "miniclaw-debug": return ("ladybug", L10n.tr("调试信息"))
        default: return ("wrench.and.screwdriver", name.replacingOccurrences(of: "_", with: " "))
        }
    }

    private func toolSymbol(for name: String) -> String {
        switch name {
        case "file_read": return "doc.text"
        case "file_write": return "square.and.pencil"
        case "file_edit": return "pencil.and.outline"
        case "browser", "miniclaw-browser-use": return "globe"
        case "shell_execute": return "terminal"
        case "memory_write": return "brain.head.profile"
        case "memory_get": return "magnifyingglass"
        case "read_image": return "photo"
        case "apple-calendar": return "calendar"
        case "apple-reminders": return "checklist"
        case "apple-weather": return "cloud.sun"
        case "apple-speak": return "speaker.wave.2"
        case "apple-speech": return "mic"
        case "apple-clipboard": return "doc.on.clipboard"
        case "apple-device": return "iphone"
        case "apple-nlp": return "text.alignleft"
        case "apple-open": return "arrow.up.forward.app"
        case "apple-notification": return "bell"
        case "apple-location": return "location"
        case "apple-maps": return "map"
        case "miniclaw_config": return "gearshape"
        case "sessions_cli": return ("bubble.left.and.bubble.right")
        case "miniclaw-debug": return "ladybug"
        default: return "wrench.and.screwdriver"
        }
    }

    private func extractJSONField(_ json: String, field: String) -> String? {
        let pattern = "\"\(field)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        return String(json[range])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pill 主体行
            Button(action: { onToggle?() }) {
                HStack(spacing: 6) {
                    let info = toolDisplayInfo()
                    Image(systemName: event.wasInterrupted ? "stop.circle.fill" : info.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(stateColor)
                    Text(info.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if event.wasInterrupted {
                        Text(L10n.tr("已停止"))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                    } else if isPending {
                        if isDownloading {
                            Text("\(Int(downloadTracker.progress * 100))%")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(red: 0.098, green: 0.549, blue: 0.996))
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                    } else if isDownloadDone {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                            Text(L10n.tr("已下载"))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    } else {
                        Text(formattedDuration)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(stateColor)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
            }
            .buttonStyle(.plain)

            // 展开详情
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 4) {
                    if !event.arguments.isEmpty {
                        Text(event.arguments)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(5)
                    }
                    if !event.resultText.isEmpty {
                        Text(event.resultText)
                            .font(.caption2)
                            .foregroundStyle(event.success ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                            .lineLimit(8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(pillBackground)
        // 开源参考实现对齐(2026-08-09):折叠态 Capsule(高36)、展开态圆角 18
        .clipShape(isExpanded ? AnyShape(RoundedRectangle(cornerRadius: 18)) : AnyShape(Capsule()))
        .overlay(
            (isExpanded ? AnyShape(RoundedRectangle(cornerRadius: 18)) : AnyShape(Capsule()))
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .fixedSize(horizontal: !isExpanded, vertical: true)
    }
}

// MARK: - 用户附件缩略图

/// 单个附件单元格：图片显示本地缩略图（点按全屏），非图片显示文件卡片。
private struct AttachmentCell: View {
    let path: String
    let onImageTap: ((URL) -> Void)?
    /// 所属会话 ID：把「attachments/<name>」相对路径解析为当前会话目录真实文件。
    let sessionID: UUID?

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"
    ]

    private var isImage: Bool {
        AttachmentCell.imageExts.contains((path as NSString).pathExtension.lowercased())
    }

    /// 解析附件真实 URL：
    /// - 绝对路径且文件存在 → 直接使用（兼容旧数据 / 智能体落盘的绝对路径）；
    /// - 相对路径「attachments/<name>」→ 经当前会话目录解析（活动 Documents 路径，避免容器 UUID 变化失效）；
    /// - 都不命中 → 回退原路径，交由 UIImage 判定。
    private var resolvedURL: URL {
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let sid = sessionID {
            let candidate = SessionFileRouter.shared.sessionHostDirectory(for: sid)
                .appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        let url = resolvedURL
        if isImage, let ui = UIImage(contentsOfFile: url.path) {
            // 等比缩小：用紧贴图片真实宽高比的紧框（而非 200x200 letterbox），
            // 这样图片才会真正靠右、且圆角作用于图片本身而非透明外框。
            let cgW = max(ui.size.width, 1)
            let cgH = max(ui.size.height, 1)
            let ratio = min(200 / cgW, 200 / cgH)
            let w = cgW * ratio
            let h = cgH * ratio
            Image(uiImage: ui)
                .resizable()
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { onImageTap?(url) }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .padding(8)
            .frame(width: 110, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - 块级组件（2026-08-09 块级拆分提取）

/// 智能体消息头部：头像 + 名字。
struct AssistantHeaderView: View {
    let agentName: String

    var body: some View {
        HStack(spacing: 6) {
            Text("✨")
                .font(.system(size: 18))
            Text(agentName)
                .font(.body)
                .fontWeight(.bold)
                .foregroundStyle(Color(red: 0.098, green: 0.549, blue: 0.996))
        }
    }
}

/// 智能体消息底部状态行（已完成/已停止/已中断/回复中/已暂停 + 任务耗时）。
/// 数据全部来自落盘消息字段（块级拆分后独立渲染，非流式消息专用路径）。
struct AssistantStatusRow: View {
    let wasStopped: Bool
    let wasInterrupted: Bool
    let taskElapsedSeconds: Double?
    let isStreaming: Bool
    let isPaused: Bool
    /// 流式呼吸点（消息级路径传入；块级路径恒 false 不显示流式态）
    var replyDotDimmed: Bool = false
    /// 智能体名（开源参考实现 TypingIndicator 文案用）
    var agentName: String = "MiniClaw"

    @State private var dotDimmed = false
    /// 三点弹跳（开源参考实现对齐：easeInOut 0.4s 错峰 0.15s，offset -3↔1）
    @State private var dotOffsets: [Bool] = [false, false, false]

    var body: some View {
        if isPaused {
            HStack(spacing: 5) {
                Image(systemName: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.098, green: 0.549, blue: 0.996))
                Text(L10n.tr("已暂停"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if isStreaming {
            // 开源参考实现对齐(2026-08-09)：TypingIndicator = "<名字> 正在思考" + 3 点弹跳
            HStack(spacing: 0) {
                Text(agentName + L10n.tr(" 正在思考"))
                ForEach(0..<3, id: \.self) { i in
                    Text(".")
                        .offset(y: dotOffsets[i] ? -3 : 1)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(i) * 0.15)) {
                                dotOffsets[i] = true
                            }
                        }
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color(.tertiaryLabel))
            .padding(.top, 2)
        } else if wasStopped {
            HStack(spacing: 5) {
                Image(systemName: "stop.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(L10n.tr("已停止"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                elapsedSuffix
            }
            .padding(.top, 2)
        } else if wasInterrupted {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(L10n.tr("已中断"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                elapsedSuffix
            }
            .padding(.top, 2)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(L10n.tr("已完成"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                elapsedSuffix
            }
            .padding(.top, 2)
        }
    }

    /// 任务总耗时后缀：23s / 12m23s / 1h2m3s（断点恢复/旧消息无字段不显示）。
    @ViewBuilder
    private var elapsedSuffix: some View {
        if let et = Self.elapsedText(taskElapsedSeconds) {
            Text(" · \(et)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func elapsedText(_ seconds: Double?) -> String? {
        guard let s = seconds, s >= 1 else { return nil }
        let t = Int(s.rounded())
        let h = t / 3600
        let m = (t % 3600) / 60
        let sec = t % 60
        if h > 0 { return "\(h)h\(m)m\(sec)s" }
        if m > 0 { return "\(m)m\(sec)s" }
        return "\(sec)s"
    }
}

extension AssistantSegment {
    /// 高度缓存签名（2026-08-09）：文本取长度、工具取事件 id、思考取文本长度。
    var contentSignature: String {
        // 长度 + 内容前缀共同签名（2026-08-09 修复 P2：同长度不同内容避免误命中高度缓存）
        switch self {
        case .text(let t): return "t\(t.count)-\(t.prefix(32))"
        case .tool(let ev): return "tool\(ev.id.uuidString.prefix(8))-r\(ev.resultText.count)"
        case .reasoning(let rs): return "r\(rs.text.count)-\(rs.text.prefix(32))"
        }
    }
}
