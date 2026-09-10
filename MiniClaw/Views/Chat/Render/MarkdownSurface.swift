import SwiftUI

/// 全 App 统一的 Markdown 展示入口（2026-09-08 双套合并）。
///
/// 合并前：主聊天（`MessageCollectionView`）走本 Kit 的 cmark-gfm 管线，而
/// 子代理聊天气泡 / .md 文件查看器 / 设置文档页走主工程另一套「手写逐行解析器
/// + SwiftUI 视图」管线，两套并存、语法覆盖与缺陷各自漂移（手写套不支持数学
/// 公式、GFM 表格与 autolink 也不完整）。
///
/// 现统一到 cmark 管线：手写套已删除，所有 SwiftUI 表面复用 `MarkdownView`。
/// 本类型是它对主 App 的 public 门面——`MarkdownView` 是 internal，主 App
/// target 无法直接构造。
public struct MarkdownSurface: View {
    private let markdown: String
    private let isStreaming: Bool
    /// 所属消息 ID：非空时行内图片点击路由到该消息的图片画廊；独立渲染场景传 nil。
    private let messageId: UUID?
    /// 链接打开拦截：非空时接管本视图内所有链接点击（宿主自定义路由），
    /// 为空时走全 App 统一通道 `MiniClawOpenURLHandler`。
    private let onOpenURL: ((URL) -> Void)?

    public init(markdown: String,
                isStreaming: Bool = false,
                messageId: UUID? = nil,
                onOpenURL: ((URL) -> Void)? = nil) {
        self.markdown = markdown
        self.isStreaming = isStreaming
        self.messageId = messageId
        self.onOpenURL = onOpenURL
    }

    public var body: some View { content }

    /// `fixedSize(horizontal: false, vertical: true)`：与聊天列表内的用法一致，
    /// 让 UITextView 按内容高度撑开、不被父容器压缩（否则 ScrollView 里高度归零）。
    private var rendered: some View {
        MarkdownView(markdown: markdown, isStreaming: isStreaming, messageId: messageId)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        if let onOpenURL {
            rendered.environment(\.openURL, OpenURLAction { url in
                onOpenURL(url)
                return .handled
            })
        } else {
            rendered.modifier(MiniClawOpenURLHandler())
        }
    }
}
