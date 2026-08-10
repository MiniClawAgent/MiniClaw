import Foundation
import SwiftUI
import WebKit
import Combine
import MiniClawKit

// MARK: - 浏览器引擎适配桥(2026-08-10)
// 把移植引擎(MiniClawTabPool + MiniClawBrowserEngine)包装成 BrowserView 依赖的
// 接口形态(BrowserController 同名成员),BrowserView 零改动切到引擎。
// 引擎照搬自 OpenMinis BrowserUse 子系统;UI 复用主工程 BrowserView。

@MainActor
final class BrowserEngineAdapter: ObservableObject {
    static let shared = BrowserEngineAdapter()

    /// 引擎标签池(会话级;宿主在进入会话时 setSession;
    /// 2026-08-10:与工具链共用——BrowserController 也经 pool(for:) 取池,UI/工具标签同步)
    private let pool = MiniClawTabPool()
    private var pools: [String: MiniClawKit.MiniClawTabPool] = [:]
    private let sharedPool = MiniClawKit.MiniClawTabPool()

    /// 会话级池(工具链共用)
    func pool(for sessionID: UUID?) -> MiniClawKit.MiniClawTabPool {
        guard let sessionID else { return sharedPool }
        let key = sessionID.uuidString
        if let p = pools[key] { return p }
        let p = MiniClawKit.MiniClawTabPool()
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
        pool.sessionId = sessionID?.uuidString
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
        // 标签表投影
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
            }
            .store(in: &subs)
        // 活跃 manager 状态
        if let manager = pool.activeManager {
            manager.$canGoBack.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
            manager.$canGoForward.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
            manager.$isLoading.sink { [weak self] loading in
                guard let self else { return }
                if loading {
                    self.loadingProgress = 0.1
                } else {
                    self.loadingProgress = 1.0
                }
                self.objectWillChange.send()
            }.store(in: &subs)
            manager.$pageTitle.sink { [weak self] _ in self?.rebindTabs() }.store(in: &subs)
            manager.$currentURL.sink { [weak self] _ in self?.rebindTabs() }.store(in: &subs)
        }
        pool.$isBrowserLoading.sink { [weak self] loading in
            self?.isAgentOperating = loading
        }.store(in: &subs)
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


