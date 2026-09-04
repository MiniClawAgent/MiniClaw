import SwiftUI
import Combine

// MARK: - Assistant Block View (individual block — isolated invalidation)

@MainActor
final class ThinkingHitchMonitor {
    static let shared = ThinkingHitchMonitor()
    private let logger = AppLogger(category: "ThinkPerf")
    private var cadLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// Body-eval counter since start (bumped by the view; sampled into hitch logs).
    var bodyEvalCount = 0
    var contentLenProvider: (() -> Int)?
    /// The block that started the monitor. Stops from OTHER blocks are ignored —
    /// with several thinking blocks in one chat, an older (collapsed / finished)
    /// block's task(id:) firing false must not kill the live block's monitor.
    private var ownerId: UUID?

    func start(owner: UUID) {
        if cadLink != nil {
            ownerId = owner  // live monitor adopted by the newest streaming block
            if collapseAt != nil {
                collapseAt = nil  // re-expanded within the grace window
                logger.info("[ThinkPerf] phase → EXPANDED (re-expand)")
            }
            return
        }
        ownerId = owner
        lastTick = 0
        bodyEvalCount = 0
        let link = CADisplayLink(target: self,selector: #selector(tick(_:)))
        link.add(to: .main,forMode: .common)
        cadLink = link
        logger.info("[ThinkPerf] hitch-monitor START owner=\(owner.uuidString.prefix(8))")
    }

    /// When the owner collapses, keep sampling for a grace window so the
    /// COLLAPSED state's frame stats can be compared A/B against EXPANDED
    /// under the same interactions. Frame lines are tagged with the phase.
    private var collapseAt: CFTimeInterval?
    private static let collapsedGraceSeconds: CFTimeInterval = 25

    func stop(owner: UUID) {
        guard cadLink != nil,owner == ownerId else { return }
        collapseAt = CACurrentMediaTime()
        logger.info("[ThinkPerf] phase → COLLAPSED (monitor continues \(Int(Self.collapsedGraceSeconds))s for A/B) bodyEvals=\(self.bodyEvalCount)")
    }

    private func stopHard() {
        cadLink?.invalidate()
        cadLink = nil
        ownerId = nil
        collapseAt = nil
        logger.info("[ThinkPerf] hitch-monitor STOP bodyEvals=\(self.bodyEvalCount)")
    }

    // Per-second frame statistics: dropped-frame count (>33ms), worst gap, and
    // frame count — a per-second FPS/drop summary shows sub-100ms jank the
    // single HITCH threshold misses.
    private var statWinStart: CFTimeInterval = 0
    private var statFrameCnt = 0
    private var statDropCnt = 0
    private var statWorstMsVal: Double = 0

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTick = link.timestamp }
        guard lastTick>0 else { statWinStart = link.timestamp; return }
        let gapMs = (link.timestamp-lastTick)*1000
        statFrameCnt += 1
        if gapMs>33 { statDropCnt += 1 }
        if gapMs>statWorstMsVal { statWorstMsVal = gapMs }
        if gapMs>100 {
            logger.info("[ThinkPerf] HITCH gap=\(Int(gapMs))ms contentLen=\(self.contentLenProvider?() ?? -1) bodyEvals=\(self.bodyEvalCount)")
        }
        let windowDt = link.timestamp-statWinStart
        if windowDt >= 1.0 {
            let fps = Double(statFrameCnt)/windowDt
            let phase = collapseAt == nil ? "EXP" : "COL"
            // [T-log-noise-privacy 2026-07-18] info → debug: per-second frame
            // stats; the HITCH lines (rare, actionable) stay at info.
            logger.debug("[ThinkPerf] [\(phase)] frames/s=\(Int(fps)) dropped=\(self.statDropCnt) worst=\(Int(self.statWorstMsVal))ms contentLen=\(self.contentLenProvider?() ?? -1) bodyEvals=\(self.bodyEvalCount)")
            statWinStart = link.timestamp
            statFrameCnt = 0
            statDropCnt = 0
            statWorstMsVal = 0
        }
        if let c = collapseAt,link.timestamp-c>Self.collapsedGraceSeconds {
            stopHard()
        }
    }
}

struct DismissImmersiveCoversListener: ViewModifier {
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .dismissAllImmersivePresentations)) { _ in
            onDismiss()
        }
    }
}

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
    @State private var dotsOn = false
    /// [T-tool-bg-suspended-hint] Drives the background-suspension info alert.
    @State private var bgHintAlert = false
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    /// Show the yellow ⓘ hint only when this tool was flagged as background-
    /// suspended AND enhanced background isn't already effective (nothing to
    /// suggest if it's on). Mirrors the BackgroundInterruptionTracker gate.
    private var bgSuspendHint: Bool {
        block.wasBackgroundSuspended && !keepAlive.enhancedBackgroundEffective
    }
    /// [T-ios-retry-hide-when-processing] Used to suppress the "Re-run From
    /// Here" long-press menu item while the agent loop is busy — tapping it
    /// mid-run would corrupt the in-flight processing state.
    @EnvironmentObject private var vm: MessageListModel

    /// Display text: prefer LLM-generated toolSummary, fall back to toolDescription.
    private var displayStr: String {
        if let summary = block.toolSummary,!summary.isEmpty {
            return summary
        }
        return block.toolDescription
    }

    /// [T-ios-tool-bubble-longpress-menu] Human-readable, paste-back-able
    /// dump of this tool call + its result for the "Copy Tool Details"
    /// menu action. Pulls tool name from the block kind, the input JSON
    /// from toolInputArgs (pretty-printed when it parses), and the result
    /// text + status from the block's content / toolStatus (with the
    /// snapshot text as a fallback source).
    private var toolClip: String {
        // Tool name from the block kind.
        let toolName: String
        switch block.kind {
        case .shellTool:     toolName = "shell_execute"
        case .fileReadTool:  toolName = "file_read"
        case .fileWriteTool: toolName = "file_write"
        case .fileEditTool:  toolName = "file_edit"
        case .browserTool:   toolName = "browser_use"
        case .readImageTool: toolName = "read_image"
        case .memoryTool:    toolName = "memory"
        case .text, .thinking, .info: toolName = "unknown"
        case .file: toolName = "file"
        }

        // Pretty-print the input JSON when possible; otherwise emit raw.
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

        // Result text: prefer the live block content, fall back to the
        // snapshot text matched by toolUseId.
        var resultText = block.content
        if resultText.isEmpty,let tuId = block.toolUseId,
           let snap = toolSnapshots.first(where: { $0.id == tuId }) {
            resultText = snap.snapshot.text ?? ""
        }
        let hasScreenshot = block.imageFilePath != nil
            || (block.toolUseId.flatMap { tuId in toolSnapshots.first(where: { $0.id == tuId }) }?.snapshot.type == .image)

        // Status string.
        let statusLabel: String
        switch block.toolStatus {
        case .success:   statusLabel = "success"
        case .failed:    statusLabel = "failed"
        case .cancelled: statusLabel = "cancelled"
        case .running:   statusLabel = "running"
        case .streaming: statusLabel = "streaming"
        case .none:      statusLabel = "unknown"
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
                // Status indicator / icon
                statusOrGlyph

                // Description text with bouncing dots during streaming
                HStack(spacing: 0) {
                    Text(displayStr)
                        .font(.system(size: 13,weight: .medium))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineLimit(1)
                    if isStreaming {
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
                }
                .lineLimit(1)

                // Execution duration (shown after completion). The HH:mm:ss
                // start time is surfaced inside the detail view's bottom bar
                // (ToolLiveSheet.bottomBar) instead of here — the inline
                // pill list stays clean.
                if let dur = durationLabel {
                    Text(dur)
                        .font(.system(size: 11,weight: .regular,design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }

                // Stop button for running commands
                if case .running = block.toolStatus {
                    Button {
                        onStop?()
                    } label: {
                        // Visual: 10×10 red square unchanged. Hit area enlarged to
                        // 24×24 via an expanded contentShape, while the negative
                        // padding pins the *layout* footprint back to 18×18 so the
                        // capsule width/height is identical to before.
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
                // [T-ios-msg-contextmenu-recursion-crash] Gate the eager menu
                // tree behind an Equatable key so this tool cell's body churn
                // during `gh`/shell streaming doesn't rebuild + re-diff the menu
                // subtree every frame (part of the deep ContextMenuModifier
                // recursion in incident 98E8805F). `toolClip` is read
                // lazily at TAP time, so the key only tracks structure: the tool
                // (blockId) and whether the Re-run branch is shown (isProcessing).
                EquatableMenuGate(key: ToolMenuKey(
                    blockId: block.id,
                    processing: vm.isProcessing
                )) {
                    // [T-ios-tool-bubble-longpress-menu]
                    Button {
                        UIPasteboard.general.string = toolClip
                    } label: {
                        Label(String(localized: "Copy Tool Details"), systemImage: "doc.on.doc")
                    }
                    // [T-ios-retry-hide-when-processing] Only expose the
                    // destructive Re-run action when the agent loop is idle.
                    // Re-running mid-stream would tear down an in-flight turn
                    // and confuse downstream state — hide both the divider and
                    // the button as a group so the menu doesn't leave a
                    // trailing separator with nothing under it.
                    if !vm.isProcessing {
                        Divider()
                        Button(role: .destructive) {
                            // Re-run the whole assistant turn that owns this
                            // tool_use. Routed via notification so we don't have
                            // to thread a vm closure through the 4-layer cell
                            // hosting chain — ChatView's RerunFromToolBlockListener
                            // maps blockId → owning assistant msg → preceding user
                            // msg → vm.retryFromMessage.
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
            // [T-tool-bg-suspended-hint] Yellow ⓘ just outside the capsule's
            // trailing edge when this tool was likely suspended by the OS in the
            // background. Tapping shows an alert offering to enable enhanced
            // background (deep-links to Settings → Permissions → Background).
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
                // Deep-link to Settings → Permissions → Background, nudging the
                // recommended rows ON — they highlight only while still OFF
                // (= miniclaw://settings/background?focus=…:true,…:true). Location
                // Tracking is included so the background heartbeat that keeps the
                // task Live Activity refreshing in real time gets enabled too.
                DeepLinkCoordinator.shared.setFocus(
                    rawQueryValue: "enhancedBackgroundExecution:true,backgroundSpeakEnabled:true,locationTrackingEnabled:true")
                DeepLinkCoordinator.shared.pendingSettingsTarget = .background
            }
            Button(String(localized: "Maybe Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "This tool may have been paused by the system while running in the background. Enable enhanced background execution to improve background task reliability."))
        }
        .onChange(of: isStreaming) { streaming in
            dotsOn = streaming
        }
        .onAppear {
            if isStreaming {
                dotsOn = true
            }
        }
    }

    // MARK: - Status / Icon

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

    /// Formatted execution duration (e.g. "1.2s", "45s", "2m 10s").
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

    /// Bind to block.isThinkingExpanded so state survives cell reuse and triggers cell re-sizing.
    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { block.isThinkingExpanded },
            set: { block.isThinkingExpanded = $0 }
        )
    }

    init(block: AssistantBlock,isStreaming: Bool) {
        self.block = block
        self.isStreaming = isStreaming
        // Auto-expand-on-stream is handled in `.onAppear` (gated by block.id)
        // rather than from `init`. Mutating @Published from a SwiftUI view
        // initializer fires for every cell-reuse pass and was reaching the
        // wrong block when the cell was being recycled between an earlier
        // (frozen) thinking block and the currently-streaming one — manifesting
        // as "tap an old thinking block, see the streaming block's content."
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
                if block.content.count>0 || block.thinkingContentBuffer.count>0 {
                    let charCnt = max(block.content.count,block.thinkingContentBuffer.count)
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
                // Mark before flipping so any concurrent stream-end collapse
                // observer in this view sees `thinkingUserToggled = true`
                // and bails out instead of stomping the user's choice.
                // The collection view's cached height is invalidated by the
                // `onChange(of: isThinkingExpanded)` observer below — single
                // source of truth so the auto-collapse path stays in sync.
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] tap block=\(block.id.uuidString.prefix(8)) wasExpanded=\(expandedBinding.wrappedValue) streaming=\(isStreaming) contentLen=\(block.content.count)")
                block.thinkingUserToggled = true
                if !expandedBinding.wrappedValue {
                    block.flushThinkingBuffer()
                }
                expandedBinding.wrappedValue.toggle()
            }

            // Content — only visible when expanded, windowed to the tail
            // to prevent UI freeze on very long thinking (T-thinking-render-perf-ios).
            if expandedBinding.wrappedValue,!block.content.isEmpty {
                let windowSz = 8000
                let total = block.content.count
                let truncatedFlag = total>windowSz
                let displayBody: String = {
                    // [T-thinking-stream-jank] Time the tail-window slice and count
                    // body re-evals. This closure runs on EVERY body evaluation of
                    // an expanded thinking block — if body re-evals track the
                    // per-token contentUpdateSeq rather than the 0.3s flush, the
                    // eval counter in the 1s summary exposes it directly.
                    let t0 = CFAbsoluteTimeGetCurrent()
                    defer {
                        let ms = (CFAbsoluteTimeGetCurrent()-t0)*1000
                        ThinkingHitchMonitor.shared.bodyEvalCount += 1
                        if ms>4 {
                            AppLogger(category: "ThinkPerf").info("[ThinkPerf] slice SLOW total=\(total) took=\(String(format: "%.1f", ms))ms eval#\(ThinkingHitchMonitor.shared.bodyEvalCount)")
                        }
                    }
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
                    // [T-thinking-stream-jank] Follow the tail at FLUSH pace
                    // (content updates every 0.3s), not per token. The old
                    // trigger was the per-delta contentUpdateSeq — with it
                    // @Published, an expanded block re-ran body + an animated
                    // scrollTo for every delta (~60-105/s measured); the flush
                    // pace is ~3-4/s for the same visual result.
                    .onChange(of: block.content.count) { len in
                        guard isStreaming else { return }
                        AppLogger(category: "ThinkPerf").debug("[ThinkPerf] scrollTo(flush) contentLen=\(len) seq=\(block.contentUpdateSeq)")
                        withAnimation(.linear(duration: 0.15)) {
                            proxy.scrollTo("thinkingBottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        // [T-thinking-stream-jank] Hitch monitor runs while this block is
        // EXPANDED — streaming or static. The refined report says the jank is
        // tied to the expanded state itself (collapse instantly recovers), so
        // the monitor must also capture expanded-static interactions (list
        // scrolling, new messages arriving) to compare against collapsed.
        .task(id: expandedBinding.wrappedValue) {
            if expandedBinding.wrappedValue {
                ThinkingHitchMonitor.shared.contentLenProvider = { [weak block] in
                    block?.thinkingContentBuffer.count ?? -1
                }
                ThinkingHitchMonitor.shared.start(owner: block.id)
            } else {
                ThinkingHitchMonitor.shared.stop(owner: block.id)
            }
        }
        .onDisappear {
            ThinkingHitchMonitor.shared.stop(owner: block.id)
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
        .task(id: block.id) {
            // 2026-08-10 用户要求:思考块默认折叠,永不自动展开。
            // 原 autoExpand(UserDefaults chat.autoExpandThinking)自动展开逻辑
            // 已移除——即使用户设备残留旧值 true,新消息思考块也保持折叠;
            // 手动 tap 仍可展开(ThinkingBlockView 的 onTapGesture 设置
            // thinkingUserToggled,展开状态仅保留在当前消息生命周期内,
            // 下次消息重建时由适配层强制重置)。
        }
        .onChange(of: isStreaming) { streaming in
            // Auto-collapse when streaming for THIS block ends, but only if
            // the user hasn't manually toggled it. Without the user-touched
            // gate, the streaming-end transition stomped a tap the user did
            // on an earlier thinking block while a later one was still live.
            if !streaming,!block.thinkingUserToggled {
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] auto-collapse block=\(block.id.uuidString.prefix(8)) streaming→false userToggled=false contentLen=\(block.content.count)")
                block.isThinkingExpanded = false
            } else if !streaming {
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] stream-end-skip block=\(block.id.uuidString.prefix(8)) userToggled=\(block.thinkingUserToggled) currentlyExpanded=\(block.isThinkingExpanded)")
            }
        }
        .onChange(of: block.isThinkingExpanded) { newValue in
            // Single source of truth for cell-height invalidation: fires
            // for BOTH manual taps and the stream-end auto-collapse path
            // above. Previously only the tap gesture posted this, so when
            // a long thinking block auto-collapsed at stream end, the
            // UICollectionView kept the expanded cell height (~300pt) and
            // rendered a tall empty gap below the pill — see 2026-05-17
            // screenshot bug.
            AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] post block=\(block.id.uuidString.prefix(8)) expanded=\(newValue) userToggled=\(block.thinkingUserToggled) streaming=\(isStreaming)")
            NotificationCenter.default.post(name: .thinkingBlockToggled,
                                            object: block.id)
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotOffsets: [Bool] = [false,false,false]
    /// Live Soul name so the indicator reads "<custom name> is thinking…" when
    /// the user has renamed the assistant in Soul settings. Updates via
    /// `.soulMdChanged` Notification — same wiring used by `AssistantSoulName`.
    @State private var soulName: String = {
        let n = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "MiniClaw" : n
    }()

    var body: some View {
        // The thinking-level badge that used to trail this indicator was
        // removed — the nav-bar title (ChatView.thinkingLevelBadge) is now
        // the single place that shows and changes the thinking level, so a
        // duplicate here was redundant. ThinkingLevelSheetView is unchanged;
        // it's still presented from the nav-bar badge.
        HStack(spacing: 0) {
            Text("\(soulName) is thinking")
            ForEach(0..<3,id: \.self) { i in
                Text(".")
                    .offset(y: dotOffsets[i] ? -3 : 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            let n = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            soulName = n.isEmpty ? "MiniClaw" : n
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

// MARK: - Thinking Level Sheet

struct ChatInputAppendListener: ViewModifier {
    let vm: MessageListModel
    @Binding var inputFocused: Bool

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .chatInputAppendRequested)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            vm.appendToInputText(text)
            // Focus the composer + pop the keyboard so the user can
            // immediately continue typing after a long-press → Add to Chat
            // Input. Independent of the post-reply auto-pop Settings
            // toggle (#354 / eb6d8164) — that gate is for *passive*
            // moments (reply finished, scroll, etc.); this is a direct
            // user gesture and should always focus. (T-add-to-input-focus)
            //
            // Async hop so the inputText `didSet` settles into the
            // composer's TextField before the focus binding flips —
            // without it the keyboard occasionally pops first and the
            // text appears mid-animation.
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }
}

// MARK: - Thinking Block View

/// [T-thinking-stream-jank] Main-thread hitch monitor, active only while an
/// expanded thinking block is streaming. Logs frame gaps > 100ms together with
/// the current thinking length so hitches can be correlated with content size.
/// One shared instance — at most one thinking block streams at a time.
private struct ToolCopyButton: View {
    var accentColor: Color = .green
    let content: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = content()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now()+1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 16,height: 16)
                .foregroundStyle(copied ? accentColor : accentColor.opacity(0.4))
        }
        .animation(.easeInOut(duration: 0.15),value: copied)
    }
}

extension Notification.Name {
    static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled")
    /// Posted when a long-press selection menu's "Add to Chat Input" action
    /// fires. userInfo["text"] is the selected text to append. The active
    /// chat's ChatView listens and forwards to `vm.appendToInputText`.
    static let chatInputAppendRequested = Notification.Name("chatInputAppendRequested")
    /// Posted when an inline media attachment (image / video thumbnail /
    /// audio waveform) finishes async loading and its intrinsic content
    /// size changes. The collection view listens and invalidates self-sizing
    /// caches so cells re-measure. notification.object is the source URL
    /// string (for logging only — handler invalidates all visible cells).
    /// [T-attachment-size-invalidate 2026-05-21]
    static let miniClawAttachmentSizeChanged = Notification.Name("miniClawAttachmentSizeChanged")
    /// Posted from a tool capsule's long-press menu "Re-run from here".
    /// userInfo["blockId"] is the AssistantBlock.id (UUID) of the tapped
    /// tool_use. The active ChatView listens, maps the block to its
    /// owning assistant message, finds the preceding user message, and
    /// re-runs the agent loop from there. [T-ios-tool-bubble-longpress-menu]
    static let rerunFromToolBlock = Notification.Name("rerunFromToolBlock")
}

/// Listens for `.rerunFromToolBlock` and drives the re-run. Extracted into
/// its own ViewModifier (like ChatInputAppendListener) to keep ChatView's
/// body within the Swift type-checker budget. [T-ios-tool-bubble-longpress-menu]
///
/// "Re-run from here" semantics (block boundary —
/// T-ios-rerun-from-tool-block-position): re-run from the exact point this
/// tool_use was about to be issued. retryFromToolBlock keeps the blocks
/// BEFORE the target tool_use within its assistant turn, drops the target
/// block + later blocks in that turn + all later messages (rewriting the
/// trimmed assistant row in the DB), then re-runs the agent loop. If the
/// target is the first block with nothing preceding it, that path degrades
/// to a preceding-user-message truncation automatically.
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

/// View-modifier wrapper around the `chatInputAppendRequested` listener.
/// Extracted out of ChatView.body because that body sits at the Swift
/// type-checker's expression budget and inlining another `.onReceive` block
/// trips the "compiler unable to type-check this expression in reasonable
/// time" diagnostic.
/// Listens for `.dismissAllImmersivePresentations` and calls the host
/// view's clear method. Extracted into its own modifier so ChatView's
/// body type stays demangleable — adding the onReceive directly to body
/// trips the Swift type-checker timeout (same class of issue as the
/// 2026-04-17 inputBar / 2026-05-24 attachmentMenu blow-ups).
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
            if let u = URL(string: url) {
                NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: u)
            }
        }
    }
}

struct AssistantBlockView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    let isActiveMessage: Bool
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onTapBlank: ((CGPoint) -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// [T-selection-menu-tts] Selection-menu read-aloud hooks, plumbed
    /// down to SelectableMarkdownView (nil for non-text or streaming contexts).
    var onReadAloud: (() -> Void)?
    var onSpeakText: ((String) -> Void)?
    var browserPool: MiniClawTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    /// 快照桥（主会话 cell 传入）：透传给浮层，结果快照更新时浮层实时刷新。
    var snapshotBridge: CellStateBridge? = nil
    @Binding var highlightedBlockId: UUID?
    @Binding var detailBlock: AssistantBlock?
    private var isHighlighted: Bool { highlightedBlockId == block.id }

    var body: some View {
        switch block.kind {
        case .text:
            if !block.content.isEmpty {
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
        case .memoryTool:
            ToolCapsuleView(block: block, icon: "brain.head.profile", accentColor: .pink,
                            commandStartTime: commandStartTime,onStop: onStop,
                            toolSnapshots: toolSnapshots,snapshotBridge: snapshotBridge,detailBlock: $detailBlock)
        case .info:
            let allLines = block.content.components(separatedBy: "\n").filter { !$0.isEmpty }
            // Separate reason lines (⚠️) from the final switched line (✅)
            let reasonLinesList = allLines.filter { $0.hasPrefix("⚠️") }
            let switchedLine = allLines.first { !$0.hasPrefix("⚠️") && !$0.isEmpty }
            // Truncate middle if more than 9 reason lines
            let displayReasons: [String] = {
                if reasonLinesList.count <= 9 { return reasonLinesList }
                return Array(reasonLinesList.prefix(4))+[String(localized: "⋯ \(reasonLinesList.count - 8) more")]+Array(reasonLinesList.suffix(4))
            }()
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
        SelectableMarkdownView(
            markdown: block.content,
            cachedContent: block.cachedMarkdown,
            cachedAttributedString: block.cachedAttributedString,
            messageId: message.id,
            blockId: block.id,
            onTapBlank: onTapBlank,
            onCopyScreenshot: onCopyScreenshot,
            onReadAloud: onReadAloud,
            onSpeakText: onSpeakText
        )
        .fixedSize(horizontal: false,vertical: true)
        .modifier(MiniClawOpenURLHandler())
    }
}

// MARK: - Shimmer Overlay (continuous diagonal shine via offset animation)

/// A diagonal shimmer band that sweeps from top-leading to bottom-trailing.
/// Uses a single stable gradient with an animated offset rather than rebuilding
/// gradient stops every frame — avoids a CAGradientLayer colorspace teardown
/// race during CATransaction flush (EXC_BAD_ACCESS at encode_colorspace).
struct ShimmerOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var offsetX: CGFloat = -1.0

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
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: stableStops,
                        startPoint: UnitPoint(x: 0,y: 1),
                        endPoint: UnitPoint(x: 1,y: 0)
                    )
                )
                .frame(width: diag,height: geo.size.height)
                .offset(x: offsetX*geo.size.width)
                .onAppear {
                    withAnimation(
                        .linear(duration: 2.8)
                        .repeatForever(autoreverses: false)
                    ) {
                        offsetX = 1.0
                    }
                }
        }
        .clipped()
    }
}

// MARK: - Tool Capsule View (unified pill for all tool types)

struct ThinkingLevelSheetView: View {
    let currentLevel: ThinkingLevel
    let availableLevels: [ThinkingLevel]
    let onSelect: (ThinkingLevel) -> Void

    var body: some View {
        NavigationStack {
            List {
                thinkingRow(level: .off,isSelected: !currentLevel.isEnabled)
                Section {
                    ForEach(availableLevels,id: \.self) { level in
                        thinkingRow(level: level,isSelected: currentLevel == level)
                    }
                }
            }
            .navigationTitle(String(localized: "Thinking Intensity"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func thinkingRow(level: ThinkingLevel,isSelected: Bool) -> some View {
        Button {
            onSelect(level)
        } label: {
            HStack {
                Image("ThinkingIcon")
                    .resizable()
                    .frame(width: 16,height: 16)
                    .opacity(level == .off ? 0.4 : 1.0)
                Text(level.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ChatColors.primaryText)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Tool Copy Button
