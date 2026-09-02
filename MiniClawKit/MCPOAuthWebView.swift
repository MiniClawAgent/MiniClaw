import SwiftUI
import WebKit

// MARK: - MCP OAuth 认证页（Kit 层：Swift 5 target 编译；主工程 Swift 6 模式下
// WKWebView 版 UIViewRepresentable 在 Xcode 26.6 + iOS 26.5 SDK 组合存在
// conformance 判定异常，故认证页放 Kit——唐唐 2026-09-01 拍板 App 内 WebKit 授权）
//
// 标题文本由调用方传入（Kit 层不引主工程 L10n）。

// MARK: - 授权流程上下文（驱动设置页的 sheet）

public struct MCPOAuthFlowContext: Identifiable {
    public let id = UUID()
    public let serverID: UUID
    public let serverName: String
    public let authorizeURL: URL
    public let onCode: (URL) -> Void
    public let onCancel: () -> Void

    public init(
        serverID: UUID,
        serverName: String,
        authorizeURL: URL,
        onCode: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.serverID = serverID
        self.serverName = serverName
        self.authorizeURL = authorizeURL
        self.onCode = onCode
        self.onCancel = onCancel
    }
}

// MARK: - 认证页 WebKit 容器（App 内授权，redirect 在导航拦截中捕获）

public struct MCPOAuthWebView: UIViewRepresentable {
    let url: URL
    let onRedirect: (URL) -> Void
    let onFinishedLoading: () -> Void

    // iOS 26 SDK：WKNavigationDelegate 方法为 @MainActor 隔离，Coordinator 需同隔离。
    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate {
        // loopback 回调（与 MCPOAuthManager.redirectURI 一致）：授权完成时
        // WebKit 导航到 127.0.0.1，此处拦截取码并取消导航（请求不出 WebKit）。
        let redirectScheme = "http"
        let redirectHost = "127.0.0.1"
        let redirectPort = 18231
        let onRedirect: (URL) -> Void
        let onFinishedLoading: () -> Void
        private var redirectHandled = false
        private let logger = AppLogger(category: "MCP-OAuth-Web")

        init(onRedirect: @escaping (URL) -> Void, onFinishedLoading: @escaping () -> Void) {
            self.onRedirect = onRedirect
            self.onFinishedLoading = onFinishedLoading
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let navType: String
            switch navigationAction.navigationType {
            case .linkActivated: navType = "link"
            case .formSubmitted: navType = "form"
            case .backForward: navType = "backForward"
            case .reload: navType = "reload"
            @unknown default: navType = "other"
            }
            logger.info("[MCP-OAuth-Web] 请求(\(navType)): \(url?.absoluteString ?? "nil")")

            if let url,
               url.scheme?.lowercased() == redirectScheme,
               url.host == redirectHost,
               url.port == redirectPort,
               url.path == "/callback" {
                guard !redirectHandled else { decisionHandler(.cancel); return }
                logger.info("[MCP-OAuth-Web] loopback redirect 命中, 捕获授权码")
                redirectHandled = true
                onRedirect(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// 响应阶段：400/500 等服务器错误在这里可见（授权页报错的直接证据）。
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                logger.error("[MCP-OAuth-Web] HTTP \(http.statusCode) ← \(http.url?.absoluteString ?? "")")
            }
            decisionHandler(.allow)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("[MCP-OAuth-Web] 导航失败: \(error.localizedDescription)")
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.error("[MCP-OAuth-Web] 初始导航失败: \(error.localizedDescription)")
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinishedLoading()
        }
    }

    public init(
        url: URL,
        onRedirect: @escaping (URL) -> Void,
        onFinishedLoading: @escaping () -> Void
    ) {
        self.url = url
        self.onRedirect = onRedirect
        self.onFinishedLoading = onFinishedLoading
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onRedirect: onRedirect, onFinishedLoading: onFinishedLoading)
    }

    public func makeUIView(context: Context) -> WKWebView {
        // 授权页是 SPA——登录后的授权确认走 fetch/XHR（不触发 WKNavigationDelegate），
        // 注入 JS 钩子把页面内的 API 调用（URL/状态码/响应体）桥接给原生日志，
        // 否则 400 等服务器错误是盲区（唐唐 2026-09-02）。
        let userContent = WKUserContentController()
        userContent.addUserScript(
            WKUserScript(source: Self.xhrHookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        userContent.add(context.coordinator, name: "mcpOAuthLog")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        AppLogger(category: "MCP-OAuth-Web").info("[MCP-OAuth-Web] 认证页加载: \(url.absoluteString)")
        web.load(URLRequest(url: url))
        return web
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 页面内 fetch/XHR 抓包（注入 JS + message handler 桥接）

extension MCPOAuthWebView.Coordinator: WKScriptMessageHandler {
    /// 接收页面 JS 上报的 fetch/XHR 非 2xx 调用（400 等服务器错误的直接证据）。
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "mcpOAuthLog",
              let payload = message.body as? String
        else { return }
        logger.error("[MCP-OAuth-Web] 页面API: \(payload)")
    }
}

extension MCPOAuthWebView {
    /// 页面内 fetch/XHR 拦截：非 2xx 的 API 调用全部上报（URL/状态码/响应体前 600 字符）。
    static let xhrHookJS = """
    (function() {
      function report(url, status, body) {
        try {
          window.webkit.messageHandlers.mcpOAuthLog.postMessage({
            url: String(url || ''), status: Number(status || 0),
            body: String(body || '').slice(0, 600)
          });
        } catch (e) {}
      }
      if (window.__mcpOAuthHooked) return; window.__mcpOAuthHooked = true;
      const origFetch = window.fetch;
      if (origFetch) {
        window.fetch = async function() {
          const resp = await origFetch.apply(this, arguments);
          if (resp.status >= 300) {
            try { const c = resp.clone(); c.text().then(t => report(resp.url, resp.status, t)).catch(() => report(resp.url, resp.status, '')); } catch (e) {}
          }
          return resp;
        };
      }
      const origOpen = XMLHttpRequest.prototype.open;
      const origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u) { this.__mcpUrl = u; return origOpen.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() { if (this.status >= 300) report(this.__mcpUrl, this.status, this.responseText); });
        this.addEventListener('error', function() { report(this.__mcpUrl, 0, 'network error'); });
        return origSend.apply(this, arguments);
      };
    })();
    """
}

// MARK: - 认证页 sheet（设置页挂载）

/// App 内 WebKit OAuth 授权页：标题 + 取消 + 网页（redirect 由 WebView 拦截回调）。
public struct MCPOAuthFlowSheet: View {
    let context: MCPOAuthFlowContext
    let title: String

    public init(context: MCPOAuthFlowContext, title: String) {
        self.context = context
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            MCPOAuthWebView(
                url: context.authorizeURL,
                onRedirect: context.onCode,
                onFinishedLoading: {}
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n_cancel()) { context.onCancel() }
                }
            }
        }
    }
}

/// Kit 层取消按钮文本（主工程调用方传 title 时一并传；此兜底为通用「取消」多语言常量）。
private func L10n_cancel() -> String {
    // Kit 内无主工程 L10n；按首选语言给「取消」。主工程接线时可改传参。
    let lang = Locale.preferredLanguages.first ?? "en"
    if lang.hasPrefix("zh") { return "取消" }
    if lang.hasPrefix("ja") { return "キャンセル" }
    if lang.hasPrefix("ko") { return "취소" }
    return "Cancel"
}
