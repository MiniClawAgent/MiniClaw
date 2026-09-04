import SwiftUI
import UIKit
import Photos
import Foundation
import Combine
struct MarkdownTheme {
    let baseFontSize: CGFloat
    let codeBlockCornerRadius: CGFloat = 8
    let inlineCodeCornerRadius: CGFloat = 5

    init(baseFontSize: CGFloat? = nil) {
        self.baseFontSize = baseFontSize ?? 16.5
    }

    var baseFont: UIFont { .systemFont(ofSize: baseFontSize) }
    var labelColor: UIColor { .label }
    var secondaryLabelColor: UIColor { .secondaryLabel }
    var accentColor: UIColor { .systemOrange }
    var linkColor: UIColor { .systemBlue }
    var codeBlockBackground: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15,alpha: 1) : .black }
    }
    var codeBlockTextColor: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.55,green: 0.95,blue: 0.55,alpha: 1) : .systemGreen }
    }
    var inlineCodeBackground: UIColor { miniClawInlineCodeBackgroundColor }
    var inlineCodeColor: UIColor { .systemOrange }
    var blockquoteBarColor: UIColor { UIColor.systemOrange.withAlphaComponent(0.5) }
    var tableBorderColor: UIColor { UIColor.label.withAlphaComponent(0.25) }

    func headingFont(level: Int) -> UIFont {
        let size: CGFloat
        let weight: UIFont.Weight
        switch level {
        case 1: size = baseFontSize*1.5; weight = .bold
        case 2: size = baseFontSize*1.3; weight = .bold
        case 3: size = baseFontSize*1.15; weight = .semibold
        case 5: size = baseFontSize*0.875; weight = .semibold
        case 6: size = baseFontSize*0.85; weight = .semibold
        default: size = baseFontSize; weight = .semibold // H4 and fallback
        }
        return .systemFont(ofSize: size,weight: weight)
    }

    var inlineCodeFont: UIFont {
        let size = baseFontSize*0.845
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor,size: size)
        }
        return .monospacedSystemFont(ofSize: size,weight: .regular)
    }

    var codeBlockFont: UIFont {
        let size = baseFontSize*0.85
        // Use Menlo as the base monospaced font, with PingFang SC as CJK fallback.
        // PingFang SC's CJK glyphs are exactly 2x the width of Menlo's ASCII glyphs
        // at the same point size, enabling proper table alignment in code blocks.
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor,size: size)
        }
        return .monospacedSystemFont(ofSize: size,weight: .regular)
    }
}

/// Renders markdown blocks into an NSAttributedString using a fresh MarkdownNSRenderer.
/// Intended for one-shot rendering of completed messages (e.g. caching in MessageListModel).
func percentEncodePathSegmentIdempotent(_ seg: String) -> String {
    let decoded = seg.removingPercentEncoding ?? seg
    return decoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seg
}

// MARK: - MarkdownTheme

/// [T-inline-code-dark-bg-ios] Inline-code span background, shared by the
/// theme and the layout manager's fillBackgroundRectArray (the actual paint
/// site) so the two can never drift. Light stays EXACTLY .systemGray6
/// (#F2F2F7); dark lifts to #3A3A3C (systemGray4's dark value) — systemGray6
/// resolves to #1C1C1E in dark, indistinguishable from the near-black chat
/// background, which made inline code read as bare orange text.
/// 文件指示器附件:带边框的胶囊 + SF 文档图标 + 文件名(超 10 字截断)。
/// 区别于工具/思考指示器,让用户一眼识别是文件(2026-08-13)。
// MARK: - SelectableMarkdownView (UIViewRepresentable)

/// SwiftUI wrapper for the UITextView-based selectable Markdown renderer.
struct MarkdownView: UIViewRepresentable {
    let markdown: String
    var cachedContent: MarkdownContent?
    var cachedAttributedString: NSAttributedString?
    /// Optional owning assistant message id. When set, inline image tap
    /// gestures route to a paged gallery of all markdown-embedded images in
    /// that message. Leave nil for standalone markdown rendering.
    var messageId: UUID?
    /// Optional block identity for table slot-cache keying. In the list
    /// cell-per-block, each AssistantBlock has its own UUID — using it as
    /// the slot key guarantees uniqueness even when two tables in the same
    /// message have identical content.
    var blockId: UUID?
    /// Called when the user taps a blank (non-link, non-code) area of the text view.
    /// The CGPoint is the tap location in **window coordinates**.
    var onTapBlank: ((CGPoint) -> Void)?
    /// Called when the user picks "Copy Screenshot" from the text selection menu.
    var onCopyScreenshot: (() -> Void)?
    /// [T-selection-menu-tts] "Read from Start" (whole reply) via MiniClaw TTS.
    var onReadAloud: (() -> Void)?
    /// [T-selection-menu-tts] "Read Selection" (selected text) via MiniClaw TTS.
    var onSpeakText: ((String) -> Void)?
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator()
        // [TableIdentityFix] When the same messageId remounts a fresh
        // Coordinator (cell reuse / SwiftUI body re-evaluation), hand the
        // new Coordinator the previously-cached renderer for that message.
        // Without this every cell reuse produces a fresh renderer →
        // fresh TableAttachment objects → layoutManager sees attachments
        // with no identity continuity and keeps the early-stream glyph
        // rects cached.
        if let mid = messageId,let existing = MarkdownView.rendererCache[mid] {
            coord.renderer = existing
        } else if let mid = messageId {
            MarkdownView.rendererCache[mid] = coord.renderer
        }
        return coord
    }

    /// [TableIdentityFix] Per-message renderer cache: keyed by `messageId`,
    /// kept across Coordinator recreations so TableAttachment identity (and
    /// the streaming `update(...)` path) survives SwiftUI body re-evaluations
    /// / cell reuses that throw away the previous Coordinator. Without this
    /// we observed up to 6 distinct Coordinators (each with its own renderer
    /// + fresh attachments) inside a single streaming response — every
    /// throwaway one writing new attachments into textStorage and leaving
    /// the layout manager with stale glyph rects for the early small-table
    /// state. The cache uses a regular dictionary because the keys are
    /// stable across the chat session and entries are cheap; in practice
    /// it grows at the rate of unique assistant messages in the live chat.
    @MainActor private static var rendererCache: [UUID: MarkdownNSRenderer] = [:]

    func makeUIView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.setContentHuggingPriority(.required,for: .vertical)
        textView.setContentCompressionResistancePriority(.required,for: .vertical)
        context.coordinator.lastMarkdown = ""
        context.coordinator.openURL = openURL
        textView.onTapBlank = onTapBlank
        textView.onCopyScreenshot = onCopyScreenshot
        textView.onReadAloud = onReadAloud
        textView.onSpeakText = onSpeakText
        #if DEBUG
        // [T-ios-markdown-rerender-burst] makeUIView creates a FRESH textView +
        // resets lastMarkdown="", forcing the next updateUIView through a full
        // re-render (the markdown != lastMarkdown dedup can never hit on a brand
        // new view). Log rnd (coordinator's renderer id) so we can count
        // makeUIView churn against the [RND] burst — same rnd across many
        // [MK-VIEW] => SwiftUI is re-creating the view for a reused coordinator.
        let rId = String(ObjectIdentifier(context.coordinator.renderer).hashValue&0xFFFFFF,radix: 16)
        AppLogger(category: "MarkdownRenderer").info("[MK-VIEW] new textView rnd=\(rId)")
        #endif
        return textView
    }

    func updateUIView(_ textView: MarkdownTextView,context: Context) {
        let updateStart = CFAbsoluteTimeGetCurrent()
        context.coordinator.openURL = openURL
        textView.onTapBlank = onTapBlank
        textView.onCopyScreenshot = onCopyScreenshot
        textView.onReadAloud = onReadAloud
        textView.onSpeakText = onSpeakText

        let currentFontSize = FontSettings.shared.scaledMessage(16.5)
        let fontChanged = context.coordinator.lastFontSize != currentFontSize

        // [AttachHotPath] updateUIView entry — only log when this textView has
        // image attachments in its renderer's cache (the only scenario that can
        // trigger the streaming + image re-layout problem). Skips noise from
        // pure-text blocks.
        let imgCacheN = context.coordinator.renderer.imageAttachmentCache.count
        if imgCacheN>0 {
            let prevLen = context.coordinator.lastMarkdown.count
            let curLen = markdown.count
            let isAppend = curLen>prevLen && markdown.hasPrefix(context.coordinator.lastMarkdown)
            AppLogger(category: "AttachHotPath").info("[UPD] entry imgCache=\(imgCacheN) prevLen=\(prevLen) curLen=\(curLen) Δ\(curLen - prevLen) appendOnly=\(isAppend ? 1 : 0) fontChanged=\(fontChanged ? 1 : 0)")
        }

        // [RotationTableFix] Detect (markdown unchanged + width changed) — the
        // rotation path. SwiftUI calls updateUIView with the textView already
        // at the new textContainer width, but `markdown` is unchanged so the
        // guard below early-returns. Without this branch the TableAttachment
        // cachedLayout never invalidates and the rendered table sticks at the
        // old portrait column widths. We invalidate just the attachment caches
        // (not a full re-render) so the next layout pass asks for fresh
        // `attachmentBounds` at the new width and makeView rebuilds the
        // SelectableTableView with the new columns.
        let _curW = textView.textContainer.size.width
        let _prevW = context.coordinator.lastRenderedWidth
        let _widthChanged = _curW>1 && _prevW>1 && abs(_curW-_prevW)>0.5
        if _widthChanged && markdown == context.coordinator.lastMarkdown && !fontChanged {
            // [WordFade] Width change (rotation) re-lays-out everything; snap
            // any mid-fade words to full opacity so none stick translucent.
            context.coordinator.fadeAnimator.cancelAll()
            let storage = textView.textStorage
        if storage.length>0 {
                var ranges: [NSRange] = []
                storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { value,range,_ in
                    if let table = value as? TableAttachment {
                        table.invalidateCachedLayoutForWidthChange()
                        ranges.append(range)
                    }
                }
                if !ranges.isEmpty,let lm = textView.layoutManager as? MiniClawLayoutManager {
                    for r in ranges {
                        lm.invalidateLayout(forCharacterRange: r,actualCharacterRange: nil)
                    }
                }
            }
            context.coordinator.cachedSizes.removeAll(keepingCapacity: true)
            textView.refreshAttachViews()
            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()
            textView.invalidateCellSizeIfChanged()
        }
        if _curW>1 {
            context.coordinator.lastRenderedWidth = _curW
        }
        guard markdown != context.coordinator.lastMarkdown || fontChanged else {
            let shouldRecover = textView.window != nil
                && textView.needsAttachmentRecovery
                && !textView.hasScheduledRecoveryForCurrentContent

            if shouldRecover {
                textView.hasScheduledRecoveryForCurrentContent = true
                DispatchQueue.main.async { [weak textView] in
                    guard let textView,textView.window != nil else { return }
                    textView.refreshAttachViews()
                    textView.invalidateIntrinsicContentSize()
                    textView.setNeedsDisplay()
                    textView.setNeedsLayout()
                }
            }
            // [DIAG-RENDER-1] markdown matches lastMarkdown — no re-render.
            // If the cell appears empty, it means the PREVIOUS updateUIView call
            // set lastMarkdown but didn't actually render the text (e.g. was skipped
            // due to background state, or attributedText was empty/truncated).
            if !markdown.isEmpty && (textView.attributedText?.length ?? 0) == 0 {
                AppLogger(category: "StreamDiag").info("[RENDER] ⚠️ EMPTY-DESPITE-MATCH markdown len=\(markdown.count) lastMarkdown len=\(context.coordinator.lastMarkdown.count) attrText len=\(textView.attributedText?.length ?? 0) window=\(textView.window != nil) — CELL APPEARS EMPTY")
            }
            return
        }

        // [DIAG-RENDER-2] Three paths based on application state:
        //   .background                   → defer (always; final streaming
        //                                   frame would otherwise be blank
        //                                   until SwiftUI re-evaluates)
        //   .inactive ≥ 30s               → defer (long-running .inactive is
        //                                   indistinguishable from background
        //                                   for watchdog purposes — commit
        //                                   e6efac23 fixed crashes here)
        //   .inactive < 30s               → render normally (control center
        //                                   swipe, incoming call banner,
        //                                   app-switcher peek — short enough
        //                                   that the scene-transition
        //                                   watchdog window has settled)
        //   .active                       → render normally (falls through)
        //
        // Deferred frames are stashed on the coordinator and replayed by the
        // didBecomeActive observer once applicationState is genuinely
        // `.active` again, so the expensive setAttributedText + ensureLayout
        // pass never runs while the watchdog is timing.
        let appState = UIApplication.shared.applicationState
        let inactiveDuration: TimeInterval = appState == .inactive
            ? (context.coordinator.inactiveEnteredAt.map { Date().timeIntervalSince($0) } ?? 0)
            : 0
        let shouldDefer: Bool = {
            switch appState {
            case .background: return true
            case .inactive: return inactiveDuration >= 30.0
            default: return false
            }
        }()
        if shouldDefer {
            context.coordinator.deferRender(markdown) { [weak textView] in
                guard let textView else { return }
                // Defeat the content-hash skip so the deferred frame actually
                // re-renders even if an intervening pass set the same hash.
                context.coordinator.lastRenderedContentHash = nil
                self.updateUIView(textView,context: context)
            }
            return
        }
        let oldMarkdown = context.coordinator.lastMarkdown
        context.coordinator.lastMarkdown = markdown

        if fontChanged {
            context.coordinator.renderer.applyFontSizeChange(currentFontSize)
            context.coordinator.lastFontSize = currentFontSize
            context.coordinator.lastRenderedContentHash = nil
            // Math images are rendered at a specific font size — clear stale caches.
            context.coordinator.renderer.mathAttachmentCache.removeAll()
            textView.clearAllAttachViews()
        }

        let isNewMessage = !oldMarkdown.isEmpty && !markdown.hasPrefix(oldMarkdown)
        if isNewMessage {
            // [WordFade] The storage is about to be rebuilt from scratch; any
            // in-flight fade ranges are stale. Drop them before the rewrite.
            context.coordinator.fadeAnimator.cancelAll()
            // [AttachHotPath] If this fires DURING streaming (i.e. between
            // tokens of the same message), it means markdown.hasPrefix(oldMarkdown)
            // returned false despite being the same message — every
            // ImageAttachment is destroyed and recreated on the next render,
            // ObjectIdentifier changes, and refreshAttachViews rebuilds
            // every UIImageView. This is the smoking gun if it appears in
            // the streaming log stream.
            let imgN = context.coordinator.renderer.imageAttachmentCache.count
            let vidN = context.coordinator.renderer.videoAttachmentCache.count
            let audN = context.coordinator.renderer.audioAttachmentCache.count
            let codeN = context.coordinator.renderer.codeBlockAttachmentCache.count
            let tailOld = String(oldMarkdown.suffix(40)).replacingOccurrences(of: "\n", with: "⏎")
            let headNew = String(markdown.prefix(40)).replacingOccurrences(of: "\n", with: "⏎")
            AppLogger(category: "AttachHotPath").info("[CACHE-WIPE] isNewMessage=true — clearing img=\(imgN) vid=\(vidN) aud=\(audN) code=\(codeN) oldLen=\(oldMarkdown.count) newLen=\(markdown.count) oldTail=\"\(tailOld)\" newHead=\"\(headNew)\"")
            let renderer = context.coordinator.renderer
            renderer.imageAttachmentCache.removeAll()
            renderer.videoAttachmentCache.removeAll()
            renderer.audioAttachmentCache.removeAll()
            renderer.codeBlockAttachmentCache.removeAll()
            renderer.codeBlockContentHashes.removeAll()
            // HangFix(2026-05-14) — DO NOT wipe tableAttachmentCache /
            // tableAttachmentLRU. They are keyed by contentHash with a
            // 64-entry LRU bound; identical tables across messages
            // legitimately share the same TableAttachment instance (and
            // its precomputed `cachedLayout`), which is the only thing
            // that prevents a 6-table cell from costing seconds inside
            // `attachmentBounds` on every typesetter pass.
            renderer.mathAttachmentCache.removeAll()
            textView.clearAllAttachViews()
        }

        let prepStart = CFAbsoluteTimeGetCurrent()
        // REPRO-FIX(2026-05-16): split off in-flight table tail before
        // markdown parsing. The plain suffix is appended below after
        // markdown rendering completes; it bypasses cmark entirely so no
        // inline syntax (`*`, `**`, `` ` ``, `_`) inside the partial
        // table cells is parsed during streaming.
        //
        // Don't split once the message has finished streaming — the
        // presence of either a prebuilt `cachedAttributedString` or a
        // prebuilt `cachedContent` is the finalised-message signal sent
        // by `MessageListModel.cacheAttributedString(for:)`. After that
        // point cmark must see the full markdown so a trailing
        // un-terminated `|...|` final row (no trailing `\n`) is still
        // rendered as a real table row.
        let _isFinalised = cachedAttributedString != nil || cachedContent != nil
        let _splitForUpdate = _isFinalised ? (prefix: markdown, plainSuffix: "") : splitStreamingTableTail(markdown)
        let _hasPlainSuffix = !_splitForUpdate.plainSuffix.isEmpty
        let prepared = prepareMarkdownForRender(_splitForUpdate.prefix)
        // If we split off a suffix, the prebuilt cache (which was rendered
        // from the full markdown) no longer matches what we'll render —
        // force a fresh MarkdownContent parse and skip cachedContent.
        let content = (_hasPlainSuffix ? nil : cachedContent) ?? MarkdownContent(prepared)
        let prepElapsed = (CFAbsoluteTimeGetCurrent()-prepStart)*1000
        // Image-related diagnostics — only walk the parsed block tree when
        // the raw markdown actually contains image syntax. The block walk
        // is O(N) over every node in every block, which on long messages
        // becomes a measurable chunk of every updateUIView pass (and
        // updateUIView runs on each SwiftUI body re-evaluation, so it
        // multiplies during streaming and self-sizing measurement loops).
        let imageMatches = markdown.ranges(of: /!\[([^\]]*)\]\(([^)]+)\)/)
        if !imageMatches.isEmpty {
            for match in imageMatches {
                let matchStr = String(markdown[match])
                imgLogger.info("[MiniClawImage][StreamParse] image markdown found: \(matchStr)")
            }
            let imageBlockCount = content.blocks.flatMap { Self.collectImageNodes(from: $0) }.count
            if imageBlockCount>0 {
                imgLogger.info("[MiniClawImage][StreamParse] parsed \(imageBlockCount) image node(s) from \(content.blocks.count) block(s), markdownLen=\(markdown.count)")
            }
        }

        var hasher = Hasher()
        hasher.combine(cachedContent != nil ? cachedContent!.blocks.hashValue : markdown.hashValue)
        hasher.combine(FontSettings.shared.scaledMessage(16.5))
        let contentHash: Int = hasher.finalize()
        if contentHash == context.coordinator.lastRenderedContentHash {
            // [DIAG-RENDER-3] Content hash matches — skip re-render.
            // If text was already set correctly, this is fine. But if
            // attributedText is empty despite matching hash, we have a bug.
            if !markdown.isEmpty && (textView.attributedText?.length ?? 0) == 0 {
                AppLogger(category: "StreamDiag").info("[RENDER] ⚠️ HASH-MATCH-BUT-EMPTY markdown len=\(markdown.count) hash=\(contentHash) attrText len=0 — SKIPPING RENDER OF NON-EMPTY CONTENT")
            }
            if textView.textContainer.size.width>1 {
                textView.refreshAttachViews()
            }
            return
        }
        #if DEBUG
        // [T-ios-markdown-rerender-burst] Hash MISS — log why so we can tell if
        // the content hash is genuinely changing each updateUIView (unstable
        // hash input) vs lastRenderedContentHash being reset between calls.
        // Gated to non-streaming messages with prebuilt cache so it only fires
        // on the scroll-rerender case, not live streaming.
        if cachedContent != nil || cachedAttributedString != nil {
            let prev = context.coordinator.lastRenderedContentHash
            let usingBlocks = cachedContent != nil
            AppLogger(category: "MarkdownRenderer").info("[RND-MISS] hash=\(contentHash) prev=\(prev.map(String.init) ?? "nil") src=\(usingBlocks ? "blocks" : "markdown") hasPlainSuffix=\(_hasPlainSuffix) fontChanged=\(fontChanged) mdLen=\(markdown.count)")
        }
        #endif
        context.coordinator.lastRenderedContentHash = contentHash

        let renderStart = CFAbsoluteTimeGetCurrent()
        let renderer = context.coordinator.renderer
        let attributed: NSAttributedString
        let usedCache: Bool
        // [TablePathFix] When the prebuilt attributed string contains a
        // TableAttachment we must NOT use it — the cached path comes from
        // `MessageListModel.cacheAttributedString(for:)` which uses a fresh
        // `MarkdownNSRenderer` each call and therefore creates a *new*
        // TableAttachment object every flush. During streaming this
        // detaches the live attachments from the coordinator's
        // `tableAttachmentCache` (which is what `update()` mutates with
        // proper `contentGeneration` bumps and `cachedLayout = nil` resets).
        // The visible symptom is the "table rendered as a single column"
        // / "stale layout cached for old probe width" case logged via
        // [TableDiag]. Falling through to `coord.renderer.render` preserves
        // TableAttachment object identity across renders, so `update()`
        // works as intended and the layout manager sees the correct bounds.
        let prebuiltHasTable: Bool = {
            guard let prebuilt = cachedAttributedString,prebuilt.length>0 else { return false }
            var found = false
            prebuilt.enumerateAttribute(.attachment,in: NSRange(location: 0,length: prebuilt.length),options: []) { value,_,stop in
                if value is TableAttachment {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }()
        // REPRO-FIX(2026-05-16): when we split off an in-flight plain
        // suffix above, the prebuilt cache covers the wrong content —
        // bypass it and re-render so the appended suffix lives in the
        // current view's storage (the prebuilt was for the full markdown).
        if let prebuilt = cachedAttributedString,!fontChanged,!prebuiltHasTable,!_hasPlainSuffix {
            attributed = prebuilt
            usedCache = true
        } else {
            renderer.messageId = messageId
            renderer.blockId = blockId
            let renderedBody = autoreleasepool {
                renderer.render(blocks: content.blocks)
            }
            if _hasPlainSuffix {
                let mut = NSMutableAttributedString(attributedString: renderedBody)
                let suffixAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: FontSettings.shared.scaledMessage(16.5)),
                    .foregroundColor: UIColor.label,
                ]
                mut.append(NSAttributedString(string: _splitForUpdate.plainSuffix,attributes: suffixAttrs))
                attributed = mut
            } else {
                attributed = renderedBody
            }
            usedCache = false
        }
        // Walk every inline image attachment so we can:
        //   1. patch `messageId` (the cached path via renderMarkdownBlocks
        //      creates attachments without one)
        //   2. invalidate any stale bitmap if the underlying file was
        //      rewritten since the attachment last loaded (size+mtime
        //      fingerprint mismatch). Skips the on-disk stat for
        //      non-miniclaw schemes.
        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0,length: attributed.length),
                                      options: []) { value,_,_ in
            guard let att = value as? ImageAttachment else { return }
            if let messageId { att.messageId = messageId }
            if let loadedFp = att.loadedFingerprint {
                let currentFp = miniClawMediaCacheKey(for: att.source)
                if loadedFp != currentFp {
                    imgLogger.info("[MiniClawImage][CachedAttr] FINGERPRINT CHANGED src=\(att.source) old=\(loadedFp) new=\(currentFp) — invalidating cached image")
                    att.invalidateLoadedImage()
                }
            }
        }
        let renderElapsed = (CFAbsoluteTimeGetCurrent()-renderStart)*1000

        let assignStart = CFAbsoluteTimeGetCurrent()
        // [AttachHotPath] Append-only fast path: when the new attributed string
        // is a strict extension of what's already in textStorage, only replace
        // the tail. The prefix's glyphs / line fragments / attachment bounds
        // stay laid out — TextKit doesn't re-call attachmentBounds for the
        // image attachments in the prefix, which was the per-token hot path
        // (see `[IMG][BOUNDS]` log series climbing into the hundreds during
        // streaming).
        // [WordFade] Compute the freshly-revealed character range BEFORE we
        // mutate storage, using a pure STRING-prefix diff — exactly how
        // Microsoft's SwiftStreamingMarkdown keys its per-word fade
        // (`newContentLength = attr.length - oldLength`). This is deliberately
        // decoupled from the append fast path below: the fade must fire whether
        // or not the attributed-string fast path is taken, and the renderer's
        // attribute churn (CJK NSFont fallback, NSOriginalFont, fresh paragraph
        // styles) must NOT gate it. We only require the OLD text to be a literal
        // prefix of the NEW text — true for every streamed token. [T-ios-word-fade-animation]
        var fadeRevealRange: NSRange? = nil
        let oldStorage = textView.textStorage
        if oldStorage.length>0,
           attributed.length>oldStorage.length {
            let oldLen = oldStorage.length
            let oldStr = oldStorage.string as NSString
            let newStr = attributed.string as NSString
            if newStr.length >= oldLen,
               newStr.substring(to: oldLen) == (oldStr as String) {
                fadeRevealRange = NSRange(location: oldLen,length: attributed.length-oldLen)
            }
        }

        var fastPathTaken = false
        var newAttachInTail = 0
        let prevStorage = textView.textStorage
        if prevStorage.length>0,
           attributed.length>prevStorage.length {
            let prefixLen = prevStorage.length
            let newPrefix = attributed.attributedSubstring(from: NSRange(location: 0,length: prefixLen))
            // isEqual on NSAttributedString compares both string AND attribute
            // dictionaries (including attachment object identity). Since the
            // renderer reuses ImageAttachment objects via imageAttachmentCache,
            // a token-only append produces an identical prefix here. Ignore the
            // TextKit-injected NSOriginalFont / substituted NSFont so CJK
            // streams (whose laid-out prefix differs only by font fallback)
            // still take the fast path instead of a full re-render.
            let _oldPrefix = prevStorage.attributedSubstring(from: NSRange(location: 0,length: prefixLen))
            if Self.prefixesEqualIgnoringFontSubstitution(newPrefix,_oldPrefix) {
                let tailRange = NSRange(location: prefixLen,length: 0)
                let tail = attributed.attributedSubstring(from: NSRange(location: prefixLen,length: attributed.length-prefixLen))
                tail.enumerateAttribute(.attachment,in: NSRange(location: 0,length: tail.length),options: []) { v,_,_ in
                    if v != nil { newAttachInTail += 1 }
                }
                prevStorage.beginEditing()
                prevStorage.replaceCharacters(in: tailRange,with: tail)
                prevStorage.endEditing()
                fastPathTaken = true
            }
        }
        if !fastPathTaken {
            textView.attributedText = attributed
        }

        // [WordFade] Now that storage holds the final text (via either path),
        // fade the revealed range in word-by-word. Decoupled from fastPathTaken
        // so a full-replace token still animates. A scene-deferred / background
        // frame never reaches here; isNewMessage / rotation already cancelAll'd.
        if let revealRange = fadeRevealRange {
            context.coordinator.fadeTextView = textView
            context.coordinator.fadeAnimator.scheduleAnimation(for: revealRange,in: textView.textStorage)
        }
        let assignElapsed = (CFAbsoluteTimeGetCurrent()-assignStart)*1000
        textView.rawMarkdown = markdown
        textView.resetAttachmentRecovery()
        // [HangRepro] Record the full markdown just assigned to this
        // textView so a subsequent main-thread hang (caught by
        // HangDetector) can dump the actual input that triggered the
        // typesetter feedback loop. Bounded ring of last 10 entries.
        StreamingHangLogger.shared.recordAssignedText(
            messageId: messageId,
            markdown: markdown,
            attrLen: attributed.length,
            path: fastPathTaken ? "fast-append" : "full-assign"
        )

        // Walk attachments that mutated their content in place (currently
        // TableAttachment via `update(...)`) and invalidate JUST those
        // character ranges in the layout manager. With identity-stable
        // attachments TextKit otherwise keeps the cached attachment-bounds
        // (and therefore the wrong rendered height) for the table.
        let storage = textView.textStorage
        let storageLen = storage.length
        if storageLen>0 {
            storage.enumerateAttribute(.attachment,
                                       in: NSRange(location: 0,length: storageLen),
                                       options: []) { value,range,_ in
                if let table = value as? TableAttachment,table.needsLayoutInvalidation {
                    textView.layoutManager.invalidateLayout(forCharacterRange: range,actualCharacterRange: nil)
                    table.needsLayoutInvalidation = false
                }
            }
        }

        let layoutStart = CFAbsoluteTimeGetCurrent()
        var ensureLayoutMs: Double = 0
        if fastPathTaken {
            // Prefix is already laid out. Don't ensureLayout the whole range —
            // TextKit will lay out the appended tail on demand. setNeedsLayout
            // is enough so the text view re-draws and re-measures intrinsic size.
            textView.setNeedsLayout()
        } else if (cachedContent != nil || cachedAttributedString != nil) && textView.textContainer.size.width>1 {
            // Bounded slow-path layout: only ensure the visible glyph range
            // plus a small overscan. Replacing the full-range ensureLayout
            // here was the second prong of the NSTypesetter watchdog fix —
            // even when the fast path is missed (e.g. a new attachment
            // appeared in the prefix), we no longer pay O(N) layout cost
            // synchronously on the main thread for the entire message.
            let tEnsure = CFAbsoluteTimeGetCurrent()
            let containerSize = textView.textContainer.size
            let visibleRect: CGRect
            if textView.bounds.width>1,textView.bounds.height>1 {
                visibleRect = CGRect(x: 0,y: 0,width: containerSize.width,height: textView.bounds.height+800)
            } else {
                visibleRect = CGRect(x: 0,y: 0,width: containerSize.width,height: 1200)
            }
            let visibleGlyphRange = textView.layoutManager.glyphRange(forBoundingRect: visibleRect,
                                                                     in: textView.textContainer)
            if visibleGlyphRange.length>0 {
                textView.layoutManager.ensureLayout(forGlyphRange: visibleGlyphRange)
            } else {
                textView.setNeedsLayout()
            }
            ensureLayoutMs = (CFAbsoluteTimeGetCurrent()-tEnsure)*1000
        } else {
            textView.setNeedsLayout()
        }
        textView.invalidateIntrinsicContentSize()
        textView.setNeedsDisplay()
        textView.invalidateCellSizeIfChanged()
        let layoutElapsed = (CFAbsoluteTimeGetCurrent()-layoutStart)*1000
        // [WATCHDOG-DIAG] Log when updateUIView's ensureLayout runs long — this
        // is the other hot site that can burn main-thread wall-clock time.
        if ensureLayoutMs >= 50 || attributed.length >= 10_000 {
        }

        let attachStart = CFAbsoluteTimeGetCurrent()
        // When fast path was taken AND no new attachment was introduced in the
        // appended tail, existing attachment views' character indices are
        // unchanged, their boundingRects are stable, and we can skip the full
        // refreshAttachViews enumeration. If a new attachment did appear
        // (rare during text streaming after an image), fall through to refresh.
        let skipAttachUpdate = fastPathTaken && newAttachInTail == 0
        if skipAttachUpdate {
            // No-op. Existing attachment views remain correctly placed.
        } else if textView.textContainer.size.width>1 {
            textView.refreshAttachViews()
        } else {
            DispatchQueue.main.async { [weak textView] in
                guard let textView,textView.window != nil else { return }
                textView.refreshAttachViews()
                textView.invalidateIntrinsicContentSize()
                textView.setNeedsDisplay()
                textView.setNeedsLayout()
                textView.invalidateCellSizeIfChanged()
            }
        }
        _ = (CFAbsoluteTimeGetCurrent()-attachStart)*1000
        let updateElapsed = (CFAbsoluteTimeGetCurrent()-updateStart)*1000

        // [WatchdogProbe] watchdog crash repro lead — the iOS 26 hang stack
        // shows _performTextKit1LayoutCalculation re-running per cell on
        // collection-view bounds change. Emit when a single updateUIView
        // takes >300ms; chain of these in one main-runloop iteration is the
        // direct cause of a 0x8BADF00D termination.
        #if DEBUG
        let msgIdShort = messageId?.uuidString.prefix(8) ?? "—"
        if updateElapsed >= 300 {
            Self.watchdogProbe.warning("[WatchdogProbe][upd] slow updateUIView elapsed=\(String(format: "%.1f", updateElapsed))ms attrLen=\(textView.attributedText?.length ?? 0) markdownLen=\(markdown.count) msgId=\(msgIdShort)")
        }
        Self.recordUpdateUIView(elapsedMs: updateElapsed,attrLen: textView.attributedText?.length ?? 0,msgId: messageId)
        #endif

        // Keep textContainer height unconstrained so subsequent boundingRect
        // queries return correct positions for attachments near the end.
        // Only assign when it's actually clamped — see layoutSubviews.
        if textView.textContainer.size.height<CGFloat.greatestFiniteMagnitude {
            textView.textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        #if DEBUG
        // [T-attachment-zero-origin] Snapshot at end of updateUIView (live uiView).
        MarkdownSnapshotCollector.captureIfEnabled(
            textView: textView,
            phase: "afterUpdateUIView",
            messageId: context.coordinator.renderer.messageId?.uuidString,
            isMeasureView: false
        )
        #endif
    }

    /// Key TextKit injects on laid-out storage to remember the pre-fallback
    /// font (CJK / emoji substitution). It never appears on a freshly-rendered
    /// attributed string, so a literal `isEqual` between the renderer's output
    /// and the already-laid-out storage always differs by exactly this key.
    private static let nsOriginalFontKey = NSAttributedString.Key("NSOriginalFont")

    /// True when `newPrefix` (renderer output) and `oldPrefix` (already
    /// laid-out storage) are equal once TextKit's font-substitution bookkeeping
    /// is normalized away. When TextKit lays out CJK / emoji, it swaps `NSFont`
    /// to a fallback face and stashes the pre-fallback font under
    /// `NSOriginalFont`. The renderer's fresh string has neither — just the
    /// original `NSFont`. A literal `isEqual` therefore fails on every token,
    /// silently disabling the append fast path (and the word-fade) for CJK.
    ///
    /// We accept the run as equal when, after dropping `NSOriginalFont` and
    /// `NSFont` from both sides, all OTHER attributes (color, paragraph style,
    /// attachment identity, …) match exactly AND the fonts are reconcilable:
    /// either the raw `NSFont`s are equal, or the new side's `NSFont` equals the
    /// old side's `NSOriginalFont` (i.e. old is just `new` after fallback).
    /// A genuine font/size change still breaks the match. [T-ios-word-fade-animation]
    private static func prefixesEqualIgnoringFontSubstitution(
        _ newPrefix: NSAttributedString,
        _ oldPrefix: NSAttributedString
    ) -> Bool {
        guard newPrefix.length == oldPrefix.length else { return false }
        guard (newPrefix.string as NSString).isEqual(oldPrefix.string) else { return false }
        let fontKey = NSAttributedString.Key.font
        let full = NSRange(location: 0,length: newPrefix.length)
        var equal = true
        newPrefix.enumerateAttributes(in: full,options: []) { aN,range,stop in
            let aO = oldPrefix.attributes(at: range.location,effectiveRange: nil)
            // Reconcile fonts: equal as-is, or new.NSFont == old.NSOriginalFont.
            let fontN = aN[fontKey] as? UIFont
            let fontO = aO[fontKey] as? UIFont
            let originalO = aO[nsOriginalFontKey] as? UIFont
            let fontsOK = (fontN == fontO) || (fontN != nil && fontN == originalO)
            if !fontsOK { equal = false; stop.pointee = true; return }
            // Compare everything else with font bookkeeping removed.
            var nN = aN; nN.removeValue(forKey: fontKey); nN.removeValue(forKey: nsOriginalFontKey)
            var nO = aO; nO.removeValue(forKey: fontKey); nO.removeValue(forKey: nsOriginalFontKey)
            if !(nN as NSDictionary).isEqual(to: nO) {
                equal = false
                stop.pointee = true
            }
        }
        return equal
    }

    /// Recursively collect `.image` inline nodes from a block tree for logging.
    private static func collectImageNodes(from block: BlockNode) -> [String] {
        var results: [String] = []
        func walkInlineNodes(_ inlines: [InlineNode]) {
            for inline in inlines {
                switch inline {
                case .image(let src,_):
                    results.append(src)
                case .emphasis(let ch),.strong(let ch),.strikethrough(let ch),.link(_,let ch):
                    walkInlineNodes(ch)
                default: break
                }
            }
        }
        func walkBlockNodes(_ blocks: [BlockNode]) {
            for b in blocks {
                switch b {
                case .paragraph(let inlines),.heading(_,let inlines):
                    walkInlineNodes(inlines)
                case .blockquote(let children):
                    walkBlockNodes(children)
                case .bulletedList(_,let items):
                    for item in items { walkBlockNodes(item.children) }
                case .numberedList(_,_,let items):
                    for item in items { walkBlockNodes(item.children) }
                case .taskList(_,let items):
                    for item in items { walkBlockNodes(item.children) }
                default: break
                }
            }
        }
        walkBlockNodes([block])
        return results
    }

    /// [T-ios-longreply-boundingRect-watchdog] Measure attributed-string height with
    /// bare CoreText `CTFramesetter` instead of `NSAttributedString.boundingRect`
    /// (which wraps TextKit1 / `NSLayoutManager` and has near-O(n²) cost in line
    /// count — 100 lines ≈ 1.7s, 1000 lines ≈ 17.7s, the 8.7–10.8s SLOW MEASUREs
    /// behind the 0x8BADF00D watchdog kills). `CTFramesetter` uses the same CoreText
    /// typesetter foundation with no TextKit wrapper: 100 lines ≈ 24ms (71×), 1000
    /// lines ≈ 24ms (738×), and it barely grows with line count.
    ///
    /// Only valid for **attachment-free** text — `CTFramesetter` cannot see the
    /// custom `attachmentBounds` of TableAttachment/CodeBlockAttachment/ImageAttachment
    /// (those need TextKit to invoke the line-fragment typesetter), so callers MUST
    /// gate on "no attachments" before using this. Returns the text height only;
    /// callers add `textContainerInset` (top+bottom) to match `UITextView.sizeThatFits`.
    static func ctFramesetterHeight(for attrStr: NSAttributedString,width: CGFloat) -> CGFloat {
        guard attrStr.length>0,width>0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let constraint = CGSize(width: width,height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0,length: 0),// 0 length = whole string
            nil,
            constraint,
            nil
        )
        return ceil(size.height)
    }

    @available(iOS 16.0,*)
    func sizeThatFits(_ proposal: ProposedViewSize,uiView: MarkdownTextView,context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        // Key the size cache on the SwiftUI binding length, not
        // uiView.textStorage.length. Within a single render pass SwiftUI calls
        // sizeThatFits BEFORE updateUIView, so textStorage still reflects the
        // previous commit. Streaming providers that push tokens in bursts with
        // pauses (DeepSeek V4 especially) would otherwise hit cached heights
        // keyed on the stale length, locking the cell at the old size and
        // clipping the newly arrived characters until the cell was recycled.
        let bindingLen = (markdown as NSString).length
        let storageLen = uiView.textStorage.length

        let coord = context.coordinator
        coord.sizeThatFitsCallCount &+= 1
        let callIdx = coord.sizeThatFitsCallCount
        let t0 = CFAbsoluteTimeGetCurrent()

        // Cache key includes the width bucket (1pt precision) AND the binding
        // length. Multi-width cache survives SwiftUI's recursive sizeThatFits
        // probing where the same view is measured at 2–3 nearby widths during
        // a single preferredLayoutAttributesFitting pass.
        let widthKey = Int(width.rounded())
        if bindingLen == coord.cachedSizeMarkdownCount,
           let cachedHeight = coord.cachedSizes[widthKey] {
            coord.sizeThatFitsCacheHitCount &+= 1
            if callIdx%50 == 0 {
            }
            return CGSize(width: width,height: cachedHeight)
        }

        // [T-ios-markdown-table-double-render] Near-width cache hit for FULLY
        // COMMITTED (non-streaming) content. During a deceleration glide UIKit
        // probes a cell's sizeThatFits several times at WIDTHS that differ by
        // 1–2pt of rounding (preferredLayoutAttributesFitting passes), so the
        // exact-`widthKey` hit above misses each time and we fall through to the
        // off-screen measure path — which renders the markdown again (the [RND]
        // burst). For a message whose binding is fully laid into storage
        // (`bindingLen == storageLen`, i.e. NOT mid-stream), a height measured
        // 1–2pt away is correct to the pixel for our purposes; reuse it and skip
        // the re-render entirely. This was the table-message "rendered 6×/decel"
        // cost (measure renderer ×3 + display renderer ×3). Gated to non-streaming so token growth
        // (bindingLen != storageLen) is unaffected, and to a tight ±2pt window so
        // a genuine width change (rotation / sidebar) still re-measures. No new
        // measurement happens — we return a height the SAME content already
        // produced — so this cannot reintroduce the historical
        // sizeThatFits→fillLayoutHole typesetter loop.
        if bindingLen == coord.cachedSizeMarkdownCount,
           bindingLen == storageLen,
           !coord.cachedSizes.isEmpty {
            var nearestHeight: CGFloat?
            var nearestDelta = Int.max
            for (bucket,h) in coord.cachedSizes {
                let delta = abs(bucket-widthKey)
                if delta <= 2,delta<nearestDelta {
                    nearestDelta = delta
                    nearestHeight = h
                }
            }
            if let nearestHeight {
                coord.sizeThatFitsCacheHitCount &+= 1
                // Memoize at the exact requested width so the next identical
                // probe takes the exact-hit fast path above (and a flapping
                // width sequence still respects the 4-bucket cap below).
                coord.cachedSizes[widthKey] = nearestHeight
                if coord.cachedSizes.count>4,let firstKey = coord.cachedSizes.keys.first {
                    coord.cachedSizes.removeValue(forKey: firstKey)
                }
                return CGSize(width: width,height: nearestHeight)
            }
        }

        // HangFix(2026-05-14) — streaming-aware approximate cache hit.
        // If we have a recent full-measurement anchor at this width, and the
        // binding has only grown by a small amount (typical streaming
        // delta), extrapolate the new height linearly to avoid an expensive
        // off-screen measurement. This avoids the 0x8BADF00D watchdog
        // crash on iPhone 17 Pro Max where every token chunk used to spawn
        // a 50-200ms typesetter pass.
        //
        // Strict guards to avoid runaway estimates (the very-tall-table
        // bug seen 2026-05-14 20:21: prevLen=2 prevH=14 → 7pt/char → 200
        // chars later 1547pt) — the anchor must be substantial enough to
        // give a meaningful per-char rate, the delta must be modest, the
        // estimate is bounded by an absolute cap, and the estimate is NOT
        // written back to cachedSizes so a later sizeThatFits at the same
        // length doesn't reuse it.
        let useMeasureTextView = bindingLen != storageLen
        // [T-ios-streaming-est-attachment-clip] STREAM-EST disabled again.
        // It was restored in de4d3df6 to kill visible-streaming hangs, but the
        // linear pxPerChar extrapolation under-measures cells that contain
        // fixed-height attachments (tool capsules, code/shell blocks, images):
        // those blocks don't grow with character count, so the estimate came
        // out too short and the NEXT cell overlapped the tail of a finished
        // message (user report, macOS, "MiniClaw Feedback Review" — the shell
        // preview + tool capsule covered the body text of the last message).
        // Gate it back off so every streaming sizeThatFits takes a real
        // measurement; the hang de4d3df6 fixed is the tradeoff to revisit with
        // an attachment-aware estimate rather than this whole-cell linear one.
        let disableStreamEst = true
        if !disableStreamEst,
           useMeasureTextView,
           let prevHeight = coord.lastFullMeasureHeight[widthKey],
           coord.lastFullMeasureBindingLen >= 64,// anchor must represent enough characters
           prevHeight >= 30,// and a real laid-out block
           bindingLen>coord.lastFullMeasureBindingLen,
           bindingLen-coord.lastFullMeasureBindingLen<128 {           // tighter delta window
            let prevLen = coord.lastFullMeasureBindingLen
            let pxPerChar = prevHeight/CGFloat(prevLen)
            let delta = CGFloat(bindingLen-prevLen)
            // Cap the extrapolated growth to 1.5× the anchor and to an
            // absolute ceiling matching the on-screen viewport (avoids
            // table/code blocks blowing the estimate past the screen).
            let rawEstimate = prevHeight+delta*pxPerChar
            let estimated = min(rawEstimate,prevHeight*1.5,1200)
            // DO NOT write `estimated` to `cachedSizes` — that would let
            // the next sizeThatFits at the same bindingLen think it has a
            // real measurement and skip re-measurement entirely. Just
            // return the estimate for this probe; the next probe will
            // re-enter and either compute a real value (storage catches
            // up) or extrapolate again (delta still in range).
            return CGSize(width: width,height: estimated)
        }

        // If the binding length changed, the old cache is invalid — flush all
        // width buckets. Otherwise we're just adding a new width bucket.
        if bindingLen != coord.cachedSizeMarkdownCount {
            coord.cachedSizes.removeAll(keepingCapacity: true)
            coord.cachedSizeMarkdownCount = bindingLen
        }

        // If textStorage hasn't caught up to the binding yet (SwiftUI's
        // sizeThatFits-before-updateUIView ordering), measure against an
        // off-screen textView. Previously we committed the pending
        // attributedText into `uiView` here so its own sizeThatFits saw the
        // new content — but that rebuilds attachment subviews and calls
        // `addSubview` / `setNeedsLayout` on the live textView during
        // SwiftUI's measurement pass, which causes SwiftUI to re-invoke
        // `sizeThatFits` recursively. The resulting watchdog hang is
        // recorded in `MiniClaw-2026-05-13-084827.ips` (depth=9 recursion at
        // `LayoutEngineBox.sizeThatFits`). Measuring on a detached textView
        // keeps the live view's state stable until the subsequent
        // `updateUIView` runs.
        // (`useMeasureTextView` already declared above in the streaming
        // approximate-cache fast path.)
        let measuringTextView: MarkdownTextView
        // REPRO-FIX(2026-05-16): when storage doesn't have the latest content
        // yet, we used to write `pending` to an off-screen measureTextView
        // and call its sizeThatFits — but that triggers full _fillLayoutHole
        // + tcSize churn for every stream chunk. Replace with
        // NSAttributedString.boundingRect when pending is attachment-free
        // (boundingRect uses CoreText and never invalidates UIKit layout
        // state). When pending has attachments, TableAttachment /
        // CodeBlockAttachment / ImageAttachment custom `attachmentBounds`
        // is needed for correct heights, so we still fall back to mtv.
        if useMeasureTextView {
            // [TablePathFix] When the prebuilt attributed string contains a
            // TableAttachment we must NOT use it — the cached path comes
            // from `MessageListModel.cacheAttributedString(for:)` which uses
            // a fresh `MarkdownNSRenderer` and creates new TableAttachment
            // objects every flush. During streaming this detaches live
            // attachments from the coordinator's `tableAttachmentCache`
            // (which `update()` mutates with `contentGeneration` bumps
            // that the UAV dedup fingerprint relies on).
            let preHasTable: Bool = {
                guard let pre = cachedAttributedString,pre.length>0 else { return false }
                var found = false
                pre.enumerateAttribute(.attachment,in: NSRange(location: 0,length: pre.length),options: []) { value,_,stop in
                    if value is TableAttachment { found = true; stop.pointee = true }
                }
                return found
            }()
            let pending: NSAttributedString
            if let pre = cachedAttributedString,!preHasTable {
                pending = pre
            } else {
                // REPRO-FIX(2026-05-16): split off any in-flight (`|`-row
                // not yet terminated by `\n`) table block at the buffer's
                // tail. cmark gets only the stable prefix; the in-flight
                // tail is appended as plain attributed text using the body
                // font. This avoids the per-chunk `TableAttachment` rebuild
                // + `_fillLayoutHole` storm that hangs iPhone 17 Pro Max.
                //
                // Skip the split once the message has finished streaming
                // (the presence of `cachedAttributedString` or
                // `cachedContent` is the finalised signal): a message
                // whose final row never gets a trailing `\n` must still
                // be rendered as a real table after stream-end.
                let _isFinalisedSTF = cachedAttributedString != nil || cachedContent != nil
                let split = _isFinalisedSTF
                    ? (prefix: markdown, plainSuffix: "")
                    : splitStreamingTableTail(markdown)
                let preparedPrefix = prepareMarkdownForRender(split.prefix)
                let blocks = MarkdownContent(preparedPrefix).blocks
                coord.renderer.messageId = messageId
                coord.renderer.blockId = blockId
                let rendered = autoreleasepool { coord.renderer.render(blocks: blocks) }
                if split.plainSuffix.isEmpty {
                    pending = rendered
                } else {
                    let mut = NSMutableAttributedString(attributedString: rendered)
                    let suffixAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: FontSettings.shared.scaledMessage(16.5)),
                        .foregroundColor: UIColor.label,
                    ]
                    mut.append(NSAttributedString(string: split.plainSuffix,attributes: suffixAttrs))
                    pending = mut
                }
            }
            // REPRO-FIX(2026-05-16): scan pending for ANY .attachment.
            // No-attachment case: take the CoreText boundingRect fast path
            // (verified across 14 streaming rounds in commit 01939f7:
            // MAIN HANG = 0, avg processMs = 0.5). Attachments require
            // the legacy mtv path because their custom `attachmentBounds`
            // depends on TextKit invoking it through the line fragment
            // typesetter.
            var hasAnyAttachment = false
            pending.enumerateAttribute(.attachment,in: NSRange(location: 0,length: pending.length),options: []) { v,_,stop in
                if v != nil { hasAnyAttachment = true; stop.pointee = true }
            }
            if !hasAnyAttachment {
                // [T-ios-decel-inv-estimate-calibration] FINALIZED content takes
                // the real-engine measure: CTFramesetter over-measures blocks
                // with inline-code/bold spans by +2..+36pt vs the actual TextKit
                // render (per-cell trajectory traces: first display grew the
                // cell mid-decel, then a later re-measure shrank it back — the
                // user-visible scroll jitter AND oscillation). An offscreen
                // MarkdownTextView measure matches the final render
                // by construction. Gated to finalized (non-streaming) content
                // and ≤8000 chars — streaming keeps the CT fast path (per-chunk
                // cost), and huge blocks avoid TextKit1's near-O(n²) wall
                // (T-ios-longreply-boundingRect-watchdog).
                let finalizedSTF = cachedAttributedString != nil || cachedContent != nil
                let h: CGFloat
                if finalizedSTF,pending.length <= 8000,
                   let mtv = coord.measureTextView as? MarkdownTextView {
                    mtv.attributedText = pending
                    h = ceil(mtv.sizeThatFits(CGSize(width: width,height: .greatestFiniteMagnitude)).height)
                } else {
                    // [T-ios-longreply-boundingRect-watchdog] CTFramesetter instead of
                    // NSAttributedString.boundingRect — same CoreText result (±1pt) but
                    // 70–700× faster on many-line text (boundingRect's TextKit1 wrapper
                    // is near-O(n²) in line count). Attachment-free is already asserted
                    // above, so it's safe here.
                    let textHeight = Self.ctFramesetterHeight(for: pending,width: width)
                    // [BoundingRectInset 2026-05-16] CoreText measurement
                    // omits UITextView.textContainerInset (configured top=4
                    // bottom=4 in init, line ~3597). Diagnostic confirmed
                    // UITextView.sizeThatFits returns text height +
                    // exactly inset.top + inset.bottom (=8) consistently
                    // across CJK + inline-code multi-paragraph blocks.
                    // Without this addition cell.frame is 7-8pt short and
                    // the last visual line of every multi-line markdown
                    // cell gets clipped at its descender.
                    let inset = uiView.textContainerInset.top+uiView.textContainerInset.bottom
                    h = textHeight+inset
                }
                coord.cachedSizes[widthKey] = h
                coord.cachedSizeMarkdownCount = bindingLen
                if bindingLen>0 {
                    coord.lastFullMeasureBindingLen = bindingLen
                    coord.lastFullMeasureHeight[widthKey] = h
                    coord.lastFullMeasureAt = CFAbsoluteTimeGetCurrent()
                }
                let _renderW = uiView.bounds.width
                if _renderW <= 0 || abs(width-_renderW)<0.5 {
                    uiView.lastComputedHeight = h
                }
                return CGSize(width: width,height: h)
            }
            // Fallback: pending has attachments — use mtv path so
            // attachmentBounds is invoked through TextKit.
            let mtv = coord.measureTextView as? MarkdownTextView ?? coord.measureTextView as! MarkdownTextView
            mtv.attributedText = pending
            #if DEBUG
            // [T-attachment-zero-origin] Snapshot the moment after attributedText
            // is assigned to the off-screen measureTextView. This is exactly when
            // TextKit runs setGlyphs:properties: — if textContainer.size.width is
            // still 0 here, attachment glyphs get classified as controlCharacter
            // (the bug we're hunting). The snapshot captures glyphProperty for
            // every attachment so we can see the bad classification directly.
            MarkdownSnapshotCollector.captureIfEnabled(
                textView: mtv,
                phase: "afterMtv.setAttributedText",
                messageId: context.coordinator.renderer.messageId?.uuidString,
                isMeasureView: true
            )
            #endif
            measuringTextView = mtv
        } else {
            measuringTextView = uiView

            // [T-ios-longreply-boundingRect-watchdog] Non-streaming fast path.
            // For a fully-committed (bindingLen == storageLen) attachment-free
            // text block, measure with CTFramesetter instead of falling through
            // to `uiView.sizeThatFits` below — that call runs TextKit1's
            // near-O(n²) layout and is the source of the 8.7–10.8s SLOW MEASURE /
            // WatchdogProbe 2000ms window / 0x8BADF00D watchdog kills on the
            // 29k-char / ~1500-line reply. CTFramesetter is 70–700× faster and
            // returns the same height (±1pt). Attachments (table/code/image) still
            // take the TextKit path so their custom attachmentBounds is honored.
            let liveStorage = uiView.textStorage
            if liveStorage.length>0 {
                var hasAnyAttachment = false
                liveStorage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: liveStorage.length),options: []) { v,_,stop in
                    if v != nil { hasAnyAttachment = true; stop.pointee = true }
                }
                if !hasAnyAttachment {
                    // [T-ios-decel-inv-estimate-calibration] Same real-engine
                    // routing as the pre-commit branch above: committed
                    // attachment-free content ≤8000 chars measures on the
                    // offscreen MarkdownTextView (matches the render
                    // exactly); CT stays for huge blocks (watchdog wall).
                    // FINALIZED-ONLY: during streaming, bindingLen catches up to
                    // storageLen between chunks, so without this gate every
                    // post-commit probe would pay the mtv measure (1.4-11ms vs
                    // CT's 0.3ms) per chunk — the exact per-chunk typesetter
                    // cost de4d3df6 / REPRO-FIX(2026-05-16) fought to remove.
                    let finalizedCommitted = cachedAttributedString != nil || cachedContent != nil
                    let h: CGFloat
                    if finalizedCommitted,liveStorage.length <= 8000,
                       let mtv = coord.measureTextView as? MarkdownTextView {
                        mtv.attributedText = liveStorage
                        h = ceil(mtv.sizeThatFits(CGSize(width: width,height: .greatestFiniteMagnitude)).height)
                    } else {
                        let textHeight = Self.ctFramesetterHeight(for: liveStorage,width: width)
                        // Match UITextView.sizeThatFits: add textContainerInset (top+bottom).
                        let inset = uiView.textContainerInset.top+uiView.textContainerInset.bottom
                        h = textHeight+inset
                    }
                    coord.cachedSizes[widthKey] = h
                    if coord.cachedSizes.count>4,let firstKey = coord.cachedSizes.keys.first {
                        coord.cachedSizes.removeValue(forKey: firstKey)
                    }
                    coord.cachedSizeMarkdownCount = bindingLen
                    if bindingLen>0 {
                        coord.lastFullMeasureBindingLen = bindingLen
                        coord.lastFullMeasureHeight[widthKey] = h
                        coord.lastFullMeasureAt = CFAbsoluteTimeGetCurrent()
                        if coord.lastFullMeasureHeight.count>4,let firstKey = coord.lastFullMeasureHeight.keys.first {
                            coord.lastFullMeasureHeight.removeValue(forKey: firstKey)
                        }
                    }
                    let renderW = uiView.bounds.width
                    if renderW <= 0 || abs(width-renderW)<0.5 {
                        uiView.lastComputedHeight = h
                    }
                    let totalMs = (CFAbsoluteTimeGetCurrent()-t0)*1000
                    coord.sizeThatFitsTotalMs += totalMs
                    #if DEBUG
                    Self.recordSTF(elapsedMs: totalMs,msgId: messageId,attrLen: bindingLen)
                    #endif
                    return CGSize(width: width,height: h)
                }
            }
        }

        // CRITICAL FIX: Only touch textContainer.size when the width ACTUALLY
        // changed. On iOS 26 TextKit1, assigning the same CGSize still triggers
        // -[NSLayoutManager textContainerChangedGeometry:] which invalidates the
        // entire layout and forces a full _fillLayoutHole pass. Time Profiler
        // showed this single line causing 8+ second hangs during CollectionView
        // bounds-change re-measurement on large messages.
        //
        // [JitterFix] SwiftUI drives sizeThatFits at TWO widths per layout
        // pass: the inner content width (~370) and the cell's outer width
        // (~402). Committing both into the live textContainer corrupts
        // render state — the next render uses whichever width "won" most
        // recently, producing a 23pt height oscillation. Only commit when
        // the probe width matches the live bounds.width (the width the cell
        // will actually render at). Other-width probes still measure
        // correctly via UITextView.sizeThatFits, but don't mutate state.
        let tc = measuringTextView.textContainer
        let oldWidth = tc.size.width
        let renderW = measuringTextView.bounds.width
        let isRenderWidth = renderW>0 && abs(width-renderW)<0.5
        let widthChanged = abs(width-oldWidth)>0.5
        // For the off-screen measureTextView (renderW == 0), always sync
        // the width so it measures at the requested fitting width.
        if widthChanged && (isRenderWidth || renderW <= 0 || useMeasureTextView) {
            tc.size = CGSize(width: width,height: .greatestFiniteMagnitude)
        }

        // Let UITextView.sizeThatFits drive layout lazily. Removing the
        // surrounding explicit lm.ensureLayout(for:) calls — they were
        // running a second and third full typesetting pass on top of the
        // one UITextView.sizeThatFits already does internally.
        let tSize = CFAbsoluteTimeGetCurrent()
        let size = measuringTextView.sizeThatFits(CGSize(width: width,height: .greatestFiniteMagnitude))
        let sizeMs = (CFAbsoluteTimeGetCurrent()-tSize)*1000

        // Restore the unbounded height so the layout manager keeps all glyphs
        // laid out for drawing. UITextView.sizeThatFits clamps this internally.
        // Only when actually clamped — see layoutSubviews for the rationale.
        if tc.size.height<CGFloat.greatestFiniteMagnitude {
            tc.size.height = CGFloat.greatestFiniteMagnitude
        }

        // Keep lastComputedHeight in sync so invalidateCellSizeIfChanged()
        // can detect real deltas. Without this, lastComputedHeight stays 0
        // after the initial sizeThatFits, causing the guard to skip layout
        // invalidation when images load asynchronously and change the height.
        //
        // [JitterFix] Only commit when probe width matches render width;
        // otherwise the outer-width probe (402) clobbers the correct
        // inner-width measurement (370 → ~611) with a 23pt-smaller value.
        // Per-width caching still works via coord.cachedSizes below.
        if isRenderWidth || renderW <= 0 {
            uiView.lastComputedHeight = size.height
        }

        // Cache the new result by width bucket. Cap at 4 buckets to bound
        // memory; evict the first inserted entry when overflowing.
        coord.cachedSizes[widthKey] = size.height
        if coord.cachedSizes.count>4 {
            if let firstKey = coord.cachedSizes.keys.first {
                coord.cachedSizes.removeValue(forKey: firstKey)
            }
        }

        // HangFix(2026-05-14) — record this real measurement as the
        // anchor for subsequent streaming approximations. Only the live-
        // view path (storage == binding) produces a fully accurate
        // height; the off-screen measureTextView path also produces a
        // real measurement so we anchor on it too (storeLen tracks
        // binding inside useMeasureTextView).
        if bindingLen>0 && size.height>0 {
            coord.lastFullMeasureBindingLen = bindingLen
            coord.lastFullMeasureHeight[widthKey] = size.height
            coord.lastFullMeasureAt = CFAbsoluteTimeGetCurrent()
            // Bound the same-width-bucket count to 4 so a flapping width
            // sequence doesn't grow without bound; reuse the same cap as
            // `cachedSizes` above.
            if coord.lastFullMeasureHeight.count>4 {
                if let firstKey = coord.lastFullMeasureHeight.keys.first {
                    coord.lastFullMeasureHeight.removeValue(forKey: firstKey)
                }
            }
        }

        let totalMs = (CFAbsoluteTimeGetCurrent()-t0)*1000
        coord.sizeThatFitsTotalMs += totalMs

        // Only log MISS on slow paths or periodically — every-token MISS during
        // streaming was a primary noise source.
        if totalMs >= 50 || callIdx%100 == 0 {
            let widthDelta = Int((width-oldWidth).rounded())
            let level: String
            if totalMs >= 200 { level = "🔥🔥" }
            else if totalMs >= 50 { level = "🔥" }
            else { level = "" }
            Self.stfLogger.info("[STF] #\(callIdx) MISS\(level) w=\(widthKey) (Δ\(widthDelta)) len=\(bindingLen) wChg=\(widthChanged ? 1 : 0) stf=\(String(format: "%.1f", sizeMs))ms total=\(String(format: "%.1f", totalMs))ms buckets=\(coord.cachedSizes.count) cumulative=\(String(format: "%.0f", coord.sizeThatFitsTotalMs))ms hits=\(coord.sizeThatFitsCacheHitCount)/\(callIdx)")
        }

        if bindingLen >= 10_000 && totalMs >= 100 {
            Self.stfLogger.warning("[STF] ⚠️ LONG-TEXT SLOW len=\(bindingLen) totalMs=\(String(format: "%.1f", totalMs)) — repeated calls of this size can trigger 0x8BADF00D")
        }

        #if DEBUG
        // [WatchdogProbe] STF window probe — watchdog kills at 10s wall clock.
        // Track cumulative STF time per main-runloop iteration; when the same
        // runloop hop has already burned >2s in TextKit measurement, emit a
        // critical warning. This is the strongest pre-watchdog signal — a
        // single runloop iteration is what FRONTBOARD measures.
        Self.recordSTF(elapsedMs: totalMs,msgId: messageId,attrLen: bindingLen)
        #endif

        #if DEBUG
        // [T-attachment-zero-origin] Snapshot the textView used for measurement.
        // For attachment-bearing markdown this is the off-screen measureTextView
        // (where the lineFrag.width=10M bug surfaces); for attachment-free
        // content it's the live uiView itself.
        let stfMid = context.coordinator.renderer.messageId?.uuidString
        let isMeasure = (measuringTextView !== uiView)
        MarkdownSnapshotCollector.captureIfEnabled(
            textView: measuringTextView,
            phase: isMeasure ? "afterSizeThatFits.mtv" : "afterSizeThatFits.live",
            messageId: stfMid,
            isMeasureView: isMeasure,
            sizeThatFitsResult: CGSize(width: width,height: size.height)
        )
        #endif

        return CGSize(width: width,height: size.height)
    }

    private static let stfLogger = AppLogger(category: "MarkdownSTF")
    #if DEBUG
    fileprivate static let watchdogProbe = AppLogger(category: "WatchdogProbe")
    #endif

    #if DEBUG
    // MARK: WatchdogProbe — runloop-window cumulative tracking

    /// Tracks how much wall-clock time TextKit measurement has consumed on
    /// the main thread within a *single runloop iteration*. FRONTBOARD's
    /// 0x8BADF00D watchdog measures elapsed real time per scene-update
    /// cycle; when a single iteration burns >2s of STF/updateUIView, we are
    /// already a quarter of the way to termination. Reset by an idle observer
    /// installed lazily on the main runloop.
    private static var stfWindowTotalMs: Double = 0
    private static var stfWindowCallCount: Int = 0
    private static var updWindowTotalMs: Double = 0
    private static var updWindowCallCount: Int = 0
    private static var distinctMsgIds: Set<UUID> = []
    private static var observerInstalled = false
    private static let windowAlarmThresholdMs: Double = 2000
    private static var alarmAlreadyFiredThisHop = false

    fileprivate static func recordSTF(elapsedMs: Double,msgId: UUID?,attrLen: Int) {
        installWindowObserverIfNeeded()
        stfWindowTotalMs += elapsedMs
        stfWindowCallCount += 1
        if let msgId { distinctMsgIds.insert(msgId) }
        checkWindowAlarm(trigger: "stf", lastLen: attrLen, lastMsgId: msgId)
    }

    fileprivate static func recordUpdateUIView(elapsedMs: Double,attrLen: Int,msgId: UUID?) {
        installWindowObserverIfNeeded()
        updWindowTotalMs += elapsedMs
        updWindowCallCount += 1
        if let msgId { distinctMsgIds.insert(msgId) }
        checkWindowAlarm(trigger: "upd", lastLen: attrLen, lastMsgId: msgId)
    }

    private static func checkWindowAlarm(trigger: String,lastLen: Int,lastMsgId: UUID?) {
        let total = stfWindowTotalMs+updWindowTotalMs
        guard total >= windowAlarmThresholdMs,!alarmAlreadyFiredThisHop else { return }
        alarmAlreadyFiredThisHop = true
        let msgIdShort = lastMsgId?.uuidString.prefix(8) ?? "—"
        watchdogProbe.warning("[WatchdogProbe][window] 🚨 cumulative=\(String(format: "%.0f", total))ms (stf=\(String(format: "%.0f", stfWindowTotalMs)) upd=\(String(format: "%.0f", updWindowTotalMs))) sttCalls=\(stfWindowCallCount) updCalls=\(updWindowCallCount) distinctMsgs=\(distinctMsgIds.count) trigger=\(trigger) lastMsgId=\(msgIdShort) lastLen=\(lastLen) — main runloop is heading toward 0x8BADF00D (10s watchdog)")
    }

    private static func installWindowObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        // beforeWaiting fires once the runloop is about to sleep — natural
        // boundary for "this hop is done". We reset and, if the hop was
        // expensive, emit a summary so the log captures it even if no alarm
        // fired (cumulative under 2s but still notable).
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,0
        ) { _,_ in
            let total = stfWindowTotalMs+updWindowTotalMs
            if total >= 500 {
                watchdogProbe.info("[WatchdogProbe][hop] cumulative=\(String(format: "%.0f", total))ms stf=\(String(format: "%.0f", stfWindowTotalMs)) upd=\(String(format: "%.0f", updWindowTotalMs)) stfCalls=\(stfWindowCallCount) updCalls=\(updWindowCallCount) distinctMsgs=\(distinctMsgIds.count)")
            }
            stfWindowTotalMs = 0
            stfWindowCallCount = 0
            updWindowTotalMs = 0
            updWindowCallCount = 0
            distinctMsgIds.removeAll(keepingCapacity: true)
            alarmAlreadyFiredThisHop = false
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(),observer,.commonModes)
        }
    }
    #endif

    // MARK: Coordinator

    final class Coordinator: NSObject,UITextViewDelegate {
        var lastMarkdown: String = ""
        var lastRenderedContentHash: Int? = nil
        /// [FGReload] Markdown whose render was skipped because the app was
        /// not `.active` (see the `!= .active` guard in `updateUIView`). The
        /// skip exists to avoid the expensive `setAttributedText` +
        /// `ensureLayout` pass blocking the main thread during a scene-update
        /// transition, which trips the 0x8BADF00D watchdog (commit e6efac23).
        /// We stash the markdown here instead of dropping it so the foreground
        /// observer can replay it once the app is safely `.active` again —
        /// otherwise the last streaming frame stays blank until SwiftUI
        /// happens to re-evaluate the view body.
        var pendingMarkdown: String? = nil
        /// Re-invokes the live `updateUIView` render path for the deferred
        /// markdown. Captured fresh on every skip so it always closes over the
        /// current textView + render inputs (cachedAttributedString etc.).
        private var replayDeferredRender: (() -> Void)?

        /// Arms the foreground-replay path. Called from the `updateUIView`
        /// skip branch with a closure that re-runs the render for the current
        /// inputs. Lifecycle observers are armed eagerly in `init` — this
        /// just stores the pending state.
        func deferRender(_ markdown: String,replay: @escaping () -> Void) {
            pendingMarkdown = markdown
            replayDeferredRender = replay
        }

        private var foregroundObserver: NSObjectProtocol?
        private var resignActiveObserver: NSObjectProtocol?
        /// Wall-clock timestamp of the most recent `willResignActive` we
        /// observed. Cleared on `didBecomeActive`. The `.inactive` skip path
        /// uses this to distinguish short interruptions (control center
        /// swipe, incoming call banner — safe to render through) from
        /// long-running `.inactive` windows where the watchdog risk that
        /// commit e6efac23 fixed becomes material again. Armed eagerly in
        /// `init` so the timestamp is correct on the very first `.inactive`
        /// skip check, not only after the first deferred render.
        var inactiveEnteredAt: Date?

        override init() {
            super.init()
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.inactiveEnteredAt = nil
                self?.applyDeferredRenderNow()
            }
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.inactiveEnteredAt = Date()
            }
        }

        private func applyDeferredRenderNow() {
            // Only render once the app is genuinely `.active`. didBecomeActive
            // fires after the watchdog-sensitive scene-update transition has
            // settled, so the expensive layout pass is safe here.
            guard UIApplication.shared.applicationState == .active else { return }
            guard let pending = pendingMarkdown,let replay = replayDeferredRender else { return }
            pendingMarkdown = nil
            replayDeferredRender = nil
            replay()
        }

        deinit {
            if let foregroundObserver {
                NotificationCenter.default.removeObserver(foregroundObserver)
            }
            if let resignActiveObserver {
                NotificationCenter.default.removeObserver(resignActiveObserver)
            }
        }
        var lastFontSize: CGFloat = FontSettings.shared.scaledMessage(16.5)
        var openURL: OpenURLAction?
        /// Cached sizeThatFits results keyed by integer width bucket.
        /// Multi-bucket cache is required because SwiftUI layout protocol
        /// may probe the same view at several nearby widths within one
        /// CollectionView self-sizing pass. A single-width cache was being
        /// bypassed on every probe, triggering full TextKit1 relayouts.
        var cachedSizes: [Int: CGFloat] = [:]
        var cachedSizeMarkdownCount: Int = 0
        /// Last textContainer width at which `updateUIView` ran. Used so that
        /// a rotation that arrives as `(markdown unchanged, width changed)`
        /// still invalidates TableAttachment cached layouts so the table
        /// frame re-bakes at the new width instead of sticking at the old
        /// portrait columns. Initialised to a sentinel so the very first
        /// update doesn't spuriously fire the invalidation path.
        var lastRenderedWidth: CGFloat = -1
        /// [WATCHDOG-DIAG] Counters for localizing 0x8BADF00D watchdog crash.
        var sizeThatFitsCallCount: Int = 0
        var sizeThatFitsCacheHitCount: Int = 0
        var sizeThatFitsTotalMs: Double = 0
        var streamRenderCount: Int = 0
        /// HangFix(2026-05-14) — streaming-aware approximate cache.
        /// Track per-character height (height ÷ bindingLen at last real
        /// measurement) so when `sizeThatFits` is called during streaming
        /// with a bindingLen that has only grown by a small amount, we can
        /// return `cachedHeight + (delta × pxPerChar)` without running a
        /// full off-screen render + UITextView.sizeThatFits pass.
        ///
        /// Why this matters: commit 0f58bb3 changed the STF cache key from
        /// textStorage.length to bindingLen, which fixed DeepSeek V4 char
        /// clipping but means every streamed token invalidates the cache.
        /// Each miss spawns a full prepareMarkdownForRender +
        /// renderer.render + off-screen UITextView measure, which on iPhone
        /// 17 Pro Max + 120Hz + CJK + emoji costs ~50-200ms per call.
        /// SwiftUI calls sizeThatFits at two widths per layout pass, so
        /// streaming a single message accumulates main-thread work
        /// faster than it drains -> background watchdog 0x8BADF00D.
        var lastFullMeasureBindingLen: Int = 0
        var lastFullMeasureHeight: [Int: CGFloat] = [:]
        var lastFullMeasureAt: CFAbsoluteTime = 0
        var renderer = MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5))

        /// [WordFade] The textView whose storage the fade animator mutates.
        /// Set on the append fast path so the animator's redraw closure can
        /// repaint it. Weak — the SwiftUI representable owns the view.
        weak var fadeTextView: MarkdownTextView?

        /// [WordFade] Drives word-by-word alpha fade-in for streamed tokens.
        /// Created lazily on first append so non-streaming / history cells
        /// (which never hit the fast path) never allocate a CADisplayLink.
        /// Its redraw closure repaints whatever `fadeTextView` currently points
        /// at, so a Coordinator reused across textViews stays correct.
        lazy var fadeAnimator: TextFadeAnimator = TextFadeAnimator { [weak self] in
            self?.fadeTextView?.setNeedsDisplay()
        }

        /// Off-screen textView used by `sizeThatFits` to measure pending
        /// attributedText that hasn't been committed to the on-screen
        /// textView yet. Writing pending text into the live `uiView` from
        /// inside `sizeThatFits` is what caused the watchdog hang seen in
        /// `MiniClaw-2026-05-13-084827.ips`: it rebuilds attachment subviews
        /// and calls `addSubview` → `setNeedsLayout` on the textView
        /// during SwiftUI's measurement pass, which then triggers SwiftUI
        /// to re-invoke `sizeThatFits` indefinitely.
        ///
        /// Configured once and reused across measurement calls. Layout is
        /// driven by `sizeThatFits` — never attached to a window.
        fileprivate lazy var measureTextView: UITextView = {
            let tv = MarkdownTextView()
            tv.isScrollEnabled = false
            tv.isEditable = false
            tv.isSelectable = false
            // [ClipFix 2026-05-16] Match the live MarkdownTextView's
            // textContainerInset (init at line ~3597 sets top=4 bottom=4).
            // Previously this was `.zero`, so mtv.sizeThatFits returned 8pt
            // less than the on-screen UITextView actually rendered, and
            // every attachment-bearing cell (tables, code blocks, images)
            // got a cell.frame 8pt shorter than its content — clipping the
            // last visual line. Verified by the ClipDiag log: BR path
            // (uiView with inset=4/4) returned diff≈-0.5 while HIT path
            // (mtv-written cached value) returned diff=+8.0 for the same
            // text type.
            tv.textContainerInset = UIEdgeInsets(top: 4,left: 0,bottom: 4,right: 0)
            tv.textContainer.lineFragmentPadding = 0
            tv.backgroundColor = .clear
            return tv
        }()

        @available(iOS 17.0,*)
        func textView(_ textView: UITextView,primaryActionFor textItem: UITextItem,defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { [weak self] _ in
                    if let openURL = self?.openURL {
                        openURL(url)
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
            // [D1 T-ios-table-attachment-tap-preview-ios18] A TableAttachment
            // carries a 1×1 transparent placeholder image (needed for
            // attachmentBounds), so on iOS 18 and below the host UITextView
            // treats a single tap on it as an IMAGE text-item and pops the
            // system "拷贝图像/存入相机胶卷" preview. Suppress that here by
            // returning a no-op action; the real table interaction lives on the
            // overlaid TableScrollView, which still scrolls/selects. iOS 19+
            // changed the system behavior, so leave its default untouched.
            if #available(iOS 19,*) {
                // iOS 19+: default behavior, no change.
            } else if case .textAttachment(let attachment) = textItem.content,
                      attachment is TableAttachment {
                return UIAction { _ in }
            }
            return defaultAction
        }

        @available(iOS 17.0,*)
        func textView(_ textView: UITextView,menuConfigurationFor textItem: UITextItem,defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            switch textItem.content {
            case .link(let url):
                let copyAction = UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = url.absoluteString
                }
                let openAction = UIAction(title: String(localized: "Open in Safari"), image: UIImage(systemName: "safari")) { _ in
                    UIApplication.shared.open(url)
                }
                let menu = UIMenu(children: [copyAction,openAction])
                return UITextItem.MenuConfiguration(preview: nil,menu: menu)
            case .textAttachment(let attachment):
                // [D1 T-ios-table-attachment-tap-preview-ios18] On iOS 18 and
                // below, a tap on a table attachment must not present the image
                // preview. Offer a real "Copy Table" menu (tab-separated text,
                // same payload as the TableScrollView copyTable path) instead of
                // the empty menu, and a nil preview so no image sheet appears.
                // iOS 19+ behavior is unchanged (falls through to the logic
                // below).
                if #available(iOS 19,*) {
                    // iOS 19+: no special-casing, use the logic below.
                } else if let tableAttach = attachment as? TableAttachment {
                    let copyTableAction = UIAction(
                        title: String(localized: "Copy Table"),
                        image: UIImage(systemName: "tablecells")
                    ) { _ in
                        UIPasteboard.general.string = tableAttach.plainText()
                    }
                    return UITextItem.MenuConfiguration(preview: nil,menu: UIMenu(children: [copyTableAction]))
                }
                guard let imageAttach = attachment as? ImageAttachment,
                      let image = imageAttach.loadedImage else {
                    // Suppress system default menu (which would copy/save the
                    // 1×1 transparent placeholder) when no real image is loaded.
                    return UITextItem.MenuConfiguration(preview: nil,menu: UIMenu(children: []))
                }
                let copyAction = UIAction(title: String(localized: "Copy Image"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.image = image
                }
                let saveAction = UIAction(title: String(localized: "Save to Camera Roll"), image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                        guard status == .authorized || status == .limited else { return }
                        PHPhotoLibrary.shared().performChanges {
                            PHAssetChangeRequest.creationRequestForAsset(from: image)
                        }
                    }
                }
                let menu = UIMenu(children: [copyAction,saveAction])
                return UITextItem.MenuConfiguration(preview: nil,menu: menu)
            @unknown default:
                return nil
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? MarkdownTextView)?.refreshSelectionState()
        }

        func textView(_ textView: UITextView,shouldInteractWith URL: URL,in characterRange: NSRange,interaction: UITextItemInteraction) -> Bool {
            if interaction == .presentActions {
                let alert = UIAlertController(title: URL.absoluteString,message: nil,preferredStyle: .actionSheet)
                alert.addAction(UIAlertAction(title: String(localized: "Copy Link"), style: .default) { _ in
                    UIPasteboard.general.string = URL.absoluteString
                })
                alert.addAction(UIAlertAction(title: String(localized: "Open in Safari"), style: .default) { _ in
                    UIApplication.shared.open(URL)
                })
                alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    var presenter = root
                    while let presented = presenter.presentedViewController { presenter = presented }
                    if let popover = alert.popoverPresentationController {
                        popover.sourceView = textView
                        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: characterRange,actualCharacterRange: nil)
                        popover.sourceRect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange,in: textView.textContainer)
                    }
                    presenter.present(alert,animated: true)
                }
                return false
            }
            if let openURL {
                openURL(URL)
            } else {
                UIApplication.shared.open(URL)
            }
            return false
        }
    }
}

