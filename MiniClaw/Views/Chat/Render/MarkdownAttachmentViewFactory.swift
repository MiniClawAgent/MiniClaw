import UIKit

// MARK: - MarkdownAttachmentViewFactory（渲染架构专项 阶段 2）
//
// 从 MarkdownTextView.rebuildAttachViews / refreshAttachViews 抽取的「按附件类型
// 创建视图」逻辑。MarkdownRenderView 持有 NSTextStorage，但自身不感知具体附件类型——
// 它通过注入的 `attachmentViewFactory` 闭包调用本工厂来创建附件视图。
//
// 职责边界：
// - 本工厂只负责「从无到有」创建视图（对应 MarkdownTextView 的 new-attachment 分支）。
//   MarkdownRenderView.rebuildAttachmentViews 已按 ObjectIdentifier 处理复用/移除，
//   复用命中时走 `attachmentViewUpdater`（见 MarkdownRenderedText），不会再到本工厂。
// - 异步加载完成后的重建回调（reload）由调用方注入——图片/视频/数学公式加载完需要
//   重新排版并通知宿主 cell 自 sizing。
// - 表格内链接（onOpenURL）通过 `onOpenLink` 注入；未注入时回退到 UIApplication.open。

enum MarkdownAttachmentViewFactory {

    /// 由宿主注入：表格内链接打开。未设置时回退 UIApplication.shared.open。
    /// 设计为宿主 init（makeUIView）时一次性配置。
    nonisolated(unsafe) static var onOpenLink: ((URL) -> Void)?

    /// 按附件类型创建视图。
    ///   - attachment: NSTextStorage 中的 NSTextAttachment 子类实例。
    ///   - width: 容器宽度（用于 makeView 内部布局）。
    ///   - reload: 异步加载完成后触发的重建回调（调用方注入，指向具体
    ///     MarkdownRenderView 的 rebuild + invalidate）。
    /// - Returns: 视图，或 nil 表示不支持该附件类型。
    @MainActor
    static func makeView(
        for attachment: NSTextAttachment,
        width: CGFloat,
        reload: (() -> Void)? = nil
    ) -> UIView? {
        if let imageAttach = attachment as? ImageAttachment {
            // 仅当图片未加载时才挂 onLoad + 触发加载；已加载则清理旧回调，
            // 避免内存缓存命中时同步回调递归进 rebuild（[AttachHang] 防御）。
            if imageAttach.loadedImage == nil {
                imageAttach.onLoad = reload
                imageAttach.beginLoadingIfNeeded()
            } else {
                imageAttach.onLoad = nil
            }
            return imageAttach.makeView(width: width)
        }

        if let videoAttach = attachment as? VideoAttachment {
            videoAttach.onLoad = reload
            videoAttach.beginLoadingIfNeeded()
            return videoAttach.makeView(width: width)
        }

        if let mathAttach = attachment as? MathAttachment {
            // 旧路径走 scheduleMathCoalesce 做合并；此处直接复用 reload（重建+自 sizing）。
            mathAttach.onLoad = reload
            mathAttach.beginRenderingIfNeeded()
            return mathAttach.makeView(width: width)
        }

        if let tableAttach = attachment as? TableAttachment {
            // 每次渲染重挂 onOpenURL：旧闭包可能捕获了已释放的 coordinator
            // （[weak self] → nil），导致 miniclaw:// 链接静默失败。
            tableAttach.onOpenURL = { url in
                if let handler = MarkdownAttachmentViewFactory.onOpenLink {
                    handler(url)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return tableAttach.makeView(width: width)
        }

        if let codeBlock = attachment as? CodeBlockAttachment {
            return codeBlock.makeView(width: width)
        }

        if let thematicBreak = attachment as? ThematicBreakAttachment {
            return thematicBreak.makeView(width: width)
        }

        if let audioAttach = attachment as? AudioAttachment {
            return audioAttach.makeView(width: width)
        }

        if let fileAttach = attachment as? FileAttachment {
            return fileAttach.makeView(width: width)
        }

        return nil
    }
}
