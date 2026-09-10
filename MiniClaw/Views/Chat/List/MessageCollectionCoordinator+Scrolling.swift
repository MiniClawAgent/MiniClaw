import SwiftUI
import UIKit
import Combine
import Foundation

extension MessageCollectionView.Coordinator {

        ///

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

        public func isAtContentTop(_ threshold: CGFloat = 8) -> Bool {
            guard let cv = viewController?.collectionView else { return false }
            return cv.contentOffset.y <= -cv.adjustedContentInset.top+threshold
        }

        public func isWithinBottom(_ threshold: CGFloat) -> Bool {
            guard let cv = viewController?.collectionView else { return true }
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

        /// - First tap: scroll to the user message of the turn the viewport is
        /// currently in (nearest role==.user at or above the top visible item).
        /// - Repeated taps (no intervening drag / new message / etc): each tap
        /// goes to the PREVIOUS turn's user message.
        /// - At the first turn already: stay put, no overscroll.
        public func scrollToPreviousUserTurn(animated: Bool = true) {
            guard let cv = viewController?.collectionView,
                  let vm,let ds = dataSource else { return }
            let msgs = vm.messages
            guard !msgs.isEmpty else { return }

            let userIds = msgs.compactMap { $0.role == .user ? $0.id : nil }
            guard !userIds.isEmpty else {
                if cv.numberOfSections>0,cv.numberOfItems(inSection: 0)>0 {
                    cv.scrollToItem(at: IndexPath(item: 0,section: 0),at: .top,animated: animated)
                }
                return
            }

            // anchorY).
            let topItemMsgId: UUID? = cv.indexPathsForVisibleItems.min()
                .flatMap { ds.itemIdentifier(for: $0) }
                .flatMap { Self.messageId(of: $0) }
            let topMsgIdx = topItemMsgId.flatMap { id in msgs.firstIndex(where: { $0.id == id }) } ?? 0
            let currentAnchor = msgs[...topMsgIdx].reversed().first(where: { $0.role == .user })?.id ?? userIds.first!

            // Decide the target: if the viewport is already at the anchorY we last
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
            #if DEBUG
            let nbNow = isNearBottom()
            ScrollMetricsRecorder.shared.record(kind: "prevUserTurn", idx: tgtTurn,
                a: Double(curTurn),b: Double(userIds.count),
                pos: "call buttonsVisible=\(!msgs.isEmpty && !nbNow)",
                offset: Double(cv.contentOffset.y),note: Self.nbDump(cv))
            #endif
            cv.scrollToItem(at: ip,at: .top,animated: animated)
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

        static func nbDump(_ cv: UICollectionView?) -> String {
            guard let cv else { return "cv=nil→isWithinBottom RETURNS TRUE" }
            let maxOff = cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom
            let diff = maxOff-cv.contentOffset.y
            return "offY=\(String(format: "%.0f", cv.contentOffset.y)) cs=\(String(format: "%.0f", cv.contentSize.height)) bh=\(String(format: "%.0f", cv.bounds.height)) adjBot=\(String(format: "%.0f", cv.adjustedContentInset.bottom)) maxOff=\(String(format: "%.0f", maxOff)) diff=\(String(format: "%.0f", diff))"
        }

        /// Base contentInset.top (without sub-viewport overflowH compensation).
        public var baseContentInsetTop: CGFloat {
            if #available(iOS 26,*) { return 0 } else { return 8 }
        }

        /// contentInset.bottom — it reads this base and adds overflowH.

        ///
        /// Compensate by inflating `contentInset.bottom` by the overflowH
        ///
        /// `baseBottomInset + (needs ? overflowH : 0)`.
        ///
        @discardableResult
        public func applySubViewportCompensation(caller: String = "?", forceRelax: Bool = false) -> Bool {
            guard let cv = viewController?.collectionView else { return false }
            // [2026-09-09 NaN/异常值治理] CV 尚未完成布局时 bounds.height 为 0：
            // visibleH = 0 - safeAreaTop - bottomInsetBase 变成**负数** → overflowH
            // 虚增一整个视口高度 → 单调补偿把 bottom inset 抬到数千 pt；下一帧
            // bounds 就绪后与 inflated inset 相减得到大负数/非有限值，是「会话首帧、
            // 键盘弹出收起」时 CoreGraphics NaN 告警成片的直接来源。
            // 布局未就绪就整体跳过——补偿每帧重算且幂等，下一帧自然会补上。
            guard cv.bounds.height > 1 else { return false }
            let safeAreaTop = cv.safeAreaInsets.top
            let bottomInsetBase = baseBottomInset
            let visibleH = cv.bounds.height-safeAreaTop-bottomInsetBase
            let overflowH = cv.contentSize.height-visibleH
            // contentSize - bounds + adjustedContentInset.top + adjustedContentInset.bottom
            let rawMaxOff = cv.contentSize.height-cv.bounds.height+bottomInsetBase+safeAreaTop
            let needsCompensation = overflowH>0 && rawMaxOff <= 0
            let prevBottomInset = cv.contentInset.bottom

            // grows token-by-token. The naive `desired = needs ? base+overflowH
            // mid-screen back to the bottom by ~overflowH pt (observed: 114pt
            //
            let priorInflation = max(0,prevBottomInset-bottomInsetBase)
            let canSafelyRelax = rawMaxOff >= priorInflation-0.5
            let desiredBottomInset: CGFloat
            if needsCompensation {
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
            if scrollMode == .autoScrolling {
                //
                let pinBottomInset = bottomInsetBase+cv.safeAreaInsets.bottom
                let rawTarget = cv.contentSize.height-cv.bounds.height+pinBottomInset
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
                DispatchQueue.main.async { [weak self] in self?.syncScrollFlags() }
            } else {
                cv.contentOffset = target
                syncScrollFlags()
            }
        }

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

        /// Locate the UITextView descendant
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

        @MainActor
        func clearTextSelection(in cv: UICollectionView) {
            cv.window?.endEditing(true)
            UIMenuController.shared.hideMenu()

            func walk(_ view: UIView) {
                if let tv = view as? UITextView {
                    if tv.isFirstResponder { tv.resignFirstResponder() }
                    if let start = tv.position(from: tv.beginningOfDocument,offset: 0) {
                        tv.selectedTextRange = tv.textRange(from: start,to: start)
                    }
                    tv.selectedTextRange = nil
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(cv)
        }

        ///
        @MainActor
        public func captureScrollingTurnScreenshot(userMessageId: UUID,assistantMessageId: UUID?) -> UIImage? {
            // All ChatScreenshot logs share
            // this monotonic anchorY so users can read elapsed-ms deltas
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

            let savedOffset = cv.contentOffset
            // Suspend the auto-scroll
            let savedScrollMode = self.scrollMode
            let savedClampAfterSessionLoad = self.clampAfterSessionLoad
            self.scrollMode = .userBrowsing
            self.clampAfterSessionLoad = false
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) userMsg=\(userMessageId.uuidString.prefix(8)) startIdx=\(startIdx) endIdx=\(endIdx) totalItems=\(items.count) scrollMode=\(savedScrollMode == .autoScrolling ? "auto" : "browse")→browse(suspendedFlag) clampAfterSessionLoad=\(savedClampAfterSessionLoad)→false")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.contentOffset=(\(String(format: "%.1f", savedOffset.x)),\(String(format: "%.1f", savedOffset.y)))")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.bounds=\(String(format: "%.0fx%.0f", cv.bounds.width, cv.bounds.height)) cv.contentSize=\(String(format: "%.0fx%.0f", cv.contentSize.width, cv.contentSize.height))")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.adjustedContentInset=(t=\(String(format: "%.1f", cv.adjustedContentInset.top)) b=\(String(format: "%.1f", cv.adjustedContentInset.bottom)))")
            // user-message cell was offY-screen at long-press time.
            let entryFirstFrame = cv.layoutAttributesForItem(at: IndexPath(item: startIdx,section: 0))?.frame
            let entryLastFrame = cv.layoutAttributesForItem(at: IndexPath(item: endIdx,section: 0))?.frame
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) PRE-warm firstFrame=\(entryFirstFrame.map { String(format: "y=%.1f h=%.1f", $0.minY, $0.height) } ?? "nil") lastFrame=\(entryLastFrame.map { String(format: "y=%.1f h=%.1f", $0.minY, $0.height) } ?? "nil")")
            let visibleRange: ClosedRange<CGFloat>? = {
                let bounds = cv.bounds
                return savedOffset.y...(savedOffset.y+bounds.height)
            }()
            if let f = entryFirstFrame,let vr = visibleRange {
                let onScreen = f.maxY >= vr.lowerBound && f.minY <= vr.upperBound
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) userMessage visibleAtLongPress=\(onScreen) frameRange=[\(String(format: "%.1f", f.minY)),\(String(format: "%.1f", f.maxY))] viewportRange=[\(String(format: "%.1f", vr.lowerBound)),\(String(format: "%.1f", vr.upperBound))]")
            }
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
            // offY the final canvas.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            let viewportH = cv.bounds.height
            let bottomMask = max(0,cv.adjustedContentInset.bottom)
            let topMask = max(0,cv.adjustedContentInset.top)
            let navSafetyGap: CGFloat = 10
            let cropTopY = topMask+navSafetyGap
            let usableH = max(1,viewportH-cropTopY-bottomMask)

            chatScreenshotLogger.info("[Stage2-Warming] \(ms()) BEGIN viewportH=\(String(format: "%.1f", viewportH)) topMask=\(String(format: "%.1f", topMask)) bottomMask=\(String(format: "%.1f", bottomMask)) cropTopY=\(String(format: "%.1f", cropTopY)) usableH=\(String(format: "%.1f", usableH))")
            do {
                let beforeStep1 = cv.contentOffset.y
                cv.scrollToItem(at: IndexPath(item: startIdx,section: 0),at: .top,animated: false)
                cv.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                let afterStep1 = cv.contentOffset.y
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) STEP1 scrollToItem(startIdx) offset: \(String(format: "%.1f", beforeStep1)) → \(String(format: "%.1f", afterStep1)) Δ=\(String(format: "%.1f", afterStep1 - beforeStep1))")

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
            // offY (= bottom of the turn) rather than from the user
            let beforeReAnchor = cv.contentOffset.y
            cv.scrollToItem(at: IndexPath(item: startIdx,section: 0),at: .top,animated: false)
            cv.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) scrollToItem(startIdx, .top) offset: \(String(format: "%.1f", beforeReAnchor)) → \(String(format: "%.1f", cv.contentOffset.y)) Δ=\(String(format: "%.1f", cv.contentOffset.y - beforeReAnchor))")

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
            // a scroll has placed nextContentY (= turnTopY) at the cropTopY
            // line. If contentOffset.y is far offY from (turnTopY - cropTopY),
            let expectedOffsetY = turnTopY-cropTopY
            let offsetDelta = cv.contentOffset.y-expectedOffsetY
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) ALIGN cv.contentOffset.y=\(String(format: "%.1f", cv.contentOffset.y)) expected=(turnTopY - cropTopY)=\(String(format: "%.1f", expectedOffsetY)) DELTA=\(String(format: "%.1f", offsetDelta)) (positive=scrolled past top)")
            // Diagnostic dump of every
            let maxOff = max(0,cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom)
            let nearBottom = (maxOff-cv.contentOffset.y)<60
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) PIN-STATE scrollMode=\(self.scrollMode == .autoScrolling ? "auto" : "browse") clampAfterSessionLoad=\(self.clampAfterSessionLoad) isAnimatingScrollToBottom=\(self.isAnimatingScrollToBottom) maxOff=\(String(format: "%.1f", maxOff)) currentOffset.y=\(String(format: "%.1f", cv.contentOffset.y)) nearBottom=\(nearBottom) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) dragging=\(cv.isDragging) GRs=\((cv.gestureRecognizers ?? []).map { "\(type(of: $0)):\($0.state.rawValue)" }.joined(separator: ","))")
            // Probe each scroll write
            if abs(offsetDelta)>1 {
                self.clearTextSelection(in: cv)
                let savedGRStates: [(UIGestureRecognizer,Bool)] = (cv.gestureRecognizers ?? []).map { ($0,$0.isEnabled) }
                for (gr,_) in savedGRStates { gr.isEnabled = false }

                let pA0 = cv.contentOffset.y
                cv.setContentOffset(CGPoint(x: 0,y: max(0,expectedOffsetY)),animated: false)
                let pA1 = cv.contentOffset.y // immediate readback (pre-runloop)
                cv.layoutIfNeeded()
                let pA2 = cv.contentOffset.y // after layoutIfNeeded
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                let pA3 = cv.contentOffset.y // after one runloop hop — if pA3 != pA2 someone wrote it back

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

            let currentStyle = cv.traitCollection.userInterfaceStyle
            let windowStyle = cv.window?.traitCollection.userInterfaceStyle
            let windowOverride = cv.window?.overrideUserInterfaceStyle
            let cvOverride = cv.overrideUserInterfaceStyle
            screenshotLogger.info("captureScrolling [DEBUG] cv.traitCollection.userInterfaceStyle=\(currentStyle.rawValue) (0=unspec,1=light,2=dark)")
            screenshotLogger.info("captureScrolling [DEBUG] window.traitCollection.userInterfaceStyle=\(windowStyle?.rawValue ?? -1)")
            screenshotLogger.info("captureScrolling [DEBUG] window.overrideUserInterfaceStyle=\(windowOverride?.rawValue ?? -1)")
            screenshotLogger.info("captureScrolling [DEBUG] cv.overrideUserInterfaceStyle=\(cvOverride.rawValue)")
            screenshotLogger.info("captureScrolling [DEBUG] cv.backgroundColor=\(String(describing: cv.backgroundColor))")

            var sv = cv.superview
            var depth = 0
            while let v = sv,depth<5 {
                let resolvedBg = v.backgroundColor?.resolvedColor(with: v.traitCollection)
                screenshotLogger.info("captureScrolling [DEBUG] superview[\(depth)] \(type(of: v)) bg=\(String(describing: resolvedBg)) overrideStyle=\(v.overrideUserInterfaceStyle.rawValue)")
                sv = v.superview
                depth += 1
            }

            let bgResolved = UIColor.systemBackground.resolvedColor(with: cv.traitCollection)
            var bgR: CGFloat = 0; var bgG: CGFloat = 0; var bgB: CGFloat = 0; var bgA: CGFloat = 0
            bgResolved.getRed(&bgR,green: &bgG,blue: &bgB,alpha: &bgA)
            screenshotLogger.info("captureScrolling [DEBUG] resolved systemBackground RGBA=(\(bgR),\(bgG),\(bgB),\(bgA))")

            let savedOverride = cv.overrideUserInterfaceStyle
            cv.overrideUserInterfaceStyle = currentStyle == .dark ? .dark : .light

            let savedCvBg = cv.backgroundColor
            let savedParentBg = cv.superview?.backgroundColor
            cv.backgroundColor = bgResolved
            cv.superview?.backgroundColor = bgResolved

            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            let finalSize = CGSize(width: cvWidth,height: totalH)
            let bg = bgResolved

            // 1. Scroll so `nextContentY` lands at the `cropTopY` line
            // (= topMask + navSafetyGap from the viewport top).
            // 2. Snapshot the full cv bounds.
            // 3. Crop the snapshot to [cropTopY, cropTopY + sliceH].
            // 4. Blit the crop into the final canvas at dstY.
            // 5. Advance by `usableH`.
            //
            // `cropTopY` is the y-coordinate inside the viewport where the
            // `nextContentY` sits exactly at `cropTopY`, the crop always
            // starts exactly where the previous page's crop ended — no gapH,
            struct PageSlice {
                let snap: UIImage
                let viewportContentY: CGFloat
                let contentStart: CGFloat
                let contentEnd: CGFloat
            }
            var slices: [PageSlice] = []
            var drawnEndY: CGFloat = turnTopY

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

                // clamping prevented the loop from reaching turnBottomEdge,
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
                // it's > turnTopY, we know the gapH exactly.
                for (i,s) in slices.enumerated() {
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) slice[\(i)] contentStart=\(String(format: "%.1f", s.contentStart)) contentEnd=\(String(format: "%.1f", s.contentEnd)) viewportContentY=\(String(format: "%.1f", s.viewportContentY)) snap=\(String(format: "%.0fx%.0f", s.snap.size.width, s.snap.size.height))")
                }
                if let firstSlice = slices.first {
                    let topGap = firstSlice.contentStart-turnTopY
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) TOP-GAP=\(String(format: "%.1f", topGap)) (first slice content start minus turnTopY; positive = top of turn missing from canvas)")
                }
            }

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

            if let cg = image.cgImage,
               let dp = cg.dataProvider,let data = dp.data,
               let ptr = CFDataGetBytePtr(data) {
                let bpp = cg.bitsPerPixel/8
                let bpr = cg.bytesPerRow
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

        public func collectionView(_ collectionView: UICollectionView,prefetchItemsAt indexPaths: [IndexPath]) {
            guard let vm,let layout = viewController?.messageListLayout else { return }
            // Items below come from prevSnapshotIds (snapshot-locked) — the
            // estimates collapse to the 44pt fallback.
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth
            for indexPath in indexPaths {
                let index = indexPath.item
                guard !layout.hasMeasuredHeight(at: index),
                      !layout.hasPrecalcHeight(at: index) else { continue }
                guard index<prevSnapshotIds.count else { continue }
                let item = prevSnapshotIds[index]
                let est = Self.estimateItemHeight(item,messages: messages,width: width)
                layout.setEstimatedHeight(est,at: index)
            }
        }

        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // [Scroll][willBeginDragging] 逐次日志已删（每次拖动一条、纯偏移陈述）；
            // 滚动诊断由 ScrollStall / Settle / ChatList.CellMetrics 的异常路径日志承载。
            #if DEBUG
            stopDecelDisplayLink()
            #endif
            scrollMode = .userBrowsing
            clampAfterSessionLoad = false
            // should re-anchorY to wherever the user landed, not continue the old
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
            startDecelDisplayLink()
            #endif
        }

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            // [Decel] DECELERATION END — summarize the phase: total
            if decelStartTime>0 {
                #if DEBUG
                let dur = (CACurrentMediaTime()-decelStartTime)*1000
                AppLogger(category: "ChatList.Decel").info("[Decel][END] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelFrameCount) slowFrames=\(self.decelSlowFrameCount) offset \(String(format: "%.0f→%.0f", self.decelStartOffset, scrollView.contentOffset.y)) (target was \(String(format: "%.0f", self.decelTargetOffset)))")
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

        //
        // The existing `[Decel] SLOW-FRAME` log measures the wall-clock gapH
        // visually change (snap-to-target), so a 250ms "gapH" can happen with the
        #if DEBUG

        @objc private func decelDisplayLinkTick(_ link: CADisplayLink) {
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

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // [Decel] Detect dropped frames during the deceleration phase
            // (cheap: early-returns unless decelerating + frame gapH exceeded).
            logDecelFrameIfSlow(scrollView)
            #if DEBUG
            // Per-frame offset/contentSize sample —
            ScrollMetricsRecorder.shared.record(
                kind: "scroll", a: scrollView.contentOffset.y,
                b: scrollView.contentSize.height,
                pos: scrollView.isDecelerating ? "decel" : (scrollView.isTracking ? "drag" : "idle"),
                offset: scrollView.contentOffset.y)
            #endif
            if let vm {
                let nbFlag = isNearBottom()
                if vm.isNearBottom != nbFlag {
                    #if DEBUG
                    // !isNearBottom). Only fires on change, so it stays offY the
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
        /// A frame gapH above this (seconds) during deceleration is a dropped

        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isAnimatingScrollToBottom = false
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
            // and jittering.
            let atBottom = isWithinBottom(reacquireAutoScrollThreshold)
            let nearBottom = isNearBottom()
            if atBottom {
                scrollMode = .autoScrolling
            }
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else { return }

            _ = nearBottom
            layout.deferSelfSizing = false

            let savedOffset = cv.contentOffset.y
            flushingNow = true
            layout.applyDeferredHeights()

            layout.suppressContentOffsetAdjustment = true
            layout.invalidateLayout()
            layout.suppressContentOffsetAdjustment = false
            flushingNow = false

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
