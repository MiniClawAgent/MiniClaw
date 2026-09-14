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

        /// 滚到指定消息的**首行**（`at: .top`）。
        ///
        /// [2026-09-13 补读路径] 此前 `AppState.scrollToMessageID` 只有**写入点**
        /// （`HomeView` 搜索结果点击）和**清空点**（`ChatView.onAppear`）——全库无读取点，
        /// 列表侧也从没有"滚到某条消息"的能力（只有贴底 / 上一轮）⇒ 点搜索结果只进会话、不定位。
        /// 本函数补上这条能力，并作为该语义的**唯一入口**（与 `scrollToBottomNow`、
        /// `scrollToPreviousUserTurn` 并列的第三个滚动落点）。
        ///
        /// 定位失败**必须显式**（禁静默降级）：目标不在当前快照里就记一条日志后原样返回。
        /// 一条消息可能横跨多行（assistant = header + N 个块 + footer），故取**首个**归属它的行。
        public func scrollToMessage(id: UUID,animated: Bool = true) {
            guard let cv = viewController?.collectionView,let ds = dataSource else { return }
            let items = ds.snapshot().itemIdentifiers
            guard let firstIdx = items.firstIndex(where: { $0.messageId == id }) else {
                AppLogger.shared.info("[Scroll][toMessage] ABORT 目标不在快照内 id=\(id.uuidString.prefix(8)) items=\(items.count)", category: "ChatList.Scroll")
                return
            }
            AppLogger.shared.info("[Scroll][toMessage][CALL] id=\(id.uuidString.prefix(8)) item=\(firstIdx)/\(items.count) \(Self.nbDump(cv))", category: "ChatList.Scroll")
            // 定位到历史消息 = 用户开始浏览：必须先关掉贴底闸门，否则流式更新或会话载入的
            // 自动贴底会立刻把这次跳转拽回底部 —— 与 `scrollViewWillBeginDragging` 同一处理。
            scrollMode = .userBrowsing
            clampAfterSessionLoad = false
            cv.scrollToItem(at: IndexPath(item: firstIdx,section: 0),at: .top,animated: animated)
            // 与 `scrollToPreviousUserTurn` 同源：立即 + 动画结束后各同步一次滚动标志 ——
            // UIKit 的动画滚动不一定在稳定位置发出终止 `scrollViewDidScroll`。
            DispatchQueue.main.async { [weak self] in self?.syncScrollFlags() }
            if animated {
                DispatchQueue.main.asyncAfter(deadline: .now()+0.4) { [weak self] in
                    self?.syncScrollFlags()
                }
            }
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
                AppLogger.shared.info("[Scroll][prevUserTurn] ABORT target item not found target=\(target.uuidString.prefix(8))", category: "ChatList.Scroll")
                return
            }

            lastJumpedUserId = target
            let curTurn = userIds.firstIndex(of: currentAnchor) ?? -1
            let tgtTurn = userIds.firstIndex(of: target) ?? -1
            AppLogger.shared.info("[Scroll][prevUserTurn][CALL] curTurn=\(curTurn) targetTurn=\(tgtTurn)/\(userIds.count) topMsgIdx=\(topMsgIdx) currentAnchor=\(currentAnchor.uuidString.prefix(8)) target=\(target.uuidString.prefix(8)) ip=\(ip.section).\(ip.item) \(Self.nbDump(cv))", category: "ChatList.Scroll")
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
        ///
        /// [T2 修正 2026-09-12] **顶部留白 = 常量**（`appBaseContentInsetTop`，iOS26+ 为 0）。
        /// 之前的两次模型错误：
        ///   ① 用「容器瞬时安全区」当数据源 → 它在 116 ↔ 0 之间切换；
        ///   ② 用 `navBar.frame.maxY`(=116) 当留白 → 那是**导航栏在窗口中的位置**，
        ///      而不是「CV 缺失的覆盖量」。稳态 `safeAreaInsets.top == 0` 恰好证明
        ///      **CV 的 frame 本来就在导航栏下方** ⇒ 顶部留白**本就应为 0**，加上 116 就多出大片空白。
        /// 常量 0 同时带来关键性质：**该值不切换** ⇒ `.never` 下 `adjustedContentInset` 恒定
        /// ⇒ UIKit 无需补偿 ⇒ 入口期不再位移。
        public var baseContentInsetTop: CGFloat {
            appBaseContentInsetTop
        }

        /// App 自有顶部基础留白（与设备无关的那部分）。
        public var appBaseContentInsetTop: CGFloat {
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
            // [T2] 用**稳定的顶部留白**（= `baseContentInsetTop`，取 window 安全区 + 导航栏 frame）
            // 替代会切换的 `cv.safeAreaInsets.top`：否则顶端一换，`visibleH → overflowH →
            // desiredBottomInset` 全跟着变，底部留白变化 ⇒ 整块内容位移（传导路径）。
            let safeAreaTop = baseContentInsetTop
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
                AppLogger.shared.info("[CHANGE] from=\(caller) bottomInset \(String(format: "%.1f", prevBottomInset))→\(String(format: "%.1f", desiredBottomInset)) Δ\(String(format: "%+.1f", desiredBottomInset - prevBottomInset)) — \(reason)", category: "ChatList.SubViewport")
                cv.contentInset.bottom = desiredBottomInset
            }
            if scrollMode == .autoScrolling {
                //
                // [T2] `baseBottomInset` 现已含底部安全区，故不再二次叠加（否则多 34pt）。
                let pinBottomInset = bottomInsetBase
                let rawTarget = cv.contentSize.height-cv.bounds.height+pinBottomInset
                let inflatedMaxOff = cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom
                let topLimit = -cv.adjustedContentInset.top
                let target = min(max(rawTarget,topLimit),inflatedMaxOff)
                let offsetBefore = cv.contentOffset.y
                if target>topLimit-0.5 && abs(cv.contentOffset.y-target)>0.5 {
                    // [T1 2026-09-12] 转场期间同样不直接写 offset（此写入不经 `setContentOffset`，
                    // 探针抓不到，但同属「转场期提交 offset」这一类）——推迟到转场完成后的贴底。
                }
            }
            return needsCompensation
        }

        /// [T1 2026-09-12] 转场期间被推迟的贴底请求存放在 Coordinator 主体声明处
        /// （`MessageCollectionView.pendingEntryPin` —— 扩展不能声明存储属性）。

        public func scrollToBottomNow(animated: Bool = false) {
            guard let cv = viewController?.collectionView else { return }
            // [T1 2026-09-12 · 入会话时序] push 转场期间容器的顶部安全区**尚未就位**
            //（真机实测 `safeAreaInsets.top` 116 ↔ 0 翻转），此时提交 offset 会与转场赛跑：
            // 入口窗口内出现 4 次 animated offset 写入（delta −33/+26/+5.7/−34）
            // ⇒ 用户看到的「重进会话，首次上滑整屏上下弹」。
            // 治法与本因同源：**整个转场期间不提交任何 offset**，转场完成后再执行一次。
            // 转场之外（流式跟随、点按回底等）此闸门不生效，行为不变。
            if let tc = viewController?.transitionCoordinator {
                pendingEntryPin = animated
                tc.animate(alongsideTransition: nil) { [weak self] _ in
                    guard let self, let a = self.pendingEntryPin else { return }
                    self.pendingEntryPin = nil
                    self.scrollToBottomNow(animated: a)
                }
                return
            }
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
                AppLogger.shared.info("[Scroll][syncScrollFlags] isNearBottom \(vm.isNearBottom)→\(nbFlag) \(Self.nbDump(viewController?.collectionView))", category: "ChatList.Scroll")
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
            // [2026-09-13 出入口统一 3/3] 预取不再自行算估高、直接写 `heightEntries` ——
            // 那是**第 4 条绕过播种唯一入口**的写路径。改为复用 `seedHeights(.indices:)`。
            //
            // 原实现有两处口径错误（都是"同一语义各自写一遍"的必然产物）：
            //   ① 宽度取 `maxContentWidth`，而它的唯一构造点是 `ChatView` 传入的 `0`
            //      ⇒ 估高按 0 宽算（文本可用宽被 `max(w-80,100)` 兜到 100）⇒ 系统性虚高，
            //      正是 S1 描述的"虚高帧 ⇒ 手势期收缩被拒"的原料；
            //      其余所有播种路径用的都是 `cv.bounds.width`。
            //   ② 直接写 `.estimated` 且**不写内容键** ⇒ 条目 `key == nil`，
            //      `currentEntry` 判它"信息不足、保守当有效"，内容变化时不会 demote。
            // 走 `seedHeights` 后两者一并消失：宽度同源、内容键同源、缺失判据同源。
            guard let vm, let cv = viewController?.collectionView else { return }
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            seedHeights(.indices(indexPaths.map(\.item)),
                        rows: prevSnapshotIds,
                        messages: messages,
                        width: cv.bounds.width)
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
            // [P5 2026-09-13] 记下冻结起点（供泄漏兜底判定）。**仅在本就未冻结时写**：
            // 若上一轮冻结已泄漏，这里保持旧起点 ⇒ 宽限期继续累积 ⇒ 兜底能立刻命中，
            // 而不是被本次手势"刷新"成新起点、把泄漏再拖一整轮。
            if freezeStartedAt == nil { freezeStartedAt = CFAbsoluteTimeGetCurrent() }
            viewController?.messageListLayout?.deferSelfSizing = true
            // [2026-09-13 隐患①修复] 清零 settle 期的偏移补偿累积量：该累积必须**只反映本次手势期间**
            // 的变化。真机实证（三个构建均复现）`pendingΣ=+1037.0 applied=1 offset -76.7→960.3`：
            // 1037pt 是更早（offset 在底部一带）累积的，却在之后的 settle 被消费 ⇒ 停手瞬间整屏跳。
            // 清零安全：拖拽开始那一刻屏幕上的内容即用户基准，此前的高度变化**早已反映在画面上**、
            // 无需补偿；本次手势期间的新变化仍在清零后的窗口内照常累积。
            // 本改动**只写 contentOffset、不写高度** ⇒ 最坏是"少补一次"（原地不动），不可能造成内容偏差。
            viewController?.messageListLayout?.clearPendingAboveShift()
            vm?.setStreamingUIUpdatesSuspended(true)
            // [2026-09-13 兜底自足] 兜底原先只挂在 `updateUIViewController`，而它恰恰在
            // 「流式挂起 ⇒ 不再有 @Published 变化 ⇒ SwiftUI 不再重算 body」时不会被调用 ——
            // 那正是泄漏的定义场景。补一条**时间驱动**的第二触发点（幂等、自限，见实现）。
            scheduleFreezeWatchdog()
        }

        public func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            // [Decel] Fires the instant the finger lifts and UIKit has
            decelTargetOffset = targetContentOffset.pointee.y
            #if DEBUG
            AppLogger.shared.info("[Decel][willEndDragging] vy=\(String(format: "%.0f", velocity.y))pt/s offset=\(String(format: "%.0f", scrollView.contentOffset.y)) → target=\(String(format: "%.0f", decelTargetOffset)) projDist=\(String(format: "%.0f", decelTargetOffset - scrollView.contentOffset.y)) cs=\(String(format: "%.0f", scrollView.contentSize.height))", category: "ChatList.Decel")
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
            AppLogger.shared.info("[Decel][BEGIN] offset=\(String(format: "%.0f", decelStartOffset)) target=\(String(format: "%.0f", decelTargetOffset)) decelDist=\(String(format: "%.0f", decelTargetOffset - decelStartOffset)) visibleCells=\(visibleN) deferSelfSizing=\((viewController?.messageListLayout?.deferSelfSizing ?? false) ? 1 : 0)", category: "ChatList.Decel")
            startDecelDisplayLink()
            #endif
        }

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            // [Decel] DECELERATION END — summarize the phase: total
            if decelStartTime>0 {
                #if DEBUG
                let dur = (CACurrentMediaTime()-decelStartTime)*1000
                AppLogger.shared.info("[Decel][END] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelFrameCount) slowFrames=\(self.decelSlowFrameCount) offset \(String(format: "%.0f→%.0f", self.decelStartOffset, scrollView.contentOffset.y)) (target was \(String(format: "%.0f", self.decelTargetOffset)))", category: "ChatList.Decel")
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
            AppLogger.shared.warning("[Decel][SLOW-FRAME] +\(String(format: "%.0f", sinceStart))ms into decel gapH=\(String(format: "%.0f", gapH * 1000))ms offset=\(String(format: "%.0f", offY))\(dir) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - offY)) visibleCells=\(visibleN) frame#\(self.decelFrameCount)", category: "ChatList.Decel")
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
                AppLogger.shared.warning("[DecelDisplayLink][DROP] +\(String(format: "%.0f", sinceStart))ms into decel gapH=\(String(format: "%.1f", gapMs))ms (expected \(String(format: "%.1f", self.decelDLExpectedMs))ms, ~\(dropped) frame(s) dropped) offset=\(String(format: "%.0f", offY)) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - offY)) frame#\(self.decelDLFrames)", category: "ChatList.Decel")
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
            AppLogger.shared.info("[DecelDisplayLink][SUMMARY] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelDLFrames) drops=\(self.decelDLDrops) actualFps=\(String(format: "%.1f", actualFps)) gapRange=[\(String(format: "%.1f", minGap))..\(String(format: "%.1f", self.decelDLMaxGapMs))]ms expected=\(String(format: "%.1f", self.decelDLExpectedMs))ms", category: "ChatList.Decel")
        }
        #endif

        // MARK: - [2026-09-13 空白直接测量]
        //
        /// 拖动/惯性期 1Hz 采样**两件直接指向"空白"的事实**（不再测高度条目——上一版
        /// `[BlankProbe] entryH=nil` 已证否：它只是"cell 配置早于补播"的时序现象，
        /// 修复后仍存在，与空白无关）：
        ///   ① 可见矩形内**布局属性是否连续**：`first…last` 里缺号的 index = 布局没给
        ///      格位 ⇒ 那个区间必然空白（且抬手 settle 失效后才补上）。
        ///   ② 每个可见 cell 的**分配高 vs 内容实际占用高**：差值 > 8pt = 分了高度却没
        ///      填内容 ⇒ 也是空白。
        /// 只读、1Hz、只在拖动/惯性期工作；无异常不打印。
        /// （extension 不能放实例存储属性，故用 static 节流锚点。）
        private static var blankProbeLastAt: CFTimeInterval = 0
        private func blankHoleProbeIfNeeded(_ sv: UIScrollView) {
            guard sv.isDragging || sv.isDecelerating else { return }
            let now = CACurrentMediaTime()
            guard now - Self.blankProbeLastAt >= 1.0 else { return }
            Self.blankProbeLastAt = now
            guard let cv = sv as? UICollectionView else { return }
            let attrs = cv.collectionViewLayout.layoutAttributesForElements(in: cv.bounds) ?? []
            let idxs = attrs.map(\.indexPath.item).sorted()
            var holeTag = ""
            if let first = idxs.first, let last = idxs.last, first < last {
                let present = Set(idxs)
                let missing = (first...last).filter { !present.contains($0) }
                if !missing.isEmpty {
                    holeTag = " 洞=\(missing.prefix(24))共\(missing.count)"
                }
            }
            var empties: [String] = []
            for cell in cv.visibleCells {
                guard let ip = cv.indexPath(for: cell) else { continue }
                let contentH = cell.contentView.subviews.map { $0.frame.maxY }.max() ?? 0
                if cell.bounds.height - contentH > 8 {
                    empties.append("idx=\(ip.item):cellH=\(Int(cell.bounds.height))/contentH=\(Int(contentH))")
                }
            }
            if !holeTag.isEmpty || !empties.isEmpty {
                AppLogger.shared.info("[BlankProbe2] attrIdx=\(idxs.first ?? -1)~\(idxs.last ?? -1) 属性数=\(attrs.count)\(holeTag) 空内容格(\(empties.count)): \(empties.prefix(12).joined(separator: " | "))",
                                      category: "ChatList.Blank")
            }
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // [Decel] Detect dropped frames during the deceleration phase
            // (cheap: early-returns unless decelerating + frame gapH exceeded).
            logDecelFrameIfSlow(scrollView)
            blankHoleProbeIfNeeded(scrollView)
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
            // [P5 2026-09-13] **正在进行新手势时拒绝 settle**。
            //
            // `scrollViewDidEndDecelerating` 里是 `DispatchQueue.main.async { settle }` ——
            // 异步那一跳之间用户完全可能已经重新按下并开始拖动。此时若旧 settle 落地，它会
            //   ① 把 `deferSelfSizing` 置 false ⇒ **在拖动手势中途解冻**（−160pt 收缩抖动会回来）；
            //   ② 按旧基准改写 `contentOffset` ⇒ 与新手势抢方向盘。
            // 拒绝是安全的：本次手势结束时它自己的 `didEndDragging`/`didEndDecelerating` 会再调一次；
            // 万一都没来，`resetLeakedFreezeIfNeeded(_:)` 的宽限期兜底也会补上。
            guard let cvNow = viewController?.collectionView,!cvNow.isTracking else { return }

            // and jittering.
            let atBottom = isWithinBottom(reacquireAutoScrollThreshold)
            let nearBottom = isNearBottom()
            if atBottom {
                scrollMode = .autoScrolling
            }
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else {
                // [P5 2026-09-13] **早退也必须解冻**。解冻两个动作都不依赖 `layout`/`cv`，
                // 而本函数是冻结的**唯一关闭点** —— 任何早退都会让两轴永久滞留
                //（几何不再收缩 ⇒ 拖动手感变"粘"；快照永不上屏 ⇒ 流式内容不显示）。
                // 原先这里直接 `return`，是一个真实的泄漏口。
                viewController?.messageListLayout?.deferSelfSizing = false
                vm?.setStreamingUIUpdatesSuspended(false)
                freezeStartedAt = nil
                AppLogger.shared.warning("[Freeze] settle 早退（layout/cv 缺失）→ 强制解冻两轴", category: "ChatList.Scroll")
                return
            }

            _ = nearBottom
            layout.deferSelfSizing = false

            let savedOffset = cv.contentOffset.y
            flushingNow = true
            // [2026-09-12 抖动根因·解除跳动] 视口**上方**的高度变化会 1:1 平移可见内容
            // （解冻后 offset 是数值恢复的），所以原子应用之后必须把该合计值锚回 offset，
            // 否则呈现为「停下瞬间整屏跳一下」。真机实录 aboveΣ = −648.6pt（19 个工具胶囊
            // 各自从兜底 200pt 收缩到真实的 36/39.7pt）。
            let aboveSum = layout.applyDeferredHeights()
            if abs(aboveSum) > 0.5 { cv.contentOffset.y = savedOffset + aboveSum }

            layout.suppressContentOffsetAdjustment = true
            layout.invalidateLayout()
            layout.suppressContentOffsetAdjustment = false
            // [2026-09-12] 上面那次强制重排**关闭了布局自带的 offset 补偿**，所以期间发生的
            // 「视口上方高度变化」没有任何锚定（真机实测 aboveΣ=-183.7pt）⇒ 停手瞬间整屏平移。
            // 这里把这批量一次性锚回，与 `aboveSum`（延后项）相加，两者互不重叠。
            let settleAbove = layout.takePendingAboveShift()
            if abs(settleAbove) > 0.5 {
                cv.contentOffset.y = savedOffset + aboveSum + settleAbove
            }
            // [2026-09-13] 把 settle 期补偿量打进日志：残留抖动不必再靠截图反推，
            // 直接看这一行是否为 0 即可判定"停手不再挪动"。
            AppLogger.shared.info(
                "[SettleAnchor] deferredΣ=\(String(format: "%+.1f", aboveSum)) pendingΣ=\(String(format: "%+.1f", settleAbove)) applied=\(abs(settleAbove) > 0.5 ? 1 : 0) offset \(String(format: "%.1f", savedOffset))→\(String(format: "%.1f", cv.contentOffset.y))",
                category: "ChatList.Settle")
            flushingNow = false

            if scrollMode == .userBrowsing {
                cv.contentOffset.y = savedOffset
            }

            vm?.setStreamingUIUpdatesSuspended(false)
            // [P5 2026-09-13] 两轴均已解冻 = 本次冻结结束 ⇒ 清冻结起点，泄漏兜底的宽限期重新起算。
            freezeStartedAt = nil

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

        /// 视口顶部锚点（**按身份**，不按数值）。
        ///
        /// 为什么需要它：`.miniClawAttachmentSizeChanged` 的处理会**全表**失效高度。全表失效后
        /// `aboveΣ` 失去意义（"视口上方的高度变化"变成"整表的高度变化"，无法求和），
        /// 而 `contentOffset` 只是个数值 —— 内容总高一变，同一个数值就指向**完全不同的内容**。
        /// 唯一能表达"我在看这里"的东西是**窗口顶部那个 item + 它当时的屏内偏移**。
        struct ViewportTopAnchor {
            let item: MessageListItem
            /// `cell.frame.minY - contentOffset.y`：该 item 相对内容区顶缘的位置（含 inset 语义）。
            let deltaInViewport: CGFloat
        }

        /// 取当前视口顶部的 item 作为锚点。取不到（列表空 / 尚未布局）时返回 nil，调用方跳过锚定。
        func viewportTopAnchor() -> ViewportTopAnchor? {
            guard let cv = viewController?.collectionView,let ds = dataSource else { return nil }
            // 探针取「内容区顶缘略下方」一点：直接取顶缘可能落在区头/间隙上而查不到 item。
            let probeY = cv.contentOffset.y+cv.adjustedContentInset.top+1
            guard let ip = cv.indexPathForItem(at: CGPoint(x: 8,y: probeY)),
                  let item = ds.itemIdentifier(for: ip),
                  let cell = cv.cellForItem(at: ip) else { return nil }
            return ViewportTopAnchor(item: item,deltaInViewport: cell.frame.minY-cv.contentOffset.y)
        }

        /// 把锚点 item 还原到**同一屏内位置**。幂等：item 已不在快照里、或取不到其 frame 时原样返回。
        ///
        /// 命中与否都要打印一次：这条日志是「带图片回复是否还会跳位」的唯一判据。
        func restoreViewportTopAnchor(_ anchor: ViewportTopAnchor?,reason: String) {
            guard let anchor,let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let ds = dataSource,let ip = ds.indexPath(for: anchor.item) else { return }
            cv.layoutIfNeeded()
            // 优先用真 cell 的 frame；它已离屏时退回布局属性（不物化 cell）。
            let minY: CGFloat
            if let cell = cv.cellForItem(at: ip) {
                minY = cell.frame.minY
            } else if let attrs = layout.layoutAttributesForItem(at: ip) {
                minY = attrs.frame.minY
            } else {
                AppLogger.shared.info("[AttachAnchor] 取不到 frame，放弃锚定（\(reason)）", category: "ChatList.Scroll")
                return
            }
            let maxOffset = max(0,cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom)
            let target = min(max(minY-anchor.deltaInViewport,-cv.adjustedContentInset.top),maxOffset)
            let before = cv.contentOffset.y
            guard abs(target-before) > 0.5 else {
                AppLogger.shared.info("[AttachAnchor] 无需还原（\(reason)）offset=\(String(format: "%.1f", before))", category: "ChatList.Scroll")
                return
            }
            cv.contentOffset.y = target
            AppLogger.shared.info("[AttachAnchor] 按身份还原（\(reason)）offset \(String(format: "%.1f", before))→\(String(format: "%.1f", target)) delta=\(String(format: "%.1f", anchor.deltaInViewport))", category: "ChatList.Scroll")
        }

        /// 冻结的关闭判定（2026-09-13 治本后：由**轮询**驱动，滚动回调只是快路径）。
        ///
        /// ⚠️ **它不新增第二条关闭路径** —— 命中后只是**重新触发唯一关闭点**
        /// `settleAfterInteraction`。这样"解冻"依然只有一个出入口：解冻顺带把
        /// `deferredHeights` 应用掉、并把视口上方的高度变化 1:1 锚回 offset
        ///（`aboveSum` + `settleAbove`）。若在这里另写一份"只把两个 bool 置 false"的简化解冻，
        /// 就会出现**收缩不被锚定** ⇒ 可见内容原地跳（这正是 M1/M3 反复修过的东西）。
        ///
        /// 判据 = 「**正在手势或正在减速**」才算合法冻结。这个条件与滚动回调无关，故可轮询；
        /// 宽限期只剩 `0.05s`：用于不与"减速已结束、`didEndDecelerating` 里那次异步 settle
        /// 尚未执行"的正常窗口抢跑（那里只差一次主队列跳转），而不再承担"兜底迟到的量化误差"
        /// —— 后者已由 0.1s 的轮询间隔本身覆盖。
        func resetLeakedFreezeIfNeeded(_ reason: String) {
            guard let cv = viewController?.collectionView else { return }
            guard let started = freezeStartedAt else { return }
            guard !cv.isTracking,!cv.isDecelerating else { return }
            let grace: CFTimeInterval = 0.05
            let elapsed = CFAbsoluteTimeGetCurrent()-started
            guard elapsed > grace else { return }
            AppLogger.shared.warning(
                "[Freeze] 轮询关闭：冻结已 \(Int(elapsed * 1000))ms 且既非 tracking 也非 decelerating ⇒ 滚动回调未到，由轮询触发唯一关闭点 settle（来源 \(reason)）",
                category: "ChatList.Scroll")
            settleAfterInteraction(cv)
        }

        /// 冻结的**主关闭路径**（2026-09-13 治本：不再依赖滚动回调）。
        ///
        /// 真机日志实证：`[Freeze] 泄漏兜底` 在 20 分钟内触发 **12 次**，且 elapsed 几乎全是
        /// **~1050ms / ~2100ms** —— 恰为当时轮询间隔（1s）的整数倍 ⇒ 说明**每次拖动后
        /// `settleAfterInteraction` 都没有被滚动回调叫到**，冻结一直挂到兜底把它解开。
        /// 即：`scrollViewDidEndDragging(willDecelerate:true)` 之后 `scrollViewDidEndDecelerating`
        /// 没来（减速被程序化 `setContentOffset` 打断时不保证回调），于是关闭点永远不触发。
        ///
        /// 治本方向：**关闭条件本来就与滚动回调无关** —— 冻结只在「正在手势或正在减速」时合法。
        /// 所以改成**轮询该条件**：一旦观察到 `!isTracking && !isDecelerating`，立即走唯一的
        /// 关闭点 `settleAfterInteraction`。滚动回调降级为"能叫就更快"的**快路径**。
        ///
        /// 轮询间隔 = 冻结的最大残留时间，取 **0.1s**：手指离开后最多 0.1s 解除，人眼不可辨；
        /// 代价仅为冻结期间每 100ms 一次主队列检查（未冻结时本函数根本不排期，零开销）。
        private func scheduleFreezeWatchdog() {
            DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { [weak self] in
                guard let self,self.freezeStartedAt != nil else { return }
                self.resetLeakedFreezeIfNeeded("poll")
                if self.freezeStartedAt != nil { self.scheduleFreezeWatchdog() }
            }
        }

}
