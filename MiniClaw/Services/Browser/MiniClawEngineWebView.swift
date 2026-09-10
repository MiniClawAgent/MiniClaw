import SwiftUI
import WebKit

/// UIViewRepresentable wrapper that displays a `MiniClawBrowserEngine`'s WKWebView.
struct MiniClawEngineWebView: UIViewRepresentable {
    let manager: MiniClawBrowserEngine

    func makeUIView(context: Context) -> WKWebView {
        manager.webView
    }

    func updateUIView(_ uiView: WKWebView,context: Context) {
    }
}
