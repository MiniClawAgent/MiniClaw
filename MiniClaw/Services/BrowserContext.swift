import WebKit

/// 单个浏览器上下文：一套独立的 WKWebsiteDataStore + WKProcessPool + 标签页。
/// 同一会话内的所有标签页共享 Cookie、缓存和站点存储；
/// 不同会话使用不同上下文，完全隔离。
@MainActor
final class BrowserContext {
    let id = UUID()
    let dataStore: WKWebsiteDataStore
    let processPool = WKProcessPool()

    /// 该上下文内的标签页（最多 3 个）
    var tabs: [BrowserTab] = []

    /// 返回 httpCookieStore，供 get/set cookie 使用
    var cookieStore: WKHTTPCookieStore { dataStore.httpCookieStore }

    /// 用外部 dataStore 创建（BrowserContextManager 传入全局共享持久存储）。
    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
    }

    /// 用本上下文的配置创建新的 WKWebView
    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.processPool = processPool
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 官方文档：javaScriptCanOpenWindowsAutomatically iOS 默认 false——
        // 异步/延迟触发的 window.open 会被 WebKit 直接拒绝，连 WKUIDelegate 回调都不触发
        // （点击"完全无反应、无日志"）。设为 true 让弹窗请求全部到达 delegate，
        // 放行/拦截改由我们的「拦截弹窗」开关 + 手势判定统一接管（自动弹窗仍被拦）。
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        return config
    }

    /// 获取或创建指定索引的标签页
    func ensureTab(at index: Int, uaProvider: () -> String) -> BrowserTab {
        while tabs.count <= index {
            let tab = BrowserTab(config: makeWebViewConfiguration(), uaString: uaProvider())
            tabs.append(tab)
        }
        return tabs[index]
    }

    /// 获取标签页（安全访问）
    func tab(at index: Int) -> BrowserTab? {
        guard tabs.indices.contains(index) else { return nil }
        return tabs[index]
    }
}
