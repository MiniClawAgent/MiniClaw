import SwiftUI
import UIKit
import Combine
import Foundation

extension MessageCollectionView.Coordinator {
        // MARK: - Accurate Height Measurement

        /// Measure the rendered height of an NSAttributedString using TextKit's
        /// full layout engine (NSLayoutManager + NSTextContainer). This correctly
        /// handles NSTextAttachment subclasses (tables, code blocks, images) by
        /// calling attachmentBounds() during layout, unlike boundingRect() which
        /// uses the attachment's 1×1px placeholder image.
        /// [T-ios-decel-inv-estimate-calibration] Measure with the REAL render
        /// engine: an offscreen MarkdownTextView (MiniClawLayoutManager +
        /// 4/4 textContainerInset), exactly what the live cell hosts. The
        /// previous bare-NSLayoutManager measure drifted +4..+21pt on ~30% of
        /// blocks (multi-paragraph / emoji-heading content) — debug.measureCompare
        /// ground truth showed the drift is engine-internal (usesFontLeading was
        /// ruled out: identical results), so no formula over the bare engine can
        /// close it. Measuring with the same engine is exact BY CONSTRUCTION.
        /// Cost: avg 1.4ms/block (vs 0.67ms bare), cached per attributed string
        /// in attrStringHeightCache, main-thread only (seed loop already is).
        ///
        /// RETURNS the full text-view height INCLUDING its 8pt vertical insets
        /// (4 top + 4 bottom) — callers add only the SwiftUI wrapper's
        /// .padding(.vertical, 2) (+4), NOT the historical +8.
        static func measureAttributedStringHeight(_ attrStr: NSAttributedString,width: CGFloat) -> CGFloat {
            // Watchdog guard: UITextView.sizeThatFits is near-O(n²) in line
            // count (the 29k-char / 8-10s SLOW MEASURE history,
            // T-ios-longreply-boundingRect-watchdog). Above the cap, fall back
            // to the linear bare-NSLayoutManager measure and accept its small
            // drift — on a 10000pt+ cell a ±20pt error is invisible.
            guard attrStr.length <= 8000 else {
                let storage = NSTextStorage(attributedString: attrStr)
                let container = NSTextContainer(size: CGSize(width: width,height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                let lm = NSLayoutManager()
                lm.addTextContainer(container)
                storage.addLayoutManager(lm)
                lm.ensureLayout(for: container)
                // +8 = the text view insets the tv path includes natively.
                return ceil(lm.usedRect(for: container).height)+8
            }
            measureTextView.attributedText = attrStr
            let size = measureTextView.sizeThatFits(
                CGSize(width: width,height: .greatestFiniteMagnitude))
            return ceil(size.height)
        }

        /// Shared offscreen measurement text view (main-thread only).
        static let measureTextView = MarkdownTextView()

        /// [T-ios-user-msg-estimate-tail-jitter] Accurate height for a USER
        /// message cell, measured with the SAME font / wrap width / paddings as
        /// `ChatMessageRow.userRow` renders, so the precalc lands the cell at its
        /// true height (the coarse char-count estimator was ~10pt short, which
        /// grew contentSize mid-decel and caused the stop-then-twitch tail jank).
        /// Returns nil for attachment-only / empty text (caller falls back to the
        /// coarse estimate). Cached by content|width|fontsize.
        ///
        /// Layout constants mirror ChatView.userRow:
        ///   - font: .system(size: scaledMessage(16.5))
        ///   - bubble: .padding(.horizontal,14) .padding(.vertical,10)  → +20 height, -28 width
        ///   - row:   HStack { Spacer(minLength: 60); VStack(spacing:6){ attachments?; bubble } }
        ///   - cell:  .padding(.horizontal, 16) on the whole row
        /// No on-screen view is touched; pure TextKit measurement (usedRect).
        static func measureUserBubbleHeight(for message: ChatMessage,cvWidth: CGFloat,
                                            cache: inout [String: CGFloat]) -> CGFloat? {
            // userDisplayText: strip the <user-attached-files> block, trim.
            var text = message.content
            if let start = text.range(of: "<user-attached-files>") {
                let end = text.range(of: "</user-attached-files>")
                let endBound = end?.upperBound ?? text.endIndex
                text = String(text[text.startIndex..<start.lowerBound]+text[endBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let attachCount = message.attachments.isEmpty
                ? message.inputAttachments.count : message.attachments.count

            // Attachment tiles (70pt rows) sit above the bubble with 6pt spacing.
            // Reuses the same formula as estimateItemHeight(.user).
            let fontSize = FontSettings.shared.scaledMessage(16.5)
            let usableTextWidth = max(cvWidth-32 /*cell*/ - 60 /*Spacer*/ - 28 /*bubble pad*/,80)

            var attachH: CGFloat = 0
            if attachCount>0 {
                let tilesPerRow = max(1,Int((cvWidth-32-60)/70))
                let rows = ceil(CGFloat(attachCount)/CGFloat(tilesPerRow))
                attachH = rows*70+6 /*VStack spacing*/
            }

            guard !text.isEmpty else {
                // Attachment-only message: return tiles height if any, else nil
                // so the caller uses the coarse estimate (covers oddball cases).
                return attachCount>0 ? attachH : nil
            }

            let key = "\(text.count)|\(Int(usableTextWidth))|\(Int(fontSize))|\(attachCount)|\(text.hashValue)"
            if let cached = cache[key] { return cached }

            // [T-ios-user-msg-estimate-tail-jitter] Measure with UILabel, NOT raw
            // NSLayoutManager.usedRect. SwiftUI `Text` lays each line at the
            // font's full line-height box (with default leading); a bare
            // NSLayoutManager usedRect is ~2-3pt/line TIGHTER, so it
            // under-estimated by ~7pt on a multi-line bubble — and an
            // UNDER-estimate is exactly what makes the cell lay out short, so
            // SwiftUI Text truncates with "..." during scroll then visibly
            // expands at settle (the user-reported symptom). UILabel
            // (numberOfLines=0, byWordWrapping) reproduces SwiftUI Text's
            // Cheap TextKit measurement (boundingRect). NOTE: this gives the
            // font's TextKit line height (~fontSize×1.21), which is ~2.4pt/line
            // SHORTER than SwiftUI Text's rendered line box — so it slightly
            // under-estimates multi-line bubbles. We accept that here because the
            // real "…→expand" jitter is NOT primarily this residual (proven: every
            // measurement engine still left the symptom); the actual cause is
            // being investigated separately. Keep the measurement cheap.
            let font = UIFont.systemFont(ofSize: fontSize)
            let attr = NSAttributedString(string: text,attributes: [.font: font])
            let bounds = attr.boundingRect(
                with: CGSize(width: usableTextWidth,height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin,.usesFontLeading],
                context: nil
            )
            let textH = ceil(bounds.height)
            // [T-ios-decel-inv-estimate-calibration] CJK bubble correction: all
            // five first-measure samples in the debug.scrollMetrics trace showed
            // CJK bubbles landing +6.3–7.0 taller than this boundingRect-based
            // estimate (SwiftUI Text gives PingFang-fallback lines a taller
            // box), independent of line count in the observed 1–4 line range.
            // Latin-only bubbles were exact, so gate on CJK presence. ALSO gated
            // to attachment-free bubbles: the one attachment bubble in the
            // trace (att=1) measured exactly at the UNcorrected estimate — the
            // +7 overshot it to a -6.7 shrink correction — while all five
            // validated +7 samples were att=0.
            let cjk = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x30FF).contains($0.value) }
            // bubble vertical padding (10*2) + attachment block + 1pt safety.
            let total = textH+20+attachH+1+(cjk && attachCount == 0 ? 7 : 0)
            cache[key] = total
            return total
        }

        // MARK: - Height Estimation

        /// [T-ios-scroll-decel-height-drift] The owning message id for a list
        /// item (used to detect the actively streaming message so its cells are
        /// excluded from the height memo).
        static func messageId(of item: MessageListItem) -> UUID? {
            switch item {
            case .wholeMessage(let id): return id
            case .assistantHeader(let id): return id
            case .assistantFooter(let id): return id
            case .assistantBlock(let mid,_): return mid
            }
        }

        /// [T-ios-scroll-decel-height-drift] Stable per-content key for the
        /// measured-height memo, keyed by item identity AND a cheap content
        /// fingerprint (content length / attachment count). The fingerprint makes
        /// the key CHANGE when the content changes height without changing
        /// identity — streaming append, async image/attachment load, tool output
        /// growth — so a stale (shorter, mid-stream) height can't be seeded onto
        /// a now-taller cell. Combined with the width-gated lookup (rotation) and
        /// clearHeightCache (session switch / font-size change), this closes the
        /// memo's staleness paths. Font size is NOT in the key because a font
        /// change routes through clearHeightCache (wipes the whole memo).
        #if DEBUG
        /// [T-ios-scroll-metrics-ring] Stable content-hash identity for a cell.
        /// Unlike contentKey (built on runtime UUIDs, regenerated when history
        /// paging reloads message objects), this survives object regeneration:
        /// same rendered content → same tag. Used ONLY by the scroll-metrics
        /// ring so one cell's height trajectory can be followed across
        /// seed/measure/inv/flush events and across reload generations.
        static func stableCellTag(for item: MessageListItem,messages: [ChatMessage],messageIndex: [UUID: Int]) -> String {
            func digest(_ s: String) -> String {
                var h: UInt32 = 5381
                for b in s.prefix(96).utf8 { h = (h &* 33) &+ UInt32(b) }
                return String(h,radix: 36)
            }
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id],i<messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let c = msg(id)?.content ?? ""
                return "w#\(digest(c))#\(c.count)"
            case .assistantHeader(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "h#\(digest(c))"
            case .assistantFooter(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "f#\(digest(c))"
            case .assistantBlock(let mid,let bid):
                guard let b = msg(mid)?.blocks.first(where: { $0.id == bid }) else { return "b#?" }
                let c = b.content
                return "b#\(digest(c))#\(c.count)#\(b.kind)"
            }
        }
        #endif

        static func contentKey(for item: MessageListItem,messages: [ChatMessage],messageIndex: [UUID: Int]) -> String {
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id],i<messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let n = msg(id)?.content.count ?? 0
                let a = msg(id)?.attachments.count ?? 0
                return "w:\(id.uuidString):\(n):\(a)"
            case .assistantHeader(let id):
                return "h:\(id.uuidString)"
            case .assistantFooter(let id):
                return "f:\(id.uuidString)"
            case .assistantBlock(let mid,let bid):
                let block = msg(mid)?.blocks.first(where: { $0.id == bid })
                let n = block?.content.count ?? 0
                return "b:\(mid.uuidString):\(bid.uuidString):\(n)"
            }
        }

        static func estimateItemHeight(_ item: MessageListItem,messages: [ChatMessage],width: CGFloat) -> CGFloat {
            let scale = FontSettings.shared.scaledMessage(16)
            let lineHeight = scale*1.4
            let hPad: CGFloat = 80

            switch item {
            case .wholeMessage(let msgId):
                guard let msg = messages.first(where: { $0.id == msgId }) else { return 44 }
                switch msg.role {
                case .compactDivider: return 44
                case .systemInfo: return 36
                case .user:
                    // [T-ios-user-msg-estimate-tail-jitter] Use the SAME accurate
                    // UILabel-based measurement as the precalc path, NOT the coarse
                    // char-count heuristic. The heuristic (cpl = tw/(scale*0.55))
                    // under-counts lines — a 3-line message estimated as 2 lines —
                    // so when this estimate is the height used during a fast scroll
                    // / offscreen pass (before precalc lands, or via the
                    // configureCell/prefetch estimate fallback), the
                    // UIHostingConfiguration lays the Text into a 2-line box and
                    // SwiftUI truncates it to "2 lines + …"; at settle the real
                    // measure returns 3 lines and the cell visibly expands, jolting
                    // the whole page. Routing the estimate through the accurate
                    // measurement makes the offscreen height already 3 lines, so the
                    // Text never truncates and there is nothing to expand.
                    var throwaway: [String: CGFloat] = [:]
                    if let h = Self.measureUserBubbleHeight(for: msg,cvWidth: width,cache: &throwaway) {
                        return h
                    }
                    // Fallback (empty/attachment-only): coarse heuristic.
                    let tw = max(width-hPad,100)
                    let attachCount = msg.attachments.count
                    let imgH: CGFloat
                    if attachCount>0 {
                        let tilesPerRow = max(1,Int(tw/70))
                        let rows = ceil(CGFloat(attachCount)/CGFloat(tilesPerRow))
                        imgH = rows*70
                    } else {
                        imgH = 0
                    }
                    return imgH+44
                case .assistant: return 200
                }
            case .assistantHeader:
                return 28
            case .assistantBlock(let msgId,let blockId):
                guard let msg = messages.first(where: { $0.id == msgId }),
                      let block = msg.blocks.first(where: { $0.id == blockId }) else { return 44 }
                switch block.kind {
                case .text:
                    if let attrStr = block.cachedAttributedString {
                        let textWidth = max(width-32,100)
                        // [T-ios-longreply-boundingRect-watchdog] CTFramesetter instead
                        // of NSAttributedString.boundingRect. estimateItemHeight runs
                        // in prefetch/scroll-back for every not-yet-measured cell;
                        // boundingRect's TextKit1 layout is near-O(n²) in line count
                        // and could burn hundreds of ms per cell (watchdog risk on
                        // long history). CTFramesetter is 70–700× faster with the same
                        // height (±1pt). This is only a layout ESTIMATE, and the .text
                        // block's cachedAttributedString is attachment-free markdown
                        // text (attachments render as separate blocks), so it's safe.
                        let textH = MarkdownView.ctFramesetterHeight(for: attrStr,width: textWidth)
                        // +12 = text view insets (8) + SwiftUI wrapper vertical
                        // padding (4). This CT path is the coarse prefetch
                        // fallback; the seed loop's precalc uses the exact
                        // render-engine measure (measureAttributedStringHeight).
                        return textH+12
                    }
                    return Self.estimateTextBlockHeight(block.content,width: width,scale: scale,lineHeight: lineHeight)
                case .thinking:
                    // Header (icon 14pt or label 13pt) + vPad 10·2 + capsule border ≈ 36pt,
                    // + 4pt block-wrapper vertical padding = 40 (same calibration as tool
                    // capsules, [T-ios-decel-inv-estimate-calibration]).
                    // When expanded, content area adds up to 300pt of inner text + 10pt bottom pad.
                    let headerH: CGFloat = 40
                    guard block.isThinkingExpanded,!block.content.isEmpty else {
                        return headerH
                    }
                    let innerWidth = max(width-24,100)         // 12pt horizontal pad each side
                    let innerLineHeight: CGFloat = 13*1.4+3   // .lineSpacing(3) on 13pt font
                    let lines = block.content.split(separator: "\n", omittingEmptySubsequences: false)
                    var textH: CGFloat = 0
                    let cpl = max(1,innerWidth/7)              // ~7pt per CJK/wide glyph at 13pt
                    for line in lines {
                        let wrapped = max(1,ceil(CGFloat(line.count)/cpl))
                        textH += wrapped*innerLineHeight
                    }
                    let contentH = min(textH+10,300)            // ScrollView capped at 300pt
                    let total = headerH+contentH
                    return total
                // [T-ios-decel-inv-estimate-calibration] Tool capsules measure exactly
                // 36pt: ToolCapsuleView has NO vertical padding (unlike .text/.thinking,
                // which add .padding(.vertical, 2) → +4). The debug.scrollMetrics ring
                // proved the split: with 40 here, every real tool capsule corrected
                // 40→36 (-4) mid-decel; the +4 growths that motivated 40 were actually
                // collapsed THINKING blocks (handled above with headerH = 40).
                case .readImageTool: return 36
                case .file: return 40
                case .info:
                    let lineCount = max(1, block.content.components(separatedBy: "\n").count)
                    return CGFloat(20+lineCount*16)
                default: return 36  // Tool capsules (execute, browser, etc.): no wrapper pad
                }
            case .assistantFooter:
                return 4
            }
        }

        static func estimateTextBlockHeight(_ content: String,width: CGFloat,scale: CGFloat,lineHeight: CGFloat) -> CGFloat {
            // [T-ios-empty-textblock-gapH] An empty text block renders nothing
            // (EmptyView) — the one-line floor below is only for non-empty
            // streaming placeholders whose first delta is about to land.
            guard !content.isEmpty else { return 0 }
            let hPad: CGFloat = 80
            let tw = max(width-hPad,100)
            let cpl = tw/(scale*0.5)
            var total: CGFloat = 4

            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var i = 0
            while i<lines.count {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Fenced code block
                if trimmed.hasPrefix("```") {
                    var codeLines = 0
                    i += 1
                    while i<lines.count {
                        let cl = lines[i].trimmingCharacters(in: .whitespaces)
                        if cl.hasPrefix("```") { i += 1; break }
                        codeLines += 1
                        i += 1
                    }
                    total += 32+CGFloat(max(codeLines,1))*18+24
                    continue
                }

                // Table
                if trimmed.hasPrefix("|") && trimmed.contains("|") {
                    var tableRows = 0
                    while i<lines.count {
                        let tl = lines[i].trimmingCharacters(in: .whitespaces)
                        if tl.hasPrefix("|") && tl.contains("|") {
                            if !tl.contains("---") { tableRows += 1 }
                            i += 1
                        } else {
                            break
                        }
                    }
                    total += CGFloat(max(tableRows,1))*36+16
                    continue
                }

                // Horizontal rule
                if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    total += 16
                    i += 1
                    continue
                }

                // Image
                if trimmed.hasPrefix("![") && trimmed.contains("](") {
                    total += Self.estimateMarkdownImageHeight(line: trimmed,containerWidth: tw)
                    i += 1
                    continue
                }

                // Math block
                if trimmed == "$$" {
                    i += 1
                    while i<lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                        i += 1
                    }
                    i += 1
                    total += 80
                    continue
                }

                // Regular text
                if trimmed.isEmpty {
                    total += lineHeight*0.5
                } else {
                    let charCount = CGFloat(trimmed.count)
                    let wrappedLines = max(1,ceil(charCount/cpl))
                    total += wrappedLines*lineHeight
                }
                i += 1
            }

            // [T-ios-stream-bubble-spacing] +4 to match the measured-path baseline
            // (cachedAttributedString branch returns usedRect + 8; this heuristic
            // seeds total = 4, so it ran 4pt short). Centralizing the compensation
            // HERE — rather than at one applySnapshot call site — means EVERY
            // consumer (applySnapshot precalc, configureCell's estimate, and the
            // prefetch estimate) gets the padded height. The earlier per-call-site
            // +4 didn't stick because configureCell re-set the estimate from this
            // function WITHOUT the +4, overwriting it; a streaming cell then laid
            // out ~4pt short and SwiftUI clipped the bubble's .padding(.vertical, 2),
            // so the text looked glued to the bubble edges until a real measure ran.
            return max(total,lineHeight+4)+4
        }

        /// Estimate height for a Markdown image line by checking the image cache.
        /// Falls back to 200pt placeholder if the image hasn't been loaded yet.
        static func estimateMarkdownImageHeight(line: String,containerWidth: CGFloat) -> CGFloat {
            let maxImageWidth: CGFloat = 400
            // Extract URL from ![alt](url)
            guard let openParen = line.range(of: "]("),
                  let closeParen = line.range(of: ")", range: openParen.upperBound..<line.endIndex) else {
                return 200
            }
            let src = String(line[openParen.upperBound..<closeParen.lowerBound])
            if let cached = NativeMediaImageCache.shared.image(for: src) {
                let imgWidth = min(min(containerWidth,cached.size.width),maxImageWidth)
                let aspect = cached.size.height/max(cached.size.width,1)
                let maxH = UIScreen.main.bounds.height/2
                return min(imgWidth*aspect,maxH)+6
            }
            return 200
        }

}
