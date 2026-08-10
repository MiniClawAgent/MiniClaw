import Foundation
import MiniClawKit
import WebKit
import UIKit
import SwiftUI
import Combine

/// 浏览器控制器：管理多个 WKWebView 标签（上限由「通用设置 → 浏览器 → 最大标签数」控制，默认 3），并提供 智能体与 UI 共用的网页操作。
/// 所有网页访问都在主线程（MainActor）进行，符合 WKWebView 的线程要求。
/// 
/// 会话隔离：每个 ChatSession 拥有独立的 BrowserContext（WKWebsiteDataStore.nonPersistent），
/// 同一会话的标签页共享 Cookie/Storage，不同会话完全隔离。
/// JPEG 编码只读传递盒：UIImage 非 Sendable，但编码只读不改图，
/// 经 @unchecked Sendable 盒传入后台线程编码（线程治理 2026-08-09）。
private struct JPEGEncodeBox: @unchecked Sendable {
    let image: UIImage
}

@MainActor
final class BrowserController: NSObject, ObservableObject {
    static let shared = BrowserController()

    /// 最多标签数（由「通用设置 → 浏览器 → 最大标签数」控制，范围 1…5，缺省 3）。
    static var maxTabs: Int {
        let v = SettingsStore.shared.settings.browser.maxTabs
        return min(5, max(1, v))
    }

    private let contextManager = BrowserContextManager.shared

    /// 浏览器操作的串行门：引擎侧会把多个 browser 工具调用并发执行（如一次回复里同时开两个标签页），
    /// 但本控制器是 @MainActor 单例，scopedSessionID / activeIndex / tabs 等是共享可变状态，
    /// 并行写会互相覆盖导致导航回调解析到错误上下文、续体迟迟不被 resume —— 表现为“一直转圈”。
    /// 用此门把每个带 sessionID 的 run() 调用串行化，确保任一时刻只有一个浏览器操作在真正执行。
    private let serialGate = BrowserSerialGate()

    // MARK: - 智能体托管指示（会话页浏览器遮罩）

    /// 智能体正在操作浏览器（引擎经 run() 调用期间为 true；操作结束后延迟隐藏，
    /// 覆盖 智能体连续多步操作之间的模型思考间隔，避免指示器闪烁）。
    @Published var isAgentOperating = false
    /// 用户点击「取消托管」后的接管标记（2026-08-07 语义收紧）：
    /// **智能体操作浏览器优先于用户打开浏览器**——用户打开/手动导航/开标签都不算接管；
    /// 唯一拒绝 智能体的途径 = 智能体操作期间用户点击「取消托管」按钮（或遮罩显示时）。
    /// 标记置位后 智能体浏览器调用立即返回「用户已接管」错误，直到浏览器视图重新打开时重置。
    private(set) var agentControlRevoked = false
    private var agentOperationFadeTask: Task<Void, Never>?

    /// 标记 智能体正在操作（每次工具调用进入时调用）：立即显示指示器，取消延迟隐藏。
    private func markAgentOperating() {
        agentOperationFadeTask?.cancel()
        isAgentOperating = true
    }

    /// 操作结束：延迟 3 秒隐藏指示器（智能体连续操作/思考间隔 <3s 时保持显示，不闪烁）。
    private func scheduleAgentOperationEnd() {
        agentOperationFadeTask?.cancel()
        agentOperationFadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.isAgentOperating = false
        }
    }

    /// 统一清理「浏览器缓存」（2026-08-07 口径统一）：WebKit 磁盘/内存/离线缓存 +
    /// URLCache + 共享区 browser/ + 系统 Caches/MiniClaw/。
    /// 浏览器设置页与设置→存储→清理浏览器缓存共用此方法；会话级 browser/ 属「会话缓存」，不在此列。
    func clearBrowserCaches() async {
        let dataStore = activeContext.dataStore
        await dataStore.removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache],
            modifiedSince: .distantPast
        )
        URLCache.shared.removeAllCachedResponses()
        // 共享区浏览器落盘（历史/Cookie 快照等）
        let sharedBrowser = FileSystemManager.shared.miniClawRoot.appendingPathComponent("browser")
        if let items = try? FileManager.default.contentsOfDirectory(at: sharedBrowser, includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        // 系统 Caches/MiniClaw/（下载临时等）
        if let cachesURL = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("MiniClaw") {
            if let items = try? FileManager.default.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: nil) {
                for item in items { try? FileManager.default.removeItem(at: item) }
            }
        }
    }

    /// 用户点击「取消托管」：立即隐藏指示器并拒绝 智能体后续浏览器操作（用户接管）。
    func cancelAgentOperation() {
        agentOperationFadeTask?.cancel()
        isAgentOperating = false
        agentControlRevoked = true
    }

    /// 浏览器视图重新打开时调用：重置接管标记，智能体可在新一轮会话期内恢复托管。
    func resetAgentTakeover() {
        agentControlRevoked = false
    }



    /// 当前关联的会话 ID；设置为 nil 时使用默认上下文
    var currentSessionID: UUID? = nil
    private let defaultSessionID = UUID() // fallback（无会话时的兜底上下文）
    /// 首页/手动浏览器使用的独立上下文（与任何 智能体会话隔离，智能体永不写入此处）
    private let manualSessionID = UUID()
    /// 智能体工具调用期间临时绑定的会话（优先于 currentSessionID），
    /// 确保会话隔离不被前台页面切换破坏。
    private var scopedSessionID: UUID?

    /// 当前激活的浏览器上下文（供 BrowserSettingsView 等读取 Cookie）
    var activeContext: BrowserContext {
        contextManager.context(for: scopedSessionID ?? currentSessionID ?? defaultSessionID)
    }

    /// 文件写入用的有效会话 ID：智能体调用优先用 scopedSessionID，否则用当前前台会话。
    private var effectiveSessionID: UUID? { scopedSessionID ?? currentSessionID }

    /// UA 预设（手动浏览默认 Mobile；智能体使用 Desktop）
    enum UAProfile: String, CaseIterable {
        case mobile
        case desktop
    }

    /// 桌面 Safari UA（提供给 智能体使用）
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    /// 移动端（iOS）UA
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 当前 UA 预设（持久化到 UserDefaults，默认 Mobile Safari）
    /// fileprivate：供同文件内的 BrowserTab.init 直接读取，避免触发 `BrowserController.shared` 递归初始化。
    fileprivate static let uaProfileKey = "miniClaw.browserUAProfile"
    var uaProfile: UAProfile {
        get { UAProfile(rawValue: UserDefaults.standard.string(forKey: Self.uaProfileKey) ?? "") ?? .mobile }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.uaProfileKey) }
    }
    /// 当前 UA 字符串：**以浏览器 UA 预设（uaProfile）为单一事实来源**。
    /// 之前误读 settings.browser.uaMode（通用设置另一套存储），导致在浏览器设置里
    /// 切「Desktop Safari」后 applyUAProfileToAllTabs 仍应用移动 UA，页面不变。
    /// desktop → 桌面 UA；mobile → 移动 UA（通用设置配了 custom 且非空时用 custom）。
    static func defaultUAString() -> String {
        let profile = UAProfile(rawValue: UserDefaults.standard.string(forKey: uaProfileKey) ?? "") ?? .mobile
        switch profile {
        case .desktop:
            return BrowserController.desktopUA
        case .mobile:
            let b = SettingsStore.shared.settings.browser
            if b.uaMode == "custom" {
                let custom = b.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !custom.isEmpty { return custom }
            }
            return BrowserController.mobileUA
        }
    }

    /// 当前预设对应的 UA 字符串
    var currentUAString: String { Self.defaultUAString() }

    /// 将当前 UA 预设应用到当前上下文的所有标签
    func applyUAProfileToAllTabs() {
        let ua = currentUAString
        for tab in activeContext.tabs { tab.webView.customUserAgent = ua }
    }

    // MARK: - 对外状态（SwiftUI 观察）

    @Published var activeIndex: Int = 0
    @Published var tabInfos: [TabInfo] = []
    /// 加载进度（0-1）。完成时先置 1（输入框填满），停留 1s 后归零（UI 动画恢复灰色）。
    @Published var loadingProgress: Double = 0
    /// 标签导航完成(didFinish)信号：携带该标签 id，UI 层据此使快照缓存失效。
    let tabDidFinishPublisher = PassthroughSubject<UUID, Never>()



    /// 加载完成（didFinish/didFail）：进度填满 1.0（UI 停 1s 后整体淡出恢复原色）。
    func notifyLoadingFinished() {
        loadingProgress = 1.0
    }

    struct TabInfo: Identifiable, Equatable {
        let id: UUID
        var title: String
        var url: String
    }

    // MARK: - 内部状态（路由到当前上下文）

    private let fs = FileSystemManager.shared
    private var tabs: [BrowserTab] {
        get { activeContext.tabs }
        set { activeContext.tabs = newValue }
    }
    private var _tabsAccess: BrowserContext { activeContext }

    private override init() {
        super.init()
        _ = ensureTab(at: 0)
        rebuildTabInfos()
    }

    /// 当前激活标签的 WKWebView（供 UI 直接嵌入）。
    /// 单一事实来源：controller.activeIndex（@Published，UI 高亮/地址栏/切换全用它）；
    /// 曾因 BrowserContext 另存一份 activeIndex 且从不赋值（恒 0），导致
    /// 「切换/弹窗新标签后网页永远显示第一个标签」——已删掉重复状态。
    var activeWebView: WKWebView? { tabs[safe: activeIndex]?.webView }

    var canGoBack: Bool { tabs[safe: activeIndex]?.webView.canGoBack ?? false }
    var canGoForward: Bool { tabs[safe: activeIndex]?.webView.canGoForward ?? false }

    // MARK: - 上下文管理

    /// 更新当前会话（ChatView 进入/退出时调用），切换浏览器上下文
    func setSession(_ sessionID: UUID?) {
        currentSessionID = sessionID
        // 上下文首次进入（新会话/手动模式的上下文 tabs 为空）：补初始标签，
        // 否则 activeWebView 为 nil、手动输入网址 navigate 报「标签不存在」——首页空浏览器无反应的根因。
        _ = ensureTab(at: 0)
        rebuildTabInfos()
    }

    /// 会话感知的 `miniclaw://` 资源解析（截图/下载预览用）：带当前有效会话解析，
    /// 否则会话独享目录（browser/attachments 等）会解析到扁平目录而 miss，
    /// 表现为「全页截图并分享」不弹分享页。
    func resolveResourceURL(_ raw: String) -> String? {
        FileSystemManager.shared.resolveMiniClawResourceURL(raw, sessionID: effectiveSessionID)?.path
    }

    /// 销毁指定会话的浏览器上下文
    func destroySession(_ sessionID: UUID) {
        contextManager.destroy(sessionID: sessionID)
    }

    /// 将浏览器切到首页手动浏览上下文（与任何 智能体会话完全隔离）。
    /// 打开首页浏览器前调用，避免首页看到某个 智能体会话搜过的内容。
    func setManualSession() {
        currentSessionID = manualSessionID
        // 同上：manual 上下文首次进入必须有初始标签。
        _ = ensureTab(at: 0)
        rebuildTabInfos()
    }

    /// 智能体工具入口：在指定会话上下文内执行，完全独立于全局 currentSessionID（首页/手动浏览）。
    /// 通过 scopedSessionID 临时覆盖 activeContext 的解析目标，调用结束后恢复。
    /// - Parameter tabID: 稳定标签 id（list_tabs 返回的 tab_id；标签增删后索引漂移但 id 稳定）。
    ///   优先于 tabIndex 解析，换算成当前索引后走原链路；nil 则仅用 tabIndex。
    /// 2026-08-10:动作参数 → 引擎 MiniClawActionInput(引擎优先路径)
    private static func engineInput(action: String, params: [String: Any]) -> MiniClawKit.MiniClawActionInput? {
        guard let browserAction = MiniClawKit.MiniClawBrowserAction(rawValue: action) else { return nil }
        return MiniClawKit.MiniClawActionInput(
            action: browserAction,
            url: params["url"] as? String,
            selector: params["selector"] as? String,
            text: params["text"] as? String,
            coordinateX: params["x"] as? Int,
            coordinateY: params["y"] as? Int,
            direction: (params["direction"] as? String).flatMap(MiniClawKit.MiniClawActionInput.ScrollDirection.init),
            amount: params["amount"] as? Int,
            script: params["script"] as? String,
            userAgent: (params["user_agent"] as? String).flatMap(MiniClawKit.MiniClawUAProfile.init),
            maxDepth: params["max_depth"] as? Int,
            tabId: params["tab_id"] as? Int,
            scrollCount: params["scroll_count"] as? Int,
            itemSelector: params["item_selector"] as? String,
            keywords: params["keywords"] as? [String],
            fuzzy: params["fuzzy"] as? Bool,
            timeout: params["timeout"] as? Int,
            viewportWidth: params["width"] as? Int,
            viewportHeight: params["height"] as? Int,
            viewportReset: params["reset"] as? Bool,
            fullPage: params["full_page"] as? Bool,
            cookies: params["cookies"] as? [[String: Any]]
        )
    }

    /// 2026-08-10:引擎执行(共用池:UI 与工具同一引擎,标签同步)
    private func engineExecute(input: MiniClawKit.MiniClawActionInput, sessionID: UUID?) async throws -> String {
        let pool = enginePool(for: sessionID)
        let result = try await pool.execute(action: input, singleTab: false)
        return result.text
    }

    /// 引擎标签池(2026-08-10:与 UI 适配桥共用同一池,标签同步)
    private func enginePool(for sessionID: UUID?) -> MiniClawKit.MiniClawTabPool {
        BrowserEngineAdapter.shared.pool(for: sessionID)
    }

    func run(action: String, paramsData: Data, tabIndex: Int?, tabID: String?, sessionID: UUID?) async throws -> String {
        // 用户已取消托管（点「取消托管」按钮或手动操作过浏览器）：智能体的浏览器操作立即被拒，
        // 工具返回错误文本给模型，模型据此停止操作浏览器。
        guard !agentControlRevoked else {
            throw ToolError.executionFailed("用户已手动接管浏览器（取消了智能体托管），请停止浏览器操作，改用其它工具或直接回答。")
        }
        // 串行门：浏览器工具在引擎侧被并发调用（如一次回复里同时开两个标签页），
        // 此处串行化，避免并行写坏 scopedSessionID / activeIndex / tabs 等共享状态导致死锁或转圈。
        await serialGate.enter()
        defer { serialGate.leave() }
        // 取消可能在排队期间发生：进入临界区后复查一次，
        // 拒绝「取消时已排队、随后才轮到」的并发调用（防用户要点 N 次取消才能挡住 N 个调用）。
        guard !agentControlRevoked else {
            throw ToolError.executionFailed("用户已手动接管浏览器（取消了智能体托管），请停止浏览器操作，改用其它工具或直接回答。")
        }
        markAgentOperating()
        defer { scheduleAgentOperationEnd() }
        scopedSessionID = sessionID
        defer { scopedSessionID = nil }
        // 2026-08-10:引擎优先——照搬引擎执行;引擎不识别/执行异常时回退旧实现。
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        if let engineInput = Self.engineInput(action: action, params: params),
           let engineText = try? await engineExecute(input: engineInput, sessionID: sessionID) {
            return engineText
        }
        let result = try await run(action: action, paramsData: paramsData, tabIndex: tabIndex, tabID: tabID)
        // Cookie 保活：每个动作成功后节流快照；检测到登录 Cookie 被系统清除时自动重注入（对抗 ITP）。
        await keepAliveCookies()
        return result
    }

    // MARK: - 标签管理

    private func ensureTab(at index: Int) -> BrowserTab {
        while tabs.count <= index {
            let tab = BrowserTab()
            tab.navDelegate.controller = self
            ensureHosted(tab)
            tabs.append(tab)
        }
        observeProgress(for: tabs[index])
        return tabs[index]
    }

    /// KVO 观察当前标签 webView 的加载进度（estimatedProgress），发布到 loadingProgress。
    /// 完成（estimatedProgress >= 1）走 notifyLoadingFinished：填满后由 UI 淡出。
    /// 每个标签独立的进度观察（P3-1 修复：原单槽在并发开标签时互相 invalidate，
    /// 只有最后一个标签有进度显示）。按 tab.id 建字典，关闭标签时移除。
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    private func observeProgress(for tab: BrowserTab) {
        progressObservations[tab.id]?.invalidate()
        progressObservations[tab.id] = tab.webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                guard let self else { return }
                // 只发布当前激活标签的进度（进度条语义 = 用户正在看的标签；
                // 后台标签加载不影响进度条，多标签并发互不干扰）。
                guard self.tabs[safe: self.activeIndex]?.webView === wv else { return }
                if wv.estimatedProgress >= 1.0 {
                    self.notifyLoadingFinished()
                } else {
                    // 单调化：WebKit 的 estimatedProgress 在加载中会因资源权重重估而回落
                    // （大文件先占权重、后续小资源摊薄），直接映射会出现进度回缩。
                    // 只增不减，用户感知的进度条永远向前。新导航由 didStartProvisional 重置。
                    self.loadingProgress = max(self.loadingProgress, wv.estimatedProgress)
                }
            }
        }
    }

    /// 标签销毁时移除观察（防 KVO 悬垂）。
    private func stopObserving(_ tab: BrowserTab) {
        progressObservations[tab.id]?.invalidate()
        progressObservations[tab.id] = nil
    }

    /// 取得指定（或当前激活）标签
    func tab(at index: Int?) -> BrowserTab? {
        let i = index ?? activeIndex
        guard tabs.indices.contains(i) else { return nil }
        return tabs[i]
    }

    private func rebuildTabInfos() {
        tabInfos = tabs.enumerated().map { (i, tab) in
            TabInfo(
                id: tab.id,
                title: tab.title.isEmpty ? (tab.webView.url?.absoluteString ?? "新标签页") : tab.title,
                url: tab.webView.url?.absoluteString ?? ""
            )
        }
        if activeIndex >= tabs.count { activeIndex = max(0, tabs.count - 1) }
    }

    // MARK: - 宿主窗口（用于离屏渲染 / 截图）

    private func currentHost() -> UIView? {
        let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    }

    /// 将 webView 挂到离屏宿主窗口，保证可以渲染、截图
    private func ensureHosted(_ tab: BrowserTab) {
        guard tab.webView.superview == nil else { return }
        guard let host = currentHost() else { return }
        // 宿主用 **frame 布局**（离屏坐标 -10000）。此前设 translatesAutoresizingMaskIntoConstraints=false
        // 却未添加任何约束 → webView bounds 恒为 0x0 → takeSnapshot 返回 0x0 空图，
        // 这就是「非活跃标签切走后再进概览，缩略图空白」的直接根因（日志实证 img=0x0）。
        // 宿主尺寸与宿主窗口一致（= 屏幕尺寸）：viewport 不变 → 页面不重排、
        // 滚动位置不重置。此前硬编码 1024x768 使 viewport 突变，页面重排且滚动回顶部，
        // 概览缩略图从「滑动位置的截图」跳成「顶部截图」（用户实证）。
        tab.webView.translatesAutoresizingMaskIntoConstraints = true
        tab.webView.frame = CGRect(x: -10000, y: 0, width: host.bounds.width, height: host.bounds.height)
        host.addSubview(tab.webView)
    }

    /// 把非活跃标签的 webView 从主视图移回离屏宿主。
    /// 此前用 isHidden 隐藏——**隐藏的 WKWebView 无法正常 takeSnapshot**（截图空白/失败），
    /// 导致「切走后再进标签概览，该标签缩略图消失」；且 isHidden 视图不参与渲染。
    /// 移回宿主（同在 keyWindow，屏幕外坐标）既保持可渲染可截图，也不触发
    /// 「离开 window 再回来交互损坏」的 iOS 18 问题（与 ensureHosted 新建标签同一已验证路径）。
    func rehost(_ webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        if webView.superview != nil {
            webView.removeFromSuperview()
        }
        ensureHosted(tab)
    }

    // MARK: - UI 操作入口（供 BrowserView 调用）

    func uiSelectTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        observeProgress(for: tabs[index])
        rebuildTabInfos()
    }

    /// 标签页概览用：指定标签的网页快照（异步）。失败返回 nil（调用方显示占位矩形）。
    func uiSnapshot(index: Int) async -> UIImage? {
        guard tabs.indices.contains(index) else { return nil }
        let wv = tabs[index].webView
        return await withCheckedContinuation { cont in
            wv.takeSnapshot(with: nil) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    /// 用户手动新建标签（标签栏 + / 菜单「新标签」/ 会话页点链接）。
    /// **不受 maxTabs 限制**（设置里的「最大标签数」只约束 智能体的 new_tab 与自动弹窗）：
    /// 用户永远能新建标签，避免「标签满了却开不了新页」。
    /// 返回 true（恒成功）。用户操作不视为「接管」——智能体操作浏览器优先，
    /// 唯一拒绝途径是 智能体操作期间用户点「取消托管」。
    func uiAddTab(urlString: String? = nil) -> Bool {
        let idx = tabs.count
        _ = ensureTab(at: idx)
        if let urlString, !urlString.isEmpty {
            Task {
                // 与 智能体导航共用串行门（见 uiNavigate 注释）
                await serialGate.enter()
                defer { serialGate.leave() }
                // P1-B 修复：导航执行前标签可能已被用户关闭——不再重建（防「已关闭标签复活」）。
                guard tabs.indices.contains(idx) else { return }
                _ = try? await navigate(action: ["url": urlString], tabIndex: idx)
            }
        }
        activeIndex = idx
        rebuildTabInfos()
        return true
    }

    /// 供「新标签页」使用：新建一个标签并承载页面。
    /// 两条调用路径：
    /// 1. 原生弹窗回调（WebKit 传入 configuration）——必须用传入的 config 创建
    ///    （官方要求，否则 WebKit 不加载请求），WebKit 自动加载，无需手动 load；
    /// 2. 页面接管（iOS 18 系统弹窗回调不可靠，脚本拦截 target=_blank/window.open
    ///    走 message handler）——无 WebKit config，用当前上下文的 config（同会话
    ///    dataStore），创建后主动 load(urlString)。
    /// **不挂离屏宿主**：macOS 实测无父视图的 webView 弹窗加载正常；而同步挂到
    /// 离屏宿主(-10000)再移入可见层级,在 iOS 17+ 存在「移入后不渲染」的已知风险。
    /// 弹窗是给用户看的(不走 智能体截图路径),无需离屏宿主,直接交由 SwiftUI 挂载。
    /// 达到标签上限时返回 nil（由调用方忽略弹窗）。
    func openPopupTab(urlString: String?, configuration: WKWebViewConfiguration? = nil) -> WKWebView? {
        guard tabs.count < BrowserController.maxTabs else {
            AppLogger.shared.info("弹窗被忽略：已达标签上限（\(BrowserController.maxTabs) 个）", category: "Browser", subsystem: "Browser")
            return nil
        }
        let idx = tabs.count
        // WebKit 传入的 configuration：关闭「不在窗口即挂起」（iOS 17+）与
        // 「window.open 需自动允许」（官方默认 iOS false 会静默拒绝无手势弹窗）。
        if let configuration {
            if #available(iOS 17.0, *) {
                configuration.preferences.inactiveSchedulingPolicy = .none
            }
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        }
        let config = configuration ?? activeContext.makeWebViewConfiguration()
        let tab = BrowserTab(config: config, uaString: Self.defaultUAString())
        tab.navDelegate.controller = self
        tabs.append(tab)
        observeProgress(for: tab)
        activeIndex = idx
        rebuildTabInfos()
        AppLogger.shared.info("弹窗:已创建标签 #\(idx)(共 \(tabs.count) 个),url=\(urlString ?? "")", category: "Browser", subsystem: "Browser")
        // 页面接管路径：WebKit 不会自动加载，需主动 load；原生回调路径由 WebKit 加载。
        if configuration == nil, let urlString, let url = URL(string: urlString) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            tab.webView.load(req)
        }
        return tab.webView
    }

    func uiCloseTab(index: Int) {
        guard tabs.indices.contains(index), tabs.count > 1 else { return }
        let tab = tabs.remove(at: index)
        tab.webView.removeFromSuperview()
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        rebuildTabInfos()
    }

    /// 用户导航（地址栏/历史/链接）。用户操作不视为「接管」——智能体操作浏览器优先，
    /// 唯一拒绝途径是 智能体操作期间用户点「取消托管」（语义 2026-08-07 收紧）。
    func uiNavigate(urlString: String) {
        // 与 智能体工具入口 run() 共用串行门：用户手动导航与 智能体导航并发会互相覆盖
        // navContinuation/navResolved，导致 continuation 丢失、导航状态错乱。
        Task {
            await serialGate.enter()
            defer { serialGate.leave() }
            try? await navigate(action: ["url": urlString], tabIndex: activeIndex)
        }
    }

    func uiBack() {
        Task {
            await serialGate.enter()
            defer { serialGate.leave() }
            tabs[safe: activeIndex]?.webView.goBack()
        }
    }
    func uiForward() {
        Task {
            await serialGate.enter()
            defer { serialGate.leave() }
            tabs[safe: activeIndex]?.webView.goForward()
        }
    }
    func uiReload() {
        Task {
            await serialGate.enter()
            defer { serialGate.leave() }
            tabs[safe: activeIndex]?.webView.reload()
        }
    }


    // MARK: - 历史记录

    struct BrowserHistoryItem: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let isCurrent: Bool
    }

    /// 读取持久化浏览历史（跨启动），供「历史记录」面板展示。
    /// 原实现读 WKWebView.backForwardList（当前 webView 会话内后退/前进列表），
    /// App 重启或重新进入浏览器后为空——改为落盘历史（BrowserHistoryStore）。
    func uiHistoryItems() -> [BrowserHistoryItem] {
        BrowserHistoryStore.shared.all().map { entry in
            BrowserHistoryItem(url: URL(string: entry.url) ?? URL(string: "about:blank")!,
                               title: entry.title.isEmpty ? entry.url : entry.title,
                               isCurrent: false)
        }
    }

    /// 清空全部浏览历史。
    func uiClearHistory() {
        BrowserHistoryStore.shared.clear()
    }

    /// 从历史记录点击某条后跳转（按 URL 重新导航）。
    func uiGoToHistory(url: URL) {
        uiNavigate(urlString: url.absoluteString)
    }

    func uiScreenshot(fullPage: Bool = false) async -> String? {
        do {
            return try await screenshot(tabIndex: activeIndex, fullPage: fullPage)
        } catch {
            return nil
        }
    }

    // MARK: - miniclaw:// 资源解析

    /// 将 miniclaw:// 资源安全解析为本地文件绝对路径；导航型 deep link 返回 nil。
    static func resolveMiniClawURL(_ raw: String) -> String? {
        FileSystemManager.shared.resolveMiniClawResourceURL(raw)?.path
    }

    // MARK: - 统一操作入口

    /// action: 操作名；paramsData: 参数字典的 JSON 序列化（Sendable，安全跨 actor）；tabIndex: 目标标签（nil=当前）
    /// 返回：给模型的文本结果
    /// 内部执行（private：智能体唯一入口是带 sessionID 与托管守卫的 `run(action:paramsData:tabIndex:sessionID:)`）。
    private func run(action: String, paramsData: Data, tabIndex: Int?, tabID: String? = nil) async throws -> String {
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        // 稳定 tab_id 寻址（A 方案）：优先按 id 定位——标签增删（智能体开/关、弹窗、用户操作）会
        // 让 tab_index 漂移失效，但 tab_id 恒稳定。换算成当前索引再走原链路；id 不存在即报错。
        var resolvedIndex = tabIndex
        if let tabID, let uuid = UUID(uuidString: tabID) {
            guard let idx = tabs.firstIndex(where: { $0.id == uuid }) else {
                throw ToolError.invalidParameters("标签不存在（tab_id 已失效：该标签可能已被关闭，请先 list_tabs 获取最新 tab_id/tab_index 再操作）")
            }
            resolvedIndex = idx
        }
        switch action {
        case "navigate":           return try await navigate(action: params, tabIndex: resolvedIndex, applyDesktopUA: true)
        case "screenshot":         return try await screenshotAction(params, tabIndex: resolvedIndex)
        case "click":              return try await click(params, tabIndex: resolvedIndex)
        case "type":               return try await typeText(params, tabIndex: resolvedIndex)
        case "get_text":           return try await getText(params, tabIndex: resolvedIndex)
        case "get_readable":       return try await getReadable(params, tabIndex: resolvedIndex)
        case "get_page_info":      return try await getPageInfo(params, tabIndex: resolvedIndex)
        case "get_backbone":       return try await getBackbone(params, tabIndex: resolvedIndex)
        case "scroll":             return try await scroll(params, tabIndex: resolvedIndex)
        case "scroll_and_collect": return try await scrollAndCollect(params, tabIndex: resolvedIndex)
        case "execute_js":         return try await executeJS(params, tabIndex: resolvedIndex)
        case "find_elements":      return try await findElements(params, tabIndex: resolvedIndex)
        case "hover":              return try await hover(params, tabIndex: resolvedIndex)
        case "set_user_agent":     return try await setUserAgent(params, tabIndex: resolvedIndex)
        case "set_viewport":       return try await setViewport(params, tabIndex: resolvedIndex)
        case "fetch":              return try await fetchResource(params)
        case "new_tab":            return try await newTab(params)
        case "close_tab":          return try await closeTab(params)
        case "list_tabs":          return listTabs()
        case "get_cookies":        return try await getCookies(params)
        case "set_cookies":        return try await setCookies(params)
        case "wait_for_dom_stable":return try await waitForDomStable(params, tabIndex: resolvedIndex)
        default:
            throw ToolError.invalidParameters("未知浏览器操作: \(action)")
        }
    }

    // MARK: - 操作实现

    private func navigate(action params: [String: Any], tabIndex: Int?, applyDesktopUA: Bool = false) async throws -> String {
        guard let raw = params["url"] as? String, !raw.isEmpty else {
            throw ToolError.invalidParameters("navigate 需要 url 参数")
        }
        // 寻址（P1-B 修复）：显式 tabIndex 越界 → 报错引导（绝不静默重建幽灵标签）；
        // 未指定时用当前激活标签（空标签组兜底创建 0 号）。
        let tab: BrowserTab
        if let tabIndex {
            // self. 前缀：局部变量 tab 会遮蔽同名方法 tab(at:)
            guard let t = self.tab(at: tabIndex) else {
                throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作")
            }
            tab = t
        } else {
            tab = self.tab(at: nil) ?? ensureTab(at: 0)
        }
        activeIndex = tabs.firstIndex(where: { $0 === tab }) ?? activeIndex
        // 智能体通过 run 导航时强制使用桌面 UA（提供给 智能体抓取/阅读用）；手动浏览沿用当前 UA 预设
        if applyDesktopUA { tab.webView.customUserAgent = BrowserController.desktopUA }
        ensureHosted(tab)

        guard !raw.lowercased().hasPrefix("miniclaw://") else {
            throw ToolError.invalidParameters("miniclaw:// 是 App 内部 deep link，不可传入浏览器工具；请在聊天中输出 Markdown 链接")
        }
        guard !raw.hasPrefix("file://"), !raw.hasPrefix("/") else {
            throw ToolError.invalidParameters("浏览器工具仅接受 http/https URL，不可直接读取本地文件")
        }
        let loadURLString = normalizeURL(raw)

        guard let url = URL(string: loadURLString) else {
            throw ToolError.invalidParameters("非法 URL: \(raw)")
        }

        tab.navResolved = false
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            tab.navContinuation = cont
            if loadURLString.hasPrefix("file://") {
                let dir = url.deletingLastPathComponent()
                tab.webView.loadFileURL(url, allowingReadAccessTo: dir)
            } else {
                var req = URLRequest(url: url)
                req.timeoutInterval = 30
                tab.webView.load(req)
            }
            // 超时：SPA 可能没有明确的 didFinish，最多等 15s 后视为完成。
            // 正常页面会在 didFinish 时立即 resume，远快于此；15s 仅为防止无限转圈的兜底。
            // 已正常完成（navResolved）时不置超时标记，避免把成功导航误报为超时。
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if !tab.navResolved { tab.navTimedOut = true }
                tab.resolveNav()
            }
        }
        rebuildTabInfos()
        return pageInfoJSON(tab, requested: loadURLString)
    }

    private func screenshotAction(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        let full = params["full_page"] as? Bool ?? false
        return try await screenshot(tabIndex: tabIndex, fullPage: full)
    }

    private func screenshot(tabIndex: Int?, fullPage: Bool) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        ensureHosted(tab)
        // 等一帧确保渲染
        try? await Task.sleep(nanoseconds: 200_000_000)

        let image: UIImage
        if fullPage {
            let size = try await contentSize(tab)
            // 整页截图尺寸上限（2026-08-07 修复「截图编码失败」根因）：
            // 旧实现把 webView 拉到最高 32768pt 且 snapshotWidth 用原始 pt 宽度——
            // 3x 屏下可达 1170×98304px ≈ 460MB RGBA，超出 GPU 纹理上限（16384px）导致
            // WKSnapshot 渲染异常，随后 jpegData 内存分配失败返回 nil → 「截图编码失败」。
            // 修复：宽度钳到 780pt 逻辑宽（看清页面足够），高度按屏幕 scale 折算到纹理安全区
            // （16384px 内，@3x ≈ 5461pt；@2x ≈ 8192pt），总像素 ≈ 1900 万（约 77MB），必成功。
            let screenScale = UIScreen.main.scale
            let maxTexturePixels: CGFloat = 16384
            let cappedWidth = min(CGFloat(size.width), 780)
            let maxH = min(CGFloat(size.height), maxTexturePixels / screenScale)
            let oldFrame = tab.webView.frame
            tab.webView.frame = CGRect(x: -10000, y: 0, width: cappedWidth, height: maxH)
            tab.webView.layoutIfNeeded()
            // 无论截图成功/超时/抛错都必须恢复 frame：否则 webView 保持拉伸 frame，
            // 影响后续渲染并放大内存占用。defer 覆盖所有退出路径。
            defer { tab.webView.frame = oldFrame }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let cfg = WKSnapshotConfiguration()
            cfg.snapshotWidth = NSNumber(value: Double(cappedWidth))
            image = try await snapshot(tab.webView, config: cfg)
        } else {
            image = try await snapshot(tab.webView, config: nil)
        }

        // JPEG 编码降级重试（源头兜底）：内存压力下 jpegData 可能返回 nil——
        // 逐级降采样（1/2、1/4、1/8）重试，确保编码必成功；全失败才报错。
        // 线程治理（2026-08-09）：大图 jpegData 编码数百 ms，移后台执行不阻塞主线程。
        // UIImage 非 Sendable，经 @unchecked Sendable 盒只读传递（编码不修改 image）。
        let box = JPEGEncodeBox(image: image)
        let data: Data = try await Task.detached(priority: .userInitiated) {
            let image = box.image
            if let d = image.jpegData(compressionQuality: 0.85) {
                return d
            }
            var downsampled: Data?
            var divisor: CGFloat = 2
            while divisor <= 8 {
                let small = Self.downscaled(image, divisor: divisor)
                downsampled = small.jpegData(compressionQuality: 0.85)
                if downsampled != nil { break }
                divisor *= 2
            }
            guard let d = downsampled else {
                throw ToolError.executionFailed("截图编码失败")
            }
            return d
        }.value
        let filename = "screenshot_\(Int(Date().timeIntervalSince1970)).jpg"
        try fs.writeAutomaticData(
            at: "/var/MiniClaw/browser/\(filename)",
            data: data,
            actor: .browserAutomatic,
            sessionID: effectiveSessionID
        )
        rebuildTabInfos()
        return "miniclaw://browser/\(filename)"
    }

    /// 截图编码失败时的降采样辅助：按除数缩小图像（UIGraphicsImageRenderer 软缩放，
    /// 内存占用按 1/divisor² 下降，编码必成功）。
    /// nonisolated：后台线程调用（线程治理 2026-08-09）。
    nonisolated private static func downscaled(_ image: UIImage, divisor: CGFloat) -> UIImage {
        let size = CGSize(width: image.size.width / divisor, height: image.size.height / divisor)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func click(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        if let x = params["x"] as? Double, let y = params["y"] as? Double {
            let script = """
            (function(){
              var el = document.elementFromPoint(\(x), \(y));
              if(!el) return JSON.stringify({ok:false, error:'no element at (\(x),\(y))'});
              el.scrollIntoView({block:'center'});
              el.click();
              return JSON.stringify({ok:true, tag:el.tagName.toLowerCase()});
            })()
            """
            return try await js(tab, script)
        }
        guard let selector = params["selector"] as? String else {
            throw ToolError.invalidParameters("click 需要 selector 或 x/y")
        }
        let sel = jsStringLiteral(selector)
        let script = """
        (function(){
          var el = document.querySelector(\(sel));
          if(!el) return JSON.stringify({ok:false, error:'element not found: \(selector)'});
          el.scrollIntoView({block:'center'});
          el.click();
          return JSON.stringify({ok:true, tag:el.tagName.toLowerCase()});
        })()
        """
        return try await js(tab, script)
    }

    private func typeText(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        guard let selector = params["selector"] as? String else {
            throw ToolError.invalidParameters("type 需要 selector")
        }
        guard let text = params["text"] as? String else {
            throw ToolError.invalidParameters("type 需要 text")
        }
        let sel = jsStringLiteral(selector)
        let txt = jsStringLiteral(text)
        let script = """
        (function(){
          var el = document.querySelector(\(sel));
          if(!el) return JSON.stringify({ok:false, error:'element not found: \(selector)'});
          var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, \(txt));
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
          // 框架适配：Angular / Vue 受控组件需要额外通知才能同步模型（自研，防填表后校验不通过）
          try { if (window.angular && angular.element && angular.element(el).scope()) { angular.element(el).scope().$apply(); } } catch(e){}
          try { if (el.__vue__ && el.__vue__.$forceUpdate) { el.__vue__.$forceUpdate(); } } catch(e){}
          try { el.dispatchEvent(new Event('blur', {bubbles:true})); } catch(e){}
          return JSON.stringify({ok:true, tag:el.tagName.toLowerCase()});
        })()
        """
        return try await js(tab, script)
    }

    private func getText(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        guard let selector = params["selector"] as? String, !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 模型想取「整页文本内容」却漏传 selector：降级为整页可读正文提取，
            // 避免 get_text 缺参直接报错导致重试，与 get_readable 等价。
            return try await getReadable(params, tabIndex: tabIndex)
        }
        let sel = jsStringLiteral(selector)
        let script = "document.querySelector(\(sel)) ? document.querySelector(\(sel)).innerText : ''"
        return try await js(tab, script)
    }

    private func getReadable(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        let maxLen = params["max_length"] as? Int ?? 8000
        let script = """
        (function(){
          var clone = document.body.cloneNode(true);
          clone.querySelectorAll('script,style,nav,header,footer,aside,svg,noscript').forEach(function(e){e.remove();});
          var text = (clone.innerText || '').replace(/\\s+/g,' ').trim();
          return text;
        })()
        """
        let text = try await js(tab, script)
        // 空白 + 仍在加载 → 明确提示，避免把空/旧页面当结果（曾导致检索空转）。
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if tab.webView.isLoading {
                return "页面仍在加载中，暂无内容。请稍后重试 get_readable，或先等待导航完成。"
            }
            return "页面内容为空（可能被反爬/JS 未渲染）。建议换渠道或换 URL，不要重复读取同一页面。"
        }
        if text.count > maxLen { return String(text.prefix(maxLen)) + "\n…(已截断)" }
        return text
    }

    private func getPageInfo(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        let script = """
        (function(){
          var m = document.querySelector('meta[name="description"]');
          return JSON.stringify({
            title: document.title,
            url: location.href,
            description: m ? m.getAttribute('content') : '',
            lang: document.documentElement.lang || '',
            readyState: document.readyState
          });
        })()
        """
        return try await js(tab, script)
    }

    private func getBackbone(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        let script = """
        (function(){
          function walk(node, depth){
            if(depth>5) return null;
            if(node.nodeType!==1) return null;
            var tag=node.tagName.toLowerCase();
            if(['script','style','meta','link','head','noscript','svg'].indexOf(tag)>=0) return null;
            var text=(node.innerText||'').replace(/\\s+/g,' ').trim().slice(0,60);
            var children=[];
            for(var i=0;i<node.children.length;i++){
              var c=walk(node.children[i],depth+1);
              if(c) children.push(c);
            }
            return {tag:tag, id:node.id||undefined, cls:(typeof node.className==='string'?node.className.split(' ').slice(0,3).join('.'):undefined), text:text, children:children};
          }
          return JSON.stringify(walk(document.body,0));
        })()
        """
        return try await js(tab, script)
    }

    private func scroll(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        // element 参数：滚动到指定元素（比 window.scrollTo 更精确，配合可滚动容器自动定位）
        if let element = params["element"] as? String, !element.isEmpty {
            let sel = jsStringLiteral(element)
            let script = """
            (function(){
              var el = document.querySelector(\(sel));
              if(!el) return JSON.stringify({ok:false, error:'element not found: \(element)'});
              el.scrollIntoView({behavior:'auto', block:'nearest'});
              // 若元素位于可滚动容器内，滚动该容器到元素可见（长页面翻页场景）
              // 用 getBoundingClientRect 差值（offsetTop 相对 offsetParent，容器内有
              // positioned 中间层时会算错）。
              var er = el.getBoundingClientRect();
              var p = el.parentElement;
              while(p){
                if(p.scrollHeight > p.clientHeight + 8){
                  var pr = p.getBoundingClientRect();
                  p.scrollTop += (er.top - pr.top) - p.clientHeight/2;
                  break;
                }
                p = p.parentElement;
              }
              return JSON.stringify({ok:true, scrollY: window.scrollY});
            })()
            """
            return try await js(tab, script)
        }
        if let direction = params["direction"] as? String {
            let amount = params["amount"] as? Int ?? 400
            let dy = direction == "up" ? -amount : amount
            let script = "window.scrollBy(0, \(dy)); JSON.stringify({scrollY: window.scrollY})"
            return try await js(tab, script)
        }
        let x = params["x"] as? Int ?? 0
        let y = params["y"] as? Int ?? 0
        let script = "window.scrollTo(\(x), \(y)); JSON.stringify({scrollX: window.scrollX, scrollY: window.scrollY})"
        return try await js(tab, script)
    }

    private func scrollAndCollect(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        let maxRounds = min(params["max_rounds"] as? Int ?? 12, 30)
        let selector = params["selector"] as? String
        let sel = selector.map { jsStringLiteral($0) } ?? "document.body"
        let script = """
        (function(){
          var maxRounds = \(maxRounds);
          var sel = \(sel);
          var collected = [];
          var lastSig = '';
          function snapshot(){
            var el = sel === 'document.body' ? document.body : document.querySelector(sel);
            return (el ? el.innerText : '') || '';
          }
          for(var i=0;i<maxRounds;i++){
            var txt = snapshot();
            if(txt && txt.length > collected.join('\\n').length){
              collected.push(txt);
            }
            var before = window.scrollY;
            window.scrollBy(0, window.innerHeight * 0.9);
            if(window.scrollY === before){
              break; // 到底了
            }
          }
          return collected.join('\\n====\\n');
        })()
        """
        return try await js(tab, script)
    }

    private func executeJS(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        guard let rawScript = params["script"] as? String else {
            throw ToolError.invalidParameters("execute_js 需要 script")
        }
        let trimmed = rawScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.invalidParameters("execute_js 的 script 不能为空")
        }

        // WKWebView.evaluateJavaScript 直接执行的是脚本程序，顶层 `return` 属于非法语法。
        // 模型经常生成 `return {...};`，自动包入 IIFE，使其成为合法函数体并保留返回值。
        let script: String
        if trimmed.hasPrefix("return ") || trimmed.hasPrefix("return{") || trimmed == "return;" {
            script = "(function(){\n\(trimmed)\n})()"
        } else {
            script = rawScript
        }

        do {
            return try await js(tab, script)
        } catch {
            let nsError = error as NSError
            throw ToolError.executionFailed(
                "JavaScript 执行失败（\(nsError.domain) code=\(nsError.code)）：\(error.localizedDescription)。若脚本需要返回值，可直接写表达式，或使用 return（系统会自动包装）。"
            )
        }
    }

    private func findElements(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        guard let selector = params["selector"] as? String else {
            throw ToolError.invalidParameters("find_elements 需要 selector")
        }
        let sel = jsStringLiteral(selector)
        let limit = params["limit"] as? Int ?? 20
        let script = """
        (function(){
          var els = document.querySelectorAll(\(sel));
          var out = [];
          for(var i=0;i<els.length && i<\(limit);i++){
            var e = els[i];
            var r = e.getBoundingClientRect();
            out.push({
              index: i,
              tag: e.tagName.toLowerCase(),
              id: e.id || undefined,
              cls: (typeof e.className==='string'? e.className.split(' ').slice(0,4).join('.') : undefined),
              text: (e.innerText||'').replace(/\\s+/g,' ').trim().slice(0,80),
              href: e.href || undefined,
              rect: {x:Math.round(r.x), y:Math.round(r.y), w:Math.round(r.width), h:Math.round(r.height)}
            });
          }
          return JSON.stringify({count: els.length, shown: out.length, elements: out});
        })()
        """
        return try await js(tab, script)
    }

    private func hover(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        guard let selector = params["selector"] as? String else {
            throw ToolError.invalidParameters("hover 需要 selector")
        }
        let sel = jsStringLiteral(selector)
        let script = """
        (function(){
          var el = document.querySelector(\(sel));
          if(!el) return JSON.stringify({ok:false, error:'element not found'});
          el.dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));
          el.dispatchEvent(new MouseEvent('mouseenter', {bubbles:true}));
          return JSON.stringify({ok:true});
        })()
        """
        return try await js(tab, script)
    }

    private func setUserAgent(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        let ua: String
        if let preset = params["preset"] as? String {
            ua = preset == "mobile" ? BrowserController.mobileUA : BrowserController.desktopUA
        } else if let custom = params["ua"] as? String {
            ua = custom
        } else {
            ua = BrowserController.desktopUA
        }
        tab.webView.customUserAgent = ua
        rebuildTabInfos()
        return "UA 已设置为: \(ua.prefix(60))"
    }

    private func setViewport(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        let w = params["width"] as? Double ?? 1024
        let h = params["height"] as? Double ?? 768
        tab.webView.frame = CGRect(x: tab.webView.frame.origin.x, y: 0, width: CGFloat(w), height: CGFloat(h))
        return "视口已设置为 \(Int(w))x\(Int(h))"
    }

    private func fetchResource(_ params: [String: Any]) async throws -> String {
        guard let raw = params["url"] as? String else {
            throw ToolError.invalidParameters("fetch 需要 url")
        }
        guard let url = URL(string: raw) else { throw ToolError.invalidParameters("非法 URL") }

        let filename = url.lastPathComponent
        await DownloadProgressTracker.shared.start(label: filename.isEmpty ? "下载文件" : filename)

        let data: Data
        do {
            data = try await downloadWithProgress(from: url)
        } catch {
            await DownloadProgressTracker.shared.finish()
            throw error
        }
        await DownloadProgressTracker.shared.finish()

        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
        let savedName = "downloaded_\(UUID().uuidString.prefix(8)).\(ext)"
        try fs.writeAutomaticData(
            at: "/var/MiniClaw/browser/\(savedName)",
            data: data,
            actor: .browserAutomatic,
            sessionID: effectiveSessionID
        )
        return "miniclaw://browser/\(savedName)"
    }

    private func downloadWithProgress(from url: URL) async throws -> Data {
        // 迁移到 background session：App 退后台/被杀后下载由系统继续传输，
        // 完成后唤醒 App 收尾（见 BackgroundDownloader）。普通 session 挂起即断。
        return try await BackgroundDownloader.shared.download(from: url)
    }

    private func newTab(_ params: [String: Any]) async throws -> String {
        guard tabs.count < BrowserController.maxTabs else {
            throw ToolError.executionFailed("已达标签上限（\(BrowserController.maxTabs) 个）")
        }
        let idx = tabs.count
        _ = ensureTab(at: idx)
        let targetURL = params["url"] as? String ?? ""
        if !targetURL.isEmpty {
            _ = try? await navigate(action: ["url": targetURL], tabIndex: idx)
        }
        // P1-A 修复：await 导航期间标签可能被用户关闭 → 越界守卫（曾直接 tabs[idx] 崩溃）。
        guard tabs.indices.contains(idx) else {
            throw ToolError.executionFailed("新标签（索引 \(idx)）在加载期间被关闭，请重新 list_tabs 获取最新列表")
        }
        // P3-2 修复：不抢用户当前高亮（智能体后续用 tab_id/tab_index 显式操作新标签即可）。
        rebuildTabInfos()
        // 附加目标页面状态（requested/url/error），模型可立即判断新标签是否加载成功。
        let summary = targetURL.isEmpty ? "" : pageInfoJSON(tabs[idx], requested: targetURL)
        return "新标签已创建，索引 \(idx)（共 \(tabs.count) 个）" + (summary.isEmpty ? "" : "\n" + summary)
    }

    private func closeTab(_ params: [String: Any]) async throws -> String {
        let idx = params["index"] as? Int ?? activeIndex
        guard tabs.indices.contains(idx), tabs.count > 1 else {
            throw ToolError.executionFailed("无法关闭：仅剩一个标签或索引越界")
        }
        let tab = tabs.remove(at: idx)
        stopObserving(tab)
        tab.webView.removeFromSuperview()
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        rebuildTabInfos()
        return "已关闭标签 \(idx)（剩余 \(tabs.count) 个）"
    }

    private func listTabs() -> String {
        let arr = tabs.enumerated().map { (i, tab) in
            ["index": i, "tab_id": tab.id.uuidString, "title": tab.title, "url": tab.webView.url?.absoluteString ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - Cookie 保活（对抗 ITP 清除，自研）

    /// 上次 Cookie 快照时间（60s 节流）。
    private var lastCookieSnapshot: Date?
    /// 最近一次非空 Cookie 备份（检测到被清除时重注入）。
    private var backupCookies: [HTTPCookie] = []
    /// 重注入防护：短时间内反复被清零说明是主动登出/系统策略，放弃保活（防旧登录复活）。
    private var reinjectCount = 0
    private var lastReinjectAt: Date?
    private let reinjectMax = 3
    private let reinjectMinInterval: TimeInterval = 120

    /// 每个动作成功后调用：节流快照；发现「之前有登录 Cookie、现在全空」→ 重注入备份。
    /// 对抗 WebKit 的 ITP（Intelligent Tracking Prevention）在会话中清除 Cookie 的问题。
    /// 防护：仅当非空备份存在且非「反复清零」时才重注入；重注入不覆盖现存新 Cookie。
    private func keepAliveCookies() async {
        let store = activeContext.cookieStore
        if let last = lastCookieSnapshot, Date().timeIntervalSince(last) < 60 { return }
        lastCookieSnapshot = Date()
        let all = await store.allCookies()
        if !backupCookies.isEmpty && all.isEmpty {
            // 反复清零（120s 内再次全空）→ 判定为主动登出/策略清除，放弃并清空备份。
            if let lastReinject = lastReinjectAt,
               Date().timeIntervalSince(lastReinject) < reinjectMinInterval {
                backupCookies = []
                AppLogger.shared.info("CookieKeeper：短时间内两次 Cookie 清零，判定为主动登出，停止重注入", category: "Browser", subsystem: "Browser")
                return
            }
            guard reinjectCount < reinjectMax else {
                backupCookies = []
                return
            }
            reinjectCount += 1
            lastReinjectAt = Date()
            for c in backupCookies {
                await store.setCookie(c)
            }
            AppLogger.shared.info("CookieKeeper：检测到 Cookie 被清除，已重注入 \(backupCookies.count) 条（第 \(reinjectCount) 次）", category: "Browser", subsystem: "Browser")
            return
        }
        if !all.isEmpty { backupCookies = all }
    }

    private func getCookies(_ params: [String: Any]) async throws -> String {
        guard let raw = params["url"] as? String, let url = URL(string: raw) else {
            throw ToolError.invalidParameters("get_cookies 需要 url")
        }
        let store = activeContext.cookieStore
        let all = await store.allCookies()
        let matched = all.filter { $0.domain == url.host || url.host?.hasSuffix("." + $0.domain) == true }
        let arr = matched.map { ["name": $0.name, "value": $0.value, "domain": $0.domain, "path": $0.path] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func setCookies(_ params: [String: Any]) async throws -> String {
        guard let raw = params["url"] as? String, let url = URL(string: raw) else {
            throw ToolError.invalidParameters("set_cookies 需要 url")
        }
        guard let name = params["name"] as? String, let value = params["value"] as? String else {
            throw ToolError.invalidParameters("set_cookies 需要 name 与 value")
        }
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .path: params["path"] as? String ?? "/",
            .domain: params["domain"] as? String ?? url.host ?? ""
        ]
        if let expires = params["expires_days"] as? Double {
            props[.expires] = Date().addingTimeInterval(expires * 86400)
        }
        guard let cookie = HTTPCookie(properties: props) else {
            throw ToolError.executionFailed("构造 Cookie 失败")
        }
        await activeContext.cookieStore.setCookie(cookie)
        return "Cookie 已设置: \(name)"
    }

    private func waitForDomStable(_ params: [String: Any], tabIndex: Int?) async throws -> String {
        guard let tab = tab(at: tabIndex) else { throw ToolError.invalidParameters("标签不存在或已变化，请先 list_tabs 获取最新 tab_id/tab_index 再操作") }
        let timeout = params["timeout"] as? Int ?? 15
        let deadline = Date().addingTimeInterval(Double(timeout))
        var lastState = "unknown"
        // 轮询 readyState，避免返回 Promise（WebKit 在某些环境不会 await Promise，
        // 会把 Promise 对象当返回值导致 WKError 5「结果类型不受支持」）。
        while Date() < deadline {
            lastState = (try? await js(tab, "document.readyState"))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            if lastState == "complete" || lastState == "interactive" {
                return "stable"
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return "timeout (lastState: \(lastState))"
    }

    // MARK: - 工具方法

    private func contentSize(_ tab: BrowserTab) async throws -> (width: CGFloat, height: CGFloat) {
        let script = "JSON.stringify({w: document.documentElement.scrollWidth, h: document.documentElement.scrollHeight})"
        let raw = try await js(tab, script)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let w = (obj["w"] as? NSNumber)?.doubleValue,
              let h = (obj["h"] as? NSNumber)?.doubleValue else {
            return (tab.webView.frame.width, tab.webView.frame.height)
        }
        return (CGFloat(w), CGFloat(h))
    }

    /// 在 WKWebView 上执行 JS。带超时安全网：若 `evaluateJavaScript` 的回调在
    /// `timeoutSeconds` 内未触发（典型场景：页面仍在导航中、求值被卡在 in-flight navigation 后），
    /// 直接抛清晰错误，避免工具调用无限转圈。
    private func js(_ tab: BrowserTab, _ script: String, timeoutSeconds: TimeInterval = 20) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var didResume = false
            var timeoutTask: DispatchWorkItem?
            let finish: (Result<String, Error>) -> Void = { result in
                guard !didResume else { return }
                didResume = true
                timeoutTask?.cancel()
                switch result {
                case .success(let s): cont.resume(returning: s)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            timeoutTask = DispatchWorkItem {
                finish(.failure(ToolError.executionFailed(
                    "JavaScript 执行超时（\(Int(timeoutSeconds))s）：页面可能仍在加载或脚本卡死，请先 navigate 完成、必要时 wait_for_dom_stable 后再取内容"
                )))
            }
            if let t = timeoutTask {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: t)
            }

            tab.webView.evaluateJavaScript(script) { result, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                guard let result else { finish(.success("undefined")); return }
                if let str = result as? String { finish(.success(str)); return }
                if let num = result as? NSNumber { finish(.success(num.stringValue)); return }
                if let dict = result as? [String: Any] {
                    if let data = try? JSONSerialization.data(withJSONObject: dict),
                       let s = String(data: data, encoding: .utf8) {
                        finish(.success(s)); return
                    }
                    finish(.success("\(result)")); return
                }
                if let arr = result as? [Any] {
                    if let data = try? JSONSerialization.data(withJSONObject: arr),
                       let s = String(data: data, encoding: .utf8) {
                        finish(.success(s)); return
                    }
                    finish(.success("\(result)")); return
                }
                finish(.success("\(result)"))
            }
        }
    }

    private func snapshot(_ webView: WKWebView, config: WKSnapshotConfiguration?) async throws -> UIImage {
        // 与 js() 一致的必然终态保障：页面渲染引擎卡死/导航中时 takeSnapshot 回调可能永不触发，
        // 无超时会让工具调用无限转圈。20s 兜底 + didResume 防重入。
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UIImage, Error>) in
            var didResume = false
            var timeoutTask: DispatchWorkItem?
            let finish: (Result<UIImage, Error>) -> Void = { result in
                guard !didResume else { return }
                didResume = true
                timeoutTask?.cancel()
                switch result {
                case .success(let img): cont.resume(returning: img)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            timeoutTask = DispatchWorkItem {
                finish(.failure(ToolError.executionFailed("截图超时（20s）：页面渲染引擎可能卡死，请稍后重试")))
            }
            if let t = timeoutTask {
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: t)
            }

            webView.takeSnapshot(with: config) { image, error in
                if let image {
                    finish(.success(image))
                } else if let error {
                    finish(.failure(error))
                } else {
                    finish(.failure(ToolError.executionFailed("截图失败")))
                }
            }
        }
    }

    /// 直接读取 WKWebView 原生属性构造页面信息，**不调用 evaluateJavaScript**，
    /// 避免在页面仍处 in-flight navigation 时 JS 求值被排队、反复卡满 20s 兜底导致工具调用"一致转圈"。
    private func pageInfoJSON(_ tab: BrowserTab, requested: String? = nil) -> String {
        let title = tab.webView.title ?? tab.title ?? ""
        let url = tab.webView.url?.absoluteString ?? ""
        let readyState = tab.webView.isLoading ? "loading" : "complete"
        var dict: [String: Any] = ["title": title, "url": url, "readyState": readyState]
        // 目标 URL：让模型始终知道「自己请求了什么」，与 url(实际)对比可判断重定向/加载失败。
        if let requested { dict["requested"] = requested }
        if let err = tab.navFailedError { dict["error"] = err }
        // 导航超时：明确告知模型，避免把「加载中」中间态当成功继续空等。
        if tab.navTimedOut {
            dict["error"] = "导航超时（15s 无完成回调）：页面可能仍在加载或无法访问，建议换 URL 或换渠道重试"
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        var fallback = "{\"title\":\"\(title)\",\"url\":\"\(url)\",\"readyState\":\"\(readyState)\""
        if let requested { fallback += ",\"requested\":\"\(requested)\"" }
        if let err = tab.navFailedError { fallback += ",\"error\":\"\(err)\"" }
        if tab.navTimedOut {
            fallback += ",\"error\":\"导航超时（15s 无完成回调）：页面可能仍在加载或无法访问，建议换 URL 或换渠道重试\""
        }
        return fallback + "}"
    }

    private func normalizeURL(_ raw: String) -> String {
        let url = raw
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        // data: URL 是合法协议（iOS Safari 支持），保留原样（自测/诊断页用）。
        if url.hasPrefix("data:") { return url }
        if url.contains(".") && !url.contains(" ") {
            return "https://" + url
        }
        // 纯文本（搜索词）→ 按「浏览器设置 → 搜索引擎」跳转（默认 bing；仅切换搜索，非默认首页）。
        let engine = SearchEngine(rawValue: SettingsStore.shared.settings.browser.searchEngine) ?? .bing
        return engine.searchURL(query: url)
    }

    private func jsStringLiteral(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        if let data, let str = String(data: data, encoding: .utf8), str.hasPrefix("[") {
            return String(str.dropFirst().dropLast()) // 去掉 [ ]
        }
        return "'" + s.replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

// MARK: - 标签模型

@MainActor
final class BrowserTab: NSObject {
    let id = UUID()
    let webView: WKWebView
    let navDelegate: BrowserNavDelegate
    let uiDelegate: BrowserUIDelegate

    var title: String = ""
    var navContinuation: CheckedContinuation<Void, Error>?
    var navResolved = false
    /// 最近一次主框架导航失败的错误描述（成功导航时清空；pageInfoJSON 带上供模型判断）。
    var navFailedError: String? = nil
    /// 导航 15s 超时兜底已触发（SPA/慢站无 didFinish）：pageInfoJSON 据此返回明确超时错误，
    /// 避免模型把「加载中」中间态当成功结果继续空等。
    var navTimedOut = false

    /// 无参 init（保留给旧代码兼容；新代码应使用 BrowserContext.makeWebViewConfiguration）
    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 同 BrowserContext.makeWebViewConfiguration：让 window.open 类弹窗请求到达 delegate
        // （iOS 默认 false 会静默拒绝，回调都不触发）。
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // iOS 17+ 机制：webView 不在窗口时（离屏宿主 / 弹窗创建瞬间）导航任务默认可能被挂起，
        // 表现为「回调被调了、tab 建了、页面永远不加载」。显式 .none = 正常调度。
        // （官方文档：WKPreferences.inactiveSchedulingPolicy，iOS 17.0+）
        if #available(iOS 17.0, *) {
            config.preferences.inactiveSchedulingPolicy = .none
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.minimumZoomScale = 1.0
        wv.scrollView.maximumZoomScale = 5.0
        Self.applyDarkModeBackground(to: wv)
        let defaultUA = BrowserController.defaultUAString()
        wv.customUserAgent = defaultUA
        self.config = config
        self.webView = wv
        self.navDelegate = BrowserNavDelegate()
        self.uiDelegate = BrowserUIDelegate()
        super.init()
        wv.navigationDelegate = navDelegate
        navDelegate.tab = self
        wv.uiDelegate = uiDelegate
        uiDelegate.tab = self
        installGestureTracking()
    }

    /// 深色模式适配（系统深浅色自动切换的根源修复）：
    /// WKWebView 默认 `underPageBackgroundColor` 是**白色**——页面加载中 / 空白页 /
    /// 下拉回弹（overscroll）都会露出白底，深色系统下整个浏览器看起来"没适配深色"。
    /// 用动态系统色（.systemBackground）填充三层背景，随系统深浅色自动切换；
    /// 网页内容自身的深色由页面 prefers-color-scheme 决定（WKWebView 默认跟随系统）。
    /// static：两个 init 须在 super.init() 前调用（实例方法不被允许）。
    private static func applyDarkModeBackground(to wv: WKWebView) {
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        wv.scrollView.backgroundColor = .systemBackground
        if #available(iOS 15.0, *) {
            wv.underPageBackgroundColor = .systemBackground
        }
    }

    /// 新 init：接受外部 WKWebViewConfiguration（从 BrowserContext 传入，带隔离的 dataStore）
    init(config: WKWebViewConfiguration, uaString: String) {
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.minimumZoomScale = 1.0
        wv.scrollView.maximumZoomScale = 5.0
        Self.applyDarkModeBackground(to: wv)
        wv.customUserAgent = uaString
        self.config = config
        self.webView = wv
        self.navDelegate = BrowserNavDelegate()
        self.uiDelegate = BrowserUIDelegate()
        super.init()
        wv.navigationDelegate = navDelegate
        navDelegate.tab = self
        wv.uiDelegate = uiDelegate
        uiDelegate.tab = self
        installGestureTracking()
    }

    /// 保存 config 引用，供后续读取 websiteDataStore（Cookie 操作等）
    private let config: WKWebViewConfiguration
    var dataStore: WKWebsiteDataStore { config.websiteDataStore }

    /// 最近一次用户手势（touchstart/click）时间；弹窗拦截用（1s 内 = 用户触发）。
    var lastUserGestureAt: Date?
    /// 手势消息 handler（config.userContentController 强持有；tab 持有弱引用方）。
    private var gestureHandler: BrowserGestureHandler?
    /// 「新标签页」消息 handler：页面点击 target=_blank / window.open 时接管。
    private var openTabHandler: BrowserOpenTabHandler?

    /// 判断弹窗请求是否由用户手势触发（用于「拦截弹窗」只拦自动弹窗）。
    func wasRecentUserGesture() -> Bool {
        guard let t = lastUserGestureAt else { return false }
        return Date().timeIntervalSince(t) < 1.0
    }

    /// 注入页面脚本：手势时间戳 + 「新标签页」接管。
    /// 背景（2026-08-05，iOS 18 真机实测）：标准 target=_blank 链接 + 用户手势点击，
    /// WKUIDelegate.createWebViewWithConfiguration **回调不触发**（data: 测试页与
    /// fullScreenCover 双路径均零日志；官方配置 javaScriptCanOpenWindowsAutomatically/
    /// inactiveSchedulingPolicy 已全部到位仍无效；同一链路 macOS 正常）。
    /// 对策：不再依赖系统弹窗回调，改为页面事件层接管——
    /// 捕获 target=_blank 链接点击与 window.open，经 message handler 走我们自己的
    /// 标签创建逻辑（手势判定/拦截开关照常生效）。原生 WKUIDelegate 回调保留兜底
    /// （页面 preventDefault 后原生回调不会来，二者互斥；iframe 内弹窗若脚本未覆盖，
    /// 原生回调仍可接住）。
    /// 每个 tab 独立 config；先 remove 再 add，避免同名 handler 叠堆路由错乱。
    private func installGestureTracking() {
        let handler = BrowserGestureHandler()
        handler.tab = self
        gestureHandler = handler
        let openTab = BrowserOpenTabHandler()
        openTab.tab = self
        openTabHandler = openTab
        let ucc = config.userContentController
        ucc.removeScriptMessageHandler(forName: "miniclawUserGesture")
        ucc.add(handler, name: "miniclawUserGesture")
        ucc.removeScriptMessageHandler(forName: "miniclawOpenTab")
        ucc.add(openTab, name: "miniclawOpenTab")
        let js = """
        (function(){
          function ping(){ try { window.webkit.messageHandlers.miniclawUserGesture.postMessage(Date.now()); } catch(e){} }
          document.addEventListener('touchstart', ping, true);
          document.addEventListener('click', ping, true);
          // ── 新标签页接管（iOS 18 系统弹窗回调不可靠的架构层对策）──
          document.addEventListener('click', function(e){
            try {
              var a = e.target && e.target.closest ? e.target.closest('a[target="_blank"]') : null;
              if (a && a.href && a.href.indexOf('javascript:') !== 0) {
                e.preventDefault();
                window.webkit.messageHandlers.miniclawOpenTab.postMessage(a.href);
              }
            } catch(err){}
          }, true);
          try {
            var _open = window.open.bind(window);
            window.open = function(url, name, features){
              try { window.webkit.messageHandlers.miniclawOpenTab.postMessage(String(url)); } catch(e){}
              return null;
            };
          } catch(e){}
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    deinit {
        config.userContentController.removeScriptMessageHandler(forName: "miniclawUserGesture")
    }

    func resolveNav(throwing error: Error? = nil) {
        guard !navResolved else { return }
        navResolved = true
        guard let cont = navContinuation else { return }
        navContinuation = nil
        if let error { cont.resume(throwing: error) }
        else { cont.resume() }
    }
}

@MainActor
final class BrowserNavDelegate: NSObject, WKNavigationDelegate {
    weak var tab: BrowserTab?
    /// 所属控制器（加载完成回调用；弱引用防环）。
    weak var controller: BrowserController?

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.title = webView.title ?? tab?.title ?? ""
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 新导航开始：重置进度（否则单调化会让新页面从旧进度继续）。
        controller?.loadingProgress = 0
        // 新导航开始即清空旧失败/超时记录（失败/成功都会重写；避免把上一页的错误带给新页）。
        tab?.navFailedError = nil
        tab?.navTimedOut = false
    }


    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.title = webView.title ?? ""
        tab?.resolveNav()
        // 导航完成：通知 UI 该标签内容已更新（快照缓存失效，下次概览重截）。
        if let tabID = tab?.id {
            controller?.tabDidFinishPublisher.send(tabID)
        }
        // 加载完成：进度条填满 → 停 1s → 归零（UI 动画恢复灰色）
        controller?.notifyLoadingFinished()
        // 持久化浏览历史（跨启动）：主框架导航完成即记录。
        // 原实现读 backForwardList（webView 会话内历史），重启/重进浏览器后为空。
        if let url = webView.url?.absoluteString {
            Task { @MainActor in
                BrowserHistoryStore.shared.record(url: url, title: webView.title ?? "")
            }
        }
        // 注入 viewport meta 启用双指缩放——**仅当站点未声明 viewport 时兜底**。
        // 站点已声明(如 user-scalable=no)时绝不覆盖:强制改写成可缩放会破坏其
        // 交互(表现为移动版页面单击无反应、滚动/长按正常,如 36kr/deepseek)。
        webView.evaluateJavaScript("""
            (function(){
                var m=document.querySelector('meta[name=viewport]');
                if(m){return;}
                var n=document.createElement('meta');n.name='viewport';n.content='width=device-width,initial-scale=1.0,maximum-scale=5.0,user-scalable=yes';document.head.appendChild(n);
            })();
            """)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.title = webView.title ?? ""
        // 记录失败原因（SSL/网络/超时等），供 pageInfoJSON 返回给模型判断，
        // 避免把旧页面状态当成新导航结果（曾导致检索串页误判）。
        tab?.navFailedError = (error as NSError).localizedDescription
        // 加载失败同样结束进度：填满 → 停 1s → 归零（避免绿色卡在半截）。
        controller?.notifyLoadingFinished()
        // 主框架已渲染出内容（例如仅子资源失败、或中途重定向），仍视为可用，不硬抛。
        if webView.url != nil {
            tab?.resolveNav()
        } else {
            tab?.resolveNav(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // -999 取消：常因同帧内新导航 / 重定向触发，并非真实失败，直接视为成功。
        if nsError.code == NSURLErrorCancelled {
            tab?.resolveNav()
            return
        }
        // DNS/连接/SSL 等失败几乎都走这里——记录失败原因供 pageInfoJSON 返回给模型，
        // 否则模型看不到最常见的失败场景（曾导致检索串页误判）。
        tab?.navFailedError = nsError.localizedDescription
        controller?.notifyLoadingFinished()
        // 主框架已加载出页面（即便 WebKit 报了兜底失败），仍视为可用。
        if webView.url != nil {
            tab?.resolveNav()
        } else {
            tab?.resolveNav(throwing: error)
        }
    }
}

/// 弹窗代理：处理 `window.open` / `target="_blank"` 等新建窗口请求。
/// 手势时间戳回传 handler：注入页面的 touchstart/click 监听通过
/// `window.webkit.messageHandlers.miniclawUserGesture` 回传时间，供弹窗拦截判定。
/// tab 强持有本 handler（私有属性），handler 弱引用 tab 防环。
final class BrowserGestureHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        tab?.lastUserGestureAt = Date()
    }
}

/// 「新标签页」接管 handler：注入页面拦截 target=_blank 链接点击与 window.open，
/// 经 `miniclawOpenTab` 消息走我们自己的标签创建逻辑（iOS 18 系统弹窗回调
/// 不触发的架构层对策，见 BrowserTab.installGestureTracking 注释）。
final class BrowserOpenTabHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let tab, let url = message.body as? String, !url.isEmpty else { return }
        // 拦截开关开启时：只放行用户手势（1s 内点击）触发的；自动弹窗丢弃。
        if SettingsStore.shared.settings.browser.blockPopups, !tab.wasRecentUserGesture() {
            AppLogger.shared.info("已拦截自动弹窗（页面接管）：\(url)", category: "Browser", subsystem: "Browser")
            return
        }
        AppLogger.shared.info("弹窗接管:收到页面新标签请求 url=\(url)", category: "Browser", subsystem: "Browser")
        Task { @MainActor in
            _ = BrowserController.shared.openPopupTab(urlString: url)
        }
    }
}

/// 受「通用设置 → 浏览器 → 拦截弹窗」开关控制：开启时直接拦截（返回 nil），
/// 关闭时新建一个标签承载弹窗，并复用其 webView 交由 WebKit 加载。
final class BrowserUIDelegate: NSObject, WKUIDelegate {
    weak var tab: BrowserTab?

    func webView(_ webView: WKWebView,
                 createWebViewWithConfiguration configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 仅拦截真正的新窗口请求（targetFrame == nil）；同框内导航不拦截。
        guard navigationAction.targetFrame == nil else {
            AppLogger.shared.info("弹窗回调:同框导航,忽略(\(navigationAction.request.url?.absoluteString ?? ""))", category: "Browser", subsystem: "Browser")
            return nil
        }
        AppLogger.shared.info("弹窗回调:收到新窗口请求 url=\(navigationAction.request.url?.absoluteString ?? "")", category: "Browser", subsystem: "Browser")

        let block = SettingsStore.shared.settings.browser.blockPopups
        let urlString = navigationAction.request.url?.absoluteString ?? ""
        if block {
            // 手势放行：用户点击（1s 内 touchstart/click）触发的 window.open 放行，
            // 与 iOS Safari「拦截弹窗」行为一致——只拦页面自动弹出的广告弹窗，
            // 不拦用户主动点击的「登录窗口/分享窗口」等。
            if let tab = tab, tab.wasRecentUserGesture() {
                AppLogger.shared.info("弹窗放行（用户手势触发）：\(urlString)", category: "Browser", subsystem: "Browser")
            } else {
                AppLogger.shared.info("已拦截自动弹窗（拦截弹窗开关开启）：\(urlString)", category: "Browser", subsystem: "Browser")
                return nil
            }
        }

        // 允许：在主线程开新标签并复用其 webView，WebKit 会自动把弹窗请求加载进该 webView。
        // 必须把 WebKit 传入的 configuration 原样传给 openPopupTab（见该方法注释）。
        // WKUIDelegate 回调可能在非主线程触发，先用主线程守卫再 assumeIsolated 调用 @MainActor 方法。
        var result: WKWebView?
        let runOnMain = {
            result = MainActor.assumeIsolated {
                BrowserController.shared.openPopupTab(urlString: urlString, configuration: configuration)
            }
        }
        // 全工程唯一允许的 `DispatchQueue.main.sync`：WKUIDelegate 要求**同步**返回 WKWebView?，
        // 无法 async 化。且 WebKit 的 UI delegate 实际总在主线程回调，下面的 sync 分支是纯防御、
        // 正常路径不会走到。其余任何地方一律禁止 main.sync（见 AgentLoopEngine.deliverOnMain 说明）。
        if Thread.isMainThread { runOnMain() }
        else { DispatchQueue.main.sync(execute: runOnMain) }
        return result
    }
}

// MARK: - Array 安全下标

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 下载进度代理

// MARK: - 串行门（浏览器操作串行化）

/// 一个轻量异步串行门：保证同一时刻只有一个调用进入临界区。
/// enter() 在忙时挂起，leave() 唤醒下一个等待者（可同步调用，供 defer 使用）。
/// 内部用 NSLock 保护状态，用于把并发的 browser 工具调用串行化，避免共享状态竞态。
private final class BrowserSerialGate: @unchecked Sendable {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    func enter() async {
        var immediate: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { cont in
            self.lock.lock()
            if self.isBusy {
                self.waiters.append(cont)
            } else {
                self.isBusy = true
                immediate = cont
            }
            self.lock.unlock()
            immediate?.resume()
        }
    }

    func leave() {
        self.lock.lock()
        if let next = self.waiters.first {
            self.waiters.removeFirst()
            self.lock.unlock()
            next.resume()
        } else {
            self.isBusy = false
            self.lock.unlock()
        }
    }
}


// MARK: - 搜索引擎

/// 地址栏搜索词使用的搜索引擎（浏览器设置可切换；仅影响搜索跳转，不影响默认首页）。
enum SearchEngine: String, CaseIterable, Identifiable {
    case bing, sogou, so360, baidu, google, duckduckgo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bing: return "Bing"
        case .sogou: return "搜狗"
        case .so360: return "360 搜索"
        case .baidu: return "百度"
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    /// 搜索 URL 模板（q= 已编码的搜索词）。
    func searchURL(query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .bing: return "https://www.bing.com/search?q=" + encoded
        case .sogou: return "https://www.sogou.com/web?query=" + encoded
        case .so360: return "https://www.so.com/s?q=" + encoded
        case .baidu: return "https://www.baidu.com/s?wd=" + encoded
        case .google: return "https://www.google.com/search?q=" + encoded
        case .duckduckgo: return "https://duckduckgo.com/?q=" + encoded
        }
    }
}
