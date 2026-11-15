import SwiftUI
import UIKit

struct ChatMessageRow: View {
    @ObservedObject var message: RenderMessage
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
    /// Wired from ChatView (which owns the view model). Disabled while the
    var onReadAloud: (() -> Void)?
    /// When set, presents the compact summary sheet outside the cell tree.
    /// Falls back to a local .sheet when nil.
    var onShowCompactSummary: ((String) -> Void)?
    /// Triggers MessageListModel.revertCompact(). Wired from ChatView so the
    var onRevertCompact: (() -> Void)?
    var browserPool: MiniClawTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @State private var usageShown = false
    @State private var compactShown = false
    @State private var usageContentShown = false
    @State private var rowFrame: CGRect = .zero
    private let usageTapLog = AppLogger(category: "ChatList.Usage")
    @State private var highlightedBlockId: UUID?
    @State private var detailBlock: AssistantBlock?

    private var fullReplyStr: String {
        message.blocks
            .filter { if case .text = $0.kind { return true }; return false }
            .map(\.content)
            .joined(separator: "\n\n")
    }

    private var fullMsgStr: String {
        var partItems: [String] = []
        for block in message.blocks {
            switch block.kind {
            case .text:
                if !block.content.isEmpty { partItems.append(block.content) }
            case .subagentTool(let action):
                if !action.isEmpty { partItems.append("Subagent: \(action)") }
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
            // [死代码清理 2026-11-15] 列表里 assistant 消息一律拆成
            // `.assistantHeader` + `.assistantBlock` + `.assistantFooter` 三类 item
            //（见 MessageCollectionCoordinator+Snapshot 的行生成），本视图只服务
            // `.wholeMessage`（user / compactDivider / systemInfo）。
            // 原 `.assistant` 分支（约 300 行）因此恒不执行，已删除。
            EmptyView()
        case .compactDivider:
            compactDivider
        case .systemInfo:
            // [Stage 1 · §6.3 A10] 原调用传 `compact: false` 字面量，而 `compact` 在
            // `systemDivider` 内只被用于一处三元 `compact ? 16 : 6` ⇒ 恒取 6 ⇒ 该参数是**残留参数**
            //（需要 16 的形态由独立的 `compactDivider` 承担，见 `:101`）。参数已删除。
            systemDivider(icon: message.isCompactLoading ? nil : (message.systemIcon ?? "info.circle"),
                             loading: message.isCompactLoading)
        }
    }

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

    private func systemDivider(icon: String?,loading: Bool) -> some View {
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
            // systemInfo line (e.g. pre-v3 "Downloaded … to /var/MiniClaw/… —
            // miniclaw://…" rows persisted in history) overflowed BOTH screen
            .layoutPriority(1)
            VStack { Divider() }
        }
        .padding(.horizontal,24)
        .padding(.vertical,6)  // [Stage 1 · A10] 原为 `compact ? 16 : 6`，而 compact 恒 false
    }

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
                if !message.attachments.isEmpty {
                    UserAttachmentList(attachments: message.attachments)
                } else if !message.inputAttachments.isEmpty {
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
                MessageContextMenuPreview(text: message.content)
            }
        }
        .padding(.horizontal,16)
        .padding(.vertical,4)
    }
}
