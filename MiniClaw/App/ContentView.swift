import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    /// 订阅界面语言单例：语言切换时 `current` 变化触发本视图重渲染，
    /// 让 NavigationStack 及其内 HomeView（含设置 sheet）的 `L10n.tr` 文案以新语言重新求值。
    /// App 文案走纯 String、不读 `.locale` 环境，故必须在 View 层显式订阅 L10n.shared；
    /// 各用 L10n.tr 的关键子视图（HomeView / SettingsView / AppearanceSettingsView 等）同样订阅。
    @ObservedObject private var l10n = L10n.shared
    @State private var isChatActive: Bool = false
    @State private var chatSession: ChatSession?
    /// 订阅工具确认桥：确认框为全局弹窗，挂在本根视图，
    /// 无论用户当前在首页还是任意会话，只要有工具待确认都会弹出。
    @ObservedObject private var confirmBridge = ToolConfirmationBridge.shared
    /// 当前弹出的确认项（用 isPresented 形式承载，按 pendingItems 同步）。
    @State private var currentConfirmItem: ToolConfirmationBridge.Item?

    var body: some View {
        NavigationStack(path: Bindable(appState).navigationPath) {
            HomeView()
                .navigationDestination(isPresented: $isChatActive) {
                    if let session = chatSession {
                        ChatView(session: session)
                    }
                }
        }
        .onChange(of: appState.selectedSession) { _, newValue in
            if let session = newValue {
                chatSession = session
                isChatActive = true
            }
        }
        // 真正退出会话（导航 pop 回首页）时才清理选中状态。
        // 不能用 ChatView.onDisappear：fullScreenCover（会话内命令行/浏览器）
        // 也会把 ChatView 暂时移出层级并触发 onDisappear，导致误清理。
        .onChange(of: isChatActive) { _, active in
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
        // ── 语言切换 ──
        // appState.appLanguage 的 didSet 已同步 L10n.shared.current；
        // 此处 onChange 作为双保险（防 @Observable 宏下 didSet 行为异常时漏同步）。
        // 注意：不再使用 .id(appState.appLanguage.rawValue) 强制重建整棵视图树——
        // 之前的实现会导致 HomeView 的设置 sheet 被销毁后用全新 NavigationStack 重开，
        // 用户从「外观」子页被打回「设置」根页、NavigationStack 路径丢失，看起来像「切换没生效」。
        // 现改为：依赖 L10n.shared (ObservableObject) 的 @Published current 变化，
        // 让观察了 L10n.shared 的视图（ContentView / HomeView / SettingsView / AppearanceSettingsView 等）
        // 自动重新求值，L10n.tr(...) 读到新语言；sheet 状态不受影响，用户留在原页面看到文案即时切换。
        .onChange(of: appState.appLanguage) { _, newLang in
            L10n.shared.setLanguage(newLang)
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
                        Text(L10n.tr("工具调用确认"))
                            .font(.headline)
                        Text(L10n.tr("即将调用工具「") + item.toolName + "」\n" + L10n.tr("操作：") + item.summary)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Divider()
                        Button {
                            confirmBridge.resolve(itemID: item.id, approved: true)
                        } label: {
                            Text(L10n.tr("允许一次")).frame(maxWidth: .infinity)
                        }
                        Button {
                            confirmBridge.approveSession(sessionID: item.sessionID)
                            confirmBridge.resolve(itemID: item.id, approved: true)
                        } label: {
                            Text(L10n.tr("允许本次会话")).frame(maxWidth: .infinity)
                        }
                        Button(role: .destructive) {
                            confirmBridge.resolve(itemID: item.id, approved: false)
                        } label: {
                            Text(L10n.tr("拒绝")).frame(maxWidth: .infinity)
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
