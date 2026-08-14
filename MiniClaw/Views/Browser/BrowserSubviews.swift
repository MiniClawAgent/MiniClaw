import SwiftUI
import WebKit
import UIKit

struct ControllerWebView: UIViewRepresentable {
    @ObservedObject var controller: BrowserEngineAdapter

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let webView = controller.activeWebView else { return }

        // 标签切换：非活跃 webView **移回离屏宿主**（同在 keyWindow，屏幕外坐标）。
        // 不用 isHidden——隐藏视图无法正常 takeSnapshot（标签概览缩略图会变空白）；
        // 也不 removeFromSuperview 丢弃——iOS 18 离开 window 再回来会损坏触摸/交互
        // （点击只出蓝色高亮不响应）。移回宿主 = 同一 window 内移动，两问题都不触发。
        for subview in uiView.subviews where subview is WKWebView && subview !== webView {
            controller.rehost(subview as! WKWebView)
        }

        if webView.superview !== uiView {
            webView.translatesAutoresizingMaskIntoConstraints = false
            uiView.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: uiView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: uiView.trailingAnchor),
                webView.topAnchor.constraint(equalTo: uiView.topAnchor),
                webView.bottomAnchor.constraint(equalTo: uiView.bottomAnchor)
            ])
        }
        webView.isHidden = false
    }
}


// MARK: - Toolbar Button

struct BrowserToolbarButton: View {
    let icon: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                // 与其它浏览器按钮统一：白色图标（浅色模式下 .primary 会变黑，不一致）。
                .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.4))
                .frame(width: 44, height: 44)
                .background(Color(.systemGray4), in: Circle())
        }
        .disabled(!isEnabled)
    }
}

// MARK: - 历史记录列表

/// 「历史记录」面板：展示当前标签的内部 Safari 历史（后退列表 + 当前 + 前进列表），点按跳转到对应页面。
struct BrowserHistoryView: View {
    let items: [BrowserEngineAdapter.BrowserHistoryItem]
    let onSelect: (URL) -> Void

    var body: some View {
        List {
            if items.isEmpty {
                EmptyStateView(label: L10n.l("no_history_yet"), systemImage: "clock")
            }
            ForEach(items) { item in
                Button(action: { onSelect(item.url) }) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.body)
                                .fontWeight(item.isCurrent ? .semibold : .regular)
                                // 标题单行显示，超出部分省略号截断（网址在下一行，标题不必换行）。
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if item.isCurrent {
                                Text(L10n.l("current"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(item.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle(L10n.l("history_records"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

