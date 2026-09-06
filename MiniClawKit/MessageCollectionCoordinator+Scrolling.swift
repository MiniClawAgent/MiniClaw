import SwiftUI
import UIKit
import Combine
import Foundation

extension MessageCollectionView.Coordinator {
        // MARK: - Scroll


        /// Tighter threshold for *re-acquiring* `.autoScrolling` after a
        /// deliberate user interaction settles. `nearBottomThreshold` (20pt)
        /// is right for *maintaining* the bottom-pin during streaming, but
        /// reusing it to re-arm auto-scroll caused trackpad jitter on iPad:
        /// a tiny two-finger scroll up leaves the offset well within 20pt of
        /// the bottom, so settle flipped straight back to `.autoScrolling`,
        /// the contentSize KVO re-pinned to the bottom, and that fought the
        /// next small scroll — the scrollbar darted up and down. Requiring the
        /// content to be essentially flush with the bottom (≤4pt) means a
        /// deliberate small scroll stays in `.userBrowsing`, while a scroll
        /// that genuinely lands at the bottom still resumes follow-along.
        ///

        /// Whether a list item is part of the given assistant message's span
        /// (block or footer — the header is the span's start, matched
        /// separately).
        static func item(_ item: MessageListItem,belongsTo messageId: UUID) -> Bool {
            switch item {
            case .assistantBlock(let mid,_): return mid == messageId
            case .assistantFooter(let mid): return mid == messageId
            case .wholeMessage,.assistantHeader: return false
            }
        }

        public func isNearBottom() -> Bool {
            return isWithinBottom(nearBottomThreshold)
        }

        /// True when the viewport is at (or within `threshold` of) the very top
        /// of the content — the first message's top is showing. Drives the
        /// up-button's hide: once the user has walked all the way up, there's
        /// nowhere further to jump. The top resting offset is
        /// -adjustedContentInset.top (content pinned under the nav bar).
        public func isAtContentTop(_ threshold: CGFloat = 8) -> Bool {
            guard let cv = viewController?.collectionView else { return false }
            return cv.contentOffset.y <= -cv.adjustedContentInset.top+threshold
        }

        /// True when the content offset is within `threshold` pt of the
        /// maximum (bottom) offset.
        public func isWithinBottom(_ threshold: CGFloat) -> Bool {
            guard let cv = viewController?.collectionView else { return true }
            // Use adjustedContentInset to account for input bar + tool bar overlay insets.
            let maxOffset = cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom
            return maxOffset-cv.contentOffset.y<threshold
        }

        public func scrollToLastItem(animated: Bool = false) {
            guard let cv = viewController?.collectionView else { return }
            let section = cv.numberOfSections-1
            guard section >= 0 else { return }
            let item = cv.numberOfItems(inSection: section)-1
            guard item >= 0 else { return }
            cv.scrollToItem(at: IndexPath(item: item,section: section),at: .bottom,animated: animated)
        }

        /// The user-message id the up-button last jumped to, so a repeated tap
        /// walks one turn further back. Reset (nil) whenever the anchoring
        /// context changes — manual drag, jump-to-bottom, snapshot change, or
        /// session load — so the next tap re-anchors to the current viewport
        /// instead of continuing from a stale turn.

        /// Diagnostics: which user turn the current viewport TOP is in.
        /// Returns (turnIndex, totalTurns); turnIndex is 0-based into the ordered
        /// list of user messages, -1 if unresolved. Cheap enough to call from a
        /// throttled scroll sampler.
        public func currentViewportUserTurn() -> (index: Int,total: Int) {
            guard let cv = viewController?.collectionView,
                  let vm,let ds = dataSource else { return (-1,0) }
            let msgs = vm.messages
            let userIds = msgs.compactMap { $0.role == .user ? $0.id : nil }
            guard !userIds.isEmpty else { return (-1,0) }
            let topItemMsgId: UUID? = cv.indexPathsForVisibleItems.min()
                .flatMap { ds.itemIdentifier(for: $0) }
                .flatMap { Self.messageId(of: $0) }
            let topMsgIdx = topItemMsgId.flatMap { id in msgs.firstIndex(where: { $0.id == id }) } ?? 0
            let anchorY = msgs[...topMsgIdx].reversed().first(where: { $0.role == .user })?.id ?? userIds.first!
            return (userIds.firstIndex(of: anchorY) ?? -1,userIds.count)
        }

        /// Up-button action: walk backwards through the conversation one user
        /// turn at a time. Replaces the old "jump to the very first message":
        /// - First tap: scroll to the user message of the turn the viewport is
        /// currently in (nearest role==.user at or above the top visible item).
        /// - Repeated taps (no intervening drag / new message / etc): each tap
        /// goes to the PREVIOUS turn's user message.
        /// - At the first turn already: stay put, no overscroll.
        /// A browse action — must NOT touch scrollMode (same rationale as the old
        /// scrollToTopNow: leave auto-scroll as-is so streaming doesn't yank the
        /// user back down after they jump up).
        public func scrollToPreviousUserTurn(animated: Bool = true) {
            guard let cv = viewController?.collectionView,
                  let vm,let ds = dataSource else { return }
            let msgs = vm.messages
            guard !msgs.isEmpty else { return }

            // Ordered list of user-message ids as they appear in the conversation.
            let userIds = msgs.compactMap { $0.role == .user ? $0.id : nil }
            guard !userIds.isEmpty else {
                // No user turns (rare) — fall back to the top of the list.
                if cv.numberOfSections>0,cv.numberOfItems(inSection: 0)>0 {
                    cv.scrollToItem(at: IndexPath(item: 0,section: 0),at: .top,animated: animated)
                }
                return
            }

            // Resolve the message id at the top of the viewport → its message
            // index → the nearest user message at or above it (the current turn's
            // anchorY).
            let topItemMsgId: UUID? = cv.indexPathsForVisibleItems.min()
                .flatMap { ds.itemIdentifier(for: $0) }
                .flatMap { Self.messageId(of: $0) }
            let topMsgIdx = topItemMsgId.flatMap { id in msgs.firstIndex(where: { $0.id == id }) } ?? 0
            let currentAnchor = msgs[...topMsgIdx].reversed().first(where: { $0.role == .user })?.id ?? userIds.first!

            // Decide the target: if the viewport is already at the anchorY we last
            // jumped to (user has seen this turn's start), step to the previous
            // turn; otherwise land on the current turn's anchorY first.
            let target: UUID
            if lastJumpedUserId == currentAnchor,
               let pos = userIds.firstIndex(of: currentAnchor),pos>0 {
                target = userIds[pos-1]
            } else {
                target = currentAnchor
            }

            guard let targetItem = ds.snapshot().itemIdentifiers.first(where: {
                if case .wholeMessage(let id) = $0,id == target { return true }
                return false
            }),let ip = ds.indexPath(for: targetItem) else {
                AppLogger(category: "ChatList.Scroll").info("[Scroll][prevUserTurn] ABORT target item not found target=\(target.uuidString.prefix(8))")
                return
            }

            lastJumpedUserId = target
            let curTurn = userIds.firstIndex(of: currentAnchor) ?? -1
            let tgtTurn = userIds.firstIndex(of: target) ?? -1
            AppLogger(category: "ChatList.Scroll").info("[Scroll][prevUserTurn][CALL] curTurn=\(curTurn) targetTurn=\(tgtTurn)/\(userIds.count) topMsgIdx=\(topMsgIdx) currentAnchor=\(currentAnchor.uuidString.prefix(8)) target=\(target.uuidString.prefix(8)) ip=\(ip.section).\(ip.item) \(Self.nbDump(cv))")
            // Also record to the in-memory ring (debug.scrollMetrics) — the
            // on-device FILE log pipeline can stall, but the ring is live.
            // idx=target user-turn index, a=current viewport turn, b=total turns,
            // pos encodes the resulting button visibility for this frame.
            #if DEBUG
            let nbNow = isNearBottom()
            ScrollMetricsRecorder.shared.record(kind: "prevUserTurn", idx: tgtTurn,
                a: Double(curTurn),b: Double(userIds.count),
                pos: "call buttonsVisible=\(!msgs.isEmpty && !nbNow)",
                offset: Double(cv.contentOffset.y),note: Self.nbDump(cv))
            #endif
            cv.scrollToItem(at: ip,at: .top,animated: animated)
            // Re-sync isNearBottom so the up/down buttons reflect the new
            // position. Two syncs on purpose:
            // - the immediate main.async catches the common case;
            // - the delayed one covers UIKit's animated scrollToItem, whose
            // internal animation may not fire a terminal scrollViewDidScroll
            // at the settled offset. 0.4s covers the default scroll animation.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let cv2 = self.viewController?.collectionView
                let nbFlag = self.isNearBottom()
                #if DEBUG
                ScrollMetricsRecorder.shared.record(kind: "prevUserTurn",
                    a: nbFlag ? 1 : 0,b: (self.vm?.isNearBottom == true) ? 1 : 0,
                    pos: "sync-immediate", offset: Double(cv2?.contentOffset.y ?? -9999),
                    note: Self.nbDump(cv2))
                #endif
                _ = nbFlag
                self.syncScrollFlags()
            }
            if animated {
                DispatchQueue.main.asyncAfter(deadline: .now()+0.4) { [weak self] in
                    guard let self else { return }
                    let cv2 = self.viewController?.collectionView
                    let nbFlag = self.isNearBottom()
                    #if DEBUG
                    ScrollMetricsRecorder.shared.record(kind: "prevUserTurn",
                        a: nbFlag ? 1 : 0,b: (self.vm?.isNearBottom == true) ? 1 : 0,
                        pos: "sync-0.4s", offset: Double(cv2?.contentOffset.y ?? -9999),
                        note: Self.nbDump(cv2))
                    #endif
                    _ = nbFlag
                    self.syncScrollFlags()
                }
            }
        }

        /// Compact dump of the isWithinBottom inputs for ScrollDiag logs.
        static func nbDump(_ cv: UICollectionView?) -> String {
            guard let cv else { return "cv=nil→isWithinBottom RETURNS TRUE" }
            let maxOff = cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom
            let diff = maxOff-cv.contentOffset.y
            return "offY=\(String(format: "%.0f", cv.contentOffset.y)) cs=\(String(format: "%.0f", cv.contentSize.height)) bh=\(String(format: "%.0f", cv.bounds.height)) adjBot=\(String(format: "%.0f", cv.adjustedContentInset.bottom)) maxOff=\(String(format: "%.0f", maxOff)) diff=\(String(format: "%.0f", diff))"
        }

        /// Base contentInset.top (without sub-viewport overflowH compensation).
        /// iOS 26+ relies on system; older iOS uses an 8pt manual padding.
        public var baseContentInsetTop: CGFloat {
            if #available(iOS 26,*) { return 0 } else { return 8 }
        }

        /// Base contentInset.bottom = inputBarHeight + floatingBarHeight + 8.
        /// Set by updateUIViewController; the actual cv.contentInset.bottom
        /// equals this plus the current sub-viewport compensation (if any).
        /// `applySubViewportCompensation` is the only place that writes
        /// contentInset.bottom — it reads this base and adds overflowH.

        /// When content overflows the visible area but is still smaller than the
        /// UIKit-scrollable threshold, UIKit clamps maxOffset at 0 and the
        /// bottom of the content gets hidden behind the bottom overlay.
        ///
        /// Compensate by inflating `contentInset.bottom` by the overflowH
        /// amount so UIKit's natural maxOffset moves down (= contentSize -
        /// bounds + bottomInset becomes positive). The user can then scroll
        /// up to reveal the bottom rows that were hidden by the floating bar.
        /// `contentInset.top` stays at `baseContentInsetTop` so the first row
        /// is always glued to the safe area — no blank above the user message.
        ///
        /// `applySubViewportCompensation` is the only writer of
        /// `cv.contentInset.bottom`. updateUIViewController writes
        /// `coord.baseBottomInset`; this function reads it and applies
        /// `baseBottomInset + (needs ? overflowH : 0)`.
        ///
        /// Returns true if compensation is currently active.
        @discardableResult
        public func applySubViewportCompensation(caller: String = "?", forceRelax: Bool = false) -> Bool {
            guard let cv = viewController?.collectionView else { return false }
            let safeAreaTop = cv.safeAreaInsets.top
            // Use baseBottomInset (set by updateUIViewController) as the truth
            // for the non-compensated bottom. Reading cv.adjustedContentInset.bottom
            // here would create a feedback loop: we'd be measuring the inset we
            // just inflated and concluding we don't need to inflate any more.
            let bottomInsetBase = baseBottomInset
            let visibleH = cv.bounds.height-safeAreaTop-bottomInsetBase
            let overflowH = cv.contentSize.height-visibleH
            // Active compensation: content overflows but UIKit thinks no scroll
            // is needed. UIKit's natural maxContentOffset is
            // contentSize - bounds + adjustedContentInset.top + adjustedContentInset.bottom
            // safeAreaTop becomes adjustedContentInset.top, so include it here —
            // omitting it under-counts maxOffset by safeAreaTop (~116pt) and
            // wrongly engages compensation when content already fits naturally.
            let rawMaxOff = cv.contentSize.height-cv.bounds.height
+bottomInsetBase+safeAreaTop
            let needsCompensation = overflowH>0 && rawMaxOff <= 0
            let prevBottomInset = cv.contentInset.bottom

            // [B-fix] Monotonic compensation: during streaming, contentSize
            // grows token-by-token. The naive `desired = needs ? base+overflowH
            // : base` jumps the inset back to base the moment `rawMaxOff`
            // crosses 0 (~content reaches bounds.height), and the PIN below
            // chases the inset down — visually the streaming cell snaps from
            // mid-screen back to the bottom by ~overflowH pt (observed: 114pt
            // jump at 17:35:39, log [CHANGE] bottomInset 302.7→188.4 RELAX).
            //
            // Hold the inflated inset until either (a) caller explicitly asks
            // for a RELAX (e.g. mode change, snapshot-shrink, clear), or (b)
            // the cell can naturally scroll past `prevBottomInset - base` —
            // i.e. rawMaxOff has caught up to the existing inflation, so
            // releasing it produces no geometric jump.
            let priorInflation = max(0,prevBottomInset-bottomInsetBase)
            let canSafelyRelax = rawMaxOff >= priorInflation-0.5
            let desiredBottomInset: CGFloat
            if needsCompensation {
                // Grow only — never let the inset shrink mid-stream.
                desiredBottomInset = max(prevBottomInset,bottomInsetBase+overflowH)
            } else if forceRelax || canSafelyRelax {
                desiredBottomInset = bottomInsetBase
            } else {
                desiredBottomInset = prevBottomInset
            }
            let bottomInsetWillChange = abs(prevBottomInset-desiredBottomInset)>0.5
            if bottomInsetWillChange {
                let reason: String
                if desiredBottomInset<prevBottomInset {
                    reason = forceRelax ? "RELAX-FORCED" : "RELAX-SAFE (rawMaxOff≥priorInfl)"
                } else if needsCompensation && prevBottomInset <= bottomInsetBase+0.5 {
                    reason = "ENGAGE (overflowH=\(String(format: "%.0f", overflowH)))"
                } else {
                    reason = "GROW (overflowH=\(String(format: "%.0f", overflowH)))"
                }
                AppLogger(category: "ChatList.SubViewport").info("[CHANGE] from=\(caller) bottomInset \(String(format: "%.1f", prevBottomInset))→\(String(format: "%.1f", desiredBottomInset)) Δ\(String(format: "%+.1f", desiredBottomInset - prevBottomInset)) — \(reason)")
                cv.contentInset.bottom = desiredBottomInset
            }
            // Pin offset so content's bottom reaches the overlay top
            // (= bounds - bottomInset in viewport coords). Active in both the
            // compensation and the natural-scroll regime, as long as we are in
            // autoScrolling mode and there's something to pin to. Read the
            // INFLATED inset (cv.adjustedContentInset.bottom) for the pin
            // target so we glue to the just-applied bottom.
            if scrollMode == .autoScrolling {
                // [PIN-fix] Pin against the BASE bottom inset, not the
                // inflated one. Reading inflated `cv.adjustedContentInset.bottom`
                // here would push the cell up by `bottomI - base` (= the
                // sub-viewport compensation amount, up to ~90pt observed),
                // because the inflated inset effectively reserves blank space
                // BELOW the input bar that nobody can see. The compensation's
                // sole job is to make UIKit's natural maxOffset positive so
                // the user can scroll up to reveal the last cell — it is NOT
                // meant to define the resting position. Pinning to base keeps
                // the last cell glued to the input-bar top.
                //
                // adjustedContentInset.top still applies (safe-area /
                // navigation bar) — keep that as-is.
                let pinBottomInset = bottomInsetBase+cv.safeAreaInsets.bottom
                let rawTarget = cv.contentSize.height-cv.bounds.height+pinBottomInset
                // Clamp: don't let target go below -adjustedTop (would scroll
                // past the top edge), and don't exceed the inflated-inset
                // maxOff (would over-scroll past content end).
                let inflatedMaxOff = cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom
                let topLimit = -cv.adjustedContentInset.top
                let target = min(max(rawTarget,topLimit),inflatedMaxOff)
                if target>topLimit-0.5 && abs(cv.contentOffset.y-target)>0.5 {
                    cv.contentOffset.y = target
                }
            }
            return needsCompensation
        }

        public func scrollToBottomNow(animated: Bool = false) {
            guard let cv = viewController?.collectionView else { return }
            // Sub-viewport overflowH path: re-evaluate compensation, then pin.
            if applySubViewportCompensation(caller: "scrollToBottom") {
                syncScrollFlags()
                return
            }
            let maxOff = cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom
            guard maxOff>0 else { return }
            let target = CGPoint(x: 0,y: maxOff)
            if animated {
                isAnimatingScrollToBottom = true
                cv.setContentOffset(target,animated: true)
                // The animated set's final scrollViewDidScroll should land within
                // the near-bottom threshold, but an interrupted animation or
                // sub-pixel/inset rounding can leave vm.isNearBottom stuck false,
                // so the scroll-to-bottom button keeps showing while already at
                // the bottom. Re-sync once the animation settles.
                DispatchQueue.main.async { [weak self] in self?.syncScrollFlags() }
            } else {
                cv.contentOffset = target
                syncScrollFlags()
            }
        }

        /// Push the current near-bottom / far-from-top readings to the view
        /// model (change-gated to avoid @Published churn). Call after any
        /// programmatic scroll whose terminal scrollViewDidScroll may not fire
        /// or may land just outside a threshold.
        /// Re-sync isNearBottom after a programmatic jump (up-turn walk /
        /// jump-to-bottom) so the floating up/down buttons — both gated on
        /// !isNearBottom — reflect the settled position even when the terminal
        /// scrollViewDidScroll lands just outside the threshold. Called on the
        /// main thread after a jump settles.
        public func syncScrollFlags() {
            guard let vm else { return }
            let nbFlag = isNearBottom()
            if vm.isNearBottom != nbFlag {
                AppLogger(category: "ChatList.Scroll").info("[Scroll][syncScrollFlags] isNearBottom \(vm.isNearBottom)→\(nbFlag) \(Self.nbDump(viewController?.collectionView))")
                vm.isNearBottom = nbFlag
            }
            let atTop = isAtContentTop()
            if vm.isAtFirstTurn != atTop { vm.isAtFirstTurn = atTop }
        }

        // MARK: - Scrolling Screenshot Capture

        /// Locate the UITextView descendant
        /// (if any) that currently holds an active text-range selection in
        /// the collection view subtree. Used only by the screenshot
        /// diagnostic trace — non-destructive (does NOT clear selection).
        /// Returns the first textView found with a non-zero selectedRange,
        /// matching the depth-first walk order of `clearTextSelection`.
        @MainActor
        func activeSelectableTextView(in cv: UICollectionView) -> UITextView? {
            var found: UITextView? = nil
            func walk(_ view: UIView) {
                if found != nil { return }
                if let tv = view as? UITextView,tv.selectedRange.length>0 {
                    found = tv
                    return
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(cv)
            return found
        }

        /// Walk all subviews of `cv` and clear any active text selection so
        /// selection handles, magnifier loupes, focus rings and tinted ranges
        /// don't show up in screenshots.
        @MainActor
        func clearTextSelection(in cv: UICollectionView) {
            // Dismiss keyboard / global edit menu first.
            cv.window?.endEditing(true)
            UIMenuController.shared.hideMenu()

            func walk(_ view: UIView) {
                if let tv = view as? UITextView {
                    if tv.isFirstResponder { tv.resignFirstResponder() }
                    // Collapse selection to a zero-length range (nil doesn't
                    // always clear UITextView's internal selection state).
                    if let start = tv.position(from: tv.beginningOfDocument,offset: 0) {
                        tv.selectedTextRange = tv.textRange(from: start,to: start)
                    }
                    tv.selectedTextRange = nil
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(cv)
        }

        /// Capture a conversation turn by scrolling the live collection view
        /// page by page and stitching the snapshots into a single image.
        ///
        /// Uses fixed-height pages (`usableH`). Each page is cropped to
        /// exclude the nav bar (top) and input bar (bottom) overlay areas.
        /// Original `contentOffset` is restored before returning.
        @MainActor
        public func captureScrollingTurnScreenshot(userMessageId: UUID,assistantMessageId: UUID?) -> UIImage? {
            // All ChatScreenshot logs share
            // this monotonic anchorY so users can read elapsed-ms deltas
            // between stages without reasoning about wall-clock timestamps.
            let t0 = CACurrentMediaTime()
            func ms() -> String { String(format: "%6.1fms", (CACurrentMediaTime()-t0)*1000) }

            guard let cv = viewController?.collectionView,
                  let snapshot = dataSource?.snapshot() else {
                screenshotLogger.info("captureScrolling: no cv or snapshot")
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) ABORT — no cv or snapshot")
                return nil
            }
            let items = snapshot.itemIdentifiers

            guard let startIdx = items.firstIndex(where: {
                if case .wholeMessage(let id) = $0,id == userMessageId { return true }
                return false
            }) else {
                screenshotLogger.info("captureScrolling: user item not found")
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) ABORT — user message id=\(userMessageId.uuidString.prefix(8)) not found in snapshot")
                return nil
            }

            let endIdx: Int
            if let assistantMessageId,
               let i = items.lastIndex(where: {
                   if case .assistantFooter(let id) = $0,id == assistantMessageId { return true }
                   return false
               }) {
                endIdx = i
            } else {
                endIdx = startIdx
            }

            guard endIdx >= startIdx else { return nil }

            // [Stage1-Entry] full pre-capture state dump. The most important
            // fields for the top-blank symptom are contentOffset.y vs the
            // measured user-message frame.minY — if these don't align after
            // the warming pass, the page loop's first iteration crops from
            // the wrong starting Y.
            let savedOffset = cv.contentOffset
            // Suspend the auto-scroll
            // pinning machinery for the duration of the capture. When
            // the session is in `.autoScrolling` mode, the contentSize
            // KVO observer (around line 695) reacts to any layout
            // change — including the stream-driven cell-height
            // measurements that fire while we hold the runloop — by
            // resetting `cv.contentOffset.y = max(cv.contentOffset.y,
            // maxOff)`. That silently undoes our setContentOffset
            // writes during the page loop and the top of the turn
            // ends up missing from the canvas. Switch to
            // `.userBrowsing` for the capture (the same flag scrollViewWillBeginDragging
            // uses) and also clear `clampAfterSessionLoad`.
            // Restored before returning.
            let savedScrollMode = self.scrollMode
            let savedClampAfterSessionLoad = self.clampAfterSessionLoad
            self.scrollMode = .userBrowsing
            self.clampAfterSessionLoad = false
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) userMsg=\(userMessageId.uuidString.prefix(8)) startIdx=\(startIdx) endIdx=\(endIdx) totalItems=\(items.count) scrollMode=\(savedScrollMode == .autoScrolling ? "auto" : "browse")→browse(suspendedFlag) clampAfterSessionLoad=\(savedClampAfterSessionLoad)→false")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.contentOffset=(\(String(format: "%.1f", savedOffset.x)),\(String(format: "%.1f", savedOffset.y)))")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.bounds=\(String(format: "%.0fx%.0f", cv.bounds.width, cv.bounds.height)) cv.contentSize=\(String(format: "%.0fx%.0f", cv.contentSize.width, cv.contentSize.height))")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.adjustedContentInset=(t=\(String(format: "%.1f", cv.adjustedContentInset.top)) b=\(String(format: "%.1f", cv.adjustedContentInset.bottom)))")
            // Pre-warming frame readback — these may be ESTIMATED if the
            // user-message cell was offY-screen at long-press time.
            let entryFirstFrame = cv.layoutAttributesForItem(at: IndexPath(item: startIdx,section: 0))?.frame
            let entryLastFrame = cv.layoutAttributesForItem(at: IndexPath(item: endIdx,section: 0))?.frame
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) PRE-warm firstFrame=\(entryFirstFrame.map { String(format: "y=%.1f h=%.1f", $0.minY, $0.height) } ?? "nil") lastFrame=\(entryLastFrame.map { String(format: "y=%.1f h=%.1f", $0.minY, $0.height) } ?? "nil")")
            // Is the user message currently visible? If yes, no scroll
            // adjustment needed; if not, warming has to do real work.
            let visibleRange: ClosedRange<CGFloat>? = {
                let bounds = cv.bounds
                return savedOffset.y...(savedOffset.y+bounds.height)
            }()
            if let f = entryFirstFrame,let vr = visibleRange {
                let onScreen = f.maxY >= vr.lowerBound && f.minY <= vr.upperBound
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) userMessage visibleAtLongPress=\(onScreen) frameRange=[\(String(format: "%.1f", f.minY)),\(String(format: "%.1f", f.maxY))] viewportRange=[\(String(format: "%.1f", vr.lowerBound)),\(String(format: "%.1f", vr.upperBound))]")
            }
            // Active text selection state — text-selection menu path enters
            // here with selection ranges held by some UITextView descendant.
            // Knowing whether selection is held and which direction it was
            // dragged is the spec's prime suspect for the top-blank symptom.
            let activeSel = self.activeSelectableTextView(in: cv)
            if let tv = activeSel {
                let r = tv.selectedRange
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) selection ACTIVE on textView=\(String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(tv).toOpaque()))) range=(loc=\(r.location), len=\(r.length)) textLen=\(tv.textStorage.length)")
            } else {
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) no active text selection")
            }

            clearTextSelection(in: cv)
            cv.layoutIfNeeded()
            // After clearing the active
            // text selection, give UIKit one runloop tick to finish
            // releasing the selection state. Without this short wait,
            // scrollToItem below sometimes no-ops or partial-commits — the
            // cv is still inside its selection-locked autoscroll state from
            // the long-press gesture that opened the menu — and the
            // measured firstFrame.minY ends up offset from where the
            // page-loop expects it, dropping the top of the user message
            // offY the final canvas.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            let viewportH = cv.bounds.height
            let bottomMask = max(0,cv.adjustedContentInset.bottom)
            let topMask = max(0,cv.adjustedContentInset.top)
            let navSafetyGap: CGFloat = 10
            let cropTopY = topMask+navSafetyGap
            let usableH = max(1,viewportH-cropTopY-bottomMask)

            chatScreenshotLogger.info("[Stage2-Warming] \(ms()) BEGIN viewportH=\(String(format: "%.1f", viewportH)) topMask=\(String(format: "%.1f", topMask)) bottomMask=\(String(format: "%.1f", bottomMask)) cropTopY=\(String(format: "%.1f", cropTopY)) usableH=\(String(format: "%.1f", usableH))")
            // --- Warming pass ---
            // On first session load, cells above the viewport haven't been
            // configured yet (UICollectionView lazy-loads). First scroll the
            // user message into view so its cell is created and measured,
            // then scroll page-by-page through the assistant response.
            // After this pass all layout frames reflect measured heights.
            do {
                // Step 1: bring the user message cell on screen.
                let beforeStep1 = cv.contentOffset.y
                cv.scrollToItem(at: IndexPath(item: startIdx,section: 0),at: .top,animated: false)
                cv.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                let afterStep1 = cv.contentOffset.y
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) STEP1 scrollToItem(startIdx) offset: \(String(format: "%.1f", beforeStep1)) → \(String(format: "%.1f", afterStep1)) Δ=\(String(format: "%.1f", afterStep1 - beforeStep1))")

                // Step 2: scroll through the rest of the turn so all cells
                // between startIdx and endIdx are configured.
                let estLast = cv.layoutAttributesForItem(at: IndexPath(item: endIdx,section: 0))?.frame.maxY
                    ?? (cv.contentOffset.y+viewportH*3)
                var warmY = cv.contentOffset.y+cropTopY
                var warmCount = 0
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) STEP2 begin estLast=\(String(format: "%.1f", estLast)) initialWarmY=\(String(format: "%.1f", warmY))")
                while warmY<estLast && warmCount<200 {
                    warmCount += 1
                    cv.contentOffset = CGPoint(x: 0,y: warmY-cropTopY)
                    cv.layoutIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    let actual = cv.contentOffset.y+cropTopY
                    if actual+usableH >= estLast { break }
                    if actual <= warmY-0.5 && warmCount>1 { break }
                    warmY = actual+usableH
                }
                cv.layoutIfNeeded()
                screenshotLogger.info("captureScrolling: warming pass complete (\(warmCount) steps)")
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) END steps=\(warmCount) finalOffset=\(String(format: "%.1f", cv.contentOffset.y)) estLast=\(String(format: "%.1f", estLast))")
            }

            // After the warming pass
            // re-anchorY scroll to the user message's measured top. The
            // warming pass advances contentOffset turn-by-turn, leaving
            // the cv parked deep in the assistant response. Subsequent
            // page-loop code reads `firstAttrs.frame` for turnTopY but
            // never repositions the scroll view — so the first page
            // capture would start from wherever the warming pass left
            // offY (= bottom of the turn) rather than from the user
            // message top. The page loop's per-page scrollToY corrects
            // this once it iterates, but the first frame readback
            // happens before that and prior code paths assumed
            // contentOffset already matched. Make the assumption hold
            // by explicitly scrolling startIdx back to top here.
            let beforeReAnchor = cv.contentOffset.y
            cv.scrollToItem(at: IndexPath(item: startIdx,section: 0),at: .top,animated: false)
            cv.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) scrollToItem(startIdx, .top) offset: \(String(format: "%.1f", beforeReAnchor)) → \(String(format: "%.1f", cv.contentOffset.y)) Δ=\(String(format: "%.1f", cv.contentOffset.y - beforeReAnchor))")

            // --- Read final layout frames (now measured, not estimated) ---
            let firstAttrs = cv.layoutAttributesForItem(at: IndexPath(item: startIdx,section: 0))
            let lastAttrs = cv.layoutAttributesForItem(at: IndexPath(item: endIdx,section: 0))
            guard let firstFrame = firstAttrs?.frame,let lastFrame = lastAttrs?.frame else {
                screenshotLogger.info("captureScrolling: missing layout attributes")
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) ABORT — missing layout attributes (firstAttrs=\(firstAttrs == nil ? "nil" : "ok") lastAttrs=\(lastAttrs == nil ? "nil" : "ok"))")
                cv.contentOffset = savedOffset
                self.scrollMode = savedScrollMode
                self.clampAfterSessionLoad = savedClampAfterSessionLoad
                return nil
            }
            let turnTopY = firstFrame.minY-10
            let turnBottomEdge = lastFrame.maxY
            let totalH = turnBottomEdge-turnTopY
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) MEASURED firstFrame=\(String(format: "y=%.1f h=%.1f maxY=%.1f", firstFrame.minY, firstFrame.height, firstFrame.maxY)) lastFrame=\(String(format: "y=%.1f h=%.1f maxY=%.1f", lastFrame.minY, lastFrame.height, lastFrame.maxY))")
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) DERIVED turnTopY=\(String(format: "%.1f", turnTopY)) turnBottomEdge=\(String(format: "%.1f", turnBottomEdge)) totalH=\(String(format: "%.1f", totalH))")
            // KEY DIAGNOSTIC: alignment of cv.contentOffset.y vs turnTopY
            // matters because the first iteration of the page loop ASSUMES
            // a scroll has placed nextContentY (= turnTopY) at the cropTopY
            // line. If contentOffset.y is far offY from (turnTopY - cropTopY),
            // the first scrollToY may clamp or no-op and the top of the
            // capture starts from elsewhere.
            let expectedOffsetY = turnTopY-cropTopY
            let offsetDelta = cv.contentOffset.y-expectedOffsetY
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) ALIGN cv.contentOffset.y=\(String(format: "%.1f", cv.contentOffset.y)) expected=(turnTopY - cropTopY)=\(String(format: "%.1f", expectedOffsetY)) DELTA=\(String(format: "%.1f", offsetDelta)) (positive=scrolled past top)")
            // Diagnostic dump of every
            // mechanism that could be pinning the cv to bottom and
            // overriding our setContentOffset writes — without these
            // we cannot tell whether scrollMode/autoScrolling, the
            // clamp-after-session-load timer, an in-flight animated
            // scroll, an active gesture, deceleration, or some other
            // observer is rejecting the offset write.
            let maxOff = max(0,cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom)
            let nearBottom = (maxOff-cv.contentOffset.y)<60
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) PIN-STATE scrollMode=\(self.scrollMode == .autoScrolling ? "auto" : "browse") clampAfterSessionLoad=\(self.clampAfterSessionLoad) isAnimatingScrollToBottom=\(self.isAnimatingScrollToBottom) maxOff=\(String(format: "%.1f", maxOff)) currentOffset.y=\(String(format: "%.1f", cv.contentOffset.y)) nearBottom=\(nearBottom) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) dragging=\(cv.isDragging) GRs=\((cv.gestureRecognizers ?? []).map { "\(type(of: $0)):\($0.state.rawValue)" }.joined(separator: ","))")
            // Probe each scroll write
            // separately so the log records which one (if any) actually
            // moves the offset. Reading cv.contentOffset.y BEFORE every
            // setter + RIGHT AFTER (no runloop) shows whether UIKit
            // accepted the write synchronously; one runloop hop later
            // tells whether some observer rewrote it. Without this
            // breakdown we can't distinguish "setter rejected" from
            // "setter accepted but reverted".
            if abs(offsetDelta)>1 {
                self.clearTextSelection(in: cv)
                // Disable scroll gestures temporarily — these are the
                // most visible suspect for blocking writes during a
                // selection long-press.
                let savedGRStates: [(UIGestureRecognizer,Bool)] = (cv.gestureRecognizers ?? []).map { ($0,$0.isEnabled) }
                for (gr,_) in savedGRStates { gr.isEnabled = false }

                // Attempt A: setContentOffset(animated:false)
                let pA0 = cv.contentOffset.y
                cv.setContentOffset(CGPoint(x: 0,y: max(0,expectedOffsetY)),animated: false)
                let pA1 = cv.contentOffset.y // immediate readback (pre-runloop)
                cv.layoutIfNeeded()
                let pA2 = cv.contentOffset.y // after layoutIfNeeded
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                let pA3 = cv.contentOffset.y // after one runloop hop — if pA3 != pA2 someone wrote it back

                // Attempt B (only if A didn't reach target): direct assignment + runloop
                var pB0: CGFloat = -1,pB1: CGFloat = -1,pB2: CGFloat = -1
                if abs(pA3-expectedOffsetY)>1 {
                    pB0 = cv.contentOffset.y
                    cv.contentOffset = CGPoint(x: 0,y: max(0,expectedOffsetY))
                    pB1 = cv.contentOffset.y
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    pB2 = cv.contentOffset.y
                }

                for (gr,wasEnabled) in savedGRStates { gr.isEnabled = wasEnabled }
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT-A setContentOffset(animated:false) target=\(String(format: "%.1f", expectedOffsetY)) trace: pre=\(String(format: "%.1f", pA0)) postSet=\(String(format: "%.1f", pA1)) postLayout=\(String(format: "%.1f", pA2)) postRunloop=\(String(format: "%.1f", pA3))")
                if pB0 >= 0 {
                    chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT-B contentOffset= assignment target=\(String(format: "%.1f", expectedOffsetY)) trace: pre=\(String(format: "%.1f", pB0)) postSet=\(String(format: "%.1f", pB1)) postRunloop=\(String(format: "%.1f", pB2))")
                }
                // Final state for the page loop
                let postFinal = cv.contentOffset.y
                let postDelta = postFinal-expectedOffsetY
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT FINAL offset=\(String(format: "%.1f", postFinal)) postDelta=\(String(format: "%.1f", postDelta)) (postDelta=0 means commit succeeded)")
            }
            guard totalH>0 else {
                cv.contentOffset = savedOffset
                self.scrollMode = savedScrollMode
                self.clampAfterSessionLoad = savedClampAfterSessionLoad
                return nil
            }

            screenshotLogger.info("captureScrolling: turn=[\(Int(turnTopY)),\(Int(turnBottomEdge))] totalH=\(Int(totalH)) usableH=\(Int(usableH))")

            let scale = UIScreen.main.scale
            let cvWidth = cv.bounds.width

            // --- DEBUG: log appearance state ---
            let currentStyle = cv.traitCollection.userInterfaceStyle
            let windowStyle = cv.window?.traitCollection.userInterfaceStyle
            let windowOverride = cv.window?.overrideUserInterfaceStyle
            let cvOverride = cv.overrideUserInterfaceStyle
            screenshotLogger.info("captureScrolling [DEBUG] cv.traitCollection.userInterfaceStyle=\(currentStyle.rawValue) (0=unspec,1=light,2=dark)")
            screenshotLogger.info("captureScrolling [DEBUG] window.traitCollection.userInterfaceStyle=\(windowStyle?.rawValue ?? -1)")
            screenshotLogger.info("captureScrolling [DEBUG] window.overrideUserInterfaceStyle=\(windowOverride?.rawValue ?? -1)")
            screenshotLogger.info("captureScrolling [DEBUG] cv.overrideUserInterfaceStyle=\(cvOverride.rawValue)")
            screenshotLogger.info("captureScrolling [DEBUG] cv.backgroundColor=\(String(describing: cv.backgroundColor))")

            // Check superview/host backgrounds
            var sv = cv.superview
            var depth = 0
            while let v = sv,depth<5 {
                let resolvedBg = v.backgroundColor?.resolvedColor(with: v.traitCollection)
                screenshotLogger.info("captureScrolling [DEBUG] superview[\(depth)] \(type(of: v)) bg=\(String(describing: resolvedBg)) overrideStyle=\(v.overrideUserInterfaceStyle.rawValue)")
                sv = v.superview
                depth += 1
            }

            // Resolve bg color and log it
            let bgResolved = UIColor.systemBackground.resolvedColor(with: cv.traitCollection)
            var bgR: CGFloat = 0; var bgG: CGFloat = 0; var bgB: CGFloat = 0; var bgA: CGFloat = 0
            bgResolved.getRed(&bgR,green: &bgG,blue: &bgB,alpha: &bgA)
            screenshotLogger.info("captureScrolling [DEBUG] resolved systemBackground RGBA=(\(bgR),\(bgG),\(bgB),\(bgA))")

            // Lock the collection view's appearance to its current mode
            let savedOverride = cv.overrideUserInterfaceStyle
            cv.overrideUserInterfaceStyle = currentStyle == .dark ? .dark : .light

            // The CV and its immediate parent have backgroundColor set to
            // black-transparent (UIColor(white:0, alpha:0)). On screen this
            // is invisible because the SwiftUI HostingView behind it provides
            // the real background. But drawHierarchy renders the CV subtree
            // in isolation — the black bg composites on top of our white fill,
            // producing a black screenshot. Temporarily swap to the correct
            // background color for the capture.
            let savedCvBg = cv.backgroundColor
            let savedParentBg = cv.superview?.backgroundColor
            cv.backgroundColor = bgResolved
            cv.superview?.backgroundColor = bgResolved

            // Final canvas — Use standard-range sRGB (8 bpc) — the default
            // UIGraphicsImageRendererFormat creates a wide-color
            // ExtendedSRGB 16 bpc bitmap, and many apps (WeChat, etc.)
            // render 16 bpc PNGs as black/white.
            // opaque = true ensures a solid background (no alpha channel)
            // so pasted images don't show as transparent/white.
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            let finalSize = CGSize(width: cvWidth,height: totalH)
            let bg = bgResolved

            // Scroll through the turn range one page at a time. Each page:
            // 1. Scroll so `nextContentY` lands at the `cropTopY` line
            // (= topMask + navSafetyGap from the viewport top).
            // 2. Snapshot the full cv bounds.
            // 3. Crop the snapshot to [cropTopY, cropTopY + sliceH].
            // 4. Blit the crop into the final canvas at dstY.
            // 5. Advance by `usableH`.
            //
            // `cropTopY` is the y-coordinate inside the viewport where the
            // usable (nav-bar-free) area starts. By scrolling so that
            // `nextContentY` sits exactly at `cropTopY`, the crop always
            // starts exactly where the previous page's crop ended — no gapH,
            // no overlap.
            // Snapshot each page into memory BEFORE entering the final
            // canvas renderer. Nesting `drawHierarchy(afterScreenUpdates:true)`
            // inside an outer `UIGraphicsImageRenderer.image { }` block can
            // produce black snapshots: the outer context is the current
            // graphics context, and `afterScreenUpdates:true` defers
            // rendering to a screen-update cycle that doesn't reliably
            // complete inside the nested renderer. Symptom was a stitched
            // image whose top pages were solid bg-color/black with only the
            // last page (drawn via the tail-clamp recovery path) showing
            // real content. Decouple the two phases: pass 1 collects page
            // snapshots with no outer graphics context active; pass 2
            // composites the collected snapshots into the final canvas.
            struct PageSlice {
                let snap: UIImage
                let viewportContentY: CGFloat
                let contentStart: CGFloat
                let contentEnd: CGFloat
            }
            var slices: [PageSlice] = []
            var drawnEndY: CGFloat = turnTopY

            /// Snapshot the current cv viewport, fill bg first.
            func snapshotViewport() -> UIImage {
                let pageSize = cv.bounds.size
                let pageFmt = UIGraphicsImageRendererFormat()
                pageFmt.scale = scale; pageFmt.opaque = true
                pageFmt.preferredRange = .standard
                let pr = UIGraphicsImageRenderer(size: pageSize,format: pageFmt)
                return pr.image { snapCtx in
                    bg.setFill()
                    snapCtx.fill(CGRect(origin: .zero,size: pageSize))
                    cv.drawHierarchy(in: CGRect(origin: .zero,size: pageSize),afterScreenUpdates: true)
                }
            }

            chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) BEGIN turnTopY=\(String(format: "%.1f", turnTopY)) turnBottomEdge=\(String(format: "%.1f", turnBottomEdge)) finalCanvas=\(String(format: "%.0fx%.0f", finalSize.width, finalSize.height)) scale=\(scale)")
            do {
                var nextContentY = turnTopY
                var lastActualY: CGFloat = -.greatestFiniteMagnitude
                var pageCount = 0

                while nextContentY<turnBottomEdge && pageCount<200 {
                    pageCount += 1
                    let pageStart = CACurrentMediaTime()

                    // Place nextContentY at the cropTopY line in the viewport.
                    let targetOffset = nextContentY-cropTopY
                    let beforeOffset = cv.contentOffset.y
                    cv.contentOffset = CGPoint(x: 0,y: targetOffset)
                    cv.layoutIfNeeded()
                    cv.layer.displayIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                    self.clearTextSelection(in: cv)

                    // Read back actual offset (UIKit clamps near scroll edges).
                    let actualY = cv.contentOffset.y+cropTopY
                    let clampDelta = (cv.contentOffset.y)-targetOffset
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) nextContentY=\(String(format: "%.1f", nextContentY)) target=(offset=\(String(format: "%.1f", targetOffset))) before=\(String(format: "%.1f", beforeOffset)) after=\(String(format: "%.1f", cv.contentOffset.y)) clampDelta=\(String(format: "%.1f", clampDelta)) actualY=\(String(format: "%.1f", actualY))")
                    if actualY <= lastActualY+0.5 && pageCount>1 {
                        chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) BREAK — actualY=\(String(format: "%.1f", actualY)) <= lastActualY=\(String(format: "%.1f", lastActualY))+0.5 (no progress)")
                        break
                    }
                    lastActualY = actualY

                    let pageEndY = min(turnBottomEdge,actualY+usableH)
                    let sliceH = pageEndY-actualY
                    if sliceH <= 0 {
                        chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) BREAK — sliceH=\(String(format: "%.1f", sliceH)) <= 0")
                        break
                    }

                    let snapStart = CACurrentMediaTime()
                    let snap = snapshotViewport()
                    let snapMs = (CACurrentMediaTime()-snapStart)*1000
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) slice=[\(String(format: "%.1f", actualY)),\(String(format: "%.1f", pageEndY))] sliceH=\(String(format: "%.1f", sliceH)) snap=\(String(format: "%.0fx%.0f", snap.size.width, snap.size.height)) snapTime=\(String(format: "%.1f", snapMs))ms pageTime=\(String(format: "%.1f", (CACurrentMediaTime() - pageStart) * 1000))ms")

                    if pageCount <= 2,let cg = snap.cgImage,
                       let dp = cg.dataProvider,let data = dp.data,
                       let ptr = CFDataGetBytePtr(data) {
                        let bpp = cg.bitsPerPixel/8
                        let bpr = cg.bytesPerRow
                        let sampleY = Int((cropTopY+10)*scale)
                        let sampleX = Int(10*scale)
                        if sampleY<cg.height && sampleX<cg.width {
                            let offset = sampleY*bpr+sampleX*bpp
                            let r = ptr[offset]; let g = ptr[offset+1]; let b = ptr[offset+2]
                            let a = bpp >= 4 ? ptr[offset+3] : 255
                            self.screenshotLogger.info("captureScrolling [DEBUG] page\(pageCount) snap pixel(\(sampleX),\(sampleY)) RGBA=(\(r),\(g),\(b),\(a)) bpp=\(bpp) size=\(cg.width)x\(cg.height) colorSpace=\(String(describing: cg.colorSpace?.name))")
                        }
                    }

                    slices.append(PageSlice(snap: snap,viewportContentY: actualY-cropTopY,
                                            contentStart: actualY,contentEnd: pageEndY))
                    drawnEndY = max(drawnEndY,pageEndY)

                    if pageEndY >= turnBottomEdge { break }
                    nextContentY = actualY+usableH
                }

                // Tail-clamp recovery (see commit 97af7f35): if contentOffset
                // clamping prevented the loop from reaching turnBottomEdge,
                // scroll to maxScrollY and snapshot the missing range.
                if drawnEndY<turnBottomEdge-0.5 {
                    let maxScrollY = max(0,cv.contentSize.height-cv.bounds.height)
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) tail-clamp NEEDED drawnEndY=\(String(format: "%.1f", drawnEndY)) < turnBottomEdge=\(String(format: "%.1f", turnBottomEdge)) maxScrollY=\(String(format: "%.1f", maxScrollY))")
                    cv.contentOffset = CGPoint(x: 0,y: maxScrollY)
                    cv.layoutIfNeeded()
                    cv.layer.displayIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                    self.clearTextSelection(in: cv)

                    let snap = snapshotViewport()
                    let tailContentEnd = min(turnBottomEdge,maxScrollY+cv.bounds.height)
                    slices.append(PageSlice(snap: snap,viewportContentY: maxScrollY,
                                            contentStart: drawnEndY,contentEnd: tailContentEnd))
                    self.screenshotLogger.info("captureScrolling: tail-clamp recovery added [\(Int(drawnEndY)),\(Int(tailContentEnd))] (was missing)")
                    drawnEndY = max(drawnEndY,tailContentEnd)
                }

                self.screenshotLogger.info("captureScrolling: \(pageCount) pages → \(Int(finalSize.width))x\(Int(finalSize.height)) drawnEnd=\(Int(drawnEndY))/turnBottom=\(Int(turnBottomEdge))")
                chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) END pages=\(pageCount) slices=\(slices.count) drawnEnd=\(String(format: "%.1f", drawnEndY)) turnBottom=\(String(format: "%.1f", turnBottomEdge)) coverageGap=\(String(format: "%.1f", turnBottomEdge - drawnEndY))")
                // SLICE-LEVEL DIAGNOSTIC: dump every slice's content
                // start/end + viewport origin. If the symptom is top-blank,
                // the first slice's contentStart should equal turnTopY. If
                // it's > turnTopY, we know the gapH exactly.
                for (i,s) in slices.enumerated() {
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) slice[\(i)] contentStart=\(String(format: "%.1f", s.contentStart)) contentEnd=\(String(format: "%.1f", s.contentEnd)) viewportContentY=\(String(format: "%.1f", s.viewportContentY)) snap=\(String(format: "%.0fx%.0f", s.snap.size.width, s.snap.size.height))")
                }
                if let firstSlice = slices.first {
                    let topGap = firstSlice.contentStart-turnTopY
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) TOP-GAP=\(String(format: "%.1f", topGap)) (first slice content start minus turnTopY; positive = top of turn missing from canvas)")
                }
            }

            // Pass 2: composite the collected page snapshots into the final
            // canvas. All page bitmaps already exist as independent
            // UIImages — no nested drawHierarchy here.
            chatScreenshotLogger.info("[Stage5-Composite] \(ms()) BEGIN finalCanvas=\(String(format: "%.0fx%.0f", finalSize.width, finalSize.height)) sliceCount=\(slices.count)")
            let image = renderer(size: finalSize,format: format,bg: bg) { _ in
                for (i,slice) in slices.enumerated() {
                    let sliceH = slice.contentEnd-slice.contentStart
                    guard sliceH>0,let cg = slice.snap.cgImage else {
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] SKIP sliceH=\(String(format: "%.1f", sliceH)) hasCG=\(slice.snap.cgImage != nil)")
                        continue
                    }
                    let viewportYStart = slice.contentStart-slice.viewportContentY
                    let srcPx = CGRect(
                        x: 0,
                        y: viewportYStart*scale,
                        width: cvWidth*scale,
                        height: sliceH*scale
                    )
                    let dstY = slice.contentStart-turnTopY
                    if let cropped = cg.cropping(to: srcPx) {
                        let dst = CGRect(x: 0,y: dstY,
                                         width: cvWidth,height: sliceH)
                        UIImage(cgImage: cropped,scale: scale,orientation: .up).draw(in: dst)
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] BLIT viewportYStart=\(String(format: "%.1f", viewportYStart)) srcPx=\(String(format: "%.0fx%.0f@%.0f,%.0f", srcPx.width, srcPx.height, srcPx.minX, srcPx.minY)) dstY=\(String(format: "%.1f", dstY)) dstH=\(String(format: "%.1f", sliceH))")
                    } else {
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] CROP FAILED srcPx=\(String(format: "%.0fx%.0f@%.0f,%.0f", srcPx.width, srcPx.height, srcPx.minX, srcPx.minY)) cgSize=\(cg.width)x\(cg.height)")
                    }
                }
            }
            chatScreenshotLogger.info("[Stage5-Composite] \(ms()) END image=\(String(format: "%.0fx%.0f", image.size.width, image.size.height)) scale=\(image.scale)")

            cv.overrideUserInterfaceStyle = savedOverride
            cv.backgroundColor = savedCvBg
            cv.superview?.backgroundColor = savedParentBg

            // DEBUG: sample final image pixel
            if let cg = image.cgImage,
               let dp = cg.dataProvider,let data = dp.data,
               let ptr = CFDataGetBytePtr(data) {
                let bpp = cg.bitsPerPixel/8
                let bpr = cg.bytesPerRow
                // Sample at (10, 10) — should be the background
                let offset = 10*bpr+10*bpp
                let r = ptr[offset]; let g = ptr[offset+1]; let b = ptr[offset+2]
                let a = bpp >= 4 ? ptr[offset+3] : 255
                screenshotLogger.info("captureScrolling [DEBUG] FINAL image pixel(10,10) RGBA=(\(r),\(g),\(b),\(a)) bpp=\(bpp) size=\(cg.width)x\(cg.height)")
            }

            cv.contentOffset = savedOffset
            cv.layoutIfNeeded()
            self.scrollMode = savedScrollMode
            self.clampAfterSessionLoad = savedClampAfterSessionLoad
            chatScreenshotLogger.info("[Stage6-Exit] \(ms()) restored cv.contentOffset=\(String(format: "%.1f", savedOffset.y)) scrollMode=\(savedScrollMode == .autoScrolling ? "auto" : "browse") returning image=\(String(format: "%.0fx%.0f", image.size.width, image.size.height))")

            return image
        }

        func renderer(size: CGSize,format: UIGraphicsImageRendererFormat,bg: UIColor,
                              actions: @escaping (UIGraphicsImageRendererContext) -> Void) -> UIImage {
            let r = UIGraphicsImageRenderer(size: size,format: format)
            return r.image { ctx in
                bg.setFill()
                ctx.fill(CGRect(origin: .zero,size: size))
                actions(ctx)
            }
        }

        // MARK: - UICollectionViewDataSourcePrefetching

        public func collectionView(_ collectionView: UICollectionView,prefetchItemsAt indexPaths: [IndexPath]) {
            guard let vm,let layout = viewController?.messageListLayout else { return }
            // Items below come from prevSnapshotIds (snapshot-locked) — the
            // messages they're resolved against must be the SAME locked array,
            // or a concurrent loadSession() swap makes every lookup miss and
            // estimates collapse to the 44pt fallback.
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth
            for indexPath in indexPaths {
                let index = indexPath.item
                // Skip if we already have a measured or precalculated height.
                // estimateItemHeight calls NSAttributedString.boundingRect which invokes
                // CoreText font shaping (GSUB lookups) — for complex markdown blocks this
                // can take hundreds of ms per cell and accumulate into a watchdog crash
                // when the user scrolls back through long history. See 3a9fb98 for the
                // matching configureCell guard.
                guard !layout.hasMeasuredHeight(at: index),
                      !layout.hasPrecalcHeight(at: index) else { continue }
                guard index<prevSnapshotIds.count else { continue }
                let item = prevSnapshotIds[index]
                let est = Self.estimateItemHeight(item,messages: messages,width: width)
                layout.setEstimatedHeight(est,at: index)
            }
        }

        // MARK: - UIScrollViewDelegate

        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            AppLogger(category: "ChatList.Scroll").info("[Scroll][willBeginDragging] offset=\(String(format: "%.0f", scrollView.contentOffset.y)) contentSize=\(String(format: "%.0f", scrollView.contentSize.height)) visibleCells=\(viewController?.collectionView?.visibleCells.count ?? -1)")
            #if DEBUG
            // [DecelDisplayLink] Safety: if the user grabs again mid-decel, stop
            // the previous link so it doesn't keep ticking under the new gesture.
            stopDecelDisplayLink()
            #endif
            scrollMode = .userBrowsing
            // Cancel session-load clamp immediately — user has started interacting.
            clampAfterSessionLoad = false
            // A manual drag breaks the up-button's turn-walk chain: the next tap
            // should re-anchorY to wherever the user landed, not continue the old
            // sequence.
            lastJumpedUserId = nil
            viewController?.messageListLayout?.deferSelfSizing = true
            vm?.setStreamingUIUpdatesSuspended(true)
        }

        public func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            // [Decel] Fires the instant the finger lifts and UIKit has
            // projected where the deceleration will land. Logs the launch
            // velocity + projected target so the upcoming decel can be
            // correlated to the content region it's about to render.
            decelTargetOffset = targetContentOffset.pointee.y
            #if DEBUG
            AppLogger(category: "ChatList.Decel").info("[Decel][willEndDragging] vy=\(String(format: "%.0f", velocity.y))pt/s offset=\(String(format: "%.0f", scrollView.contentOffset.y)) → target=\(String(format: "%.0f", decelTargetOffset)) projDist=\(String(format: "%.0f", decelTargetOffset - scrollView.contentOffset.y)) cs=\(String(format: "%.0f", scrollView.contentSize.height))")
            #endif
        }

        public func scrollViewDidEndDragging(_ scrollView: UIScrollView,willDecelerate decelerate: Bool) {
            if !decelerate {
                settleAfterInteraction(scrollView)
            }
        }

        public func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
            // [Decel] DECELERATION START — the marker the analysis hangs
            // offY. Every subsequent slow frame is logged as "+Xms into decel".
            let now = CACurrentMediaTime()
            decelStartTime = now
            decelLastFrameTime = now
            decelStartOffset = scrollView.contentOffset.y
            decelFrameCount = 0
            decelSlowFrameCount = 0
            #if DEBUG
            let visibleN = viewController?.collectionView?.visibleCells.count ?? -1
            AppLogger(category: "ChatList.Decel").info("[Decel][BEGIN] offset=\(String(format: "%.0f", decelStartOffset)) target=\(String(format: "%.0f", decelTargetOffset)) decelDist=\(String(format: "%.0f", decelTargetOffset - decelStartOffset)) visibleCells=\(visibleN) deferSelfSizing=\((viewController?.messageListLayout?.deferSelfSizing ?? false) ? 1 : 0)")
            // [DecelDisplayLink] Start the real-frame-rate meter only for this
            // decel phase. Drops/summary go to the log; CADisplayLink is removed
            // in scrollViewDidEndDecelerating below.
            startDecelDisplayLink()
            #endif
        }

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            // [Decel] DECELERATION END — summarize the phase: total
            // duration, frames, how many were slow (dropped), final offset.
            if decelStartTime>0 {
                #if DEBUG
                let dur = (CACurrentMediaTime()-decelStartTime)*1000
                AppLogger(category: "ChatList.Decel").info("[Decel][END] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelFrameCount) slowFrames=\(self.decelSlowFrameCount) offset \(String(format: "%.0f→%.0f", self.decelStartOffset, scrollView.contentOffset.y)) (target was \(String(format: "%.0f", self.decelTargetOffset)))")
                // [DecelDisplayLink] Print the REAL frame-rate summary for this
                // decel and stop the link. If actualFps≈vsync and drops=0 the
                // visual "jitter" wasn't a dropped frame at all.
                logDecelDisplayLinkSummary()
                stopDecelDisplayLink()
                #endif
                decelStartTime = 0
            }
            DispatchQueue.main.async { [weak self] in
                self?.settleAfterInteraction(scrollView)
            }
        }

        /// [Decel] Called from scrollViewDidScroll. While decelerating,
        /// measures the gapH since the previous frame; a gapH above the threshold
        /// is a dropped/janky frame and gets logged with how far into the decel
        /// it happened, the current offset/scroll direction, and how many cells
        /// are on screen (heavy cells = expensive sizeThatFits). This is the
        /// "which stage of the decel started the costly render" signal.
        func logDecelFrameIfSlow(_ scrollView: UIScrollView) {
            #if DEBUG
            guard decelStartTime>0,scrollView.isDecelerating else { return }
            let now = CACurrentMediaTime()
            let gapH = now-decelLastFrameTime
            decelLastFrameTime = now
            decelFrameCount += 1
            guard gapH>decelSlowFrameThreshold else { return }
            decelSlowFrameCount += 1
            let sinceStart = (now-decelStartTime)*1000
            let offY = scrollView.contentOffset.y
            let dir = offY >= decelStartOffset ? "↓" : "↑"
            let visibleN = viewController?.collectionView?.visibleCells.count ?? -1
            AppLogger(category: "ChatList.Decel").warning("[Decel][SLOW-FRAME] +\(String(format: "%.0f", sinceStart))ms into decel gapH=\(String(format: "%.0f", gapH * 1000))ms offset=\(String(format: "%.0f", offY))\(dir) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - offY)) visibleCells=\(visibleN) frame#\(self.decelFrameCount)")
            #endif
        }

        // MARK: - [DecelDisplayLink] CADisplayLink frame meter (DEBUG only)
        //
        // The existing `[Decel] SLOW-FRAME` log measures the wall-clock gapH
        // between consecutive `scrollViewDidScroll` callbacks. That is NOT the
        // same as a real dropped frame: during the tail of a decel UIKit stops
        // calling scrollViewDidScroll for the frames where contentOffset doesn't
        // visually change (snap-to-target), so a 250ms "gapH" can happen with the
        // main thread completely idle and CADisplayLink ticking 16.7ms steady —
        // a false positive for jank. Run a CADisplayLink only during the decel
        // and measure actual frame intervals; >1.5× the expected vsync interval
        // is a real dropped frame.
        #if DEBUG

        @objc private func decelDisplayLinkTick(_ link: CADisplayLink) {
            // The first tick has no prior timestamp — establish the baseline + expected interval.
            if decelDLLastTimestamp == 0 {
                decelDLLastTimestamp = link.timestamp
                decelDLExpectedMs = (link.targetTimestamp-link.timestamp)*1000
                return
            }
            let gapMs = (link.timestamp-decelDLLastTimestamp)*1000
            decelDLLastTimestamp = link.timestamp
            decelDLFrames += 1
            if gapMs<decelDLMinGapMs { decelDLMinGapMs = gapMs }
            if gapMs>decelDLMaxGapMs { decelDLMaxGapMs = gapMs }
            // A real dropped frame: gapH exceeds 1.5× the expected vsync interval.
            // At 120Hz expected≈8.33ms → threshold≈12.5ms; at 60Hz ≈16.67ms → 25ms.
            let dropThreshold = decelDLExpectedMs*1.5
            if gapMs>dropThreshold {
                decelDLDrops += 1
                let cv = viewController?.collectionView
                let offY = cv?.contentOffset.y ?? 0
                let sinceStart = (CACurrentMediaTime()-decelStartTime)*1000
                let dropped = Int((gapMs/decelDLExpectedMs).rounded())-1
                AppLogger(category: "ChatList.Decel").warning("[DecelDisplayLink][DROP] +\(String(format: "%.0f", sinceStart))ms into decel gapH=\(String(format: "%.1f", gapMs))ms (expected \(String(format: "%.1f", self.decelDLExpectedMs))ms, ~\(dropped) frame(s) dropped) offset=\(String(format: "%.0f", offY)) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - offY)) frame#\(self.decelDLFrames)")
            }
        }

        func startDecelDisplayLink() {
            stopDecelDisplayLink()
            decelDLLastTimestamp = 0
            decelDLFrames = 0
            decelDLDrops = 0
            decelDLMinGapMs = .infinity
            decelDLMaxGapMs = 0
            let link = CADisplayLink(target: self,selector: #selector(decelDisplayLinkTick(_:)))
            link.add(to: .main,forMode: .common)
            decelDisplayLink = link
        }

        func stopDecelDisplayLink() {
            decelDisplayLink?.invalidate()
            decelDisplayLink = nil
        }

        func logDecelDisplayLinkSummary() {
            guard decelDLFrames>0 else { return }
            let dur = (CACurrentMediaTime()-decelStartTime)*1000
            let actualFps = decelDLFrames>0 ? Double(decelDLFrames)/(dur/1000) : 0
            let minGap = decelDLMinGapMs.isFinite ? decelDLMinGapMs : 0
            AppLogger(category: "ChatList.Decel").info("[DecelDisplayLink][SUMMARY] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelDLFrames) drops=\(self.decelDLDrops) actualFps=\(String(format: "%.1f", actualFps)) gapRange=[\(String(format: "%.1f", minGap))..\(String(format: "%.1f", self.decelDLMaxGapMs))]ms expected=\(String(format: "%.1f", self.decelDLExpectedMs))ms")
        }
        #endif

        /// Track last logged offset to detect jumps after settle.

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // [Decel] Detect dropped frames during the deceleration phase
            // (cheap: early-returns unless decelerating + frame gapH exceeded).
            logDecelFrameIfSlow(scrollView)
            #if DEBUG
            // Per-frame offset/contentSize sample —
            // lets the pulled trace reconstruct exactly when visible content
            // shifted vs when the offset moved (jitter = the two disagreeing).
            ScrollMetricsRecorder.shared.record(
                kind: "scroll", a: scrollView.contentOffset.y,
                b: scrollView.contentSize.height,
                pos: scrollView.isDecelerating ? "decel" : (scrollView.isTracking ? "drag" : "idle"),
                offset: scrollView.contentOffset.y)
            #endif
            if let vm {
                // IMPORTANT: only write when the value actually changes.
                // `isNearBottom` is `@Published`, and every write broadcasts
                // `objectWillChange` to every SwiftUI view observing the VM —
                // triggering a full AttributeGraph invalidation+re-evaluation
                // pass on the SwiftUI update thread. On iPhone 8 this was
                // burning 100% of one CPU core every scroll frame.
                let nbFlag = isNearBottom()
                if vm.isNearBottom != nbFlag {
                    #if DEBUG
                    // Diagnostics: record every isNearBottom TRANSITION with the
                    // scroll position and the user-turn the viewport is in, plus
                    // the resulting up/down-button visibility (!messages.empty &&
                    // !isNearBottom). Only fires on change, so it stays offY the
                    // per-frame hot path. ScrollMetricsRecorder is DEBUG-only.
                    let turn = currentViewportUserTurn()
                    ScrollMetricsRecorder.shared.record(kind: "nbChange",
                        idx: turn.index,a: nbFlag ? 1 : 0,b: Double(turn.total),
                        pos: "buttonsVisible=\(!vm.messages.isEmpty && !nbFlag)",
                        offset: Double(scrollView.contentOffset.y),
                        note: Self.nbDump(viewController?.collectionView))
                    #endif
                    vm.isNearBottom = nbFlag
                }
                let atTop = isAtContentTop()
                if vm.isAtFirstTurn != atTop { vm.isAtFirstTurn = atTop }
                vm.contentOffsetYSignal.send(scrollView.contentOffset.y)
            }
        }

        // [Decel] Deceleration-phase instrumentation. Lets us pin a
        // dropped frame to "Xms into the decel, at offset Y" so the
        // scroll-jank trace's micro-hangs can be aligned to the exact moment
        // and content region where the costly render started.
        /// A frame gapH above this (seconds) during deceleration is a dropped
        /// frame worth logging. ~32ms ≈ two missed frames at 60Hz / several at
        /// 120Hz — low enough to catch the jitter, high enough to stay quiet
        /// on smooth scrolls.

        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isAnimatingScrollToBottom = false
            // Final clamp: ensure offset doesn't exceed actual content bounds
            // after the animation completes (contentSize may have changed mid-flight).
            guard let cv = viewController?.collectionView else { return }
            let maxOff = max(0,cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom)
            if cv.contentOffset.y>maxOff {
                cv.contentOffset.y = maxOff
            }
        }

        public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            scrollMode = .userBrowsing
        }

        func settleAfterInteraction(_ scrollView: UIScrollView) {
            // Re-acquire auto-scroll only when the user settled essentially at
            // the bottom (tight threshold), not merely "near" it. This stops
            // small trackpad scrolls on iPad from snapping back to the bottom
            // and jittering.
            let atBottom = isWithinBottom(reacquireAutoScrollThreshold)
            let nearBottom = isNearBottom()
            if atBottom {
                scrollMode = .autoScrolling
            }
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else { return }

            _ = nearBottom
            // Re-enable self-sizing so future layout passes use real heights.
            layout.deferSelfSizing = false

            let savedOffset = cv.contentOffset.y
            flushingNow = true
            layout.applyDeferredHeights()

            layout.suppressContentOffsetAdjustment = true
            layout.invalidateLayout()
            layout.suppressContentOffsetAdjustment = false
            flushingNow = false

            // Restore offset
            if scrollMode == .userBrowsing {
                cv.contentOffset.y = savedOffset
            }

            vm?.setStreamingUIUpdatesSuspended(false)

            if pendingSnapshotFlag {
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingSnapshotIfNeeded(caller: "settle")
                }
            }

            // 打开「settle 后内容收缩主动 clamp」窗口（见 contentSize KVO 分支）。
            settleJustFinished = true
            DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { [weak self] in
                self?.settleJustFinished = false
            }
        }

}
