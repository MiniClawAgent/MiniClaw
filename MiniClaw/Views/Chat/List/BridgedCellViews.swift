import SwiftUI
import UIKit
import Combine
import Foundation

/// 块内容的左右内边距（单侧）。
/// [2026-09-12 裁尾修复] 测量与渲染必须使用**同一个内容宽度**：
/// 内容能拿到的宽度 = cell 宽度 − 2×blockHPadding。此前 `.frame(maxWidth:)` 直接用了 cell 宽度，
/// 于是测量按更宽的宽度排版（行数偏少）、高度比真实需要矮约一行 → 尾部半行被裁。
/// 真机实证：cell 宽 402、渲染内容宽 370（402−32 = 370 ✓），而测量按 402 得出 1703，
/// 真实需要 1711.3（370 下），差 8.3pt ≈ 一行。
private let blockHPadding: CGFloat = 16


struct BridgedAssistantBlock: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: RenderMessage
    @ObservedObject var bridge: CellStateBridge
    var maxWidth: CGFloat
    /// [2026-09-12 裁尾修复] 宿主的**真实 cell 宽度**（= collectionView.bounds.width）。
    ///
    /// 为什么不复用 `maxWidth`：`maxWidth` 来自 `coord.maxContentWidth`，而 ChatView 传的是
    /// **0**（语义 = 不设内容宽上限），所以 `maxWidth>0 ? … : nil` 一路落 nil，既让
    /// `.frame(maxWidth:)` 成为 no-op，也让传给 MarkdownView 的 contentWidth 为 nil。
    /// 没有真实内容宽，`MarkdownView.sizeThatFits` 在「理想尺寸 pass」（proposal.width == nil、
    /// bounds == 0）只能退回**屏幕宽 402**，按 402 排版行数偏少 → 高度偏矮 12.3pt，被
    /// `.fixedSize(vertical: true)` 钉死 → 尾部半行永久被裁（真机 `[STF] rawProposal=nil
    /// contentW=nil w=402.0` 实证）。由 cell 显式传入 402 后，真实内容宽 = 402 − 2×16 = 370。
    var cellWidth: CGFloat = 0

    /// 本块的真实内容宽度（cell 宽 − 两侧块内边距）。单一事实源：与下方
    /// `.padding(.horizontal, blockHPadding)` 用的是同一个 `blockHPadding`。
    private var resolvedContentWidth: CGFloat? {
        let base = cellWidth > 1 ? cellWidth : (maxWidth > 1 ? maxWidth : 0)
        guard base > 1 else { return nil }
        return max(0, base - 2*blockHPadding)
    }

    var blockAccessibilityId: String {
        switch block.kind {
        case .text: return "assistantTextBlock"
        case .thinking: return "assistantThinkingBlock"
        case .shellTool: return "assistantShellBlock"
        case .subagentTool: return "assistantSubagentBlock"
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
            // Selection-menu TTS: whole-reply
            onReadAloud: bridge.isStreaming ? nil : bridge.onReadAloud,
            onSpeakText: bridge.onSpeakText,
            browserPool: bridge.browserPool,
            toolSnapshots: bridge.toolSnapshots,
            snapshotBridge: bridge,
            // [2026-09-12 裁尾修复] 真实内容宽度 = cell 宽 − 2×块内边距，与下面 frame 用的是
            // 同一个量（单一事实源），保证「测量宽度」与「渲染宽度」按构造一致。
            contentWidth: resolvedContentWidth,
            highlightedBlockId: .constant(nil),
            detailBlock: $bridge.detailBlock
        )
        .frame(maxWidth: maxWidth>0 ? max(0, maxWidth-2*blockHPadding) : nil,alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal,blockHPadding)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier(blockAccessibilityId)
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
                    // This .contextMenu
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
                NotificationCenter.default.post(name: .messageListNeedsResnapshot,object: nil)
            }
        } else {
            bridge.showUsage = true
            NotificationCenter.default.post(name: .messageListNeedsResnapshot,object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.05) {
                withAnimation(.easeInOut(duration: 0.2)) { bridge.usageContentVisible = true }
            }
        }
    }
}

/// No GeometryReader. Sheet moved to zero-size overlay to prevent
struct BridgedAssistantFooter: View {
    @ObservedObject var message: RenderMessage
    @ObservedObject var bridge: CellStateBridge
    var maxWidth: CGFloat

    /// 回复中指示器（唐唐 2026-09-06 调整）：绿色圆内黄色呼吸点 +「回复中」。
    /// 外圈 12pt 与其余状态行的 caption SF Symbol（已完成/已停止圆图标）视觉等大；
    /// 呼吸点用透明度呼吸（0.2 ↔ 1）。
    @State private var replyBreathing = false
    private var replyingIndicator: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 5, height: 5)
                    .opacity(replyBreathing ? 1 : 0.2)
            }
            Text(String(localized: "replying"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                replyBreathing = true
            }
        }
    }

    /// 终态状态行（已完成/已停止/已中断 + 耗时后缀）。
    /// 水平 12pt：与消息正文块（工具/文本块同衬距）对齐（唐唐 2026-09-05）。
    private func statusRow(icon: String, color: Color, key: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let et = message.taskElapsedSeconds, et >= 1 {
                Text(" · \(Self.elapsedText(et))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private static func elapsedText(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return "\(h)h\(m)m\(sec)s" }
        if m > 0 { return "\(m)m\(sec)s" }
        return "\(sec)s"
    }

    // 单一事实源在 RenderMessage.footerHasVisibleContent（种子循环同用，
    // 防止渲染与估高两处判定漂移）。
    var hasVisibleContent: Bool {
        message.footerHasVisibleContent
    }

    /// doesn't insert a phantom 4pt gapH between the last assistant block
    var hasFooterContent: Bool {
        let showTyping = bridge.isActiveMessage && (!hasVisibleContent || message.isAwaitingModelResponse)
        let showError = message.error != nil
        let showResume = bridge.canResume && message.error == nil
        let showUsageRow = message.streamInterruptCount>0 || bridge.showUsage
        return showTyping || showError || showResume || showUsageRow
    }

    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            // 消息状态行（2026-09-05，对齐子代理会话页 AssistantStatusRow）：
            // 流式/等待首字 = 三点思考指示器；终态按 已停止/已中断/已完成 显示（含耗时）。
            // 错误（inlineError）与「已暂停」恢复横幅保留原有专属展示，不在此重复。
            if bridge.isActiveMessage && (!hasVisibleContent || message.isAwaitingModelResponse) {
                replyingIndicator
            } else if message.error == nil && !bridge.canResume {
                if message.wasStopped {
                    statusRow(icon: "stop.circle.fill", color: .orange, key: "stopped")
                } else if message.wasInterrupted {
                    statusRow(icon: "exclamationmark.triangle.fill", color: .red, key: "interrupted")
                } else if hasVisibleContent {
                    statusRow(icon: "checkmark.circle.fill", color: .green, key: "completed")
                }
            }

            if let error = message.error {
                inlineError(error)
            }

            if bridge.canResume && message.error == nil {
                resumeBanner
            }

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
        .frame(maxWidth: maxWidth>0 ? max(0, maxWidth-2*blockHPadding) : nil,alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal,blockHPadding)
        .padding(.vertical,hasFooterContent ? 2 : 0)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantFooter")
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
                    // Opaque preview
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

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
                Text(String(localized: "pause_resume_hint")).font(.system(size: 13)).foregroundStyle(.secondary)
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

/// No GeometryReader.
struct BridgedWholeMessage: View {
    @ObservedObject var message: RenderMessage
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
