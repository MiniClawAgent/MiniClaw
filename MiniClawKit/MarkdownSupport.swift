import SwiftUI

let imgLogger = AppLogger(category: "MiniClawImage")
let nativeAudioExts: Set<String> = ["mp3", "m4a", "wav", "aac", "ogg", "flac"]
import UIKit
import Foundation
import Combine
enum MiniClawToast {
    /// Show a toast with an already-localized message. Safe from any thread.
    /// `systemImage` sets the leading icon (default: success checkmark); pass an
    /// error glyph like "exclamationmark.triangle.fill" for failures.
    static func show(_ message: String,duration: TimeInterval = 1.6,
                     systemImage: String = "checkmark.circle.fill") {
        if Thread.isMainThread {
            present(message,duration: duration,systemImage: systemImage)
        } else {
            DispatchQueue.main.async { present(message,duration: duration,systemImage: systemImage) }
        }
    }

    static func present(_ message: String,duration: TimeInterval,
                                systemImage: String = "checkmark.circle.fill") {
        guard let window = keyWindow() else { return }

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let check = UIImageView(image: UIImage(systemName: systemImage))
        check.tintColor = .white
        check.contentMode = .scaleAspectFit
        check.translatesAutoresizingMaskIntoConstraints = false

        let capsule = UIView()
        capsule.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        capsule.layer.cornerRadius = 18
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.alpha = 0

        capsule.addSubview(check)
        capsule.addSubview(label)
        window.addSubview(capsule)

        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: capsule.leadingAnchor,constant: 16),
            check.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 16),
            check.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: check.trailingAnchor,constant: 8),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor,constant: -16),
            label.topAnchor.constraint(equalTo: capsule.topAnchor,constant: 10),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor,constant: -10),
            capsule.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor,constant: -48),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor,constant: 24),
            capsule.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor,constant: -24),
        ])

        UIView.animate(withDuration: 0.25) { capsule.alpha = 1 }
        UIView.animate(withDuration: 0.3,delay: duration,options: [.curveEaseIn]) {
            capsule.alpha = 0
        } completion: { _ in
            capsule.removeFromSuperview()
        }
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }
}

// MARK: - Custom Attributed String Keys

extension UIView {
    /// Walk the responder chain to find the nearest UIViewController.
    func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }

    /// Walk the superview chain to find the nearest UIScrollView.
    func enclosingScrollView() -> UIScrollView? {
        var current = self.superview
        while let v = current {
            if let sv = v as? UIScrollView { return sv }
            current = v.superview
        }
        return nil
    }
}

struct ScrollRestoringDismissWrapper<Content: View>: View {
    private weak var scrollView: UIScrollView?
    let savedOffset: CGPoint?
    let content: Content

    init(scrollView: UIScrollView?,savedOffset: CGPoint?,@ViewBuilder content: () -> Content) {
        self.scrollView = scrollView
        self.savedOffset = savedOffset
        self.content = content()
    }

    var body: some View {
        content
            .onDisappear {
                if let scrollView,let savedOffset {
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.1) {
                        scrollView.setContentOffset(savedOffset,animated: false)
                    }
                }
            }
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = fontDescriptor.withSymbolicTraits(combined) else { return self }
        return UIFont(descriptor: descriptor,size: 0)
    }
}

// MARK: - InlineNode Plain Text Helper

final class TableCellLabel: UILabel,UIGestureRecognizerDelegate,UIContextMenuInteractionDelegate {
    /// The attributed string to hand off to the UITextView when activated.
    var selectableAttributedText: NSAttributedString?
    /// Closure that copies the entire parent table. Set during `makeView`.
    var copyTableAction: (() -> Void)?
    /// Closure that copies the full table as a PNG image.
    var copyTableImageAction: (() -> Void)?
    /// Currently promoted UITextView (if any). Kept to clean up on dealloc/reuse.
    nonisolated(unsafe) private weak var activeTextView: TableCellTextView?
    /// Window-level tap gesture used to dismiss the promoted text view.
    private var dismissTap: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        let lp = UILongPressGestureRecognizer(target: self,action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.4
        addGestureRecognizer(lp)

        // Double-tap selects the cell text and shows the edit menu — mirrors
        // the long-press and right-click flows so users on iPad without a
        // trackpad can reach Copy quickly.
        let dt = UITapGestureRecognizer(target: self,action: #selector(handleDoubleTap(_:)))
        dt.numberOfTapsRequired = 2
        addGestureRecognizer(dt)

        // Right-click (external mouse / trackpad secondary) promotes the cell
        // to a selectable UITextView so the native edit menu can appear.
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeTapGesture()
        activeTextView?.removeFromSuperview()
    }

    // MARK: Rounded inline-code background

    // The label has no NSLayoutManager, so
    // the body painter (fillBackgroundRectArray) can't reach it. Setting the
    // standard `.backgroundColor` would paint SQUARE corners. Instead we strip
    // `.backgroundColor` from the displayed text (keeping `.inlineCodeBackground`
    // as the range marker) and paint rounded rects ourselves in drawText.
    // `selectableAttributedText` is left untouched — the promoted UITextView
    // keeps `.backgroundColor` so its MiniClawLayoutManager painter still fires.

    override var attributedText: NSAttributedString? {
        get { super.attributedText }
        set { super.attributedText = newValue.map(Self.strippingSquareCodeBackground) }
    }

    /// Returns a copy with `.backgroundColor` removed from any inline-code
    /// range (ranges carrying `.inlineCodeBackground`), leaving other
    /// background colors — if any — intact.
    private static func strippingSquareCodeBackground(_ attr: NSAttributedString) -> NSAttributedString {
        let full = NSRange(location: 0,length: attr.length)
        var hasCode = false
        attr.enumerateAttribute(.inlineCodeBackground,in: full,options: []) { value,_,stop in
            if value != nil { hasCode = true; stop.pointee = true }
        }
        guard hasCode else { return attr }
        let mutable = NSMutableAttributedString(attributedString: attr)
        attr.enumerateAttribute(.inlineCodeBackground,in: full,options: []) { value,range,_ in
            if value != nil { mutable.removeAttribute(.backgroundColor,range: range) }
        }
        return mutable
    }

    override func drawText(in rect: CGRect) {
        drawInlineCodeBG()
        super.drawText(in: rect)
    }

    /// Lay the attributed text out in a transient TextKit1 stack matching the
    /// label's bounds, then fill a rounded rect behind each inline-code range.
    private func drawInlineCodeBG() {
        guard let attr = super.attributedText,attr.length>0,
              let ctx = UIGraphicsGetCurrentContext() else { return }
        let full = NSRange(location: 0,length: attr.length)
        var codeRanges: [NSRange] = []
        attr.enumerateAttribute(.inlineCodeBackground,in: full,options: []) { value,range,_ in
            if value != nil { codeRanges.append(range) }
        }
        guard !codeRanges.isEmpty else { return }

        let storage = NSTextStorage(attributedString: attr)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: bounds.width,height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        // Vertically center the laid-out text the same way UILabel does so the
        // painted rects line up with the glyphs super draws.
        let usedHeight = manager.usedRect(for: container).height
        let yOffset = max(0,(bounds.height-usedHeight)/2)

        let bgColor = miniClawInlineCodeBackgroundColor.resolvedColor(with: traitCollection)
        ctx.saveGState()
        ctx.setFillColor(bgColor.cgColor)
        for range in codeRanges {
            let glyphRange = manager.glyphRange(forCharacterRange: range,actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                            withinSelectedGlyphRange: NSRange(location: NSNotFound,length: 0),
                                            in: container) { rectPtr,_ in
                let r = rectPtr.offsetBy(dx: 0,dy: yOffset).insetBy(dx: -1,dy: -0.5)
                guard r.width>2 else { return }
                let path = UIBezierPath(roundedRect: r,cornerRadius: 5)
                ctx.addPath(path.cgPath)
            }
        }
        ctx.fillPath()
        ctx.restoreGState()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        promoteToTextViewMode()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        promoteToTextViewMode()
    }

    // MARK: UIContextMenuInteractionDelegate

    /// Right-click (external mouse / trackpad) promotes the cell to a
    /// selectable UITextView with its text already selected — matching the
    /// long-press flow. Returning nil suppresses UIKit's default context menu
    /// so UITextView's native edit menu (Copy / Look Up / etc.) takes over.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        promoteToTextViewMode()
        return nil
    }

    /// Replace this label with a selectable UITextView and immediately activate selection.
    private func promoteToTextViewMode() {
        guard let parent = superview,activeTextView == nil else { return }

        let tv = TableCellTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainer.lineFragmentPadding = 0
        tv.attributedText = selectableAttributedText ?? attributedText

        // Give the text view a taller frame than the label so the selection
        // handles have enough touch area. Vertically pad around the text so
        // the content stays visually centered at the label's original position.
        let extraPad: CGFloat = 12
        tv.frame = CGRect(
            x: frame.origin.x,
            y: frame.origin.y-extraPad,
            width: frame.width,
            height: frame.height+extraPad*2
        )
        tv.textContainerInset = UIEdgeInsets(top: extraPad,left: 0,bottom: extraPad,right: 0)

        // When the user taps away or the copy menu closes, the text view resigns
        // first responder. Swap back to the lightweight label at that point.
        tv.onResignFirstResponder = { [weak self] in
            self?.demoteTextViewMode()
        }

        // Pass through the "Copy Table" action so it appears in the edit menu.
        tv.copyTableAction = copyTableAction
        tv.copyTableImageAction = copyTableImageAction

        activeTextView = tv
        isHidden = true
        parent.addSubview(tv)

        // Register the custom menu items, then select all and show the menu.
        // Order matches buildMenu: Add to Chat Input → Copy Table → Copy Table
        // Image.
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: String(localized: "Add to Chat Input"), action: #selector(TableCellTextView.addSelectionToChatInput(_:))),
            UIMenuItem(title: String(localized: "Copy Table"), action: #selector(TableCellTextView.copyTable)),
            //
            UIMenuItem(title: String(localized: "Copy Table Image"), action: #selector(TableCellTextView.copyTableImage)),
        ]

        // Select all text after a run-loop turn so TextKit finishes layout.
        DispatchQueue.main.async { [weak self,weak tv] in
            guard let tv else { return }
            tv.becomeFirstResponder()
            tv.selectedRange = NSRange(location: 0,length: tv.attributedText?.length ?? 0)

            // Show the edit menu over the text view.
            UIMenuController.shared.showMenu(from: tv,rect: tv.bounds)

            // Install the dismiss-tap after a short delay so it doesn't
            // immediately interfere with the menu presentation.
            DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { [weak self] in
                self?.addDismissTap()
            }
        }
    }

    /// Adds a tap recognizer to the window so that tapping *anywhere* outside
    /// the edit menu dismisses the promoted text view.
    private func addDismissTap() {
        guard let window = activeTextView?.window,dismissTap == nil else { return }
        let tap = UITapGestureRecognizer(target: self,action: #selector(handleDismissTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        dismissTap = tap
    }

    private func removeTapGesture() {
        if let tap = dismissTap {
            tap.view?.removeGestureRecognizer(tap)
            dismissTap = nil
        }
    }

    @objc private func handleDismissTap(_ gesture: UITapGestureRecognizer) {
        // Let the text view resign naturally — this triggers demoteTextViewMode()
        // via onResignFirstResponder. Calling demoteTextViewMode() directly here
        // would remove the text view before a menu action (e.g. Copy) completes.
        activeTextView?.resignFirstResponder()
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Don't let the dismiss tap fire while the edit menu is visible —
        // otherwise it kills the text view before Copy can execute.
        if gestureRecognizer === dismissTap,UIMenuController.shared.isMenuVisible {
            return false
        }
        return true
    }

    /// Remove the promoted UITextView and show the label again.
    private func demoteTextViewMode() {
        removeTapGesture()
        activeTextView?.onResignFirstResponder = nil
        activeTextView?.removeFromSuperview()
        activeTextView = nil
        isHidden = false
        UIMenuController.shared.menuItems = nil
    }
}

// MARK: - MiniClawToast

/// Lightweight, self-dismissing toast for one-shot action
/// feedback ("Saved", "Table copied", …). Window-level so it works from both
/// SwiftUI screens and UIKit views (e.g. the markdown table copy actions,
/// which run in a UILabel subclass with no SwiftUI context). Mirrors the
/// capsule style FileBrowserView already uses for its "Copied" toast.
func resolveMiniClawFileURLForNativeText(url: URL) -> URL? {
    guard url.scheme == "miniclaw" else { return nil }
    guard let host = url.host else {
        imgLogger.warning("[MiniClawImage][Resolve] no host in URL: \(url.absoluteString)")
        return nil
    }
    // Try the single-decoded subpath first; fall back to a double-decoded
    // variant when an inline-image link arrives double-encoded. This is the
    // same tolerant resolution the other 4 miniclaw:// resolvers already use; this
    // one (the inline-markdown image resolver) was the remaining single-decode
    // holdout, so double-encoded non-ASCII inline image names still failed here.
    // [T-ios-file-preview-stale-cache, completing T-fix-double-encoding 2026-06-01]
    let subPaths = MiniClawURLPathDecoding.subPathCandidates(for: url)
    imgLogger.info("[MiniClawImage][Resolve] BEGIN url=\(url.absoluteString) host=\(host) subPaths=\(subPaths) activeSession=\(MessageListModel.activeSessionId ?? "nil")")
    let fm = FileManager.default

    // Primary: active session persistent storage
    if let sid = MessageListModel.activeSessionId {
        for subPath in subPaths {
            let persistURL = MessageListModel.miniClawPersistentBase
                .appendingPathComponent(sid,isDirectory: true)
                .appendingPathComponent(host,isDirectory: true)
                .appendingPathComponent(subPath)
            imgLogger.info("[MiniClawImage][Resolve] checking session path=\(persistURL.path)")
            if fm.fileExists(atPath: persistURL.path) {
                let size = (try? fm.attributesOfItem(atPath: persistURL.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MiniClawImage][Resolve] FOUND in active session=\(sid) path=\(persistURL.path) size=\(size)")
                return persistURL
            }
        }
        imgLogger.info("[MiniClawImage][Resolve] NOT in active session=\(sid)")
    } else {
        imgLogger.info("[MiniClawImage][Resolve] no active session — skipping session lookup")
    }

    // Global namespaces (not session-scoped)
    if host == "skills" {
        for subPath in subPaths {
            let candidate = MessageListModel.miniClawSkillsPersistentDir.appendingPathComponent(subPath)
            imgLogger.info("[MiniClawImage][Resolve] checking global skills path=\(candidate.path)")
            if fm.fileExists(atPath: candidate.path) {
                let size = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MiniClawImage][Resolve] FOUND global skills path=\(candidate.path) size=\(size)")
                return candidate
            }
        }
    } else if host == "memory" {
        for subPath in subPaths {
            let candidate = MessageListModel.miniClawMemoryPersistentDir.appendingPathComponent(subPath)
            imgLogger.info("[MiniClawImage][Resolve] checking global memory path=\(candidate.path)")
            if fm.fileExists(atPath: candidate.path) {
                let size = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MiniClawImage][Resolve] FOUND global memory path=\(candidate.path) size=\(size)")
                return candidate
            }
        }
    }

    // [T-ios-miniClawurl-cross-session-isolation] DO NOT scan all session dirs.
    // This is the main image-render resolve path; the old "scan every session
    // and return the first same-named file" loop was the same P0 isolation
    // leak fixed in resolveMiniClawFileURL — session B rendering
    // model-use-zimage-0.jpg would resolve to session A's image. miniclaw:// is
    // session-scoped; not-found is the correct result for a cross-session ref.
    //
    // The rootfs `/var/miniclaw/<host>` fallback is kept ONLY for the global,
    // non-session-scoped namespaces (skills/memory/shared) — for those it just
    // points at the same global dir the iSH mount binds to. We explicitly
    // restrict it to those hosts so it can never reach another session's
    // attachments via whichever session happens to be mounted.
    let globalHosts: Set<String> = ["skills", "memory", "shared"]
    if globalHosts.contains(host) {
        for subPath in subPaths {
            let rootfsURL = RootfsManager.shared.dataPath
                .appendingPathComponent("var/miniclaw", isDirectory: true)
                .appendingPathComponent(host,isDirectory: true)
                .appendingPathComponent(subPath)
            if fm.fileExists(atPath: rootfsURL.path) {
                let size = (try? fm.attributesOfItem(atPath: rootfsURL.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MiniClawImage][Resolve] FOUND in global rootfs path=\(rootfsURL.path) size=\(size)")
                return rootfsURL
            }
        }
    }

    imgLogger.warning("[MiniClawImage][Resolve] NOT FOUND in active session / global dirs url=\(url.absoluteString) host=\(host) subPaths=\(subPaths) (cross-session scan disabled for isolation)")
    return nil
}

extension Array where Element == InlineNode {
    var plainText: String {
        map { node -> String in
            switch node {
            case .text(let t): return t
            case .code(let c): return c
            case .emphasis(let ch),.strong(let ch),.strikethrough(let ch): return ch.plainText
            case .link(_,let ch),.image(_,let ch): return ch.plainText
            case .softBreak: return " "
            case .lineBreak: return "\n"
            case .html(let h): return h
            case .inlineMath(let latex): return latex
            }
        }.joined()
    }
}

// MARK: - URL Resolution (bridged from ChatView)

/// Resolves a `miniclaw://` URL to a local file URL.
/// Keeps resolution behavior aligned with ChatView's miniclaw resolver.
final class MarkdownNSRenderer {
    private(set) var theme: MarkdownTheme

    /// Assistant message this renderer belongs to. Set by `MarkdownView`
    /// before each `render(blocks:)` call so inline image attachments can route
    /// tap gestures back to a paged gallery of all sibling images in the message.
    /// nil for contexts that don't provide a message (e.g. standalone previews).
    var messageId: UUID?
    /// Block identity for table slot-cache disambiguation. Set per render()
    /// call; when non-nil the slot key is simply messageId:blockId — immune
    /// to content collisions between tables with identical rows.
    var blockId: UUID?

    init(baseFontSize: CGFloat? = nil) {
        self.theme = MarkdownTheme(baseFontSize: baseFontSize)
    }

    func applyFontSizeChange(_ size: CGFloat) {
        theme = MarkdownTheme(baseFontSize: size)
    }
    private var bodyLineSpacing: CGFloat { theme.baseFontSize*0.25 }
    /// miniClawChat list item: .em(0.25) top margin
    private var listItemTopMargin: CGFloat { theme.baseFontSize*0.25 }
    /// miniClawChat headings: .em(1) top and bottom
    private var headingTopMargin: CGFloat { theme.baseFontSize }
    private var headingBottomMargin: CGFloat { theme.baseFontSize }

    /// Reuse existing media attachments across re-renders to avoid reload flicker during streaming.
    var imageAttachmentCache: [String: ImageAttachment] = [:]
    var videoAttachmentCache: [String: VideoAttachment] = [:]
    var audioAttachmentCache: [String: AudioAttachment] = [:]
    /// Reuse code block attachments by index to preserve ObjectIdentifier across streaming re-renders.
    var codeBlockAttachmentCache: [Int: CodeBlockAttachment] = [:]
    /// Content hashes for code blocks, keyed by sequential index.
    var codeBlockContentHashes: [Int: Int] = [:]
    /// Reuse table attachments by content hash so the same table layout
    /// can be reused even when re-rendered in a different message slot
    /// or after the renderer was wiped for an unrelated reason.
    ///
    /// HangFix(2026-05-14): the previous `[Int: …]` keyed by streaming
    /// index meant that whenever `isNewMessage` triggered a renderer wipe
    /// (e.g. when the cell is reused with a different assistant message),
    /// every TableAttachment was rebuilt and its `cachedLayout` reset to
    /// nil — forcing typesetter to run a full per-cell `boundingRect`
    /// pass on each `attachmentBounds` query. On a 6-table message that
    /// was 27 s of main-thread typesetter pin (ips MiniClaw-2026-05-14-094312).
    /// Keying by contentHash lets re-rendered identical tables hit the
    /// previously-built attachment + its `cachedLayout`.
    var tableAttachmentCache: [Int: TableAttachment] = [:]
    /// LRU eviction order for `tableAttachmentCache` so the cache can't
    /// grow without bound when the user scrolls through long history.
    /// Most-recently-touched contentHash sits at the end.
    var tableAttachmentLRU: [Int] = []
    private let tableAttachmentCacheCap = 64
    /// HangFix(2026-05-14) — per-slot identity preservation for in-progress
    /// streaming tables. When a table at the same `tableIndex` keeps
    /// growing row-by-row, its content hash changes every flush but it's
    /// the *same* visual table. Calling `update()` on the existing
    /// TableAttachment instance preserves NSTextAttachment identity, which
    /// keeps `updateUIView`'s prefix-equality fast path alive and lets
    /// `refreshAttachViews` swap only the affected TableScrollView in
    /// place rather than tearing down every attachment view. Without this,
    /// every streamed token rebuilds every attachment subview → flicker +
    /// O(N) work per flush.
    /// Key: "<messageUUID>:<tableIndex>". Without messageId, two different
    /// messages that both have a table at idx=2 would falsely share a
    /// slot during render — the new message's first render would call
    /// `update()` on the previous message's table data. Tracking by
    /// (messageId, idx) keeps streaming-growth detection scoped to the
    /// single message that's actually growing.
    var tableSlotCache: [String: TableAttachment] = [:]
    /// Map TableAttachment instance → its current contentHash key in
    /// `tableAttachmentCache` so we can re-key when `update()` mutates an
    /// in-place attachment. Keyed by ObjectIdentifier hashValue.
    var tableAttachmentReverseKey: [ObjectIdentifier: Int] = [:]
    var mathAttachmentCache: [String: MathAttachment] = [:]
    private var codeBlockIndex = 0
    private var tableIndex = 0

    struct RenderedBlock {
        let attributed: NSAttributedString
        let topMargin: CGFloat?
        let bottomMargin: CGFloat?
        let isBlockAttachment: Bool

        init(attributed: NSAttributedString,topMargin: CGFloat?,bottomMargin: CGFloat?,isBlockAttachment: Bool = false) {
            self.attributed = attributed
            self.topMargin = topMargin
            self.bottomMargin = bottomMargin
            self.isBlockAttachment = isBlockAttachment
        }
    }

    func render(blocks: [BlockNode]) -> NSAttributedString {
        codeBlockIndex = 0
        tableIndex = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        let tableCountBefore = tableAttachmentCache.count

        let result = renderBlockSeq(blocks,listDepth: 0,quoteDepth: 0,tightSpacing: false).attributed
        let elapsed = (CFAbsoluteTimeGetCurrent()-t0)*1000

        // Only log noisy cases to keep signal-to-noise high: slow renders, or
        // renders that touched tables (streaming table bug suspect).
        if elapsed >= 20 || tableIndex>0 {
            let level = elapsed >= 100 ? "🔥" : ""
            // Include messageId + rendererPtr so
            // we can distinguish "1 textView rendering N times" from "N
            // different textViews rendering the same content" (cell reuse vs
            // SwiftUI re-invalidation of the same coordinator).
            let mid = messageId?.uuidString.prefix(8) ?? "?"
            let rId = String(ObjectIdentifier(self).hashValue&0xFFFFFF,radix: 16)
            Self.rendererLogger.info("[RND]\(level) mid=\(mid) rnd=\(rId) blocks=\(blocks.count) tables=\(tableIndex) codeBlocks=\(codeBlockIndex) attrLen=\(result.length) \(String(format: "%.1f", elapsed))ms tableCache=\(tableCountBefore)→\(tableAttachmentCache.count)")
        }
        return result
    }

    fileprivate static let rendererLogger = AppLogger(category: "MarkdownRenderer")

    // MARK: Block Rendering

    private func renderBlock(_ block: BlockNode,listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        switch block {
        case .paragraph(let content):
            return renderParagraph(content,quoteDepth: quoteDepth)
        case .heading(let level,let content):
            return renderHeading(level: level,content: content,quoteDepth: quoteDepth)
        case .codeBlock(let fenceInfo,let content):
            return renderCodeBlockAttachment(fenceInfo: fenceInfo,content: content,quoteDepth: quoteDepth)
        case .blockquote(let children):
            return renderBlockquote(children: children,listDepth: listDepth,quoteDepth: quoteDepth)
        case .bulletedList(let isTight,let items):
            return renderBulletList(isTight: isTight,items: items,listDepth: listDepth,quoteDepth: quoteDepth)
        case .numberedList(let isTight,let start,let items):
            return renderNumberList(isTight: isTight,start: start,items: items,listDepth: listDepth,quoteDepth: quoteDepth)
        case .taskList(let isTight,let items):
            return renderTaskListView(isTight: isTight,items: items,listDepth: listDepth,quoteDepth: quoteDepth)
        case .table(let alignments,let rows):
            return renderTableAttach(alignments: alignments,rows: rows)
        case .thematicBreak:
            return renderThematicBreakAttach()
        case .htmlBlock(let content):
            return renderHTMLBlockNow(content,quoteDepth: quoteDepth)
        case .mathBlock(let content):
            return renderMathBlockAttach(latex: content)
        }
    }

    private func renderBlockSeq(_ blocks: [BlockNode],listDepth: Int,quoteDepth: Int,tightSpacing: Bool) -> RenderedBlock {
        mergeRenderedBlocksNow(
            blocks.map { renderBlock($0,listDepth: listDepth,quoteDepth: quoteDepth) },
            tightSpacing: tightSpacing
        )
    }

    private func mergeRenderedBlocksNow(_ blocks: [RenderedBlock],tightSpacing: Bool) -> RenderedBlock {
        guard let first = blocks.first else {
            return RenderedBlock(attributed: NSAttributedString(),topMargin: nil,bottomMargin: nil)
        }

        let result = NSMutableAttributedString(attributedString: first.attributed)
        for i in 1..<blocks.count {
            let previous = blocks[i-1]
            let current = blocks[i]
            let suppressBottom = tightSpacing && !previous.isBlockAttachment && !current.isBlockAttachment
            let previousBottom = suppressBottom ? 0 : (previous.bottomMargin ?? 0)
            let spacing = max(current.topMargin ?? 0,previousBottom)
            // Apply spacing as paragraphSpacing on the last paragraph of the accumulated result
            addBlockSpacing(result,spacing: spacing)
            result.append(blockSeparator(height: spacing))
            result.append(current.attributed)
        }

        return RenderedBlock(
            attributed: result,
            topMargin: first.topMargin,
            bottomMargin: blocks.last?.bottomMargin
        )
    }

    private func blockSeparator(height: CGFloat) -> NSAttributedString {
        // Strategy: inject paragraphSpacing (after) on the previous block's trailing \n,
        // rather than trying to create an independent spacer paragraph.
        // This is handled by addSpacingAfterLastParagraph on the previous block.
        // Here we just return a plain \n to separate paragraphs.
        let separator = NSMutableAttributedString(string: "\n")
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0
        style.maximumLineHeight = 0.01
        style.lineSpacing = 0
        separator.addAttributes([
            .font: UIFont.systemFont(ofSize: 0.01),
            .paragraphStyle: style,
        ],range: NSRange(location: 0,length: 1))
        return separator
    }

    /// Sets `paragraphSpacing` on the last paragraph of the attributed string
    /// so TextKit adds space after it.
    private func addBlockSpacing(_ attrStr: NSMutableAttributedString,spacing: CGFloat) {
        guard attrStr.length>0 else { return }
        // Find the last paragraph's range
        let text = attrStr.string as NSString
        let lastParaRange = text.paragraphRange(for: NSRange(location: max(text.length-1,0),length: 0))
        let style: NSMutableParagraphStyle
        if let existing = attrStr.attribute(.paragraphStyle,at: lastParaRange.location,effectiveRange: nil) as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.paragraphSpacing = spacing
        attrStr.addAttribute(.paragraphStyle,value: style,range: lastParaRange)
    }

    // MARK: Paragraph

    private func renderParagraph(_ inlines: [InlineNode],quoteDepth: Int) -> RenderedBlock {
        var baseAttrs = baseAttributes(quoteDepth: quoteDepth)
        let style: NSMutableParagraphStyle
        if let existing = baseAttrs[.paragraphStyle] as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.lineSpacing = bodyLineSpacing
        // 2026-08-12:AI 消息段落/图片硬左对齐(LTR 默认 natural 也是左,显式保证
        // 不受未来 paragraphStyle 复用/继承影响,满足"AI 发送的文件靠左显示")。
        style.alignment = .left
        baseAttrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: renderInlines(inlines,baseAttributes: baseAttrs),
            topMargin: 0,
            bottomMargin: 12
        )
    }

    // MARK: Heading

    private func renderHeading(level: Int,content: [InlineNode],quoteDepth: Int) -> RenderedBlock {
        var attrs = baseAttributes(quoteDepth: quoteDepth)
        attrs[.font] = theme.headingFont(level: level)
        let style = NSMutableParagraphStyle()
        // miniClawChat doesn't set relativeLineSpacing for headings
        style.lineSpacing = 0
        if quoteDepth>0 {
            style.headIndent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel
            style.firstLineHeadIndent = style.headIndent
        }
        attrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: renderInlines(content,baseAttributes: attrs),
            topMargin: headingTopMargin,
            bottomMargin: headingBottomMargin
        )
    }

    // MARK: Code Block (NSTextAttachment)

    private func renderCodeBlockAttachment(fenceInfo: String?,content: String,quoteDepth: Int = 0) -> RenderedBlock {
        // A fence with no info string (a bare
        // ``` block) has no language. Default it to "text" so every code block
        // shows a language label (and reserves the header space) uniformly —
        // an unlabeled block now reads as "text" instead of being blank.
        let parsedLang = fenceInfo?.split(separator: " ").first.map(String.init)
        let language = (parsedLang?.isEmpty == false) ? parsedLang : "text"
        let trimmed = content.hasSuffix("\n") ? String(content.dropLast()) : content
        let idx = codeBlockIndex
        codeBlockIndex += 1

        var hasher = Hasher()
        hasher.combine(trimmed)
        hasher.combine(language)
        let contentHash = hasher.finalize()

        let attachment: CodeBlockAttachment
        if let cached = codeBlockAttachmentCache[idx],codeBlockContentHashes[idx] == contentHash {
            // Exact same content — reuse object so TextKit skips attachmentBounds recalc
            cached.blockIndex = idx
            attachment = cached
        } else {
            // Content changed or first time — create fresh object so TextKit recalculates bounds.
            // The previous view will be updated in-place by refreshAttachViews via codeBlockViewCache.
            attachment = CodeBlockAttachment(code: trimmed,language: language,theme: theme,quoteDepth: quoteDepth)
            attachment.blockIndex = idx
            codeBlockAttachmentCache[idx] = attachment
            codeBlockContentHashes[idx] = contentHash
        }

        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        return RenderedBlock(
            attributed: result,
            topMargin: 6,
            bottomMargin: 4,
            isBlockAttachment: true
        )
    }

    // MARK: Blockquote

    private func renderBlockquote(children: [BlockNode],listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        let newDepth = quoteDepth+1
        let renderedChildren = renderBlockSeq(children,listDepth: listDepth,quoteDepth: newDepth,tightSpacing: false)
        let result = NSMutableAttributedString(attributedString: renderedChildren.attributed)
        // Mark the entire range with blockquote depth for bar drawing
        let fullRange = NSRange(location: 0,length: result.length)
        if fullRange.length>0 {
            // 2026-08-11 嵌套引用修复:先收集本段内已有的更高深度(内层嵌套
            // 块渲染时已写入 depth=2/3…),无条件覆盖会把它压成 1,导致
            // 二级/三级嵌套引用只画一根竖线(drawQuoteBars 按 depth 画线)。
            // 覆盖后写回更高深度,内层 span 才能画多根。
            var deeperRanges: [(NSRange,Int)] = []
            result.enumerateAttribute(.blockquoteDepth,in: fullRange,options: []) { value,range,_ in
                if let d = value as? Int, d > newDepth {
                    deeperRanges.append((range,d))
                }
            }
            result.addAttribute(.blockquoteDepth,value: newDepth,range: fullRange)
            for (r,d) in deeperRanges {
                result.addAttribute(.blockquoteDepth,value: d,range: r)
            }
            // miniClawChat blockquote uses secondaryText color
            // 2026-08-11 引用内链接/行内代码/标题变色修复:与上方 blockquoteDepth
            // 同模式——先收集本段内已有的特殊前景色(链接 linkColor、行内代码
            // inlineCodeColor、标题 labelColor),再覆盖为引用灰,最后写回,
            // 否则 > [链接](url) 和 > `code` 会被压成灰色(链接仍可点但不可辨识)。
            var specialColorRanges: [(NSRange,UIColor)] = []
            result.enumerateAttribute(.foregroundColor,in: fullRange,options: []) { value,range,_ in
                guard let color = value as? UIColor else { return }
                if color != theme.secondaryLabelColor {
                    specialColorRanges.append((range,color))
                }
            }
            result.addAttribute(.foregroundColor,value: theme.secondaryLabelColor,range: fullRange)
            for (r,c) in specialColorRanges {
                result.addAttribute(.foregroundColor,value: c,range: r)
            }
        }
        // Blockquote inherits margins from children (no explicit markdownMargin in miniClawChat)
        return RenderedBlock(
            attributed: result,
            topMargin: renderedChildren.topMargin,
            bottomMargin: renderedChildren.bottomMargin
        )
    }

    // MARK: Bulleted List

    private func renderBulletList(isTight: Bool,items: [RawListItem],listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel+CGFloat(listDepth)*Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent+Self.listIndentPerLevel

        // HangFix(2026-05-13, re-restored 2026-05-14 with .ips evidence) —
        // Bullet glyphs MUST be Unicode characters, NOT NSTextAttachments.
        // Build 13 reverted bullets to SF-symbol NSTextAttachments per
        // user request to restore visual size — within 90s of install the
        // device hit a fresh 0x8BADF00D watchdog (ips MiniClaw-2026-05-14-
        // 163330). Main-thread frame #1: `NSConcreteTextStorage
        // attribute:atIndex:effectiveRange:` — fillLayoutHole scanning
        // attribute runs. A 6-item list produces 6 image-attachment runs;
        // typesetter cost is O(glyphs × runs) and explodes whenever
        // setSize: forces a full re-layout.
        //
        // To keep bullets visually prominent (the original complaint about
        // "list got smaller") without paying the attachment-run tax, render the
        // Unicode glyph at 1.25× baseFont with bold weight + a small
        // baseline offset so it reads as an emphasized punctuation mark.
        // Depth → glyph:
        // 0  filled circle "•" U+2022
        // 1  hollow circle "◦" U+25E6
        // 2+ filled square "▪" U+25AA
        let bulletGlyph: String
        switch listDepth {
        case 0: bulletGlyph = "\u{2022}" // •
        case 1: bulletGlyph = "\u{25E6}" // ◦
        default: bulletGlyph = "\u{25AA}" // ▪
        }
        let bulletColor = quoteDepth>0 ? theme.secondaryLabelColor : theme.labelColor
        var bulletAttrs = baseAttributes(quoteDepth: quoteDepth)
        bulletAttrs[.foregroundColor] = bulletColor
        // 1.25× bold makes the Unicode bullet read at roughly the same
        // visual weight as the prior SF-symbol filled circle.
        bulletAttrs[.font] = UIFont.systemFont(ofSize: theme.baseFontSize*1.25,weight: .bold)
        // Small negative baseline offset so the bullet sits near the
        // body text's x-height rather than its cap-height.
        bulletAttrs[.baselineOffset] = -theme.baseFontSize*0.05

        for item in items {
            let itemResult = NSMutableAttributedString()
            itemResult.append(NSAttributedString(string: bulletGlyph,attributes: bulletAttrs))
            itemResult.append(NSAttributedString(string: " ", attributes: baseAttributes(quoteDepth: quoteDepth)))
            let child = renderListItemsChildren(item.children,listDepth: listDepth+1,quoteDepth: quoteDepth,isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndentWidth(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocksNow(renderedItems,tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0,16)
        )
    }

    // MARK: Numbered List

    private func renderNumberList(isTight: Bool,start: Int,items: [RawListItem],listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel+CGFloat(listDepth)*Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent+Self.listIndentPerLevel

        for (i,item) in items.enumerated() {
            let number = "\(start + i). "
            let itemResult = NSMutableAttributedString(string: number,attributes: baseAttributes(quoteDepth: quoteDepth))
            let child = renderListItemsChildren(item.children,listDepth: listDepth+1,quoteDepth: quoteDepth,isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndentWidth(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocksNow(renderedItems,tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0,16)
        )
    }

    // MARK: Task List

    private func renderTaskListView(isTight: Bool,items: [RawTaskListItem],listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel+CGFloat(listDepth)*Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent+Self.listIndentPerLevel

        for item in items {
            let checkbox = item.isCompleted ? "☑ " : "☐ "
            let itemResult = NSMutableAttributedString(string: checkbox,attributes: baseAttributes(quoteDepth: quoteDepth))
            let child = renderListItemsChildren(item.children,listDepth: listDepth+1,quoteDepth: quoteDepth,isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndentWidth(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocksNow(renderedItems,tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0,16)
        )
    }

    private func renderListItemsChildren(_ children: [BlockNode],listDepth: Int,quoteDepth: Int,isTight: Bool) -> RenderedBlock {
        renderBlockSeq(children,listDepth: listDepth,quoteDepth: quoteDepth,tightSpacing: isTight)
    }

    private func applyListIndentWidth(to attributed: NSMutableAttributedString,firstLineIndent: CGFloat,continuationIndent: CGFloat) {
        guard attributed.length>0 else { return }

        let text = attributed.string as NSString
        let total = NSRange(location: 0,length: text.length)
        var cursor = total.location
        var isFirstParagraph = true

        while cursor<NSMaxRange(total) {
            let paragraphRange = text.paragraphRange(for: NSRange(location: cursor,length: 0))
            let effectiveRange = NSIntersectionRange(paragraphRange,total)
            guard effectiveRange.length>0 else { break }

            let style: NSMutableParagraphStyle
            if let existing = attributed.attribute(.paragraphStyle,at: effectiveRange.location,effectiveRange: nil) as? NSParagraphStyle {
                style = existing.mutableCopy() as! NSMutableParagraphStyle
            } else {
                style = NSMutableParagraphStyle()
            }
            style.lineSpacing = max(style.lineSpacing,bodyLineSpacing)
            // 2026-08-11 列表内引用缩进修复:带 .blockquoteDepth 的段落
            // (baseAttributes 已按 quoteDepth*13 设好 headIndent)不再被列表
            // continuationIndent 抬走——否则引用文字被推到列表缩进(24-48pt),
            // 而竖线 drawQuoteBars 只按 quoteDepth 画在最左 1-17pt,线文错位。
            let isQuotePara = attributed.attribute(.blockquoteDepth,at: effectiveRange.location,effectiveRange: nil) != nil
            if !isQuotePara {
                style.headIndent = max(style.headIndent,continuationIndent)
                if isFirstParagraph {
                    style.firstLineHeadIndent = max(style.firstLineHeadIndent,firstLineIndent)
                    isFirstParagraph = false
                } else {
                    style.firstLineHeadIndent = max(style.firstLineHeadIndent,continuationIndent)
                }
            }
            attributed.addAttribute(.paragraphStyle,value: style,range: effectiveRange)

            cursor = NSMaxRange(paragraphRange)
        }
    }

    // MARK: Table (NSTextAttachment)

    private func renderTableAttach(alignments: [RawTableColumnAlignment],rows: [RawTableRow]) -> RenderedBlock {
        let idx = tableIndex
        tableIndex += 1

        var hasher = Hasher()
        hasher.combine(alignments)
        hasher.combine(rows)
        let contentHash = hasher.finalize()

        // [ios_session_open_last_cell_occluded] Slot key. The slot cache (Step 2
        // below) keeps a TableAttachment's identity stable while its content GROWS
        // during streaming, so a still-arriving table updates in place instead of
        // rebuilding every token. It must therefore be keyed by something that:
        // (a) stays the SAME as one table streams in, but
        // (b) DIFFERS between two genuinely distinct tables in the same message.
        //
        // The old key was "messageId:tableIndex". `tableIndex` resets to 0 at the
        // top of every `render(blocks:)` call — and in the cell-per-block list
        // each assistant block (each table) is rendered by its OWN render() call,
        // so every table got tableIndex == 0. Two different tables in one message
        // therefore collided on "messageId:0", shared one attachment via Step 2,
        // and `update()`-overwrote each other → the on-screen table showed another
        // table's content (correct on first paint, swapped after a reuse pass):
        // two distinct tables in one message both keyed "<msgId>:0", same slot,
        // same shared TableAttachment, content flipping between them.
        //
        // Fix: always include tableIndex in the slot key. tableIndex
        // increments within a single render() call, so two tables in the
        // same block (same render pass) always get distinct keys — even if
        // their content is byte-for-byte identical.
        //
        // When blockId is available (cell-per-block list), include it to
        // also disambiguate tables across blocks that happen to share the
        // same tableIndex (e.g. each block's render() resets idx to 0).
        //
        // tableIndex resets per render() call, which is the right scope:
        // a streaming re-render of the same block sees the same table at
        // the same idx, so the slot key stays stable for in-place update.
        let slotKey = "\(messageId?.uuidString ?? "nil"):\(blockId?.uuidString ?? "_"):\(idx)"

        let attachment: TableAttachment
        // Step 1: same-content cache (any slot, any message). Lets the
        // SAME identical table that already lives in another cell share
        // its precomputed `cachedLayout` — the historical-message hang
        // fix from the 27s ips capture.
        if let cached = tableAttachmentCache[contentHash] {
            attachment = cached
            // Refresh LRU position.
            if let pos = tableAttachmentLRU.firstIndex(of: contentHash) {
                tableAttachmentLRU.remove(at: pos)
            }
            tableAttachmentLRU.append(contentHash)
            // Also pin this attachment to the current (message,slot) so
            // subsequent streaming growth at this slot updates it in
            // place rather than creating a new attachment instance.
            tableSlotCache[slotKey] = cached
            tableAttachmentReverseKey[ObjectIdentifier(cached)] = contentHash
            Self.rendererLogger.info("[RND] table#\(idx) CACHE HIT rows=\(rows.count) cols=\(alignments.count) hash=\(contentHash)")
        } else if let slotAttachment = tableSlotCache[slotKey] {
            // Step 2: streaming growth — same (message,slot), new content
            // hash. Mutate in place to keep NSTextAttachment identity
            // stable so the updateUIView prefix-equality fast path stays
            // alive and refreshAttachViews swaps only this attachment's
            // TableScrollView (not every attachment view in the cell).
            // Without this, every streamed token would rebuild every
            // attachment subview — flicker + O(N) work per flush.
            slotAttachment.update(alignments: alignments,rows: rows)
            attachment = slotAttachment
            // Re-key the by-content cache: drop the old hash entry (if
            // any), insert under the new hash, refresh LRU.
            if let oldHash = tableAttachmentReverseKey[ObjectIdentifier(slotAttachment)] {
                if let pos = tableAttachmentLRU.firstIndex(of: oldHash) {
                    tableAttachmentLRU.remove(at: pos)
                }
                tableAttachmentCache.removeValue(forKey: oldHash)
            }
            tableAttachmentCache[contentHash] = slotAttachment
            tableAttachmentLRU.append(contentHash)
            tableAttachmentReverseKey[ObjectIdentifier(slotAttachment)] = contentHash
            Self.rendererLogger.info("[RND] table#\(idx) CACHE UPDATE rows=\(rows.count) cols=\(alignments.count) newHash=\(contentHash)")
        } else {
            // Step 3: brand new — neither same content nor same slot
            // recognized. Create a fresh TableAttachment.
            attachment = TableAttachment(alignments: alignments,rows: rows,theme: theme)
            tableAttachmentCache[contentHash] = attachment
            tableAttachmentLRU.append(contentHash)
            tableSlotCache[slotKey] = attachment
            tableAttachmentReverseKey[ObjectIdentifier(attachment)] = contentHash
            // LRU evict — keep the by-content cache bounded.
            while tableAttachmentLRU.count>tableAttachmentCacheCap {
                let evict = tableAttachmentLRU.removeFirst()
                if let dropped = tableAttachmentCache.removeValue(forKey: evict) {
                    tableAttachmentReverseKey.removeValue(forKey: ObjectIdentifier(dropped))
                    // Drop matching slot entries that point at the same
                    // attachment we just evicted — keeps tableSlotCache
                    // consistent with tableAttachmentCache.
                    for (slot,att) in tableSlotCache where att === dropped {
                        tableSlotCache.removeValue(forKey: slot)
                    }
                }
            }
            Self.rendererLogger.info("[RND] table#\(idx) CACHE MISS rows=\(rows.count) cols=\(alignments.count) newHash=\(contentHash) cacheSize=\(tableAttachmentCache.count)")
        }

        // Wrap the table attachment with U+2028 (LINE SEPARATOR) on both
        // sides. This forces TextKit1 to place the attachment in its own
        // line fragment and prevents `_fillLayoutHole` from trying to merge
        // it with adjacent content. Without these separators, when a tall
        // table (observed at ≥ 9 rows ~ 400pt) arrives via streaming,
        // TextKit1's line-break-fitting routine enters an infinite loop
        // inside `_performTextKit1LayoutCalculation` and hangs the main
        // thread long enough to trip the 10s scene-update watchdog
        // (0x8BADF00D). The U+2028 wrap was verified to work around this
        // on iOS 26 TextKit1. Replace with TextKit2 long-term.
        let result = NSMutableAttributedString()
        let separatorPara = NSMutableParagraphStyle()
        separatorPara.paragraphSpacing = 0
        separatorPara.paragraphSpacingBefore = 0
        separatorPara.lineSpacing = 0
        // Tiny font collapses the U+2028 line fragment to ~0pt. The separator's
        // only job is to force TextKit1 to place the table attachment in its own
        // line fragment (workaround for the 9+-row _fillLayoutHole hang); it
        // should not contribute visible vertical space. Previously used
        // theme.baseFont (16.5pt), which ate ~20pt above and below every table.
        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 0.01),
            .paragraphStyle: separatorPara,
        ]
        result.append(NSAttributedString(string: "\u{2028}", attributes: sepAttrs))
        let attachPart = NSMutableAttributedString(attachment: attachment)
        attachPart.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: attachPart.length))
        result.append(attachPart)
        result.append(NSAttributedString(string: "\u{2028}", attributes: sepAttrs))
        return RenderedBlock(
            attributed: result,
            topMargin: theme.baseFontSize*0.6,
            bottomMargin: theme.baseFontSize*0.6,
            isBlockAttachment: true
        )
    }

    // MARK: Thematic Break (NSTextAttachment)

    private func renderThematicBreakAttach() -> RenderedBlock {
        let attachment = ThematicBreakAttachment(theme: theme)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        return RenderedBlock(attributed: result,topMargin: 16,bottomMargin: 16,isBlockAttachment: true)
    }

    // MARK: HTML Block

    private func renderHTMLBlockNow(_ content: String,quoteDepth: Int) -> RenderedBlock {
        var attrs = baseAttributes(quoteDepth: quoteDepth)
        let style: NSMutableParagraphStyle
        if let existing = attrs[.paragraphStyle] as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.lineSpacing = bodyLineSpacing
        attrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: NSAttributedString(string: content,attributes: attrs),
            topMargin: 0,
            bottomMargin: 16
        )
    }

    // MARK: Media Attachments (inline .image nodes rendered as block-level attachments)

    private func renderImageAttach(source: String) -> NSAttributedString {
        let attachment: ImageAttachment
        if let cached = imageAttachmentCache[source] {
            AppLogger(category: "ChatList.Attach").info("[IMG][RENDER] REUSE src=\(ImageAttachment.shortSrc(source)) ptr=\(ObjectIdentifier(cached).hashValue & 0xFFFFFF) loaded=\(cached.loadedImage != nil)")
            imgLogger.info("[MiniClawImage][RenderAttach] REUSE cached attachment src=\(source) loaded=\(cached.loadedImage != nil) imgSize=\(cached.loadedImage.map { "\($0.size.width)x\($0.size.height)" } ?? "nil")")
            // Keep messageId fresh on reused attachments — the same renderer
            // instance may survive across different messages during cell reuse.
            cached.messageId = messageId
            // Fingerprint check: if the underlying file has been rewritten
            // since we last loaded (size or mtime changed), drop the
            // cached bitmap so the next draw re-reads from disk.
            let currentFp = miniClawMediaCacheKey(for: source)
            if let loadedFp = cached.loadedFingerprint,loadedFp != currentFp {
                AppLogger(category: "ChatList.Attach").info("[IMG][RENDER] FINGERPRINT-DROP src=\(ImageAttachment.shortSrc(source)) old=\(loadedFp) new=\(currentFp) — bitmap invalidated, will reload")
                imgLogger.info("[MiniClawImage][RenderAttach] FINGERPRINT CHANGED src=\(source) old=\(loadedFp) new=\(currentFp) — invalidating cached image")
                cached.invalidateLoadedImage()
            }
            attachment = cached
        } else {
            AppLogger(category: "ChatList.Attach").info("[IMG][RENDER] CREATE src=\(ImageAttachment.shortSrc(source)) cacheCount=\(self.imageAttachmentCache.count) — fresh ImageAttachment, ObjectIdentifier changed, view WILL be rebuilt")
            imgLogger.info("[MiniClawImage][RenderAttach] CREATE new ImageAttachment src=\(source) cacheCount=\(self.imageAttachmentCache.count)")
            attachment = ImageAttachment(source: source,theme: theme,messageId: messageId)
            imageAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        // 2026-08-12 治本:图片字符必须带显式 .left 段落样式——append 不继承属性,
        // 缺 .paragraphStyle 时 TextKit 回退 .natural(实测居中),造成"文字靠左、图片居中"。
        let imagePara = NSMutableParagraphStyle()
        imagePara.alignment = .left
        result.addAttribute(.paragraphStyle,value: imagePara,range: NSRange(location: 0,length: result.length))
        return result
    }

    private func renderVideoAttach(source: String) -> NSAttributedString {
        let attachment: VideoAttachment
        if let cached = videoAttachmentCache[source] {
            attachment = cached
        } else {
            attachment = VideoAttachment(source: source,theme: theme)
            videoAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        // 2026-08-12 治本:视频卡片同图片——显式 .left 段落样式,避免缺属性回退居中。
        let videoPara = NSMutableParagraphStyle()
        videoPara.alignment = .left
        result.addAttribute(.paragraphStyle,value: videoPara,range: NSRange(location: 0,length: result.length))
        return result
    }

    private func renderAudioAttach(source: String) -> NSAttributedString {
        let attachment: AudioAttachment
        if let cached = audioAttachmentCache[source] {
            attachment = cached
        } else {
            attachment = AudioAttachment(source: source,theme: theme)
            audioAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        // 2026-08-12 治本:音频卡片同图片——显式 .left 段落样式,避免缺属性回退居中。
        let audioPara = NSMutableParagraphStyle()
        audioPara.alignment = .left
        result.addAttribute(.paragraphStyle,value: audioPara,range: NSRange(location: 0,length: result.length))
        return result
    }

    /// 非媒体文件(pdf/md/docx/txt 等 markdown 图片语法的未知扩展名)→ 渲染为
    /// 带边框 + SF 图标的文件指示器(2026-08-13 治本:替代大矩形占位,区别于工具/思考指示器)。
    /// 文件名超 10 字截断 + …;点击走系统预览(QL)。
    func renderFileAttach(source: String, altText: String) -> NSAttributedString {
        let rawName: String
        if let url = URL(string: source), !url.lastPathComponent.isEmpty {
            rawName = url.lastPathComponent
        } else {
            rawName = altText.isEmpty ? "file" : altText
        }
        let name = rawName.count > 10 ? String(rawName.prefix(10)) + "…" : rawName
        let attachment = FileAttachment(fileName: name, source: source, theme: theme)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        // 治本:显式 lineSpacing=0,让文件卡片所在行的行高 = 卡片高(40),
        // 四角圆角完整落在行内,既不露黑也不会上圆下直。
        let filePara = NSMutableParagraphStyle()
        filePara.alignment = .left
        filePara.lineSpacing = 0
        result.addAttribute(.paragraphStyle, value: filePara, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Inline Rendering

    /// Build the URL stored in a markdown link's `.link` attribute, undoing a
    /// double percent-encoding when present.
    ///
    /// file_write returns a singly-encoded
    /// miniclaw_url (e.g. `miniclaw://workspace/GitHub%E7%83%AD….md`). When the model
    /// embeds it in `[text](url)` and it passes through the markdown render
    /// pipeline, the literal `%` can get re-encoded to `%25`, yielding a
    /// double-encoded destination (`…%25E7…`). `URL(string:).path` then only
    /// peels one layer, leaving `%E7…`, which matches no file on disk — so the
    /// tap falls through to the parent workspace folder (the reported `.bin`
    /// folder symptom) instead of previewing the file. Detect that case and
    /// decode one extra layer before building the URL, so the `.link` carries
    /// the correct singly-encoded URL the tap handler / resolver expects. The
    /// resolver-side `subPathCandidates` tolerance stays as a backstop.
    private func normalizeLinkURL(from destination: String) -> URL? {
        let fallback = URL(string: destination)
        // Only miniclaw:// links are affected; everything else is untouched.
        guard destination.hasPrefix("miniclaw://") else {
            return fallback
        }
        // URL(string:) returned nil — on iOS
        // Foundation this happens when the destination carries raw non-ASCII in
        // the path (e.g. a filename with U+FF5C `｜`, CJK, emoji that the LLM
        // emitted unencoded inside a miniclaw:// link). The link would otherwise be
        // dead (no .link attribute → not tappable). Percent-encode the path
        // portion segment-by-segment and retry. Idempotent: a segment that is
        // ALREADY validly encoded is left untouched, so an already-%EF%BD%9C URL
        // is never double-encoded (it also wouldn't reach here, since URL(string:)
        // accepts it — this is belt-and-suspenders).
        guard let base = fallback else {
            return encodeRawMiniClawURL(destination)
        }
        // A correctly singly-encoded miniclaw_url decodes cleanly: `base.path`
        // contains no stray `%`. A double-encoded one (`%25E7…`) peels only one
        // layer here, leaving a literal `%E7…` in `.path`. That residual `%` is
        // the double-encoding signal — decode one more layer. A filename that
        // legitimately contains `%` is recovered to the same path either way
        // (the `%XX` of a real byte can't reappear), and the resolve-time
        // existence check (subPathCandidates) remains the final disambiguator.
        guard base.path.contains("%"),
              let once = destination.removingPercentEncoding,
              once.hasPrefix("miniclaw://"),
              let fixed = URL(string: once) else {
            return base
        }
        return fixed
    }


    private func renderInlines(_ inlines: [InlineNode],baseAttributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in inlines {
            result.append(renderInline(inline,attributes: attrs))
        }
        return result
    }

    private func renderInline(_ node: InlineNode,attributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch node {
        case .text(let text):
            return NSAttributedString(string: text,attributes: attrs)

        case .code(let code):
            var codeAttrs = attrs
            codeAttrs[.font] = theme.inlineCodeFont
            codeAttrs[.foregroundColor] = theme.inlineCodeColor
            codeAttrs[.inlineCodeBackground] = true
            codeAttrs[.inlineCodeText] = code
            // Set .backgroundColor to trigger fillBackgroundRectArray in MiniClawLayoutManager
            // The actual color is drawn there with rounded corners; this just triggers the callback.
            codeAttrs[.backgroundColor] = theme.inlineCodeBackground
            // Add hair spaces for visual padding inside the background highlight.
            return NSAttributedString(string: "\u{200A}\(code)\u{200A}", attributes: codeAttrs)

        case .emphasis(let children):
            var emphAttrs = attrs
            if let font = attrs[.font] as? UIFont {
                emphAttrs[.font] = font.withTraits(.traitItalic)
            }
            return renderInlines(children,baseAttributes: emphAttrs)

        case .strong(let children):
            var strongAttrs = attrs
            if let font = attrs[.font] as? UIFont {
                let descriptor = font.fontDescriptor.addingAttributes([
                    .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
                ])
                strongAttrs[.font] = UIFont(descriptor: descriptor,size: font.pointSize)
            }
            return renderInlines(children,baseAttributes: strongAttrs)

        case .strikethrough(let children):
            var strikeAttrs = attrs
            strikeAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return renderInlines(children,baseAttributes: strikeAttrs)

        case .link(let destination,let children):
            var linkAttrs = attrs
            if let url = normalizeLinkURL(from: destination) {
                linkAttrs[.link] = url
            }
            linkAttrs[.foregroundColor] = theme.linkColor
            linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return renderInlines(children,baseAttributes: linkAttrs)

        case .image(let source,let children):
            let ext = URL(string: source)?.pathExtension.lowercased() ?? ""
            let altText = children.plainText
            imgLogger.info("[MiniClawImage][InlineParse] .image node src=\(source) ext=\(ext) alt=\(altText)")
            if nativeAudioExts.contains(ext) {
                return renderAudioAttach(source: source)
            } else if nativeVideoExts.contains(ext) {
                return renderVideoAttach(source: source)
            } else if nativeImageExts.contains(ext) || ext.isEmpty {
                imgLogger.info("[MiniClawImage][InlineParse] routing to IMAGE attachment src=\(source)")
                return renderImageAttach(source: source)
            } else {
                // 非媒体文件(pdf/md/docx 等)→「📃文件名」文本附件(2026-08-13 治本:
                // 替代加载失败的大矩形占位)。
                imgLogger.info("[MiniClawImage][InlineParse] non-media ext=\(ext), routing to FILE attachment src=\(source)")
                return renderFileAttach(source: source, altText: altText)
            }

        case .html(let html):
            return NSAttributedString(string: html,attributes: attrs)

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attrs)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attrs)

        case .inlineMath(let latex):
            return renderInlineMathAttach(latex: latex)
        }
    }

    // MARK: Helpers

    /// Per-depth indent: 3pt bar + 10pt leading padding (matches miniClawChat blockquote padding)
    private static let quoteIndentPerLevel: CGFloat = 13
    private static let listIndentPerLevel: CGFloat = 24

    private func baseAttributes(quoteDepth: Int) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: theme.baseFont,
            .foregroundColor: quoteDepth>0 ? theme.secondaryLabelColor : theme.labelColor,
        ]
        if quoteDepth>0 {
            attrs[.blockquoteDepth] = quoteDepth
            let style = NSMutableParagraphStyle()
            let indent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.lineSpacing = bodyLineSpacing
            attrs[.paragraphStyle] = style
        }
        return attrs
    }

    // MARK: Math Attachments

    private func renderMathBlockAttach(latex: String) -> RenderedBlock {
        let key = "D:\(Int(theme.baseFontSize)):"+latex
        let attachment: MathAttachment
        if let cached = mathAttachmentCache[key] {
            attachment = cached
        } else {
            attachment = MathAttachment(latex: latex,isBlock: true,theme: theme)
            mathAttachmentCache[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        return RenderedBlock(attributed: result,topMargin: bodyLineSpacing,bottomMargin: bodyLineSpacing,isBlockAttachment: true)
    }

    private func renderInlineMathAttach(latex: String) -> NSAttributedString {
        let key = "I:\(Int(theme.baseFontSize)):"+latex
        let attachment: MathAttachment
        if let cached = mathAttachmentCache[key] {
            attachment = cached
        } else {
            attachment = MathAttachment(latex: latex,isBlock: false,theme: theme)
            mathAttachmentCache[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        return result
    }
}

// MARK: - UIFont+Traits

@MainActor
func renderMarkdownBlocks(_ blocks: [BlockNode]) -> NSAttributedString {
    let renderer = MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5))
    return renderer.render(blocks: blocks)
}

// MARK: - MarkdownNSRenderer

/// Converts `[BlockNode]` → `NSMutableAttributedString` for display in a UITextView.
extension NSAttributedString.Key {
    static let inlineCodeBackground = NSAttributedString.Key("miniClawInlineCodeBackground")
    static let inlineCodeText = NSAttributedString.Key("miniClawInlineCodeText")
    static let blockquoteDepth = NSAttributedString.Key("miniClawBlockquoteDepth")
}

// MARK: - Media Extension Sets

let attachLogger = AppLogger(category: "AttachDebug")

// MARK: - miniclaw:// URL encoding

/// Percent-encode the path of a `miniclaw://` destination that contains raw,
/// unencoded bytes (e.g. a filename with U+FF5C `｜`, CJK, emoji the LLM emitted
/// unencoded inside a miniclaw:// link), returning a parseable URL (or nil if it
/// still can't be formed). Used by both the link path (MarkdownTheme)
/// and the image path (ImageAttachment), so it lives at file scope.
func encodeRawMiniClawURL(_ destination: String) -> URL? {
    let prefix = "miniclaw://"
    guard destination.hasPrefix(prefix) else { return URL(string: destination) }
    let rest = String(destination.dropFirst(prefix.count))
    let encoded = rest.split(separator: "/", omittingEmptySubsequences: false)
        .map { percentEncodePathSegmentIdempotent(String($0)) }
        .joined(separator: "/")
    return URL(string: prefix+encoded)
}

/// Encode a single path segment idempotently: DECODE any existing percent escapes
/// first, then re-encode once. Normalizes mixed inputs (partly raw, partly
/// already-encoded, e.g. `cover%EF%BD%9C某某`) to a single clean encoding instead
/// of double-encoding the already-escaped bytes (`%EF…`→`%25EF…`). Fully-raw and
/// fully-encoded inputs both round-trip to the same result.
