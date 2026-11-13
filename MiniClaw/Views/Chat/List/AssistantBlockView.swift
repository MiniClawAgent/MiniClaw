import SwiftUI
import Combine


struct ToolCapsuleView: View {
    @ObservedObject var block: AssistantBlock
    let icon: String
    let accentColor: Color
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var browserPool: MiniClawTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    /// 快照桥：透传给浮层（结果快照更新实时刷新）。
    var snapshotBridge: CellStateBridge? = nil
    @Binding var detailBlock: AssistantBlock?
    /// Drives the background-suspension info alert.
    @State private var bgHintAlert = false
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    private var bgSuspendHint: Bool {
        block.wasBackgroundSuspended && !keepAlive.enhancedBackgroundEffective
    }
    /// Used to suppress the "Re-run From
    @EnvironmentObject private var vm: MessageListModel

    private var displayStr: String {
        if let summary = block.toolSummary,!summary.isEmpty {
            return summary
        }
        return block.toolDescription
    }

    /// Human-readable, paste-back-able
    private var toolClip: String {
        let toolName: String
        switch block.kind {
        case .shellTool: toolName = "shell_execute"
        case .fileReadTool: toolName = "file_read"
        case .fileWriteTool: toolName = "file_write"
        case .fileEditTool: toolName = "file_edit"
        case .browserTool: toolName = "browser_use"
        case .readImageTool: toolName = "read_image"
        case .memoryTool: toolName = "memory"
        case .subagentTool: toolName = "subagent"
        case .text, .thinking, .info: toolName = "unknown"
        case .file: toolName = "file"
        }

        let inputBlk: String
        if let raw = block.toolInputArgs,!raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj,options: [.prettyPrinted,.sortedKeys]),
               let prettyStr = String(data: pretty,encoding: .utf8) {
                inputBlk = prettyStr
            } else {
                inputBlk = raw
            }
        } else {
            inputBlk = "(no input captured)"
        }

        var resultText = block.content
        if resultText.isEmpty,let tuId = block.toolUseId,
           let snap = toolSnapshots.first(where: { $0.id == tuId }) {
            resultText = snap.snapshot.text ?? ""
        }
        let hasScreenshot = block.imageFilePath != nil
            || (block.toolUseId.flatMap { tuId in toolSnapshots.first(where: { $0.id == tuId }) }?.snapshot.type == .image)

        let statusLabel: String
        switch block.toolStatus {
        case .success: statusLabel = "success"
        case .failed: statusLabel = "failed"
        case .cancelled: statusLabel = "cancelled"
        case .running: statusLabel = "running"
        case .streaming: statusLabel = "streaming"
        case .none: statusLabel = "unknown"
        }

        var resultMetaStr = "(\(resultText.count) chars, \(statusLabel)"
        if hasScreenshot { resultMetaStr += ", screenshot" }
        resultMetaStr += ")"

        return """
        ## Tool Call
        name: \(toolName)
        id: \(block.toolUseId ?? "(none)")
        input:
        \(inputBlk)

        ## Tool Result
        \(resultMetaStr)
        \(resultText)
        """
    }

    private var isStreaming: Bool {
        if case .streaming = block.toolStatus { return true }
        return false
    }

    private var isActive: Bool {
        switch block.toolStatus {
        case .streaming,.running: return true
        default: return false
        }
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                statusOrGlyph

                HStack(spacing: 0) {
                    Text(displayStr)
                        .font(.system(size: 13,weight: .medium))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineLimit(1)
                    if isStreaming {
                        BouncingDots()
                    }
                }
                .lineLimit(1)

                if let dur = durationLabel {
                    Text(dur)
                        .font(.system(size: 11,weight: .regular,design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }

                if case .running = block.toolStatus {
                    Button {
                        onStop?()
                    } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.red)
                            .frame(width: 10,height: 10)
                            .frame(width: 24,height: 24)
                            .contentShape(Rectangle())
                            .padding(-3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal,12)
            .frame(height: 36)
            .background(Color(UIColor.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                Group {
                    if isActive {
                        ShimmerOverlay()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(ChatColors.toolBorder,lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                detailBlock = block
            }
            .contextMenu {
                // Gate the eager menu
                // recursion in incident 98E8805F). `toolClip` is read
                // (blockId) and whether the Re-run branch is shown (isProcessing).
                EquatableMenuGate(key: ToolMenuKey(
                    blockId: block.id,
                    processing: vm.isProcessing
                )) {
                    //
                    Button {
                        UIPasteboard.general.string = toolClip
                    } label: {
                        Label(String(localized: "Copy Tool Details"), systemImage: "doc.on.doc")
                    }
                    // Only expose the
                    if !vm.isProcessing {
                        Divider()
                        Button(role: .destructive) {
                            // hosting chain — ChatView's RerunFromToolBlockListener
                            NotificationCenter.default.post(
                                name: .rerunFromToolBlock,
                                object: nil,
                                userInfo: ["blockId": block.id]
                            )
                        } label: {
                            Label(String(localized: "Re-run From Here"), systemImage: "arrow.clockwise")
                        }
                    }
                }
                .equatable()
            }
            // Yellow ⓘ just outside the capsule's
            if bgSuspendHint {
                Button {
                    bgHintAlert = true
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .padding(.leading,6)
                .accessibilityLabel(Text(String(localized: "Background suspension info")))
            }
            Spacer(minLength: 0)
        }
        .alert(
            String(localized: "Task may have been paused"),
            isPresented: $bgHintAlert
        ) {
            Button(String(localized: "Go Enable")) {
                // (= miniclaw://settings/background?focus=…:true,…:true). Location
                DeepLinkCoordinator.shared.setFocus(
                    rawQueryValue: "enhancedBackgroundExecution:true,backgroundSpeakEnabled:true,locationTrackingEnabled:true")
                DeepLinkCoordinator.shared.pendingSettingsTarget = .background
            }
            Button(String(localized: "Maybe Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "This tool may have been paused by the system while running in the background. Enable enhanced background execution to improve background task reliability."))
        }
    }

    @ViewBuilder
    private var statusOrGlyph: some View {
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(glyphColor)
    }

    private var glyphColor: Color {
        switch block.toolStatus {
        case .success: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        default: return accentColor
        }
    }

    private var durationLabel: String? {
        guard let dur = block.toolDuration else { return nil }
        if dur<1 { return String(format: "%.1fs", dur) }
        if dur<60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur)/60
        let secs = Int(dur)%60
        return "\(mins)m \(secs)s"
    }

}

struct ThinkingBlockView: View {
    @ObservedObject var block: AssistantBlock
    let isStreaming: Bool

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { block.isThinkingExpanded },
            set: { block.isThinkingExpanded = $0 }
        )
    }

    init(block: AssistantBlock,isStreaming: Bool) {
        self.block = block
        self.isStreaming = isStreaming
    }

    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            // Header(2026-08-11 调整:菊花移到字数后;去掉 Spacer 不撑满整行,
            // 宽度随内容自适应,与工具指示器胶囊一致)。
            HStack(spacing: 6) {
                // 魔法棒图标(思考指示器文字前,2026-08-10 用户要求)。
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatColors.primaryText)
                // 2026-08-12 本地化:经主 App xcstrings 查表(LocalizedStringKey 走 main bundle),
                // 跟随 App 语言设置而非仅系统语言。
                Text("deep_thinking")
                    .font(.system(size: 13,weight: .semibold))
                    .foregroundStyle(ChatColors.primaryText)
                // [Stage 1 · §6.3 A2/A3 收口 2026-09-17] 此处原为
                // `block.content.count > 0 || block.thinkingContentBuffer.count > 0`，
                // 且 `charCnt = max(block.content.count, block.thinkingContentBuffer.count)`。
                // `thinkingContentBuffer` 已删除：它唯一的写者是 `appendThinkingDelta`，
                // 而后者全仓零调用 ⇒ 缓冲**恒为空** ⇒ 那个析取项与 `max` 的第二项**恒为 0**、
                // 从不改变结果。改为直读正文长度（等价，且不再误导后来者以为该机制在工作）。
                if block.content.count>0 {
                    let charCnt = block.content.count
                    Text(charCnt>1000 ? "\(charCnt / 1000)K" : "\(charCnt)")
                        .font(.system(size: 11,weight: .medium,design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.blue)
                }
                Image(systemName: expandedBinding.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11,weight: .medium))
                    .foregroundStyle(ChatColors.tertiaryText)
            }
            .padding(.horizontal,12)
            .padding(.vertical,10)
            .contentShape(Rectangle())
            .onTapGesture {
                AppLogger.shared.info("[Collapse] tap block=\(block.id.uuidString.prefix(8)) wasExpanded=\(expandedBinding.wrappedValue) streaming=\(isStreaming) contentLen=\(block.content.count)", category: "ChatList.Collapse")
                block.thinkingUserToggled = true
                // [Stage 1 · §6.3 A2/A3 收口 2026-09-17] 此处原有
                // `if !expandedBinding.wrappedValue { block.flushThinkingBuffer() }`。
                // 该调用**恒为 no-op**（缓冲恒空，见上方说明），且已随缓冲一并删除 ——
                // 展开/收起本来就只由 `expandedBinding` 驱动，不需要"先把缓冲刷进 content"这一步。
                expandedBinding.wrappedValue.toggle()
            }

            if expandedBinding.wrappedValue,!block.content.isEmpty {
                let windowSz = 8000
                let total = block.content.count
                let truncatedFlag = total>windowSz
                let displayBody: String = {
                    guard truncatedFlag else { return block.content }
                    let startCellIdx = block.content.index(block.content.endIndex,offsetBy: -windowSz)
                    let cleanStart = block.content[startCellIdx...].firstIndex(of: "\n")
                        .map { block.content.index(after: $0) } ?? startCellIdx
                    return String(block.content[cleanStart...])
                }()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading,spacing: 0) {
                            if truncatedFlag {
                                Text("Showing last \(displayBody.count / 1000)K of \(total / 1000)K characters", comment: "Thinking window truncation hint")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal,12)
                                    .padding(.bottom,4)
                            }
                            Text(displayBody)
                                .font(.system(size: 13))
                                .foregroundStyle(ChatColors.tertiaryText)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity,alignment: .leading)
                                .padding(.horizontal,12)
                                .padding(.bottom,10)
                                .id("thinkingBottom")
                        }
                    }
                    .frame(maxHeight: 300)
                    // Follow the tail at FLUSH pace
                    .onChange(of: block.content.count) { _ in
                        guard isStreaming else { return }
                        withAnimation(.linear(duration: 0.15)) {
                            proxy.scrollTo("thinkingBottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        // 2026-09-02 唐唐反馈：结束态 0.15 在浅背景上几乎不可见（思考中灰底→结束"背景消失"的断裂感）。
        // 2026-09-02 唐唐定稿：恒定不透明灰（与工具指示器底一致，思考中/结束不切换）；
        // 完成态仅由最外层边框变绿表达。
        .background(Color(UIColor.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // 2026-09-02 唐唐定稿：思考中边框不变（蓝），完成后边框改绿。
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isStreaming ? Color.blue.opacity(0.15) : Color.green, lineWidth: 0.5)
        )
        // [Stage 1 · §6.3.2 A9] 此处原有 `.task(id: block.id) { … }`，其闭包体内**只有注释**、
        // 无任何语句 ⇒ 每次 block.id 变化都排期一个**空任务**。已删除该修饰符，但把那段注释
        // 记录的**决策**保留在下面（Q6：删注释不等于删决策，决策不应静默丢失）：
        //   2026-08-10 用户要求：思考块默认折叠、**永不自动展开**。原 autoExpand
        //   （UserDefaults `chat.autoExpandThinking`）自动展开逻辑已移除——即使用户设备残留
        //   旧值 true，新消息思考块也保持折叠；手动 tap 仍可展开（`ThinkingBlockView` 的
        //   onTapGesture 设 `thinkingUserToggled`，展开态仅保留在当前消息生命周期内，
        //   下次消息重建由适配层强制重置）。
        .onChange(of: isStreaming) { streaming in
            if !streaming,!block.thinkingUserToggled {
                AppLogger.shared.info("[Collapse] auto-collapse block=\(block.id.uuidString.prefix(8)) streaming→false userToggled=false contentLen=\(block.content.count)", category: "ChatList.Collapse")
                // [2026-09-09 并发违规治理] onChange 回调仍在 SwiftUI view update
                // 事务内，直接写 @ObservedObject 的 @Published 会触发
                // "Publishing changes from within view updates is not allowed"。
                // 推到下一 runloop：下方 :471 的 post 通知也顺延一帧，cell 高度
                // 失效晚一帧（本就是异步路径，可接受）。
                let blockID = block.id
                DispatchQueue.main.async { [weak block] in
                    guard let block, block.id == blockID else { return }
                    block.isThinkingExpanded = false
                }
            } else if !streaming {
                AppLogger.shared.info("[Collapse] stream-end-skip block=\(block.id.uuidString.prefix(8)) userToggled=\(block.thinkingUserToggled) currentlyExpanded=\(block.isThinkingExpanded)", category: "ChatList.Collapse")
            }
        }
        .onChange(of: block.isThinkingExpanded) { newValue in
            AppLogger.shared.info("[Collapse] post block=\(block.id.uuidString.prefix(8)) expanded=\(newValue) userToggled=\(block.thinkingUserToggled) streaming=\(isStreaming)", category: "ChatList.Collapse")
            NotificationCenter.default.post(name: .thinkingBlockToggled,
                                            object: block.id)
        }
    }
}

/// 三点弹跳指示器（2026-09-08 性能修复）：自持动画状态。
/// 此前 `dotsOn` 挂在 AssistantBlockView（含 MarkdownView）上——repeatForever
/// 每帧修改会重算包含富文本的整个块视图 body；抽成独立小 View 后动画只失效自身。
struct BouncingDots: View {
    @State private var dotsOn = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3,id: \.self) { i in
                Text(".")
                    .font(.system(size: 13,weight: .medium))
                    .foregroundStyle(ChatColors.primaryText)
                    .offset(y: dotsOn ? -2 : 1)
                    .animation(
                        Animation.easeInOut(duration: 0.35)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i)*0.12),
                        value: dotsOn
                    )
            }
        }
        .onAppear { dotsOn = true }
    }
}

struct TypingIndicator: View {
    @State private var dotOffsets: [Bool] = [false,false,false]
    @State private var soulName: String = {
        let n = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "MiniClaw" : n
    }()

    var body: some View {
        HStack(spacing: 0) {
            // 2026-09-05 本地化：hardcoded 英文 "is thinking" → thinking_suffix 键
            //（" 正在思考"，四语齐），与主 App AssistantStatusRow 同源。
            Text("\(soulName)\(String(localized: "thinking_suffix"))")
            ForEach(0..<3,id: \.self) { i in
                Text(".")
                    .offset(y: dotOffsets[i] ? -3 : 1)
            }
        }
        .font(.system(size: 15,weight: .medium))
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.top,0)
        .onAppear {
            for i in 0..<3 {
                withAnimation(
                    .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i)*0.15)
                ) {
                    dotOffsets[i] = true
                }
            }
        }
    }
}

struct ChatInputAppendListener: ViewModifier {
    let vm: MessageListModel
    @Binding var inputFocused: Bool

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .chatInputAppendRequested)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            vm.appendToInputText(text)
            //
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }
}

extension Notification.Name {
    static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled")
    /// chat's ChatView listens and forwards to `vm.appendToInputText`.
    static let chatInputAppendRequested = Notification.Name("chatInputAppendRequested")
    static let miniClawAttachmentSizeChanged = Notification.Name("miniClawAttachmentSizeChanged")
    /// tool_use. The active ChatView listens, maps the block to its
    /// re-runs the agent loop from there.
    static let rerunFromToolBlock = Notification.Name("rerunFromToolBlock")
}

/// its own ViewModifier (like ChatInputAppendListener) to keep ChatView's
/// body within the Swift type-checker budget.
///
struct RerunFromToolBlockListener: ViewModifier {
    let vm: MessageListModel

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .rerunFromToolBlock)) { note in
            guard let blockId = note.userInfo?["blockId"] as? UUID else { return }
            vm.retryFromToolBlock(blockId: blockId)
            vm.forceScrollToBottom.send()
        }
    }
}

/// Extracted out of ChatView.body because that body sits at the Swift
/// view's clear method. Extracted into its own modifier so ChatView's
/// 文件引用块(块级 SwiftUI):灰底圆角 + 图标 + 文件名,点击打开系统预览。
/// 块级渲染不受正文 lineSpacing 影响,无黑边(替代行内 FileAttachment 的展示路径)。
private struct FileBlockView: View {
    let url: String
    let fileName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(fileName.isEmpty ? "file" : fileName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            // [2026-09-12 修复·勿再整串编码] **禁止**对整串做
            // `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)`：
            // 实测 `miniclaw://shared/今日科技新闻-20260912.md` →
            // `miniclaw%3A//shared/…`，**scheme 被毁**（scheme=nil）⇒ 统一解析器接不到 ⇒ 点击无反应。
            // 中文 `URL(string:)` 本来就能正确解析（scheme/host/path 均正确）；
            // 只有**空格**会让它返回 nil —— 此时仅把空格替换为 %20 再试。
            let constructed = URL(string: url)
                ?? URL(string: url.replacingOccurrences(of: " ", with: "%20"))
            AppLogger.shared.info("[FileOpen] tap raw=\"\(url)\" constructed=\(constructed?.absoluteString ?? "nil") scheme=\(constructed?.scheme ?? "nil") host=\(constructed?.host ?? "nil")", category: "FileOpen")
            if let constructed {
                NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: constructed)
            }
        }
    }
}

struct AssistantBlockView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: RenderMessage
    let isActiveMessage: Bool
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onTapBlank: ((CGPoint) -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// Selection-menu read-aloud hooks, plumbed
    /// down to MarkdownView (nil for non-text or streaming contexts).
    var onReadAloud: (() -> Void)?
    var onSpeakText: ((String) -> Void)?
    var browserPool: MiniClawTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    /// 快照桥（主会话 cell 传入）：透传给浮层，结果快照更新时浮层实时刷新。
    var snapshotBridge: CellStateBridge? = nil
    /// [2026-09-12 裁尾修复] 本块可用的**真实内容宽度**（= cell 宽 − 2×块内边距），由
    /// `BridgedAssistantBlock` 传入并透传给 `MarkdownView.sizeThatFits`。nil（非列表场景）时
    /// MarkdownView 退回自解析链。见 MarkdownView.contentWidth 的完整根因说明。
    var contentWidth: CGFloat? = nil
    @Binding var highlightedBlockId: UUID?
    @Binding var detailBlock: AssistantBlock?
    private var isHighlighted: Bool { highlightedBlockId == block.id }
    /// 本块是否仍在流式输出（与 ThinkingBlockView 的构造口径一致：`:731`）。
    /// 传给 MarkdownView 作为**显式终态信号**——终态回写富文本缓存不能再靠
    /// 「缓存是否已存在」反推（自依赖，缓存缺失时永远打不开）。
    private var isStreamingBlock: Bool {
        isActiveMessage && message.blocks.last?.id == block.id
    }

    var body: some View {
        switch block.kind {
        case .text:
            if block.hasVisibleText {
                textBlockView
                    .padding(.vertical,2)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(ChatColors.accent.opacity(isHighlighted ? 0.10 : 0))
                    )
            }
        case .thinking:
            ThinkingBlockView(
                block: block,
                isStreaming: isActiveMessage && message.blocks.last?.id == block.id
            )
            // [Fix 2026-08-11] 显式靠左:外层容器 frame(maxWidth:.infinity) 会把
            // 收缩后的 HStack 居中,加 .leading 对齐保证思考指示器靠左。
            .frame(maxWidth: .infinity,alignment: .leading)
            .padding(.vertical,2)
        case .shellTool:
            ToolCapsuleView(block: block, icon: "terminal", accentColor: .green,
                            commandStartTime: commandStartTime,onStop: onStop,browserPool: browserPool,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .fileReadTool:
            ToolCapsuleView(block: block, icon: "doc.text", accentColor: .cyan,
                            commandStartTime: commandStartTime,onStop: onStop,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .fileWriteTool:
            ToolCapsuleView(block: block, icon: "doc.text.fill", accentColor: .blue,
                            commandStartTime: commandStartTime,onStop: onStop,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .fileEditTool:
            ToolCapsuleView(block: block, icon: "square.and.pencil", accentColor: .orange,
                            commandStartTime: commandStartTime,onStop: onStop,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .browserTool:
            ToolCapsuleView(block: block, icon: "globe", accentColor: .blue,
                            commandStartTime: commandStartTime,onStop: onStop,browserPool: browserPool,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .readImageTool:
            ToolCapsuleView(block: block, icon: "photo", accentColor: .purple,
                            commandStartTime: commandStartTime,onStop: onStop,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .subagentTool:
            ToolCapsuleView(block: block, icon: "person.2.fill", accentColor: .purple,
                            commandStartTime: commandStartTime,onStop: onStop,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .memoryTool:
            ToolCapsuleView(block: block, icon: "brain.head.profile", accentColor: .pink,
                            commandStartTime: commandStartTime,onStop: onStop,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .info:
            // [治本 2026-09-17] **原处有一份"哪些行会被渲染"的私有实现**，而播种侧另有一份
            // "按原始行数外推"的猜测 —— 两者必然漂移（真机：播种 148 / 真值 20.3）。
            // 现统一读 `AssistantBlockKind` 上的唯一实现：视图怎么显示，播种就怎么算。
            let displayReasons = AssistantBlockKind.infoDisplayedLines(block.content)
            let switchedLine = AssistantBlockKind.infoSwitchedLine(block.content)
            VStack(alignment: .leading,spacing: 3) {
                ForEach(Array(displayReasons.enumerated()),id: \.offset) { _,line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(ChatColors.primaryText.opacity(0.45))
                        .lineLimit(2)
                }
                if let switchedLine {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10,weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.8))
                        Text(switchedLine)
                            .font(.system(size: 11,weight: .medium))
                            .foregroundStyle(ChatColors.primaryText.opacity(0.75))
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity,alignment: .leading)
            .padding(.horizontal,10)
            .padding(.vertical,7)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.14),lineWidth: 0.5))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = block.content
                } label: {
                    Label(String(localized: "Copy Error"), systemImage: "doc.on.doc")
                }
            }
        case .file(let url):
            FileBlockView(url: url, fileName: block.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var textBlockView: some View {
        // [2026-09-13 清理定论] 曾评估一条「自绘 TextKit1 承载视图」的替代渲染路线
        //（2026-09-08 阶段 1/2 建立，同日 17:00 因「与 collection 自 sizing 的交互存在
        // 未解回归（滑动排版叠加）」止血下线）。方法级复核结论：该路线的高度算法
        //（裸 NSLayoutManager usedRect+8）与已被真机证伪的测量口径同款（矮 12.3pt →
        // 尾部半行被裁），且未接 MessageListLayout.deferSelfSizing —— 回归根因即在此。
        // 故**不采用该路线**，其实现已移除；唯一列入 backlog 的是它的「后台渲染
        // attributed」能力（本路径正文渲染在主线程，仅靠后台高度预热规避长会话阻塞）。
        // 保留的确定性修复：流式渲染节流、统一缓存 LRU 1024、
        // mtv 测量赋值绕 UITextView setter、MCP 预热/超时/负缓存、userBubbleMemo。
        markdownView
    }

    private var markdownView: some View {
        MarkdownView(
            markdown: block.content,
            cachedContent: block.cachedMarkdown,
            cachedAttributedString: block.cachedAttributedString,
            isStreaming: isStreamingBlock,
            messageId: message.id,
            blockId: block.id,
            onTapBlank: onTapBlank,
            onCopyScreenshot: onCopyScreenshot,
            onReadAloud: onReadAloud,
            onSpeakText: onSpeakText,
            // 终态渲染结果回写块缓存（2026-09-08）：cacheRenderedContent() 从未
            // 被接线 → cachedAttributedString 恒 nil → 同块在每个 cell 实例上反复
            // 全量渲染（真机 RenderTrace 实证）。复用首次渲染写回，后续 cell 实例/
            // 重进会话直接命中。
            // [2026-09-09 截短锁死修复] 回写从「判 nil 防覆盖」改为**覆盖式**：
            // 工具挂载会让块提前被判终态（isStreamingBlock 只认 blocks.last），
            // 此时回写的是**缺尾包的中间态**；内容随后增长，若仍判 nil 防覆盖，
            // 旧短版会被 prebuilt 采用点永久锁死（真机 IMG_4605 正文截短）。
            // 改为「缓存缺失或指纹≠当前内容」即覆盖，缓存永远追赶内容；
            // 内容稳定后指纹相等，自然收敛为不再覆盖。
            // [2026-09-09 指纹同源修复] 指纹取**渲染输入**的 renderedFingerprint，不取
            // 回调时刻的 block.content.count——后者在 body 求值之后可能已被 Bridge
            // 改写（流式 ~100ms/次），会让指纹指向新内容而 att 是旧内容的渲染结果，
            // prebuilt 长度校验恰好通过 → 正文被钉在旧版本（回复中工具挂载后正文
            // 截短，滑动/复用均不恢复，只有重进会话才恢复）。
            onRendered: { att, renderedFingerprint in
                // 空产物不入缓存：空 att 回写后会被 MarkdownView 的
                // prebuilt 路径反复采用 → attrText=0 死循环（配合使用点 length>0
                // 校验，双保险）。
                if att.length > 0,
                   block.cachedAttributedString == nil
                    || block.cachedAttrFingerprint != renderedFingerprint {
                    // [2026-09-09 诊断] 覆盖式回写发生 = 缓存曾落后于内容（工具挂载
                    // 时被当终态回写过缺尾包中间态）。低频，打 info 定位锁死源头。
                    if block.cachedAttributedString != nil {
                        AppLogger.shared.info("[Prebuilt] OVERWRITE block=\(block.id.uuidString.prefix(8)) cachedFp=\(block.cachedAttrFingerprint.map(String.init) ?? "nil")→\(renderedFingerprint) — 缓存追赶内容", category: "MarkdownSTF")
                    }
                    block.cachedAttributedString = att
                    block.cachedAttrFingerprint = renderedFingerprint
                }
            },
            // [2026-09-09 截短锁死修复] prebuilt 内容指纹：采用点据此校验缓存是否
            // 对应当前内容（nil=缓存尚未建立，同样放行走渲染路径）。
            prebuiltFingerprint: block.cachedAttrFingerprint,
            // [2026-09-12 裁尾修复] 透传真实内容宽度：让首次（理想尺寸）pass 也按内容宽排版，
            // 避免按边界宽测出偏矮高度被 fixedSize(vertical:) 钉死 → 尾部行被裁。
            contentWidth: contentWidth
        )
        .fixedSize(horizontal: false,vertical: true)
        .modifier(MiniClawOpenURLHandler())
    }
}

struct ShimmerOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    private var peakOpacity: CGFloat {
        colorScheme == .light ? 0.75 : 0.25
    }

    private func bell(_ x: CGFloat) -> CGFloat {
        exp(-4.5*x*x)
    }

    private var stableStops: [Gradient.Stop] {
        let stepCount = 12
        let bandRadiusVal: CGFloat = 0.40
        let center: CGFloat = 0.5
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: .white.opacity(0),location: 0))
        for i in 0...stepCount {
            let frac = CGFloat(i)/CGFloat(stepCount)
            let pos = center-bandRadiusVal+frac*bandRadiusVal*2.0
            let dist = (pos-center)/bandRadiusVal
            let alpha = bell(dist)*peakOpacity
            stops.append(.init(color: .white.opacity(Double(alpha)),location: pos))
        }
        stops.append(.init(color: .white.opacity(0),location: 1))
        return stops
    }

    var body: some View {
        GeometryReader { geo in
            let diag = geo.size.width+geo.size.height
            // 2026-09-05 修复：repeatForever 动画在 Collection cell 离屏时被系统
            // 暂停、回屏不恢复——手机上 pill 一旦离屏过，流光即永久消失（Mac 窗口
            // 大 pill 常驻可见，故 Mac 上一直正常）。改为 TimelineView 按墙钟时间
            // 计算光带位置：不依赖动画状态存活，任何时刻回屏自动继续。
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let period = 2.8
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: stableStops,
                            startPoint: UnitPoint(x: 0,y: 1),
                            endPoint: UnitPoint(x: 1,y: 0)
                        )
                    )
                    .frame(width: diag,height: geo.size.height)
                    .offset(x: (-1.0 + phase * 2.0) * geo.size.width)
            }
        }
        .clipped()
    }
}

