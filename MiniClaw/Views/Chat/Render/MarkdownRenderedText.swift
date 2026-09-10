import MiniClawKit
import UIKit
import SwiftUI

// MARK: - MarkdownRenderedText（渲染架构专项 阶段 2）
//
// 无附件 markdown 文本块的 UIViewRepresentable：用自绘 TextKit1 的 MarkdownRenderView
// 替代 UITextView，消除流式期间每 token 全量排版 1.2s 的主线程阻塞。
//
// 本组件只服务于「无附件」块（附件块仍走旧 MarkdownView 路径，直到双轨验证完成）。
// 渲染逻辑复刻 MarkdownView 的核心分支（MarkdownView.swift 渲染分支），但剥离了
// 表格尾拆分 / 附件 fast-path 等仅用于含附件块的特殊处理。

struct MarkdownRenderedText: UIViewRepresentable {

    let markdown: String
    let messageId: UUID?
    let blockId: UUID?
    let onTapBlank: (() -> Void)?
    let onOpenLink: ((URL) -> Void)?
    let onTapInlineCode: ((String) -> Void)?

    @MainActor
    final class Coordinator {
        /// 渲染器（见 MarkdownView.Coordinator 的初始化）。
        var renderer = MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5))
        /// 最近一次提交的 markdown 源文。
        var lastMarkdown: String = ""
        /// 流式渲染节流：最近一次全量渲染结果，250ms 内复用。
        var lastStreamPending: NSAttributedString?
        /// 最近一次全量渲染的 CACurrentMediaTime 时间戳。
        var lastStreamRenderAt: CFTimeInterval = 0
        /// 最近一次使用的字号（字号已进 cache key，故变化时自动失效，无需手动清缓存）。
        var lastFontSize: CGFloat = FontSettings.shared.scaledMessage(16.5)
        /// [T-perf 2026-09-08] 进行中的后台渲染 key（防同内容重复派发 + 完成回调 key 校验）。
        var inflightRenderKey: String? = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: makeUIView

    func makeUIView(context: Context) -> MarkdownRenderView {
        let uiView = MarkdownRenderView()

        // 附件视图工厂：转发到静态工厂，并在异步加载完成后重建当前视图 + 通知宿主自 sizing。
        uiView.attachmentViewFactory = { [weak uiView] attachment, width in
            MainActor.assumeIsolated {
                MarkdownAttachmentViewFactory.makeView(for: attachment, width: width) {
                    guard let uiView else { return }
                    uiView.rebuildAttachmentViews()
                    uiView.invalidateCellSizeIfNeeded()
                }
            }
        }

        // 复用命中时的增量更新（仅代码块需要就地刷新内容）。
        uiView.attachmentViewUpdater = { attachment, view, _ in
            if let codeBlock = attachment as? CodeBlockAttachment {
                codeBlock.updateExistingAttachView(view)
            }
        }

        // 交互回调转发。
        uiView.onTapBlank = onTapBlank
        uiView.onOpenLink = onOpenLink
        uiView.onTapInlineCode = onTapInlineCode

        // 注入表格内链接打开回调（静态依赖，宿主 init 时一次性配置）。
        MarkdownAttachmentViewFactory.onOpenLink = onOpenLink

        return uiView
    }

    // MARK: updateUIView

    func updateUIView(_ uiView: MarkdownRenderView, context: Context) {
        let coord = context.coordinator
        let fontSize = FontSettings.shared.scaledMessage(16.5)
        coord.lastFontSize = fontSize

        let renderCacheKey = MarkdownRenderCache.key(for: markdown, fontSize: fontSize)

        if let memo = MarkdownRenderCache.shared.cachedAttributed(for: renderCacheKey) {
            // ① 统一缓存命中：直接复用已渲染 attributed（增量 setAttributedString 路径）。
            coord.lastMarkdown = markdown
            coord.inflightRenderKey = nil
            uiView.attributedText = memo
        } else if let prev = coord.lastStreamPending,
                  CACurrentMediaTime() - coord.lastStreamRenderAt < MarkdownView.Coordinator.streamThrottleWindow {
            // ② 流式节流：距上次全量渲染 <节流窗，复用上次结果（显示滞后 ≤节流窗）。
            coord.lastMarkdown = markdown
            uiView.attributedText = prev
        } else if coord.inflightRenderKey == renderCacheKey {
            // ③ 后台渲染进行中（同内容）：保持现状，等渲染完成回调赋值。
            return
        } else {
            // ④ [T-perf 2026-09-08] 渲染后台化：进入长会话时数百个块在主线程
            // 逐块同步渲染 = 16s 主线程阻塞（真机 Watchdog 实证）。无附件块的
            // 渲染是纯文本构造（无 UIKit 视图），线程安全 → 后台执行，主线程
            // 只做最终的 attributedText 赋值。key 变化（流式 token）时结果作废。
            coord.inflightRenderKey = renderCacheKey
            coord.lastMarkdown = markdown
            let renderer = coord.renderer
            let mid = messageId
            let bid = blockId
            let md = markdown
            Task.detached(priority: .userInitiated) { [weak uiView] in
                let prepared = prepareMarkdownForRender(md)
                let blocks = MarkdownContent(prepared).blocks
                await MainActor.run {
                    renderer.messageId = mid
                    renderer.blockId = bid
                }
                let pendingBox = RenderOutputBox(pending: autoreleasepool { renderer.render(blocks: blocks) })
                await MainActor.run {
                    guard let uiView else { return }
                    // key 校验：渲染期间内容变了（流式 token）则丢弃，下轮重渲。
                    let currentKey = MarkdownRenderCache.key(
                        for: coord.lastMarkdown, fontSize: coord.lastFontSize)
                    guard currentKey == renderCacheKey else { return }
                    coord.inflightRenderKey = nil
                    coord.lastStreamPending = pendingBox.pending
                    coord.lastStreamRenderAt = CACurrentMediaTime()
                    // [2026-09-08 修复] 与全库同口径：**含附件语法的块不进统一缓存**
                    //（附件实例与 renderer/视图上下文身份耦合，共享会串味）。此前这里
                    // 无条件 store，一旦重新接线（当前已回退）就是 P0 级错误复用。
                    if !AssistantBlock.hasRichSyntax(md) {
                        MarkdownRenderCache.shared.store(attributed: pendingBox.pending, key: renderCacheKey)
                    }
                    uiView.attributedText = pendingBox.pending
                    uiView.invalidateCellSizeIfNeeded()
                }
            }
            return
        }

        // 触发宿主 cell 自 sizing（SwiftUI 经 preferredLayoutAttributesFitting 拾取）。
        uiView.invalidateCellSizeIfNeeded()
    }

    // MARK: sizeThatFits

    /// 注意：本方法不做任何渲染——渲染只在 updateUIView（SwiftUI 保证 layout 测量前
    /// 已先跑过 updateUIView）。miss 时退回 MarkdownRenderView.sizeThatFits 的 TextKit
    /// usedRect 计算（便宜）。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownRenderView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let widthKey = Int(width)
        let renderCacheKey = MarkdownRenderCache.key(
            for: markdown,
            fontSize: FontSettings.shared.scaledMessage(16.5)
        )

        // ① 统一缓存 heights 命中：直接返回（widthKey = Int(width)）。
        if let cachedH = MarkdownRenderCache.shared.cachedHeight(for: renderCacheKey, width: widthKey) {
            return CGSize(width: width, height: cachedH)
        }

        // ② miss：退回 MarkdownRenderView 的 TextKit usedRect 计算（便宜）。
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        MarkdownRenderCache.shared.store(height: size.height, key: renderCacheKey, width: widthKey)
        return size
    }
}

/// 后台渲染输出的跨隔离传递盒：`NSAttributedString` 为非 Sendable 类型，
/// 装入标注 `@unchecked Sendable` 的盒以通过 Swift 6 发送检查。
/// 该值由后台任务独占构造后单侧传递给主线程，不共享可变状态（与迁入前语义一致）。
private struct RenderOutputBox: @unchecked Sendable {
    let pending: NSAttributedString
}
