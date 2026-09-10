import Foundation
import UIKit
import WebKit
import Combine
import os.log

@MainActor
public final class MiniClawTabPoolRegistry {
    public static let shared = MiniClawTabPoolRegistry()

    public static let globalTabCap = 8

    private struct WeakPool {
        weak var pool: MiniClawTabPool?
    }
    private var pools: [ObjectIdentifier: WeakPool] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MiniClawTabPoolRegistry.shared.handleMemoryWarning()
            }
        }
        installLivenessProbe()
    }

    public func register(_ pool: MiniClawTabPool) {
        pools[ObjectIdentifier(pool)] = WeakPool(pool: pool)
    }

    public func unregister(_ pool: MiniClawTabPool) {
        pools.removeValue(forKey: ObjectIdentifier(pool))
    }

    public func totalLiveTabs() -> Int {
        compactPools()
        return pools.values.reduce(0) { $0+($1.pool?.tabs.count ?? 0) }
    }

    @discardableResult
    public func requestSlot(for requester: MiniClawTabPool) -> Bool {
        compactPools()
        if totalLiveTabs()<Self.globalTabCap { return true }

        let requesterId = ObjectIdentifier(requester)

        var idleVictim: (pool: MiniClawTabPool,tabId: Int,idle: TimeInterval)? = nil
        var busyVictim: (pool: MiniClawTabPool,tabId: Int,idle: TimeInterval)? = nil
        let now = Date()
        for (id,weak) in pools where id != requesterId {
            guard let pool = weak.pool else { continue }
            for tab in pool.tabs {
                let idle = now.timeIntervalSince(tab.lastActivityDate)
                if !tab.inUse {
                    if idleVictim == nil || idle>idleVictim!.idle {
                        idleVictim = (pool,tab.id,idle)
                    }
                } else {
                    if busyVictim == nil || idle>busyVictim!.idle {
                        busyVictim = (pool,tab.id,idle)
                    }
                }
            }
        }
        if let v = idleVictim {
            registryLogger.info("Global cap (\(Self.globalTabCap)) reached — evicting idle tab \(v.tabId) from sibling pool (idle \(String(format: "%.0f", v.idle))s) for requester")
            v.pool.evictTabForRegistry(id: v.tabId)
            return true
        }
        if let v = busyVictim {
            registryLogger.info("Global cap (\(Self.globalTabCap)) reached and no idle siblings — preempting in-use tab \(v.tabId) (idle \(String(format: "%.0f", v.idle))s) for requester")
            v.pool.preemptTabForRegistry(id: v.tabId)
            return true
        }
        registryLogger.info("Global cap (\(Self.globalTabCap)) reached and no sibling tabs to evict — denying slot")
        return false
    }

    private func handleMemoryWarning() {
        compactPools()
        var evicted = 0
        for weak in pools.values {
            guard let pool = weak.pool else { continue }
            evicted += pool.evictAllIdleForMemoryWarning()
        }
        if evicted>0 {
            registryLogger.info("Memory warning — evicted \(evicted) idle tab(s) across \(self.pools.count) pool(s)")
        }
    }

    public struct TabSnapshot {
        let sessionId: String
        let tabId: Int
        let url: String
        let title: String
        let isLoading: Bool
        let inUse: Bool
        let lastActivityAgo: TimeInterval
    }

    public func allTabSnapshots() -> [TabSnapshot] {
        compactPools()
        let now = Date()
        var result: [TabSnapshot] = []
        for weak in pools.values {
            guard let pool = weak.pool else { continue }
            let sid = String((pool.sessionId ?? "unknown").prefix(8))
            for tab in pool.tabs {
                result.append(TabSnapshot(
                    sessionId: sid,
                    tabId: tab.id,
                    url: String(tab.manager.currentURL.prefix(100)),
                    title: String(tab.manager.pageTitle.prefix(100)),
                    isLoading: tab.manager.isLoading,
                    inUse: tab.inUse,
                    lastActivityAgo: now.timeIntervalSince(tab.lastActivityDate)
                ))
            }
        }
        return result
    }

    private func compactPools() {
        pools = pools.filter { $0.value.pool != nil }
    }

    /// [BrowserToolDiag] Teach MiniClawResourceMonitor how to tell whether a tab's
    ///
    private func installLivenessProbe() {
        MiniClawResourceMonitor.shared.livenessProbe = { [weak self] tabId in
            guard let self else { return nil }
            self.compactPools()
            for weak in self.pools.values {
                guard let pool = weak.pool,
                      let tab = pool.tabs.first(where: { $0.id == tabId }) else { continue }
                let webView = tab.manager.webView
                return MiniClawResourceMonitor.WebContentLiveness(
                    hasURL: webView.url != nil,
                    hasTitle: !(webView.title ?? "").isEmpty
                )
            }
            return nil
        }
    }
}

@MainActor
public final class MiniClawTabPool: ObservableObject {
    public static let maxTabs = 3

    #if DEBUG
    public static weak var debugInstance: MiniClawTabPool?
    #endif

    public static let idleTimeout: TimeInterval = 15*60 // 15 minutes

    private static let idleCheckInterval: TimeInterval = 60

    public struct Tab: Identifiable {
        public let id: Int
        public let manager: MiniClawBrowserEngine
        ///
        public var inUse: Bool = false
        public var graceExpiryTask: Task<Void,Never>? = nil
        public var lastActivityDate: Date = Date()
    }

    public static let postActionGraceSeconds: TimeInterval = 15

    private var savedURLs: [Int: String] = [:]

    private var preemptedTabIds: Set<Int> = []

    private var tabSerialChains: [Int: (token: UInt64,task: Task<Void,Never>)] = [:]
    private var nextSerialToken: UInt64 = 0

    private static let serialWaitTimeout: TimeInterval = 60

    @Published public var tabs: [Tab] = []
    @Published public var selectedTabId: Int = 0 {
        didSet { rebindLoadingObservation() }
    }
    @Published public var userAgentProfile: MiniClawUAProfile = .mobileSafari
    @Published public var customUserAgentString: String = ""

    @Published public var customViewportWidth: Int = 0
    @Published public var customViewportHeight: Int = 0

    @Published private(set) var sessionViewportWidth: Int = 0
    @Published private(set) var sessionViewportHeight: Int = 0

    private static let uaProfileKey = "BrowserUserAgentProfile"
    private static let uaCustomStringKey = "BrowserCustomUserAgentString"

    private static let viewportWidthKey = "BrowserCustomViewportWidth"
    private static let viewportHeightKey = "BrowserCustomViewportHeight"

    /// Session ID for disk persistence. Set by MessageListModel.
    public var sessionId: String? {
        didSet {
            if let sessionId,sessionId != oldValue {
                loadPersistedURLs()
            }
        }
    }

    private nonisolated(unsafe) var idleTimer: Timer?
    private var loadingObservation: AnyCancellable?

    @Published public var isBrowserLoading: Bool = false

    /// ⚠️ 含完成后 15s 宽限期（inUse 的 tab 预留语义）——**不可直接用作 UI 的
    /// 「AI 正在操作」指示**（唐唐 2026-09-02：AI 拿到结果就应脱手，宽限期内
    /// 不得显示 AI 操作覆盖层）。UI 指示用 `isAgentActivelyOperating`。
    public var isAgentBrowsing: Bool {
        tabs.contains { $0.inUse }
    }

    /// 当前实际执行中的 browser 动作数（不含 15s 宽限期）。
    private var activeActionCount = 0
    /// 「AI 正在操作」的 UI 指示语义：有动作**正在实际执行**（排除宽限期）。
    /// 浏览器覆盖层（agentOperatingOverlay）应绑定此状态。
    @Published public var isAgentActivelyOperating = false

    public var activeManager: MiniClawBrowserEngine? {
        tabs.first { $0.id == selectedTabId }?.manager
    }

    ///
    public var hasLoadingTab: Bool {
        tabs.contains { $0.manager.isLoading }
    }

    ///
    @discardableResult
    public func stopAllLoading() -> Int {
        var stopped = 0
        for tab in tabs where tab.manager.isLoading {
            tab.manager.stopLoading()
            stopped += 1
        }
        return stopped
    }

    public init() {
        if let raw = UserDefaults.standard.string(forKey: Self.uaProfileKey),
           let profile = MiniClawUAProfile(rawValue: raw) {
            userAgentProfile = profile
        }
        if let custom = UserDefaults.standard.string(forKey: Self.uaCustomStringKey) {
            customUserAgentString = custom
        }
        customViewportWidth = UserDefaults.standard.integer(forKey: Self.viewportWidthKey)
        customViewportHeight = UserDefaults.standard.integer(forKey: Self.viewportHeightKey)
        startIdleTimer()
        MiniClawTabPoolRegistry.shared.register(self)
        #if DEBUG
        Self.debugInstance = self
        #endif
    }

    deinit {
        idleTimer?.invalidate()
    }

    private func rebindLoadingObservation() {
        loadingObservation?.cancel()
        guard let mgr = activeManager else {
            isBrowserLoading = false
            return
        }
        isBrowserLoading = mgr.isLoading
        loadingObservation = mgr.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                self?.isBrowserLoading = loading
            }
    }

    public func acquireTab() -> Int {
        if let idx = tabs.firstIndex(where: { $0.id == 0 }) {
            tabs[idx].inUse = true
            tabs[idx].lastActivityDate = Date()
            return 0
        }
        MiniClawTabPoolRegistry.shared.requestSlot(for: self)
        let manager = makeManager()
        let tab = Tab(id: 0,manager: manager,inUse: true)
        tabs.append(tab)
        selectedTabId = 0
        restoreSavedURL(for: 0,manager: manager)
        logger.info("Created tab 0")
        return 0
    }

    public func ensureTabForUI() {
        if !tabs.contains(where: { $0.id == 0 }) {
            guard MiniClawTabPoolRegistry.shared.requestSlot(for: self) else {
                logger.info("Skipping UI prefetch tab — global cap reached and no idle siblings to evict")
                return
            }
            let manager = makeManager()
            let tab = Tab(id: 0,manager: manager,inUse: false)
            tabs.append(tab)
            selectedTabId = 0
            restoreSavedURL(for: 0,manager: manager)
            logger.info("Created tab 0 for UI")
        }
    }

    public func newTab(url: String? = nil) -> MiniClawActionResult {
        guard tabs.count<Self.maxTabs else {
            return .error("Maximum of \(Self.maxTabs) tabs reached. Close a tab first with close_tab.")
        }
        guard MiniClawTabPoolRegistry.shared.requestSlot(for: self) else {
            return .error("Browser memory cap reached across all sessions (\(MiniClawTabPoolRegistry.globalTabCap) tabs). Close a tab here or in another session first.")
        }
        let nextId = (tabs.map(\.id).max() ?? -1)+1
        let manager = makeManager()
        let tab = Tab(id: nextId,manager: manager,inUse: true)
        tabs.append(tab)
        selectedTabId = nextId
        //
        let trimmedUrl = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let loadUrl = trimmedUrl,!loadUrl.isEmpty {
            manager.loadURL(loadUrl)
        } else {
            restoreSavedURL(for: nextId,manager: manager)
        }
        logger.info("Created new tab \(nextId), total: \(self.tabs.count)")
        let urlSuffix = (trimmedUrl?.isEmpty == false) ? " at \(trimmedUrl!)" : ""
        return MiniClawActionResult(
            text: "Opened new tab \(nextId)\(urlSuffix). You now have \(tabs.count) tab(s). Use tab_id: \(nextId) to target this tab.",
            tabId: nextId)
    }

    public func openURL(_ url: URL) {
        if tabs.count<Self.maxTabs {
            _ = newTab()
            activeManager?.loadURL(url.absoluteString)
        } else {
            touchActivity()
            activeManager?.loadURL(url.absoluteString)
        }
    }

    @discardableResult
    public func openWithConfiguration(_ configuration: WKWebViewConfiguration,url: URL?) -> WKWebView? {
        guard tabs.count<Self.maxTabs else {
            if let url {
                activeManager?.loadURL(url.absoluteString)
            }
            return nil
        }
        guard MiniClawTabPoolRegistry.shared.requestSlot(for: self) else {
            logger.info("Suppressing window.open popup — global tab cap reached")
            if let url {
                activeManager?.loadURL(url.absoluteString)
            }
            return nil
        }
        let nextId = (tabs.map(\.id).max() ?? -1)+1
        let ua = resolvedUserAgentString()
        let vp = resolvedViewportSize()
        let manager = MiniClawBrowserEngine(profile: userAgentProfile,customString: ua,
                                        configuration: configuration,
                                        viewportWidth: vp.width,viewportHeight: vp.height)
        wireManager(manager)
        let tab = Tab(id: nextId,manager: manager,inUse: false)
        tabs.append(tab)
        selectedTabId = nextId
        logger.info("Created popup tab \(nextId) via window.open, total: \(self.tabs.count)")
        return manager.webView
    }

    public func closeWebView(_ webView: WKWebView) {
        if let tab = tabs.first(where: { $0.manager.webView === webView }) {
            _ = closeTab(id: tab.id)
        }
    }

    public func closeTab(id: Int) -> MiniClawActionResult {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else {
            return .error("No tab with id \(id)")
        }
        savedURLs.removeValue(forKey: id)
        tabs.remove(at: idx)
        logger.info("Closed tab \(id), remaining: \(self.tabs.count)")

        if selectedTabId == id {
            selectedTabId = tabs.first?.id ?? 0
        }

        persistURLs()
        return MiniClawActionResult(text: "Closed tab \(id). \(tabs.count) tab(s) remaining.")
    }

    public func listTabs() -> MiniClawActionResult {
        if tabs.isEmpty {
            return MiniClawActionResult(text: "No tabs open.")
        }
        var lines: [String] = ["Open tabs:"]
        for tab in tabs {
            let url = tab.manager.currentURL.isEmpty ? "(blank)" : tab.manager.currentURL
            let title = tab.manager.pageTitle.isEmpty ? "(untitled)" : tab.manager.pageTitle
            let marker = tab.id == selectedTabId ? " *" : ""
            lines.append(" Tab \(tab.id): \(title) — \(url)\(marker)")
        }
        return MiniClawActionResult(text: lines.joined(separator: "\n"))
    }

    ///
    private func acquireSerialSlot(tabId: Int) async -> (() -> Void)? {
        let predecessor = tabSerialChains[tabId]?.task

        // triage).
        //
        let token = nextSerialToken
        nextSerialToken &+= 1

        final class GateBox: @unchecked Sendable {
            private var lock = os_unfair_lock()
            private var resume: (() -> Void)?
            private var preFired = false

            func signal() {
                os_unfair_lock_lock(&lock)
                if let r = resume {
                    resume = nil
                    os_unfair_lock_unlock(&lock)
                    r()
                } else {
                    preFired = true
                    os_unfair_lock_unlock(&lock)
                }
            }

            func install(_ r: @escaping () -> Void) {
                os_unfair_lock_lock(&lock)
                if preFired {
                    os_unfair_lock_unlock(&lock)
                    r()
                } else {
                    resume = r
                    os_unfair_lock_unlock(&lock)
                }
            }
        }
        let gateBox = GateBox()
        let gate = Task<Void,Never> {
            await withCheckedContinuation { (cont: CheckedContinuation<Void,Never>) in
                gateBox.install { cont.resume() }
            }
        }
        tabSerialChains[tabId] = (token,gate)

        var released = false
        let release: () -> Void = { [weak self] in
            guard !released else { return }
            released = true
            gateBox.signal()
            Task { @MainActor in
                guard let self else { return }
                if self.tabSerialChains[tabId]?.token == token {
                    self.tabSerialChains.removeValue(forKey: tabId)
                }
            }
        }

        guard let predecessor else {
            return release
        }

        let waited = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await predecessor.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.serialWaitTimeout*1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if waited {
            return release
        } else {
            logger.warning("[SerialDiag] tab \(tabId): serial-wait timed out after \(Int(Self.serialWaitTimeout))s — releasing own gate, returning open-new-tab guidance")
            release()
            return nil
        }
    }

    ///
    /// grace window. This is the `miniclaw-browser-use` CLI path: a human/script
    ///
    public func execute(
        action input: MiniClawActionInput,
        singleTab: Bool = false
    ) async throws -> MiniClawActionResult {
        let diagId = MiniClawResourceMonitor.shared.actionWillStart(
            action: input.action.rawValue,
            url: input.url,
            tabId: input.tabId
        )
        // 动作执行中计数（排除 15s 宽限期——宽限只是 tab 预留，不算「AI 正在操作」）。
        activeActionCount += 1
        isAgentActivelyOperating = true
        defer {
            activeActionCount -= 1
            if activeActionCount <= 0 { isAgentActivelyOperating = false }
        }
        do {
            let result = try await executeInner(action: input,singleTab: singleTab)
            MiniClawResourceMonitor.shared.actionDidFinish(
                diagId,
                success: result.success,
                error: result.success ? nil : result.text
            )
            return result
        } catch {
            MiniClawResourceMonitor.shared.actionDidFinish(
                diagId,
                success: false,
                error: "throw: \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func executeInner(
        action input: MiniClawActionInput,
        singleTab: Bool
    ) async throws -> MiniClawActionResult {
        let poolStart = CFAbsoluteTimeGetCurrent()
        // [PoolTiming] enter 逐条日志已删（每次工具调用两条、纯时序陈述）；
        // 耗时汇总由函数尾部的 elapsed 日志承载。

        switch input.action {
        case .newTab:
            // already does this (MiniClawTabPool.kt NEW_TAB branch).
            //
            return newTab(url: input.url)
        case .closeTab:
            let tabId = input.tabId ?? selectedTabId
            return closeTab(id: tabId)
        case .listTabs:
            return listTabs()
        default:
            break
        }

        //
        let explicitTabId = input.tabId != nil
        // Only *open-page*
        let isOpenPageAction = (input.action == .navigate)
        let targetId: Int
        // still shows its old site.
        var reusedTabSwitch: (tabId: Int,oldURL: String)? = nil
        if let requestedId = input.tabId {
            if tabs.contains(where: { $0.id == requestedId }) {
                targetId = requestedId
            } else {
                // 2026-08-12:显式 tab_id 已给出但池中不存在 → 明确报错,不再静默回退激活标签
                // (此前回退会让 screenshot/get_readable 截到别的 tab,AI 误以为是目标页)。
                return .error("No tab with id \(requestedId). Run list_tabs to get the current tab ids.")
            }
        } else if !isOpenPageAction {
            let probe = input.tabId ?? selectedTabId
            if preemptedTabIds.remove(probe) != nil {
                return .error("Browser tab \(probe) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
            }
            targetId = tabs.contains(where: { $0.id == selectedTabId })
                ? selectedTabId
                : ensureDefaultTab()
        } else {
            let probe = input.tabId ?? 0
            if preemptedTabIds.remove(probe) != nil {
                return .error("Browser tab \(probe) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
            }
            // Implicit-tab content action: per spec
            // 1. Pick any existing tab whose `inUse=false` (prefers reuse).
            // 2. Otherwise, if capacity remains, fan out to a fresh tab.
            // 3. Otherwise, fall back to ensureDefaultTab() — at full
            // capacity with everything busy, the agent will hit the
            // serial-slot wait below or return a busy hint.
            if singleTab {
                targetId = tabs.contains(where: { $0.id == selectedTabId })
                    ? selectedTabId
                    : ensureDefaultTab()
            } else if !explicitTabId {
                if let freeTab = tabs.first(where: { !$0.inUse }) {
                    targetId = freeTab.id
                    // We're about to REUSE an
                    let oldURL = freeTab.manager.currentURL
                    if !oldURL.isEmpty, oldURL != "about:blank",
                       let newURL = input.url,oldURL != newURL {
                        reusedTabSwitch = (tabId: freeTab.id,oldURL: oldURL)
                    }
                } else if tabs.count<Self.maxTabs,
                          MiniClawTabPoolRegistry.shared.requestSlot(for: self) {
                    let nextId = (tabs.map(\.id).max() ?? -1)+1
                    let manager = makeManager()
                    tabs.append(Tab(id: nextId,manager: manager,inUse: true))
                    restoreSavedURL(for: nextId,manager: manager)
                    logger.info("[SerialDiag] implicit-tab action — all existing tabs inUse (action/grace), fanned out to fresh tab \(nextId)")
                    targetId = nextId
                } else {
                    targetId = ensureDefaultTab()
                }
            } else {
                targetId = ensureDefaultTab()
            }
        }
        if preemptedTabIds.remove(targetId) != nil {
            return .error("Browser tab \(targetId) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
        }
        guard let idx = tabs.firstIndex(where: { $0.id == targetId }) else {
            return .error("No tab with id \(targetId). Use list_tabs to see open tabs.")
        }

        let tabResolvedMs = Int((CFAbsoluteTimeGetCurrent()-poolStart)*1000)
        logger.info("[PoolTiming] tab_resolved elapsed=\(tabResolvedMs)ms targetId=\(targetId) action=\(input.action.rawValue)")

        tabs[idx].inUse = true
        tabs[idx].graceExpiryTask?.cancel()
        tabs[idx].graceExpiryTask = nil
        tabs[idx].lastActivityDate = Date()
        selectedTabId = targetId
        defer {
            if let i = tabs.firstIndex(where: { $0.id == targetId }) {
                tabs[i].lastActivityDate = Date()
                armPostActionGrace(tabId: targetId)
            }
        }

        if input.action == .setUserAgent {
            let profile = input.userAgent ?? .mobileSafari
            setUserAgentProfile(profile,persist: false)
            let vp = profile.viewportSize
            return MiniClawActionResult(text: "Switched to \(profile.rawValue) (\(vp.width)x\(vp.height))")
        }

        if input.action == .setViewport {
            if input.viewportReset == true {
                resetSessionViewport()
                let vp = resolvedViewportSize()
                return MiniClawActionResult(
                    text: "Viewport reset to default (\(vp.width)x\(vp.height))"
                )
            }
            guard let w = input.viewportWidth,let h = input.viewportHeight,
                  w>0,h>0 else {
                return .error("set_viewport requires positive viewport_width and viewport_height, or reset=true")
            }
            setSessionViewport(width: w,height: h)
            return MiniClawActionResult(
                text: "Viewport set to \(w)x\(h) for this session"
            )
        }

        // Serialize per tab id. Acquire the
        let serialWaitStart = CFAbsoluteTimeGetCurrent()
        guard let releaseSerialSlot = await acquireSerialSlot(tabId: targetId) else {
            let serialWaitMs = Int((CFAbsoluteTimeGetCurrent()-serialWaitStart)*1000)
            logger.info("[PoolTiming] serial_slot_timeout elapsed=\(serialWaitMs)ms tab=\(targetId) action=\(input.action.rawValue)")
            return .error(String(localized: "Multiple actions are operating on browser tab \(targetId) at the same time and it could not be acquired in time. Open a new tab (action: new_tab, or pass a different tab_id) and retry this action there so it can run in parallel."))
        }
        let serialAcquiredMs = Int((CFAbsoluteTimeGetCurrent()-serialWaitStart)*1000)
        if serialAcquiredMs>100 {
            logger.info("[PoolTiming] serial_slot_waited elapsed=\(serialAcquiredMs)ms tab=\(targetId)")
        }
        defer { releaseSerialSlot() }

        guard let liveIdx = tabs.firstIndex(where: { $0.id == targetId }) else {
            return .error("No tab with id \(targetId). Use list_tabs to see open tabs.")
        }

        // Delegate to the tab's MiniClawBrowserEngine.
        let manager = tabs[liveIdx].manager
        let managerStart = CFAbsoluteTimeGetCurrent()
        logger.info("[PoolTiming] manager_execute_start elapsed=\(Int((managerStart - poolStart) * 1000))ms tab=\(targetId) action=\(input.action.rawValue)")
        let result: MiniClawActionResult
        do {
            // Hard wall-clock ceiling on a single
            var r = try await withDeadOnTimeout(
                targetId: targetId,
                action: input.action.rawValue,
                url: input.url ?? manager.currentURL
            ) {
                try await manager.execute(action: input)
            }
            let managerMs = Int((CFAbsoluteTimeGetCurrent()-managerStart)*1000)
            logger.info("[PoolTiming] manager_execute_done elapsed=\(managerMs)ms tab=\(targetId) action=\(input.action.rawValue)")
            if preemptedTabIds.remove(targetId) != nil {
                return .error("Browser tab \(targetId) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
            }
            let pageURL = manager.webView.url?.absoluteString ?? manager.currentURL
            if !pageURL.isEmpty {
                r.pageURL = pageURL
            }
            // actually ran on.
            // If this navigate repurposed an
            if let sw = reusedTabSwitch,sw.tabId == targetId,r.success {
                r.text = "[Note] Reused existing tab \(targetId): it previously showed \(sw.oldURL) and has now been navigated to the new URL. Any earlier content on tab \(targetId) is gone; use tab_id \(targetId) to operate on THIS page.\n" + r.text
            }
            result = Self.stampTabId(r,targetId: targetId)
        } catch is ActionDeadTimeout {
            // The action blew past actionDeadTimeout.
            let elapsed = Int(CFAbsoluteTimeGetCurrent()-managerStart)
            let (newId,deadURL) = rebuildDeadTab(oldId: targetId)
            logger.warning("[PoolTiming] action_DEAD elapsed=\(elapsed)s tab=\(targetId) action=\(input.action.rawValue) → rebuilt as tab \(newId)")
            let urlPart = deadURL.isEmpty ? "" : " while on \(deadURL)"
            var msg = "Browser tab \(targetId) became unresponsive: the '\(input.action.rawValue)' action ran for over \(Int(Self.actionDeadTimeout))s without completing\(urlPart) — its web page most likely wedged (an infinite script, a never-completing navigation, or a background-suspended renderer). The tab could not be recovered and was closed. A fresh tab (id \(newId)) has been opened for you. To continue, retry on tab_id \(newId)"
            if !deadURL.isEmpty { msg += " (e.g. navigate it to \(deadURL) again, or take a different approach if that page keeps hanging)" }
            msg += "."
            var r = MiniClawActionResult(text: msg,success: false,tabId: newId)
            r.pageURL = deadURL.isEmpty ? nil : deadURL
            return r
        } catch {
            if preemptedTabIds.remove(targetId) != nil {
                return .error("Browser tab \(targetId) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
            }
            throw error
        }
        persistURLs()
        let totalMs = Int((CFAbsoluteTimeGetCurrent()-poolStart)*1000)
        logger.info("[PoolTiming] total elapsed=\(totalMs)ms tab=\(targetId) action=\(input.action.rawValue) success=\(result.success)")
        return result
    }

    /// 60s, so 300s only ever trips on a genuine wedge.
    #if DEBUG
    public static var actionDeadTimeoutOverride: TimeInterval?
    public static var actionDeadTimeout: TimeInterval { actionDeadTimeoutOverride ?? 300 }
    #else
    public static let actionDeadTimeout: TimeInterval = 300
    #endif

    private struct ActionDeadTimeout: Error {}

    private final class RaceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var cont: CheckedContinuation<MiniClawActionResult,Error>?
        private var pending: Result<MiniClawActionResult,Error>?
        var onFinish: (() -> Void)?

        func attach(_ c: CheckedContinuation<MiniClawActionResult,Error>) {
            lock.lock()
            if let p = pending { // result already arrived
                lock.unlock(); c.resume(with: p); return
            }
            cont = c
            lock.unlock()
        }

        func finish(_ result: Result<MiniClawActionResult,Error>) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont; cont = nil
            if c == nil { pending = result } // finished before attach
            let cleanup = onFinish; onFinish = nil
            lock.unlock()
            cleanup?()
            c?.resume(with: result)
        }
    }

    ///
    private func withDeadOnTimeout(
        targetId: Int,
        action: String,
        url: String,
        _ operation: @escaping () async throws -> MiniClawActionResult
    ) async throws -> MiniClawActionResult {
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = Self.actionDeadTimeout
        logger.info("[DeadTimeout] armed deadline=\(Int(deadline))s tab=\(targetId) action=\(action)")
        let box = RaceBox()
        let opTask = Task {
            do { let r = try await operation(); box.finish(.success(r)) }
            catch { box.finish(.failure(error)) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now()+deadline)
        timer.setEventHandler {
            logger.warning("[DeadTimeout] FIRED tab=\(targetId) action=\(action)")
            box.finish(.failure(ActionDeadTimeout()))
        }
        timer.resume()
        box.onFinish = { timer.cancel(); opTask.cancel() }
        let raced: MiniClawActionResult = try await withCheckedThrowingContinuation { cont in
            box.attach(cont)
        }
        return raced
    }

    private func rebuildDeadTab(oldId: Int) -> (newId: Int,deadURL: String) {
        let deadURL = tabs.first(where: { $0.id == oldId })?.manager.currentURL ?? ""
        tabs.removeAll { $0.id == oldId }
        if selectedTabId == oldId { selectedTabId = tabs.first?.id ?? 0 }

        let r = newTab(url: nil)
        let newId = r.tabId ?? selectedTabId
        logger.warning("[PoolTiming] tab_rebuilt oldTab=\(oldId) newTab=\(newId) deadURL=\(deadURL.prefix(60)) — dead tab dropped, fresh WebContent opened")
        return (newId,deadURL)
    }

    public func releaseAllTabs() {
        let now = Date()
        for i in tabs.indices {
            tabs[i].graceExpiryTask?.cancel()
            tabs[i].graceExpiryTask = nil
            tabs[i].inUse = false
            tabs[i].lastActivityDate = now
        }
        persistURLs()
        logger.info("Released all tabs (\(self.tabs.count) total)")
    }

    /// a ` tab_id: <N>` line to the human-readable text in the same indent
    /// in its narrative), skip the append.
    private static func stampTabId(_ result: MiniClawActionResult,targetId: Int) -> MiniClawActionResult {
        var r = result
        r.tabId = targetId
        if !r.text.contains("tab_id:") {
            let needsNewline = !r.text.isEmpty && !r.text.hasSuffix("\n")
            r.text = r.text + (needsNewline ? "\n" : "") + " tab_id: \(targetId)"
        }
        return r
    }

    ///
    private func armPostActionGrace(tabId: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[idx].graceExpiryTask?.cancel()
        let graceNs = UInt64(Self.postActionGraceSeconds*1_000_000_000)
        tabs[idx].graceExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: graceNs)
            guard !Task.isCancelled,let self else { return }
            if let i = self.tabs.firstIndex(where: { $0.id == tabId }) {
                self.tabs[i].inUse = false
                self.tabs[i].graceExpiryTask = nil
            }
        }
    }

    public func touchActivity() {
        if let idx = tabs.firstIndex(where: { $0.id == selectedTabId }) {
            tabs[idx].lastActivityDate = Date()
        }
    }

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleCheckInterval,repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evictIdleTabs()
            }
        }
    }

    private func evictIdleTabs() {
        let now = Date()
        var evicted = 0
        tabs.removeAll { tab in
            guard !tab.inUse else { return false }
            let idle = now.timeIntervalSince(tab.lastActivityDate)
            if idle >= Self.idleTimeout {
                let url = tab.manager.currentURL
                if !url.isEmpty {
                    savedURLs[tab.id] = url
                }
                logger.info("Evicting idle tab \(tab.id) (idle \(String(format: "%.0f", idle))s, url=\(url.prefix(60)))")
                evicted += 1
                return true
            }
            return false
        }
        if evicted>0 {
            if !tabs.contains(where: { $0.id == selectedTabId }) {
                selectedTabId = tabs.first?.id ?? 0
            }
            persistURLs()
            logger.info("Evicted \(evicted) idle tab(s), \(self.tabs.count) remaining")
        }
    }

    public func evictTabForRegistry(id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        guard !tab.inUse else { return } // safety net
        let url = tab.manager.currentURL
        if !url.isEmpty {
            savedURLs[id] = url
        }
        tabs.remove(at: idx)
        if selectedTabId == id {
            selectedTabId = tabs.first?.id ?? 0
        }
        persistURLs()
        logger.info("Evicted tab \(id) at registry request (url=\(url.prefix(60)))")
    }

    public func preemptTabForRegistry(id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        let url = tab.manager.currentURL
        if !url.isEmpty {
            savedURLs[id] = url
        }
        tab.manager.stopLoading()
        tabs.remove(at: idx)
        preemptedTabIds.insert(id)
        if selectedTabId == id {
            selectedTabId = tabs.first?.id ?? 0
        }
        persistURLs()
        logger.info("Preempted in-use tab \(id) at registry request (url=\(url.prefix(60)))")
    }

    public func evictAllIdleForMemoryWarning() -> Int {
        var evicted = 0
        tabs.removeAll { tab in
            guard !tab.inUse else { return false }
            let url = tab.manager.currentURL
            if !url.isEmpty {
                savedURLs[tab.id] = url
            }
            evicted += 1
            return true
        }
        if evicted>0 {
            if !tabs.contains(where: { $0.id == selectedTabId }) {
                selectedTabId = tabs.first?.id ?? 0
            }
            persistURLs()
        }
        return evicted
    }

    /// Create a MiniClawBrowserEngine wired to this pool.
    private func makeManager() -> MiniClawBrowserEngine {
        let ua = resolvedUserAgentString()
        let vp = resolvedViewportSize()
        let manager = MiniClawBrowserEngine(profile: userAgentProfile,customString: ua,
                                        viewportWidth: vp.width,viewportHeight: vp.height)
        wireManager(manager)
        return manager
    }

    private func wireManager(_ manager: MiniClawBrowserEngine) {
        manager.newWindowHandler = { [weak self] configuration,url in
            self?.openWithConfiguration(configuration,url: url)
        }
        manager.closeHandler = { [weak self] webView in
            self?.closeWebView(webView)
        }
        // Downloads land in this session's /var/miniclaw/workspace/ so the agent
        manager.sessionIdProvider = { [weak self] in self?.sessionId }
        manager.tabIdProvider = { [weak self,weak manager] in
            guard let self,let manager else { return nil }
            return self.tabs.first(where: { $0.manager === manager })?.id
        }
    }

    public func resolvedUserAgentString() -> String? {
        if userAgentProfile == .custom {
            return customUserAgentString.isEmpty ? nil : customUserAgentString
        }
        return userAgentProfile.userAgentString
    }

    public func resolvedViewportSize() -> (width: Int,height: Int) {
        if sessionViewportWidth>0 && sessionViewportHeight>0 {
            return (sessionViewportWidth,sessionViewportHeight)
        }
        if customViewportWidth>0 && customViewportHeight>0 {
            return (customViewportWidth,customViewportHeight)
        }
        return userAgentProfile.viewportSize
    }

    public func hasCustomViewport() -> Bool {
        return (sessionViewportWidth>0 && sessionViewportHeight>0)
            || (customViewportWidth>0 && customViewportHeight>0)
    }

    public func setGlobalViewport(width: Int,height: Int) {
        customViewportWidth = max(0,width)
        customViewportHeight = max(0,height)
        UserDefaults.standard.set(customViewportWidth,forKey: Self.viewportWidthKey)
        UserDefaults.standard.set(customViewportHeight,forKey: Self.viewportHeightKey)
        applyViewportToAllTabs()
    }

    public func setSessionViewport(width: Int,height: Int) {
        sessionViewportWidth = max(0,width)
        sessionViewportHeight = max(0,height)
        applyViewportToAllTabs()
        persistURLs()
    }

    public func resetSessionViewport() {
        sessionViewportWidth = 0
        sessionViewportHeight = 0
        applyViewportToAllTabs()
        persistURLs()
    }

    private func applyViewportToAllTabs() {
        let vp = resolvedViewportSize()
        let ua = resolvedUserAgentString()
        for tab in tabs {
            tab.manager.setViewport(width: vp.width,height: vp.height,
                                    profile: userAgentProfile,customUA: ua)
        }
    }

    /// Pass `false` for temporary agent-driven switches that should not outlive the session.
    public func setUserAgentProfile(_ profile: MiniClawUAProfile,persist: Bool = true) {
        userAgentProfile = profile
        if persist {
            UserDefaults.standard.set(profile.rawValue,forKey: Self.uaProfileKey)
            UserDefaults.standard.set(customUserAgentString,forKey: Self.uaCustomStringKey)
        }
        let ua = resolvedUserAgentString()
        let vp = resolvedViewportSize()
        for tab in tabs {
            tab.manager.setUserAgent(profile: profile,customString: ua)
            tab.manager.setViewport(width: vp.width,height: vp.height,
                                    profile: profile,customUA: ua)
        }
    }

    private func restoreSavedURL(for tabId: Int,manager: MiniClawBrowserEngine) {
        if let url = savedURLs.removeValue(forKey: tabId) {
            logger.info("Restoring saved URL for tab \(tabId): \(url.prefix(60))")
            manager.loadURL(url)
            persistURLs()
        }
    }

    private func ensureDefaultTab() -> Int {
        if tabs.contains(where: { $0.id == 0 }) {
            return 0
        }
        return acquireTab()
    }

    private struct PersistedTabs: Codable {
        var tabURLs: [Int: String] // tab ID → URL (live + evicted)
        var selectedTabId: Int
        var sessionViewportWidth: Int?
        var sessionViewportHeight: Int?
    }

    private static func storeURL(for sessionId: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask).first!
            .appendingPathComponent("MiniClaw/browser_tabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sessionId).json")
    }

    private func persistURLs() {
        guard let sessionId else { return }
        var allURLs = savedURLs
        for tab in tabs {
            let url = tab.manager.currentURL
            if !url.isEmpty {
                allURLs[tab.id] = url
            }
        }
        let hasSessionViewport = sessionViewportWidth>0 && sessionViewportHeight>0
        guard !allURLs.isEmpty || hasSessionViewport else {
            let url = Self.storeURL(for: sessionId)
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = PersistedTabs(
            tabURLs: allURLs,
            selectedTabId: selectedTabId,
            sessionViewportWidth: hasSessionViewport ? sessionViewportWidth : nil,
            sessionViewportHeight: hasSessionViewport ? sessionViewportHeight : nil
        )
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: Self.storeURL(for: sessionId),options: .atomic)
            logger.info("Persisted \(allURLs.count) tab URL(s) for session \(sessionId.prefix(8))")
        } catch {
            logger.error("Failed to persist tab URLs: \(error.localizedDescription)")
        }
    }

    private func loadPersistedURLs() {
        guard let sessionId else { return }
        let url = Self.storeURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let persisted = try JSONDecoder().decode(PersistedTabs.self,from: data)
            let liveIds = Set(tabs.map(\.id))
            for (tabId,tabURL) in persisted.tabURLs where !liveIds.contains(tabId) {
                savedURLs[tabId] = tabURL
            }
            if !tabs.contains(where: { $0.id == persisted.selectedTabId }) {
                selectedTabId = persisted.selectedTabId
            }
            if let w = persisted.sessionViewportWidth,let h = persisted.sessionViewportHeight,
               w>0,h>0 {
                sessionViewportWidth = w
                sessionViewportHeight = h
                if !tabs.isEmpty {
                    applyViewportToAllTabs()
                }
            }
            logger.info("Loaded \(persisted.tabURLs.count) persisted tab URL(s) for session \(sessionId.prefix(8))")
        } catch {
            logger.error("Failed to load persisted tab URLs: \(error.localizedDescription)")
        }
    }

    public static func deletePersistedData(for sessionId: String) {
        let url = storeURL(for: sessionId)
        try? FileManager.default.removeItem(at: url)
    }
}

private let logger = AppLogger(category: "MiniClawTabPool")
private let registryLogger = AppLogger(category: "MiniClawTabPoolRegistry")

/// Process-wide cap on live `WKWebView` tabs across all `MiniClawTabPool`s.
///