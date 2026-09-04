import SwiftUI
import UIKit
import Combine
import Foundation

struct BridgedAssistantBlock: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridge
    var maxWidth: CGFloat

    var blockAccessibilityId: String {
        switch block.kind {
        case .text: return "assistantTextBlock"
        case .thinking: return "assistantThinkingBlock"
        case .shellTool: return "assistantShellBlock"
        case .fileReadTool: return "assistantFileReadBlock"
        case .fileWriteTool: return "assistantFileWriteBlock"
        case .fileEditTool: return "assistantFileEditBlock"
        case .browserTool: return "assistantBrowserBlock"
        case .readImageTool: return "assistantReadImageBlock"
        case .memoryTool: return "assistantMemoryBlock"
        case .info: return "assistantInfoBlock"
        case .file: return "assistantFileBlock"
        }
    }

    var body: some View {
        AssistantBlockView(
            block: block,
            message: message,
            isActiveMessage: bridge.isActiveMessage,
            commandStartTime: bridge.isActiveMessage ? bridge.commandStartTime : nil,
            onStop: bridge.isActiveMessage ? bridge.onStop : nil,
            onTapBlank: { _ in
                toggleUsage()
            },
            onCopyScreenshot: { bridge.onCopyScreenshot?() },
            // [T-selection-menu-tts] Selection-menu TTS: whole-reply
            // replay is suppressed while this reply is still streaming (same
            // rule as the overlay context menu); Read Selection stays available.
            onReadAloud: bridge.isStreaming ? nil : bridge.onReadAloud,
            onSpeakText: bridge.onSpeakText,
            browserPool: bridge.browserPool,
            toolSnapshots: bridge.toolSnapshots,
            snapshotBridge: bridge,
            highlightedBlockId: .constant(nil),
            detailBlock: $bridge.detailBlock
        )
        .frame(maxWidth: maxWidth>0 ? maxWidth : nil,alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal,16)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier(blockAccessibilityId)
        // Context menu on zero-size overlay so it doesn't inflate self-sizing
        // (same pattern as BridgedAssistantFooter).
        .overlay {
            Color.clear.frame(width: 0,height: 0)
                .contextMenu {
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(String(localized: "Copy All"), systemImage: "doc.on.doc")
                    }
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(String(localized: "Copy Markdown"), systemImage: "text.quote")
                    }
                    if let onReadAloud = bridge.onReadAloud {
                        Button {
                            onReadAloud()
                        } label: {
                            Label(String(localized: "Read from Start"), systemImage: "play.circle")
                        }
                        // Greyed out while streaming so it can't clash with the
                        // live streaming TTS of the same reply.
                        .disabled(bridge.isStreaming)
                    }
                    if let onCopyScreenshot = bridge.onCopyScreenshot {
                        Button {
                            onCopyScreenshot()
                        } label: {
                            Label(String(localized: "Copy Screenshot"), systemImage: "camera.viewfinder")
                        }
                    }
                    if let onForceSync = bridge.onForceSync {
                        Divider()
                        Button {
                            onForceSync()
                        } label: {
                            Label(String(localized: "Force Sync"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    if let onCompact = bridge.onCompact {
                        Divider()
                        Button(role: .destructive) {
                            onCompact()
                        } label: {
                            Label(String(localized: "Compact Above"), systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                } preview: {
                    // [T-ios-longpress-menu-preview-background] This .contextMenu
                    // is on a zero-size Color.clear overlay (kept zero-size to
                    // avoid inflating self-sizing), so without an explicit preview
                    // SwiftUI snapshots that transparent overlay → see-through
                    // preview. Supply an opaque card of the message text.
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

    func toggleUsage() {
        guard message.usage != nil else { return }
        if bridge.showUsage {
            withAnimation(.easeInOut(duration: 0.15)) { bridge.usageContentVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now()+0.15) {
                bridge.showUsage = false
                // The footer cell may have been omitted from the snapshot
                // (no content at build time). Notify the coordinator so it
                // re-snapshots and removes the now-empty footer.
                NotificationCenter.default.post(name: .messageListNeedsResnapshot,object: nil)
            }
        } else {
            bridge.showUsage = true
            // The footer cell may not exist yet — notify the coordinator to
            // re-snapshot and insert it.
            NotificationCenter.default.post(name: .messageListNeedsResnapshot,object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.05) {
                withAnimation(.easeInOut(duration: 0.2)) { bridge.usageContentVisible = true }
            }
        }
    }
}

/// Footer: typing indicator, error, resume banner, token usage.
/// No GeometryReader. Sheet moved to zero-size overlay to prevent
/// inflated self-sizing from sheet-capable view modifiers.
struct BridgedAssistantFooter: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridge
    var maxWidth: CGFloat

    // showUsage and usageContentVisible are on bridge, toggled by double-tap on block cells.

    var hasVisibleContent: Bool {
        message.blocks.contains { block in
            switch block.kind {
            case .text: return !block.content.isEmpty
            case .info: return true
            default: return true
            }
        }
    }

    /// True when any of the footer's conditional sections will actually
    /// render. When false the footer should collapse to zero height so it
    /// doesn't insert a phantom 4pt gapH between the last assistant block
    /// and the next user message.
    var hasFooterContent: Bool {
        let showTyping = bridge.isActiveMessage && (!hasVisibleContent || message.isAwaitingModelResponse)
        let showError = message.error != nil
        let showResume = bridge.canResume && message.error == nil
        let showUsageRow = message.streamInterruptCount>0 || bridge.showUsage
        return showTyping || showError || showResume || showUsageRow
    }

    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            // Typing indicator
            if bridge.isActiveMessage && (!hasVisibleContent || message.isAwaitingModelResponse) {
                TypingIndicator()
            }

            // Inline error
            if let error = message.error {
                inlineError(error)
            }

            // Resume banner
            if bridge.canResume && message.error == nil {
                resumeBanner
            }

            // Token usage
            if message.streamInterruptCount>0 || bridge.showUsage {
                HStack(spacing: 6) {
                    if message.streamInterruptCount>0 {
                        streamInterruptBadge(message.streamInterruptCount)
                    }
                    if bridge.showUsage,let usage = message.usage {
                        usageCapsule(usage)
                            .opacity(bridge.usageContentVisible ? 1 : 0)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity,alignment: .leading)
        .frame(maxWidth: maxWidth>0 ? maxWidth : nil,alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal,hasFooterContent ? 16 : 0)
        .padding(.vertical,hasFooterContent ? 2 : 0)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantFooter")
        // Sheet + contextMenu on zero-size overlay so they don't inflate self-sizing.
        // Both .sheet and .contextMenu wrap the view in interaction containers that
        // report inflated heights to systemLayoutSizeFitting, causing height oscillation.
        .overlay {
            Color.clear.frame(width: 0,height: 0)
                .contextMenu {
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(String(localized: "Copy All"), systemImage: "doc.on.doc")
                    }
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(String(localized: "Copy Markdown"), systemImage: "text.quote")
                    }
                    if let onReadAloud = bridge.onReadAloud {
                        Button {
                            onReadAloud()
                        } label: {
                            Label(String(localized: "Read from Start"), systemImage: "play.circle")
                        }
                        // Greyed out while streaming so it can't clash with the
                        // live streaming TTS of the same reply.
                        .disabled(bridge.isStreaming)
                    }
                    if let onCopyScreenshot = bridge.onCopyScreenshot {
                        Button {
                            onCopyScreenshot()
                        } label: {
                            Label(String(localized: "Copy Screenshot"), systemImage: "camera.viewfinder")
                        }
                    }
                    if let onForceSync = bridge.onForceSync {
                        Divider()
                        Button {
                            onForceSync()
                        } label: {
                            Label(String(localized: "Force Sync"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    if let onCompact = bridge.onCompact {
                        Divider()
                        Button(role: .destructive) {
                            onCompact()
                        } label: {
                            Label(String(localized: "Compact Above"), systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                } preview: {
                    // [T-ios-longpress-menu-preview-background] Opaque preview
                    // for the footer's zero-size Color.clear contextMenu overlay.
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

    // MARK: - Footer sub-views

    @ViewBuilder
    func inlineError(_ error: String) -> some View {
        HStack(alignment: .center,spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
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
            if bridge.autoRetryAttempt>0 {
                Text("Retry in \(bridge.autoRetryCountdown)s (\(bridge.autoRetryAttempt)/\(MessageListModel.retryDelays.count))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal,12).padding(.vertical,6)
                    .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
            } else if let onRetry = bridge.onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                        Text(String(localized: "Retry")).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal,12).padding(.vertical,6)
                    .background(ChatColors.primaryText.opacity(0.15)).clipShape(Capsule())
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity,alignment: .leading)
        .background(Color.red.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    var resumeBanner: some View {
        HStack(alignment: .center,spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill").font(.system(size: 13)).foregroundStyle(.orange)
                Text(String(localized: "已暂停 — 点继续恢复")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if let onResume = bridge.onResume {
                Button(action: onResume) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 11,weight: .semibold))
                        Text(String(localized: "继续")).font(.system(size: 12,weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal,10).padding(.vertical,4)
                    .background(Color.orange).clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal,12).frame(maxWidth: .infinity,alignment: .leading)
        .frame(height: 36)
        .background(Color(UIColor.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.35),lineWidth: 0.5)
        )
    }

    @ViewBuilder
    func usageCapsule(_ usage: TokenUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer").font(.system(size: 9))
            Text(usageSummary(usage)).font(.system(size: 10,design: .monospaced))
        }
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.horizontal,8).padding(.vertical,3)
        .background(ChatColors.userBubble.opacity(0.6)).clipShape(Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    @ViewBuilder
    func streamInterruptBadge(_ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
            Text("\(count)").font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(Color.orange.opacity(0.8))
        .padding(.horizontal,7).padding(.vertical,3)
        .background(Color.orange.opacity(0.12)).clipShape(Capsule())
    }

    func usageSummary(_ u: TokenUsage) -> String {
        var parts: [String] = []
        if u.latestContextTokens>0 { parts.append("ctx:\(fmtTok(u.latestContextTokens))") }
        parts.append("in:\(fmtTok(u.inputTokens))")
        parts.append("out:\(fmtTok(u.outputTokens))")
        if u.cacheReadTokens>0 { parts.append("cache:\(fmtTok(u.cacheReadTokens))") }
        if u.cacheCreationTokens>0 { parts.append("+cache:\(fmtTok(u.cacheCreationTokens))") }
        return parts.joined(separator: " ")
    }
    func fmtTok(_ c: Int) -> String {
        c >= 1000 ? (c >= 10000 ? "\(c/1000)k" : String(format: "%.1fk", Double(c)/1000)) : "\(c)"
    }
}

/// Wraps the existing ChatMessageRow for user / compactDivider / systemInfo messages.
/// No GeometryReader.
struct BridgedWholeMessage: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridge
    var maxWidth: CGFloat

    var body: some View {
        ChatMessageRow(
            message: message,
            isActiveMessage: false,
            commandStartTime: nil,
            onStop: nil,
            onRetry: bridge.onRetry,
            onEdit: bridge.onEdit,
            onWithdraw: bridge.onWithdraw,
            onSendQueued: bridge.onSendQueued,
            autoRetryAttempt: 0,
            autoRetryCountdown: 0,
            canResume: false,
            onResume: nil,
            onCompact: bridge.onCompact,
            onCopyScreenshot: bridge.onCopyScreenshot,
            onShowCompactSummary: bridge.onShowCompactSummary,
            browserPool: nil,
            toolSnapshots: []
        )
        .frame(maxWidth: maxWidth>0 ? maxWidth : nil)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(message.role == .user ? "userMessage" : "wholeMessage")
    }
}

// MARK: - Per-type Cell Subclasses (enable correct reuse)

