import Foundation
import SwiftUI
import WebKit
import Combine
import MiniClawKit

// MARK: - 浏览器引擎适配桥(2026-08-10)
// 把移植引擎(MiniClawTabPool + MiniClawBrowserEngine)包装成 BrowserView 依赖的
// 接口形态(BrowserController 同名成员),BrowserView 零改动切到引擎。
// 引擎为移植组件;UI 复用主工程 BrowserView。

@MainActor
final class BrowserEngineAdapter: ObservableObject {
    static let shared = BrowserEngineAdapter()

    /// 引擎标签池(会话级;宿主在进入会话时 setSession;
    /// 2026-08-10:与工具链共用——BrowserController 也经 pool(for:) 取池,UI/工具标签同步)
    /// 2026-08-12:改为动态切换——setSession 后指向会话级池(与工具链同一池),
    /// 未绑定会话时回落 fallbackPool(首页手动浏览器入口)。
    private let fallbackPool = MiniClawTabPool()
    private var sessionPool: MiniClawTabPool?
    private var pool: MiniClawTabPool { sessionPool ?? fallbackPool }
    private var pools: [String: MiniClawTabPool] = [:]
    private let sharedPool = MiniClawTabPool()

    /// 会话级池(工具链共用)
    func pool(for sessionID: UUID?) -> MiniClawTabPool {
        guard let sessionID else { return sharedPool }
        let key = sessionID.uuidString
        if let p = pools[key] { return p }
        let p = MiniClawTabPool()
        p.sessionId = key
        pools[key] = p
        return p
    }

    // MARK: - 状态投影(BrowserView 依赖)

    @Published var isAgentOperating = false
    @Published var activeIndex: Int = 0
    @Published var tabInfos: [TabInfo] = []
    @Published var loadingProgress: Double = 0

    var canGoBack: Bool { pool.activeManager?.canGoBack ?? false }
    var canGoForward: Bool { pool.activeManager?.canGoForward ?? false }
    var activeWebView: WKWebView? { pool.activeManager?.webView }

    struct TabInfo: Identifiable, Equatable {
        let id: Int
        var title: String
        var url: String
        var isLoading: Bool
    }

    struct BrowserHistoryItem: Identifiable {
        let id: UUID
        var url: URL
        var title: String
        var isCurrent: Bool = false
    }

    // MARK: - 会话绑定

    /// 当前绑定的会话（供 `miniclaw://` 资源按会话解析；会话独享目录否则会 miss）。
    private var currentSessionID: UUID?

    func setSession(_ sessionID: UUID?) {
        // 2026-08-12:绑定到会话级池(pool(for:) 与工具链共用同一池,标签同步);
        // 会话池的 sessionId 在 pool(for:) 创建时已设置。
        currentSessionID = sessionID
        sessionPool = sessionID.map { pool(for: $0) }
        pool.ensureTabForUI()
        rebind()
    }

    // MARK: - 取消托管（2026-09-15 体系统一）
    // 旧体系把这套标记放在 BrowserController，而 UI 点「取消托管」走的是本适配器的**空实现**
    // —— 点了没用、且另一份标记永不复位（两套体系各存一份的典型后果）。现标记只此一份。

    /// 用户点击「取消托管」后的接管标记：置位后智能体浏览器调用立即被拒，
    /// 直到浏览器视图重新打开（resetAgentTakeover）复位。
    private(set) var agentControlRevoked = false

    func cancelAgentOperation() {
        isAgentOperating = false
        agentControlRevoked = true
        pool.stopAllLoading()
    }

    /// 浏览器视图重新打开时调用：复位接管标记，智能体可恢复托管。
    func resetAgentTakeover() {
        agentControlRevoked = false
    }

    // MARK: - UA / Cookie / 缓存（体系统一后的唯一实现）

    /// UA 预设：唯一事实来源是**引擎池**的 `MiniClawUAProfile`。
    /// 旧的 `UAProfile`（key "miniClaw.browserUAProfile"）只作用于从不上屏的旧标签，已随旧体系删除。
    var uaProfile: MiniClawUAProfile {
        get { pool.userAgentProfile }
        set { pool.setUserAgentProfile(newValue) }
    }
    /// 当前 UA 字符串（设置页预览用）。
    var currentUAString: String { pool.resolvedUserAgentString() ?? "" }
    /// 把当前 UA 预设应用到池内所有标签（新建标签自动带上）。
    /// 注意：引擎 `setUserAgent` 会**重建** WKWebView，故改完必须主动通知 SwiftUI 重取
    /// `activeWebView`（否则新实例要等下一个 @Published 事件才挂上，中间可能空白一帧）。
    func applyUAProfileToAllTabs() {
        pool.applyUserAgentToAllTabs()
        objectWillChange.send()
    }

    /// Cookie 存储：引擎 WebView 用的是**默认** dataStore，设置页必须读同一个，
    /// 否则就是「显示一套 cookie、实际用另一套」。
    var cookieStore: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    /// 统一清理「浏览器缓存」：WebKit 磁盘/内存/离线缓存 + URLCache + 共享区 browser/ +
    /// 系统 Caches/MiniClaw/。（会话级 browser/ 属「会话缓存」，不在此列。）
    func clearBrowserCaches() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache],
            modifiedSince: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        let sharedBrowser = FileSystemManager.shared.miniClawRoot.appendingPathComponent("browser")
        if let items = try? FileManager.default.contentsOfDirectory(at: sharedBrowser, includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        if let cachesURL = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("MiniClaw") {
            if let items = try? FileManager.default.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: nil) {
                for item in items { try? FileManager.default.removeItem(at: item) }
            }
        }
    }

    /// 销毁会话的浏览器数据（替代原 `BrowserContextManager.destroy`）：关闭该会话池的全部标签并移除池。
    func destroySession(_ sessionID: UUID) {
        let key = sessionID.uuidString
        guard let target = pools.removeValue(forKey: key) else { return }
        for id in target.tabs.map(\.id) { _ = target.closeTab(id: id) }
        if sessionPool === target { sessionPool = nil; currentSessionID = nil }
        // 销毁的若是用户正在看的池，UI 会回落到 fallbackPool —— 必须保证回落池有标签，
        // 否则 `activeWebView` 为 nil，内容区直接空白（与首页空浏览器的成因同源）。
        pool.ensureTabForUI()
        rebind()
    }

    // MARK: - 智能体工具链入口（体系统一后的唯一路径）

    /// 浏览器操作串行门：智能体工具调用会并发（一次回复里同时开两个标签页），
    /// 而池/选中标签是共享可变状态，并行写会互相覆盖（导航回调解析错、续体不 resume → 一直转圈）。
    private let serialGate = BrowserSerialGate()

    /// 智能体浏览器工具（`BrowserTool`）的唯一入口。
    ///
    /// [2026-09-15 体系统一] **去掉了「引擎失败回退旧实现」分支**：旧实现操作的是另一套
    /// 从不上屏的标签（旧 `BrowserContext.tabs`），回退只会让智能体在错误的标签上拿到结果；
    /// 引擎 action 全集（`MiniClawBrowserAction`，22 个）与工具侧支持的 action 完全一致，无缺口。
    func run(action: String, paramsData: Data, tabIndex: Int?, tabID: String?, sessionID: UUID?) async throws -> String {
        // 用户已取消托管（点「取消托管」按钮）：智能体的浏览器操作立即被拒，工具把错误文本给模型。
        guard !agentControlRevoked else {
            throw ToolError.executionFailed(String(localized: "err_browser_user_took_over"))
        }
        await serialGate.enter()
        defer { serialGate.leave() }
        // 取消可能在排队期间发生：进入临界区后复查一次，防「取消时已排队、随后才轮到」。
        guard !agentControlRevoked else {
            throw ToolError.executionFailed(String(localized: "err_browser_user_took_over"))
        }
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        // 顶层 tab_index/tab_id 并入引擎参数（否则引擎只读 params 子对象，顶层寻址丢失 → 截错标签）。
        var engineParams = params
        if engineParams["tab_id"] == nil, let tabID, let i = Int(tabID) { engineParams["tab_id"] = i }
        if engineParams["tab_index"] == nil, let tabIndex { engineParams["tab_index"] = tabIndex }
        guard let input = BrowserActionHelpers.engineInput(action: action, params: engineParams) else {
            throw ToolError.invalidParameters(String(localized: "err_browser_unsupported_action"))
        }
        let result = try await pool(for: sessionID).execute(action: input, singleTab: false)
        // 引擎截图/fetch 产物落盘到会话 browser/ 目录，返回 miniclaw://browser/<file> 链接。
        if input.action == .screenshot, let path = result.imageFilePath {
            return try await persistEngineArtifact(filePath: path, sessionID: sessionID, fallbackText: result.text)
        }
        if input.action == .fetch, let data = result.fetchedFileData {
            let name = result.fetchedFileName ?? "fetch_\(Int(Date().timeIntervalSince1970 * 1000))"
            return try await persistEngineArtifact(data: data, preferredName: name, sessionID: sessionID, fallbackText: result.text)
        }
        return result.text
    }

    private func persistEngineArtifact(filePath: String, sessionID: UUID?, fallbackText: String) async throws -> String {
        let name = URL(fileURLWithPath: filePath).lastPathComponent
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return fallbackText + String(format: String(localized: "browser_artifact_read_failed"), filePath)
        }
        return try await persistEngineArtifact(data: data, preferredName: name, sessionID: sessionID, fallbackText: fallbackText)
    }

    private func persistEngineArtifact(data: Data, preferredName: String, sessionID: UUID?, fallbackText: String) async throws -> String {
        let safeName = preferredName.replacingOccurrences(of: "/", with: "_")
        do {
            try FileSystemManager.shared.writeAutomaticData(at: "/var/MiniClaw/browser/\(safeName)", data: data,
                                                            actor: .browserAutomatic, sessionID: sessionID)
            return fallbackText + String(format: String(localized: "browser_artifact_saved"), safeName, safeName)
        } catch {
            return fallbackText + String(format: String(localized: "browser_artifact_save_failed"), error.localizedDescription)
        }
    }

    /// 会话感知的 `miniclaw://` 资源解析（截图/下载预览用）：带当前有效会话解析，
    /// 否则会话独享目录（browser/attachments 等）会解析到扁平目录而 miss，
    /// 表现为「全页截图并分享」不弹分享页。
    /// [2026-09-15 体系统一] 迁移时一度退化成 `return raw`（原样返回）——对真实文件路径
    /// 侥幸可用，但对 `miniclaw://…` 链接必然解析失败，已恢复旧实现的会话感知解析。
    func resolveResourceURL(_ raw: String) -> String? {
        FileSystemManager.shared.resolveMiniClawResourceURL(raw, sessionID: currentSessionID)?.path
    }

    // MARK: - UI 动作(转发引擎)

    @discardableResult
    func uiAddTab(urlString: String? = nil) -> Bool {
        let result = pool.newTab(url: urlString)
        rebind()
        return result.success
    }

    func uiCloseTab(index: Int) {
        guard index < pool.tabs.count else { return }
        _ = pool.closeTab(id: pool.tabs[index].id)
        rebind()
    }

    func uiSelectTab(index: Int) {
        guard index < pool.tabs.count else { return }
        pool.selectedTabId = pool.tabs[index].id
        rebind()
    }

    /// [2026-09-15 治本] 确保 UI 所在池已就绪：建 0 号标签（若池从未建过）+ 修越界选择。
    /// 首页手动浏览器原先只调旧控制器 `BrowserController.setManualSession()`，而 UI 实际用的是
    /// 本适配器 —— 适配器的池从未 `ensureTabForUI()`，池内零标签 ⇒ `activeManager` 恒 nil
    /// ⇒ 内容区永远空白（ControllerWebView 的 guard 直接 return）+ 地址栏全部静默失效。
    func ensureUIPoolReady() {
        pool.ensureTabForUI()
        rebind()
    }

    func uiNavigate(urlString: String) {
        // [2026-09-15 治本] 原实现 `pool.activeManager?.loadURL(urlString)` 是**可选链静默失败**：
        // selectedTabId 未命中任何标签（池从未建过标签 / 标签被关后选择未回落）时
        // activeManager 为 nil ⇒ 点「前往」零日志、零报错、零反应。
        // 修法：① 先修选择（无标签则补建）；② 输入按策略归一化（中文/无点号 ⇒ 走搜索）；
        // ③ 仍拿不到标签则**报错可见**，不再静默。
        if pool.repairSelectionIfNeeded() { rebind() }
        guard let manager = pool.activeManager else {
            // 兜底失败（全局标签上限且无法腾挪）：必须可见，绝不再静默。
            AppLogger.shared.error(
                "[BrowserUse] uiNavigate 无可用标签: tabs=\(pool.tabs.count) selected=\(pool.selectedTabId) url=\(urlString)",
                category: "BrowserUse")
            return
        }
        manager.loadURL(normalizeAddress(urlString))
        rebind()
    }

    /// 地址栏输入归一化：与 智能体工具侧（`BrowserTool` 的搜索解析）**共用 `SearchEnginePolicy`**。
    /// - 显式 `http(s)://` / `data:` ⇒ 原样；
    /// - 含非 ASCII（中文等）或含空格 ⇒ 当搜索词；
    /// - 含 `.` 且纯 ASCII 无空格 ⇒ 当域名，补 `https://`；
    /// - 其余（无点号纯 ASCII 词）⇒ 当搜索词。
    /// 修的是「输入『岳麓山索道价格』被拼成 `https://岳麓山索道价格` ⇒ punycode ⇒ DNS 失败 ⇒ 页面空白」。
    private func normalizeAddress(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") { return s }
        if s.contains(where: { !$0.isASCII }) || s.contains(" ") { return searchURL(for: s) }
        if s.contains(".") { return "https://" + s }
        return searchURL(for: s)
    }

    private func searchURL(for query: String) -> String {
        SearchEnginePolicy
            .preferred(rawSetting: SettingsStore.shared.settings.browser.searchEngine)
            .searchURL(query: query)
    }

    func uiReload() {
        if pool.repairSelectionIfNeeded() { rebind() }
        pool.activeManager?.reload()
    }
    func uiBack() {
        if pool.repairSelectionIfNeeded() { rebind() }
        pool.activeManager?.goBack()
    }
    func uiForward() {
        if pool.repairSelectionIfNeeded() { rebind() }
        pool.activeManager?.goForward()
    }

    /// 持久化浏览历史（跨启动）。
    /// [2026-09-15 体系统一] 原实现返回 `[]`（历史面板恒空）。历史**只此一套存储**：
    /// `MiniClawHistoryStore`，由引擎在导航完成（didFinish）时写入 —— UI 与智能体导航都会记，
    /// 不存在「记了一套用户看不到的历史」或「只在 UI 重建订阅时补记导致漏记」的问题。
    /// （旧的 `BrowserHistoryStore` 已随旧体系删除。）
    func uiHistoryItems() -> [BrowserHistoryItem] {
        MiniClawHistoryStore.shared.entries.map { entry in
            BrowserHistoryItem(id: entry.id,
                               url: URL(string: entry.url) ?? URL(string: "about:blank")!,
                               title: entry.title.isEmpty ? entry.url : entry.title)
        }
    }
    func uiGoToHistory(url: URL) {
        if pool.repairSelectionIfNeeded() { rebind() }
        pool.activeManager?.loadURL(url.absoluteString)
    }
    /// 清空全部浏览历史（落盘同步清空）。
    func uiClearHistory() {
        MiniClawHistoryStore.shared.clearAll()
    }

    func uiScreenshot(fullPage: Bool = false) async -> String? {
        guard let img = await uiSnapshot(index: activeIndex) else { return nil }
        guard let data = img.jpegData(compressionQuality: 0.85) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-\(UUID().uuidString.prefix(8)).jpg")
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    func uiSnapshot(index: Int) async -> UIImage? {
        guard index < pool.tabs.count else { return nil }
        let webView = pool.tabs[index].manager.webView
        return await snapshot(of: webView)
    }

    /// 拆出独立函数(2026-08-10:内联 withCheckedContinuation 触发编译器 failed-diagnostic)
    private func snapshot(of webView: WKWebView) async -> UIImage? {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// 把非活跃标签的 webView 移回**离屏宿主**（`ControllerWebView` 切标签时调用）。
    ///
    /// ⚠️ [2026-09-15 体系统一] 迁移时这里一度写成空实现，而 UI 依赖它把旧 webView 移出内容区
    /// —— 后果是切标签时旧 webView 残留在顶层（**看到上一个标签的页面**）且逐次堆叠。
    /// 宿主做法沿用旧体系已验证路径：**同在 keyWindow 的屏幕外坐标 + frame 布局**：
    /// - 不用 `isHidden`：隐藏的 WKWebView 无法 `takeSnapshot`（标签概览缩略图空白）；
    /// - 不 `removeFromSuperview` 后丢弃：iOS 18 离开 window 再回来会损坏触摸交互；
    /// - 用 frame 布局（而非无约束的 autolayout）：无约束会让 bounds 恒 0x0、缩略图 0x0。
    func rehost(_ webView: WKWebView) {
        if webView.superview != nil { webView.removeFromSuperview() }
        guard let host = currentHost() else { return }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = CGRect(x: -10000, y: 0, width: host.bounds.width, height: host.bounds.height)
        host.addSubview(webView)
    }

    /// 离屏宿主：当前前台场景的 keyWindow（webView 留在同一 window 内、仅移出屏幕，
    /// 既保持可渲染/可截图，又不触发「离开 window 再回来交互损坏」）。
    private func currentHost() -> UIView? {
        let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    }

    // MARK: - 引擎状态绑定(KVO/Combine → @Published)

    private var subs: [AnyCancellable] = []

    private func rebind() {
        subs.removeAll()
        // 标签表投影 + 智能体托管状态。
        // 2026-08-12 修复:isAgentOperating 原来错误绑定 pool.$isBrowserLoading(页面加载状态),
        // 导致用户自己导航时也显示"AI 托管"遮罩。正确语义=池内是否有 tab 被 agent 占用
        // (isAgentBrowsing,含 15s grace window)。
        pool.$tabs
            .combineLatest(pool.$selectedTabId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs, selected in
                guard let self else { return }
                self.tabInfos = tabs.map { tab in
                    TabInfo(id: tab.id,
                            title: tab.manager.pageTitle,
                            url: tab.manager.currentURL,
                            isLoading: tab.manager.isLoading)
                }
                self.activeIndex = tabs.firstIndex(where: { $0.id == selected }) ?? 0
                // 2026-09-02 唐唐：AI 完成即脱手——UI 指示排除 15s 宽限期
                //（isAgentBrowsing 含宽限，是 tab 预留语义而非操作中语义）。
                self.isAgentOperating = self.pool.isAgentActivelyOperating
            }
            .store(in: &subs)
        // 2026-09-02：「AI 正在操作」指示改由动作执行中状态直接驱动
        //（排除 15s 宽限期；动作开始即亮、结束即灭，不延迟不粘滞）。
        pool.$isAgentActivelyOperating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isAgentOperating = active
            }
            .store(in: &subs)
        // 浏览历史不再由 UI 侧订阅补记：统一由引擎 didFinish 写入 MiniClawHistoryStore
        // （见 uiHistoryItems 注释），避免「rebind 才建订阅 + dropFirst 吃掉当前 URL」的漏记。

        // 活跃 manager 状态
        // [2026-09-09 并发违规治理] 以下 5 个 sink 缺 .receive(on:)：MiniClawBrowserEngine
        // 的 isLoading/currentURL/pageTitle 有写入点在 WKWebView 回调 / Task 闭包里，
        // 非 main 线程 emit 会触发 "Publishing changes from background threads"。
        if let manager = pool.activeManager {
            manager.$canGoBack
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
            manager.$canGoForward
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
            manager.$isLoading
                .receive(on: DispatchQueue.main)
                .sink { [weak self] loading in
                    guard let self else { return }
                    if loading {
                        self.loadingProgress = 0.1
                    } else {
                        self.loadingProgress = 1.0
                    }
                    self.objectWillChange.send()
                }.store(in: &subs)
            manager.$pageTitle
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rebindTabs() }.store(in: &subs)
            manager.$currentURL
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rebindTabs() }.store(in: &subs)
        }
        objectWillChange.send()
    }

    private func rebindTabs() {
        tabInfos = pool.tabs.map { tab in
            TabInfo(id: tab.id,
                    title: tab.manager.pageTitle,
                    url: tab.manager.currentURL,
                    isLoading: tab.manager.isLoading)
        }
    }
}

// MARK: - 串行门（浏览器操作串行化）
// [2026-09-15 体系统一] 随工具链入口 run() 一起从 BrowserController 迁到此处（旧体系已删）。
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


