import SwiftUI

/// 「智能体 ↔ 子代理」对话详情页。
///
/// 从会话页输入框上方的悬浮头像点按弹出（底部 sheet + 下滑返回）。
/// **完全复用主会话页的渲染组件**（`MessageBubbleView` / `ToolCallCardView` / `ReasoningBlockView`），
/// 因此渲染形式、工具调用显示、工具指示器与主线**完全一致**：
///   - 主 智能体分配给子代理的**任务** → 以 `.user` 角色呈现（绿色气泡，与普通会话里用户消息一致）；
///   - 子代理的**回复** → 以 `.assistant` 角色呈现（无聊天背景、✨ 头像 + 名称 + 正文 + 工具指示器 + 思考块）；
///   - 流式输出实时刷新，底部状态行显示「回复中 / 已完成 / 已中断」。
/// 子代理只是主 智能体的下属，由主 智能体安排任务，因此本页**不含输入框**（子代理不接收用户直接输入）。
///
/// 构造时直接持有 `SubagentConversation` 实例（@Observable 类）。因为实例由父视图在点击时
/// 从 `SubagentStore` 取好后传入，本页直接观察该实例本身，流式 词元 仅驱动本页重绘，
/// 且不存在「首帧读取 store 未命中而停在空态」的时序空窗。
struct SubagentChatView: View {
    /// 直接持有的对话实例（@Observable 类），由父视图点击时从 `SubagentStore` 取好传入。
    let conversation: SubagentConversation
    /// 会话 ID，仅用于 `MessageBubbleView` 解析图片/文件等附属资源。
    let sessionID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var browserURL: URL? = nil
    @State private var fullscreenImageItem: FullscreenImageItem? = nil

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider()

                if !conversation.messages.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(conversation.messages) { msg in
                                    MessageBubbleView(
                                        message: chatMessage(from: msg),
                                        agentName: conversation.name,
                                        showThinking: SettingsStore.shared.settings.chat.showThinking,
                                        onOpenURL: { url in
                                            // 设置类深链 → 设置页路由；其余 → 浏览器（与主会话一致）。
                                            if url.scheme?.lowercased() == "miniclaw",
                                               AppState.shared?.routeSettingsDeepLink(url) == true {
                                                return
                                            }
                                            browserURL = url
                                        },
                                        onImageTap: { url in fullscreenImageItem = FullscreenImageItem(url: url) },
                                        sessionID: sessionID
                                    )
                                    .id(msg.id)
                                }
                                Color.clear.frame(height: 1).id("subBottom")
                            }
                            .padding(.vertical, 8)
                        }
                        // 仅在「新增消息」时整体滚到底（新任务/新回复出现），避免每条 词元 都滚动造成抖动；
                        // 流式正文增长由气泡自身可见，无需逐字强滚。
                        .onChange(of: conversation.messages.count) { _, _ in
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("subBottom", anchor: .bottom)
                            }
                        }
                    }
                } else {
                    Spacer()
                    ProgressView(L10n.tr("子代理准备中…"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 { browserURL = nil } }
        )) {
            if let url = browserURL { BrowserView(startURL: url) }
        }
        .fullScreenCover(item: $fullscreenImageItem) { item in
            FullscreenImageView(
                imageURL: item.url,
                isPresented: Binding(
                    get: { fullscreenImageItem != nil },
                    set: { if !$0 { fullscreenImageItem = nil } }
                )
            )
        }
    }

    // MARK: - 把 SubagentMsg 转换为主会话页同款 ChatMessage

    /// 任务（主 智能体指派）→ `.user`（绿色气泡）；回复 → `.assistant`（无背景、含工具调用与思考段）。
    private func chatMessage(from m: SubagentMsg) -> ChatMessage {
        let role: MessageRole = (m.role == .task) ? .user : .assistant
        let msg = ChatMessage(role: role, content: m.text)
        msg.isStreaming = m.isStreaming
        msg.wasInterrupted = m.wasInterrupted
        if m.role != .task {
            msg.toolCalls = m.toolCalls
            msg.reasoningSegments = m.reasoningSegments
        }
        return msg
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill((conversation.status == .error) ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: statusIcon(conversation.status))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor(conversation.status))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                // 状态 + 模型信息同一行，但各自独立样式：
                // 状态保持原样式（状态色 caption，字体/颜色不变）；
                // 模型信息（分组·模型名 · 思考强度）跟在后面（caption2 secondary）。
                HStack(spacing: 4) {
                    Text(statusText(conversation.status))
                        .font(.caption)
                        .foregroundStyle(statusColor(conversation.status))
                    if !conversation.modelDisplay.isEmpty {
                        Text("\(conversation.modelDisplay) · \(conversation.thinkingDisplay)")
                            // 与状态同字号（caption）；颜色保持 secondary 以区分主次。
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(L10n.tr("完成")) { dismiss() }
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 状态显示（P3：完整终态机）

    private func statusText(_ s: SubagentStatus) -> String {
        switch s {
        case .running:    return L10n.tr("处理中")
        case .error:      return L10n.tr("出错")
        case .completed:  return L10n.tr("已完成")
        case .cancelled:  return L10n.tr("已取消")
        }
    }

    private func statusIcon(_ s: SubagentStatus) -> String {
        switch s {
        case .running:    return "cpu"
        case .error:      return "exclamationmark.triangle"
        case .completed:  return "checkmark.circle.fill"
        case .cancelled:  return "xmark.circle.fill"
        }
    }

    private func statusColor(_ s: SubagentStatus) -> Color {
        switch s {
        case .running:    return .accentColor
        case .error:      return .red
        case .completed:  return .green
        case .cancelled:  return .secondary
        }
    }
}
