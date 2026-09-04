import SwiftUI
import UIKit

// MARK: - Chat Message Row
struct ChatMessageRow: View {
    @ObservedObject var message: ChatMessage
    /// Only the actively streaming message needs vm access (for typing indicator & stop button).
    let isActiveMessage: Bool
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onRetry: (() -> Void)?
    var onEdit: (() -> Void)?
    var onWithdraw: (() -> Void)?
    /// 排队消息「立即发送」回调:中断当前回复并立即发送这条排队消息(2026-08-10 新增)。
    var onSendQueued: (() -> Void)?
    var autoRetryAttempt: Int = 0
    var autoRetryCountdown: Int = 0
    var canResume: Bool = false
    var onResume: (() -> Void)?
    var onCompact: (() -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// Read this whole reply aloud from the start (clears any in-progress TTS).
    /// Wired from ChatView (which owns the view model). Disabled while the
    /// message is still streaming to avoid fighting the live streaming TTS.
    var onReadAloud: (() -> Void)?
    /// When set, presents the compact summary sheet outside the cell tree.
    /// Falls back to a local .sheet when nil.
    var onShowCompactSummary: ((String) -> Void)?
    /// Triggers MessageListModel.revertCompact(). Wired from ChatView so the
    /// row + sheet stay free of view-model imports.
    var onRevertCompact: (() -> Void)?
    var browserPool: MiniClawTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @State private var usageShown = false
    @State private var compactShown = false
    /// Two-phase token usage reveal: space expands first, then content fades in.
    @State private var usageContentShown = false
    /// Row frame in window coordinates — used to gate token-usage tap to bottom zone.
    @State private var rowFrame: CGRect = .zero
    private let usageTapLog = AppLogger(category: "ChatList.Usage")
    /// ID of the block currently highlighted after a copy action.
    @State private var highlightedBlockId: UUID?
    /// The tool block whose detail sheet is currently presented.
    /// Lifted out of ToolCapsuleView so ForEach item changes don't reset it.
    @State private var detailBlock: AssistantBlock?

    /// All text block contents joined, for "Copy All".
    private var fullReplyStr: String {
        message.blocks
            .filter { if case .text = $0.kind { return true }; return false }
            .map(\.content)
            .joined(separator: "\n\n")
    }

    /// Full message including tool calls and their results, for clipboard export.
    private var fullMsgStr: String {
        var partItems: [String] = []
        for block in message.blocks {
            switch block.kind {
            case .text:
                if !block.content.isEmpty { partItems.append(block.content) }
            case .shellTool(let command):
                let cmdStr = command.isEmpty ? block.toolDescription : command
                var s = "$ \(cmdStr)"
                if !block.content.isEmpty {
                    // content is "$ cmdStr\noutput…", strip the command line
                    let output = block.content.hasPrefix("$ ") ?
                        String(block.content.drop(while: { $0 != "\n" }).dropFirst()) : block.content
                    if !output.isEmpty { s += "\n\(output)" }
                }
                partItems.append(s)
            case .fileReadTool(let path):
                partItems.append("Read: \(path)\n\(block.content)")
            case .fileWriteTool(let path):
                partItems.append("Write: \(path)\n\(block.content)")
            case .fileEditTool(let path):
                partItems.append("Edit: \(path)\n\(block.content)")
            case .browserTool(let action):
                partItems.append("Browser: \(action)\n\(block.content)")
            case .readImageTool(let path):
                partItems.append("Image: \(path)")
            case .memoryTool(let action):
                partItems.append("Memory: \(action)\n\(block.content)")
            case .thinking:
                if !block.content.isEmpty { partItems.append("[Thinking]\n\(block.content)") }
            case .info:
                if !block.content.isEmpty { partItems.append(block.content) }
            case .file(let url):
                partItems.append(url)
            }
        }
        return partItems.joined(separator: "\n\n")
    }

    var body: some View {
        switch message.role {
        case .user:
            userMsgRow
                .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        case .assistant:
            assistantMsgRow
                .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        case .compactDivider:
            compactDivider
        case .systemInfo:
            systemDivider(icon: message.isCompactLoading ? nil : (message.systemIcon ?? "info.circle"),
                             loading: message.isCompactLoading,compact: false)
        }
    }

    // MARK: Compact Divider Row

    private var compactDivider: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            HStack(spacing: 5) {
                if message.isCompactLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12,height: 12)
                } else {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10))
                }
                Text(message.content)
                    .font(.system(size: 12,weight: .medium))
                if !message.isCompactLoading && message.compactSummary != nil {
                    Button {
                        let summary = message.compactSummary ?? ""
                        if let onShowCompactSummary {
                            onShowCompactSummary(summary)
                        } else {
                            compactShown = true
                        }
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            VStack { Divider() }
        }
        .padding(.horizontal,24)
        .padding(.vertical,16)
        .sheet(isPresented: $compactShown) {
            CompactSummarySheet(summary: message.compactSummary ?? "", onRevert: onRevertCompact)
        }
    }

    // MARK: System Divider Row

    /// Shared divider-style row for system info messages.
    private func systemDivider(icon: String?,loading: Bool,compact: Bool) -> some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            HStack(spacing: 5) {
                if loading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12,height: 12)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(message.content)
                    .font(.system(size: 12,weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            // No .lineLimit(1).fixedSize() here:
            // fixedSize forced the text to its full ideal width, so a long
            // systemInfo line (e.g. pre-v3 "Downloaded … to /var/MiniClaw/… —
            // miniclaw://…" rows persisted in history) overflowed BOTH screen
            // edges from this centered row. layoutPriority keeps the flexible
            // dividers from squeezing the text; past the available width the
            // text wraps (UIKit breaks unspaced tokens like paths/URLs
            // mid-word) instead of clipping.
            .layoutPriority(1)
            VStack { Divider() }
        }
        .padding(.horizontal,24)
        .padding(.vertical,compact ? 16 : 6)
    }

    // MARK: User Row

    /// User message text with `<user-attached-files>` metadata stripped out.
    private var userDisplayStr: String {
        var text = message.content
        if let start = text.range(of: "<user-attached-files>") {
            let end = text.range(of: "</user-attached-files>")
            let endBound = end?.upperBound ?? text.endIndex
            text = String(text[text.startIndex..<start.lowerBound]+text[endBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private var userMsgRow: some View {
        HStack {
            Spacer(minLength: 60)

            VStack(alignment: .trailing,spacing: 6) {
                // User-attached files above the text bubble
                if !message.attachments.isEmpty {
                    UserAttachmentList(attachments: message.attachments)
                } else if !message.inputAttachments.isEmpty {
                    // Queued message: show previews from cache before queue drain
                    QueuedAttachmentPreview(attachments: message.inputAttachments)
                }

                if !userDisplayStr.isEmpty {
                    HStack(spacing: 6) {
                        if message.isQueued {
                            if let onSendQueued {
                                // 排队消息「立即发送」按钮:中断当前回复并立即发送这条。
                                Button {
                                    onSendQueued()
                                } label: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        Text(userDisplayStr)
                            .font(.system(size: FontSettings.shared.scaledMessage(16.5)))
                            .foregroundStyle(message.isQueued ? ChatColors.secondaryText : ChatColors.primaryText)
                            .padding(.horizontal,14)
                            .padding(.vertical,10)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(message.isQueued ? Color.clear : ChatColors.userBubble)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5,dash: [6,4]))
                                    .foregroundStyle(ChatColors.secondaryText.opacity(0.5))
                                    .opacity(message.isQueued ? 1 : 0)
                            )

                        if message.isQueued {
                            if let onWithdraw {
                                Button {
                                    onWithdraw()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            .modifier(MiniClawOpenURLHandler())
            .contentShape(Rectangle())
            // The hit-test shape above
            // stays a full Rectangle (so the whole row is long-pressable), but
            // the context-menu PREVIEW must clip to the bubble's rounded shape —
            // otherwise the lifted preview shows square corners while the bubble
            // is RoundedRectangle(cornerRadius: 18). iOS 16+ lets us specify the
            // preview clip shape independently from the interaction shape.
            .contentShape(.contextMenuPreview,RoundedRectangle(cornerRadius: 18))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                }
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.counterclockwise")
                    }
                }
                if let onCompact {
                    Divider()
                    Button(role: .destructive) {
                        onCompact()
                    } label: {
                        Label("Compact Above", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
            } preview: {
                // Opaque card so the
                // long-press preview isn't transparent (see MessageContextMenuPreview).
                MessageContextMenuPreview(text: message.content)
            }
        }
        .padding(.horizontal,16)
        .padding(.vertical,4)
    }

    // MARK: Assistant Row

    private var assistantMsgRow: some View {
        VStack(alignment: .leading,spacing: 8) {
            // Assistant label
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18,weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.72,green: 0.69,blue: 0.59),
                                     Color(red: 0.6,green: 0.6,blue: 0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                AssistantSoulName()
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ChatColors.primaryText)
            }
            .padding(.top,4)

            ForEach(message.blocks) { block in
                AssistantBlockView(
                    block: block,
                    message: message,
                    isActiveMessage: isActiveMessage,
                    commandStartTime: commandStartTime,
                    onStop: onStop,
                    onTapBlank: message.usage != nil ? { windowPoint in
                        // Only respond to taps in the bottom 100pt of the message row
                        let bottomZoneTopY = rowFrame.maxY-100
                        let inBottomZone = windowPoint.y >= bottomZoneTopY
                        usageTapLog.debug("[usageTap] windowPt=\(String(format: "%.0f,%.0f", windowPoint.x, windowPoint.y)) rowBottom=\(String(format: "%.0f", rowFrame.maxY)) zoneTop=\(String(format: "%.0f", bottomZoneTopY)) inBottomZone=\(inBottomZone) usageShown=\(usageShown)")
                        guard inBottomZone else { return }

                        if usageShown {
                            withAnimation(.easeInOut(duration: 0.15)) { usageContentShown = false }
                            DispatchQueue.main.asyncAfter(deadline: .now()+0.15) {
                                usageShown = false
                            }
                        } else {
                            usageShown = true
                            DispatchQueue.main.asyncAfter(deadline: .now()+0.05) {
                                withAnimation(.easeInOut(duration: 0.2)) { usageContentShown = true }
                            }
                        }
                    } : nil,
                    onCopyScreenshot: onCopyScreenshot,
                    browserPool: browserPool,
                    toolSnapshots: toolSnapshots,
                    highlightedBlockId: $highlightedBlockId,
                    detailBlock: $detailBlock
                )
            }

            // Typing indicator: show when waiting for first content, or when
            // all tools have completed and we're waiting for the model's next response
            if isActiveMessage && (!hasVisibleBody || message.isAwaitingModelResponse) {
                TypingIndicator()
            }

            // Inline error + retry
            if let error = message.error {
                inlineErrorBanner(error)
            }

            // Resume banner for interrupted sessions
            if canResume && message.error == nil {
                resumeBannerView
            }

            // Token usage — two-phase reveal: space expands first, then content fades in
            if message.streamInterruptCount>0 || usageShown {
                HStack(spacing: 6) {
                    if message.streamInterruptCount>0 {
                        streamInterruptMark(message.streamInterruptCount)
                    }
                    if usageShown,let usage = message.usage {
                        usageCapsuleView(usage)
                            .opacity(usageContentShown ? 1 : 0)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity,alignment: .leading)
        .padding(.horizontal,16)
        .padding(.vertical,6)
        // THE crasher from the v1.8b13 IPS:
        // onChange(of: geo.frame(in: .global)) wrote state inside the
        // geometry-observer path and tripped the async renderer
        // (ViewGraphGeometryObservers.needsUpdate SIGTRAP). onGeometryChange
        // measures the same row bounds the background GeometryReader did,
        // and its initial fire covers the old onAppear seed.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { rowFrame = $0 }
        .background {
            // Context menu on the background layer so it only fires on
            // blank areas — UITextView link taps in the foreground take priority.
            Color.clear
                .contentShape(Rectangle())
                .contextMenu {
                    // Gate the eager menu
                    // tree behind an Equatable key so the cell body churn during
                    // `gh`/shell streaming output doesn't rebuild + re-diff the
                    // whole menu subtree every frame — the deep ContextMenuModifier
                    // / UnwrapConditional recursion that blew the update stack into
                    // unmapped heap (incident 98E8805F). Copy actions read
                    // `fullReplyStr` lazily at TAP time, so the menu structure
                    // only needs rebuilding when the key changes: which optional
                    // actions exist + the streaming-disabled state.
                    EquatableMenuGate(key: AssistantMenuKey(
                        messageId: message.id,
                        hasReadAloud: onReadAloud != nil,
                        hasCopyScreenshot: onCopyScreenshot != nil,
                        compact: onCompact != nil,
                        active: isActiveMessage
                    )) {
                        Button {
                            UIPasteboard.general.string = fullReplyStr
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = fullReplyStr
                        } label: {
                            Label("Copy Markdown", systemImage: "text.quote")
                        }
                        if let onReadAloud {
                            Button {
                                onReadAloud()
                            } label: {
                                Label(String(localized: "Read from Start"), systemImage: "play.circle")
                            }
                            // Greyed out while streaming so it can't clash with the
                            // live streaming TTS of the same reply.
                            .disabled(isActiveMessage)
                        }
                        if let onCopyScreenshot {
                            Button {
                                onCopyScreenshot()
                            } label: {
                                Label(String(localized: "Copy Screenshot"), systemImage: "camera.viewfinder")
                            }
                        }
                        if let onCompact {
                            Divider()
                            Button(role: .destructive) {
                                onCompact()
                            } label: {
                                Label("Compact Above", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                        }
                    }
                    .equatable()
                } preview: {
                    // Opaque card for
                    // this Color.clear-attached contextMenu (see
                    // MessageContextMenuPreview).
                    MessageContextMenuPreview(text: fullReplyStr)
                }
        }
        // 2026-09-01 唐唐拍板：工具卡片浮层改由 ToolCardWindowPresenter 独立窗口承载
        //（bridge.detailBlock → 列表 sink → 窗口呈现），此处不再弹 sheet，避免双弹。
    }

    @ViewBuilder
    private func usageCapsuleView(_ usage: TokenUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.system(size: 9))
            Text(usageSummaryStr(usage))
                .font(.system(size: 10,design: .monospaced))
        }
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.horizontal,8)
        .padding(.vertical,3)
        .background(ChatColors.userBubble.opacity(0.6))
        .clipShape(Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    @ViewBuilder
    private func streamInterruptMark(_ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9,weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10,design: .monospaced))
        }
        .foregroundStyle(Color.orange.opacity(0.8))
        .padding(.horizontal,7)
        .padding(.vertical,3)
        .background(Color.orange.opacity(0.12))
        .clipShape(Capsule())
    }

    private func usageSummaryStr(_ u: TokenUsage) -> String {
        var partItems: [String] = []
        if u.latestContextTokens>0 {
            partItems.append("ctx:\(formatTokenCnt(u.latestContextTokens))")
        }
        partItems.append("in:\(formatTokenCnt(u.inputTokens))")
        partItems.append("out:\(formatTokenCnt(u.outputTokens))")
        if u.cacheReadTokens>0 {
            partItems.append("cache:\(formatTokenCnt(u.cacheReadTokens))")
        }
        if u.cacheCreationTokens>0 {
            partItems.append("+cache:\(formatTokenCnt(u.cacheCreationTokens))")
        }
        return partItems.joined(separator: " ")
    }

    private func formatTokenCnt(_ count: Int) -> String {
        if count >= 1000 {
            let k = Double(count)/1000.0
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(k))k"
                : String(format: "%.1fk", k)
        }
        return "\(count)"
    }

    @ViewBuilder
    private func inlineErrorBanner(_ error: String) -> some View {
        HStack(alignment: .center,spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = error
                } label: {
                    Label(String(localized: "Copy Error"), systemImage: "doc.on.doc")
                }
            }

            Spacer()

            if autoRetryAttempt>0 {
                Text("Retry in \(autoRetryCountdown)s (\(autoRetryAttempt)/\(MessageListModel.retryDelays.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal,12)
                    .padding(.vertical,6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            } else if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                        Text("Retry")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal,12)
                    .padding(.vertical,6)
                    .background(ChatColors.primaryText.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity,alignment: .leading)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var resumeBannerView: some View {
        HStack(alignment: .center,spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Interrupted — tap Resume to continue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let onResume {
                Button(action: onResume) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.semibold))
                        Text("Resume")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal,12)
                    .padding(.vertical,6)
                    .background(Color.orange)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity,alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var hasVisibleBody: Bool {
        message.blocks.contains { block in
            switch block.kind {
            case .text: return !block.content.isEmpty
            case .thinking: return true
            case .info: return true
            case .file: return true
            case .shellTool,.fileReadTool,.fileWriteTool,.fileEditTool,.browserTool,.readImageTool,.memoryTool: return true
            }
        }
    }

}



