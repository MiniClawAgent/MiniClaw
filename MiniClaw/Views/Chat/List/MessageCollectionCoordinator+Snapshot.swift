import SwiftUI
import UIKit
import Combine
import Foundation

extension MessageCollectionView.Coordinator {

        /// When a snapshot is deferred (e.g. streaming UI updates suspendedFlag),

        // MARK: - 高度播种的唯一入口（2026-09-13 出入口统一）

        /// 「保证某些 index 有**当期**高度条目」的作用域策略。
        ///
        /// 此前这件事散在**三处**、各写一遍循环，策略不同但语义同一 —— 现在收敛为一个入口
        /// + 一个显式策略参数（与 `MessageListLayout.MemoPolicy` 同一思路）。
        /// 差异成为**参数**，而不是"散落在三个地方、靠注释各自说明"的隐式差别。
        enum SeedScope {
            /// 全部 item。`seedHeight` 内部对 `.measured` 早退 ⇒ 不会覆盖实测值（只刷新估算/预演）。
            case all
            /// 本次**新增**的 item：先只清索引条目（**保留** memo，见下）再播种。
            case inserted([MessageListItem])
            /// 仅这些 index（UIKit 预取回调）：只给尚未实测的行播种，避免全表扫描。
            case indices([Int])
        }

        /// 高度播种的**唯一入口**。
        ///
        /// ⚠️ **调用时机由调用方保证，且不可变**（顺序敏感点 S1/S4）：
        /// `inserted` 与 `missing` 两次播种**必须早于 `dataSource.apply`** —— 否则 apply 触发的
        /// 布局 `prepare()` 会读不到条目、落 `estimatedItemHeight`(200pt) 兜底 ⇒ 虚高帧 ⇒
        /// 手势期收缩被拒 ⇒ **拖动期大片空白**（真机量化 Σ928.6pt/38 格位）。
        /// 本函数只统一**实现**，不改变各调用点的时间位置。
        func seedHeights(_ scope: SeedScope, rows: [MessageListItem],
                         messages: [RenderMessage], width: CGFloat) {
            switch scope {
            case .all:
                for (i, item) in rows.enumerated() {
                    seedHeight(at: i, item: item, messages: messages, width: width)
                }
            case .inserted(let items):
                for item in items {
                    guard let idx = rows.firstIndex(of: item) else { continue }
                    guard let layout = viewController?.messageListLayout else { continue }
                    // 只清索引条目、**保留** content-keyed memo：紧接着的重播种要读它。
                    // 若连带剔 memo（`.withMemo`），种子会退化为粗估 ⇒ 上滑抖动（2026-09-06 真机）。
                    layout.invalidateHeight(at: idx, memo: .indexOnly)
                    seedHeight(at: idx, item: item, messages: messages,
                               width: width, isReseed: true)
                }
            case .indices(let idxs):
                guard let layout = viewController?.messageListLayout else { return }
                // [P1-9] 判据从"没有条目"改成"没有实测"：`invalidateHeight` 现在是**降级不删除**
                // （条目仍在、source 变 estimated），用 cachedHeight == nil 会导致重播种整段跳过。
                for i in idxs where i >= 0 && i < rows.count
                    && !layout.hasMeasuredHeight(at: i) {
                    seedHeight(at: i, item: rows[i], messages: messages,
                               width: width, isReseed: true)
                }
            }
        }

        func applySnapshot(messages rawMessages: [RenderMessage], caller: String = "?") {
            guard let vm,!vm.isLoadingSession else { return }

            // Single UI-collection sink for EVERY
            let messages = rawMessages.contains(where: { $0.isInternalBridge })
                ? rawMessages.filter { !$0.isInternalBridge }
                : rawMessages

            // anchorY may no longer line up, so restart it on the next tap.
            lastJumpedUserId = nil

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
                        // [2026-09-13 「带图片回复上滑跳位」修复·诊断] 本 handler 是**唯一**会对
                        // "全表高度"动手、却**完全没有偏移锚定**的路径；而只有附件（图片）会发这个
                        // 通知 —— 正好解释了"只有带图片的 AI 回复才跳"。
                        //
                        // 图片附件高度是**异步**确定的：`attachmentBounds` 先返回占位 200pt，
                        // 加载完成后返回真实高度并发出本通知（机制见 `MarkdownAttachments` 中
                        // "SwiftUI sizeThatFits → attachmentBounds → placeholder 200pt … 异步加载
                        // 完成，attachmentBounds now returns 280pt" 那段注释）。于是原实现造成两件事：
                        //   ① 全表 `invalidateHeight` 之后**没有重播种** ⇒ 每个 index 都变"无条目"，
                        //      `prepare()` 只能落到「按内容键前缀选类型常量」（`b:` → 36/40），
                        //      离屏长正文被算成几十点 ⇒ **contentSize 整体塌缩**；
                        //   ② 塌缩之后 `contentOffset` 是**数值不变**的 ⇒ 同一数值指向完全不同的内容
                        //      ⇒ 用户看到的就是「突然跳到聊天记录的其他位置」。
                        // 修法与既有纪律一致：失效后立刻重播种（唯一入口）+ 重排前后按身份锚定。
                        let urlStr = (notification.object as? String) ?? "<nil>"
                        // 贴底时**不**锚定 —— 那时应继续贴底，交给既有 pin 机制（contentSize KVO）。
                        let topAnchor: ViewportTopAnchor? =
                            (self.scrollMode == .autoScrolling || self.isNearBottom())
                            ? nil : self.viewportTopAnchor()
                        let visibleIPs = cv.indexPathsForVisibleItems.sorted()
                        var cleared = 0
                        for ip in visibleIPs {
                            if let cell = cv.cellForItem(at: ip) as? SelfSizingCell {
                                cell.clearCachedHeight()
                                layout.invalidateHeight(at: ip.item)
                                cleared += 1
                            }
                        }
                        // ── 只失效「含该附件的那些行」（全表失效是历史遗留，且**有害**）────────
                        // 通知的 object 是**来源串**（src），不是消息 id ⇒ 按内容反查归属。
                        // 为什么不能全表：全表失效 + 全表 reconfigure 会在图片异步加载期间**反复**
                        // 把 cell 打回"重新量一次"的状态，而重量的那一刻 storage 可能还没重建完
                        // ⇒ 量出 `orig=451.7→pref=32.0` 这种荒唐值（真机 22:33:26 实证），
                        // 而收缩又被手势期策略拒绝 ⇒ 帧留在 451.7、内容只有一小截
                        // = 「文字被裁 + 下面一大片空白」。
                        let seedMessages = self.snapshotMessages.isEmpty
                            ? (self.vm?.messages ?? []) : self.snapshotMessages
                        var byId: [UUID: RenderMessage] = [:]
                        for m in seedMessages { byId[m.id] = m }
                        var affected: Set<Int> = []
                        for (i, item) in self.prevSnapshotIds.enumerated() {
                            guard case .assistantBlock(let mid, let bid) = item,
                                  let msg = byId[mid],
                                  let blk = msg.blocks.first(where: { $0.id == bid }),
                                  blk.kind == .text,
                                  blk.content.contains(urlStr) else { continue }
                            affected.insert(i)
                        }
                        // 归属查不到（src 被规范化过 / 该行已不在快照里）⇒ 退化为"只处理可见行"，
                        // **绝不退回全表**：全表正是上面那个荒唐测量的来源。
                        if affected.isEmpty { affected = Set(visibleIPs.map(\.item)) }
                        for idx in affected {
                            layout.invalidateHeight(at: idx)
                            (cv.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell)?
                                .clearCachedHeight()
                        }
                        // 失效后**只对这几行**重播种：唯一入口 `seedHeights(.indices:)`，
                        // 且 rows 与 messages 来自**同一次快照**（都用 `prevSnapshotIds` + 同一份
                        // `seedMessages`）—— 此前用 `rows: prevSnapshotIds` 配"现场取的 vm.messages"，
                        // 两侧 id 集合可能已经错位 ⇒ 成片 `[Seed] 消息 … 无块 … 兜底估高 44pt`。
                        self.seedHeights(.indices(Array(affected)),rows: self.prevSnapshotIds,
                                         messages: seedMessages,width: cv.bounds.width)
                        if let snapshot = self.dataSource?.snapshot() {
                            // 只重配**受影响的那几行**：原先 `reconfigureItems(全部)` 会把整表 cell
                            // 打回"重新量一次"，那正是 `orig=451.7→pref=32.0` 荒唐测量的来源。
                            var snap = snapshot
                            let items = snapshot.itemIdentifiers
                            let ids = Array(affected).sorted()
                                .compactMap { $0 < items.count ? items[$0] : nil }
                            if !ids.isEmpty { snap.reconfigureItems(ids) }
                            self.dataSource?.apply(snap,animatingDifferences: false)
                        }
                        DispatchQueue.main.async {
                            for ip in cv.indexPathsForVisibleItems {
                                (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                            }
                            layout.invalidateLayout()
                            if self.clampAfterSessionLoad {
                                self.scrollToLastItem()
                            } else {
                                // ── B. 重排后按**身份**把锚点 item 放回同一屏内位置 ──────────
                                // 全表失效时 `aboveΣ` 无法求和（"上方变化"退化成"整表变化"），
                                // 故只能靠"同一个 item 回到同一屏内位置"。
                                self.restoreViewportTopAnchor(topAnchor,reason: "attachmentSize")
                            }
                        }
                        alog.info("[AttachmentSize] url=\(urlStr) cleared=\(cleared)/\(visibleIPs.count) affected=\(affected.count) clamp=\(self.clampAfterSessionLoad)")
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
                        // a tall empty gapH below the collapsed pill (user
                        var matched = false
                        for (i,item) in snapshot.itemIdentifiers.enumerated() {
                            if case .assistantBlock(_,let bid) = item,bid == blockId {
                                matched = true
                                let beforeLayout = layout.cachedHeight(at: i)
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
                                tlog.info("[Collapse] HIT block=\(blockId.uuidString.prefix(8)) idx=\(i) cellFound=\(cellOpt != nil) frameH=\(String(format: "%.1f", frameH)) beforeLayout=\(beforeLayout.map { String(format: "%.1f", $0) } ?? "nil")")
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

            messageIndex.removeAll(keepingCapacity: true)
            for (i,msg) in messages.enumerated() {
                messageIndex[msg.id] = i
            }

            let currentIds = Set(messages.map(\.id))
            let removedIds = Set(cellBridgeMap.keys).subtracting(currentIds)
            for id in removedIds { bridgeSheetSubs.removeValue(forKey: id) }
            cellBridgeMap = cellBridgeMap.filter { currentIds.contains($0.key) }

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
                    // 2026-09-05 TopFlow要求：**每一条** AI 回复都持久显示状态行（已完成/已停止/
                    // 已中断 + 耗时），不再只显示最后一条。
                    // [Stage 1 · §6.3.1 A19] 原判据是六路析取
                    // `isLastAssistant || role == .assistant || error != nil
                    //  || streamInterruptCount>0 || canResume || showUsage`。本分支已在
                    // `switch message.role { case .assistant: }` 内，而 `RenderMessage.role` 是
                    // 不可变 `let`（RenderModels.swift:285）⇒ 第二项**结构上恒真**，整个析取恒真。
                    // 故简化为无条件追加；连带删掉 `isLastAssistant`——它是一次
                    // `messages.last(where:)` 的 **O(n) 线性扫描**，且因析取短路被**先求值再丢弃**，
                    // 每条 assistant 消息白跑一次。
                    newRows.append(.assistantFooter(message.id))
                }
            }

            // [2026-09-13 出入口统一·删除冗余实现] 原此处先调 `layout.updateCacheForSnapshot`，
            // 随后又有一次 `remapHeights` 对**同一 old→new 映射**跑一遍 —— 两份实现做同一件事，
            // 且 `remapHeights` 是前者的**严格超集**（还搬 contentKeyByIndex / footerHugByIndex /
            // metricsTagByIndex）；早退路径上 old==new 属恒等映射，前者净效果为零。⇒ 语义等价，已删除。

            // ── 段 0：身份迁移（唯一入口 `remapHeights`）· 必须早于任何播种 ──────────
            //
            // [2026-09-13 P3·S4「由注释变结构」] 此前 `remapHeights` 排在 `seedHeights(.all)`
            // **之后**，而两者都写 `contentKeyByIndex` ⇒ 互相拆台：
            //   ① `.all` 播种先按**新索引**重写整表内容键（`seedHeight` 内的 `setContentKey`）；
            //   ② 随后的 `remapHeights` 用 `contentKeyByIndex[oldIndex]` 去写 `newIndex`
            //      —— 读到的是「新索引体系下**旧下标**那个 item 的键」，与被搬移条目自带的键错配。
            // 后果（`currentEntry` 的键一致性判据）：`stored != cur` ⇒ 刚迁移来的 `.measured`
            // 条目被整体判为陈旧 ⇒ **迁移等于白做**；`footerHugByIndex` 同样被搬错。
            // 顺序改成「先迁移、后播种」即根治：迁移读到的是**原封未动的旧键**（正确），
            // 播种随后安装正确的新键，并对内容未变的 `.measured` 条目早退（保留实测值）。
            //
            // 身份集合未变时是恒等映射，跳过（省一次全表重建）。
            let identityUnchanged = (newRows == prevSnapshotIds)
            let oldRows = prevSnapshotIds
            let oldSet = Set(prevSnapshotIds)
            let inserted = newRows.filter { !oldSet.contains($0) }
            // 高度按行身份存储，行号位移不再丢条目 ⇒ 只需要把**当前顺序**告诉布局，
            // 让「行号 → 身份」的翻译可用。不再有 remap（它的 `continue` 就是丢条目的入口）。
            // 即使 identityUnchanged 也同步一次：开销是一次数组赋值，换来顺序永不过期。
            viewController?.messageListLayout?.setOrder(newRows)

            // ── 段 1：播种（唯一入口 `seedHeights`）───────────────────────────────
            if viewController?.messageListLayout != nil {
                seedHeights(.all, rows: newRows, messages: messages,
                            width: viewController?.collectionView.bounds.width ?? 390)
            }
            itemToIndex.removeAll(keepingCapacity: true)
            for (i,item) in newRows.enumerated() {
                itemToIndex[item] = i
            }

            // them. Not just the LAST
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
            //
            viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            let oldCount = prevSnapshotIds.count
            // created RenderMessage/AssistantBlock objects (new UUIDs) — the
            //
            snapshotMessages = messages

            // [2026-09-11 TopFlow补充] 最终回复（loop 末轮）**后面不接任何指示器**，
            // 借不到「指示器出现」的节律 → 改在「整轮结束」（isProcessing 由 true→
            // false）时对最后一个文本块失效重测，避免最终回复少字/少行。
            // 必须放在早退之前：终态那次 item 身份集合通常不变（footer 还是同一个
            // item），早退会让后续所有失效逻辑都不执行。
            let nowProcessing = vm.isProcessing
            if lastWasProcessing,!nowProcessing {
                reseedTrailingTextBlock(rows: newRows,messages: messages)
            }
            lastWasProcessing = nowProcessing

            // 段 0 已算好 `identityUnchanged` / `oldRows` / `inserted`，此处只做提交。
            if identityUnchanged { return }
            prevSnapshotIds = newRows

            var snapshot = NSDiffableDataSourceSnapshot<MessageCollectionView.Section,MessageListItem>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newRows,toSection: .main)
            let snapshotLayout = viewController?.messageListLayout
            // [2026-09-09 快照缓存重映射] 身份重映射已上移到「段 0」——**必须早于播种**
            // （理由见段 0 注释：先迁移读到的是旧键，后迁移读到的是被播种改写过的键）。
            // 此处只保留 `snapshotLayout` 供下方 apply 前后的 offset 补偿使用。

            // [2026-09-11 TopFlow思路] loop 结构决定「回复之后必接思考/工具指示器」——
            // 指示器出现的那一刻 = 上一段文本块已定型（后面不可能再长字）。
            // 利用这个天然节律：在 dataSource.apply **之前**先把上一段文本块的索引高度
            // 作废并重测，让补齐发生在「新指示器渲染之前」——视觉顺序变成
            // 「上一句收尾 → 指示器出现」，消除原来「新卡先出、旧句后跳」的割裂。
            // 相比「给 HeightEntry 加内容版本」：不改结构、不动优先级、不引入新状态。
            if !inserted.isEmpty {
                let insertedSet = Set(inserted)
                for item in inserted {
                    guard let insIdx = newRows.firstIndex(of: item) else { continue }
                    reseedTextBlock(before: insIdx,rows: newRows,messages: messages,insertedSet: insertedSet)
                }
            }

            // [2026-09-13 空白根治] **把新 item 的高度播种提到 `dataSource.apply` 之前**。
            //
            // 病根：此前「inserted 补播」与「缺失条目全扫补播」都排在 apply **之后**，而 apply
            // 会立刻触发一次布局 `prepare()`。那一刻这些 index 还没有条目 ⇒ `prepare()` 落到
            // 兜底 `estimatedItemHeight`(200pt) ⇒ **帧被算成 200**；随后 PLAF 量出真实值
            //（如 36/40/57pt）要求收缩，而 `shouldInvalidateLayout` 的 `deferSelfSizing` 分支
            // 在**手势期间一律拒绝收缩**（`MessageListLayout.swift:356-374`）⇒ cell 继续占据
            // 200pt 虚高帧 ⇒ **大片空白**；settle 时 `applyDeferredHeights()` 才落盘 ⇒ 空白
            // "松手即消失"。
            // 真机量化（`[DeferShrink]` 台账，一次拖动 3 秒内）：Σ|delta| = **928.6pt**、
            // 单条最大 **−164.0pt**（`200.0→36.0`）、`pos` **全部 inside**、src 为
            // estimated×8 / precalc×3。`[BlankProbe2]` 同步显示 `cellH=200/contentH=118`
            //（差 82pt）与 `cellH=40/contentH=0`。
            //
            // ⚠️ 注意 `−164.0 / 200→36` 与 2026-09-12 那次「`liveShrink` 抖动事故」的数字
            // **逐位相同**：那次是用「禁止手势期收缩」修掉的，代价正是今天这个空白。
            // 两者同根 = **帧被算成 200**。故**治本点是别让 `prepare()` 看到 200**，
            // 而不是放宽那个门（放宽＝把 −160pt 的抖动放回来）。
            // 播种提前后：`prepare()` 直接读到正确条目 ⇒ 既不产生虚高帧、也就没有"需要拒绝的
            // 收缩" ⇒ 空白与抖动同时不成立。这也是 `reseedTextBlock(before:)`（本文件）
            // 已经采用的正确时序（"让补齐发生在渲染之前"）。
            // [2026-09-13] 此处原先写死行号 `:247`，已因搬移失效 —— 跨文件/跨段引用一律用符号名。
            if let cv = viewController?.collectionView {
                // 两处播种统一走同一入口（策略成为参数）：新增项 → 缺失项。
                // ⚠️ 时机仍在 `dataSource.apply` **之前**（顺序敏感点 S1）。
                if !inserted.isEmpty {
                    seedHeights(.inserted(Array(inserted)), rows: newRows,
                                messages: messages, width: cv.bounds.width)
                }
                // [2026-11-15 高度重写] 原先这里还有一次 `.missing` 全表扫描（判据 cachedHeight==nil）。
                // 它恒不生效：前面的 `.all` 已逐条播种，而 `seedHeight` 的每条出口都会写条目。
                // 删掉省下每次快照一次 O(n) 扫描；`cachedHeight` 现在也永不因"内容过期"返回 nil
                // （过期只降级、不丢高度），这个判据本身已失去意义。
            }

            snapshotLayout?.suppressContentOffsetAdjustment = true
            flushingNow = true
            cellConfigCount = 0
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            dataSource.apply(snapshot,animatingDifferences: false)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = false
            viewController?.collectionView.setNeedsLayout()

            if let cv = viewController?.collectionView {
                // [2026-09-13 空白根治] 原在此处的两段补播——「本次新增（inserted）补播」与
                // 「按缺失条目全扫补播」——**已上移到 `dataSource.apply` 之前**（见上方同名
                // 根治注释）。它们排在这里（apply 之后）时，apply 触发的那次布局 `prepare()`
                // 看不到新 index 的条目 ⇒ 落到 200pt 兜底 ⇒ 虚高帧 ⇒ 拖动期空白。
                // 提前后此处无需补播，那次为"补播后必须重排"而设的 `!deferSelfSizing` 门控
                // 也随之取消（不再存在"补播晚于布局"的窗口）。
                cv.layoutIfNeeded()
                snapshotLayout?.suppressContentOffsetAdjustment = false
                flushingNow = false
                let rawMaxOff = cv.contentSize.height-cv.bounds.height+cv.adjustedContentInset.bottom
                let maxOff = max(0,rawMaxOff)
                // [2026-11-15 空白] offset 越界兜底：下面的收缩分支只覆盖「行数减少」，
                // 而 footer 状态变化/工具块/思考块收缩时**行数不变**，此前没有任何 clamp
                // ⇒ offset 停在内容底部之外，底部留白。这里补一条与行数无关的通用收敛。
                if cv.contentOffset.y > maxOff + 0.5, !cv.isDragging, !cv.isDecelerating {
                    cv.setContentOffset(CGPoint(x: 0, y: maxOff), animated: false)
                    applySubViewportCompensation(caller: "snapshot-overrun", forceRelax: true)
                } else if newRows.count<oldCount && cv.contentOffset.y>maxOff {
                    cv.setContentOffset(CGPoint(x: 0,y: maxOff),animated: false)
                    // overflowH region — re-evaluate compensation so any
                    // and would leave a permanent blank gapH at the bottom.
                    applySubViewportCompensation(caller: "snapshot-shrink", forceRelax: true)
                } else if scrollMode == .autoScrolling && maxOff>0 {
                    cv.contentOffset.y = maxOff
                    // flushingNow suppresses it. The coalesced scroll (80ms) catches the
                    scheduleCoalescedScroll()
                } else {
                    applySubViewportCompensation(caller: "snapshot-subVP")
                }
                // under flushingNow=true, which suppresses the contentSize KVO
                // (sub-viewport overflowH) without anyone updating vm.isNearBottom,
                if let vm = self.vm {
                    let nbFlag = isNearBottom()
                    if vm.isNearBottom != nbFlag {
                        #if DEBUG
                        // [Stage 2 · A1 收口·第三轮] 本处是 `applySnapshot` 内的**独立**写点
                        //（不走 `syncScrollFlags`），且 `applySnapshot` 可经
                        // `updateUIViewController` → `rebindViewModelIfNeeded` 落在更新事务内。
                        SwiftUIUpdatePhase.reportIfInUpdate("applySnapshot.isNearBottom")
                        #endif
                        vm.isNearBottom = nbFlag
                    }
                }
                syncScrollFlags()
                // [T-perf 2026-09-08 渲染架构专项] 首帧稳定后后台预测量：把全部
                // 文本块的精确高度预先写入统一缓存——滑动到任何位置（含消息边界）
                // 时 PLAF 直接命中缓存，消除「首次进入视口 hosting 实测 60-144ms/
                // 块」的边界卡顿。仅会话进入类快照触发（流式增量快照不需要）。
                // [2026-09-08 交汇处卡顿修复] 触发名单加入**流式结束**（stream-end /
                // bind4b-blockCount）：本轮流式产生的新块从未被 prewarm 覆盖 →
                // 回滑到新旧消息交汇处时首入视口全量实测 → 定点卡一下。流式结束
                // 为低频事件，强制预排版（绕过 30s 去重）。
                let isStreamEnd = caller.contains("stream-end") || caller.contains("bind4b")
                if caller.contains("loadSession") || caller.contains("suspend-resume")
                    || caller.contains("bind1-messages") || isStreamEnd {
                    Self.scheduleHeightPrewarm(messages: messages, cvWidth: cv.bounds.width,
                                               force: isStreamEnd)
                }
                // [2026-09-17 **撤销自动触发**] 此处原有对 `runStage0HarnessOnce()` 的调用，
                // 它会在每次会话进入时**主动程序化滚动 6 步 ×3 遍**。后果是**用户一进会话就被自动
                // 滚到别处**（用户实测反馈），属不可接受的干扰，故**删除该调用**。
                //
                // 结论：LayoutHarness 改为**纯 opt-in**——没有任何自动触发点；即便从调试器手动调用，
                // 它也要求 `ScrollMetricsRecorder.shared.isEnabled` 为真（见 `+Scrolling.swift`）。
                // 而且它本来就**替代不了人工拖动**（程序化滚动不产生 `isTracking`/`isDragging`，
                // 拿不到 M10/M11/M12/[DeferShrink]/[SettleAnchor] 的数据），
                // 用户已明确由自己完成全部拖动 ⇒ 自动触发没有存在价值，只有副作用。
                //
                // ⚠️ 数据有效性影响：此前几轮里 `[Stage0][harness]` 的指标、以及 M13/M14/M15 的样本，
                // 有一部分是在**这个自动滚动之后**的状态取的 ⇒ 需要用"关闭 harness 的纯人工拖动"重取一遍。
            } else {
                snapshotLayout?.suppressContentOffsetAdjustment = false
                flushingNow = false
            }
        }

        /// 播种单个 item 的估高（原种子循环主体，抽成方法以便 apply 后对被
        /// 清理的 insert 索引重播）。applySnapshot 里旧 cell 脏写被清掉后必须
        /// [T-perf 2026-09-08 渲染架构专项] 后台高度预测量：进入会话首帧稳定后，
        /// 对全部文本块用**独立 TextKit1 栈**（线程隔离，不与主线程共享任何
        /// layout 对象）排版出精确高度，连同渲染结果一并写入进程级统一缓存
        ///（MarkdownRenderCache）——滑动到任何位置（含消息边界）时 PLAF 的
        /// hosting 实测直接命中缓存，消除「首次进入视口 60-144ms/块」的边界卡顿。
        /// 每次会话进入类快照都会重跑（缓存命中时写入为幂等 no-op，成本仅后台排版）。
        /// [2026-09-08 风暴修复] 前版缺陷：① caller "bind1-messages" 匹配**所有**快照
        ///（含流式期每 400ms 一次）→ 每次全量重测 428 块 + 1284 次零散 MainActor
        /// 写回轰炸主线程（snap.diffable applied 8552ms）。修复：30s 去重窗口 +
        /// 主线程收集时增量过滤（已有高度的块跳过）+ 测量完一次性批量写回。
        private static var lastPrewarmAt: CFTimeInterval = 0

        /// [2026-09-08] `force` = 流式刚结束（stream-end/bind4b）：本轮流式产生的
        /// 新块此前从未被 prewarm 覆盖（触发名单只有会话进入类 caller + 30s 去重），
        /// 用户回滑到「新旧消息交汇处」时这些块首入视口 → 含表格块走
        /// `mtv.attributedText` 全量重排（755-811ms）→ **定点卡一下**。
        /// 流式结束是低频事件，此处强制预排版（绕过 30s 去重）。
        private static func scheduleHeightPrewarm(messages: [RenderMessage], cvWidth: CGFloat, force: Bool = false) {
            let now = CACurrentMediaTime()
            guard force || now - lastPrewarmAt > 30 else { return }
            lastPrewarmAt = now

            let fontSize = FontSettings.shared.scaledMessage(16.5)
            // 两个探测宽度：PLAF 以 402（边界宽）/370（内容宽）交替询问，都预填。
            let widths = [Int(cvWidth), Int(cvWidth - 32)].filter { $0 > 50 }
            guard !widths.isEmpty else { return }
            // 主线程收集 + 增量过滤：统一缓存已有全部宽度高度的块跳过
            //（流式期重复快照时 entries 几乎为空 → 后台任务直接返回，零成本）。
            // [2026-09-08] **含附件块不再被排除**：height-only entry（store(height:)
            // 已与 attributed 解耦）使附件块也能只缓存高度；后台独立 TextKit 栈排版
            // 会调用 attachmentBounds——已核对其全部为纯计算（UIFont 系统字体 +
            // 尺寸算术），无主线程状态依赖，后台测量安全。仅 **不写 attributed**
            //（附件实例与 renderer 身份耦合，维持既有口径）。
            var entries: [(key: String, attr: NSAttributedString, rich: Bool)] = []
            for m in messages where m.role == .assistant {
                for blk in m.blocks where blk.kind == .text && !blk.content.isEmpty {
                    guard let attr = blk.cachedAttributedString, attr.length > 0 else { continue }
                    let c = blk.content
                    // [2026-09-13 缓存串味修复] 补结构判据：源文启发式 `hasRichSyntax` 只查
                    // `$$`，漏判行内 `$...$`（会产出 MathAttachment）⇒ 会放行带附件的产物
                    // 进共享缓存。故对渲染产物本身再判一次，与 MarkdownView 写入口径统一。
                    // [2026-09-13 判据统一] 该"源文 OR 产物"组合已收口为唯一入口
                    // `hasRichSyntaxOrAttachment`，此处改为调用它（不再各自拼一遍）。
                    let rich = AssistantBlock.hasRichSyntaxOrAttachment(c,rendered: attr)
                    let key = MarkdownRenderCache.key(for: c, fontSize: fontSize)
                    if widths.allSatisfy({ MarkdownRenderCache.shared.cachedHeight(for: key, width: $0) != nil }) {
                        continue // 已有全部宽度高度——增量跳过
                    }
                    entries.append((key, attr, rich))
                }
            }
            guard !entries.isEmpty else { return }
            // 跨 Task 边界传递的非 Sendable 负载（NSAttributedString 等）装入
            // @unchecked Sendable 盒：这些值由后台任务独占构造、只读传递，
            // 不跨线程共享可变状态，语义与迁入前一致。
            let entryBox = MeasuredEntryBox(entries: entries)
            Task.detached(priority: .utility) {
                // 独立 TextKit1 栈：NSLayoutManager 非线程安全，但本栈为
                // 后台任务私有实例、不与主线程共享，排版只读不可变 attrStr。
                var results: [(key: String, attr: NSAttributedString, heights: [Int: CGFloat], rich: Bool)] = []
                for entry in entryBox.entries {
                    let storage = NSTextStorage(attributedString: entry.attr)
                    let lm = NSLayoutManager()
                    let tc = NSTextContainer(size: CGSize(width: CGFloat(widths[0]), height: .greatestFiniteMagnitude))
                    tc.lineFragmentPadding = 0
                    lm.addTextContainer(tc)
                    storage.addLayoutManager(lm)
                    var heights: [Int: CGFloat] = [:]
                    for w in widths {
                        tc.size = CGSize(width: CGFloat(w), height: .greatestFiniteMagnitude)
                        lm.ensureLayout(for: tc)
                        heights[w] = ceil(lm.usedRect(for: tc).height) + 8  // 对齐 textContainerInset(4+4)
                    }
                    results.append((entry.key, entry.attr, heights, entry.rich))
                }
                // 测量完一次性批量写回（避免逐块 MainActor 调度轰炸主线程）。
                // 含附件块只写 heights（height-only entry）——不写 attributed
                //（附件实例与 renderer 身份耦合，维持既有口径）。
                let resultBox = MeasuredResultBox(results: results)
                await MainActor.run {
                    for r in resultBox.results {
                        if !r.rich {
                            MarkdownRenderCache.shared.store(attributed: r.attr, key: r.key)
                        }
                        for (w, h) in r.heights {
                            // [Stage 3 · S3.1] **只补不覆盖**的语义不再靠特例方法，
                            // 而由「`.prewarm` 是最低等级」构造性保证（见 `HeightGrade`）。
                            // 本栈与渲染引擎不同源（实测同内容同宽度矮 12.3pt），覆盖会毒化
                            // 屏上测量 → 裁尾。
                            MarkdownRenderCache.shared.store(height: h, key: r.key, width: w, grade: .prewarm)
                        }
                    }
                }
            }
        }

        /// 重新播种，否则该 item 落到 `estimatedItemHeight`(200pt) 并首次自测
        /// 大修正 → 重进会话上滑抖动（2026-09-06）。
        /// 从行尾往前找第一个「已完结文本块」，把它作废并重测（供指示器插入时调用）。
        ///
        /// [2026-09-11 掉帧修复] reseed 处在插入的关键路径上，**禁止同步 TextKit
        /// 全量精测**——含表格块一次 50-80ms 主线程，loop 中每个工具结果/思考块
        /// 插入都触发 → 整页掉到 30fps（真机 09-11 实录）。只走两条便宜路径：
        /// ① 统一缓存命中（内容定型后多半已有精确高度）→ 精确 precalc；
        /// ② miss → 便宜估算；真实值由 cell 自 sizing 修正（本来就要跑）+
        /// 流式结束的 scheduleHeightPrewarm 后台补齐统一缓存。
        private func reseedTextBlock(before index: Int,
                                     rows: [MessageListItem],
                                     messages: [RenderMessage],
                                     insertedSet: Set<MessageListItem>) {
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else { return }
            guard case .assistantBlock(let mid,_) = rows[index] else { return }
            var j = index-1
            while j >= 0 {
                if !Self.item(rows[j],belongsTo: mid) { return }
                if case .assistantBlock(let m2,let b2) = rows[j],m2 == mid,
                   !insertedSet.contains(rows[j]),
                   let msg = messages.first(where: { $0.id == mid }),
                   let blk = msg.blocks.first(where: { $0.id == b2 }),
                   blk.kind == .text,!blk.content.isEmpty {
                    let textWidth = max(cv.bounds.width-32,100)
                    let uKey = MarkdownRenderCache.key(
                        for: blk.content, fontSize: FontSettings.shared.scaledMessage(16.5))
                    if let uH = MarkdownRenderCache.shared.cachedHeight(for: uKey, width: Int(textWidth)) {
                        // [2026-09-11 修正] 仅在统一缓存有**真实精高**时才 purge+播种——
                        // 此前缓存 MISS 时无条件 purge 后落粗估：把 cell 自 sizing 正在
                        // 维护的实测高替换成偏矮估算，恰在指示器插入瞬间裁尾（真机
                        // IMG_4663 实锤）。MISS 时不动条目：流式中活 cell 的高度由
                        // 自 sizing 管线维护，比任何粗估都准。
                        layout.invalidateHeight(at: j, memo: .indexOnly)
                        layout.setPrecalcHeight(uH+4,provenance: "precalc.unifiedCache",at: j)
                        AppLogger.shared.info(
                            "[Reseed] HIT blk=\(b2.uuidString.prefix(8)) h=\(Int(uH)) idx=\(j)",
                            category: "ChatList.Heights")
                    } else {
                        AppLogger.shared.info(
                            "[Reseed] MISS-KEEP blk=\(b2.uuidString.prefix(8)) idx=\(j)（保留实测高）",
                            category: "ChatList.Heights")
                    }
                    return
                }
                j -= 1
            }
        }

        /// 整轮结束时的兜底：重测**最后一个文本块**（= 最终回复，后面没有指示器）。
        /// 便宜路径原则同上（禁止同步精测，见 reseedTextBlock 注释）。
        private func reseedTrailingTextBlock(rows: [MessageListItem],messages: [RenderMessage]) {
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else { return }
            var j = rows.count-1
            while j >= 0 {
                if case .assistantBlock(let mid,let bid) = rows[j],
                   let msg = messages.first(where: { $0.id == mid }),
                   let blk = msg.blocks.first(where: { $0.id == bid }),
                   blk.kind == .text,!blk.content.isEmpty {
                    let textWidth = max(cv.bounds.width-32,100)
                    let uKey = MarkdownRenderCache.key(
                        for: blk.content, fontSize: FontSettings.shared.scaledMessage(16.5))
                    if let uH = MarkdownRenderCache.shared.cachedHeight(for: uKey, width: Int(textWidth)) {
                        // [2026-09-11 修正] 同 reseedTextBlock：MISS 不 purge（保留实测高）。
                        layout.invalidateHeight(at: j, memo: .indexOnly)
                        layout.setPrecalcHeight(uH+4,provenance: "precalc.unifiedCache",at: j)
                        AppLogger.shared.info(
                            "[Reseed] TAIL-HIT blk=\(bid.uuidString.prefix(8)) h=\(Int(uH)) idx=\(j)",
                            category: "ChatList.Heights")
                    } else {
                        AppLogger.shared.info(
                            "[Reseed] TAIL-MISS-KEEP blk=\(bid.uuidString.prefix(8)) idx=\(j)（保留实测高）",
                            category: "ChatList.Heights")
                    }
                    // 终态这次不会走 layoutIfNeeded（身份集合未变时早退）→ 主动失效布局，
                    // 推到下一 runloop 与项目既有惯例一致（避免 view update 事务内改布局）。
                    DispatchQueue.main.async { [weak self] in
                        self?.viewController?.messageListLayout?.invalidateLayout()
                    }
                    return
                }
                j -= 1
            }
        }

        private func seedHeight(at i: Int,item: MessageListItem,
                                messages: [RenderMessage],width: CGFloat,
                                isReseed: Bool = false) {
            guard let layout = viewController?.messageListLayout,let vm else { return }
            let cvWidth = width
            // Register the stable
            // estimate is a coarse char-count heuristic (±13–52pt offY),
            let contentKey = Self.contentKey(for: item,messages: messages,messageIndex: messageIndex)
            layout.setContentKey(contentKey,at: i)
            // Content-aware spacing policy — must run
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
                // [2026-11-16] 状态行统一高度：所有形态同一高度，播种不再随状态漂移。
                // 错误条是唯一例外（多行内容，保持自适应）。
                footerEstimate = errored ? 48 : ChatFooterMetrics.height

            }

            // 守卫语义 = 旧三字典的「仅实测高度跳过」。合并字典后
            // cachedHeight 对 estimated/precalc 也返回值，若用它挡守卫，
            // 流式文本块的首帧估高会永久冻结（重播种被跳过），正文
            // 停在首帧高度与下方内容重叠（2026-09-05 回归）。
            guard !layout.hasMeasuredHeight(at: i) else { return }

            if let memo = layout.measuredHeight(forKey: contentKey,width: cvWidth) {
                layout.setPrecalcHeight(memo,provenance: "precalc.memo",at: i)
                return
            }

            switch item {
            case .assistantHeader:
                // [治本·每行唯一生产者 2026-09-17] 此处原为裸字面量 `28`（`est.literal28`），
                // 而**滚动路径的 `estimateItemHeight` 也写这一行**（现在推导出 25.5）——
                // 两个生产者写同一行 ⇒ 条目与帧各取一个。真机 M24 实证：
                //   `h(header) 帧28.0 / 条目25.5 / PLAF成型25.7`
                // ⇒ **帧停在 28**、条目已是 25.5，而**后写的那个不会刷新帧** ⇒ 屏上留 2.3pt 空白。
                // 收口：header 只由 `estimateItemHeight` 这一个生产者产出（其 25.5 由视图度量推导）。
                layout.setEstimatedHeight(
                    Self.estimateItemHeight(item,messages: messages,width: cvWidth),
                    provenance: "est.estimateItemHeight",at: i)

            case .assistantFooter:
                // Prominent banners (error/resume) measure
                // ~44-56pt; quiet status row / replying indicator
                // ~18pt; empty footer ~0-4pt.
                layout.setEstimatedHeight(footerEstimate,provenance: "est.footer",at: i)

            case .assistantBlock(let msgId,let blockId):
                // [2026-09-13 P3·失败必须显式] 原先这两处是**静默 `return`**：查不到消息、或消息里
                // 找不到该块时，这个 index 就**不写任何高度条目** ⇒ `prepare()` 的 `currentEntry`
                // 取不到值，只能退到「按内容键前缀选类型常量」（`b:` → 36/40）——该常量是**块间**
                // 通用的，对一段长正文远小于真实高度 ⇒ 帧偏矮、且随后要**增长**（手势期放行，
                // 不产生空白，但会造成一次实测跳变与滚动位置抖动）。而且静默降级会把
                // "这条消息高度为什么不对"变成无从下手。（`setContentKey` 在守卫**之前**已写入，
                // 故这里丢的是**条目**、不是键；原先注释写成"落 200pt 兜底"不准确，已更正。）
                // 现改为**显式兜底 + 告警**。
                // 兜底用 `estimateItemHeight`：它不读 `messageIndex`（自己查 `messages`），
                // 故仍可能给出该块类型的真实量级；彻底查不到时退 44pts 保守值。最坏也比"无条目 ⇒ 类型常量"好。
                guard let msgIdx = messageIndex[msgId],msgIdx<messages.count else {
                    let est = Self.estimateItemHeight(item,messages: messages,width: cvWidth)
                    layout.setEstimatedHeight(est,provenance: "est.estimateItemHeight",at: i)
                    AppLogger.shared.info("[Seed] messageIndex 无 \(msgId.uuidString.prefix(8)) → 兜底估高 \(Int(est))pt idx=\(i) reseed=\(isReseed ? 1 : 0)（原为静默留空 ⇒ 该格位无高度条目，prepare 退到块间通用常量）", category: "ChatList.Heights")
                    return
                }
                let msg = messages[msgIdx]
                guard let block = msg.blocks.first(where: { $0.id == blockId }) else {
                    let est = Self.estimateItemHeight(item,messages: messages,width: cvWidth)
                    layout.setEstimatedHeight(est,provenance: "est.estimateItemHeight",at: i)
                    AppLogger.shared.info("[Seed] 消息 \(msgId.uuidString.prefix(8)) 无块 \(blockId.uuidString.prefix(8)) → 兜底估高 \(Int(est))pt idx=\(i) reseed=\(isReseed ? 1 : 0)", category: "ChatList.Heights")
                    return
                }

                // [2026-11-20 重进会话上滑空白] 工具已折叠成思考行后的圆点，
                // 这些行在渲染上是空视图；但播种仍按块类型给了 36pt ⇒ 每颗球下面
                // 垫一条空白，松手重测归零才收起（真机日志 16:31:25 rows 3/4 h=36/estimated）。
                if ChatInlineToolBadges.isEnabled, block.toolStatus != nil {
                    layout.setEstimatedHeight(0, provenance: "est.inlineBadge", at: i)
                    return
                }

                switch block.kind {
                case .text:
                    // [2026-09-11 尾部行裁切修复] 陈旧渲染结果**不得**用于精确 precalc：
                    // 它按旧（短）内容算高 → 矮值播种 → 尾部行被裁，且会以「当前内容」
                    // 为 key 回写统一高度缓存形成跨会话污染（重进会话继续命中）。
                    // 判据与渲染侧 prebuilt 采用点同源（hasFreshRenderedContent）。
                    if let attrStr = block.cachedAttributedString, block.hasFreshRenderedContent {
                        let textWidth = max(cvWidth-32,100)
                        let height: CGFloat
                        // [T-perf 2026-09-08] ① 先查进程级统一缓存 heights（与
                        // MarkdownView 渲染分支/后台预填充同 key 体系：content+字号，
                        // 宽度=textWidth 整数化）——重进会话/预填充后全部命中，零排版。
                        let uKey = MarkdownRenderCache.key(
                            for: block.content, fontSize: FontSettings.shared.scaledMessage(16.5))
                        if let uH = MarkdownRenderCache.shared.cachedHeight(for: uKey, width: Int(textWidth)) {
                            height = uH  // 统一缓存高度（含 8pt inset）
                        } else {
                            // [2026-09-09] 种子循环改走 CTFramesetter 快路径：
                            // `measureAttributedStringHeight` 是 TextKit1 全量排版，
                            // 冷启动进入长会话时每个文本块都 miss 统一缓存 → 上百次
                            // 全量排版（实测 428 项 ≈ 5s，即「进入长会话 50+ 消息卡」
                            // 的主因）。CTFramesetter 同高度 ±1pt、快 70–700×，
                            // +8 补齐 textContainerInset 以对齐
                            // measureAttributedStringHeight 的语义（其返回值已含 8pt）。
                            // ⚠️ 前提 = **attachment-free**（同 estimateItemHeight 的
                            // CT 用法）：CTFramesetter 不调用 attachmentBounds，
                            // 代码块/表格等附件高度会失真 —— 含富语法块必须退回
                            // TextKit 精测（违反此前提曾致 cell 高度错误撑出大空白）。
                            // [2026-09-13 判据统一] 原为纯源文启发式（`hasRichSyntax`），会漏判
                            // parser 新增的附件类型（如行内 `$...$`）⇒ 含附件的块被送进 CT 快路径
                            // ⇒ 高度失真（矮）且矮值会回写统一缓存。改用唯一入口并带上产物判据
                            //（`attrStr` 就是紧接着要测的那份串，`hasAnyAttachment` 对它是权威的）。
                            if AssistantBlock.hasRichSyntaxOrAttachment(block.content,rendered: attrStr) {
                                height = Self.measureAttributedStringHeight(attrStr,width: textWidth)
                                // [2026-09-12 裁尾修复·含附件块不回写缓存] 本分支测的是
                                // `block.cachedAttributedString`，而**渲染路径对含附件的块会
                                // 重新渲染**（附件实例与 renderer 身份耦合，不能跨上下文共享）
                                // ⇒ 两者**输入不同**，实测差一行（真机实证：播种 1361 vs 渲染
                                // 1379，同一块同一宽度）。矮值一旦进统一缓存，屏上
                                // `sizeThatFits` 就命中它 → representable 高度被钉死 → 末行
                                // 永久被裁（`branch=measure src=unified-cache h=1361` 反复出现，
                                // 而屏上 TextKit 需要 1379）。故本分支**不回写**：权威值由渲染
                                // 路径按新渲染串实测后写回（`sizeThatFits` 的 mtv/尾部路径），
                                // 口径与渲染同源。下方非附件分支的输入与渲染一致，仍照常回写。
                            } else if let authored = block.kind.authoredHeight {
                                // [治本 2026-09-17] **声明了固定高度的类型，禁止走文本测量**。
                                // 真机证据：`precalc.ct 种子2764 → 真值20.3` —— CT 量的是块里的
                                // **文字**，而该类型渲染的是固定 36pt 的胶囊 ⇒ 帧被写成 2764pt，
                                // 屏上就是那片空白。类型自己声明高度后，这条链对它**整条不适用**。
                                height = authored - SelfSizingCell.assistantBlockVerticalChrome
                            } else {
                                height = MarkdownView.ctFramesetterHeight(for: attrStr,width: textWidth) + 8
                                // 回写统一缓存（下次进入/预填充命中，不再重复计算）。
                                // 非附件块：本路径输入（cachedAttributedString）与渲染路径
                                // 完全相同（`pending = pre`），故回写安全、口径同源。
                                MarkdownRenderCache.shared.store(
                                    height: height, key: uKey, width: Int(textWidth), grade: .ct)  // S3.1：ctFramesetterHeight + 8
                            }
                        }
                        layout.setPrecalcHeight(height+SelfSizingCell.assistantBlockVerticalChrome,provenance: "precalc.ct",at: i)
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
                        layout.setEstimatedHeight(0,provenance: "est.literal0",at: i)
                    } else {
                        let est = Self.estimateItemHeight(item,messages: messages,width: cvWidth)
                        layout.setEstimatedHeight(est,provenance: "est.estimateItemHeight",at: i)
                    }
                case .thinking:
                    let est = Self.estimateItemHeight(item,messages: messages,width: cvWidth)
                    layout.setEstimatedHeight(est,provenance: "est.estimateItemHeight",at: i)
                // [Stage 1 · R7] 工具类兜底表已收口到 `AssistantBlockKind.seedFallbackHeight`
                //（唯一定义见 RenderModels.swift）—— 与 `estimateItemHeight` 共用同一张表，
                // 此前两处各自维护同一组常量。等价性：四个返回值与原值逐字相同
                //（.readImageTool→36 / .file→40 / .info→20+行数*16 / default→36）。
                // 不改用 `estimateItemHeight` 是刻意的：那会为每个 item 增加一次
                // `messages.first(where:)` + `blocks.first(where:)` 的 **O(n) 查找**，
                // 而这里 `block` 就在手上 —— 收口不应引入新的扫描成本。
                default:
                    layout.setEstimatedHeight(block.kind.seedFallbackHeight(content: block.content),provenance: block.kind.authoredHeight != nil
                                        ? "authored#\(String(describing: block.kind).prefix(14))"
                                        : "est.seedFallbackHeight#\(String(describing: block.kind).prefix(14))",at: i)
                }

            case .wholeMessage(let msgId):
                if let msg = messages.first(where: { $0.id == msgId }),
                   msg.role == .user {
                    let effWidth = maxContentWidth>0 ? min(cvWidth,maxContentWidth) : cvWidth
                    // `allowRender: false`：种子循环覆盖全部 item，不能每条都跑
                    // cmark 渲染（50+ 消息 = 上百次串行解析 → 进入会话卡顿）。
                    // 未命中统一缓存时用便宜估算，精度由 cell 首次自 sizing 修正。
                    let h = Self.measureUserBubbleHeight(for: msg,cvWidth: effWidth,
                                                         allowRender: false)
                    if let h {
                        layout.setPrecalcHeight(h,provenance: "precalc.userBubble",at: i)
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
                            Self.estimateItemHeight(item,messages: messages,width: cvWidth),provenance: "est.estimateItemHeight",at: i)
                    }
                } else {
                    let est = Self.estimateItemHeight(item,messages: messages,width: cvWidth)
                    layout.setEstimatedHeight(est,provenance: "est.estimateItemHeight",at: i)
                }
            }
        }

        /// [P0-5] 字体度量变更：清高度缓存**并重播种**。
        ///
        /// `clearHeightCache()` 会连 `contentKeyByItem` 一起清；若不重播种，`prepare()` 对每个
        /// 无条目/无键的行落到 `estimatedItemHeight`（200pt）⇒ 内容总高虚高数倍、同一 offset
        /// 指向别处（跳位），随滚动逐行收缩。宽度变更路径有 `onIndexHeightsPurged` 补播种，
        /// 字体路径此前没有。
        func reconfigureAllCells() {
            guard let layout = viewController?.messageListLayout else { return }
            layout.clearHeightCache()
            seedHeights(.all, rows: prevSnapshotIds, messages: snapshotMessages,
                        width: viewController?.collectionView.bounds.width ?? 390)
            reconfigureVisibleCells()
            layout.invalidateLayout()
        }

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

/// 后台高度测量跨 Task 边界传递的非 Sendable 负载（NSAttributedString / 索引表）。
/// 由后台任务独占构造并只读传递，不跨线程共享可变状态——标注 `@unchecked Sendable`
/// 仅为通过 Swift 6 发送检查，运行时语义与迁入前一致。
private struct MeasuredEntryBox: @unchecked Sendable {
    let entries: [(key: String, attr: NSAttributedString, rich: Bool)]
}
private struct MeasuredResultBox: @unchecked Sendable {
    let results: [(key: String, attr: NSAttributedString, heights: [Int: CGFloat], rich: Bool)]
}
