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

    func setSession(_ sessionID: UUID?) {
        // 2026-08-12:绑定到会话级池(pool(for:) 与工具链共用同一池,标签同步);
        // 会话池的 sessionId 在 pool(for:) 创建时已设置。
        sessionPool = sessionID.map { pool(for: $0) }
        pool.ensureTabForUI()
        rebind()
    }

    func resetAgentTakeover() {}
    func cancelAgentOperation() {
        isAgentOperating = false
        pool.stopAllLoading()
    }

    func resolveResourceURL(_ raw: String) -> String? { raw }

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

    func uiNavigate(urlString: String) {
        pool.activeManager?.loadURL(urlString)
        rebind()
    }

    func uiReload() { pool.activeManager?.reload() }
    func uiBack() { pool.activeManager?.goBack() }
    func uiForward() { pool.activeManager?.goForward() }

    func uiHistoryItems() -> [BrowserHistoryItem] { [] }
    func uiGoToHistory(url: URL) { pool.activeManager?.loadURL(url.absoluteString) }
    func uiClearHistory() {}

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

    func rehost(_ webView: WKWebView) {
        // 引擎自持 webView;宿主重挂场景由引擎 ensureTabForUI 处理
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


