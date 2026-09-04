import SwiftUI
import UIKit
import Foundation
import Combine
final class MarkdownTextView: UITextView,UIGestureRecognizerDelegate {
    private var attachmentViews: [UIView] = []
    /// Returns true if the text storage contains NSTextAttachment objects but no attachment views
    /// have been created yet. Used by updateUIView to detect the LazyVStack reappear case where
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
    /// Whether a same-markdown attachment recovery has already been scheduled/performed
    /// for the current attributedText snapshot. Prevents repeated recovery storms while
    /// LazyVStack / SwiftUI is still settling.
    var hasScheduledRecoveryForCurrentContent = false

    /// Invoked when the user picks "Copy Screenshot" from the text selection menu.
    /// Set by the SwiftUI layer so the menu item can reach the owning turn.
    var onCopyScreenshot: (() -> Void)?

    /// Coalesce guard for math-attachment `onLoad` refreshes. With hundreds of
    /// formulas each completing asynchronously, scheduling a full
    /// `rebuildAttachViews()` per callback multiplies the cost N×; instead
    /// we set this flag, dispatch one refresh, and clear it on arrival.
    private var pendingMathRefresh = false

    /// Schedule at most one `rebuildAttachViews()` per runloop tick from
    /// math-attachment `onLoad` callbacks. Safe to call any number of times.
    func scheduleMathCoalesce() {
        guard !pendingMathRefresh else { return }
        pendingMathRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingMathRefresh = false
            self.rebuildAttachViews()
        }
    }

    /// Reset whenever attributedText content changes, so a future same-markdown reappear
    /// may recover once if attachments are missing/incomplete.
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

    /// Maps attachment identity (ObjectIdentifier) to its current UIView, for reuse during streaming.
    private var attachmentViewMap: [ObjectIdentifier: UIView] = [:]

    /// Fingerprint of the last successful refreshAttachViews invocation.
    /// Tuple = (textStorage.length, textContainer.size.width, attachmentViewMap.count).
    /// When the next call sees the same fingerprint AND every attachment in
    /// storage is already in attachmentViewMap, we can skip the full
    /// enumeration — there's nothing to do. This eliminates the redundant
    /// 2nd/3rd UAV call SwiftUI's UIHostingConfiguration triggers per BIG-CELL
    /// onscreen (window=nil → window-set → layoutSubviews chain).
    private var lastUAVStorageLen: Int = -1
    private var lastUAVWidth: CGFloat = -1
    private var lastUAVViewCount: Int = -1
    /// [TableDedupBug] Tracks the sum of all TableAttachments' contentGeneration
    /// at the moment of the last successful `refreshAttachViews` pass.
    /// Without this term the per-token streaming attachment mutations (which
    /// preserve textStorage length) defeat the (storageLen+width+viewCount)
    /// fingerprint and the table view never gets re-rendered with the new
    /// rows. See the entry-block dedup in `refreshAttachViews` for the
    /// matching consumer.
    private var lastUAVTableGenSum: UInt64 = 0
    /// Maps code block sequential index to its current UIView, for reuse when content changes
    /// (new attachment object but same visual position). Allows `updateExistingAttachView` instead of full rebuild.
    var codeBlockViewCache: [Int: UIView] = [:]
    /// Tracks the last textContainer width used for layout, to detect rotation/size changes.
    private var lastLayoutWidth: CGFloat = 0
    /// Tracks the last computed intrinsic content height to detect when height changes
    /// and the parent collection view cell needs to re-self-size.
    var lastComputedHeight: CGFloat = 0

    /// Fingerprint inputs that produced `lastComputedHeight`. Used by
    /// `invalidateCellSizeIfChanged` to skip the costly sizeThatFits + collection
    /// view layout invalidation when nothing observable changed since the last
    /// measurement. Refreshed after a successful sizeThatFits.
    private var lastSizedStorageLen: Int = -1
    private var lastSizedWidth: CGFloat = -1
    /// Sum of every TableAttachment's `contentGeneration` at the moment of
    /// the last successful sizeThatFits. Streaming tables mutate their rows
    /// in place without changing textStorage.length, so without this extra
    /// term the `(storageLen, width)` dedup fingerprint would falsely report
    /// "unchanged" and the cell would never re-measure — visible to the
    /// user as the table rendering only its first column / first row(s)
    /// even though the markdown source already contains the full table.
    private var lastSizedTableGenSum: UInt64 = 0
    /// Raw markdown source for "Copy Markdown" action.
    var rawMarkdown: String = ""

    // MARK: Attachment-layout re-entry guards (defensive — image-attachment hang)
    /// Set while `rebuildAttachViews` is executing. Same-runloop re-entry
    /// (e.g. `beginLoadingIfNeeded` synchronously firing `onLoad` from the
    /// `NativeMediaImageCache` hit path) would otherwise recurse into itself.
    private var isRefreshingAttachments = false
    /// Set while `invalidateCellSizeIfChanged` is executing. The collection-view
    /// `invalidateLayout()` it triggers can synchronously re-enter
    /// `preferredLayoutAttributesFitting` → `sizeThatFits` → `invalidateCellSizeIfChanged`.
    private var isInvalidatingCellSize = false
    /// Armed when a REAL height change was
    /// detected during a deferSelfSizing window and the correction had to be
    /// skipped. Guarantees one post-settle retry of invalidateCellSizeIfChanged
    /// even if no further UAV/measure call arrives after the glide ends.
    private var pendingDeferredRemeasure = false
    /// Records the last time the layout loop tripped the re-entry guard, for
    /// watchdog diagnostics. If this fires many times per second we know the
    /// loop is hot even if we successfully short-circuit it.
    private var reentryGuardHits: Int = 0

    /// Set when `rebuildAttachViews` was dropped because the view was
    /// detached from window (`window == nil`). Replayed from
    /// `didMoveToWindow` once the view is re-attached so an async image load
    /// that completed while off-screen still gets its cell-size grow.
    ///
    /// Background: when an assistant message contains multiple inline images
    /// that load asynchronously, the LAST image's `onLoad` callback can
    /// arrive after the cell has been briefly recycled out of window (scroll
    /// off-screen, then user immediately scrolls back). With the
    /// `window != nil` guard at the top of `rebuildAttachViews` the
    /// refresh is silently dropped, leaving the cell sized to the last
    /// known attachment bounds (where the final image was still a 200pt
    /// placeholder). Scrolling back never re-triggers the refresh, so the
    /// last image renders clipped or empty until the user exits + re-enters
    /// the chat. (T-multi-image-last d8a51f73.)
    private var pendingRefreshAfterWindowAttach = false

    init() {
        // Use TextKit 1 for reliable NSLayoutManager overrides
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
        // Symmetric 4pt top/bottom inset. Bottom was there originally to keep
        // emoji and Latin descenders (g, p, y) off the clipping edge under
        // TextKit 1; without a matching TOP inset the ascender of glyphs
        // whose mark extends above cap-height — the dot on "i" / "j",
        // accents, the curl on "f" — gets sliced by `clipsToBounds = true`
        // when the first line's `lineFragmentRect` starts at y=0. T-dot-clip
        // 8d2c7f4a.
        //
        // 4pt matches the bottom inset and fits the heightForBlock precalc's
        // existing `bounds.height + 8` buffer (4 top + 4 bottom = 8), so no
        // change is needed in the height-cache layer.
        textContainerInset = UIEdgeInsets(top: 4,left: 0,bottom: 4,right: 0)
        backgroundColor = .clear
        textContainer.lineBreakMode = .byWordWrapping
        // Prevent UITextView from inserting extra padding
        contentInset = .zero
        clipsToBounds = true
        textDragInteraction?.isEnabled = false
        linkTextAttributes = [
            .foregroundColor: MarkdownTheme().linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        // Tap gesture for inline code copy
        let codeTap = UITapGestureRecognizer(target: self,action: #selector(handleInlineCodeTap(_:)))
        codeTap.delegate = self
        addGestureRecognizer(codeTap)
        inlineCodeTapGesture = codeTap

        // A non-cancelling,
        // zero-duration long-press that simply TRACKS the live touch during a
        // selection-handle drag. It never consumes the touch (cancelsTouchesInView
        // = false, recognizes simultaneously with everything) so UIKit's own
        // selection knobs keep working; we only read its location to drive the
        // collection view's edge auto-scroll while the finger is held. Unlike the
        // first cut, this gives us a real drag lifecycle (.ended/.cancelled =
        // finger lift) and a per-frame touch position, so holding still at the
        // edge keeps scrolling.
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
    // UIContextMenuInteraction that, when an inline NSTextAttachment carries an
    // image (our TableAttachment / CodeBlockAttachment / MathAttachment all use a
    // transparent placeholder image for layout), long-press pops the system
    // image preview menu — "Copy Image" / "Save to Camera Roll" over an all-black
    // (transparent-placeholder) preview. There is no delegate hook to suppress
    // it on iOS 16 (the UITextItem.menuConfiguration API is iOS 17+, which is why
    // 17/18 are handled in menuConfigurationFor and 16 slipped through). We strip
    // the system context-menu interaction as UIKit installs it; the app's own
    // affordances don't depend on it — text selection/copy uses the edit menu
    // (UIMenuController) and table cells promote to TableCellTextView with their
    // own Copy Table / Copy Table Image menu. Gated to iOS <17 so 17+ keeps the
    // (handled) system menu and link/text-item previews.
    override func addInteraction(_ interaction: any UIInteraction) {
        if #unavailable(iOS 17.0),interaction is UIContextMenuInteraction {
            return
        }
        super.addInteraction(interaction)
    }

    private weak var selectionDragTracker: UILongPressGestureRecognizer?

    private weak var inlineCodeTapGesture: UITapGestureRecognizer?
    /// Called when the user taps a blank (non-link, non-code) area.
    /// The CGPoint is the tap location in **window coordinates**.
    var onTapBlank: ((CGPoint) -> Void)?

    /// Track whether we have an active (non-empty) text selection and notify
    /// the parent NoAnimationCollectionView.
    private var hadSelection = false
    /// Offsets (from beginningOfDocument) of the previous selection's start/end,
    /// so we can tell which handle is the one being dragged this change.
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
        // change while a selection is active (the user is dragging a handle),
        // report the MOVING handle's caret to the collection view so it can
        // auto-scroll when that handle nears an edge. UITextView's own
        // auto-scroll only moves the text view, not the outer list.
        guard let cv else { return }
        guard hasSelection,let range = selectedTextRange else {
            prevSelStartOffset = nil
            prevSelEndOffset = nil
            cv.stopSelectionAutoScroll()
            return
        }
        let startOff = offset(from: beginningOfDocument,to: range.start)
        let endOff = offset(from: beginningOfDocument,to: range.end)
        // The handle that moved since last change is the dragging one. On the
        // first change of a new selection (no prev), default to the end handle.
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
        // (start vs end) is the one being dragged so the auto-scroll step can
        // extend THAT end to the content scrolled under the finger.
        draggingHandleIsEnd = (draggingEnd === range.end)
    }

    /// Which selection handle the user is currently dragging (true = end/right,
    /// false = start/left). Used to extend the correct end while auto-scrolling.
    private var draggingHandleIsEnd = true

    /// Tracks the live selection-handle drag touch and drives the collection
    /// view's edge auto-scroll off it.
    @objc private func handleSelectionDragTrack(_ g: UILongPressGestureRecognizer) {
        guard let cv = findCollectionView() else { return }
        switch g.state {
        case .began,.changed:
            // Only drive auto-scroll while a real (non-empty) selection exists —
            // i.e. the user is dragging a selection handle, not just touching.
            let hasSelection = selectedTextRange.map { !$0.isEmpty } ?? false
            guard hasSelection else { cv.stopSelectionAutoScroll(); return }
            // Feed the live touch Y in the collection view's coordinate space and
            // wire the per-frame selection-follow callback.
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

    /// After an auto-scroll step, extend the dragging end of the selection to the
    /// document position now under the held touch, so the range follows the
    /// scrolled-in content (the iMessage-style behavior).
    private func extendSelectionToPoint(pointInCollectionView pt: CGPoint,cv: NoAnimationCollectionView) {
        // Convert the REAL touch point
        // (both X and Y) into this text view's coordinates. The earlier version
        // used the text view's mid-X, so the caret it computed sat at a
        // different in-line position than UIKit's own native caret (driven by
        // the real touch X). The two then overwrote `selectedTextRange` with
        // different ranges on alternating frames — the handle/highlight redrew
        // back and forth = the reported edge flicker. Using the real X makes our
        // computed caret agree with UIKit's, so they no longer fight.
        let pointInSelf = cv.convert(pt,to: self)
        guard let touchPos = closestPosition(to: pointInSelf),
              let current = selectedTextRange else { return }
        let newRange: UITextRange?
        if draggingHandleIsEnd {
            // Dragging the end handle downward: anchor = start, moving = touch.
            newRange = textRange(from: current.start,to: touchPos)
        } else {
            // Dragging the start handle upward: anchor = end, moving = touch.
            newRange = textRange(from: touchPos,to: current.end)
        }
        guard let r = newRange,!r.isEmpty else { return }
        // Skip the write when the range
        // is unchanged — re-assigning the same selection still forces UITextView
        // to redraw its handles/highlight, adding to the per-frame churn.
        // UITextPosition is a reference type, so compare by document offset
        // rather than identity.
        if let cur = selectedTextRange,
           compare(cur.start,to: r.start) == .orderedSame,
           compare(cur.end,to: r.end) == .orderedSame {
            return
        }
        selectedTextRange = r
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        // Momentarily lock the collection view's contentOffset during
        // becomeFirstResponder to block UIKit's _adjustContentOffsetIfNecessary.
        let cv = findCollectionView()
        cv?.offsetLocked = true
        let result = super.becomeFirstResponder()
        cv?.offsetLocked = false
        return result
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        // Momentarily lock during resignFirstResponder too.
        let cv = findCollectionView()
        cv?.offsetLocked = true
        let result = super.resignFirstResponder()
        cv?.offsetLocked = false
        // Safety net: always clear selection lock when losing focus.
        if hadSelection {
            hadSelection = false
            cv?.hasActiveTextSelection = false
        }
        // Losing focus ends any
        // selection drag — stop the edge auto-scroll ticker immediately.
        prevSelStartOffset = nil
        prevSelEndOffset = nil
        cv?.stopSelectionAutoScroll()
        return result
    }

    /// Walk the superview chain to find the parent NoAnimationCollectionView.
    func findCollectionView() -> NoAnimationCollectionView? {
        var view: UIView? = superview
        while let v = view {
            if let cv = v as? NoAnimationCollectionView { return cv }
            view = v.superview
        }
        return nil
    }

    /// Walk up the view hierarchy to find the enclosing UICollectionViewCell.
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

        // Check if tap is inside an attachment view (code block, table, image, etc.)
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

        // Determine if the tap is actually over rendered text or in empty space.
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

        // Inline code: copy it
        if let codeText = textStorage.attribute(.inlineCodeText,at: charIndex,effectiveRange: nil) as? String {
            tapLogger.debug("[tap] inline code → copy")
            UIPasteboard.general.string = codeText
            showCopyFeedback(at: charIndex)
            return
        }

        // Link or plain text — don't intercept
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

        // Show "Copied" toast near the code
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
        // Keep toast within text view bounds
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

    // Allow code block UITextViews to handle horizontal pans.
    // The outer text view's panGestureRecognizer can intercept touches
    // even when isScrollEnabled=false; reject horizontal pans that
    // originate inside a scrollable code block subview.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == self.panGestureRecognizer {
            let location = gestureRecognizer.location(in: self)
            // Check if touch is inside any code block UITextView subview
            for subview in attachmentViews {
                if subview.frame.contains(location) {
                    // Find the UITextView inside this attachment view
                    if let codeTV = findCodeTV(in: subview),codeTV.isScrollEnabled {
                        let vel = self.panGestureRecognizer.velocity(in: self)
                        // If primarily horizontal, let the inner code block handle it
                        if abs(vel.x)>abs(vel.y) {
                            return false
                        }
                    }
                }
            }
        }
        // Inline code tap / blank area tap: allow unless tapping a link or attachment view
        if gestureRecognizer === inlineCodeTapGesture {
            // Don't interfere with active text selection
            if let sel = selectedTextRange,!sel.isEmpty { return false }
            let point = gestureRecognizer.location(in: self)
            // Don't interfere with attachment views (code blocks, tables, images)
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
            // Blank area → allow if handler exists
            if isBlankArea { return onTapBlank != nil }
            // On a link → don't begin (UITextView handles it)
            if textStorage.attribute(.link,at: idx,effectiveRange: nil) != nil { return false }
            // On inline code → allow
            if textStorage.attribute(.inlineCodeText,at: idx,effectiveRange: nil) != nil { return true }
            // On plain text → don't intercept (let text selection work)
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    // Allow our tap gesture to coexist with other tap gestures (e.g. link taps),
    // but NOT with long-press or pan gestures used for text selection.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The selection-drag
        // tracker is a pure observer — it must run alongside UIKit's selection
        // knobs and everything else, and never blocks another gesture.
        if gestureRecognizer === selectionDragTracker || otherGestureRecognizer === selectionDragTracker {
            return true
        }
        if gestureRecognizer === inlineCodeTapGesture {
            return otherGestureRecognizer is UITapGestureRecognizer
        }
        return false
    }

    // When the user is actively selecting text (selection range exists and is non-zero),
    // don't let our tap gesture interfere with the selection handles.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === inlineCodeTapGesture,
           otherGestureRecognizer is UILongPressGestureRecognizer {
            // The
            // selection-drag tracker is a `minimumPressDuration = 0` long-press,
            // so it SUCCEEDS on touch-down and never fails. Requiring it to fail
            // (the blanket `is UILongPressGestureRecognizer` rule) permanently
            // blocked codeTap, so tapping inline code did nothing. Only require a
            // *real* long-press (text selection) to fail; never the tracker.
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
        // Block edit-related actions since we're read-only; allow everything else
        // (select, copy, look up, share, Copy Markdown, etc.)
        let blocked: Set<String> = ["paste:", "cut:", "delete:", "_addShortcut:"]
        if blocked.contains(NSStringFromSelector(action)) {
            return false
        }
        // iOS 16: long-pressing inline NSTextAttachment objects that carry a
        // transparent placeholder UIImage (TableAttachment, CodeBlockAttachment,
        // MathAttachment, etc.) makes the system add "Copy Image" / "Save
        // Image" / "Share Image" entries to UIMenuController. The image is a
        // 1×1 transparent placeholder used so UIKit doesn't render a default
        // "?" glyph — copying it is meaningless. Filter the relevant
        // selectors so the menu only surfaces actions that work on the
        // underlying text. iOS 17+ uses UIEditMenuInteraction and doesn't
        // present these by default.
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

    /// Append the currently-selected text to the active chat's input field
    /// via the `chatInputAppendRequested` notification. ChatView listens
    /// and routes to `MessageListModel.appendToInputText`, which handles the
    /// `<existing> <selected> ` / `<selected> ` formatting.
    @objc func addSelectionToChatInput(_ sender: Any?) {
        guard selectedRange.length>0,
              let range = Range(selectedRange,in: text) else {
            // 运行时打点(2026-08-13):菜单点击但无选中文本。
            AppLogger(category: "ChatInputInject").warning("[MENU] addSelectionToChatInput 无选中文本 selectedRange.length=\(selectedRange.length)")
            return
        }
        let snippet = String(text[range])
        // 运行时打点(2026-08-13):菜单点击成功,发通知前记录选中片段。
        AppLogger(category: "ChatInputInject").info("[MENU] 点击「添加到输入框」选中 \(snippet.count) 字:\(snippet.prefix(40))")
        NotificationCenter.default.post(
            name: .chatInputAppendRequested,
            object: nil,
            userInfo: ["text": snippet]
        )
        // Drop the selection / dismiss the edit menu so the user sees the
        // result land in the input. Mirrors the system Copy behaviour.
        resignFirstResponder()
    }

    /// Copies the raw Markdown source to the pasteboard.
    @objc func copyMarkdown(_ sender: Any?) {
        // Normalize LaTeX delimiters to the
        // $...$ / $$...$$ form that most LaTeX editors expect. LLM output often
        // uses the \(...\) / \[...\] alternate delimiters which are valid LaTeX
        // but not recognized by many markdown renderers.
        var md = rawMarkdown
        md = md.replacingOccurrences(of: "\\(", with: "$")
        md = md.replacingOccurrences(of: "\\)", with: "$")
        md = md.replacingOccurrences(of: "\\[", with: "$$")
        md = md.replacingOccurrences(of: "\\]", with: "$$")
        UIPasteboard.general.string = md
    }

    /// Override the standard Copy so selections spanning tables include table
    /// cell text instead of a single space (the default attachment fallback).
    override func copy(_ sender: Any?) {
        let range = selectedRange.length>0 ? selectedRange : NSRange(location: 0,length: attributedText.length)
        UIPasteboard.general.string = plainTextWithTabs(in: range)
    }

    /// Invokes the Copy Screenshot closure plumbed through from SwiftUI.
    @objc func copyScreenshotFromMenu(_ sender: Any?) {
        onCopyScreenshot?()
    }

    // MARK: - MiniClaw TTS menu actions

    /// Read the WHOLE reply from the start via the MiniClaw TTS stack
    /// (vm.readReplyFromStart). Plumbed from the cell bridge; nil while the
    /// reply is still streaming (would clash with live streaming TTS).
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

    /// Copies the rendered rich text (RTF) to the pasteboard.
    @objc func copyRichText(_ sender: Any?) {
        let range = selectedRange.length>0 ? selectedRange : NSRange(location: 0,length: attributedText.length)
        let subAttr = attributedText.attributedSubstring(from: range)
        if let rtfData = try? subAttr.data(from: NSRange(location: 0,length: subAttr.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            UIPasteboard.general.setData(rtfData, forPasteboardType: "public.rtf")
        }
        // Also write plain-text fallback that includes table cell content (the
        // RTF substring's NSTextAttachment for tables collapses to a space when
        // pasted into plain-text targets).
        UIPasteboard.general.string = plainTextWithTabs(in: range)
    }

    /// Returns the plain-text representation of `range`, expanding any
    /// `TableAttachment` runs into tab-separated cell text so multi-block
    /// selections that span a table preserve table content on copy.
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
        // pre-pass injects to fix CommonMark flanking around CJK punctuation
        // (ZWSP now; hair space from the pre-2026-05 fixers may survive in
        // cached attributed strings) — they must not leak into the clipboard
        // or the TTS text.
        return out
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200A}", with: "")
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // Remove the SYSTEM speech menu ("Speak…"
        // / "Spell") — it reads with the OS voice, bypassing the MiniClaw TTS
        // stack (provider voices, sanitizer, fail-over). Replaced below with
        // our own Read Selection / Read Reply entries.
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
        // Selection" speaks just the selected range; "Read from Start" replays
        // the whole reply — both through the in-app TTS stack.
        // Matching speaker glyph family so the two read-aloud entries read as
        // one feature: selection = plain speaker, whole reply = speaker+waves.
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
        // insertSibling(afterMenu: .standardEdit) pushes successive inserts
        // toward the anchor — i.e. the LAST inserted sibling lands closest to
        // standardEdit. Insert the secondary copy commands first so the
        // high-frequency "Add to Chat Input" action ends up immediately after
        // the system Copy item.
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

    // MARK: Selection Dismissal

    /// Anchor character index for Shift+Click range selection.
    private var selectionAnchor: Int?

    /// Clear text selection on the first tap outside the selected range.
    ///
    /// By default, UITextView (isSelectable=true, isEditable=false) intercepts the
    /// first tap to manipulate the selection, so the outer SwiftUI .onTapGesture
    /// never fires — the user has to tap twice to dismiss the selection and trigger
    /// the parent's tap handler. This override detects a tap outside the current
    /// selection and immediately clears it, then lets the touch propagate normally
    /// so the parent view responds on the same tap.
    ///
    /// When Shift is held (external keyboard), extends the selection from the
    /// anchor to the tap point.
    override func touchesBegan(_ touches: Set<UITouch>,with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesBegan(touches,with: event)
            return
        }

        let point = touch.location(in: self)
        let glyphIndex = layoutManager.glyphIndex(for: point,in: textContainer,fractionOfDistanceThroughGlyph: nil)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let isShift = event?.modifierFlags.contains(.shift) == true

        // Tap on a link: always let UITextView handle it so the link-interaction
        // path (primaryActionFor / shouldInteractWith) fires. Otherwise a stale
        // selection from a prior interaction (which survives until SwiftUI
        // recycles the view) would cause the selection-handling branch below to
        // swallow the touch and the link would silently no-op.
        if !isShift,
           charIndex<textStorage.length,
           textStorage.attribute(.link,at: charIndex,effectiveRange: nil) != nil {
            super.touchesBegan(touches,with: event)
            return
        }

        // Shift+click: extend selection from anchor to clicked position.
        if isShift {
            let anchor = selectionAnchor ?? selectedRange.location
            let newStart = min(anchor,charIndex)
            let newEnd = max(anchor,charIndex)
            selectedRange = NSRange(location: newStart,length: newEnd-newStart)
            // Keep the original anchor so further Shift+clicks extend from the same point.
            if selectionAnchor == nil { selectionAnchor = anchor }
            return
        }

        // Non-shift click resets the anchor.
        selectionAnchor = nil

        let sel = selectedRange
        guard sel.length>0 else {
            super.touchesBegan(touches,with: event)
            return
        }

        // If the tap lands inside or at the edge of the selected range, let UITextView
        // handle it normally (the user may be tapping or dragging a selection handle).
        let selEnd = sel.location+sel.length
        let isInOrAtEdge = NSLocationInRange(charIndex,sel) || charIndex == selEnd

        if isInOrAtEdge {
            super.touchesBegan(touches,with: event)
            return
        }

        // Also check if the touch point is geometrically close to a selection handle.
        let selGlyphRange = layoutManager.glyphRange(forCharacterRange: sel,actualCharacterRange: nil)
        let selRect = layoutManager.boundingRect(forGlyphRange: selGlyphRange,in: textContainer)
        let handleMargin: CGFloat = 44
        if selRect.insetBy(dx: -handleMargin,dy: -handleMargin).contains(point) {
            super.touchesBegan(touches,with: event)
            return
        }

        // Tap is outside the selection — clear it immediately so this single tap
        // also propagates to the parent SwiftUI view as expected.
        selectedRange = NSRange(location: charIndex,length: 0)
        resignFirstResponder()
        // Do NOT call super: we've already cleared the selection and we want the
        // touch to fall through to the scroll view / SwiftUI gesture recognizers.
    }

    // MARK: Attachment Views

    /// Remove all attachment subviews and clear tracking state.
    /// Called when SwiftUI recycles this view for a different message.
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
        // [AttachHotPath] Dedupe: when nothing relevant changed since the last
        // successful call AND the existing view map already covers every
        // attachment in storage, there is nothing to do — every branch in the
        // enumeration below would land in `reuse` and just re-set the same
        // frame. This skip eliminates the redundant 2nd/3rd UAV call per
        // BIG-CELL onscreen (window=nil → window-set chain that SwiftUI
        // UIHostingConfiguration triggers on cell reuse).
        let storage = self.textStorage
        if storage.length == lastUAVStorageLen,
           abs(self.textContainer.size.width-lastUAVWidth)<0.5,
           !attachmentViewMap.isEmpty,
           attachmentViewMap.count == lastUAVViewCount {
            // Verify every attachment in storage is in the map, AND that
            // each TableAttachment's contentGeneration matches what we saw
            // at the last successful UAV pass.
            // [TableDedupBug] During streaming, a TableAttachment occupies a
            // single character in the attributed string; rows grow via
            // `update()` which mutates the attachment in place (object
            // identity preserved) but does NOT change `storage.length`.
            // The previous fingerprint (storageLen + width + viewCount) was
            // therefore satisfied on every streamed token, causing
            // `refreshAttachViews` to return early without rebuilding
            // the TableScrollView. Visible symptom: the table cell stays
            // pinned at its first-row rendering even as cell height grows
            // to accommodate later rows the layout manager already knows
            // about — the "table is mostly empty space" report.
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
                AppLogger(category: "ChatList.Attach").info("[UAV][SKIP-DEDUPE] storageLen=\(storage.length) tcW=\(String(format: "%.0f", self.textContainer.size.width)) views=\(self.attachmentViewMap.count) tableGen=\(currentTableGenSum) — fingerprint match, nothing to do")
                return
            }
        }
        // [AttachHotPath] One log per call. If imageAttachmentCount > 0, this
        // is in the hot path during streaming.
        let imageAttachmentCount: Int = {
            let storage = self.textStorage
            var n = 0
            storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { v,_,_ in
                if v is ImageAttachment { n += 1 }
            }
            return n
        }()
        if imageAttachmentCount>0 {
            AppLogger(category: "ChatList.Attach").info("[UAV] enter imgAttach=\(imageAttachmentCount) prevViews=\(self.attachmentViews.count) tcW=\(String(format: "%.0f", self.textContainer.size.width))")
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

        // Ensure TextKit has laid out all glyphs including trailing attachments.
        // UIKit may have clamped textContainer height to the current bounds, which
        // causes glyphs beyond that height to have zero bounding rects. Temporarily
        // expand to infinite height for both ensureLayout and boundingRect queries.
        let savedContainerHeight = self.textContainer.size.height
        if savedContainerHeight<CGFloat.greatestFiniteMagnitude {
            self.textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        // [T-attachment-zero-origin 2026-05-23] Invalidate glyph properties
        // (not just layout) for the full range before ensureLayout. Otherwise
        // TextKit retains stale glyphProp=controlCharacter cached during an
        // earlier zero/narrow textContainer pass, leaving attachment glyphs
        // with `boundingRect.origin == .zero` even after layout settles — the
        // attachment view then gets pinned at (0,0) overlaying the cell's
        // first text line. Reproducible on iPhone 15 Pro Max (tcW=370);
        // iPad (tcW=900) escapes because its width never narrowed enough
        // to trip the controlCharacter fallback. Pairs with the explicit
        // `view.frame.origin = boundingRect.origin` write below.
        layoutManager.invalidateGlyphs(forCharacterRange: fullRange,changeInLength: 0,actualCharacterRange: nil)
        layoutManager.ensureLayout(forCharacterRange: fullRange)
        // NOTE: we restore savedContainerHeight AFTER enumeration, not here

        textStorage.enumerateAttribute(.attachment,in: fullRange,options: []) { value,range,_ in
            guard let attachment = value as? NSTextAttachment else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,actualCharacterRange: nil)
            var boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange,in: self.textContainer)
            let existingView = previousViewMap[ObjectIdentifier(attachment)]
            // TextKit may return zero-width rects when layout is invalidated but
            // not yet recalculated (e.g. during rebuildAttachViews after an
            // async image load). Fall back to the text container width so
            // attachment views are created at a usable size.
            if boundingRect.width<1 || (containerWidth>0 && boundingRect.width>containerWidth) {
                boundingRect.size.width = containerWidth
            }

            let attachId = ObjectIdentifier(attachment)
            let view: UIView

            // For attachments that are cached (same object identity), reuse existing UIView
            // — but discard stale placeholders if the attachment has since loaded its content.
            if let existingView = previousViewMap[attachId] {
                var stale = false
                if let imageAttach = attachment as? ImageAttachment {
                    // File was rewritten since last load — force a rebuild
                    // so the new bitmap reaches the UIImageView inside.
                    if imageAttach.needsViewRebuild {
                        AppLogger(category: "ChatList.Attach").info("[IMG][UAV] STALE-needsRebuild src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF)")
                        stale = true
                        imageAttach.needsViewRebuild = false
                    }
                    // Only (re-)arm onLoad and kick loading if the image isn't
                    // loaded yet. Otherwise a `NativeMediaImageCache` hit inside
                    // `beginLoadingIfNeeded` could fire `onLoad` synchronously
                    // and recurse back into `rebuildAttachViews` during
                    // `refreshAttachViews`. [AttachHang defensive guard]
                    if imageAttach.loadedImage == nil {
                        imageAttach.onLoad = { [weak self] in
                            DispatchQueue.main.async { self?.rebuildAttachViews() }
                        }
                        imageAttach.beginLoadingIfNeeded()
                    } else {
                        // Clear any stale onLoad so a later invalidation path
                        // doesn't surface a synchronous refresh from an earlier
                        // incarnation of this attachment view.
                        imageAttach.onLoad = nil
                    }
                    if !stale && imageAttach.loadedImage != nil {
                        let hasImageView = existingView.subviews.contains(where: { $0 is UIImageView || ($0.subviews.contains(where: { $0 is UIImageView })) })
                        if !hasImageView {
                            AppLogger(category: "ChatList.Attach").info("[IMG][UAV] STALE-placeholderToLoaded src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — replacing placeholder with image view")
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
                    // Code block with same object identity (content unchanged) — just track for future reuse
                    codeBlockViewCache[codeBlock.blockIndex] = existingView
                } else if let tableAttach = attachment as? TableAttachment {
                    // In-place content update during streaming markdown: the
                    // TableAttachment object identity is preserved (so the
                    // MarkdownView fast-path stays alive) but the
                    // rendered TableScrollView still holds the old rows.
                    // Force a rebuild so the user sees the new content.
                    //
                    // EXCEPT while the
                    // user is actively scrolling THIS table horizontally.
                    // A rebuild removes the live TableScrollView from the
                    // hierarchy, which cancels the in-flight pan gesture —
                    // preservedScrollOffset keeps the position but not the
                    // gesture, so during streaming every chunk killed the drag
                    // after a few points. Defer instead: leave
                    // needsViewRebuild pending for the next streaming pass and
                    // arm a one-shot end-of-interaction callback so the
                    // rebuild still lands if the stream finishes mid-drag.
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
                        // stale stays false — reuse the live view this pass.
                    } else if tableAttach.needsViewRebuild {
                        stale = true
                        tableAttach.needsViewRebuild = false
                    } else if sizeMismatch {
                        // [TableFrameFix] Even when `needsViewRebuild` is
                        // false (because the previous stale path already
                        // consumed it), the cached TableScrollView's inner
                        // stack/cells are sized against an out-of-date
                        // (typically smaller) layout. Trigger a rebuild
                        // whenever the existing view's size disagrees with
                        // the typesetter's boundingRect.
                        stale = true
                    }
                }

                if stale {
                    // Content loaded since last render — recreate the view
                    existingView.removeFromSuperview()
                    if let imageAttach = attachment as? ImageAttachment {
                        AppLogger(category: "ChatList.Attach").info("[IMG][UAV] RECREATE src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — same attachment, but stale view → makeView")
                        view = imageAttach.makeView(width: boundingRect.width)
                    } else if let videoAttach = attachment as? VideoAttachment {
                        view = videoAttach.makeView(width: boundingRect.width)
                    } else if let mathAttach = attachment as? MathAttachment {
                        view = mathAttach.makeView(width: boundingRect.width)
                    } else if let tableAttach = attachment as? TableAttachment {
                        // Belt-and-suspenders capture of the live position
                        // right before teardown (onUserScroll normally keeps
                        // preservedScrollOffset current). Only when x > 0 —
                        // a transient 0 here (restore not yet applied) must
                        // not clobber the user's real preserved position.
                        if let oldScroll = TableAttachment.tableScrollView(in: existingView),
                           oldScroll.contentOffset.x>0 {
                            tableAttach.preservedScrollOffset = oldScroll.contentOffset
                        }
                        // Re-wire onOpenURL on the new view (mirrors the new-attachment branch below).
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
                    // Reuse: just update position and size
                    if let imageAttach = attachment as? ImageAttachment {
                        AppLogger(category: "ChatList.Attach").info("[IMG][UAV] REUSE src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — view kept, only frame updated")
                    }
                    view = existingView
                }
                reusedIds.insert(attachId)
                view.frame = CGRect(origin: boundingRect.origin,size: view.frame.size)
            } else if let codeBlock = attachment as? CodeBlockAttachment {
                // New attachment object (content changed or first time).
                // Try to reuse the previous view at the same index via updateExistingAttachView.
                if let previousView = codeBlockViewCache[codeBlock.blockIndex] {
                    codeBlock.updateExistingAttachView(previousView)
                    view = previousView
                    // Trust the height computed by updateExistingAttachView from the
                    // real code content. TextKit's boundingRect can be stale
                    // (glyph layout cached against a clamped textContainer
                    // height) and would otherwise collapse the view to the
                    // previous, smaller size.
                    view.frame = CGRect(
                        origin: boundingRect.origin,
                        size: CGSize(width: boundingRect.width,height: view.frame.size.height)
                    )
                } else {
                    view = codeBlock.makeView(width: boundingRect.width)
                }
                codeBlockViewCache[codeBlock.blockIndex] = view
            } else if let table = attachment as? TableAttachment {
                // Re-wire every render: the prior closure may have captured a
                // since-deallocated coordinator (`[weak self] → nil`), in which
                // case taps fell through to UIApplication.open and miniclaw://
                // links failed silently. Closure assignment is cheap.
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
                AppLogger(category: "ChatList.Attach").info("[IMG][UAV] NEW src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — no previous view (first render OR ObjectIdentifier changed) → makeView")
                // Same guard as the reused-attachment branch above: only arm
                // onLoad when the image isn't already loaded, so a memory-cache
                // hit during beginLoadingIfNeeded can't synchronously recurse
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

            // [T-attachment-zero-origin 2026-05-23] Per-attachment retry: even
            // after the up-front invalidateGlyphs(fullRange), TextKit can still
            // return boundingRect.origin == .zero on the first query for an
            // attachment glyph in a narrow textContainer (iPhone tcW≈370 +
            // CJK paragraph). The diagnostic experiment showed a SECOND
            // invalidate+ensureLayout consistently returns the real origin
            // (e.g. (0, 99.4, 369x254)). Pinning a fresh attachment view at
            // (0,0) overlays the cell's first text line, and the
            // layoutSubviews fallback (line ~4677) refuses to move it
            // because both the cached origin and boundingRect.origin are
            // zero — so the only chance to land it correctly is right here.
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

        // Remove views that are no longer present.
        // Views reused via codeBlockViewCache may appear under a new ObjectIdentifier
        // (content changed → new attachment), so also check newViewMap.values before removing.
        let newViewSet = Set(newViewMap.values.map { ObjectIdentifier($0) })
        for (id,view) in previousViewMap where !reusedIds.contains(id) && newViewMap[id] == nil {
            if newViewSet.contains(ObjectIdentifier(view)) { continue }
            view.removeFromSuperview()
        }

        // Restore textContainer height after all boundingRect queries are done.
        // Only when it actually changed — see layoutSubviews for why we avoid
        // redundant setSize: calls.
        if self.textContainer.size.height != savedContainerHeight {
            self.textContainer.size.height = savedContainerHeight
        }

        attachmentViews = newViews
        attachmentViewMap = newViewMap
        // [AttachHotPath] Refresh dedupe fingerprint so the next UAV call
        // can short-circuit when storage / width / view count are unchanged.
        let uavStorage = self.textStorage
        lastUAVStorageLen = uavStorage.length
        // [TableDedupBug] Snapshot the current sum of TableAttachment
        // contentGeneration so the next dedupe check can detect a
        // streaming `update()` that didn't change storage.length.
        var sum: UInt64 = 0
        uavStorage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: uavStorage.length),options: []) { v,_,_ in
            if let table = v as? TableAttachment { sum &+= table.contentGeneration }
        }
        lastUAVTableGenSum = sum
        lastUAVWidth = self.textContainer.size.width
        lastUAVViewCount = newViewMap.count
        // Force redraw so blockquote bars are painted with correct attachment
        // exclusion rects. draw() may fire before attachmentViews are populated,
        // causing bars to overlap tables on initial layout.
        setNeedsDisplay()
        #if DEBUG
        // Capture immediately after attachment views
        // have been rebuilt — async image/video load completes also lands here
        // (via rebuildAttachViews), so this is the most likely site where
        // table container frame gets reset to (0,0).
        MessageListSnapshotCollector.captureIfEnabled(
            from: self,
            trigger: "mtv.refreshAttachViews",
            triggerDetail: String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        )
        #endif
    }

    /// Re-layout attachment views after an async image/video load completes.
    private func rebuildAttachViews() {
        AppLogger(category: "ChatList.Attach").info("[REFRESH] entry — async media-load callback fired (image/video/math finished loading); will run refreshAttachViews + invalidateCellSize")
        guard window != nil else {
            // Detached from window — defer the refresh until re-attach so an
            // async image load that completed mid-recycle still grows the
            // cell. Replayed in `didMoveToWindow`. (T-multi-image-last
            // d8a51f73)
            pendingRefreshAfterWindowAttach = true
            return
        }
        // Re-entry guard: `invalidateCellSizeIfChanged` below triggers
        // `collectionViewLayout.invalidateLayout()`, which can synchronously
        // re-enter `layoutSubviews` → `rebuildAttachViews` if the cell's
        // width changed. [AttachHang defensive guard]
        if isRefreshingAttachments {
            reentryGuardHits &+= 1
            attachLogger.warning("[AttachHang][Refresh] RE-ENTRY BLOCKED hits=\(self.reentryGuardHits) window=\(self.window != nil) attachmentViews=\(self.attachmentViews.count)")
            return
        }
        isRefreshingAttachments = true
        defer { isRefreshingAttachments = false }
        // [T-table-zero-y 2026-05-23] When an async-loaded attachment (Video
        // thumbnail / Image) finishes loading, its attachmentBounds height
        // changes (e.g. Video 200pt placeholder → 231pt thumbnail-aware). We
        // need (a) the typesetter to re-query attachmentBounds and (b) the
        // cell to grow before the typesetter can fit the new layout.
        //
        // (a) invalidate the layout so ensureLayout will re-typeset.
        if let layoutManager = self.layoutManager as? MiniClawLayoutManager {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0,length: self.textStorage.length),actualCharacterRange: nil)
        }
        // (b) reset the sizeThatFits fingerprint so invalidateCellSizeIfChanged
        // below cannot DEDUPE-SKIP. textStorage.length and measureWidth are
        // unchanged after Video.onLoad (the Video glyph is still 1 char), but
        // the attachment's intrinsic height changed — we MUST re-measure. The
        // cascade is: sizeThatFits → newH includes the larger Video → write
        // coordinator cache → collectionView self-sizing → cell grows →
        // live textView.bounds grows → tcH grows (UIKit clamps tcH to
        // bounds.h − inset) → subsequent layoutSubviews can fit the new
        // attachment height inside the container.
        lastSizedStorageLen = -1
        lastSizedWidth = -1
        lastComputedHeight = 0
        // Remove old attachment subviews before clearing tracking state,
        // otherwise refreshAttachViews sees an empty previousViewMap
        // and cannot clean up orphaned views — causing duplication/overlap.
        for view in attachmentViews { view.removeFromSuperview() }
        attachmentViews.removeAll()
        attachmentViewMap.removeAll()
        codeBlockViewCache.removeAll()
        // Reset dedupe fingerprint so the next refreshAttachViews fully runs.
        lastUAVStorageLen = -1
        lastUAVWidth = -1
        lastUAVViewCount = -1
        refreshAttachViews()
        // invalidateIntrinsicContentSize() alone is NOT enough for
        // UICollectionView self-sizing — it marks the intrinsic size dirty
        // but doesn't trigger preferredLayoutAttributesFitting. We must
        // go through invalidateCellSizeIfChanged() which clears the
        // SelfSizingCell cache and invalidates the collection view layout.
        invalidateCellSizeIfChanged()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // Release CALayer backing stores when removed from view tree
            layer.contents = nil
            for sub in attachmentViews {
                sub.layer.contents = nil
            }
        } else {
            // Replay any refresh dropped while we were detached. The
            // canonical case is the LAST image of a multi-image message
            // finishing its async load between scroll-out and scroll-in:
            // without this replay the cell stays at its pre-load size,
            // clipping the final image. Async so the rebind / collection
            // view's own layout pass settles first. (T-multi-image-last
            // d8a51f73)
            if pendingRefreshAfterWindowAttach {
                pendingRefreshAfterWindowAttach = false
                DispatchQueue.main.async { [weak self] in
                    self?.rebuildAttachViews()
                }
            }
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        // TEMP(2026-05-13) — layoutSubviews slow-path probe. Most layout
        // work is fast; emit a direct-write line when a single
        // layoutSubviews pass takes >=50ms so a watchdog hang can be
        // attributed to a specific text view + its content.
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

        // UIKit clamps textContainer.size.height to the view's bounds during
        // layout. For a non-scrolling text view (isScrollEnabled=false), this
        // causes NSLayoutManager to exclude text that extends beyond the
        // current bounds, making trailing paragraphs invisible. Reset to
        // unconstrained so the full text is always laid out and drawn.
        //
        // Only assign when the current value is NOT already unconstrained.
        // Unconditional assignment goes through `-[NSTextContainer setSize:]`
        // → `textContainerChangedGeometry:` → `_invalidateLayoutForExtended
        // CharacterRange:` → `_fillLayoutHoleAtIndex:` even when the value
        // is identical, because UIKit doesn't equality-check size on
        // NSTextContainer. In the BoundsChangeFading path that's the
        // recursion seed for the watchdog hang seen in
        // MiniClaw-2026-05-13-084827.ips: every layout pass re-triggers a full
        // fillLayoutHole on tables, which calls back into attachmentBounds,
        // which re-enters typesetting.
        if textContainer.size.height<CGFloat.greatestFiniteMagnitude {
            textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }

        let currentWidth = textContainer.size.width

        // If the textContainer width changed (rotation, size class change, etc.),
        // fully rebuild attachment views so they get the new width via makeView(width:).
        // Use a 0.5pt threshold — matching the sizeThatFits-path guard in
        // `MarkdownView.sizeThatFits` — so sub-pt float jitter from
        // cell self-sizing doesn't repeatedly kick `rebuildAttachViews`.
        let widthDelta = abs(currentWidth-lastLayoutWidth)
        if currentWidth>0 && widthDelta>0.5 {
            lastLayoutWidth = currentWidth
            // [RotationFix] On a real width change (rotation / size class), the
            // Coordinator's per-width size cache may hold a stale entry for
            // this width that was written before content settled (e.g. while
            // a table attachment was still computing). Clearing forces the
            // next sizeThatFits to recompute, which is required for the
            // trailing-paragraph truncation seen on rotation back to portrait.
            // Also reset the invalidateCellSizeIfChanged fingerprint so it
            // doesn't short-circuit when the storage length is unchanged.
            if let coord = (self.delegate as? MarkdownView.Coordinator) {
                coord.cachedSizes.removeAll(keepingCapacity: true)
            }
            lastSizedStorageLen = -1
            lastSizedWidth = -1
            // [RotationTableFix] Reset every TableAttachment's cached layout so
            // `computeLayout`'s "reuse cached columnWidths at new width"
            // branch doesn't keep returning the old portrait-width columns
            // when the bubble has expanded for the new orientation. Without
            // this, the rendered table view sticks at the pre-rotation width.
            // Also invalidate the layoutManager for each attachment's char
            // range so ensureLayout asks for fresh `attachmentBounds`.
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
                // Width just became available (e.g. UIHostingConfiguration finished layout)
                // but refreshAttachViews was skipped earlier because width was 0.
                refreshAttachViews()
                invalidateIntrinsicContentSize()
                invalidateCellSizeIfChanged()
            } else {
                // No attachments — still need a fresh measurement so the cell
                // resizes for the new width. Without this, attachment-free
                // messages keep their pre-rotation height and clip trailing
                // lines.
                invalidateIntrinsicContentSize()
                invalidateCellSizeIfChanged()
            }
            return
        }

        // Width unchanged — just re-position attachment views so their origins
        // match the freshly computed glyph bounding rects. This corrects the
        // first-load case where refreshAttachViews() runs before sizeThatFits
        // has set the correct textContainer size.
        guard !attachmentViews.isEmpty,
              let layoutManager = self.layoutManager as? MiniClawLayoutManager else { return }
        let textStorage = self.textStorage
        let fullRange = NSRange(location: 0,length: textStorage.length)

        // textContainer.size.height is already unconstrained (set above after
        // super.layoutSubviews), so boundingRect queries return correct positions
        // for all attachments including those near the end of the text.
        textStorage.enumerateAttribute(.attachment,in: fullRange,options: []) { value,range,_ in
            guard let attachment = value as? NSTextAttachment else { return }
            let attachId = ObjectIdentifier(attachment)
            guard let view = attachmentViewMap[attachId] else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,actualCharacterRange: nil)
            var boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange,in: self.textContainer)
            // [T-attachment-zero-origin 2026-05-23] Mirror the per-attachment
            // retry from refreshAttachViews. If TextKit returns
            // boundingRect.origin == .zero here (stale controlCharacter glyph
            // property), an invalidateGlyphs + ensureLayout consistently
            // yields the real origin on the second query.
            if boundingRect.origin == .zero {
                layoutManager.invalidateGlyphs(forCharacterRange: range,changeInLength: 0,actualCharacterRange: nil)
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0,length: textStorage.length))
                let retry = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range,actualCharacterRange: nil),in: self.textContainer)
                if retry.origin != .zero {
                    boundingRect = retry
                }
            }
            // Only reposition if boundingRect has a valid origin (non-zero rect).
            // A zero rect means layout hasn't been computed yet — keep current position.
            if boundingRect.origin != .zero || view.frame.origin == .zero {
                if view.frame.origin != boundingRect.origin {
                    view.frame.origin = boundingRect.origin
                }
            }
        }
        #if DEBUG
        // Capture render snapshot — disabled by default.
        let msgId = (self.delegate as? MarkdownView.Coordinator)?.renderer.messageId?.uuidString.prefix(8)
        MarkdownSnapshotCollector.captureIfEnabled(
            textView: self,
            phase: "afterLayoutSubviews",
            messageId: msgId.map(String.init),
            isMeasureView: false
        )
        // Also: full message-list capture so we can see the entire collection
        // state at the same moment a cell's textView finished layout.
        MessageListSnapshotCollector.captureIfEnabled(
            from: self,
            trigger: "mtv.layoutSubviews",
            triggerDetail: String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        )
        #endif
    }

    // MARK: Cell Self-Sizing Invalidation

    /// Called after content changes to detect height growth and invalidate the
    /// parent UICollectionView cell's self-sizing so the layout re-measures it.
    /// Without this, UIHostingConfiguration may not propagate height changes
    /// caused by nested @ObservedObject updates (e.g. AssistantBlock.content
    /// growing from 1 line to 2 lines during streaming).
    private let cellSizeLogger = AppLogger(category: "CellSize")

    /// Sum of `TableAttachment.contentGeneration` over every table attachment
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
        // Re-entry guard: `cv.collectionViewLayout.invalidateLayout()` below
        // can synchronously re-enter `preferredLayoutAttributesFitting` →
        // `sizeThatFits` → `invalidateCellSizeIfChanged`. Without this guard
        // a height that is still settling can spin for the full watchdog
        // window. [AttachHang defensive guard]
        if isInvalidatingCellSize {
            reentryGuardHits &+= 1
            cellSizeLogger.warning("[AttachHang][CellMetrics] RE-ENTRY BLOCKED hits=\(self.reentryGuardHits) tcW=\(String(format: "%.0f", self.textContainer.size.width)) lastH=\(String(format: "%.1f", self.lastComputedHeight))")
            return
        }
        // Fingerprint early-exit: when textStorage and width are unchanged
        // from the last successful measurement, the height can't have moved.
        // The full path below pays for `sizeThatFits` (~2-4ms on long
        // attributed strings) before discovering NOOP. Skipping here saves
        // that cost on every repeated call (SwiftUI reuse / didMoveToWindow
        // bursts each trigger an UAV chain that includes this).
        // [JitterFix] Measure at the actual render width (bounds.width) when
        // available. textContainer.size.width can be transiently set to the
        // outer-cell probe width (~402) by SwiftUI's preferredLayoutAttributes
        // pass — measuring at that wrong width would write a 23pt-too-small
        // height into lastComputedHeight, producing the streaming spike.
        let measureWidth: CGFloat = bounds.width>1 ? bounds.width : textContainer.size.width
        // [TableGenDedup] Compute the sum of every TableAttachment's generation
        // counter. Streaming tables mutate rows in place without changing
        // textStorage.length, so the (storageLen, width) fingerprint alone
        // can't detect those mutations and would short-circuit the remeasure
        // — visible as a streaming table rendering only its first column
        // until the entire message stops streaming.
        let tableGenSum = currentTableGenerationSum()
        if lastSizedStorageLen >= 0,
           textStorage.length == lastSizedStorageLen,
           abs(measureWidth-lastSizedWidth)<0.5,
           tableGenSum == lastSizedTableGenSum,
           lastComputedHeight>0 {
            cellSizeLogger.info("[invalidateCell][SKIP-DEDUPE] storageLen=\(textStorage.length) measureW=\(String(format: "%.0f", measureWidth)) tcW=\(String(format: "%.0f", textContainer.size.width)) lastH=\(String(format: "%.1f", lastComputedHeight)) tableGen=\(tableGenSum) — fingerprint match, skipping sizeThatFits")
            return
        }
        isInvalidatingCellSize = true
        defer { isInvalidatingCellSize = false }
        let newHeight = sizeThatFits(CGSize(width: measureWidth,height: .greatestFiniteMagnitude)).height
        // sizeThatFits clamps textContainer.size.height — restore it (only
        // when actually clamped, to avoid a redundant setSize: → fillLayoutHole).
        if textContainer.size.height<CGFloat.greatestFiniteMagnitude {
            textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        let previousHeight = lastComputedHeight
        if abs(newHeight-previousHeight) <= 1 {
            // Unchanged — refresh the fingerprint so subsequent calls can
            // SKIP-DEDUPE, exactly as before.
            lastSizedStorageLen = textStorage.length
            lastSizedWidth = measureWidth
            lastSizedTableGenSum = tableGenSum
            return
        }
        let delta = newHeight-previousHeight

        // Height genuinely moved. Decide the
        // defer-skip BEFORE consuming the measurement. The old order refreshed
        // the dedup fingerprint + lastComputedHeight first and THEN bailed on
        // deferSelfSizing / first-measure — after which every later call hit
        // [SKIP-DEDUPE] and the correction could never fire again. Combined
        // with SelfSizingCell's unbounded same-width height cache (which never
        // re-enters SwiftUI on its own), the cell stayed frozen at the
        // too-short first-commit height and clipsToBounds cropped the tail —
        // the "last message truncated mid-sentence, survives restart" repro
        // (A71D8A0D: CTFramesetter first-commit under-measured the 839-char
        // CJK block by ~1 line vs TextKit's later authoritative measure; the
        // cold-open auto-scroll glide kept deferSelfSizing=true at exactly the
        // moment this correction tried to run).
        let cvOpt = findCollectionView()
        let layout = cvOpt?.collectionViewLayout as? MessageListLayout
        let isDeferred = layout?.deferSelfSizing ?? false

        // When deferSelfSizing is active (user scrolling), skip the full layout
        // invalidation — it causes contentSize changes that push the streaming
        // cell into other cells during deceleration. The height change will be
        // picked up naturally via preferredLayoutAttributesFitting when the
        // deferred heights are flushed after scrolling ends.
        //
        // EXCEPTION: image-attachment placeholder→loaded transition. On cold
        // enter the auto `scrollToBottom` triggers a decel (deferSelfSizing=true)
        // *while* the inline images are still placeholders at 200pt. When an
        // image resolves from the memory cache (synchronous) and refreshes
        // attachments, sizeThatFits now returns the real height (e.g. 327pt).
        // If we skip invalidation here, the cell stays frozen at the 240pt
        // placeholder height and the UIImageView — which was laid out at the
        // correct 280pt by refreshAttachViews — is clipped by the cell's
        // bounds, producing the "bottom truncated" symptom. The condition is
        // narrow: image attachment present AND a large growth (>30pt). This
        // preserves the existing defer behaviour for streaming text growth.
        // [AttachHang image-attachment defer escape]
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
                // Fall through to the normal invalidate path below.
            } else {
                // Return WITHOUT touching the
                // fingerprint / lastComputedHeight / coord cache — the
                // correction is NOT consumed, so the next call re-measures and
                // retries. Streaming cost is unchanged: token growth mutates
                // storage length, which already defeats the fingerprint today.
                // Arm one guaranteed post-settle retry in case no further
                // measure call arrives after the glide ends.
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

        // Commit the measurement: fingerprint + authoritative height + the
        // Coordinator's sizeThatFits width-bucket cache. Streaming code blocks /
        // tables grow inside a single NSAttachmentCharacter, so `textLen` stays
        // fixed and the `(width, textLen)`-keyed cache would otherwise return
        // the previous (smaller) height, pinning the cell. We already paid for
        // a real `sizeThatFits` here; sharing the result costs zero additional
        // TextKit work and lets the next `preferredLayoutAttributesFitting`
        // probe HIT the fresh value without another full relayout (the 8s hang
        // `d0d3ffc` fixed).
        lastSizedStorageLen = textStorage.length
        lastSizedWidth = measureWidth
        lastSizedTableGenSum = tableGenSum
        lastComputedHeight = newHeight
        if let coord = self.delegate as? MarkdownView.Coordinator {
            // [JitterFix] Key by render width (measureWidth), matching the
            // SwiftUI sizeThatFits cache key. Using textContainer.size.width
            // here would insert under whichever stale probe width was last
            // committed, missing future render-width cache lookups.
            // REPLACE the whole bucket dict
            // instead of upserting one key: stale near-width buckets (±2pt
            // probe rounding) written by the CTFramesetter fast path would
            // otherwise be copied back over this authoritative TextKit height
            // by sizeThatFits' near-width reuse, re-pinning the cell short.
            let widthKey = Int(measureWidth.rounded())
            coord.cachedSizes.removeAll(keepingCapacity: true)
            coord.cachedSizes[widthKey] = newHeight
            // Key the cache generation by the
            // RAW MARKDOWN length — sizeThatFits gates hits on
            // `bindingLen == cachedSizeMarkdownCount`, and bindingLen is the
            // raw `markdown` binding's NSString length. The old write used
            // textStorage.length (the RENDERED length), which never equals
            // bindingLen once markdown syntax is stripped — so this
            // authoritative TextKit height was permanently unreachable and the
            // correction re-measure fell back to the CTFramesetter path (the
            // short height), re-pinning the cell.
            let bindingLenForKey = rawMarkdown.isEmpty
                ? textStorage.length
                : (rawMarkdown as NSString).length
            coord.cachedSizeMarkdownCount = bindingLenForKey
        }

        // First measurement (previousHeight == 0): normally the layout queries
        // the cell naturally during the initial pass and no invalidation is
        // needed. BUT if the host cell has ALREADY committed a conflicting
        // height (cold-load: the SwiftUI sizeThatFits probe committed a
        // CTFramesetter-measured height that disagrees with this TextKit
        // measure by a line), that commit is frozen by SelfSizingCell's
        // same-width cache and MUST be invalidated here — this is the only
        // correction point. Threshold 8pt: above the ~4pt vertical padding
        // delta between the markdown view and its cell, below one text line.
        if previousHeight <= 0 {
            guard let cell = findCell() as? SelfSizingCell,
                  cell.bounds.height>4,
                  abs(cell.bounds.height-newHeight)>8 else { return }
            cellSizeLogger.info("[invalidateCell] FIRST-MEASURE CORRECTION cellH=\(String(format: "%.1f", cell.bounds.height)) newH=\(String(format: "%.1f", newHeight)) — cell committed a conflicting height, invalidating")
        }

        // Clear SelfSizingCell's cached height so preferredLayoutAttributesFitting
        // re-measures instead of returning the stale cached value. Without this,
        // the precalcHeight-based initial measurement (from applySnapshot) gets
        // locked in, even though the actual TextKit layout produced a different height.
        if let cell = findCell() as? SelfSizingCell {
            cell.clearCachedHeight()
        }

        cvOpt?.collectionViewLayout.invalidateLayout()
    }

    // MARK: Blockquote Bars

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

        // Collect contiguous blockquote spans and compute their union bounding rects.
        // Multiple attributed-string ranges may have the same depth but different styling
        // (bold, italic, etc.), so we merge adjacent ranges into one continuous bar.
        struct BarSpan {
            let depth: Int
            var rect: CGRect
        }
        var spans: [BarSpan] = []

        // Helper: process a single non-attachment character range for bar drawing.
        //
        // Uses per-line fragment `usedRect`s (not `boundingRect(forGlyphRange:)`)
        // so the resulting span excludes trailing paragraphSpacing. Without this,
        // when a blockquote is followed by a paragraph containing inline code
        // that wraps, the bar overshoots into the next paragraph.
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

/// Custom NSLayoutManager subclass. Originally added for inline-code rounded
/// background rendering (see `fillBackgroundRectArray` below). Kept as a
/// dedicated class so other layout-manager hooks can be added in one place.
let nativeVideoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
final class MiniClawLayoutManager: NSLayoutManager {

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>,count rectCount: Int,forCharacterRange charRange: NSRange,color: UIColor) {
        // Check if this range has inline code background
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
        // against the current traits explicitly so the CGColor is correct even
        // if UITraitCollection.current isn't the drawing view's during this
        // TextKit callback.
        let bgColor = miniClawInlineCodeBackgroundColor.resolvedColor(with: UITraitCollection.current)
        context.saveGState()
        context.setFillColor(bgColor.cgColor)

        let glyphRange = self.glyphRange(forCharacterRange: charRange,actualCharacterRange: nil)

        // Count how many line fragments the code span covers (single vs multi-line)
        var lineFragCount = 0
        enumerateLineFragments(forGlyphRange: glyphRange) { _,_,_,_,_ in
            lineFragCount += 1
        }

        for i in 0..<rectCount {
            var rawRect = rectArray[i]
            guard rawRect.width>2 else { continue }

            // Check if the code span's text on this line has visible (non-whitespace)
            // characters. When word wrap pushes the code span to the next line, the
            // previous line may retain only a leading space with .backgroundColor,
            // producing an empty background rect.
            var hasVisibleText = false
            // correctedOriginY / correctedHeight: the closure captures rawRect
            // by value, so we write back corrections through these vars.
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
                    // Clamp rect to usedRect (excludes lineSpacing) so the
                    // inline-code background aligns with the text, not the
                    // bloated lineFragRect that includes paragraph spacing.
                    if rawRect.height>usedRect.height+2 {
                        correctedOriginY = usedRect.minY
                        correctedHeight = usedRect.height
                    }
                    // Fix last-line height issue: TextKit may pass a shorter rect
                    // for the final line. Only correct for single-line spans to
                    // avoid mis-firing on multi-line wrapped code.
                    if lineFragCount == 1 && rawRect.height<usedRect.height*0.8 {
                        correctedOriginY = usedRect.minY
                        correctedHeight = usedRect.height
                    }
                }
            }
            guard hasVisibleText else { continue }

            // Apply corrected origin and height from the closure above.
            rawRect = CGRect(x: rawRect.minX,y: correctedOriginY,width: rawRect.width,height: correctedHeight)

            // Vertically center the background within the line.
            // rawRect height reflects the full usedRect (dominated by the tallest
            // font on the line). The inline code font is shorter, so we compute
            // the background height from the actual glyph bounding box and center
            // it within rawRect to avoid the "floats to top" misalignment.
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

/// Non-editable, selectable UITextView subclass for rendering Markdown as NSAttributedString.
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

/// Manages inline audio UI by delegating to GlobalAudioPlayer singleton.
final class VideoTapGesture: UITapGestureRecognizer {
    var fileURL: URL?

    @objc func handleTap() {
        guard let url = fileURL else { return }
        // 2026-08-12 治本:视频点击走系统预览(Quick Look,与 iOS 文件 App 一致)。
        // 此前是自定义 MiniClawVideoFullscreenPlayer——非系统预览形式。
        NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
    }
}

