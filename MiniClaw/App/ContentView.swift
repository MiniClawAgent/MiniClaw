import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isChatActive: Bool = false
    @State private var chatSession: ChatSession?
    /// 订阅工具确认桥：确认框为全局弹窗，挂在本根视图，
    /// 无论用户当前在首页还是任意会话，只要有工具待确认都会弹出。
    @ObservedObject private var confirmBridge = ToolConfirmationBridge.shared
    /// 当前弹出的确认项（用 isPresented 形式承载，按 pendingItems 同步）。
    @State private var currentConfirmItem: ToolConfirmationBridge.Item?

    var body: some View {
        NavigationStack(path: $appState.navigationPath) {
            HomeView()
                .navigationDestination(isPresented: $isChatActive) {
                    if let session = chatSession {
                        ChatView(session: session)
                    }
                }
        }
        .onChange(of: appState.selectedSession) { newValue in
            if let session = newValue {
                chatSession = session
                isChatActive = true
            }
        }
        // 真正退出会话（导航 pop 回首页）时才清理选中状态。
        // 不能用 ChatView.onDisappear：fullScreenCover（会话内命令行/浏览器）
        // 也会把 ChatView 暂时移出层级并触发 onDisappear，导致误清理。
        .onChange(of: isChatActive) { active in
            if !active {
                chatSession = nil
                appState.selectedSession = nil
            }
        }
        // 待确认项变化时同步到「当前弹出项」：当前项仍待确认则保持，否则取最早一项（依次弹出）。
                .onReceive(confirmBridge.$pendingItems) { items in
            if let cur = self.currentConfirmItem, items.contains(where: { $0.id == cur.id }) {
                // 当前显示项仍然存在，保持
            } else {
                self.currentConfirmItem = items.first
            }
        }
        // ── 工具调用前确认（全局自定义浮层，非系统 Alert）──
        // 任意页面/会话都可看到并处理的工具确认框；框内标注会话名称避免跨会话误认；
        // 点击按 item.id 精确恢复，不会作用于其他会话。多项待确认时依次弹出。
        // 用自定义浮层替代系统 Alert：彻底移除系统自动附加的「取消」按钮，仅保留三个业务按钮；
        // 点击遮罩不关闭弹窗，避免引擎 continuation 悬挂泄漏。
        .overlay {
            if let item = currentConfirmItem {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { /* 点击遮罩不关闭，避免引擎 continuation 悬挂 */ }
                    VStack(spacing: 14) {
                        Text(String(localized: "tool_call_confirmation"))
                            .font(.headline)
                        Group {
                            let actionLine = String(localized: "about_to_call_tool") + item.toolName + "」\n" + String(localized: "operation_label") + item.summary
                            Text(actionLine)
                        }
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Divider()
                        Button {
                            confirmBridge.resolve(itemID: item.id, approved: true)
                        } label: {
                            Text(String(localized: "allow_once")).frame(maxWidth: .infinity)
                        }
                        Button {
                            confirmBridge.approveSession(sessionID: item.sessionID)
                            confirmBridge.resolve(itemID: item.id, approved: true)
                        } label: {
                            Text(String(localized: "allow_this_session")).frame(maxWidth: .infinity)
                        }
                        Button(role: .destructive) {
                            confirmBridge.resolve(itemID: item.id, approved: false)
                        } label: {
                            Text(String(localized: "deny")).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 36)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: currentConfirmItem?.id)
            }
        }
    }
}
