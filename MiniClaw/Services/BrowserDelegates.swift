import Foundation
import MiniClawKit
import WebKit
import UIKit
import SwiftUI
import Combine

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
        let defaultUA = BrowserActionHelpers.defaultUAString()
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
        wv.underPageBackgroundColor = .systemBackground
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

    // deinit 已移除：deinit 是非隔离上下文、可能在任意线程执行，而
    // `WKUserContentController` / `config` 均为 MainActor 隔离——在此处调用
    // `MainActor.assumeIsolated` 一旦遇到后台线程释放就会 fatalError 崩溃
    // （信号级硬崩溃、无日志、检查点被标 interrupted）。该清理本身也是冗余的：
    // scriptMessageHandler 注册在随本对象一同释放的 config 上，无需手动摘除。

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
            AppLogger.shared.info(String(format: String(localized: "bc_popup_blocked"), url), category: "Browser", subsystem: "Browser")
            return
        }
        AppLogger.shared.info(String(format: String(localized: "bc_popup_request"), url), category: "Browser", subsystem: "Browser")
        Task { @MainActor in
            _ = BrowserController.shared.openPopupTab(urlString: url)
        }
    }
}

/// 受「通用设置 → 浏览器 → 拦截弹窗」开关控制：开启时直接拦截（返回 nil），
/// 关闭时新建一个标签承载弹窗，并复用其 webView 交由 WebKit 加载。
final class BrowserUIDelegate: NSObject, WKUIDelegate {
    weak var tab: BrowserTab?

    // iOS26 SDK:协议方法改名 createWebViewWithConfiguration -> createWebViewWith(ObjC selector 不变)。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 仅拦截真正的新窗口请求（targetFrame == nil）；同框内导航不拦截。
        guard navigationAction.targetFrame == nil else {
            AppLogger.shared.info("弹窗回调:同框导航,忽略(\(navigationAction.request.url?.absoluteString ?? "nil"))", category: "Browser", subsystem: "Browser")
            return nil
        }
        AppLogger.shared.info("弹窗回调:收到新窗口请求 url=\(navigationAction.request.url?.absoluteString ?? "nil")", category: "Browser", subsystem: "Browser")

        let block = SettingsStore.shared.settings.browser.blockPopups
        let urlString = navigationAction.request.url?.absoluteString ?? ""
        if block {
            // 手势放行：用户点击（1s 内 touchstart/click）触发的 window.open 放行，
            // 与 iOS Safari「拦截弹窗」行为一致——只拦页面自动弹出的广告弹窗，
            // 不拦用户主动点击的「登录窗口/分享窗口」等。
            if let tab = tab, tab.wasRecentUserGesture() {
                AppLogger.shared.info(String(format: String(localized: "bc_popup_allow"), urlString), category: "Browser", subsystem: "Browser")
            } else {
                AppLogger.shared.info(String(format: String(localized: "bc_popup_blocked_switch"), urlString), category: "Browser", subsystem: "Browser")
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

