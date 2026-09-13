import SwiftUI
import UIKit
import Foundation
import Combine
final class MarkdownTextView: UITextView,UIGestureRecognizerDelegate {
    private var attachmentViews: [UIView] = []
    /// the async refreshAttachViews call was dropped because window was nil at the time.
    var hasUnrenderedAttachments: Bool {
        guard attachmentViews.isEmpty else { return false }
        let storage = textStorage
        var found = false
        storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { value,_,stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
    var hasScheduledRecoveryForCurrentContent = false

    var onCopyScreenshot: (() -> Void)?

    /// `rebuildAttachViews()` per callback multiplies the cost N×; instead
    private var pendingMathRefresh = false

    /// Schedule at most one `rebuildAttachViews()` per runloop tick from
    func scheduleMathCoalesce() {
        guard !pendingMathRefresh else { return }
        pendingMathRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingMathRefresh = false
            self.rebuildAttachViews()
        }
    }

    func resetAttachmentRecovery() {
        hasScheduledRecoveryForCurrentContent = false
    }

    var needsAttachmentRecovery: Bool {
        let storage = textStorage

        var expected = 0
        storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { value,_,_ in
            if value != nil { expected += 1 }
        }

        guard expected>0 else { return false }

        if attachmentViews.count != expected {
            return true
        }

        if attachmentViews.contains(where: { $0.superview !== self }) {
            return true
        }

        return false
    }

    private var attachmentViewMap: [ObjectIdentifier: UIView] = [:]

    /// Fingerprint of the last successful refreshAttachViews invocation.
    private var lastUAVStorageLen: Int = -1
    private var lastUAVWidth: CGFloat = -1
    private var lastUAVViewCount: Int = -1
    /// at the moment of the last successful `refreshAttachViews` pass.
    /// rows. See the entry-block dedup in `refreshAttachViews` for the
    private var lastUAVTableGenSum: UInt64 = 0
    /// (new attachment object but same visual position). Allows `updateExistingAttachView` instead of full rebuild.
    var codeBlockViewCache: [Int: UIView] = [:]
    private var lastLayoutWidth: CGFloat = 0
    var lastComputedHeight: CGFloat = 0

    /// `invalidateCellSizeIfChanged` to skip the costly sizeThatFits + collection
    /// [2026-09-13 指纹统一] 原为 `lastSizedStorageLen: Int = -1`（只比 `textStorage.length`）。
    /// 等长改写（长度不变、内容不同）会被判"未变" ⇒ 返回陈旧高度。改用 `ContentFingerprint`
    /// （长度 + FNV-1a 全量哈希，恒不为 0，故 `0` 作"未设置"哨兵）。
    private var lastSizedStorageFingerprint: Int = 0
    private var lastSizedWidth: CGFloat = -1
    private var lastSizedTableGenSum: UInt64 = 0
    var rawMarkdown: String = ""

    /// Set while `rebuildAttachViews` is executing. Same-runloop re-entry
    private var isRefreshingAttachments = false
    /// Set while `invalidateCellSizeIfChanged` is executing. The collection-view
    /// `preferredLayoutAttributesFitting` → `sizeThatFits` → `invalidateCellSizeIfChanged`.
    private var isInvalidatingCellSize = false
    /// Armed when a REAL height change was
    /// skipped. Guarantees one post-settle retry of invalidateCellSizeIfChanged
    private var pendingDeferredRemeasure = false
    /// [2026-09-08] 是否含 ImageAttachment（defer 例外判定用；枚举一次即短路）。
    private var hasImageAttachmentCached: Bool {
        var found = false
        textStorage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: textStorage.length),options: []) { value,_,stop in
            if value is ImageAttachment { found = true; stop.pointee = true }
        }
        return found
    }
    /// arm 一次性 0.6s 延迟重测（幂等：飞行中不重复 arm）。
    private func armDeferredRemeasure() {
        guard !pendingDeferredRemeasure else { return }
        pendingDeferredRemeasure = true
        DispatchQueue.main.asyncAfter(deadline: .now()+0.6) { [weak self] in
            guard let self else { return }
            self.pendingDeferredRemeasure = false
            self.invalidateCellSizeIfChanged()
        }
    }
    private var reentryGuardHits: Int = 0

    /// Set when `rebuildAttachViews` was dropped because the view was
    ///
    /// `window != nil` guard at the top of `rebuildAttachViews` the
    private var pendingRefreshAfterWindowAttach = false

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = MiniClawLayoutManager()
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        super.init(frame: .zero,textContainer: textContainer)

        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        // [Fix 2026-09-14 「流式期间尾部不显示」根治 · 社区标准做法]
        // `UITextView` **默认开启**非连续布局（Apple 文档写默认 false，实际是 true；见 WWDC2018
        // 《TextKit 最佳做法》：UITextView 默认启用、且禁用滚动时它本不生效）。
        // 非连续布局下 TextKit 只保证"用得着的部分"被排版 ⇒ `glyphRange(forBoundingRect:)` /
        // `ensureLayout(forCharacterRange:)` 可能只覆盖**部分**文本 ⇒ **尾部既不参与排版、
        // 也不被绘制**（真机签名：`glyphs=160 visEnd=77`，而存储与 cell 高度都正常 = 尾部就是画不出来）。
        // 这是 iOS7 以来 UITextView 的著名坑，标准解法就是关掉它 —— 自定义测量/绘制/流式追加的
        // TextKit 栈**必须**连续布局，否则任何按字形范围取值的逻辑都不可靠。
        layoutManager.allowsNonContiguousLayout = false
        //
        textContainerInset = UIEdgeInsets(top: 4,left: 0,bottom: 4,right: 0)
        backgroundColor = .clear
        textContainer.lineBreakMode = .byWordWrapping
        contentInset = .zero
        clipsToBounds = true
        textDragInteraction?.isEnabled = false
        linkTextAttributes = [
            .foregroundColor: MarkdownTheme().linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let codeTap = UITapGestureRecognizer(target: self,action: #selector(handleInlineCodeTap(_:)))
        codeTap.delegate = self
        addGestureRecognizer(codeTap)
        inlineCodeTapGesture = codeTap

        // A non-cancelling,
        let tracker = UILongPressGestureRecognizer(target: self,action: #selector(handleSelectionDragTrack(_:)))
        tracker.minimumPressDuration = 0
        tracker.cancelsTouchesInView = false
        tracker.delaysTouchesBegan = false
        tracker.delaysTouchesEnded = false
        tracker.delegate = self
        addGestureRecognizer(tracker)
        selectionDragTracker = tracker
    }

    // iOS 16 ONLY: UITextView attaches a built-in
    override func addInteraction(_ interaction: any UIInteraction) {
        if #unavailable(iOS 17.0),interaction is UIContextMenuInteraction {
            return
        }
        super.addInteraction(interaction)
    }

    private weak var selectionDragTracker: UILongPressGestureRecognizer?

    private weak var inlineCodeTapGesture: UITapGestureRecognizer?
    var onTapBlank: ((CGPoint) -> Void)?

    private var hadSelection = false
    ///
    private var prevSelStartOffset: Int?
    private var prevSelEndOffset: Int?

    func refreshSelectionState() {
        let hasSelection = selectedTextRange.map { !$0.isEmpty } ?? false
        let cv = findCollectionView()
        if hasSelection != hadSelection {
            hadSelection = hasSelection
            cv?.hasActiveTextSelection = hasSelection
        }
        // On every selection
        guard let cv else { return }
        guard hasSelection,let range = selectedTextRange else {
            prevSelStartOffset = nil
            prevSelEndOffset = nil
            cv.stopSelectionAutoScroll()
            return
        }
        let startOff = offset(from: beginningOfDocument,to: range.start)
        let endOff = offset(from: beginningOfDocument,to: range.end)
        let draggingEnd: UITextPosition
        if let pe = prevSelEndOffset,endOff != pe {
            draggingEnd = range.end
        } else if let ps = prevSelStartOffset,startOff != ps {
            draggingEnd = range.start
        } else {
            draggingEnd = range.end
        }
        prevSelStartOffset = startOff
        prevSelEndOffset = endOff
        // Remember which handle
        draggingHandleIsEnd = (draggingEnd === range.end)
    }

    private var draggingHandleIsEnd = true

    /// view's edge auto-scroll off it.
    @objc private func handleSelectionDragTrack(_ g: UILongPressGestureRecognizer) {
        guard let cv = findCollectionView() else { return }
        switch g.state {
        case .began,.changed:
            let hasSelection = selectedTextRange.map { !$0.isEmpty } ?? false
            guard hasSelection else { cv.stopSelectionAutoScroll(); return }
            let touchPoint = g.location(in: cv)
            cv.onAutoScrollStep = { [weak self,weak cv] pt in
                guard let self,let cv else { return }
                self.extendSelectionToPoint(pointInCollectionView: pt,cv: cv)
            }
            cv.updateSelectionAutoScroll(touchPoint: touchPoint)
        case .ended,.cancelled,.failed:
            cv.onAutoScrollStep = nil
            cv.stopSelectionAutoScroll()
        default:
            break
        }
    }

    private func extendSelectionToPoint(pointInCollectionView pt: CGPoint,cv: NoAnimationCollectionView) {
        // Convert the REAL touch point
        let pointInSelf = cv.convert(pt,to: self)
        guard let touchPos = closestPosition(to: pointInSelf),
              let current = selectedTextRange else { return }
        let newRange: UITextRange?
        if draggingHandleIsEnd {
            newRange = textRange(from: current.start,to: touchPos)
        } else {
            newRange = textRange(from: touchPos,to: current.end)
        }
        guard let r = newRange,!r.isEmpty else { return }
        // Skip the write when the range
        if let cur = selectedTextRange,
           compare(cur.start,to: r.start) == .orderedSame,
           compare(cur.end,to: r.end) == .orderedSame {
            return
        }
        selectedTextRange = r
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let cv = findCollectionView()
        cv?.offsetLocked = true
        let result = super.becomeFirstResponder()
        cv?.offsetLocked = false
        return result
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let cv = findCollectionView()
        cv?.offsetLocked = true
        let result = super.resignFirstResponder()
        cv?.offsetLocked = false
        if hadSelection {
            hadSelection = false
            cv?.hasActiveTextSelection = false
        }
        // Losing focus ends any
        prevSelStartOffset = nil
        prevSelEndOffset = nil
        cv?.stopSelectionAutoScroll()
        return result
    }

    private func findCell() -> UICollectionViewCell? {
        var view: UIView? = superview
        while let v = view {
            if let cell = v as? UICollectionViewCell { return cell }
            view = v.superview
        }
        return nil
    }

    @objc private func handleInlineCodeTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: self)
        let windowPoint = self.convert(point,to: nil)

        for subview in attachmentViews {
            if subview.frame.contains(point) {
                tapLogger.debug("[tap] hit attachment view at \(String(format: "%.0f,%.0f", point.x, point.y)) — ignored")
                return
            }
        }

        var fraction: CGFloat = 0
        let charIndex = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )

        let isBeyondText = charIndex >= textStorage.length
        let isInGlyphRect: Bool
        if !isBeyondText {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex,effectiveRange: nil)
            isInGlyphRect = lineRect.contains(point)
        } else {
            isInGlyphRect = false
        }
        let isBlankArea = isBeyondText || !isInGlyphRect

        tapLogger.debug("[tap] point=\(String(format: "%.0f,%.0f", point.x, point.y)) charIdx=\(charIndex) len=\(textStorage.length) fraction=\(String(format: "%.2f", fraction)) inGlyph=\(isInGlyphRect) isBlank=\(isBlankArea) hasOnTapBlank=\(onTapBlank != nil)")

        if isBlankArea {
            if let onTapBlank {
                tapLogger.debug("[tap] blank area → calling onTapBlank windowPt=\(String(format: "%.0f,%.0f", windowPoint.x, windowPoint.y))")
                onTapBlank(windowPoint)
            } else {
                tapLogger.debug("[tap] blank area but no onTapBlank handler")
            }
            return
        }

        if let codeText = textStorage.attribute(.inlineCodeText,at: charIndex,effectiveRange: nil) as? String {
            tapLogger.debug("[tap] inline code → copy")
            UIPasteboard.general.string = codeText
            showCopyFeedback(at: charIndex)
            return
        }

        let isLink = textStorage.attribute(.link,at: charIndex,effectiveRange: nil) != nil
        tapLogger.debug("[tap] on text content (link=\(isLink)) — not handled")
    }

    private let tapLogger = AppLogger(category: "MarkdownTap")

    private func showCopyFeedback(at charIndex: Int) {
        var effectiveRange = NSRange()
        guard textStorage.attribute(.inlineCodeText,at: charIndex,effectiveRange: &effectiveRange) != nil else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: effectiveRange,actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange,in: textContainer)

        let flash = UIView(frame: rect.insetBy(dx: -2,dy: -1))
        flash.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18)
        flash.layer.cornerRadius = 4
        flash.isUserInteractionEnabled = false
        addSubview(flash)

        let toast = UILabel()
        toast.text = "Copied"
        toast.font = .systemFont(ofSize: 11,weight: .medium)
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        toast.textAlignment = .center
        toast.layer.cornerRadius = 4
        toast.clipsToBounds = true
        toast.sizeToFit()
        toast.frame.size.width += 12
        toast.frame.size.height += 4
        toast.center = CGPoint(x: rect.midX,y: rect.minY-toast.frame.height/2-4)
        if toast.frame.minX<0 { toast.frame.origin.x = 0 }
        if toast.frame.maxX>bounds.width { toast.frame.origin.x = bounds.width-toast.frame.width }
        toast.alpha = 0
        addSubview(toast)

        UIView.animate(withDuration: 0.15) { toast.alpha = 1 }
        UIView.animate(withDuration: 0.3,delay: 0.8,options: []) {
            flash.alpha = 0
            toast.alpha = 0
        } completion: { _ in
            flash.removeFromSuperview()
            toast.removeFromSuperview()
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == self.panGestureRecognizer {
            let location = gestureRecognizer.location(in: self)
            for subview in attachmentViews {
                if subview.frame.contains(location) {
                    if let codeTV = findCodeTV(in: subview),codeTV.isScrollEnabled {
                        let vel = self.panGestureRecognizer.velocity(in: self)
                        if abs(vel.x)>abs(vel.y) {
                            return false
                        }
                    }
                }
            }
        }
        if gestureRecognizer === inlineCodeTapGesture {
            if let sel = selectedTextRange,!sel.isEmpty { return false }
            let point = gestureRecognizer.location(in: self)
            for subview in attachmentViews {
                if subview.frame.contains(point) { return false }
            }
            let idx = layoutManager.characterIndex(for: point,in: textContainer,fractionOfDistanceBetweenInsertionPoints: nil)
            let isBeyondText = idx >= textStorage.length
            let isInGlyphRect: Bool
            if !isBeyondText {
                let gi = layoutManager.glyphIndexForCharacter(at: idx)
                let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: gi,effectiveRange: nil)
                isInGlyphRect = lineRect.contains(point)
            } else {
                isInGlyphRect = false
            }
            let isBlankArea = isBeyondText || !isInGlyphRect
            if isBlankArea { return onTapBlank != nil }
            if textStorage.attribute(.link,at: idx,effectiveRange: nil) != nil { return false }
            if textStorage.attribute(.inlineCodeText,at: idx,effectiveRange: nil) != nil { return true }
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The selection-drag
        if gestureRecognizer === selectionDragTracker || otherGestureRecognizer === selectionDragTracker {
            return true
        }
        if gestureRecognizer === inlineCodeTapGesture {
            return otherGestureRecognizer is UITapGestureRecognizer
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === inlineCodeTapGesture,
           otherGestureRecognizer is UILongPressGestureRecognizer {
            // The
            if otherGestureRecognizer === selectionDragTracker { return false }
            return true // a real long press must fail before our tap can begin
        }
        return false
    }

    private func findCodeTV(in view: UIView) -> UITextView? {
        for sub in view.subviews {
            if let tv = sub as? UITextView { return tv }
            if let found = findCodeTV(in: sub) { return found }
        }
        return nil
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func canPerformAction(_ action: Selector,withSender sender: Any?) -> Bool {
        let blocked: Set<String> = ["paste:", "cut:", "delete:", "_addShortcut:"]
        if blocked.contains(NSStringFromSelector(action)) {
            return false
        }
        let actionName = NSStringFromSelector(action)
        if actionName.localizedCaseInsensitiveContains("image") {
            return false
        }
        if action == #selector(copyMarkdown(_:))
            || action == #selector(copyRichText(_:))
            || action == #selector(copyScreenshotFromMenu(_:)) {
            return true
        }
        if action == #selector(addSelectionToChatInput(_:)) {
            return selectedRange.length>0
        }
        return super.canPerformAction(action,withSender: sender)
    }

    /// via the `chatInputAppendRequested` notification. ChatView listens
    /// and routes to `MessageListModel.appendToInputText`, which handles the
    @objc func addSelectionToChatInput(_ sender: Any?) {
        guard selectedRange.length>0,
              let range = Range(selectedRange,in: text) else {
            // 运行时打点(2026-08-13):菜单点击但无选中文本。
            AppLogger.shared.warning("[MENU] addSelectionToChatInput 无选中文本 selectedRange.length=\(selectedRange.length)", category: "ChatInputInject")
            return
        }
        let snippet = String(text[range])
        // 运行时打点(2026-08-13):菜单点击成功,发通知前记录选中片段。
        AppLogger.shared.info("[MENU] 点击「添加到输入框」选中 \(snippet.count) 字:\(snippet.prefix(40))", category: "ChatInputInject")
        NotificationCenter.default.post(
            name: .chatInputAppendRequested,
            object: nil,
            userInfo: ["text": snippet]
        )
        resignFirstResponder()
    }

    @objc func copyMarkdown(_ sender: Any?) {
        // Normalize LaTeX delimiters to the
        var md = rawMarkdown
        md = md.replacingOccurrences(of: "\\(", with: "$")
        md = md.replacingOccurrences(of: "\\)", with: "$")
        md = md.replacingOccurrences(of: "\\[", with: "$$")
        md = md.replacingOccurrences(of: "\\]", with: "$$")
        UIPasteboard.general.string = md
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange.length>0 ? selectedRange : NSRange(location: 0,length: attributedText.length)
        UIPasteboard.general.string = plainTextWithTabs(in: range)
    }

    @objc func copyScreenshotFromMenu(_ sender: Any?) {
        onCopyScreenshot?()
    }

    // MARK: - MiniClaw TTS menu actions

    /// Read the WHOLE reply from the start via the MiniClaw TTS stack
    var onReadAloud: (() -> Void)?
    /// Speak an arbitrary text snippet via the MiniClaw TTS stack (vm.speakText).
    var onSpeakText: ((String) -> Void)?

    @objc func readReplyFromMenu(_ sender: Any?) {
        onReadAloud?()
    }

    @objc func readSelectionFromMenu(_ sender: Any?) {
        guard selectedRange.length>0 else { return }
        // plainTextWithTabs expands table/math attachments into speakable text.
        onSpeakText?(plainTextWithTabs(in: selectedRange))
    }

    @objc func copyRichText(_ sender: Any?) {
        let range = selectedRange.length>0 ? selectedRange : NSRange(location: 0,length: attributedText.length)
        let subAttr = attributedText.attributedSubstring(from: range)
        if let rtfData = try? subAttr.data(from: NSRange(location: 0,length: subAttr.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            UIPasteboard.general.setData(rtfData, forPasteboardType: "public.rtf")
        }
        UIPasteboard.general.string = plainTextWithTabs(in: range)
    }

    func plainTextWithTabs(in range: NSRange) -> String {
        let attr = attributedText ?? NSAttributedString()
        guard range.location >= 0,NSMaxRange(range) <= attr.length else {
            return attr.string
        }
        var out = ""
        attr.enumerateAttribute(.attachment,in: range,options: []) { value,subRange,_ in
            if let table = value as? TableAttachment {
                out += table.plainText()
            } else if let math = value as? MathAttachment {
                // Emit LaTeX with $...$ / $$...$$.
                if math.isBlock {
                    out += "$$\(math.latex)$$"
                } else {
                    out += "$\(math.latex)$"
                }
            } else {
                out += (attr.string as NSString).substring(with: subRange)
            }
        }
        // Strip the invisible spacers the markdown
        return out
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200A}", with: "")
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // Remove the SYSTEM speech menu ("Speak…"
        // / "Spell") — it reads with the OS voice, bypassing the MiniClaw TTS
        builder.remove(menu: .speech)
        let copyMd = UICommand(
            title: String(localized: "Copy Markdown"),
            image: UIImage(systemName: "text.quote"),
            action: #selector(copyMarkdown(_:))
        )
        let copyRtf = UICommand(
            title: String(localized: "Copy Rich Text"),
            image: UIImage(systemName: "doc.richtext"),
            action: #selector(copyRichText(_:))
        )
        var extras: [UIMenuElement] = [copyMd,copyRtf]
        // MiniClaw-owned read-aloud entries. "Read
        if selectedRange.length>0,onSpeakText != nil {
            extras.append(UICommand(
                title: String(localized: "Read Selection"),
                image: UIImage(systemName: "speaker.wave.1"),
                action: #selector(readSelectionFromMenu(_:))
            ))
        }
        if onReadAloud != nil {
            extras.append(UICommand(
                title: String(localized: "Read from Start"),
                image: UIImage(systemName: "speaker.wave.2"),
                action: #selector(readReplyFromMenu(_:))
            ))
        }
        let extrasMenu = UIMenu(title: "", options: .displayInline, children: extras)
        builder.insertSibling(extrasMenu,afterMenu: .standardEdit)
        if selectedRange.length>0 {
            let addToInput = UIMenu(title: "", options: .displayInline, children: [
                UICommand(
                    title: String(localized: "Add to Chat Input"),
                    image: UIImage(systemName: "text.insert"),
                    action: #selector(addSelectionToChatInput(_:))
                )
            ])
            builder.insertSibling(addToInput,afterMenu: .standardEdit)
        }
    }

    private var selectionAnchor: Int?

    ///
    ///
    override func touchesBegan(_ touches: Set<UITouch>,with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesBegan(touches,with: event)
            return
        }

        let point = touch.location(in: self)
        let glyphIndex = layoutManager.glyphIndex(for: point,in: textContainer,fractionOfDistanceThroughGlyph: nil)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let isShift = event?.modifierFlags.contains(.shift) == true

        if !isShift,
           charIndex<textStorage.length,
           textStorage.attribute(.link,at: charIndex,effectiveRange: nil) != nil {
            super.touchesBegan(touches,with: event)
            return
        }

        if isShift {
            let anchor = selectionAnchor ?? selectedRange.location
            let newStart = min(anchor,charIndex)
            let newEnd = max(anchor,charIndex)
            selectedRange = NSRange(location: newStart,length: newEnd-newStart)
            if selectionAnchor == nil { selectionAnchor = anchor }
            return
        }

        selectionAnchor = nil

        let sel = selectedRange
        guard sel.length>0 else {
            super.touchesBegan(touches,with: event)
            return
        }

        let selEnd = sel.location+sel.length
        let isInOrAtEdge = NSLocationInRange(charIndex,sel) || charIndex == selEnd

        if isInOrAtEdge {
            super.touchesBegan(touches,with: event)
            return
        }

        let selGlyphRange = layoutManager.glyphRange(forCharacterRange: sel,actualCharacterRange: nil)
        let selRect = layoutManager.boundingRect(forGlyphRange: selGlyphRange,in: textContainer)
        let handleMargin: CGFloat = 44
        if selRect.insetBy(dx: -handleMargin,dy: -handleMargin).contains(point) {
            super.touchesBegan(touches,with: event)
            return
        }

        selectedRange = NSRange(location: charIndex,length: 0)
        resignFirstResponder()
    }

    func clearAllAttachViews() {
        for view in attachmentViews { view.removeFromSuperview() }
        attachmentViews.removeAll()
        attachmentViewMap.removeAll()
        codeBlockViewCache.removeAll()
        // Reset dedupe fingerprint so the next refreshAttachViews fully runs.
        lastUAVStorageLen = -1
        lastUAVWidth = -1
        lastUAVViewCount = -1
    }

    func refreshAttachViews() {
        let storage = self.textStorage
        if storage.length == lastUAVStorageLen,
           abs(self.textContainer.size.width-lastUAVWidth)<0.5,
           !attachmentViewMap.isEmpty,
           attachmentViewMap.count == lastUAVViewCount {
            // `refreshAttachViews` to return early without rebuilding
            var allMapped = true
            var currentTableGenSum: UInt64 = 0
            storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { v,_,stop in
                guard let att = v as? NSTextAttachment else { return }
                if attachmentViewMap[ObjectIdentifier(att)] == nil {
                    allMapped = false
                    stop.pointee = true
                }
                if let table = v as? TableAttachment {
                    currentTableGenSum &+= table.contentGeneration
                }
            }
            if allMapped && currentTableGenSum == lastUAVTableGenSum {
                return
            }
        }
        let imageAttachmentCount: Int = {
            let storage = self.textStorage
            var n = 0
            storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { v,_,_ in
                if v is ImageAttachment { n += 1 }
            }
            return n
        }()
        if imageAttachmentCount>0 {
            AppLogger.shared.info("[UAV] enter imgAttach=\(imageAttachmentCount) prevViews=\(self.attachmentViews.count) tcW=\(String(format: "%.0f", self.textContainer.size.width))", category: "ChatList.Attach")
        }
        let previousViewMap = attachmentViewMap
        var newViews: [UIView] = []
        var newViewMap: [ObjectIdentifier: UIView] = [:]
        var reusedIds: Set<ObjectIdentifier> = []

        let textStorage = self.textStorage
        guard let layoutManager = self.layoutManager as? MiniClawLayoutManager else {
            for view in attachmentViews { view.removeFromSuperview() }
            attachmentViews.removeAll()
            attachmentViewMap.removeAll()
            lastUAVStorageLen = -1
            lastUAVWidth = -1
            lastUAVViewCount = -1
            return
        }

        let fullRange = NSRange(location: 0,length: textStorage.length)
        let containerWidth = self.textContainer.size.width

        let savedContainerHeight = self.textContainer.size.height
        if savedContainerHeight<CGFloat.greatestFiniteMagnitude {
            self.textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        layoutManager.invalidateGlyphs(forCharacterRange: fullRange,changeInLength: 0,actualCharacterRange: nil)
        layoutManager.ensureLayout(forCharacterRange: fullRange)

        textStorage.enumerateAttribute(.attachment,in: fullRange,options: []) { value,range,_ in
            guard let attachment = value as? NSTextAttachment else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,actualCharacterRange: nil)
            var boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange,in: self.textContainer)
            let existingView = previousViewMap[ObjectIdentifier(attachment)]
            // not yet recalculated (e.g. during rebuildAttachViews after an
            if boundingRect.width<1 || (containerWidth>0 && boundingRect.width>containerWidth) {
                boundingRect.size.width = containerWidth
            }

            let attachId = ObjectIdentifier(attachment)
            let view: UIView

            if let existingView = previousViewMap[attachId] {
                var stale = false
                if let imageAttach = attachment as? ImageAttachment {
                    if imageAttach.needsViewRebuild {
                        AppLogger.shared.info("[IMG][UAV] STALE-needsRebuild src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF)", category: "ChatList.Attach")
                        stale = true
                        imageAttach.needsViewRebuild = false
                    }
                    // and recurse back into `rebuildAttachViews` during
                    // `refreshAttachViews`. [AttachHang defensive guard]
                    if imageAttach.loadedImage == nil {
                        imageAttach.onLoad = { [weak self] in
                            DispatchQueue.main.async { self?.rebuildAttachViews() }
                        }
                        imageAttach.beginLoadingIfNeeded()
                    } else {
                        imageAttach.onLoad = nil
                    }
                    if !stale && imageAttach.loadedImage != nil {
                        let hasImageView = existingView.subviews.contains(where: { $0 is UIImageView || ($0.subviews.contains(where: { $0 is UIImageView })) })
                        if !hasImageView {
                            AppLogger.shared.info("[IMG][UAV] STALE-placeholderToLoaded src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — replacing placeholder with image view", category: "ChatList.Attach")
                            stale = true
                        }
                    }
                } else if let videoAttach = attachment as? VideoAttachment {
                    videoAttach.onLoad = { [weak self] in
                        DispatchQueue.main.async { self?.rebuildAttachViews() }
                    }
                    videoAttach.beginLoadingIfNeeded()
                    if videoAttach.thumbnail != nil {
                        stale = !existingView.subviews.contains(where: { $0 is UIImageView || ($0.subviews.contains(where: { $0 is UIImageView })) })
                    }
                } else if let mathAttach = attachment as? MathAttachment {
                    mathAttach.onLoad = { [weak self] in
                        self?.scheduleMathCoalesce()
                    }
                    mathAttach.beginRenderingIfNeeded()
                    if mathAttach.renderedImage != nil {
                        stale = !existingView.subviews.contains(where: { $0 is UIImageView || ($0.subviews.contains(where: { $0 is UIImageView })) })
                    }
                } else if let codeBlock = attachment as? CodeBlockAttachment {
                    codeBlockViewCache[codeBlock.blockIndex] = existingView
                } else if let tableAttach = attachment as? TableAttachment {
                    // MarkdownView fast-path stays alive) but the
                    //
                    // EXCEPT while the
                    let liveScroll = TableAttachment.tableScrollView(in: existingView)
                    let sizeMismatch = abs(existingView.frame.size.height-boundingRect.height)>1
                        || abs(existingView.frame.size.width-boundingRect.width)>1
                    if let liveScroll,
                       liveScroll.isTracking || liveScroll.isDragging || liveScroll.isDecelerating {
                        if tableAttach.needsViewRebuild || sizeMismatch {
                            liveScroll.onInteractionEnded = { [weak self] in
                                DispatchQueue.main.async { self?.rebuildAttachViews() }
                            }
                        }
                    } else if tableAttach.needsViewRebuild {
                        stale = true
                        tableAttach.needsViewRebuild = false
                    } else if sizeMismatch {
                        stale = true
                    }
                }

                if stale {
                    existingView.removeFromSuperview()
                    if let imageAttach = attachment as? ImageAttachment {
                        AppLogger.shared.info("[IMG][UAV] RECREATE src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — same attachment, but stale view → makeView", category: "ChatList.Attach")
                        view = imageAttach.makeView(width: boundingRect.width)
                    } else if let videoAttach = attachment as? VideoAttachment {
                        view = videoAttach.makeView(width: boundingRect.width)
                    } else if let mathAttach = attachment as? MathAttachment {
                        view = mathAttach.makeView(width: boundingRect.width)
                    } else if let tableAttach = attachment as? TableAttachment {
                        if let oldScroll = TableAttachment.tableScrollView(in: existingView),
                           oldScroll.contentOffset.x>0 {
                            tableAttach.preservedScrollOffset = oldScroll.contentOffset
                        }
                        tableAttach.onOpenURL = { [weak self] url in
                            if let coordinator = self?.delegate as? MarkdownView.Coordinator,
                               let openURL = coordinator.openURL {
                                openURL(url)
                            } else {
                                UIApplication.shared.open(url)
                            }
                        }
                        view = tableAttach.makeView(width: boundingRect.width)
                    } else {
                        view = existingView
                    }
                } else {
                    if let imageAttach = attachment as? ImageAttachment {
                        AppLogger.shared.info("[IMG][UAV] REUSE src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — view kept, only frame updated", category: "ChatList.Attach")
                    }
                    view = existingView
                }
                reusedIds.insert(attachId)
                // [抖动诊断 2026-09-12] 附件（尤其图片）视图 frame 发生**实际位移**时打一条。
                // 高度稳定但图片位置在跳 = 视觉上的「抖」，此前只查了高度与 offset，
                // 遗漏了「附件视图重定位」这条路径（本会话特征 = 消息含一张大图）。
                let newFrame = CGRect(origin: boundingRect.origin,size: view.frame.size)
                if view.frame != newFrame, attachment is ImageAttachment {
                    let cv = findCollectionView()
                    AppLogger.shared.info(
                        "[Jitter] IMG-FRAME y \(String(format: "%.1f", view.frame.origin.y))→\(String(format: "%.1f", newFrame.origin.y)) h=\(String(format: "%.1f", view.frame.height)) x=\(String(format: "%.1f", newFrame.origin.x)) tcW=\(String(format: "%.1f", self.textContainer.size.width)) boundsH=\(String(format: "%.1f", self.bounds.height)) scroll=\((cv?.isDragging ?? false) ? "drag" : ((cv?.isDecelerating ?? false) ? "decel" : "idle"))",
                        category: "Jitter")
                }
                view.frame = newFrame
            } else if let codeBlock = attachment as? CodeBlockAttachment {
                // Try to reuse the previous view at the same index via updateExistingAttachView.
                if let previousView = codeBlockViewCache[codeBlock.blockIndex] {
                    codeBlock.updateExistingAttachView(previousView)
                    view = previousView
                    // Trust the height computed by updateExistingAttachView from the
                    view.frame = CGRect(
                        origin: boundingRect.origin,
                        size: CGSize(width: boundingRect.width,height: view.frame.size.height)
                    )
                } else {
                    view = codeBlock.makeView(width: boundingRect.width)
                }
                codeBlockViewCache[codeBlock.blockIndex] = view
            } else if let table = attachment as? TableAttachment {
                // case taps fell through to UIApplication.open and miniclaw://
                table.onOpenURL = { [weak self] url in
                    if let coordinator = self?.delegate as? MarkdownView.Coordinator,
                       let openURL = coordinator.openURL {
                        openURL(url)
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
                view = table.makeView(width: boundingRect.width)
            } else if let thematicBreak = attachment as? ThematicBreakAttachment {
                view = thematicBreak.makeView(width: boundingRect.width)
            } else if let imageAttach = attachment as? ImageAttachment {
                AppLogger.shared.info("[IMG][UAV] NEW src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — no previous view (first render OR ObjectIdentifier changed) → makeView", category: "ChatList.Attach")
                // into rebuildAttachViews. [AttachHang defensive guard]
                if imageAttach.loadedImage == nil {
                    imageAttach.onLoad = { [weak self] in
                        DispatchQueue.main.async { self?.rebuildAttachViews() }
                    }
                    imageAttach.beginLoadingIfNeeded()
                } else {
                    imageAttach.onLoad = nil
                }
                view = imageAttach.makeView(width: boundingRect.width)
            } else if let videoAttach = attachment as? VideoAttachment {
                videoAttach.onLoad = { [weak self] in
                    DispatchQueue.main.async { self?.rebuildAttachViews() }
                }
                videoAttach.beginLoadingIfNeeded()
                view = videoAttach.makeView(width: boundingRect.width)
            } else if let audioAttach = attachment as? AudioAttachment {
                view = audioAttach.makeView(width: boundingRect.width)
            } else if let fileAttach = attachment as? FileAttachment {
                view = fileAttach.makeView(width: boundingRect.width)
            } else if let mathAttach = attachment as? MathAttachment {
                mathAttach.onLoad = { [weak self] in
                    self?.scheduleMathCoalesce()
                }
                mathAttach.beginRenderingIfNeeded()
                view = mathAttach.makeView(width: boundingRect.width)
            } else {
                return
            }

            if boundingRect.origin == .zero {
                layoutManager.invalidateGlyphs(forCharacterRange: range,changeInLength: 0,actualCharacterRange: nil)
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0,length: textStorage.length))
                let retry = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range,actualCharacterRange: nil),in: self.textContainer)
                if retry.origin != .zero {
                    boundingRect = retry
                }
            }
            view.frame.origin = boundingRect.origin
            if view.superview !== self {
                self.addSubview(view)
            }
            newViews.append(view)
            newViewMap[attachId] = view
        }

        let newViewSet = Set(newViewMap.values.map { ObjectIdentifier($0) })
        for (id,view) in previousViewMap where !reusedIds.contains(id) && newViewMap[id] == nil {
            if newViewSet.contains(ObjectIdentifier(view)) { continue }
            view.removeFromSuperview()
        }

        if self.textContainer.size.height != savedContainerHeight {
            self.textContainer.size.height = savedContainerHeight
        }

        attachmentViews = newViews
        attachmentViewMap = newViewMap
        let uavStorage = self.textStorage
        lastUAVStorageLen = uavStorage.length
        var sum: UInt64 = 0
        uavStorage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: uavStorage.length),options: []) { v,_,_ in
            if let table = v as? TableAttachment { sum &+= table.contentGeneration }
        }
        lastUAVTableGenSum = sum
        lastUAVWidth = self.textContainer.size.width
        lastUAVViewCount = newViewMap.count
        setNeedsDisplay()
        #if DEBUG
        // Capture immediately after attachment views
        // (via rebuildAttachViews), so this is the most likely site where
        #endif
    }

    private func rebuildAttachViews() {
        AppLogger.shared.info("[REFRESH] entry — async media-load callback fired (image/video/math finished loading); will run refreshAttachViews + invalidateCellSize", category: "ChatList.Attach")
        guard window != nil else {
            pendingRefreshAfterWindowAttach = true
            return
        }
        // Re-entry guard: `invalidateCellSizeIfChanged` below triggers
        // re-enter `layoutSubviews` → `rebuildAttachViews` if the cell's
        if isRefreshingAttachments {
            reentryGuardHits &+= 1
            attachLogger.warning("[AttachHang][Refresh] RE-ENTRY BLOCKED hits=\(self.reentryGuardHits) window=\(self.window != nil) attachmentViews=\(self.attachmentViews.count)")
            return
        }
        isRefreshingAttachments = true
        defer { isRefreshingAttachments = false }
        //
        if let layoutManager = self.layoutManager as? MiniClawLayoutManager {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0,length: self.textStorage.length),actualCharacterRange: nil)
        }
        // (b) reset the sizeThatFits fingerprint so invalidateCellSizeIfChanged
        lastSizedStorageFingerprint = 0
        lastSizedWidth = -1
        lastComputedHeight = 0
        // otherwise refreshAttachViews sees an empty previousViewMap
        for view in attachmentViews { view.removeFromSuperview() }
        attachmentViews.removeAll()
        attachmentViewMap.removeAll()
        codeBlockViewCache.removeAll()
        // Reset dedupe fingerprint so the next refreshAttachViews fully runs.
        lastUAVStorageLen = -1
        lastUAVWidth = -1
        lastUAVViewCount = -1
        refreshAttachViews()
        // go through invalidateCellSizeIfChanged() which clears the
        invalidateCellSizeIfChanged()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            layer.contents = nil
            for sub in attachmentViews {
                sub.layer.contents = nil
            }
        } else {
            if pendingRefreshAfterWindowAttach {
                pendingRefreshAfterWindowAttach = false
                DispatchQueue.main.async { [weak self] in
                    self?.rebuildAttachViews()
                }
            }
        }
    }

    override func layoutSubviews() {
        let layoutStart = CACurrentMediaTime()
        defer {
            let elapsed = (CACurrentMediaTime()-layoutStart)*1000
            if elapsed >= 50 {
                let attrLen = self.textStorage.length
                let head = attrLen>0
                    ? (self.textStorage.string as NSString)
                        .substring(to: min(40,attrLen))
                        .replacingOccurrences(of: "\n", with: "⏎")
                    : ""
                let ptr = String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
                LoggingManager.shared.writeRawLine(
                    category: "MarkdownLayout",
                    level: "WARN",
                    message: "[HangFix][LayoutSubviews] 💀 \(String(format: "%.0f", elapsed))ms tv=\(ptr) attrLen=\(attrLen) bounds=\(String(format: "%.0fx%.0f", self.bounds.width, self.bounds.height)) head=\"\(head)\""
                )
                LoggingManager.shared.flush()
            }
        }
        super.layoutSubviews()

        //
        // MiniClaw-2026-05-13-084827.ips: every layout pass re-triggers a full
        if textContainer.size.height<CGFloat.greatestFiniteMagnitude {
            textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }

        let currentWidth = textContainer.size.width

        // `MarkdownView.sizeThatFits` — so sub-pt float jitter from
        // cell self-sizing doesn't repeatedly kick `rebuildAttachViews`.
        let widthDelta = abs(currentWidth-lastLayoutWidth)
        if currentWidth>0 && widthDelta>0.5 {
            lastLayoutWidth = currentWidth
            // Also reset the invalidateCellSizeIfChanged fingerprint so it
            if let coord = (self.delegate as? MarkdownView.Coordinator) {
                coord.cachedSizes.removeAll(keepingCapacity: true)
            }
            lastSizedStorageFingerprint = 0
            lastSizedWidth = -1
            let storage = self.textStorage
        if storage.length>0 {
                var ranges: [NSRange] = []
                storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { value,range,_ in
                    if let table = value as? TableAttachment {
                        table.invalidateCachedLayoutForWidthChange()
                        ranges.append(range)
                    }
                }
                if !ranges.isEmpty,let lm = self.layoutManager as? MiniClawLayoutManager {
                    for r in ranges {
                        lm.invalidateLayout(forCharacterRange: r,actualCharacterRange: nil)
                    }
                }
            }
            if !attachmentViews.isEmpty {
                rebuildAttachViews()
            } else if hasUnrenderedAttachments {
                // but refreshAttachViews was skipped earlier because width was 0.
                refreshAttachViews()
                invalidateIntrinsicContentSize()
                invalidateCellSizeIfChanged()
            } else {
                invalidateIntrinsicContentSize()
                invalidateCellSizeIfChanged()
            }
            return
        }

        // match the freshly computed glyph bounding rects. This corrects the
        // first-load case where refreshAttachViews() runs before sizeThatFits
        guard !attachmentViews.isEmpty,
              let layoutManager = self.layoutManager as? MiniClawLayoutManager else { return }
        let textStorage = self.textStorage
        let fullRange = NSRange(location: 0,length: textStorage.length)

        textStorage.enumerateAttribute(.attachment,in: fullRange,options: []) { value,range,_ in
            guard let attachment = value as? NSTextAttachment else { return }
            let attachId = ObjectIdentifier(attachment)
            guard let view = attachmentViewMap[attachId] else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,actualCharacterRange: nil)
            var boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange,in: self.textContainer)
            // retry from refreshAttachViews. If TextKit returns
            if boundingRect.origin == .zero {
                layoutManager.invalidateGlyphs(forCharacterRange: range,changeInLength: 0,actualCharacterRange: nil)
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0,length: textStorage.length))
                let retry = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range,actualCharacterRange: nil),in: self.textContainer)
                if retry.origin != .zero {
                    boundingRect = retry
                }
            }
            if boundingRect.origin != .zero || view.frame.origin == .zero {
                if view.frame.origin != boundingRect.origin {
                    view.frame.origin = boundingRect.origin
                }
            }
        }
    }

    private let cellSizeLogger = AppLogger(category: "CellSize")

    /// currently in `textStorage`. Used as part of the cell-size dedup
    /// fingerprint so in-place table mutations defeat the early-exit even
    /// when textStorage.length is constant.
    private func currentTableGenerationSum() -> UInt64 {
        let storage = textStorage
        guard storage.length>0 else { return 0 }
        var sum: UInt64 = 0
        storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { value,_,_ in
            if let table = value as? TableAttachment {
                sum &+= table.contentGeneration
            }
        }
        return sum
    }

    func invalidateCellSizeIfChanged() {
        guard textContainer.size.width>1 else {
            return
        }
        // [2026-09-08 交汇处卡顿修复] **defer 检查前置——先拒后测改为先拒不测**。
        // 真机日志（MiniClaw-2026-09-08 3.log）：滑动期 deferSelfSizing 激活时，
        // 本函数对每个复用 cell **先真跑一次 sizeThatFits（含附件块 = mtv 全量
        // 重排 755-811ms）**，测完才发现 defer 拒绝消费 → 「SKIPPED … will retry」
        // 风暴（delta 高达 ±2500pt）+ 0.6s 重试循环贯穿整个滑动 → 回滑到新旧
        // 消息交汇处（cell 密集复用区）定点卡一下。
        // 修复：无 ImageAttachment 例外时，defer 激活期**直接 arm 一次性重试并
        // 返回（零测量成本）**；滚动结束后 deferSelfSizing=false，
        // preferredLayoutAttributesFitting 的 flush 自然消费真实高度。
        // （ImageAttachment 的 placeholder→loaded 大增长例外保留：仍先测量，
        //   largeGrowth 放行——见函数后段原 defer 块。）
        if (findCollectionView()?.collectionViewLayout as? MessageListLayout)?.deferSelfSizing == true,
           !hasImageAttachmentCached {
            armDeferredRemeasure()
            return
        }
        // `sizeThatFits` → `invalidateCellSizeIfChanged`. Without this guard
        if isInvalidatingCellSize {
            reentryGuardHits &+= 1
            cellSizeLogger.warning("[AttachHang][CellMetrics] RE-ENTRY BLOCKED hits=\(self.reentryGuardHits) tcW=\(String(format: "%.0f", self.textContainer.size.width)) lastH=\(String(format: "%.1f", self.lastComputedHeight))")
            return
        }
        let measureWidth: CGFloat = bounds.width>1 ? bounds.width : textContainer.size.width
        let tableGenSum = currentTableGenerationSum()
        // [2026-09-13 指纹统一] 用 `ContentFingerprint`（长度 + 全量哈希）替代纯 `textStorage.length`：
        // 等长改写（长度不变、内容不同）在纯长度判据下会被当"未变"⇒ 返回陈旧高度。
        // 成本可接受：一次 O(N) 字节扫描，命中后省下的是完整 TextKit 重排（远贵于扫描）。
        if lastSizedStorageFingerprint != 0,
           ContentFingerprint.of(textStorage.string) == lastSizedStorageFingerprint,
           abs(measureWidth-lastSizedWidth)<0.5,
           tableGenSum == lastSizedTableGenSum,
           lastComputedHeight>0 {
            return
        }
        isInvalidatingCellSize = true
        defer { isInvalidatingCellSize = false }
        let newHeight = sizeThatFits(CGSize(width: measureWidth,height: .greatestFiniteMagnitude)).height
        if textContainer.size.height<CGFloat.greatestFiniteMagnitude {
            textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        let previousHeight = lastComputedHeight
        if abs(newHeight-previousHeight) <= 1 {
            lastSizedStorageFingerprint = ContentFingerprint.of(textStorage.string)
            lastSizedWidth = measureWidth
            lastSizedTableGenSum = tableGenSum
            return
        }
        let delta = newHeight-previousHeight

        // [2026-09-12 裁尾修复+诊断] **引擎文本实测上报** + 零歧义欠高探针。
        //
        // 上报量 = `newHeight`（本视图在自身 `bounds.width` 下刚测出的文本高），**单调取大**。
        // **刻意不含 cell 当前高度**：cell 被抬高后 SwiftUI 不会跟着抬高本视图，任何含
        // cell 高的增量都会每轮再叠一次差值 → 高度跑飞（真机 1365→1383→…→1455，
        // 消息中间大块空白）。由 List 层在提交点用「本值 + 固定装饰」作为下限。
        //
        // 探针判据 `cell.bounds.height < newHeight`：cell 比屏上文本实测更矮 ⇒ 必然裁内容。
        // 不依赖任何装饰差推算（原 `FIRST-MEASURE CORRECTION` 用 `>8` 阈值，会漏掉 4pt 级裁字）。
        if let cell = findCell() as? SelfSizingCell, newHeight > 1 {
            // **最新实测覆盖，不取单调最大**：流式期间渲染会带「表格尾拆分 + 纯文本后缀」，
            // 布局比流式结束后的**最终渲染更高**；若取 max，该历史高值会作为下限残留
            // → 流式结束后 cell 下方出现空白（真机 IMG_4703 之后的新症状，重进会话清零即恢复）。
            // 旧值的「串内容」风险由 `engineTextContentKey` 判定兜住（见其声明处说明）。
            cell.engineTextHeight = newHeight
            cell.engineTextContentKey = cell.contentKey
            cell.engineTextValid = true
            if cell.bounds.height > 4, cell.bounds.height < newHeight - 0.5 {
                cellSizeLogger.info("[CellSize] UNDER-HEIGHT cellH=\(String(format: "%.1f", cell.bounds.height)) textNeed=\(String(format: "%.1f", newHeight)) delta=\(String(format: "%.1f", newHeight-cell.bounds.height)) viewH=\(String(format: "%.1f", bounds.height)) measureW=\(String(format: "%.1f", measureWidth)) tcW=\(String(format: "%.1f", textContainer.size.width)) storage=\(textStorage.length) prevH=\(String(format: "%.1f", previousHeight)) — cell 比文本所需更矮，内容必然被裁")
            }
        }

        // Height genuinely moved. Decide the
        let cvOpt = findCollectionView()
        let layout = cvOpt?.collectionViewLayout as? MessageListLayout
        let isDeferred = layout?.deferSelfSizing ?? false

        //
        // correct 280pt by refreshAttachViews — is clipped by the cell's
        if isDeferred {
            let cellHasImageAttachment: Bool = {
                var found = false
                textStorage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: textStorage.length),options: []) { value,_,stop in
                    if value is ImageAttachment {
                        found = true
                        stop.pointee = true
                    }
                }
                return found
            }()
            let isLargeGrowth = delta>30
            if cellHasImageAttachment && isLargeGrowth {
                cellSizeLogger.info("[AttachHang][CellMetrics] ALLOW through defer — image attachment placeholder→loaded growth prev=\(String(format: "%.1f", previousHeight))→new=\(String(format: "%.1f", newHeight)) delta=\(String(format: "%+.1f", delta))")
            } else {
                // Return WITHOUT touching the
                cellSizeLogger.info("[invalidateCell] SKIPPED — deferSelfSizing active (correction NOT consumed, delta=\(String(format: "%+.1f", delta)); will retry)")
                if !pendingDeferredRemeasure {
                    pendingDeferredRemeasure = true
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.6) { [weak self] in
                        guard let self else { return }
                        self.pendingDeferredRemeasure = false
                        self.invalidateCellSizeIfChanged()
                    }
                }
                return
            }
        }

        lastSizedStorageFingerprint = ContentFingerprint.of(textStorage.string)
        lastSizedWidth = measureWidth
        lastSizedTableGenSum = tableGenSum
        lastComputedHeight = newHeight
        if let coord = self.delegate as? MarkdownView.Coordinator {
            // [高度投毒修复 2026-09-10] 显示侧处于「落后快照」态（250ms 节流复用、
            // storage 短于当前 markdown）时，这里测出的矮高度**不能**配上
            // rawMarkdown 完整长度当指纹写入 cachedSizes——否则 sizeThatFits 的
            // sizeThatFits 的代际守卫（`bindingFingerprint == cachedSizeFingerprint`）会
            // 次次命中矮高度，尾部行被裁。脏态期跳过写入，追赶渲染落地后自然重测。
            if !coord.streamSnapshotStale {
                // REPLACE the whole bucket dict
                let widthKey = Int(measureWidth.rounded())
                coord.cachedSizes.removeAll(keepingCapacity: true)
                coord.cachedSizes[widthKey] = newHeight
                // Key the cache generation by the
                // [2026-09-13 指纹统一] 代际键改用内容指纹（原为 `bindingLenForKey` 长度）：
                // 长度不辨等长改写。来源口径与 `MarkdownView.sizeThatFits` 侧一致 ——
                // 有 `rawMarkdown` 就用它，否则用当前 storage 的实际内容。
                coord.cachedSizeFingerprint = ContentFingerprint.of(
                    rawMarkdown.isEmpty ? textStorage.string : rawMarkdown)
            }
        }

        if previousHeight <= 0 {
            guard let cell = findCell() as? SelfSizingCell,
                  cell.bounds.height>4,
                  abs(cell.bounds.height-newHeight)>8 else { return }
            // [2026-09-12 说明] 此处曾临时加过「写回 memo + 统一缓存」以求收敛。真凶
            //（后台预热用异源 NSLayoutManager 栈把同源高度覆盖成矮值）修复后已回退：
            // 写回值需要 `cell 高 − 文本视图高` 作装饰差，而该差值在「cell 与文本视图
            // 处于不同内容代际」（复用中 / idx=-1）时会失真，实测把 1217pt 抬到 2354.3pt
            // → 消息中间出现大块空白。**兜底不得依赖瞬时不一致的两个量之差。**
            cellSizeLogger.info("[invalidateCell] FIRST-MEASURE CORRECTION cellH=\(String(format: "%.1f", cell.bounds.height)) newH=\(String(format: "%.1f", newHeight)) cellW=\(String(format: "%.1f", cell.bounds.width)) measureW=\(String(format: "%.1f", measureWidth)) tcW=\(String(format: "%.1f", textContainer.size.width)) storage=\(textStorage.length) — cell committed a conflicting height, invalidating")
        }

        if let cell = findCell() as? SelfSizingCell {
            cell.clearCachedHeight()
        }

        cvOpt?.collectionViewLayout.invalidateLayout()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawQuoteBars(in: rect)
    }

    func drawQuoteBars(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let layoutManager = self.layoutManager as? MiniClawLayoutManager else { return }
        let textStorage = self.textStorage

        let theme = MarkdownTheme()
        let fullRange = NSRange(location: 0,length: textStorage.length)

        struct BarSpan {
            let depth: Int
            var rect: CGRect
        }
        var spans: [BarSpan] = []

        //
        func addBarSpan(depth: Int,range: NSRange) {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,actualCharacterRange: nil)
            guard glyphRange.length>0 else { return }

            var spanRect: CGRect = .null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _,usedRect,_,_,_ in
                spanRect = spanRect.isNull ? usedRect : spanRect.union(usedRect)
            }
            guard !spanRect.isNull,spanRect.height>0 else { return }

            if let last = spans.last,last.depth == depth,
               spanRect.minY <= last.rect.maxY+2 {
                spans[spans.count-1].rect = last.rect.union(spanRect)
            } else {
                spans.append(BarSpan(depth: depth,rect: spanRect))
            }
        }

        textStorage.enumerateAttribute(.blockquoteDepth,in: fullRange,options: []) { value,range,_ in
            guard let depth = value as? Int,depth>0 else { return }

            // Split the range into sub-ranges that exclude attachment characters
            var subStart = range.location
            let rangeEnd = range.location+range.length
            for i in range.location..<rangeEnd {
                if textStorage.attribute(.attachment,at: i,effectiveRange: nil) != nil {
                    if i>subStart {
                        addBarSpan(depth: depth,range: NSRange(location: subStart,length: i-subStart))
                    }
                    subStart = i+1
                }
            }
            if subStart<rangeEnd {
                addBarSpan(depth: depth,range: NSRange(location: subStart,length: rangeEnd-subStart))
            }
        }

        // Collect attachment view frames to exclude from bar drawing.
        // TextKit bounding rects for characters near attachments can span the
        // attachment's visual area, causing bars to overlap tables/images.
        let excludeRects = attachmentViews.map { $0.frame }

        // Draw one bar per merged span, splitting around attachment views
        for span in spans {
            // Build list of bar segments by subtracting attachment view regions
            var segments: [(minY: CGFloat,maxY: CGFloat)] = [(span.rect.minY,span.rect.maxY)]
            for exRect in excludeRects {
                // Only exclude if the attachment overlaps this bar's vertical range
                guard exRect.minY<span.rect.maxY && exRect.maxY>span.rect.minY else { continue }
                var newSegments: [(minY: CGFloat,maxY: CGFloat)] = []
                for seg in segments {
                    if exRect.minY <= seg.minY && exRect.maxY >= seg.maxY {
                        // Attachment fully covers this segment — remove it
                        continue
                    } else if exRect.minY>seg.minY && exRect.maxY<seg.maxY {
                        // Attachment splits segment into two
                        newSegments.append((seg.minY,exRect.minY))
                        newSegments.append((exRect.maxY,seg.maxY))
                    } else if exRect.minY <= seg.minY && exRect.maxY>seg.minY {
                        // Attachment trims top of segment
                        newSegments.append((exRect.maxY,seg.maxY))
                    } else if exRect.minY<seg.maxY && exRect.maxY >= seg.maxY {
                        // Attachment trims bottom of segment
                        newSegments.append((seg.minY,exRect.minY))
                    } else {
                        newSegments.append(seg)
                    }
                }
                segments = newSegments
            }

            for seg in segments {
                let segHeight = seg.maxY-seg.minY
                guard segHeight>1 else { continue }
                context.saveGState()
                context.setFillColor(theme.blockquoteBarColor.cgColor)
                for d in 1...span.depth {
                    let x = CGFloat(d-1)*13+1
                    let barRect = CGRect(x: x,y: seg.minY,width: 3,height: segHeight)
                    let barPath = UIBezierPath(roundedRect: barRect,cornerRadius: 2)
                    context.addPath(barPath.cgPath)
                }
                context.fillPath()
                context.restoreGState()
            }
        }
    }
}

// MARK: - MiniClawLayoutManager

let nativeVideoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
final class MiniClawLayoutManager: NSLayoutManager {

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>,count rectCount: Int,forCharacterRange charRange: NSRange,color: UIColor) {
        guard let textStorage = self.textStorage else {
            super.fillBackgroundRectArray(rectArray,count: rectCount,forCharacterRange: charRange,color: color)
            return
        }

        var hasInlineCode = false
        if charRange.location+charRange.length <= textStorage.length {
            textStorage.enumerateAttribute(.inlineCodeBackground,in: charRange,options: []) { value,_,_ in
                if value != nil { hasInlineCode = true }
            }
        }

        guard hasInlineCode,let context = UIGraphicsGetCurrentContext() else {
            super.fillBackgroundRectArray(rectArray,count: rectCount,forCharacterRange: charRange,color: color)
            return
        }

        // Same dynamic color as the theme; resolve
        let bgColor = miniClawInlineCodeBackgroundColor.resolvedColor(with: UITraitCollection.current)
        context.saveGState()
        context.setFillColor(bgColor.cgColor)

        let glyphRange = self.glyphRange(forCharacterRange: charRange,actualCharacterRange: nil)

        var lineFragCount = 0
        enumerateLineFragments(forGlyphRange: glyphRange) { _,_,_,_,_ in
            lineFragCount += 1
        }

        for i in 0..<rectCount {
            var rawRect = rectArray[i]
            guard rawRect.width>2 else { continue }

            var hasVisibleText = false
            var correctedOriginY: CGFloat = rawRect.minY
            var correctedHeight: CGFloat = rawRect.height
            enumerateLineFragments(forGlyphRange: glyphRange) { lineFragRect,usedRect,_,lineGlyphRange,_ in
                guard lineFragRect.midY >= rawRect.minY && lineFragRect.midY <= rawRect.maxY else { return }
                let overlapStart = max(glyphRange.location,lineGlyphRange.location)
                let overlapEnd = min(NSMaxRange(glyphRange),NSMaxRange(lineGlyphRange))
                guard overlapEnd>overlapStart else { return }
                let overlapCharRange = self.characterRange(forGlyphRange: NSRange(location: overlapStart,length: overlapEnd-overlapStart),actualGlyphRange: nil)
                guard overlapCharRange.length>0 else { return }
                let overlapText = (textStorage.string as NSString).substring(with: overlapCharRange)
                if !overlapText.trimmingCharacters(in: .whitespaces).isEmpty {
                    hasVisibleText = true
                    if rawRect.height>usedRect.height+2 {
                        correctedOriginY = usedRect.minY
                        correctedHeight = usedRect.height
                    }
                    if lineFragCount == 1 && rawRect.height<usedRect.height*0.8 {
                        correctedOriginY = usedRect.minY
                        correctedHeight = usedRect.height
                    }
                }
            }
            guard hasVisibleText else { continue }

            rawRect = CGRect(x: rawRect.minX,y: correctedOriginY,width: rawRect.width,height: correctedHeight)

            let codeFont = textStorage.attribute(.font,at: charRange.location,effectiveRange: nil) as? UIFont
            let fontLineHeight = codeFont?.lineHeight ?? rawRect.height
            let bgPaddingV: CGFloat = 2 // top + bottom padding inside the pill
            let bgHeight = min(fontLineHeight+bgPaddingV*2,rawRect.height)
            let bgY = rawRect.midY-bgHeight/2-0.5
            let rect = CGRect(x: rawRect.minX-0.5,y: bgY,width: rawRect.width+1,height: bgHeight)
            let path = UIBezierPath(roundedRect: rect,cornerRadius: 5)
            context.addPath(path.cgPath)
        }
        context.fillPath()
        context.restoreGState()
    }
}

// MARK: - MarkdownTextView

final class AudioTapGesture: UITapGestureRecognizer {
    static var expandTapKey: UInt8 = 0
    var fileURL: URL?

    @objc func handleTap() {
        guard let url = fileURL else { return }
        // 2026-08-12 治本:音频点击走系统预览(Quick Look,与 iOS 文件 App 一致)。
        // 此前是自定义 MiniClawAudioPreviewView——非系统预览形式。
        NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
    }
}

final class VideoTapGesture: UITapGestureRecognizer {
    var fileURL: URL?

    @objc func handleTap() {
        guard let url = fileURL else { return }
        // 2026-08-12 治本:视频点击走系统预览(Quick Look,与 iOS 文件 App 一致)。
        // 此前是自定义 MiniClawVideoFullscreenPlayer——非系统预览形式。
        NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
    }
}
