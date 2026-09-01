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
        let redirectScheme = "miniclaw"
        let redirectHost = "mcp-oauth"
        let onRedirect: (URL) -> Void
        let onFinishedLoading: () -> Void
        private var redirectHandled = false

        init(onRedirect: @escaping (URL) -> Void, onFinishedLoading: @escaping () -> Void) {
            self.onRedirect = onRedirect
            self.onFinishedLoading = onFinishedLoading
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               url.scheme?.lowercased() == redirectScheme,
               url.host?.lowercased() == redirectHost {
                guard !redirectHandled else { decisionHandler(.cancel); return }
                redirectHandled = true
                onRedirect(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
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
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
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
