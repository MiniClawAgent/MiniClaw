import Foundation
import WebKit
import UIKit
import os.log

extension MiniClawBrowserEngine: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            self.loadError = nil //
            self.currentURL = webView.url?.absoluteString ?? self.currentURL
            self.pageTitle = webView.title ?? ""
            self.canGoBack = webView.canGoBack
            self.canGoForward = webView.canGoForward

            MiniClawHistoryStore.shared.record(url: self.currentURL,title: self.pageTitle)

            if let cont = self.navigationContinuation {
                self.navigationContinuation = nil
                cont.resume()
            }
        }
    }

    public nonisolated func webView(_ webView: WKWebView,didCommit navigation: WKNavigation!) {
        // 新文档已开始装载 → 允许「readyState 提前收网」开始轮询
        //（此前轮询会读到上一页的 complete）。见 navigate(to:)。
        Task { @MainActor [weak self] in
            self?.navigationDidCommit = true
        }
    }

    public nonisolated func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
            // Show a Safari-style overlay in the
            self.loadError = MiniClawWebLoadError(error: error,failedURL: self.lastRequestedURL)
            logger.error("Navigation failed: \(error.localizedDescription)")

            if let cont = self.navigationContinuation {
                self.navigationContinuation = nil
                cont.resume(throwing: error)
            }
        }
    }

    public nonisolated func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
            // see didFail above.
            self.loadError = MiniClawWebLoadError(error: error,failedURL: self.lastRequestedURL)
            logger.error("Provisional navigation failed: \(error.localizedDescription)")

            if let cont = self.navigationContinuation {
                self.navigationContinuation = nil
                cont.resume(throwing: error)
            }
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy,WKWebpagePreferences) -> Void
    ) {
        let allowedSchemes: Set<String> = ["http", "https", "about", "blob", "miniclaw"]

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download,preferences)
            return
        }

        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !allowedSchemes.contains(scheme) {
            decisionHandler(.cancel,preferences)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = false
                self.currentURL = webView.url?.absoluteString ?? self.currentURL
                if let cont = self.navigationContinuation {
                    self.navigationContinuation = nil
                    cont.resume(throwing: URLError(.unsupportedURL,userInfo: [
                        NSLocalizedDescriptionKey: "Blocked navigation to \(scheme):// — only http(s) and miniclaw:// are allowed in the browser."
                    ]))
                }
            }
            return
        }

        let allowWithoutAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue+2) ?? .allow

        let mode: WKWebpagePreferences.ContentMode = MainActor.assumeIsolated {
            let profile = self.currentProfile
            let vp = self.currentViewport
            let wantsDesktop = (profile == .desktopSafari) || (vp.width >= 1024)
            return wantsDesktop ? .desktop : .mobile
        }
        preferences.preferredContentMode = mode
        decisionHandler(allowWithoutAppLink,preferences)
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.contains("attachment") {
            decisionHandler(.download)
            return
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    public nonisolated func webView(_ webView: WKWebView,navigationAction: WKNavigationAction,didBecome download: WKDownload) {
        MainActor.assumeIsolated { self.attachDownload(download) }
    }

    public nonisolated func webView(_ webView: WKWebView,navigationResponse: WKNavigationResponse,didBecome download: WKDownload) {
        MainActor.assumeIsolated { self.attachDownload(download) }
    }

    private func attachDownload(_ download: WKDownload) {
        download.delegate = self
        inflightDownloads[ObjectIdentifier(download)] = download
        isLoading = false
        if let cont = navigationContinuation {
            navigationContinuation = nil
            cont.resume()
        }
    }

    ///
    public nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            let url = self.currentURL.isEmpty ? nil : self.currentURL
            let tabId = self.tabIdProvider?()
            MiniClawResourceMonitor.shared.webContentProcessDidTerminate(tabId: tabId,url: url)

            self.isLoading = false
            let error = NSError(
                domain: "BrowserUse",
                code: -3001,
                userInfo: [NSLocalizedDescriptionKey:
                    "The browser's web content process was terminated by the system "
                    + "(likely out of memory, or suspended in the background). Retry the action."]
            )
            self.loadError = MiniClawWebLoadError(error: error,failedURL: self.lastRequestedURL)
            if let cont = self.navigationContinuation {
                self.navigationContinuation = nil
                cont.resume(throwing: error)
            }
        }
    }
}

extension MiniClawBrowserEngine: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == Self.printMessageHandlerName else { return }
        presentPrintDialog()
    }
}

// MARK: - MiniClawSchemeHandler

/// Handles `miniclaw://` URLs in WKWebView by resolving them to local files.
/// Supports `miniclaw://workspace/file.html`, `miniclaw://shared/...`, etc.
private let logger = AppLogger(category: "BrowserUse")

@MainActor
public final class MiniClawBrowserEngine: NSObject,ObservableObject {

    @Published public var currentURL: String = ""
    @Published public var pageTitle: String = ""
    @Published public var isLoading: Bool = false
    /// Non-nil when the last navigation failed
    @Published public var loadError: MiniClawWebLoadError?
    /// MiniClawWebLoadError copy can reference the exact address that failed.
    private var lastRequestedURL: URL?
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var lastScreenshot: UIImage?

    public private(set) var webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void,Error>?

    /// 本轮导航是否已 `didCommit`（新文档已开始装载）。
    /// 供「readyState 提前收网」当门闸：没有它就会读到**上一页**的 `complete` 而误判。
    private var navigationDidCommit = false

    /// 单次导航等待的三条出路（didFinish / readyState 提前收网 / 超时兜底）共享的结果标记。
    /// 用类盒而非局部 `var`：出口闭包是并发执行的 `Task`，捕获并改写局部变量在 Swift 6 下不合法。
    @MainActor
    private final class NavWaitBox {
        /// 是否走到超时兜底（此时页面可能只加载了一部分，结果需显式标注）。
        var timedOut = false
    }
    @Published private(set) var currentProfile: MiniClawUAProfile = .mobileSafari

    public var newWindowHandler: ((_ configuration: WKWebViewConfiguration,_ url: URL?) -> WKWebView?)?

    public var closeHandler: ((_ webView: WKWebView) -> Void)?

    /// Download state now lives in the session-scoped
    private var downloadCenterIds: [ObjectIdentifier: UUID] = [:]

    public var hasInflightDownloads: Bool { !inflightDownloads.isEmpty }

    /// Returns the chat session id owning this browser — wired by MiniClawTabPool.
    /// Downloads are saved into that session's /var/MiniClaw/workspace/ directory.
    public var sessionIdProvider: (() -> String?)?

    /// Returns this tab's pool id — wired by MiniClawTabPool. Diagnostics only,
    public var tabIdProvider: (() -> Int?)?

    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    private var inflightDownloads: [ObjectIdentifier: WKDownload] = [:]

    private static let navigationTimeout: TimeInterval = 30

    /// 导航进度轮询间隔（秒）。
    /// `didFinish` 在部分站点永不触发（主文档已渲染完，但持续第三方请求/长轮询让 WebKit
    /// 认为未收尾）。此时靠轮询 `document.readyState` 提前收网，省掉整个超时预算。
    private static let navigationProgressPollInterval: TimeInterval = 0.8

    /// iOS15+ WKProcessPool 实例化已无效果(系统统一管理),不再创建。
    public static let sharedProcessPool: WKProcessPool? = nil

    private(set) var currentViewport: (width: Int,height: Int) = (390,844)

    init(profile: MiniClawUAProfile = .mobileSafari,customString: String? = nil,
         viewportWidth: Int? = nil,viewportHeight: Int? = nil) {
        self.currentProfile = profile
        let vp = Self.resolveViewport(profile: profile,width: viewportWidth,height: viewportHeight)
        self.currentViewport = vp
        self.webView = Self.makeWebView(profile: profile,customString: customString,
                                        viewportWidth: vp.width,viewportHeight: vp.height)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        registerPrintHandler(on: webView)
    }

    init(profile: MiniClawUAProfile,customString: String?,configuration: WKWebViewConfiguration,
         viewportWidth: Int? = nil,viewportHeight: Int? = nil) {
        self.currentProfile = profile
        let vp = Self.resolveViewport(profile: profile,width: viewportWidth,height: viewportHeight)
        self.currentViewport = vp
        let wv = WKWebView(frame: CGRect(x: 0,y: 0,width: vp.width,height: vp.height),configuration: configuration)
        wv.customUserAgent = Self.resolveUA(profile: profile,customString: customString)
        wv.allowsBackForwardNavigationGestures = true
        self.webView = wv
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        registerPrintHandler(on: webView)
    }

    private static func resolveViewport(profile: MiniClawUAProfile,
                                        width: Int?,height: Int?) -> (width: Int,height: Int) {
        if let w = width,let h = height,w>0,h>0 {
            return (w,h)
        }
        return profile.viewportSize
    }

    /// Shared scheme handler for `miniclaw://` URLs across all browser tabs
    public static let sharedMiniClawSchemeHandler = MiniClawSchemeHandler()

    private static func resolveUA(profile: MiniClawUAProfile,customString: String?) -> String {
        if let custom = customString,!custom.isEmpty {
            return custom
        }
        return profile.userAgentString ?? MiniClawUAProfile.mobileSafari.userAgentString!
    }

    private static func makeWebView(profile: MiniClawUAProfile,
                                    customString: String? = nil,
                                    viewportWidth: Int? = nil,
                                    viewportHeight: Int? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        if let pool = sharedProcessPool { config.processPool = pool }
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(Self.sharedMiniClawSchemeHandler, forURLScheme: "miniclaw")

        // every page (miniclaw:// and external http/https) at document start so a
        config.userContentController.addUserScript(printBridgeScript())

        let vp = resolveViewport(profile: profile,width: viewportWidth,height: viewportHeight)

        // - the profile is desktop (original behavior), OR
        // - the caller supplied a custom viewport (so pages lay out at the
        // requested width instead of the container-derived size).
        let hasCustom = (viewportWidth ?? 0)>0 && (viewportHeight ?? 0)>0
        let wantsDesktop = (profile == .desktopSafari) || (hasCustom && vp.width >= 1024)
        if profile == .desktopSafari || hasCustom {
            config.userContentController.addUserScript(desktopViewportScript(width: vp.width))
        }
        config.defaultWebpagePreferences.preferredContentMode = wantsDesktop ? .desktop : .mobile

        let webView = WKWebView(frame: CGRect(x: 0,y: 0,width: vp.width,height: vp.height),configuration: config)
        webView.customUserAgent = resolveUA(profile: profile,customString: customString)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    private static func desktopViewportScript(width: Int) -> WKUserScript {
        let js = """
        (function() {
            var w = \(width);
            function apply() {
                var metas = document.querySelectorAll('meta[name="viewport"]');
                metas.forEach(function(m) { m.parentNode.removeChild(m); });
                var m = document.createElement('meta');
                m.name = 'viewport';
                m.content = 'width='+w+',initial-scale=1.0,user-scalable=yes';
                (document.head || document.documentElement).appendChild(m);
            }
            apply();
            document.addEventListener('DOMContentLoaded',apply);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    nonisolated static let printMessageHandlerName = "miniclawPrint"

    nonisolated static func printBridgeScript() -> WKUserScript {
        let js = """
        (function() {
            window.print = function() {
                try {
                    window.webkit.messageHandlers.\(printMessageHandlerName).postMessage(null);
                } catch (e) {}
            };
        })();
        """
        return WKUserScript(source: js,injectionTime: .atDocumentStart,forMainFrameOnly: true)
    }

    private func registerPrintHandler(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.printMessageHandlerName)
        controller.add(WeakScriptMessageHandler(self),name: Self.printMessageHandlerName)
    }

    private func presentPrintDialog() {
        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo.printInfo()
        printInfo.outputType = .general
        printInfo.jobName = pageTitle.isEmpty ? "MiniClaw" : pageTitle
        printController.printInfo = printInfo
        printController.printFormatter = webView.viewPrintFormatter()
        printController.present(animated: true) { _,completed,error in
            if let error = error {
                logger.error("Print dialog failed: \(error.localizedDescription)")
            } else {
                logger.info("Print dialog completed=\(completed)")
            }
        }
    }

    private static let visualChangeActions: Set<MiniClawBrowserAction> = [
        .navigate,.click,.scroll,.scrollAndCollect,.hover,.type
    ]

    public func execute(action input: MiniClawActionInput) async throws -> MiniClawActionResult {
        let mgrStart = CFAbsoluteTimeGetCurrent()
        logger.info("[MgrTiming] enter action=\(input.action.rawValue)")
        await MiniClawCookieBackup.shared.syncIfNeeded()
        var result: MiniClawActionResult
        switch input.action {
        case .navigate:
            result = try await navigate(to: input.url)
        case .screenshot:
            return try await screenshot(fullPage: input.fullPage ?? false) // already produces a screenshot
        case .click:
            result = try await click(selector: input.selector,x: input.coordinateX,y: input.coordinateY)
        case .type:
            result = try await type(selector: input.selector,text: input.text)
        case .getText:
            return try await getText(selector: input.selector)
        case .scroll:
            result = try await scroll(selector: input.selector,direction: input.direction,amount: input.amount)
        case .scrollAndCollect:
            result = try await scrollAndCollect(selector: input.selector,direction: input.direction,amount: input.amount,scrollCount: input.scrollCount,itemSelector: input.itemSelector)
        case .getPageInfo:
            return try await getPageInfo()
        case .executeJS:
            return try await executeJS(script: input.script)
        case .findElements:
            return try await findElements(selector: input.selector)
        case .hover:
            result = try await hover(selector: input.selector)
        case .getReadable:
            return try await getReadable()
        case .setUserAgent:
            return setUserAgent(profile: input.userAgent)
        case .setViewport:
            // Routed by MiniClawTabPool.execute — pool mutates all tabs; this
            return .error("set_viewport must be routed through MiniClawTabPool")
        case .getBackbone:
            return try await getBackbone(maxDepth: input.maxDepth)
        case .fetch:
            return try await fetch(url: input.url)
        case .newTab,.closeTab,.listTabs:
            return .error("Tab management actions must be routed through MiniClawTabPool")
        case .getCookies:
            return await getCookies(keywords: input.keywords,fuzzy: input.fuzzy ?? true)
        case .setCookies:
            return await setCookies(input.cookies)
        case .waitForDomStable:
            return try await waitForDomStable(timeout: input.timeout)
        }

        let actionMs = Int((CFAbsoluteTimeGetCurrent()-mgrStart)*1000)
        logger.info("[MgrTiming] action_done elapsed=\(actionMs)ms action=\(input.action.rawValue)")

        if result.success,Self.visualChangeActions.contains(input.action) {
            let settleStart = CFAbsoluteTimeGetCurrent()
            result = await waitForDomSettleAndSnapshot(result: result)
            let settleMs = Int((CFAbsoluteTimeGetCurrent()-settleStart)*1000)
            logger.info("[MgrTiming] dom_settle_snapshot elapsed=\(settleMs)ms action=\(input.action.rawValue)")
        }
        let totalMs = Int((CFAbsoluteTimeGetCurrent()-mgrStart)*1000)
        logger.info("[MgrTiming] total elapsed=\(totalMs)ms action=\(input.action.rawValue)")
        return result
    }

    /// 快照超时（秒）。`takeSnapshot` 没有取消能力，WebContent 卡死时 completion 永不回调。
    private static let snapshotTimeout: TimeInterval = 8

    /// 有界快照的结果（Sendable：可跨 continuation 传递 JPEG 数据与点尺寸）。
    private struct BoundedSnapshot: Sendable {
        let jpeg: Data
        let size: CGSize
    }

    /// 有界快照：超时 / 编码失败返回 nil。
    ///
    /// 不用 `takeSnapshot(configuration:)` 的 async 版——它无法与超时赛跑，页面卡死时会把
    /// 调用方永久挂起（实测 navigate 卡到 114s / 296s，最终引爆 TabPool 的 300s 看门狗）。
    /// 这里改用 completion 版 + 一次性收尾盒：回调与超时谁先到谁定稿，另一方成为 no-op。
    private func captureSnapshotBounded(_ configuration: WKSnapshotConfiguration,
                                        quality: CGFloat = 0.7) async -> BoundedSnapshot? {
        final class SnapshotBox: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            private var cont: CheckedContinuation<BoundedSnapshot?,Never>?
            private var timer: DispatchSourceTimer?
            func attach(_ c: CheckedContinuation<BoundedSnapshot?,Never>) {
                lock.lock()
                if done { lock.unlock(); c.resume(returning: nil); return }
                cont = c
                lock.unlock()
            }
            func setTimer(_ t: DispatchSourceTimer) {
                lock.lock()
                if done { lock.unlock(); t.cancel(); return }
                timer = t
                lock.unlock()
            }
            func finish(_ snap: BoundedSnapshot?) {
                lock.lock()
                if done { lock.unlock(); return }
                done = true
                let c = cont; cont = nil
                let t = timer; timer = nil
                lock.unlock()
                t?.cancel()
                c?.resume(returning: snap)
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<BoundedSnapshot?,Never>) in
            let box = SnapshotBox()
            box.attach(cont)
            // timer 必须挂主队列：本类型是 @MainActor，handler 闭包会继承主 actor 隔离。
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now()+Self.snapshotTimeout)
            timer.setEventHandler { box.finish(nil) }
            box.setTimer(timer)
            timer.resume()
            // takeSnapshot 的 completion 保证在主线程回调（与本类型的隔离一致）。
            webView.takeSnapshot(with: configuration) { image, _ in
                guard let image,let data = image.jpegData(compressionQuality: quality) else {
                    box.finish(nil)
                    return
                }
                box.finish(BoundedSnapshot(jpeg: data,size: image.size))
            }
        }
    }

    private func waitForDomSettleAndSnapshot(result: MiniClawActionResult) async -> MiniClawActionResult {
        let prevURL = webView.url
        let settleStart = CFAbsoluteTimeGetCurrent()
        let domSummary = await collectDomChangeSummary(timeout: 5.0)
        let domMs = Int((CFAbsoluteTimeGetCurrent()-settleStart)*1000)
        logger.info("[SettleTiming] dom_summary elapsed=\(domMs)ms")

        // Match the frame-resize approach in `screenshot()` so custom
        // viewports render at their intended size even when the browser
        // sheet is stretching the WKWebView to fill a different container.
        let snapStart = CFAbsoluteTimeGetCurrent()
        var snapshotPath: String? = nil
        let targetSize = CGSize(width: CGFloat(currentViewport.width),
                                height: CGFloat(currentViewport.height))
        let savedFrame = webView.frame
        let shouldResize = abs(savedFrame.size.width-targetSize.width)>0.5 ||
                           abs(savedFrame.size.height-targetSize.height)>0.5
        if shouldResize {
            webView.frame = CGRect(origin: savedFrame.origin,size: targetSize)
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        do {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero,size: targetSize)
            // 有界快照：WebContent 卡死时 takeSnapshot 的 completion 可能永不回调，
            // 无界等待会把整个动作吊死（实测 navigate 卡到 114s / 296s，最终引爆 300s 看门狗）。
            // 到点放弃本次快照，动作照常返回——快照只是预览图，不该拖住工具结果。
            if let snap = await captureSnapshotBounded(config) {
                lastScreenshot = UIImage(data: snap.jpeg)
                let filename = "snapshot_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
                let fileURL = Self.screenshotsDir.appendingPathComponent(filename)
                try snap.jpeg.write(to: fileURL)
                snapshotPath = fileURL.path
            } else {
                logger.warning("[SettleTiming] snapshot dropped — 超过 \(Int(Self.snapshotTimeout))s 未回调（WebContent 卡死），动作继续返回")
            }
        } catch {
            logger.warning("Post-action snapshot failed: \(error.localizedDescription)")
        }
        if shouldResize {
            restoreViewportFrame()
        }

        let snapMs = Int((CFAbsoluteTimeGetCurrent()-snapStart)*1000)
        logger.info("[SettleTiming] snapshot elapsed=\(snapMs)ms")

        var text = result.text
        if !domSummary.isEmpty {
            text += "\n" + domSummary
        }

        let newURL = webView.url
        if let prev = prevURL,let cur = newURL {
            let prevNoHash = prev.absoluteString.components(separatedBy: "#").first ?? prev.absoluteString
            let curNoHash = cur.absoluteString.components(separatedBy: "#").first ?? cur.absoluteString
            if prevNoHash != curNoHash {
                text += "\n[URL Changed] Page navigated: \(prev.absoluteString) -> \(cur.absoluteString). Take a screenshot to see the current state before continuing."
            }
        }

        return MiniClawActionResult(
            text: text,
            success: result.success,
            base64Image: result.base64Image,
            imageFilePath: snapshotPath ?? result.imageFilePath
        )
    }

    private func collectDomChangeSummary(timeout: Double) async -> String {
        let setupJS = """
        window.__postActionDom = {
            mutations: 0,
            addedTags: {},
            removedCount: 0,
            textChanges: 0,
            attrChanges: 0,
            newTexts: [],
            urlBefore: location.href,
            titleBefore: document.title
        };
        var d = window.__postActionDom;
        window.__postActionObserver = new MutationObserver(function(muts) {
            for (var i = 0; i<muts.length; i++) {
                var m = muts[i];
                d.mutations++;
                if (m.type === 'childList') {
                    for (var j = 0; j<m.addedNodes.length; j++) {
                        var n = m.addedNodes[j];
                        if (n.nodeType === 1) {
                            var tag = n.tagName;
                            d.addedTags[tag] = (d.addedTags[tag] || 0)+1;
                            var txt = (n.innerText || '').trim();
                            if (txt.length>5 && txt.length<200 && d.newTexts.length<5) {
                                d.newTexts.push(txt.substring(0,100));
                            }
                        }
                    }
                    d.removedCount += m.removedNodes.length;
                } else if (m.type === 'characterData') {
                    d.textChanges++;
                } else if (m.type === 'attributes') {
                    d.attrChanges++;
                }
            }
        });
        window.__postActionObserver.observe(document.documentElement,{
            childList: true,subtree: true,attributes: true,characterData: true
        });
        return 'ok';
        """
        _ = try? await webView.callAsyncJavaScript(setupJS, arguments: [:], contentWorld: .page)

        let pollNs: UInt64 = 500_000_000
        let stableNeeded = 3
        var lastTotal = 0
        var lastDelta = Int.max
        var stableRuns = 0
        let startTime = CFAbsoluteTimeGetCurrent()

        while true {
            try? await Task.sleep(nanoseconds: pollNs)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed >= timeout { break }

            let countResult = try? await webView.callAsyncJavaScript(
                "return window.__postActionDom ? window.__postActionDom.mutations : 0;",
                arguments: [:], contentWorld: .page
            )
            let total: Int
            if let n = countResult as? Int { total = n }
            else if let n = countResult as? Double { total = Int(n) }
            else { break } // page context lost

            let delta = total - lastTotal
            if delta <= lastDelta {
                stableRuns += 1
            } else {
                stableRuns = 0
            }
            lastTotal = total
            lastDelta = delta

            if stableRuns >= stableNeeded { break }
        }

        let readJS = """
        if (window.__postActionObserver) {
            window.__postActionObserver.disconnect();
            window.__postActionObserver = null;
        }
        var d = window.__postActionDom || {};
        return JSON.stringify({
            mutations: d.mutations || 0,
            addedTags: d.addedTags || {},
            removedCount: d.removedCount || 0,
            textChanges: d.textChanges || 0,
            attrChanges: d.attrChanges || 0,
            newTexts: d.newTexts || [],
            urlChanged: (location.href !== (d.urlBefore || '')),
            urlNow: location.href,
            titleNow: document.title
        });
        """
        guard let jsonStr = try? await webView.callAsyncJavaScript(readJS,arguments: [:],contentWorld: .page) as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return ""
        }

        let mutations = info["mutations"] as? Int ?? 0
        if mutations == 0 { return "DOM: no changes detected" }

        var parts: [String] = []

        if info["urlChanged"] as? Bool == true, let urlNow = info["urlNow"] as? String {
            parts.append("navigated to \(urlNow)")
        }

        if let tags = info["addedTags"] as? [String: Int], !tags.isEmpty {
            let sorted = tags.sorted { $0.value>$1.value }.prefix(5)
            let tagStr = sorted.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            parts.append("added: \(tagStr)")
        }

        let removed = info["removedCount"] as? Int ?? 0
        if removed > 0 { parts.append("\(removed) nodes removed") }

        let attr = info["attrChanges"] as? Int ?? 0
        let text = info["textChanges"] as? Int ?? 0
        if attr>0 || text>0 {
            var changeParts: [String] = []
            if attr > 0 { changeParts.append("\(attr) attr") }
            if text > 0 { changeParts.append("\(text) text") }
            parts.append("\(changeParts.joined(separator: "+")) updates")
        }

        if let newTexts = info["newTexts"] as? [String], !newTexts.isEmpty {
            let preview = newTexts.prefix(3).joined(separator: " | ")
            parts.append("new content: \(preview)")
        }

        if let title = info["titleNow"] as? String, !title.isEmpty {
            parts.append("title: \(title)")
        }

        return "DOM: \(mutations) mutations — \(parts.joined(separator: "; "))"
    }

    public struct JSEvalTimeout: Error {}

    ///
    /// whichever finishes first wins.
    ///
    private func evaluateJavaScriptBounded(_ js: String,timeout: TimeInterval = 10) async throws -> Any? {
        let box = ContinuationBox()
        // 同 MiniClawTabPool.withDeadOnTimeout：本类型是 @MainActor，handler 闭包会继承主 actor
        // 隔离，timer 若挂后台队列，超时触发时闭包在后台线程入口即被隔离校验拦下并 brk 崩溃。
        // JS 求值本身就在主线程，超时兜底改走主队列无额外成本。
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now()+timeout)
        timer.setEventHandler { box.finish(.failure(JSEvalTimeout())) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSResultBox,Error>) in
            box.cont = cont
            box.onFinish = { timer.cancel() }
            timer.resume()
            self.webView.evaluateJavaScript(js) { value,error in
                if let error { box.finish(.failure(error)) }
                else { box.finish(.success(value)) }
            }
        }.value
    }

    /// JS 求值结果的跨隔离传递盒：`evaluateJavaScript` 回调值为 `Any?`（非 Sendable），
    /// 装入标注 `@unchecked Sendable` 的盒以通过 Swift 6 发送检查；值本身由单侧独占传递，
    /// 不共享可变状态（与迁入前语义一致）。
    private struct JSResultBox: @unchecked Sendable {
        let value: Any?
    }

    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var cont: CheckedContinuation<JSResultBox,Error>?
        var onFinish: (() -> Void)?
        func finish(_ result: Result<Any?,Error>) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont; cont = nil
            let cleanup = onFinish; onFinish = nil
            lock.unlock()
            cleanup?()
            switch result {
            case .success(let v): c?.resume(returning: JSResultBox(value: v))
            case .failure(let e): c?.resume(throwing: e)
            }
        }
    }

    private func navigationMetadata() async -> String {
        let vp = currentViewport
        let url = webView.url?.absoluteString ?? currentURL
        let title = webView.title ?? pageTitle

        // Instrument + bound this JS eval. It runs at
        let metaStart = CFAbsoluteTimeGetCurrent()
        logger.info("[NavMeta] evalJS_start url=\(url.prefix(80))")
        var scrollX = 0,scrollY = 0,pageW = 0,pageH = 0
        do {
            if let js = try await evaluateJavaScriptBounded(
                "JSON.stringify({sx:window.scrollX,sy:window.scrollY,pw:document.documentElement.scrollWidth,ph:document.documentElement.scrollHeight})",
                timeout: 10
            ) as? String,
               let data = js.data(using: .utf8),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                scrollX = info["sx"] as? Int ?? 0
                scrollY = info["sy"] as? Int ?? 0
                pageW = info["pw"] as? Int ?? 0
                pageH = info["ph"] as? Int ?? 0
            }
            let ms = Int((CFAbsoluteTimeGetCurrent()-metaStart)*1000)
            logger.info("[NavMeta] evalJS_done elapsed=\(ms)ms url=\(url.prefix(80))")
        } catch is JSEvalTimeout {
            let ms = Int((CFAbsoluteTimeGetCurrent()-metaStart)*1000)
            logger.warning("[NavMeta] evalJS_TIMEOUT elapsed=\(ms)ms url=\(url.prefix(80)) — WebContent JS thread pinned; returning metadata without scroll/size. This is the backgrounded-hang chokepoint.")
        } catch {
            logger.warning("[NavMeta] evalJS_error \(error.localizedDescription) url=\(url.prefix(80))")
        }

        var lines: [String] = []
        lines.append("Navigated to \(url)")
        if !title.isEmpty { lines.append(" Title: \(title)") }
        lines.append(" Viewport: \(vp.width)x\(vp.height)")
        if pageW>0 || pageH>0 {
            lines.append(" Page size: \(pageW)x\(pageH)")
        }
        lines.append(" Scroll position: (\(scrollX), \(scrollY))")
        return lines.joined(separator: "\n")
    }

    private func navigate(to urlString: String?) async throws -> MiniClawActionResult {
        let navStart = CFAbsoluteTimeGetCurrent()

        guard let urlString,!urlString.isEmpty else {
            return .error("Missing 'url' parameter")
        }

        var normalized = urlString
        if !normalized.contains("://") {
            normalized = "https://\(normalized)"
        }

        guard let url = URL(string: normalized) else {
            return .error("Invalid URL: \(urlString)")
        }

        // Only allow HTTP(S) and miniclaw:// schemes for direct navigation
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "miniclaw"].contains(scheme) {
            return .error("Cannot navigate to \(scheme):// URLs. Only http://, https://, and miniclaw:// are supported.")
        }

        logger.info("[NavTiming] load_start url=\(url.absoluteString.prefix(100))")

        // it out of the 30-day retention sweep in MiniClawCookieBackup).
        if scheme == "http" || scheme == "https" {
            MiniClawCookieBackup.shared.noteVisit(url: url)
        }

        let request = URLRequest(url: url,cachePolicy: .reloadIgnoringLocalCacheData,timeoutInterval: Self.navigationTimeout)
        lastRequestedURL = url //
        loadError = nil // clear any prior failure overlay

        // 导航结束等待：三条出路，按优先级
        //   ① didFinish / didFail（正常回调，见 WKNavigationDelegate）
        //   ② document.readyState == "complete"（提前收网：主文档其实早已渲染完，
        //      却因持续第三方请求/长轮询永不发 didFinish → 白等整个超时预算）
        //   ③ navigationTimeout 兜底（内容可能不完整 → 结果里显式标注）
        let waitBox = NavWaitBox()
        navigationDidCommit = false
        isLoading = true
        webView.load(request)

        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.navigationProgressPollInterval*1_000_000_000))
                guard let self,!Task.isCancelled,self.navigationContinuation != nil else { return }
                // didCommit 之后才轮询：否则会读到上一页的 complete 而误判提前收网。
                guard self.navigationDidCommit else { continue }
                guard let state = try? await self.evaluateJavaScriptBounded("document.readyState",timeout: 3) as? String,
                      state == "complete" else { continue }
                if let cont = self.navigationContinuation {
                    self.navigationContinuation = nil
                    self.isLoading = false
                    cont.resume()
                }
                let ms = Int((CFAbsoluteTimeGetCurrent()-navStart)*1000)
                logger.info("[NavTiming] navigate_settled_by_readyState elapsed=\(ms)ms url=\(url.absoluteString.prefix(80))")
                return
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            self.navigationContinuation = continuation

            // Timeout
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.navigationTimeout*1_000_000_000))
                if let cont = self.navigationContinuation {
                    self.navigationContinuation = nil
                    self.isLoading = false
                    waitBox.timedOut = true
                    cont.resume() // Don't fail on timeout, page may be partially loaded
                    // Distinguish the two ways navigate
                    logger.warning("[NavTiming] navigate_TIMEOUT after \(Int(Self.navigationTimeout))s — no didFinish/didFail; url=\(url.absoluteString.prefix(80))")
                }
            }
        }
        progressTask.cancel()

        let navDoneMs = Int((CFAbsoluteTimeGetCurrent()-navStart)*1000)
        logger.info("[NavTiming] wait_returned elapsed=\(navDoneMs)ms url=\(url.absoluteString.prefix(100))")

        currentURL = webView.url?.absoluteString ?? normalized
        pageTitle = webView.title ?? ""
        isLoading = false

        var meta = await navigationMetadata()
        if waitBox.timedOut {
            // 超时 ≠ 成功：显式告知模型「内容可能不完整」，避免它把半个页面当成结论
            //（此前超时与正常完成返回完全相同的 success=true，模型无从分辨）。
            meta = String(localized: "browser_navigate_timeout_notice") + "\n" + meta
        }
        let totalMs = Int((CFAbsoluteTimeGetCurrent()-navStart)*1000)
        logger.info("[NavTiming] total elapsed=\(totalMs)ms url=\(url.absoluteString.prefix(100))")
        return MiniClawActionResult(text: meta)
    }

    private static let screenshotsDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("browser_screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        return dir
    }()

    private static let fullPageMaxHeight: CGFloat = 32_768

    private func screenshot(fullPage: Bool = false) async throws -> MiniClawActionResult {
        let ssStart = CFAbsoluteTimeGetCurrent()
        logger.info("[ScreenshotTiming] enter fullPage=\(fullPage)")
        let viewportSize = CGSize(width: CGFloat(currentViewport.width),
                                  height: CGFloat(currentViewport.height))
        let savedFrame = webView.frame

        var originalPageHeight: CGFloat = 0
        var truncated = false
        var captureHeight = viewportSize.height
        if fullPage {
            if let h = try? await webView.evaluateJavaScript(
                "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
            ) as? NSNumber,h.doubleValue>0 {
                originalPageHeight = CGFloat(h.doubleValue)
                captureHeight = max(viewportSize.height,originalPageHeight)
                if captureHeight>Self.fullPageMaxHeight {
                    captureHeight = Self.fullPageMaxHeight
                    truncated = true
                }
            } else {
                logger.warning("full_page screenshot: scrollHeight unavailable; falling back to viewport height")
            }
        }

        let targetSize = CGSize(width: viewportSize.width,height: captureHeight)
        let shouldResize = abs(savedFrame.size.width-targetSize.width)>0.5 ||
                           abs(savedFrame.size.height-targetSize.height)>0.5
        if shouldResize {
            webView.frame = CGRect(origin: savedFrame.origin,size: targetSize)
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
        }
        defer {
            if shouldResize {
                restoreViewportFrame()
            }
        }

        if fullPage {
            let lazyEager = """
            (async () => {
              const imgs = document.querySelectorAll('img[loading="lazy"]');
              imgs.forEach(i => { i.loading = 'eager'; });
              await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
              return imgs.length;
            })()
            """
            _ = try? await webView.evaluateJavaScript(lazyEager)
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: targetSize)
        let takeSnapStart = CFAbsoluteTimeGetCurrent()
        // 有界快照：页面卡死时 takeSnapshot 的 completion 可能永不回调，无界等待会让本动作
        // 一直挂到 TabPool 的 300s 看门狗。到点明确报错，模型可据此换站点而不是干等。
        guard let snap = await captureSnapshotBounded(config,quality: 0.8) else {
            return .error("Screenshot timed out after \(Int(Self.snapshotTimeout))s — the page's WebContent process appears wedged; try another source or retry later.")
        }
        let takeSnapMs = Int((CFAbsoluteTimeGetCurrent() - takeSnapStart) * 1000)
        logger.info("[ScreenshotTiming] takeSnapshot elapsed=\(takeSnapMs)ms")
        lastScreenshot = UIImage(data: snap.jpeg)

        let jpegData = snap.jpeg
        let filename = "screenshot_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let fileURL = Self.screenshotsDir.appendingPathComponent(filename)
        try jpegData.write(to: fileURL)

        let base64 = jpegData.base64EncodedString()
        let size = snap.size
        let totalSsMs = Int((CFAbsoluteTimeGetCurrent() - ssStart) * 1000)
        logger.info("[ScreenshotTiming] total elapsed=\(totalSsMs)ms \(Int(size.width))x\(Int(size.height)) \(jpegData.count) bytes fullPage=\(fullPage) truncated=\(truncated)")

        let meta = await viewportMetadata(
            imageSize: size,
            fileSize: jpegData.count,
            fullPage: fullPage,
            truncated: truncated,
            originalHeight: Int(originalPageHeight)
        )

        return MiniClawActionResult(
            text: meta,
            base64Image: base64,
            imageFilePath: fileURL.path
        )
    }

    private func viewportMetadata(
        imageSize: CGSize,
        fileSize: Int,
        fullPage: Bool = false,
        truncated: Bool = false,
        originalHeight: Int = 0
    ) async -> String {
        let vp = currentViewport
        let url = webView.url?.absoluteString ?? currentURL
        let title = webView.title ?? pageTitle

        var scrollX = 0, scrollY = 0, pageW = 0, pageH = 0
        if let js = try? await webView.evaluateJavaScript(
            "JSON.stringify({sx:window.scrollX,sy:window.scrollY,pw:document.documentElement.scrollWidth,ph:document.documentElement.scrollHeight})"
        ) as? String,
           let data = js.data(using: .utf8),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            scrollX = info["sx"] as? Int ?? 0
            scrollY = info["sy"] as? Int ?? 0
            pageW = info["pw"] as? Int ?? 0
            pageH = info["ph"] as? Int ?? 0
        }

        var lines: [String] = []
        lines.append("Screenshot captured")
        lines.append(" URL: \(url)")
        if !title.isEmpty { lines.append(" Title: \(title)") }
        lines.append(" Image: \(Int(imageSize.width))x\(Int(imageSize.height)) (\(fileSize / 1024)KB)")
        lines.append(" Viewport: \(vp.width)x\(vp.height)")
        if pageW > 0 || pageH > 0 {
            lines.append(" Page size: \(pageW)x\(pageH)")
        }
        lines.append(" Scroll position: (\(scrollX), \(scrollY))")
        if fullPage {
            lines.append(" Full page: true")
            if truncated && originalHeight > 0 {
                lines.append(" Truncated: true (original height \(originalHeight)px capped at \(Int(Self.fullPageMaxHeight))px)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func click(selector: String?, x: Int?, y: Int?) async throws -> MiniClawActionResult {
        let js: String
        if let selector {
            js = BrowserUseJS.click(selector: selector)
        } else if let x, let y {
            js = BrowserUseJS.clickCoordinate(x: x, y: y)
        } else {
            return .error("click requires 'selector' or 'coordinate_x'/'coordinate_y'")
        }
        return try await evaluateAndReturn(js)
    }

    private func type(selector: String?, text: String?) async throws -> MiniClawActionResult {
        guard let selector else { return .error("type requires 'selector'") }
        guard let text else { return .error("type requires 'text'") }
        let result = try await evaluateAndReturn(BrowserUseJS.type(selector: selector, text: text))
        // The type just focused a web input,
        releaseWebViewKeyboard()
        return result
    }

    private func getText(selector: String?) async throws -> MiniClawActionResult {
        let js = BrowserUseJS.getText(selector: selector)
        do {
            let raw = try await webView.evaluateJavaScript(js)
            if let str = raw as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let debug = json["debug"] as? [String: Any] {
                    print("[getText] ===== DEBUG =====")
                    print("[getText] readyState: \(debug["readyState"] ?? "?")")
                    print("[getText] url: \(debug["url"] ?? "?")")
                    print("[getText] title: \(debug["title"] ?? "?")")
                    print("[getText] innerTextLength: \(debug["innerTextLength"] ?? "?")")
                    print("[getText] textContentLength: \(debug["textContentLength"] ?? "?")")
                    print("[getText] scrollHeight: \(debug["scrollHeight"] ?? "?"), viewportHeight: \(debug["viewportHeight"] ?? "?")")
                    print("[getText] domElementCount: \(debug["domElementCount"] ?? "?")")
                    print("[getText] visible/hidden sample: \(debug["visibleSample"] ?? "?")/\(debug["hiddenSample"] ?? "?")")
                    print("[getText] innerText preview: \(debug["innerTextPreview"] ?? "")")
                    print("[getText] textContent preview: \(debug["textContentPreview"] ?? "")")
                    print("[getText] ===================")
                }
                if let error = json["error"] as? String {
                    return .error(error)
                }
                return MiniClawActionResult(text: Self.formatJSONResult(json))
            }
            return MiniClawActionResult(text: String(describing: raw ?? "null"))
        } catch {
            return .error("JavaScript error: \(error.localizedDescription)")
        }
    }

    /// 2026-08-12:动态渲染页(SPA/热榜)首次 innerText 只有 SSR 首屏(常只有十几字符),
    /// 先短轮询等正文稳定再提取,避免 get_readable 只拿到 meta/首屏一条。
    private func waitForReadableSettle() async {
        let probe = "document.body ? document.body.innerText.length : 0"
        var last = 0
        var stableCount = 0
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let value = (try? await webView.evaluateJavaScript(probe)) as? NSNumber
            let len = value?.intValue ?? 0
            if len > 0 && len == last {
                stableCount += 1
            } else {
                stableCount = 0
            }
            if stableCount >= 2 { break } // 连续两次采样稳定(约 1.2s)
            last = len
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func getReadable() async throws -> MiniClawActionResult {
        await waitForReadableSettle()
        let js = BrowserUseJS.getReadable()
        do {
            let raw = try await webView.evaluateJavaScript(js)
            if let str = raw as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let debug = json["debug"] {
                    print("[getReadable] debug: \(debug)")
                }
                if let error = json["error"] as? String {
                    return .error(error)
                }
                return MiniClawActionResult(text: Self.formatJSONResult(json))
            }
            return MiniClawActionResult(text: String(describing: raw ?? "null"))
        } catch {
            return .error("JavaScript error: \(error.localizedDescription)")
        }
    }

    private func scroll(selector: String?, direction: MiniClawActionInput.ScrollDirection?, amount: Int?) async throws -> MiniClawActionResult {
        let dir = direction ?? .down
        let px = amount ?? 500
        let js = BrowserUseJS.scroll(direction: dir, amount: px, selector: selector)
        do {
            let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            if let str = raw as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    return .error(error)
                }
                return MiniClawActionResult(text: Self.formatJSONResult(json))
            }
            return MiniClawActionResult(text: String(describing: raw ?? "null"))
        } catch {
            return .error("JavaScript error: \(error.localizedDescription)")
        }
    }

    private func scrollAndCollect(selector: String?, direction: MiniClawActionInput.ScrollDirection?, amount: Int?, scrollCount: Int?, itemSelector: String?) async throws -> MiniClawActionResult {
        let dir = direction ?? .down
        let px = amount ?? 500
        let count = min(scrollCount ?? 10, 20)
        let js = BrowserUseJS.scrollAndCollect(direction: dir, amount: px, scrollCount: count, selector: selector, itemSelector: itemSelector)
        do {
            let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            if let str = raw as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    return .error(error)
                }
                return MiniClawActionResult(text: Self.formatScrollAndCollectResult(json))
            }
            return MiniClawActionResult(text: String(describing: raw ?? "null"))
        } catch {
            return .error("JavaScript error: \(error.localizedDescription)")
        }
    }

    private static func formatScrollAndCollectResult(_ json: [String: Any]) -> String {
        let collected = json["itemsCollected"] as? Int ?? 0
        let totalSeen = json["totalItemsSeen"] as? Int ?? 0
        let steps = json["scrollSteps"] as? Int ?? 0
        let scrollPos = json["scrollPosition"] as? Int ?? 0
        let selector = json["itemSelector"] as? String ?? "?"

        var lines: [String] = []
        lines.append("Collected \(collected) unique items (\(totalSeen) total seen) over \(steps) scroll steps")
        lines.append(" Item selector: \(selector)")
        lines.append(" Final scroll position: \(scrollPos)")
        lines.append("")

        if let items = json["items"] as? [String] {
            for (i, item) in items.enumerated() {
                let compact = item.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                lines.append("[\(i + 1)] \(compact)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func getPageInfo() async throws -> MiniClawActionResult {
        return try await evaluateAndReturn(BrowserUseJS.getPageInfo())
    }

    private func getCookies(keywords: [String]?, fuzzy: Bool) async -> MiniClawActionResult {
        guard let pageURL = webView.url else {
            return .error("No page is currently loaded")
        }

        let host = pageURL.host ?? ""
        let rootDomain: String
        let parts = host.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            rootDomain = parts.suffix(2).joined(separator: ".")
        } else {
            rootDomain = host
        }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let allCookies = await store.allCookies()

        var filtered = allCookies.filter { cookie in
            let cookieDomain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return cookieDomain == host || cookieDomain == rootDomain || host.hasSuffix("." + cookieDomain)
        }

        if let keywords, !keywords.isEmpty {
            let lowerKeywords = keywords.map { $0.lowercased() }
            filtered = filtered.filter { cookie in
                let name = cookie.name.lowercased()
                if fuzzy {
                    return lowerKeywords.allSatisfy { name.contains($0) }
                } else {
                    return lowerKeywords.contains(name)
                }
            }
        }

        if filtered.isEmpty {
            let msg: String
            if let keywords, !keywords.isEmpty {
                msg = "No cookies found for \(host) matching keywords=\"\(keywords.joined(separator: " "))\" (fuzzy=\(fuzzy))."
            } else {
                msg = "No cookies found for \(host)."
            }
            return MiniClawActionResult(text: msg, pageURL: pageURL.absoluteString)
        }

        func sanitizeEnvName(_ name: String) -> String {
            let upper = name.uppercased()
            var result = ""
            for ch in upper {
                if ch.isLetter || ch.isNumber || ch == "_" {
                    result.append(ch)
                } else {
                    result.append("_")
                }
            }
            return "COOKIE_\(result)"
        }

        func shellEscape(_ value: String) -> String {
            return value.replacingOccurrences(of: "'", with: "'\\''")
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let safeDomain = rootDomain.replacingOccurrences(of: ".", with: "_")
        let envFilename = "env_cookies_\(safeDomain)_\(timestamp).sh"
        let offloadsDir = RootfsManager.shared.dataPath
            .appendingPathComponent("var/miniclaw/offloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: offloadsDir, withIntermediateDirectories: true)
        let envFileURL = offloadsDir.appendingPathComponent(envFilename)
        let envGuestPath = "/var/miniclaw/offloads/\(envFilename)"

        var envLines: [String] = ["#!/bin/sh"]
        var cookieHeaderParts: [String] = []
        var varEntries: [(originalName: String, envName: String, valueLength: Int)] = []

        for cookie in filtered {
            let envName = sanitizeEnvName(cookie.name)
            let escaped = shellEscape(cookie.value)
            envLines.append("export \(envName)='\(escaped)'")
            cookieHeaderParts.append("\(cookie.name)=\(cookie.value)")
            varEntries.append((originalName: cookie.name, envName: envName, valueLength: cookie.value.count))
        }

        let combinedHeader = shellEscape(cookieHeaderParts.joined(separator: "; "))
        envLines.append("export BROWSER_COOKIE_HEADER='\(combinedHeader)'")

        let envContent = envLines.joined(separator: "\n") + "\n"
        try? envContent.write(to: envFileURL, atomically: true, encoding: .utf8)

        var lines: [String] = []
        if let keywords, !keywords.isEmpty {
            lines.append("Retrieved \(filtered.count) cookie(s) for current site \(host) with filter keywords=\"\(keywords.joined(separator: " "))\" (fuzzy=\(fuzzy)).")
        } else {
            lines.append("Retrieved \(filtered.count) cookie(s) for current site \(host).")
        }
        lines.append("")
        lines.append("Stored env file:")
        lines.append(" \(envGuestPath)")
        lines.append("")
        lines.append("To use them in shell commands:")
        lines.append(" . \(envGuestPath) && command")
        lines.append("")
        lines.append("Available cookie variables:")
        for entry in varEntries {
            lines.append("- cookie: \(entry.originalName)")
            lines.append(" env: \(entry.envName)")
            lines.append(" value_length: \(entry.valueLength)")
            lines.append("")
        }
        lines.append("You may define your own alias variables when needed for compatibility, for example:")
        lines.append(" . \(envGuestPath) && MY_VAR=\"$\(varEntries.first?.envName ?? "COOKIE_NAME")\" && command")
        lines.append("")
        lines.append("The raw cookie values are stored only in the env file and are not included in this tool response.")

        return MiniClawActionResult(text: lines.joined(separator: "\n"), pageURL: pageURL.absoluteString)
    }

    private func setCookies(_ cookies: [[String: Any]]?) async -> MiniClawActionResult {
        guard let pageURL = webView.url else {
            return .error("set_cookies: no page is loaded (navigate first)")
        }
        guard let cookies else {
            return .error("set_cookies: 'cookies' must be a JSON array of cookie objects "
                + "(e.g. [{\"name\":\"foo\",\"value\":\"bar\"}]). It was missing or could not be "
                + "parsed — if you passed it as a string, ensure it is valid JSON; from the CLI "
                + "prefer --cookies-file <path> to avoid shell escaping.")
        }
        guard !cookies.isEmpty else {
            return .error("set_cookies: 'cookies' array is empty — provide at least one {name, value} object.")
        }

        let defaultDomain = pageURL.host ?? ""
        let store = webView.configuration.websiteDataStore.httpCookieStore

        var setNames: [String] = []
        var domainsTouched = Set<String>()
        var failures: [String] = []

        for raw in cookies {
            let str = { (aliases: [String]) in Self.cookieString(raw, aliases) }
            let bool = { (aliases: [String]) in Self.cookieBool(raw, aliases) }

            guard let name = str(["name"]), !name.isEmpty,
                  let value = str(["value"]) else {
                failures.append("(missing name/value)")
                continue
            }
            let domain = str(["domain"]).flatMap { $0.isEmpty ? nil : $0 } ?? defaultDomain
            let path = str(["path"]).flatMap { $0.isEmpty ? nil : $0 } ?? "/"

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if bool(["secure"]) == true {
                properties[.secure] = "TRUE"
            }
            if bool(["http_only", "httpOnly"]) == true {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            if let expires = Self.cookieNumber(raw, ["expires", "expirationDate"]), expires > 0 {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            }
            _ = str(["sameSite", "same_site"])

            guard let cookie = HTTPCookie(properties: properties) else {
                failures.append(name)
                continue
            }
            await store.setCookie(cookie)
            setNames.append(name)
            domainsTouched.insert(domain)
        }

        if setNames.isEmpty {
            return .error("set_cookies: no cookies were set (every entry was invalid: \(failures.joined(separator: ", ")))")
        }

        let domainLabel = domainsTouched.count == 1
            ? (domainsTouched.first ?? defaultDomain)
            : domainsTouched.sorted().joined(separator: ", ")
        var text = "Set \(setNames.count) cookie(s) for \(domainLabel): \(setNames.joined(separator: ", "))"
        if !failures.isEmpty {
            text += "\nSkipped \(failures.count) invalid entry(ies): \(failures.joined(separator: ", "))"
        }
        return MiniClawActionResult(text: text, pageURL: pageURL.absoluteString)
    }

    private static func cookieValue(_ dict: [String: Any], _ aliases: [String]) -> Any? {
        for key in aliases {
            if let v = dict[key] { return v }
        }
        let lowered = Set(aliases.map { $0.lowercased() })
        for (k, v) in dict where lowered.contains(k.lowercased()) {
            return v
        }
        return nil
    }

    private static func cookieString(_ dict: [String: Any], _ aliases: [String]) -> String? {
        switch cookieValue(dict, aliases) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func cookieBool(_ dict: [String: Any], _ aliases: [String]) -> Bool? {
        switch cookieValue(dict, aliases) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    private static func cookieNumber(_ dict: [String: Any], _ aliases: [String]) -> Double? {
        switch cookieValue(dict, aliases) {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private func executeJS(script: String?) async throws -> MiniClawActionResult {
        guard let script, !script.isEmpty else {
            return .error("execute_js requires 'script'")
        }
        // 1. Wraps the script body in an async function — `await` is valid
        // 2. Automatically resolves returned Promises before delivering the result
        // 3. Supports top-level `return` without an explicit IIFE wrapper
        do {
            let result = try await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
            return MiniClawActionResult(text: Self.stringifyJSReturn(result))
        } catch {
            let nsError = error as NSError
            let detail = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? error.localizedDescription
            return .error("JavaScript error: \(detail)")
        }
    }

    private func waitForDomStable(timeout: Int?) async throws -> MiniClawActionResult {
        let timeoutSec = Double(timeout ?? 10)
        let pollInterval: UInt64 = 500_000_000 // 0.5s in nanoseconds
        let stableThreshold = 3 // consecutive stable readings needed

        let setupJS = """
        if (!window.__domStableObserver) {
            window.__domStableCounter = 0;
            window.__domStableObserver = new MutationObserver(function(mutations) {
                for (var i = 0; i < mutations.length; i++) {
                    window.__domStableCounter += mutations[i].addedNodes.length
                        + mutations[i].removedNodes.length
                        + (mutations[i].type === 'attributes' ? 1 : 0)
                        + (mutations[i].type === 'characterData' ? 1 : 0);
                }
            });
            window.__domStableObserver.observe(document.documentElement, {
                childList: true, subtree: true, attributes: true, characterData: true
            });
        }
        window.__domStableCounter = 0;
        return 'ok';
        """
        _ = try await webView.callAsyncJavaScript(setupJS,arguments: [:],contentWorld: .page)

        let startTime = CFAbsoluteTimeGetCurrent()
        var previousCount = Int.max
        var stableRuns = 0
        var samples: [(elapsed: Double,count: Int)] = []

        while true {
            try await Task.sleep(nanoseconds: pollInterval)

            let elapsed = CFAbsoluteTimeGetCurrent()-startTime
            if elapsed >= timeoutSec {
                _ = try? await webView.callAsyncJavaScript(
                    "if (window.__domStableObserver) { window.__domStableObserver.disconnect(); window.__domStableObserver = null; } return 'ok';",
                    arguments: [:],contentWorld: .page
                )
                let totalChanges = samples.map(\.count).reduce(0,+)
                return MiniClawActionResult(
                    text: "DOM wait timed out after \(String(format: "%.1f", timeoutSec))s "
                        + "(still changing, \(totalChanges) total mutations in \(samples.count) samples)"
                )
            }

            let readJS = "var c = window.__domStableCounter || 0; window.__domStableCounter = 0; return c;"
            let count: Int
            do {
                let result = try await webView.callAsyncJavaScript(readJS,arguments: [:],contentWorld: .page)
                if let n = result as? Int {
                    count = n
                } else if let n = result as? Double {
                    count = Int(n)
                } else {
                    count = 0
                }
            } catch {
                return MiniClawActionResult(
                    text: "DOM stable (page context changed after \(String(format: "%.1f", elapsed))s)"
                )
            }

            samples.append((elapsed: elapsed,count: count))

            if count <= previousCount {
                stableRuns += 1
            } else {
                stableRuns = 0
            }
            previousCount = count

            if stableRuns >= stableThreshold && count == 0 {
                _ = try? await webView.callAsyncJavaScript(
                    "if (window.__domStableObserver) { window.__domStableObserver.disconnect(); window.__domStableObserver = null; } return 'ok';",
                    arguments: [:],contentWorld: .page
                )
                let totalChanges = samples.map(\.count).reduce(0,+)
                return MiniClawActionResult(
                    text: "DOM stable after \(String(format: "%.1f", elapsed))s "
                        + "(\(totalChanges) total mutations settled over \(samples.count) samples)"
                )
            }

            if stableRuns >= stableThreshold {
                _ = try? await webView.callAsyncJavaScript(
                    "if (window.__domStableObserver) { window.__domStableObserver.disconnect(); window.__domStableObserver = null; } return 'ok';",
                    arguments: [:],contentWorld: .page
                )
                let totalChanges = samples.map(\.count).reduce(0,+)
                return MiniClawActionResult(
                    text: "DOM stable after \(String(format: "%.1f", elapsed))s "
                        + "(\(totalChanges) total mutations, gradient settled at \(count)/interval over \(samples.count) samples)"
                )
            }
        }
    }

    private func findElements(selector: String?) async throws -> MiniClawActionResult {
        guard let selector else { return .error("find_elements requires 'selector'") }
        return try await evaluateAndReturn(BrowserUseJS.findElements(selector: selector))
    }

    private func hover(selector: String?) async throws -> MiniClawActionResult {
        guard let selector else { return .error("hover requires 'selector'") }
        return try await evaluateAndReturn(BrowserUseJS.hover(selector: selector))
    }

    private func getBackbone(maxDepth: Int?) async throws -> MiniClawActionResult {
        let depth = maxDepth ?? 5
        let js = BrowserUseJS.getBackbone(maxDepth: depth)
        do {
            let result = try await webView.evaluateJavaScript(js)
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("Failed to parse backbone result")
            }
            if let error = json["error"] as? String {
                return .error(error)
            }
            return MiniClawActionResult(text: Self.formatBackboneResult(json))
        } catch {
            return .error("JavaScript error: \(error.localizedDescription)")
        }
    }

    private static func formatBackboneResult(_ json: [String: Any]) -> String {
        let nodeCount = json["nodeCount"] as? Int ?? 0
        let depth = json["depth"] as? Int ?? 0
        let merged = json["merged"] as? Int ?? 0
        var lines: [String] = []
        lines.append("Page backbone: \(nodeCount) nodes, depth \(depth), \(merged) merged")

        if let backbone = json["backbone"] as? [[String: Any]] {
            for node in backbone {
                formatBackboneNode(node,indent: 0,lines: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatBackboneNode(_ node: [String: Any],indent: Int,lines: inout [String]) {
        let pad = String(repeating: " ", count: indent)
        let tag = node["tag"] as? String ?? "?"
        let sel = node["sel"] as? String ?? ""
        let rect = node["rect"] as? String ?? ""

        var header = "\(pad)<\(tag)>"
        if let id = node["id"] as? String, !id.isEmpty { header += " #\(id)" }
        if let cls = node["cls"] as? String, !cls.isEmpty { header += " .\(cls.replacingOccurrences(of: " ", with: "."))" }
        if let role = node["role"] as? String { header += " [\(role)]" }
        header += " | \(sel) | \(rect)"
        lines.append(header)

        if let text = node["text"] as? String, !text.isEmpty {
            lines.append("\(pad) \"\(text)\"")
        }
        if let href = node["href"] as? String, !href.isEmpty {
            lines.append("\(pad) → \(href)")
        }
        if let img = node["img"] as? String, !img.isEmpty {
            lines.append("\(pad) img: \(img)")
        }
        if let input = node["input"] as? String, !input.isEmpty {
            lines.append("\(pad) input: \(input)")
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                formatBackboneNode(child,indent: indent+1,lines: &lines)
            }
        }
    }

    private func fetch(url urlString: String?) async throws -> MiniClawActionResult {
        guard let urlString,!urlString.isEmpty else {
            return .error("fetch requires 'url' parameter")
        }

        logger.info("Fetching resource: \(urlString)")

        let js = """
        (async function() {
            try {
                const resp = await fetch(\(Self.jsStringLiteral(urlString)));
                const buf = await resp.arrayBuffer();
                const bytes = new Uint8Array(buf);
                let binary = '';
                for (let i = 0; i<bytes.length; i++) binary += String.fromCharCode(bytes[i]);
                const b64 = btoa(binary);
                const ct = resp.headers.get('content-type') || '';
                const cd = resp.headers.get('content-disposition') || '';
                return JSON.stringify({
                    base64: b64,
                    contentType: ct,
                    contentDisposition: cd,
                    status: resp.status,
                    url: resp.url,
                    size: bytes.length
                });
            } catch(e) {
                return JSON.stringify({error: e.message});
            }
        })()
        """

        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
        } catch {
            return .error("JavaScript fetch failed: \(error.localizedDescription)")
        }

        guard let jsonStr = rawResult as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return .error("Failed to parse fetch result")
        }

        if let error = json["error"] as? String {
            return .error("Fetch failed: \(error)")
        }

        guard let base64 = json["base64"] as? String,
              let data = Data(base64Encoded: base64) else {
            return .error("Failed to decode fetched data")
        }

        let contentType = json["contentType"] as? String ?? ""
        let contentDisposition = json["contentDisposition"] as? String ?? ""
        let status = json["status"] as? Int ?? 0
        let finalURL = json["url"] as? String ?? urlString
        let size = json["size"] as? Int ?? data.count

        let filename: String
        if let cdFilename = Self.parseContentDispositionFilename(contentDisposition) {
            let timestamp = Int(Date().timeIntervalSince1970)
            filename = "\(timestamp)_\(cdFilename)"
        } else if let urlObj = URL(string: finalURL), !urlObj.lastPathComponent.isEmpty, urlObj.lastPathComponent != "/" {
            let timestamp = Int(Date().timeIntervalSince1970)
            filename = "\(timestamp)_\(urlObj.lastPathComponent)"
        } else {
            let ext = Self.extensionForMimeType(contentType)
            filename = "fetch_\(Int(Date().timeIntervalSince1970)).\(ext)"
        }

        var lines: [String] = []
        lines.append("Fetched \(finalURL)")
        lines.append(" Status: \(status)")
        lines.append(" Content-Type: \(contentType)")
        lines.append(" Size: \(Self.formatBytes(size))")
        lines.append(" Filename: \(filename)")

        return MiniClawActionResult(
            text: lines.joined(separator: "\n"),
            fetchedFileData: data,
            fetchedFileName: filename
        )
    }

    private static func jsStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func parseContentDispositionFilename(_ cd: String) -> String? {
        guard !cd.isEmpty else { return nil }
        let patterns = ["filename\\*=(?:UTF-8''|utf-8'')([^;\\s]+)", "filename=\"([^\"]+)\"", "filename=([^;\\s]+)"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: cd, range: NSRange(cd.startIndex..., in: cd)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: cd) {
                let name = String(cd[range]).removingPercentEncoding ?? String(cd[range])
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private static func extensionForMimeType(_ mime: String) -> String {
        let lower = mime.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        switch lower {
        case "text/html": return "html"
        case "text/plain": return "txt"
        case "text/css": return "css"
        case "text/csv": return "csv"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "application/zip": return "zip"
        case "application/gzip": return "gz"
        default: return "bin"
        }
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    @discardableResult
    public func setUserAgent(profile: MiniClawUAProfile?, customString: String? = nil) -> MiniClawActionResult {
        let newProfile = profile ?? .mobileSafari

        currentProfile = newProfile
        let vp = currentViewport
        let newView = Self.makeWebView(profile: newProfile, customString: customString,
                                       viewportWidth: vp.width, viewportHeight: vp.height)
        newView.navigationDelegate = self
        newView.uiDelegate = self

        let oldURL = webView.url

        webView = newView

        if let url = oldURL {
            webView.load(URLRequest(url: url))
        }

        return MiniClawActionResult(text: "Switched to \(newProfile.rawValue) (\(vp.width)x\(vp.height))")
    }

    public func setViewport(width: Int, height: Int,
                     profile: MiniClawUAProfile, customUA: String?) {
        currentProfile = profile
        currentViewport = (width, height)

        let newView = Self.makeWebView(profile: profile, customString: customUA,
                                       viewportWidth: width, viewportHeight: height)
        newView.navigationDelegate = self
        newView.uiDelegate = self

        let oldURL = webView.url
        webView = newView
        if let url = oldURL {
            webView.load(URLRequest(url: url))
        }
    }

    ///
    ///
    @MainActor
    public func restoreViewportFrame() {
        // This runs when the browser sheet
        releaseWebViewKeyboard()
        let target = CGSize(width: CGFloat(currentViewport.width),
                            height: CGFloat(currentViewport.height))
        let current = webView.frame.size
        let needsResize = abs(current.width - target.width) > 0.5 ||
                          abs(current.height - target.height) > 0.5
        guard needsResize else { return }

        webView.frame = CGRect(origin: webView.frame.origin, size: target)
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'));", completionHandler: nil)
        logger.info("restoreViewportFrame: \(Int(current.width))x\(Int(current.height)) -> \(currentViewport.width)x\(currentViewport.height)")
    }

    /// Release any keyboard the offscreen
    @MainActor
    public func releaseWebViewKeyboard() {
        webView.evaluateJavaScript(
            "if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); }",
            completionHandler: nil)
        webView.endEditing(true)
    }

    public func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    public func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    public func reload() {
        webView.reload()
    }

    public func stopLoading() {
        webView.stopLoading()
        isLoading = false
    }

    public func loadURL(_ urlString: String) {
        var normalized = urlString
        if !normalized.contains("://") {
            normalized = "https://\(normalized)"
        }
        guard let url = URL(string: normalized) else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.navigationTimeout)
        lastRequestedURL = url //
        loadError = nil
        webView.load(request)
        isLoading = true
    }

    /// Retry the last requested URL after a failure.
    public func retryFailedLoad() {
        loadError = nil
        if let url = lastRequestedURL {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.navigationTimeout)
            webView.load(request)
            isLoading = true
        } else {
            webView.reload()
        }
    }

    private func evaluateAndReturn(_ js: String) async throws -> MiniClawActionResult {
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String {
                if let data = str.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let error = json["error"] as? String {
                        return .error(error)
                    }
                    return MiniClawActionResult(text: Self.formatJSONResult(json))
                }
                return MiniClawActionResult(text: str)
            }
            return MiniClawActionResult(text: String(describing: result ?? "null"))
        } catch {
            let nsError = error as NSError
            let detail = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? error.localizedDescription
            return .error("JavaScript error: \(detail)")
        }
    }

    ///
    /// re-ran it through `formatJSONResult` and produced `" key: value\n"`
    /// `"{\n key = value;\n}"` plist-ish description. Either way the
    ///
    /// - `String` → returned verbatim. A script that did
    /// `return JSON.stringify(obj)` gets its exact string back.
    /// - JSON-serialisable object/array (`NSDictionary` / `NSArray` /
    /// `NSNumber` / `NSNull`) → serialised with `JSONSerialization`
    /// (with `.fragmentsAllowed` so naked numbers/booleans round-trip
    /// to `"42"` / `"true"` / `"null"` rather than NSNumber's
    /// `String(describing:)` "1"/"0").
    /// - Anything else (extremely rare — `callAsyncJavaScript` only
    /// returns JSON-like types per WebKit's docs) → fall back to
    /// `String(describing:)` so at least something is printed.
    ///
    public static func stringifyJSReturn(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let str = value as? String { return str }
        let sanitized = sanitizeForJSON(value)
        if JSONSerialization.isValidJSONObject(sanitized) {
            if let data = try? JSONSerialization.data(withJSONObject: sanitized, options: []),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: sanitized, options: [.fragmentsAllowed]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    private static func sanitizeForJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = sanitizeForJSON(v) }
            return out
        }
        if let array = value as? [Any] {
            return array.map { sanitizeForJSON($0) }
        }
        if let number = value as? NSNumber {
            let typeID = CFNumberGetType(number as CFNumber)
            if typeID == .float32Type || typeID == .float64Type || typeID == .cgFloatType {
                let d = number.doubleValue
                if !d.isFinite { return NSNull() }
            }
            return number
        }
        return value
    }

    private static func formatJSONResult(_ json: [String: Any]) -> String {
        var lines: [String] = []

        if json["clicked"] as? Bool == true {
            let tag = json["tag"] as? String ?? "?"
            lines.append("Clicked <\(tag)>")
            if let x = json["x"], let y = json["y"] {
                lines.append(" Position: (\(x), \(y))")
            }
            if let text = json["text"] as? String, !text.isEmpty {
                lines.append(" Text: \(text.prefix(200))")
            }
        }
        else if json["typed"] as? Bool == true {
            let sel = json["selector"] as? String ?? "?"
            let len = json["length"] as? Int ?? 0
            lines.append("Typed \(len) chars into \(sel)")
        }
        else if json["scrolled"] as? Bool == true {
            let dir = json["direction"] as? String ?? "?"
            let amt = json["amount"] as? Int ?? 0
            lines.append("Scrolled \(dir) \(amt)px")
            if let y = json["scrollY"] { lines.append(" Scroll Y: \(y)") }
            if let h = json["scrollHeight"] { lines.append(" Page height: \(h)") }
            if let vh = json["viewportHeight"] { lines.append(" Viewport height: \(vh)") }
        }
        else if let sel = json["scrolledTo"] as? String {
            let tag = json["tag"] as? String ?? "?"
            lines.append("Scrolled to <\(tag)> (\(sel))")
        }
        else if json["hovered"] as? Bool == true {
            let tag = json["tag"] as? String ?? "?"
            lines.append("Hovered <\(tag)>")
            if let text = json["text"] as? String, !text.isEmpty {
                lines.append(" Text: \(text.prefix(200))")
            }
        }
        else if let text = json["text"] as? String, json["length"] != nil {
            if let title = json["title"] as? String, !title.isEmpty {
                lines.append("Title: \(title)")
            }
            let len = json["length"] as? Int ?? text.count
            lines.append("Text (\(len) chars):")
            lines.append(String(text.prefix(10000)))
        }
        else if let count = json["count"] as? Int, let elements = json["elements"] as? [[String: Any]] {
            let shown = json["shown"] as? Int ?? elements.count
            lines.append("Found \(count) element(s) (showing \(shown)):")
            for el in elements {
                let idx = el["index"] as? Int ?? 0
                let tag = el["tag"] as? String ?? "?"
                let text = (el["text"] as? String ?? "").prefix(80)
                var desc = " [\(idx)] <\(tag)>"
                if let id = el["id"] as? String, !id.isEmpty { desc += " #\(id)" }
                if !text.isEmpty { desc += " \"\(text)\"" }
                if let href = el["href"] as? String, !href.isEmpty { desc += " → \(href)" }
                lines.append(desc)
            }
        }
        else {
            for (key, value) in json.sorted(by: { $0.key < $1.key }) {
                lines.append(" \(key): \(value)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

public final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    public func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

extension MiniClawBrowserEngine: WKUIDelegate {
    @MainActor
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        if let handler = self.newWindowHandler {
            return handler(configuration, url)
        }
        webView.load(navigationAction.request)
        return nil
    }

    public nonisolated func webViewDidClose(_ webView: WKWebView) {
        Task { @MainActor in
            self.closeHandler?(webView)
        }
    }
}

extension MiniClawBrowserEngine: @preconcurrency WKDownloadDelegate {
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        Task { @MainActor in
            guard let sid = self.sessionIdProvider?(), !sid.isEmpty else {
                logger.warning("Download rejected — no session id to resolve a destination")
                self.inflightDownloads.removeValue(forKey: ObjectIdentifier(download))
                completionHandler(nil)
                return
            }
            let dir = MessageListModel.miniClawWorkspacePersistentDir(for: sid)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var name = suggestedFilename.isEmpty ? "download" : suggestedFilename
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var dest = dir.appendingPathComponent(name)
            var counter = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                dest = dir.appendingPathComponent(name)
                counter += 1
            }

            let key = ObjectIdentifier(download)
            self.downloadDestinations[key] = dest
            // Progress now surfaces via the floating
            self.downloadCenterIds[key] = BrowserDownloadCenter.shared.began(
                sessionId: sid, filename: name, progress: download.progress,
                onCancel: { [weak self, weak download] in
                    guard let self, let download else { return }
                    self.cancelDownload(download)
                })
            logger.info("⬇️ Download started: \(name) → session \(sid.prefix(8)) workspace")
            completionHandler(dest)
        }
    }

    public nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            let key = ObjectIdentifier(download)
            self.inflightDownloads.removeValue(forKey: key)
            guard let dest = self.downloadDestinations.removeValue(forKey: key) else { return }
            let name = dest.lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            if let entryId = self.downloadCenterIds.removeValue(forKey: key) {
                BrowserDownloadCenter.shared.finished(id: entryId, sizeText: sizeText)
            }
            logger.info("✅ Download finished: \(name) (\(sizeText))")
        }
    }

    public nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in
            let key = ObjectIdentifier(download)
            self.inflightDownloads.removeValue(forKey: key)
            let dest = self.downloadDestinations.removeValue(forKey: key)
            let name = dest?.lastPathComponent ?? "file"
            if let entryId = self.downloadCenterIds.removeValue(forKey: key) {
                BrowserDownloadCenter.shared.failed(id: entryId, reason: error.localizedDescription)
            }
            if let dest { try? FileManager.default.removeItem(at: dest) }
            logger.error("Download failed: \(name) — \(error.localizedDescription)")
        }
    }

    /// cancel(_:), so this is the only cleanup path.
    private func cancelDownload(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        inflightDownloads.removeValue(forKey: key)
        downloadCenterIds.removeValue(forKey: key)
        let dest = downloadDestinations.removeValue(forKey: key)
        download.cancel { _ in }
        if let dest {
            try? FileManager.default.removeItem(at: dest)
            logger.info("🛑 Download cancelled by user: \(dest.lastPathComponent) — partial file removed")
        }
    }
}

public extension String {
    ///
    func middleTruncated(head: Int = 22, tail: Int = 10) -> String {
        guard count > head + tail + 1 else { return self }
        return "\(prefix(head))…\(suffix(tail))"
    }
}

@MainActor
public final class BrowserDownloadCenter: ObservableObject {

    public static let shared = BrowserDownloadCenter()

    public enum DownloadState: Equatable {
        case downloading
        case completed(sizeText: String)
        case failed(reason: String)
    }

    public struct Entry: Identifiable {
        public let id: UUID
        public let sessionId: String
        public let filename: String
        public let progress: Progress
        public var state: DownloadState
        public let startedAt: Date
        public var seen: Bool = false
        /// Cancels the underlying WKDownload (wired by MiniClawBrowserEngine).
        public let onCancel: (() -> Void)?
    }

    @Published private(set) var entries: [Entry] = []

    private var pendingAgentEvents: [String: [(filename: String, line: String)]] = [:]

    public func downloads(for sessionId: String) -> [Entry] {
        entries.filter { $0.sessionId == sessionId }
    }

    public func badgeCount(for sessionId: String) -> Int {
        downloads(for: sessionId).filter { $0.state == .downloading || !$0.seen }.count
    }

    public func began(sessionId: String, filename: String, progress: Progress,
               onCancel: (() -> Void)? = nil) -> UUID {
        let id = UUID()
        entries.append(Entry(id: id, sessionId: sessionId, filename: filename,
                             progress: progress, state: .downloading,
                             startedAt: Date(), onCancel: onCancel))
        queueAgentEvent(sessionId: sessionId, filename: filename,
                        line: "\(filename): download started → saving to miniclaw://workspace/\(filename)")
        return id
    }

    public func finished(id: UUID, sizeText: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].state = .completed(sizeText: sizeText)
        entries[idx].seen = false
        let e = entries[idx]
        queueAgentEvent(sessionId: e.sessionId, filename: e.filename,
                        line: "\(e.filename): download COMPLETED (\(sizeText)) → miniclaw://workspace/\(e.filename) (shell path: /var/MiniClaw/workspace/\(e.filename))")
    }

    public func failed(id: UUID, reason: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].state = .failed(reason: reason)
        entries[idx].seen = false
        let e = entries[idx]
        queueAgentEvent(sessionId: e.sessionId, filename: e.filename,
                        line: "\(e.filename): download FAILED — \(reason)")
    }

    public func cancel(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }),
              entries[idx].state == .downloading else { return }
        entries[idx].onCancel?()
        entries[idx].state = .failed(reason: String(localized: "Cancelled", comment: "Download cancelled by user"))
        entries[idx].seen = true
        let e = entries[idx]
        queueAgentEvent(sessionId: e.sessionId, filename: e.filename,
                        line: "\(e.filename): download CANCELLED by the user — the partial file was removed. Do not assume this file exists.")
    }

    public func dismiss(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public func markAllSeen(for sessionId: String) {
        for idx in entries.indices where entries[idx].sessionId == sessionId {
            entries[idx].seen = true
        }
    }

    /// failed); in-flight downloads are untouched.
    public func clearFinished(for sessionId: String) {
        entries.removeAll { $0.sessionId == sessionId && $0.state != .downloading }
    }

    public func agentReport(for sessionId: String) -> String? {
        let events = pendingAgentEvents.removeValue(forKey: sessionId) ?? []
        let inflight = downloads(for: sessionId).filter { $0.state == .downloading }
        let inflightNames = Set(inflight.map(\.filename))

        var lines: [String] = inflight.map { e in
            let p = e.progress
            let pct = p.totalUnitCount > 0 ? "\(Int(p.fractionCompleted * 100))%" : "…"
            let done = ByteCountFormatter.string(fromByteCount: p.completedUnitCount, countStyle: .file)
            let total = p.totalUnitCount > 0
                ? ByteCountFormatter.string(fromByteCount: p.totalUnitCount, countStyle: .file) : "?"
            return "\(e.filename): downloading \(pct) (\(done) / \(total)) → saving to miniclaw://workspace/\(e.filename)"
        }
        lines += events.filter { !inflightNames.contains($0.filename) }.map(\.line)
        guard !lines.isEmpty else { return nil }

        return "[browser_downloads] The browser is handling file download(s) NATIVELY "
            + "(triggered by page navigation/click, saved into this session's workspace):\n"
            + lines.map { "- \($0)" }.joined(separator: "\n")
            + "\nDo NOT re-download these files with curl/wget in shell_execute. "
            + "Completed files are already fully saved at the given path; for in-progress "
            + "downloads, wait and check again (e.g. via a later browser_use call or "
            + "shell `ls -l /var/MiniClaw/workspace/`) instead of downloading in parallel."
    }

    private func queueAgentEvent(sessionId: String, filename: String, line: String) {
        var list = pendingAgentEvents[sessionId] ?? []
        list.removeAll { $0.filename == filename }
        list.append((filename: filename, line: line))
        pendingAgentEvents[sessionId] = list
    }
}

public final class MiniClawSchemeHandler: NSObject, WKURLSchemeHandler {
    private let logger = AppLogger(category: "MiniClawScheme")

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        logger.info("[MiniClawScheme] start \(url.absoluteString)")

        guard let fileURL = MessageListModel.resolveMiniClawURL(url) else {
            logger.warning("[MiniClawScheme] not found: \(url.absoluteString)")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            logger.warning("[MiniClawScheme] read failed: \(fileURL.path)")
            urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
            return
        }

        let mimeType = Self.mimeType(for: fileURL.pathExtension)
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
        logger.info("[MiniClawScheme] served \(url.absoluteString) → \(fileURL.lastPathComponent) (\(data.count) bytes, \(mimeType))")
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "txt", "log": return "text/plain"
        case "md": return "text/markdown"
        case "csv": return "text/csv"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}

/// Two consumers:
///
/// 1. **Chat UI** — `ChatView` overlays a floating download card (icon +
/// live progress + tap-to-preview) driven by `entries`, replacing the old
/// "Downloading xxx…" systemInfo row in the message list.
/// 2. **Agent loop** — browser_use tool results append `agentReport(for:)`
/// so the LLM knows a page interaction triggered a native download and
/// must NOT re-download the same file via shell curl/wget (observed
/// failure mode: browser downloads moomoo.apk natively, model curls it
/// again because nothing in the tool result mentioned the download).
///