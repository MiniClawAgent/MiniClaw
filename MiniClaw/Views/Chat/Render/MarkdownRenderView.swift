import UIKit
import SwiftUI

// MARK: - MarkdownRenderView（2026-09-08 渲染架构专项 阶段 1）
//
/// 自绘 TextKit1 栈的消息块渲染视图（渲染架构专项，自有设计与实现）。
///
/// 为什么替换 UITextView：
/// - UITextView.attributedText 赋值会重置全部内部 UI 状态（selection、scroll、
///   内部 canvas/tiled layers、手势系统）——长消息流式期间每 chunk 赋值一次，
///   TextKit1 全量重排 + UI 状态重建 = 单块 0.5-1.2s 的主线程阻塞（真机
///   SendTrace/SizeFit 实证）。
/// - 本视图直接持有 NSTextStorage + NSLayoutManager + NSTextContainer，
///   `attributedText` 走 `textStorage.setAttributedString`（TextKit 只对变化部分
///   增量排版），绘制在 `draw(_:)` 里直接调用 drawBackground/drawGlyphs——
///   无 tiled CALayer、无内部 canvas view，内存从 ~16MB 降到 ~1-2MB/实例。
///
/// 附件视图复用：`attachmentViewMap`（ObjectIdentifier(attachment) → UIView）。
/// 统一渲染缓存（MarkdownRenderCache）保证同一内容的 attributed 复用同一批
/// attachment 实例 → map 按 identity 命中 → 视图零重建，只做 frame 重定位。
///
/// 集成约定：
/// - 附件视图工厂由宿主注入（`attachmentViewFactory`），内部调用 MiniClaw 现有
///   的附件视图创建/更新逻辑（MarkdownTextView.rebuildAttachViews 同源），
///   本类不感知具体附件类型。
/// - 高度变化通过 `invalidateIntrinsicContentSize` 通知宿主（UIHostingConfiguration
///   经 preferredLayoutAttributesFitting 拾取），不直接 invalidate 整个 collection。
///
/// 交互（阶段 3 渐进补齐）：链接/内联代码/空白 tap 已实现；长按文本选择用
/// 按需 UITextView overlay（阶段 3）。

final class MarkdownRenderView: UIView {

    // MARK: - TextKit 栈

    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer

    // MARK: - 依赖注入

    /// 附件视图工厂：宿主提供（对接 MiniClaw 现有附件视图创建逻辑）。
    /// 参数：(attachment, 容器宽度) → 视图；返回 nil 表示该附件类型此视图不支持。
    var attachmentViewFactory: ((NSTextAttachment, CGFloat) -> UIView?)?

    /// 附件视图增量更新：复用命中时宿主可就地更新视图内容（可选）。
    var attachmentViewUpdater: ((NSTextAttachment, UIView, CGFloat) -> Void)?

    // MARK: - 交互回调

    /// 空白区域点击。
    var onTapBlank: (() -> Void)?
    /// 链接点击（URL）。
    var onOpenLink: ((URL) -> Void)?
    /// 内联代码点击（返回代码文本）。
    var onTapInlineCode: ((String) -> Void)?

    // MARK: - 附件视图管理

    private(set) var attachmentViews: [UIView] = []
    var attachmentViewMap: [ObjectIdentifier: UIView] = [:]
    private var lastLayoutWidth: CGFloat = 0

    // MARK: - 状态

    /// 最近一次 sizeThatFits 计算的高度（供宿主 cell 自 sizing 判定变化）。
    var lastComputedHeight: CGFloat = 0
    private var tapGesture: UITapGestureRecognizer?

    override init(frame: CGRect) {
        textStorage = NSTextStorage()
        layoutManager = NSLayoutManager()
        textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        // 自绘栈：容器宽度由 sizeThatFits/layoutSubviews 手动驱动。
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        super.init(frame: frame)

        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        tapGesture = tap
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 内容

    /// 当前渲染的富文本（含 8pt 上下 inset 语义的对齐见 sizeThatFits）。
    var attributedText: NSAttributedString? {
        get { textStorage.length > 0 ? NSAttributedString(attributedString: textStorage) : nil }
        set {
            // 清掉 layer 背板：cell 复用周期的旧内容不能在 draw() 前透出。
            layer.contents = nil
            if let newValue {
                textStorage.setAttributedString(newValue)
            } else {
                textStorage.setAttributedString(NSAttributedString())
            }
            // 内容变化后附件集合可能不同——延迟到布局时按 identity 对账。
            setNeedsLayout()
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: - 高度

    /// 纯文本排版高度（含 8pt 上下 inset，与 MarkdownTextView 的
    /// textContainerInset 语义对齐，保证替换后行高一致）。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width > 0 ? size.width : textContainer.size.width
        guard width > 1, textStorage.length > 0 else {
            return CGSize(width: width, height: 8)
        }
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: width, height: ceil(used.height) + 8)
    }

    override var intrinsicContentSize: CGSize {
        let width = textContainer.size.width
        guard width > 1, textStorage.length > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(used.height) + 8)
    }

    /// 高度变化时通知宿主（cell 自 sizing 经 preferredLayoutAttributesFitting 拾取）。
    func invalidateCellSizeIfNeeded() {
        guard textContainer.size.width > 1 else { return }
        let newHeight = sizeThatFits(CGSize(width: textContainer.size.width, height: .greatestFiniteMagnitude)).height
        let previous = lastComputedHeight
        guard abs(newHeight - previous) > 1 else { return }
        lastComputedHeight = newHeight
        guard previous > 0 else { return }
        invalidateIntrinsicContentSize()
    }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        guard textStorage.length > 0 else { return }
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else { return }
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }

    // MARK: - 布局（附件视图 frame 维护）

    override func layoutSubviews() {
        super.layoutSubviews()

        let currentWidth = bounds.width
        if currentWidth > 0, currentWidth != lastLayoutWidth {
            lastLayoutWidth = currentWidth
            textContainer.size = CGSize(width: currentWidth, height: .greatestFiniteMagnitude)
            if !attachmentViews.isEmpty {
                refreshAttachmentFrames()
            } else if hasUnrenderedAttachments {
                rebuildAttachmentViews()
                invalidateIntrinsicContentSize()
            }
            return
        }
        refreshAttachmentFrames()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // 离屏时释放 backing store，降低复用池内存。
            layer.contents = nil
            for sub in attachmentViews {
                sub.layer.contents = nil
            }
        }
    }

    // MARK: - 附件视图

    private var hasUnrenderedAttachments: Bool {
        guard attachmentViews.isEmpty else { return false }
        var found = false
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length), options: []) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// 按 identity 对账重建：复用命中 → 更新 frame；新附件 → 工厂创建；
    /// 消失的附件 → 移除视图。
    func rebuildAttachmentViews() {
        guard let factory = attachmentViewFactory, textContainer.size.width > 1 else { return }
        let previousMap = attachmentViewMap
        var newViews: [UIView] = []
        var newMap: [ObjectIdentifier: UIView] = [:]

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let containerWidth = textContainer.size.width
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let attachId = ObjectIdentifier(attachment)
            let view: UIView
            if let reused = previousMap[attachId] {
                view = reused
                self.attachmentViewUpdater?(attachment, reused, containerWidth)
            } else if let made = factory(attachment, containerWidth) {
                view = made
                if view.superview !== self { addSubview(view) }
            } else {
                return
            }
            newViews.append(view)
            newMap[attachId] = view
        }
        // 不在本次集合里的旧视图移除。
        for (id, oldView) in previousMap where newMap[id] == nil {
            oldView.removeFromSuperview()
        }
        attachmentViews = newViews
        attachmentViewMap = newMap
        refreshAttachmentFrames()
    }

    /// 依 glyph boundingRect 重定位附件视图 frame（宽度夹到容器宽）。
    func refreshAttachmentFrames() {
        guard !attachmentViews.isEmpty, textContainer.size.width > 1 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            guard let view = self.attachmentViewMap[ObjectIdentifier(attachment)] else { return }
            let glyphRange = self.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var frame = self.layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textContainer)
            if frame.width < 1 || frame.width > self.textContainer.size.width {
                frame.size.width = self.textContainer.size.width
            }
            if view.frame != frame {
                view.frame = frame
            }
        }
    }

    // MARK: - 点击

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        // 1) 附件视图自管理点击（代码块/表格内部有自己的手势/滚动）。
        for sub in attachmentViews where sub.frame.contains(location) {
            onTapBlank?()
            return
        }
        // 2) 文本区域：查字符索引 → link / inline-code 属性。
        guard textStorage.length > 0 else { return }
        let charIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex < textStorage.length, charIndex >= 0 else {
            onTapBlank?()
            return
        }
        let charRange = NSRange(location: charIndex, length: 1)
        if let url = textStorage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL {
            onOpenLink?(url)
            return
        }
        if let rawLink = textStorage.attribute(.link, at: charIndex, effectiveRange: nil) as? String,
           let url = URL(string: rawLink) {
            onOpenLink?(url)
            return
        }
        // 内联代码（背景色属性标记，与 MarkdownTextView 的判定同源）。
        let isInlineCode = textStorage.attribute(.backgroundColor, at: charIndex, effectiveRange: nil) != nil
        if isInlineCode {
            var codeRange = charRange
            textStorage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: textStorage.length), options: []) { value, range, stop in
                if value != nil, NSLocationInRange(charIndex, range) {
                    codeRange = range
                    stop.pointee = true
                }
            }
            let code = textStorage.attributedSubstring(from: codeRange).string
            onTapInlineCode?(code)
            return
        }
        onTapBlank?()
    }
}
