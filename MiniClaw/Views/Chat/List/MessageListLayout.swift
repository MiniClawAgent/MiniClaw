import UIKit
import os

///
///
public final class MessageListLayout: UICollectionViewLayout {
    public var estimatedItemHeight: CGFloat = 200

    /// 统一高度条目（2026-09-05 结构收口）：原 estimatedHeights/precalcHeights/heightCache
    /// 三套并行「index→高度」字典合并为单一「index → 条目」，条目携带来源优先级
    /// （measured > precalc > estimated），写入时低优先级不覆盖高优先级。
    enum HeightSource: String { case measured, precalc, estimated }
    struct HeightEntry { var height: CGFloat; var source: HeightSource }
    private var heightEntries: [Int: HeightEntry] = [:]

    public func setEstimatedHeight(_ height: CGFloat,at index: Int) {
        setEntry(height, source: .estimated, at: index)
    }

    public func setPrecalcHeight(_ height: CGFloat,at index: Int) {
        setEntry(height, source: .precalc, at: index)
    }

    public var deferSelfSizing: Bool = false

    public var suppressContentOffsetAdjustment: Bool = false

    /// Historically a single `Int?` for the
    ///
    /// THREAD SAFETY: this array is
    private var _streamingCellRanges: [Range<Int>] = []
    private var _streamingLock = os_unfair_lock_s()

    public var streamingCellRanges: [Range<Int>] {
        get {
            os_unfair_lock_lock(&_streamingLock)
            defer { os_unfair_lock_unlock(&_streamingLock) }
            return _streamingCellRanges
        }
        set {
            os_unfair_lock_lock(&_streamingLock)
            _streamingCellRanges = newValue
            os_unfair_lock_unlock(&_streamingLock)
        }
    }

    public var streamingCellIndex: Int? {
        os_unfair_lock_lock(&_streamingLock)
        defer { os_unfair_lock_unlock(&_streamingLock) }
        return _streamingCellRanges.last?.lowerBound
    }

    ///
    public var isAutoScrollPinning: Bool = false

    public var itemSpacing: CGFloat = 0

    /// 写入条目：measured > precalc > estimated，低优先级不覆盖高优先级。
    private func setEntry(_ height: CGFloat, source: HeightSource, at index: Int) {
        let rank: (HeightSource) -> Int = { $0 == .measured ? 3 : $0 == .precalc ? 2 : 1 }
        if let existing = heightEntries[index], rank(existing.source) > rank(source) { return }
        // [2026-09-09 NaN 治理·单一入口闸门] 高度必须是**有限非负值**。
        // 布局循环这里做 `attrs.frame = …; y += h` 累加，一个 inf 条目就会让
        // 后续全部 y 与 collectionViewContentSize 变成 inf；下游
        // `contentSize.height - bounds.height` 得到 inf-inf = NaN，CoreGraphics
        // 便打出成片的 "invalid numeric value (NaN) passed to CoreGraphics"。
        // measured / precalc / estimated 三个写入口全部经此函数，在此一次性
        // 拦截成本最低且不会再漏入口。
        guard height.isFinite, height >= 0 else { return }
        heightEntries[index] = HeightEntry(height: height, source: source)
    }

    /// single source of truth. This breaks the oscillation loop where
    private var geometryReaderConfirmed: Set<Int> = []

    /// Real measured heights keyed by a
    /// 进程级 content-keyed 实测高度 memo（2026-09-06 上滑抖动修复方案 C）。
    /// ChatView 每次进出会话都重建 VC/Coordinator/Layout 实例，实例级 memo
    /// 在「首页重进会话」场景必然死亡——而 contentKey（消息/块持久化 UUID +
    /// 内容长度，text 块用确定性 ID）本就为跨会话稳定设计。提升为进程级后，
    /// 重进会话的种子循环直接命中上次实测高度，全列表零修正、零抖动。
    /// 失效路径：字体变更走 clearHeightCache(keepingSharedMemo: false) 全量清；
    /// 宽度变化由 measuredHeight(forKey:width:) 的 ±1pt 门槛自然过滤；
    /// 流式 cell 靠 configureCell 的 contentKey 置空 + invalidateHeight 显式
    /// 逐键剔除，不会写入中途高度。footer（"f:" 前缀）仍永不写入。
    /// 锁：PLAF 可能跑在二级 layout 线程，且会话切换瞬间新旧两个实例并存，
    /// 静态字典必须互斥（沿用 streamingCellRanges 的 os_unfair_lock 模式）。
    private static var _sharedMeasuredHeights: [String: (height: CGFloat,width: CGFloat)] = [:]
    private static var _memoLock = os_unfair_lock_s()

    private var contentKeyByIndex: [Int: String] = [:]

    private var itemAttributes: [UICollectionViewLayoutAttributes] = []

    private var totalHeight: CGFloat = 0

    private var lastItemCount: Int = 0

    public override var collectionViewContentSize: CGSize {
        let width = collectionView?.bounds.width ?? 0
        return CGSize(width: width,height: totalHeight)
    }

    public override func prepare() {
        let t0 = CACurrentMediaTime()
        super.prepare()
        guard let cv = collectionView else { return }

        let sectionCount = cv.numberOfSections
        let itemCount = sectionCount>0 ? cv.numberOfItems(inSection: 0) : 0
        let width = cv.bounds.width
        guard width>0 else {
            AppLogger(category: "ChatList.Scroll").info("[Scroll][prepare] SKIP width=0 bounds=\(cv.bounds) itemCount=\(itemCount)")
            return
        }

        itemAttributes.removeAll(keepingCapacity: true)
        itemAttributes.reserveCapacity(itemCount)

        var y: CGFloat = 0
        for i in 0..<itemCount {
            let ip = IndexPath(item: i,section: 0)
            let attrs = UICollectionViewLayoutAttributes(forCellWith: ip)
            let h: CGFloat
            h = heightEntries[i]?.height ?? estimatedItemHeight
            attrs.frame = CGRect(x: 0,y: y,width: width,height: h)
            itemAttributes.append(attrs)
            y += h
            // Suppress the inter-cell spacing when the NEXT
            let isLast = (i+1 == itemCount)
            let nextIsFooter = !isLast
                && (contentKeyByIndex[i+1]?.hasPrefix("f:") ?? false)
                && (footerHugByIndex[i+1] ?? true)
                && !isStreamingCell(i+1)
            //
            if !isLast,!nextIsFooter,h>0 { y += itemSpacing }
        }
        totalHeight = y
        lastItemCount = itemCount
        // [Stall] prepare() runs on every invalidateLayout; on long
        let elapsed = (CACurrentMediaTime()-t0)*1000
        Self.prepareCallCount &+= 1
        #if DEBUG
        // Record every full re-flow.
        ScrollMetricsRecorder.shared.record(
            kind: "prepare", a: Double(itemCount), b: totalHeight,
            offset: Double(collectionView?.contentOffset.y ?? 0),
            note: String(format: "%.1fms", elapsed))
        #endif
        if elapsed >= 5 {
            AppLogger(category: "ChatList.Stall").debug("[prepare] #\(Self.prepareCallCount) \(String(format: "%.1f", elapsed))ms items=\(itemCount) totalH=\(String(format: "%.0f", totalHeight)) cacheHits=\(self.heightEntries.count)")
        }
    }
    private static var prepareCallCount: Int = 0

    public override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let t0 = CACurrentMediaTime()
        guard !itemAttributes.isEmpty else { return nil }

        let prefetchMargin = rect.height*0.5
        let expandedRect = CGRect(
            x: rect.minX,
            y: rect.minY-prefetchMargin,
            width: rect.width,
            height: rect.height+prefetchMargin*2
        )

        var result: [UICollectionViewLayoutAttributes] = []
        for attrs in itemAttributes {
            if attrs.frame.maxY<expandedRect.minY { continue }
            if attrs.frame.minY>expandedRect.maxY { break }
            result.append(attrs)
        }

        return result
    }

    public override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item<itemAttributes.count else { return nil }
        return itemAttributes[indexPath.item]
    }

    /// was scrolling. Stored here (not in heightCache) so prepare() keeps
    /// using the old height → contentSize stays frozen. Applied on thaw
    private var deferredHeights: [Int: CGFloat] = [:]

    public var deferredHeightCount: Int { deferredHeights.count }

    /// Move deferred heights into the real cache. Call after scrolling ends.
    public func applyDeferredHeights() {
        guard !deferredHeights.isEmpty else { return }
        let vpTop = collectionView?.contentOffset.y ?? 0
        let vpBottom = vpTop+(collectionView?.bounds.height ?? 0)
        var aboveSum: CGFloat = 0,insideSum: CGFloat = 0,dropped = 0
        var detail: [String] = []
        for (idx,h) in deferredHeights {
            let old = heightEntries[idx]?.height ?? estimatedItemHeight
            if heightEntries[idx] == nil {
                heightEntries[idx] = HeightEntry(height: h, source: .measured)
                let delta = h-old
                let frame = idx<itemAttributes.count ? itemAttributes[idx].frame : .zero
                let pos: String
                if frame.maxY <= vpTop { pos = "above"; aboveSum += delta }
                else if frame.minY<vpBottom { pos = "inside"; insideSum += delta }
                else { pos = "below" }
                if abs(delta)>0.5 {
                    detail.append("idx\(idx) \(pos) \(String(format: "%+.1f", delta)) (\(String(format: "%.0f", old))→\(String(format: "%.0f", h)))")
                }
                #if DEBUG
                //
                ScrollMetricsRecorder.shared.record(
                    kind: "flush", idx: idx, a: old, b: h,
                    key: String(contentKeyByIndex[idx]?.prefix(2) ?? ""),
                    pos: pos,offset: vpTop,
                    tag: metricsTagByIndex[idx] ?? "")
                #endif
            } else {
                dropped += 1
            }
        }
        if !detail.isEmpty || dropped>0 {
            AppLogger(category: "ChatList.Settle").info("[SettleJitter][flush] n=\(deferredHeights.count) dropped=\(dropped) aboveΣ=\(String(format: "%+.1f", aboveSum)) insideΣ=\(String(format: "%+.1f", insideSum)) :: \(detail.prefix(12).joined(separator: "|"))")
        }
        deferredHeights.removeAll()
    }

    public override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        let index = preferredAttributes.indexPath.item
        let prefH = preferredAttributes.size.height
        let origH = originalAttributes.size.height

        if deferSelfSizing {
            let hasCached = heightEntries[index]?.source == .measured
            if hasCached {
                if prefH <= origH+0.5 {
                    if abs(prefH-origH)>0.5 {
                        deferredHeights[index] = prefH
                    }
                    return false
                }
            } else {
            }
        }

        // ignore UIKit self-sizing. GR is the source of truth — UIKit's
        if geometryReaderConfirmed.contains(index) {
            return false
        }

        let delta = abs(prefH-origH)

        let mustInvalidate: Bool
        if heightEntries[index]?.source == .measured {
            mustInvalidate = delta>2
        } else {
            mustInvalidate = delta>0.5
        }
        if mustInvalidate && delta>100 {
            // [2026-09-09] key 从 2 字符前缀扩为完整 contentKey（含 messageId/blockId/
            // contentCount）——高度裁切类「丢字」复盘时直接指认块，不再需要反查。
            AppLogger(category: "ChatList.CellMetrics").info("[CellSizing] INVALIDATE idx=\(index) delta=\(String(format: "%.0f", delta)) est=\(String(format: "%.0f", origH)) → pref=\(String(format: "%.0f", prefH)) cached=\(heightEntries[index]?.source == .measured) key=\(contentKeyByIndex[index] ?? "??")")
        }
        return mustInvalidate
    }

    public override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let ctx = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        )

        let index = preferredAttributes.indexPath.item
        let oldH = originalAttributes.size.height
        let newH = preferredAttributes.size.height
        let delta = newH-oldH

        let estimateSrc = heightEntries[index].map { $0.source.rawValue + "!" } ?? "def"

        // [NegMeasure 2026-09-10] 与 SelfSizingCell 的负测量闸门配对：PLAF 返回的
        // preferred 高度必须有限且非负才允许写 .measured。9-09 的 NaN 闸门只盖住了
        // setEntry 三个写入口，这里是**第四写入口**（直接字典赋值），曾放进过 -40
        // （SwiftUI hosting 损坏测量）→ 负高度回流布局 → ViewGraph 二次损坏崩溃。
        if newH.isFinite,newH >= 0 {
            heightEntries[index] = HeightEntry(height: newH,source: .measured)
        } else {
            AppLogger(category: "ChatList.CellMetrics").warning(
                "[CellSizing] REJECT neg/inf preferred height=\(String(format: "%.0f", newH)) idx=\(index)（保留原条目，负高度防御）")
        }

        if let cv = collectionView {
            let cellTopY = originalAttributes.frame.minY
            let vpTop = cv.contentOffset.y
            let pos = originalAttributes.frame.maxY <= vpTop ? "above"
                : (cellTopY<vpTop+cv.bounds.height ? "inside" : "below")
            #if DEBUG
            let phase = cv.isDecelerating ? "decel" : (cv.isTracking ? "drag" : "idle")
            // Record EVERY correction (no threshold)
            ScrollMetricsRecorder.shared.record(
                kind: "inv", idx: index, a: oldH, b: newH,
                key: contentKeyByIndex[index] ?? "",
                src: estimateSrc,pos: pos,offset: vpTop,note: phase,
                tag: metricsTagByIndex[index] ?? "")
            #endif
            if cv.isDecelerating,abs(delta)>2 {
                // [2026-09-09] key 扩为完整 contentKey（原 prefix(2) 只能打出 "b:"）。
                AppLogger(category: "ChatList.Settle").info("[SettleJitter][decel-inv] idx=\(index) \(pos) Δ\(String(format: "%+.1f", delta)) (\(String(format: "%.0f", oldH))→\(String(format: "%.0f", newH))) key=\(contentKeyByIndex[index] ?? "??") src=\(estimateSrc) offset=\(String(format: "%.0f", vpTop))")
            }
        }

        // memo here could capture a mid-stream height. See.

        if let cv = collectionView,!cv.isTracking,!cv.isDecelerating,!suppressContentOffsetAdjustment {
            let cellTopY = originalAttributes.frame.minY
            let cellBottom = originalAttributes.frame.maxY
            let vpTop = cv.contentOffset.y
            let vpBottom = vpTop+cv.bounds.height
            if cellTopY<vpTop && cellBottom <= vpTop {
                ctx.contentOffsetAdjustment = CGPoint(x: 0,y: delta)
            } else if cellTopY >= vpTop && cellTopY<vpBottom && !isStreamingCell(index) {
                ctx.contentOffsetAdjustment = CGPoint(x: 0,y: delta)
            } else if isStreamingCell(index) && isAutoScrollPinning && delta>0 {
                // Actively streaming cell
                ctx.contentOffsetAdjustment = CGPoint(x: 0,y: delta)
            }
        }

        // First-entry footer-float fix.
        //
        // • only while suppressing (first snapshot settle), not steady state
        // • only on a REAL height change (|delta| > 0.5) — both growth (footer
        // hangs inside the grown block) and shrink (a stale-tall seed, e.g.
        // a footer that once measured with transient content, leaves a
        // phantom gap; frames below must be pulled up) need the re-flow
        // • NOT for streaming cells (their position is owned by the pin logic)
        // • coalesced: at most one invalidate scheduled per runloop tick, and
        // re-armed only after it fires — so a burst of corrections collapses
        // into a single prepare(), not one per cell.
        if suppressContentOffsetAdjustment,abs(delta)>0.5,!isStreamingCell(index),
           !pendingFooterReflow {
            pendingFooterReflow = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingFooterReflow = false
                self.invalidateLayout()
            }
        }

        return ctx
    }

    /// Coalescing flag so a burst of first-
    private var pendingFooterReflow = false

    /// True while any streaming cell
    public var hasActiveStreaming: Bool { !streamingCellRanges.isEmpty }

    // short-circuit.
    public func isStreamingCell(_ index: Int) -> Bool {
        // Take ONE locked snapshot of
        let ranges = streamingCellRanges
        if let last = ranges.last,index >= last.lowerBound { return true }
        //
        return ranges.contains { $0.contains(index) }
    }

    private var lastSettledWidth: CGFloat = 0

    private var widthPurgeToken: UInt = 0

    private static let widthSettleDelay: TimeInterval = 0.033

    public override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let cv = collectionView else { return false }
        if UIApplication.shared.applicationState != .active { return false }

        if newBounds.width != cv.bounds.width && newBounds.width>0 {
            // (issue #31) DO NOT clear
            //
            // origH correctness constraint that motivated clearing the
            scheduleWidthPurge(for: newBounds.width)
            return true
        }
        return false
    }

    private func scheduleWidthPurge(for targetWidth: CGFloat) {
        if abs(targetWidth-lastSettledWidth)<0.5 { return }
        widthPurgeToken &+= 1
        let token = widthPurgeToken
        DispatchQueue.main.asyncAfter(deadline: .now()+Self.widthSettleDelay) { [weak self] in
            guard let self else { return }
            guard token == self.widthPurgeToken else { return }
            guard let cv = self.collectionView,cv.bounds.width>0 else { return }
            guard abs(cv.bounds.width-targetWidth)<0.5 else { return }
            guard abs(cv.bounds.width-self.lastSettledWidth) >= 0.5 else { return }

            self.heightEntries.removeAll()
            self.geometryReaderConfirmed.removeAll()
            self.lastSettledWidth = cv.bounds.width
            self.invalidateLayout()
        }
    }

    public func updateCacheForSnapshot(oldIds: [MessageListItem],newIds: [MessageListItem]) {
        var oldIndexByItem: [MessageListItem: Int] = [:]
        for (i,item) in oldIds.enumerated() {
            oldIndexByItem[item] = i
        }

        var newEntries: [Int: HeightEntry] = [:]
        var newConfirmed: Set<Int> = []
        for (newIndex,item) in newIds.enumerated() {
            if let oldIndex = oldIndexByItem[item] {
                if let entry = heightEntries[oldIndex] { newEntries[newIndex] = entry }
                if geometryReaderConfirmed.contains(oldIndex) { newConfirmed.insert(newIndex) }
            }
        }
        heightEntries = newEntries
        geometryReaderConfirmed = newConfirmed
    }

    public func invalidateHeight(at index: Int) {
        // 统一条目：一次移除即完成原三字典的清空（measured/precalc/estimated 同源）。
        heightEntries.removeValue(forKey: index)
        geometryReaderConfirmed.remove(index)
        // Belt-and-suspenders: also drop the
        if let key = contentKeyByIndex[index] {
            invalidateMemo(forKey: key)
        }
    }

    /// 只清索引条目、保留 content-keyed memo（2026-09-06 上滑抖动修复）。
    /// 用于 applySnapshot 里清理「旧 cell 在 apply 期间写脏的索引高度」：
    /// 那个高度属于旧内容，但 memo 中该 contentKey 的实测高度依然有效
    /// （紧接着的重播种要读它）。用 invalidateHeight 会把 memo 一起剔除，
    /// 导致重进会话的种子退化为粗估 → 上滑抖动。
    public func purgeIndexEntry(at index: Int) {
        heightEntries.removeValue(forKey: index)
        geometryReaderConfirmed.remove(index)
    }

    /// [2026-09-09 快照缓存重映射] 快照行变化时按 item
    /// 身份整体重映射全部索引键缓存。索引键条目在插入/删除后**整体错位**
    /// 是高度串块的根源（真机实证：展开态思考块 idx=29 高度 340→40 裁切）；
    /// 旧方案只清洗 inserted 条目，错位的既有条目原样残留。按 item 身份
    /// 重映射后，未匹配（新增）item 的条目自然清空，由随后的 seedHeight 重新播种。
    public func remapHeights(oldIds: [MessageListItem],newIds: [MessageListItem]) {
        var oldIndexByItem: [MessageListItem: Int] = [:]
        for (i,item) in oldIds.enumerated() { oldIndexByItem[item] = i }
        var newEntries: [Int: HeightEntry] = [:]
        var newConfirmed: Set<Int> = []
        var newKeys: [Int: String] = [:]
        var newHug: [Int: Bool] = [:]
        var newTags: [Int: String] = [:]
        for (newIndex,item) in newIds.enumerated() {
            guard let oldIndex = oldIndexByItem[item] else { continue }
            if let e = heightEntries[oldIndex] { newEntries[newIndex] = e }
            if geometryReaderConfirmed.contains(oldIndex) { newConfirmed.insert(newIndex) }
            if let k = contentKeyByIndex[oldIndex] { newKeys[newIndex] = k }
            if let h = footerHugByIndex[oldIndex] { newHug[newIndex] = h }
            #if DEBUG
            if let t = metricsTagByIndex[oldIndex] { newTags[newIndex] = t }
            #endif
        }
        heightEntries = newEntries
        geometryReaderConfirmed = newConfirmed
        contentKeyByIndex = newKeys
        footerHugByIndex = newHug
        #if DEBUG
        metricsTagByIndex = newTags
        #endif
    }

    public func setCachedHeight(_ height: CGFloat,at index: Int) {
        heightEntries[index] = HeightEntry(height: height, source: .measured)
        geometryReaderConfirmed.insert(index)
    }

    public func cachedHeight(at index: Int) -> CGFloat? {
        heightEntries[index]?.height
    }

    public func precalcHeight(at index: Int) -> CGFloat? {
        heightEntries[index]?.height
    }

    public func hasPrecalcHeight(at index: Int) -> Bool {
        heightEntries[index]?.source == .precalc
    }

    /// 该索引是否已有「实测」高度（source == .measured）。
    /// 合并字典后 cachedHeight/precalcHeight 对任意来源条目都返回值，
    /// 旧三字典时代「仅实测高度才挡住估算/预演」的语义分界由本访问器承接：
    /// 种子循环、configureCell 与 prefetch 兜底必须用它做守卫——否则流式
    /// chunk 的逐次重播种（估高随内容增长刷新）会被首帧估算永久冻结，
    /// 流式 cell 停在首帧高度，正文与下方工具卡/思考块重叠（2026-09-05 回归）。
    public func hasMeasuredHeight(at index: Int) -> Bool {
        heightEntries[index]?.source == .measured
    }

    // MARK: - Content-keyed real-height memo

    public func setContentKey(_ key: String,at index: Int) {
        contentKeyByIndex[index] = key
    }

    /// Per-footer spacing policy, decided by the Coordinator
    private var footerHugByIndex: [Int: Bool] = [:]
    public func setFooterHug(_ hug: Bool,at index: Int) {
        footerHugByIndex[index] = hug
    }

    #if DEBUG
    /// index → stable content-hash tag, so layout-
    private var metricsTagByIndex: [Int: String] = [:]
    public func setMetricsTag(_ tag: String,at index: Int) {
        metricsTagByIndex[index] = tag
    }
    #endif

    /// 进程级存储（方案 C）——跨 Layout 实例、跨会话存活。
    /// [缓存观测 2026-09-10] 唐唐要求 memo 读写全量可见于日志：STORE/MISS 全打
    /// （每 key 每次播种/配置各一次，量可控），HIT 同 key 1s 节流。
    private static let memoLogger = AppLogger(category: "RenderCache")
    private nonisolated(unsafe) static var memoHitLogAt: [String: CFAbsoluteTime] = [:]

    public func measuredHeight(forKey key: String,width: CGFloat) -> CGFloat? {
        os_unfair_lock_lock(&Self._memoLock)
        let entry = Self._sharedMeasuredHeights[key]
        os_unfair_lock_unlock(&Self._memoLock)
        guard let entry,abs(entry.width-width)<1 else {
            Self.memoLogger.info("[MEMO] MISS key=\(key) w=\(String(format: "%.0f", width))")
            return nil
        }
        let now = CFAbsoluteTimeGetCurrent()
        if Self.memoHitLogAt[key].map({ now-$0 >= 1.0 }) ?? true {
            Self.memoHitLogAt[key] = now
            Self.memoLogger.info("[MEMO] HIT key=\(key) h=\(String(format: "%.0f", entry.height))")
        }
        return entry.height
    }

    /// Record a real height a cell just
    public func recordMeasuredHeight(forKey key: String,height: CGFloat,boundsWidth: CGFloat) {
        guard height >= 4,boundsWidth>1 else { return }
        // NEVER memoize footer heights. The footer's
        guard !key.hasPrefix("f:") else { return }
        os_unfair_lock_lock(&Self._memoLock)
        Self._sharedMeasuredHeights[key] = (height: height,width: boundsWidth)
        os_unfair_lock_unlock(&Self._memoLock)
        Self.memoLogger.info("[MEMO] STORE key=\(key) h=\(String(format: "%.0f", height)) w=\(String(format: "%.0f", boundsWidth))")
    }

    public func invalidateMemo(forKey key: String) {
        os_unfair_lock_lock(&Self._memoLock)
        Self._sharedMeasuredHeights.removeValue(forKey: key)
        os_unfair_lock_unlock(&Self._memoLock)
    }

    /// Wipe the process-level memo (font-size change — memo heights are
    /// font-dependent and their content keys carry no font fingerprint).
    public static func clearSharedMemo() {
        os_unfair_lock_lock(&_memoLock)
        _sharedMeasuredHeights.removeAll()
        os_unfair_lock_unlock(&_memoLock)
        memoHitLogAt.removeAll()
    }

    /// Clear per-instance cached heights (session change / reconfigure).
    /// - Parameter keepingSharedMemo: 会话切换传 true —— 进程级 memo 的
    /// contentKey 跨会话稳定（消息/块持久化 UUID），保留后重进会话种子
    /// 直接命中实测高度，上滑零修正零抖动（2026-09-06 方案 C）。字体
    /// 变更路径（reconfigureAllCells）保持默认 false，全量清 memo。
    public func clearHeightCache(keepingSharedMemo: Bool = false) {
        heightEntries.removeAll()
        geometryReaderConfirmed.removeAll()
        if !keepingSharedMemo { Self.clearSharedMemo() }
        contentKeyByIndex.removeAll()
        footerHugByIndex.removeAll()
        // [2026-09-08] user bubble 测量 memo 同为进程级静态字典，此前**从不清理**
        // → 随会话切换单调增长（长会话残留常驻）。统一在清高度缓存时释放。
        MessageCollectionView.Coordinator.clearUserBubbleMemo()
    }

    public var debugCachedHeightCount: Int { heightEntries.count }
}

// MARK: - In-memory scroll diagnostics ring buffer

#if DEBUG
/// scroll — per-frame contentOffset/contentSize sample (a=offset, b=csHeight)
/// measure — every SelfSizingCell self-size (a=est, b=fit)
/// inv — every invalidationContext height correction (a=old, b=new)
/// flush — each deferred height applied at settle (a=old, b=new)
/// settle — settle anchor shift (a=screenDelta)
/// prepare — full layout re-flow (a=itemCount, b=totalHeight)
final class ScrollMetricsRecorder {
    static let shared = ScrollMetricsRecorder()

    private(set) var isEnabled = false

    func setEnabled(_ on: Bool) {
        lock.lock()
        isEnabled = on
        if !on { head = 0; count = 0 }
        lock.unlock()
    }

    struct Event {
        let t: Double // CACurrentMediaTime
        let kind: String
        let idx: Int
        let a: Double
        let b: Double
        let key: String // content key prefix ("b:", "w:", "f:", "h:") or ""
        let src: String // estimate source (pre/est/cache/def) or phase tag
        let pos: String // above/inside/below viewport, or scroll phase
        let offset: Double // contentOffset.y at event time
        let note: String
        let tag: String // stable content-hash cell identity — survives
    }

    private var buf: [Event?]
    private var head = 0 // next write slot
    private var count = 0
    private let capacity = 20000
    private let lock = NSLock()

    private init() {
        buf = Array(repeating: nil,count: capacity)
    }

    func record(kind: String,idx: Int = -1,a: Double = 0,b: Double = 0,
                key: String = "", src: String = "", pos: String = "",
                offset: Double = 0, note: String = "", tag: String = "") {
        guard isEnabled else { return }
        let e = Event(t: CACurrentMediaTime(),kind: kind,idx: idx,a: a,b: b,
                      key: key,src: src,pos: pos,offset: offset,note: note,tag: tag)
        lock.lock()
        buf[head] = e
        head = (head+1)%capacity
        if count<capacity { count += 1 }
        lock.unlock()
    }

    func snapshot(clear: Bool) -> [[String: Any]] {
        lock.lock()
        var events: [Event] = []
        events.reserveCapacity(count)
        let start = (head-count+capacity)%capacity
        for i in 0..<count {
            if let e = buf[(start+i)%capacity] { events.append(e) }
        }
        if clear {
            buf = Array(repeating: nil,count: capacity)
            head = 0
            count = 0
        }
        lock.unlock()
        return events.map { e in
            [
                "t": (e.t*1000).rounded()/1000,
                "kind": e.kind, "idx": e.idx,
                "a": (e.a*10).rounded()/10, "b": (e.b*10).rounded()/10,
                "key": e.key, "src": e.src, "pos": e.pos,
                "offset": (e.offset*10).rounded()/10, "note": e.note,
                "tag": e.tag,
            ]
        }
    }
}
#endif
