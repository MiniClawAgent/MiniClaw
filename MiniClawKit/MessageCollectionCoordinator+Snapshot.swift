import SwiftUI
import UIKit
import Combine
import Foundation

extension MessageCollectionView.Coordinator {
        // MARK: - Snapshot

        /// When a snapshot is deferred (e.g. streaming UI updates suspendedFlag),
        /// set to true so we know to re-apply later.

        func applySnapshot(messages rawMessages: [ChatMessage], caller: String = "?") {
            guard let vm,!vm.isLoadingSession else { return }

            // Single UI-collection sink for EVERY
            // path that pushes messages to the list (loadSession, live inject,
            // compact rebuild, snapshot reload, rebind…). Filter the internal
            // role-alternation bridge (#579) here so it can never surface as a
            // chat bubble regardless of which path produced it — replacing the
            // former reliance on a single filter inside loadSession, which other
            // rebuild paths bypassed (the leak seen 2026-07-24).
            let messages = rawMessages.contains(where: { $0.isInternalBridge })
                ? rawMessages.filter { !$0.isInternalBridge }
                : rawMessages

            // Content changed (new/removed messages) — the up-button's turn-walk
            // anchorY may no longer line up, so restart it on the next tap.
            lastJumpedUserId = nil

            // Subscribe to thinking block toggle notifications (once)
            if attachmentSizeChangedSub == nil {
                attachmentSizeChangedSub = NotificationCenter.default.publisher(for: .miniClawAttachmentSizeChanged)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] notification in
                        let alog = AppLogger(category: "AttachmentSize")
                        guard let self else { return }
                        guard let cv = self.viewController?.collectionView,
                              let layout = cv.collectionViewLayout as? MessageListLayout else {
                            alog.warning("[AttachmentSize] infra missing")
                            return
                        }
                        let urlStr = (notification.object as? String) ?? "<nil>"
                        let visibleIPs = cv.indexPathsForVisibleItems.sorted()
                        var cleared = 0
                        for ip in visibleIPs {
                            if let cell = cv.cellForItem(at: ip) as? SelfSizingCell {
                                let before = cell.frame.size.height
                                cell.clearCachedHeight()
                                layout.invalidateHeight(at: ip.item)
                                cleared += 1
                                alog.info("[AttachmentSize] clear idx=\(ip.item) frameH=\(String(format: "%.1f", before))")
                            }
                        }
                        // [T-attachment-cell-offscreen 2026-05-24]
                        // A markdown-inline video/image whose initial estimate
                        // was too small (e.g. text-only block estimator
                        // returning ~50pt) is pushed offY-screen by the cold
                        // scroll-to-bottom — the visible-cells-only invalidate
                        // above then misses it, and the cell stays at the
                        // 200pt placeholder until an unrelated reconfigure
                        // runs many seconds later. Always invalidate the
                        // layout's height cache for ALL items so the next
                        // measurement pass picks up the new attachmentBounds.
                        let totalItems = self.dataSource?.snapshot().itemIdentifiers.count ?? 0
                        for idx in 0..<totalItems {
                            layout.invalidateHeight(at: idx)
                        }
                        if let snapshot = self.dataSource?.snapshot() {
                            // Reconfigure every item — cheap (no diff), forces
                            // every cell that gets re-displayed to re-measure.
                            // We still see a visible reflow only on cells in
                            // viewport; offY-screen cells just get a corrected
                            // cached height for next display.
                            var snap = snapshot
                            snap.reconfigureItems(snapshot.itemIdentifiers)
                            self.dataSource?.apply(snap,animatingDifferences: false)
                        }
                        // [T-attachment-defer-invalidate 2026-05-24]
                        // Defer invalidateLayout to the next runloop. reconfigureItems
                        // schedules a SwiftUI hosting-config update on the next
                        // runloop tick; calling invalidateLayout synchronously
                        // makes UIKit re-query PLAF while the cell's
                        // UIHostingConfiguration still wraps the STALE
                        // attributedString (with the 200pt video placeholder),
                        // so systemLayoutSizeFitting returns the old 375pt
                        // height, caches it as lastComputedHeight, and locks
                        // the cell at the wrong size until something else
                        // triggers another reconfigure (10+ seconds later
                        // when the user navigates back). Letting the runloop
                        // turn first ensures the new attributedString is
                        // mounted in the hosting view before we re-measure.
                        DispatchQueue.main.async {
                            // Clear cell-side caches AGAIN after the
                            // reconfigure has propagated, then ask UIKit to
                            // re-measure.
                            for ip in cv.indexPathsForVisibleItems {
                                (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                            }
                            layout.invalidateLayout()
                            // While we're still in the session-load clamp
                            // window, re-pin to bottom — the corrected
                            // heights shift the content offset and otherwise
                            // leave the user looking at the wrong region.
                            if self.clampAfterSessionLoad {
                                self.scrollToLastItem()
                            }
                        }
                        alog.info("[AttachmentSize] url=\(urlStr) cleared=\(cleared)/\(visibleIPs.count) totalInvalidated=\(totalItems) clamp=\(self.clampAfterSessionLoad)")
                    }
            }

            if thinkingToggleSub == nil {
                thinkingToggleSub = NotificationCenter.default.publisher(for: .thinkingBlockToggled)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] notification in
                        let tlog = AppLogger(category: "ChatList.Collapse")
                        guard let self else {
                            tlog.warning("[Collapse] sink fired but self gone")
                            return
                        }
                        guard let blockId = notification.object as? UUID else {
                            tlog.warning("[Collapse] notif object not UUID: \(String(describing: notification.object))")
                            return
                        }
                        guard let cv = self.viewController?.collectionView,
                              let layout = cv.collectionViewLayout as? MessageListLayout,
                              let snapshot = self.dataSource?.snapshot() else {
                            tlog.warning("[Collapse] block=\(blockId.uuidString.prefix(8)) infra missing: cv=\(self.viewController?.collectionView != nil) ds=\(self.dataSource != nil)")
                            return
                        }
                        // The layout-side
                        // `invalidateHeight` only wipes the MessageListLayout
                        // `heightCache`, not the per-cell `lastComputedHeight`
                        // on SelfSizingCell. Without also clearing the
                        // cell-side cache, the next
                        // `preferredLayoutAttributesFitting` short-circuits
                        // via the broad-width cache and returns the OLD
                        // expanded height (~300pt) for a cell whose SwiftUI
                        // body now renders just the 36pt header — producing
                        // a tall empty gapH below the collapsed pill (user
                        // screenshot 2026-05-19). Clear both caches here
                        // and reconfigure so UIHostingConfiguration
                        // re-measures from scratch. Trace each step so a
                        // future report can be diagnosed from logs alone.
                        var matched = false
                        for (i,item) in snapshot.itemIdentifiers.enumerated() {
                            if case .assistantBlock(_,let bid) = item,bid == blockId {
                                matched = true
                                let beforeLayout = layout.cachedHeight(at: i)
                                let beforePrecalc = layout.precalcHeight(at: i)
                                let ip = IndexPath(item: i,section: 0)
                                let cellOpt = cv.cellForItem(at: ip) as? SelfSizingCell
                                let frameH = cellOpt?.frame.size.height ?? -1
                                if let cell = cellOpt {
                                    cell.clearCachedHeight()
                                }
                                layout.invalidateHeight(at: i)
                                var snap = snapshot
                                snap.reconfigureItems([item])
                                self.dataSource?.apply(snap,animatingDifferences: false)
                                layout.invalidateLayout()
                                tlog.info("[Collapse] HIT block=\(blockId.uuidString.prefix(8)) idx=\(i) cellFound=\(cellOpt != nil) frameH=\(String(format: "%.1f", frameH)) beforeLayout=\(beforeLayout.map { String(format: "%.1f", $0) } ?? "nil") beforePrecalc=\(beforePrecalc.map { String(format: "%.1f", $0) } ?? "nil")")
                                // Defer one runloop tick to capture the
                                // post-reconfigure measurement and confirm
                                // the cell actually shrank/grew. If the
                                // delta is small the cache invalidation
                                // didn't take — that's the case to escalate.
                                DispatchQueue.main.async { [weak cv, weak layout] in
                                    let cv = cv
                                    let layout = layout
                                    let after = cv?.cellForItem(at: ip)?.frame.size.height ?? -1
                                    let afterLayout = layout?.cachedHeight(at: i)
                                    tlog.info("[Collapse] POST block=\(blockId.uuidString.prefix(8)) idx=\(i) frameH=\(String(format: "%.1f", after)) layoutCache=\(afterLayout.map { String(format: "%.1f", $0) } ?? "nil") delta=\(String(format: "%.1f", after - frameH))")
                                }
                                break
                            }
                        }
                        if !matched {
                            tlog.warning("[Collapse] MISS block=\(blockId.uuidString.prefix(8)) not in snapshot (items=\(snapshot.itemIdentifiers.count))")
                        }
                    }
            }

            // Rebuild O(1) lookup indices
            messageIndex.removeAll(keepingCapacity: true)
            for (i,msg) in messages.enumerated() {
                messageIndex[msg.id] = i
            }

            // Clean up bridges
            let currentIds = Set(messages.map(\.id))
            let removedIds = Set(cellBridgeMap.keys).subtracting(currentIds)
            for id in removedIds { bridgeSheetSubs.removeValue(forKey: id) }
            cellBridgeMap = cellBridgeMap.filter { currentIds.contains($0.key) }

            // Build items
            var newRows: [MessageListItem] = []
            for message in messages {
                switch message.role {
                case .user,.compactDivider,.systemInfo:
                    newRows.append(.wholeMessage(message.id))
                case .assistant:
                    newRows.append(.assistantHeader(message.id))
                    // 按 timelineOrder 兜底排序(2026-08-10):渲染层不依赖数据源顺序,
                    // 保证重进会话/流式收敛后「思考→工具→正文」按真实发生顺序显示,
                    // 即使块复用缓存复用了流式中途的 blocks 也不会错序。
                    let sortedBlocks = message.blocks.sorted {
                        if $0.timelineOrder != $1.timelineOrder { return $0.timelineOrder < $1.timelineOrder }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    for block in sortedBlocks {
                        newRows.append(.assistantBlock(message.id,block.id))
                    }
                    // Only emit a footer cell when it will actually render
                    // content. A footer with zero visible content (no typing
                    // indicator, no error, no resume, no usage) was leaving a
                    // phantom 4pt gapH above the next user message. When the
                    // footer IS needed later (e.g. showUsage toggled by
                    // double-tap), the toggle triggers a snapshot refresh
                    // which re-evaluates this condition.
                    let isLastAssistant = (message.id == messages.last(where: { $0.role == .assistant })?.id)
                    // 2026-09-05 唐唐要求：**每一条** AI 回复都持久显示状态行（已完成/已停止/
                    // 已中断 + 耗时），不再只显示最后一条。
                    let needsFooter = isLastAssistant
                        || message.role == .assistant
                        || message.error != nil
                        || message.streamInterruptCount>0
                        || (cellBridgeMap[message.id]?.canResume == true)
                        || (cellBridgeMap[message.id]?.showUsage == true)
                    if needsFooter {
                        newRows.append(.assistantFooter(message.id))
                    }
                }
            }

            // Remap height cache + set accurate estimates for ALL item types
            if let layout = viewController?.messageListLayout {
                layout.updateCacheForSnapshot(oldIds: prevSnapshotIds,newIds: newRows)

                let cvWidth = viewController?.collectionView.bounds.width ?? 390
                for (i,item) in newRows.enumerated() {
                    seedHeight(at: i,item: item,messages: messages,width: cvWidth)
                }
            }
            // Rebuild item→index lookup
            itemToIndex.removeAll(keepingCapacity: true)
            for (i,item) in newRows.enumerated() {
                itemToIndex[item] = i
            }

            // Track streaming cell ranges so layout doesn't adjust offset for
            // them. Not just the LAST
            // assistant message: with queued-turn interrupts an EARLIER
            // assistant message can still be receiving content (running /
            // streaming tool blocks) while the newest turn streams text. Every
            // such message's item span must be excluded from the visible-cell
            // offset adjustment, or browse-mode hovering over it gets dragged
            // down by each flush's growth delta.
            if vm.isProcessing {
                var streamingIds: [UUID] = []
                if let lastMsg = messages.last,lastMsg.role == .assistant {
                    streamingIds.append(lastMsg.id)
                }
                for msg in messages where msg.role == .assistant && msg.id != messages.last?.id {
                    let hasLiveTool = msg.blocks.contains { blk in
                        switch blk.toolStatus {
                        case .running,.streaming: return true
                        default: return false
                        }
                    }
                    if hasLiveTool { streamingIds.append(msg.id) }
                }
                var ranges: [Range<Int>] = []
                for id in streamingIds {
                    guard let start = newRows.firstIndex(of: .assistantHeader(id)) else { continue }
                    var end = start+1
                    while end<newRows.count,Self.item(newRows[end],belongsTo: id) {
                        end += 1
                    }
                    ranges.append(start..<end)
                }
                ranges.sort { $0.lowerBound<$1.lowerBound }
                viewController?.messageListLayout?.streamingCellRanges = ranges
            } else {
                viewController?.messageListLayout?.streamingCellRanges = []
            }
            // Keep the layout's pin flag in sync here too — the scrollMode
            // didSet may have fired before the layout existed (initial value).
            //
            viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            let oldCount = prevSnapshotIds.count
            // Lock the messages array the snapshot (and messageIndex, rebuilt
            // above) was built from. configureCell / prefetch MUST read this
            // same array: reading vm.messages there instead can race a
            // concurrent loadSession() that replaced the array with freshly
            // created ChatMessage/AssistantBlock objects (new UUIDs) — the
            // snapshot's block IDs then match nothing and the cell configures
            // EMPTY (silent `guard ... else return`). Updated BEFORE the
            // skip-return below so it stays in lockstep with messageIndex.
            //
            snapshotMessages = messages
            // Skip diffable-data-source apply when items haven't changed —
            // avoids expensive UIKit cell creation/layout on redundant snapshots.
            if newRows == prevSnapshotIds {
                AppLogger(category: "ChatList.Snapshot").info("[Snapshot] SKIP caller=\(caller) items unchanged (count=\(newRows.count)) — no re-apply")
                return
            }
            let oldSet = Set(prevSnapshotIds)
            let inserted = newRows.filter { !oldSet.contains($0) }
            prevSnapshotIds = newRows

            let snapLog = AppLogger(category: "ChatList.Snapshot")
            let blockItems = newRows.filter { if case .assistantBlock = $0 { return true }; return false }
            if let lastAIMsg = messages.last(where: { $0.role == .assistant }) {
                snapLog.info("[Snapshot] caller=\(caller) totalItems=\(newRows.count) blockItems=\(blockItems.count) lastAssistantBlocks=\(lastAIMsg.blocks.count) msgCount=\(messages.count)")
                for (i,block) in lastAIMsg.blocks.enumerated() {
                    let contentLen = block.content.count
                    let tail = String(block.content.suffix(20))
                    snapLog.info("[Snapshot] block[\(i)] kind=\(block.kind) id=\(block.id.uuidString.prefix(8)) contentLen=\(contentLen) tail=\"\(tail)\"")
                }
            }

            var snapshot = NSDiffableDataSourceSnapshot<MessageCollectionView.Section,MessageListItem>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newRows,toSection: .main)
            // Suppress contentOffsetAdjustment during snapshot application so that
            // rapid cell self-sizing doesn't cause visible content jumps. After layout
            // settles, pin to bottom if autoScrolling.
            let snapshotLayout = viewController?.messageListLayout
            snapshotLayout?.suppressContentOffsetAdjustment = true
            flushingNow = true
            cellConfigCount = 0
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            dataSource.apply(snapshot,animatingDifferences: false)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = false
            // [ToolLifecycle] Stage 5: log newly-inserted tool blocks now in the
            // applied snapshot. Only fires for inserts, so volume stays proportional
            // to actual new tool blocks appearing in the chat UI.
            if !inserted.isEmpty {
                let sid = vm.sessionId?.prefix(8) ?? "nil"
                let appState = UIApplication.shared.applicationState == .active ? "fg" : "bg"
                let suspendedFlag = vm.streamingUIUpdatesSuspended
                let processing = vm.isProcessing
                for item in inserted {
                    if case .assistantBlock(let msgId,let blockId) = item,
                       let msgIdx = messageIndex[msgId],
                       msgIdx<messages.count,
                       let block = messages[msgIdx].blocks.first(where: { $0.id == blockId }),
                       block.toolUseId != nil {
                        let toolName: String = switch block.kind {
                        case .shellTool: "shell_execute"
                        case .fileReadTool: "file_read"
                        case .fileWriteTool: "file_write"
                        case .fileEditTool: "file_edit"
                        case .browserTool: "browser_use"
                        case .readImageTool: "read_image"
                        case .memoryTool: "memory"
                        default: "unknown"
                        }
                        AppLogger(category: "ChatList.ToolLife").info("[ToolLifecycle] RENDERED_CHATUI toolId=\(block.toolUseId?.prefix(20) ?? "nil") tool=\(toolName) sid=\(sid) appState=\(appState) suspendedFlag=\(suspendedFlag) isProcessing=\(processing) caller=\(caller)")
                    }
                }
            }
            // Re-mark layout dirty: isApplyingSnapshot suppressed the layoutSubviews()
            // that dataSource.apply() triggered internally, so UIKit thinks layout is
            // already done. Without this, layoutIfNeeded() below is a no-op and cells
            // won't be created until the next touch/scroll.
            viewController?.collectionView.setNeedsLayout()

            if let cv = viewController?.collectionView {
                // Clear stale height cache for newly inserted items. During
                // dataSource.apply(), UIKit may trigger preferredLayoutAttributesFitting
                // on OLD cells still occupying the indices where new items will go,
                // writing the old cell's height into heightCache at the new item's index.
                // This causes the new cell to inherit the old cell's height (e.g. a 28pt
                // footer height applied to a new text block), leading to overlap.
                if !inserted.isEmpty,let layout = snapshotLayout {
                    for item in inserted {
                        if let idx = newRows.firstIndex(of: item) {
                            // 只清索引条目（保留 memo），随后立刻重新播种。
                            // 原实现用 invalidateHeight，既清索引又剔除 memo，且
                            // 不重播——重进会话时 ALL items 都算 inserted，全部种子
                            // 被清空后每个 cell 落到 estimatedItemHeight(200pt) 首次
                            // 自测大修正，offset 补偿在 tracking/decel 期间又不生效
                            // → 重进会话上滑持续抖动（2026-09-06 真机复现）。
                            layout.purgeIndexEntry(at: idx)
                            seedHeight(at: idx,item: item,messages: messages,
                                       width: viewController?.collectionView.bounds.width ?? 390,
                                       isReseed: true)
                        }
                    }
                }

                cv.layoutIfNeeded()
                snapshotLayout?.suppressContentOffsetAdjustment = false
                flushingNow = false
                let rawMaxOff = cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom
                let maxOff = max(0,rawMaxOff)
                if newRows.count<oldCount && cv.contentOffset.y>maxOff {
                    cv.setContentOffset(CGPoint(x: 0,y: maxOff),animated: false)
                    // After shrink, content may fall into the sub-viewport
                    // overflowH region — re-evaluate compensation so any
                    // previously-inflated top inset relaxes back to base.
                    // Shrink (delete/clear) — contentSize dropped, any inset
                    // accumulated from streaming-time GROW is no longer needed
                    // and would leave a permanent blank gapH at the bottom.
                    // forceRelax bypasses the monotonic guard.
                    applySubViewportCompensation(caller: "snapshot-shrink", forceRelax: true)
                } else if scrollMode == .autoScrolling && maxOff>0 {
                    cv.contentOffset.y = maxOff
                    // Deferred pin-to-bottom: UIHostingConfiguration self-sizing may
                    // complete asynchronously after layoutIfNeeded(), updating contentSize
                    // via KVO. But if another applySnapshot starts before that KVO fires,
                    // flushingNow suppresses it. The coalesced scroll (80ms) catches the
                    // final contentSize and corrects any undershoot.
                    scheduleCoalescedScroll()
                } else {
                    // Sub-viewport (rawMaxOff <= 0) or non-autoScrolling: keep
                    // the top-inset compensation tracking contentSize so the
                    // last cell stays pinned to the overlay top.
                    applySubViewportCompensation(caller: "snapshot-subVP")
                }
                // Sync isNearBottom after snapshot apply. applySnapshot runs
                // under flushingNow=true, which suppresses the contentSize KVO
                // observer — so the KVO-side sync we added doesn't run here.
                // Without this, contentSize can grow past the visible area
                // (sub-viewport overflowH) without anyone updating vm.isNearBottom,
                // leaving the scroll-to-bottom button hidden when it should appear.
                if let vm = self.vm {
                    let nbFlag = isNearBottom()
                    if vm.isNearBottom != nbFlag {
                        vm.isNearBottom = nbFlag
                    }
                }
                syncScrollFlags()
            } else {
                snapshotLayout?.suppressContentOffsetAdjustment = false
                flushingNow = false
            }
        }

        /// 播种单个 item 的估高（原种子循环主体，抽成方法以便 apply 后对被
        /// 清理的 insert 索引重播）。applySnapshot 里旧 cell 脏写被清掉后必须
        /// 重新播种，否则该 item 落到 `estimatedItemHeight`(200pt) 并首次自测
        /// 大修正 → 重进会话上滑抖动（2026-09-06）。
        private func seedHeight(at i: Int,item: MessageListItem,
                                messages: [ChatMessage],width: CGFloat,
                                isReseed: Bool = false) {
            guard let layout = viewController?.messageListLayout,let vm else { return }
            let cvWidth = width
            // Register the stable
            // content key for this index so a later self-size writes the
            // real height back under the key, and seed precalc from any
            // previously-measured real height. This kills the estimate→
            // real "settle jitter" for .wholeMessage (user) cells, whose
            // estimate is a coarse char-count heuristic (±13–52pt offY),
            // on every re-entry after the first measurement. NO new
            // measurement happens here — we reuse the height UIKit
            // already computed (see MessageListLayout.invalidationContext).
            let contentKey = Self.contentKey(for: item,messages: messages,messageIndex: messageIndex)
            layout.setContentKey(contentKey,at: i)
            // Content-aware spacing policy — must run
            // BEFORE the cachedHeight guard below, or footers that
            // already measured would skip it and fall back to the
            // default hug, re-gluing a prominent banner on the next
            // prepare(). Hug ONLY when the footer shows the quiet
            // meta/usage row (or nothing); error banner / resume banner
            // / typing indicator keep the full itemSpacing (user report
            // 2026-07-21). Mirrors BridgedAssistantFooter's sections.
            var footerProminent = false
            // 估高与 hug 解耦：hug 只看 prominent（视觉策略不变），
            // 估高按 footer 将渲染的形态取值——终态状态行/回复中指示器
            // 实际 ~18pt，errored/resume 横幅 ~44-56pt，空 footer ~0-4pt。
            // 固定 4pt 种子 vs 18pt 状态行 = 每条历史 AI 回复 +13~14pt
            // 系统性低估，是重进会话上滑抖动的主误差源（2026-09-06 方案 A）。
            var footerEstimate: CGFloat = 4
            if case .assistantFooter(let footerMID) = item {
                let footerMsg = messageIndex[footerMID].flatMap {
                    $0<messages.count ? messages[$0] : nil
                }
                let isTailMsg = messages.last?.id == footerMID
                let errored = footerMsg?.error != nil
                let canResumeFlag = isTailMsg && !errored
                    && vm.canResume && !vm.isProcessing
                let isActive = isTailMsg && vm.isProcessing
                footerProminent = errored || canResumeFlag || isActive
                layout.setFooterHug(!footerProminent,at: i)
                if errored || canResumeFlag {
                    footerEstimate = 48
                } else if isActive || (footerMsg?.footerShowsQuietStatusRow ?? false) {
                    footerEstimate = 18
                }
            }

            // 守卫语义 = 旧三字典的「仅实测高度跳过」。合并字典后
            // cachedHeight 对 estimated/precalc 也返回值，若用它挡守卫，
            // 流式文本块的首帧估高会永久冻结（重播种被跳过），正文
            // 停在首帧高度与下方内容重叠（2026-09-05 回归）。
            guard !layout.hasMeasuredHeight(at: i) else { return }

            // Re-entry seed: if we have a real measured height for this
            // exact content key at this width, use it as precalc — the
            // cell lands at its true height with zero on-screen jump.
            if let memo = layout.measuredHeight(forKey: contentKey,width: cvWidth) {
                layout.setPrecalcHeight(memo,at: i)
                return
            }

            switch item {
            case .assistantHeader:
                // Header is always a fixed "sparkles MiniClaw" label row (measured: 28pt)
                layout.setEstimatedHeight(28,at: i)

            case .assistantFooter:
                // Prominent banners (error/resume) measure
                // ~44-56pt; quiet status row / replying indicator
                // ~18pt; empty footer ~0-4pt.
                layout.setEstimatedHeight(footerEstimate,at: i)

            case .assistantBlock(let msgId,let blockId):
                guard let msgIdx = messageIndex[msgId],msgIdx<messages.count else { return }
                let msg = messages[msgIdx]
                guard let block = msg.blocks.first(where: { $0.id == blockId }) else { return }

                switch block.kind {
                case .text:
                    // Use TextKit layout for accurate height pre-calculation.
                    // Results are cached by NSAttributedString identity to avoid
                    // redundant TextKit layout on repeated snapshots.
                    if let attrStr = block.cachedAttributedString {
                        let textWidth = max(cvWidth-32,100)
                        let key = ObjectIdentifier(attrStr)
                        let height: CGFloat
                        if let cached = attrStringHeightCache[key] {
                            height = cached
                        } else {
                            height = Self.measureAttributedStringHeight(attrStr,width: textWidth)
                            attrStringHeightCache[key] = height
                        }
                        // height includes the text view's 8pt insets;
                        // +4 = the SwiftUI wrapper's .padding(.vertical, 2)
                        layout.setPrecalcHeight(height+4,at: i)
                        #if DEBUG
                        if !isReseed,ScrollMetricsRecorder.shared.isEnabled {
                            let c = block.content
                            let feats = "code=\(c.contains("```") ? 1 : 0)|tbl=\(c.contains("|") ? 1 : 0)|list=\(c.range(of: #"(?m)^\s*[-*+] "#, options: .regularExpression) != nil ? 1 : 0)|head=\(c.range(of: #"(?m)^#{1,6} "#, options: .regularExpression) != nil ? 1 : 0)|icode=\(c.contains("`") ? 1 : 0)|bold=\(c.contains("**") ? 1 : 0)|nl=\(c.filter { $0 == "\n" }.count)|n=\(c.count)"
                            ScrollMetricsRecorder.shared.record(
                                kind: "seed", idx: i, a: height+4,
                                key: contentKey, src: "tv", note: feats,
                                tag: Self.stableCellTag(for: item,messages: messages,messageIndex: messageIndex))
                        }
                        #endif
                    } else if block.content.isEmpty {
                        layout.setEstimatedHeight(0,at: i)
                    } else {
                        let est = Self.estimateItemHeight(item,messages: messages,width: cvWidth)
                        layout.setEstimatedHeight(est,at: i)
                    }
                case .thinking:
                    let est = Self.estimateItemHeight(item,messages: messages,width: cvWidth)
                    layout.setEstimatedHeight(est,at: i)
                case .readImageTool:
                    layout.setEstimatedHeight(36,at: i)
                case .file:
                    layout.setEstimatedHeight(40,at: i)
                case .info:
                    let infoLines = max(1, block.content.components(separatedBy: "\n").count)
                    layout.setEstimatedHeight(CGFloat(20+infoLines*16),at: i)
                default:
                    // Tool capsules (execute, browser, etc.) are 36pt
                    layout.setEstimatedHeight(36,at: i)
                }

            case .wholeMessage(let msgId):
                if let msg = messages.first(where: { $0.id == msgId }),
                   msg.role == .user {
                    let effWidth = maxContentWidth>0 ? min(cvWidth,maxContentWidth) : cvWidth
                    let h = Self.measureUserBubbleHeight(for: msg,cvWidth: effWidth,
                                                         cache: &userBubbleHeightCache)
                    if let h {
                        layout.setPrecalcHeight(h,at: i)
                        #if DEBUG
                        if !isReseed,ScrollMetricsRecorder.shared.isEnabled {
                            let c = msg.content
                            let cjk = c.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
                            let feats = "cjk=\(cjk ? 1 : 0)|nl=\(c.filter { $0 == "\n" }.count)|n=\(c.count)|att=\(msg.attachments.count)|inAtt=\(msg.inputAttachments.count)|tag=\(c.contains("<user-attached-files>") ? 1 : 0)"
                            ScrollMetricsRecorder.shared.record(
                                kind: "seed", idx: i, a: h,
                                key: contentKey, src: "bubble", note: feats,
                                tag: Self.stableCellTag(for: item,messages: messages,messageIndex: messageIndex))
                        }
                        #endif
                    } else {
                        layout.setEstimatedHeight(
                            Self.estimateItemHeight(item,messages: messages,width: cvWidth),at: i)
                    }
                } else {
                    // compactDivider / systemInfo — coarse estimate is fine
                    let est = Self.estimateItemHeight(item,messages: messages,width: cvWidth)
                    layout.setEstimatedHeight(est,at: i)
                }
            }
        }

        func reconfigureAllCells() {
            viewController?.messageListLayout?.clearHeightCache()
            attrStringHeightCache.removeAll()
            userBubbleHeightCache.removeAll()
            reconfigureVisibleCells()
        }

        /// Reconfigure all cells without clearing the height cache.
        /// Used after compact to update opacity without losing measured heights.
        func reconfigureVisibleCells() {
            var snapshot = dataSource.snapshot()
            let items = snapshot.itemIdentifiers
            guard !items.isEmpty else { return }
            snapshot.reconfigureItems(items)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            dataSource.apply(snapshot,animatingDifferences: false)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = false
        }

}
