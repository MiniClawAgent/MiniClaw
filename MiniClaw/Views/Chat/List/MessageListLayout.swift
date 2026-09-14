import UIKit
import os

///
///
public final class MessageListLayout: UICollectionViewLayout {
    public var estimatedItemHeight: CGFloat = 200

    // [2026-09-13 重构·删除死机制] 此处原有 `private var lastHeightByKey: [String: CGFloat]`
    //（注释自称「按内容键记住上次真实高度」，作为条目丢失的兜底）。
    // 全库核查结论：**它是死机制** —— 声明、读取（原 `prepare()` 的
    // `else if let k = key, let remembered = lastHeightByKey[k]`）、清空三处俱全，
    // **却没有任何写入点** ⇒ 那条分支**恒不执行**，注释承诺的兜底从未生效。
    // 该兜底能力另有承担者且**本来就按内容键**工作：`peekMeasuredHeight(forKey:width:)`
    //（进程级 `_sharedMeasuredHeights`，由 PLAF 的 `recordMeasuredHeight` 写入）
    // ⇒ 删除本字典不丢任何能力。删除后 `prepare()` 的取高链收敛为清晰三级：
    //   **① 当前有效条目（内容版本匹配） → ② 进程级按键 memo → ③ 类型化常量**

    /// [2026-09-12] settle 期「视口上方高度变化」的累积量。
    ///
    /// `settleAfterInteraction` 会先 `suppressContentOffsetAdjustment = true` 再强制重排，
    /// 此时**布局自带的 offset 补偿被关掉**，于是这批修正在没有任何锚定的情况下生效
    /// （真机实测 aboveΣ = −183.7pt）⇒ 停手瞬间整屏平移。这里累积、由 settle 侧一次性锚回。
    private(set) var pendingAboveShift: CGFloat = 0

    /// 取走并清零（settle 侧消费）。
    public func takePendingAboveShift() -> CGFloat {
        let v = pendingAboveShift
        pendingAboveShift = 0
        return v
    }

    /// [2026-09-13 隐患①修复] 清零累积量 —— **在拖拽开始时调用**（`scrollViewWillBeginDragging`）。
    ///
    /// 为什么必须清：该累积的语义是「**本次交互期间**发生的、需要锚回的偏移量」。但它的累积点
    /// （`invalidationContext`）在任何布局失效时都会跑（进会话的大量实测、流式、空闲重排…），
    /// 而消费点只在手势 settle —— 于是会跨越「上一次 settle → 本次 settle」这段**任意长**的窗口。
    /// 真机实证（三个构建均复现）：`pendingΣ=+1037.0 applied=1 offset -76.7→960.3` ——
    /// 1037 是更早（offset 在底部一带）累积的，却在之后的 settle 被消费 ⇒ **停手瞬间整屏跳**。
    ///
    /// 清零为何安全：拖拽开始那一刻屏幕上的内容就是用户的基准，**此前**的高度变化早已反映在画面上，
    /// 不需要补偿；**本次手势期间**产生的新变化仍在清零之后的窗口内照常累积。
    /// 本调用只影响 `contentOffset`，**不写任何高度** ⇒ 不可能造成内容/文字偏差。
    public func clearPendingAboveShift() { pendingAboveShift = 0 }

    /// 统一高度条目（2026-09-05 结构收口）：原 estimatedHeights/precalcHeights/heightCache
    /// 三套并行「index→高度」字典合并为单一「index → 条目」，条目携带来源优先级
    /// （measured > precalc > estimated），写入时低优先级不覆盖高优先级。
    enum HeightSource: String { case measured, precalc, estimated }
    /// 统一高度条目 = **高度 + 来源优先级 + 内容版本键**。
    ///
    /// [2026-09-13 内容版本·重排第一刀] `key` 是该条目**写入时**的
    /// `contentKeyByIndex[index]`。此前条目**按 index 存、完全不含内容版本**，于是"内容变了"
    /// 这件事：有的缓存看得见（`MarkdownRenderCache` 用全量 hash），有的看不见（条目只看 index）
    /// ⇒ **陈旧条目永不被发现**。真机后果两类：
    ///   ① **拖动期大片空白**：`prepare()` 拿陈旧偏大条目算帧 → PLAF 要求收缩 →
    ///      `deferSelfSizing` 分支因「已有条目」而冻结（`shouldInvalidateLayout:364`）⇒ 空白，
    ///      settle 才落盘（实测 Σ928.6pt / 38 格位 / 单条最大 −164pt）；
    ///   ② **上滑回看裁尾**：陈旧**偏矮**条目被 `setEntry` 的"低不覆盖高"永久压住。
    /// 检出依据（已核实）：`seedHeight` 与 `configureCell` 都**先写 `contentKeyByIndex`（当前键）
    /// 再走后续 guard**，故陈旧条目记录的旧键与当前键**必然不等** ⇒ 可可靠 demote。
    /// `key == nil` = 写入时尚无内容键（极早期播种）⇒ 保守起见仍信任它，不 demote。
    /// 默认 `nil`：先让字段中性落地（编译通过、行为不变），再在 `setEntry` 里接上捕获。
    struct HeightEntry { var height: CGFloat; var source: HeightSource; var key: String? = nil }
    private var heightEntries: [Int: HeightEntry] = [:]

    /// 该 index 的**有效**条目：当"条目记录的内容键"与"当前内容键"**已知不一致**时返回 nil，
    /// 视同「没有条目」。这样调用方会走兜底链，并且：
    /// - `setEntry` 的"低不覆盖高"不会再被旧值压住（陈旧矮条目可被新值覆盖）；
    /// - `applySnapshot` 的「缺失条目全扫」（`cachedHeight == nil`）会重新播种它；
    /// - `seedHeight` 的 `hasMeasuredHeight` 早退不再拦住内容已变的块。
    /// 键任一为 nil 时不 demote（信息不足，保守当作有效）。
    private func currentEntry(at index: Int) -> HeightEntry? {
        guard let e = heightEntries[index] else { return nil }
        guard let stored = e.key, let cur = contentKeyByIndex[index] else { return e }
        return stored == cur ? e : nil
    }

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
    /// 返回是否写入成功；`false` 仅表示被闸门拒绝（非有限/负值或优先级不足），调用方可据此告警。
    ///
    /// [2026-09-12 写入口收敛] **这是 `heightEntries` 的唯一写入口**。此前 `prepare()`、
    /// `invalidationContext`、`setCachedHeight` 三处直接对字典赋值，形成旁路 —— 2026-09-09
    /// 的 -40 负高度正是从 `invalidationContext` 这条旁路进去的。收敛后闸门只有一处，
    /// 新增写入点无法再漏掉校验。
    @discardableResult
    private func setEntry(_ height: CGFloat, source: HeightSource, at index: Int) -> Bool {
        let rank: (HeightSource) -> Int = { $0 == .measured ? 3 : $0 == .precalc ? 2 : 1 }
        // [2026-09-13 S15 闭环·闸门必须按"当期"条目判] 原先比的是**裸条目**
        // `heightEntries[index]`。于是内容已变的陈旧 `.measured`（其 `key` 与
        // `contentKeyByIndex[index]` 不一致）会出现一个自相矛盾的组合：
        //   · `currentEntry` 认为它**已不是条目**（键不一致 ⇒ nil）；
        //   · `hasMeasuredHeight` 因此返回 false ⇒ `seedHeight` 的 measured 早退**不拦**它，
        //     播种会照常算出一个新的 `.precalc`/`.estimated`；
        //   · 但闸门这里仍按 rank 3 比较 ⇒ 新值**被静默拒绝**（调用方不看返回值，没有任何信号）。
        // 净效果：陈旧高度永久压住新内容，且 `.missing` 每轮重试、每轮失败。这正是 S15
        // 想消灭的"旧实测值永久滞留"，只是断点藏在这个闸门里。
        // 判据与 `currentEntry` **同源**：键不一致即视为无条目 ⇒ 允许覆盖。
        if let existing = currentEntry(at: index), rank(existing.source) > rank(source) { return false }
        // [2026-09-09 NaN 治理·单一入口闸门] 高度必须是**有限非负值**。
        // 布局循环这里做 `attrs.frame = …; y += h` 累加，一个 inf 条目就会让
        // 后续全部 y 与 collectionViewContentSize 变成 inf；下游
        // `contentSize.height - bounds.height` 得到 inf-inf = NaN，CoreGraphics
        // 便打出成片的 "invalid numeric value (NaN) passed to CoreGraphics"。
        guard height.isFinite, height >= 0 else { return false }
        heightEntries[index] = HeightEntry(height: height, source: source, key: contentKeyByIndex[index])
        return true
    }

    // [2026-09-12 删除死机制] 这里原有 `geometryReaderConfirmed: Set<Int>` 及其守卫，
    // 注释称其为「single source of truth」。真机清点发现：**唯一写入者**是
    // `setCachedHeight`，而它**没有任何调用方** ⇒ 集合恒空 ⇒ 守卫永远不成立，
    // 是一条只在热路径上白跑的分支。机制已整体移除；若将来重新引入第二套测高通道，
    // 必须连同「与自 sizing 谁优先」的规则一起进 `setEntry` 单一入口，不得另开旁路。

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
            AppLogger.shared.info("[Scroll][prepare] SKIP width=0 bounds=\(cv.bounds) itemCount=\(itemCount)", category: "ChatList.Scroll")
            return
        }

        itemAttributes.removeAll(keepingCapacity: true)
        itemAttributes.reserveCapacity(itemCount)

        var y: CGFloat = 0
        for i in 0..<itemCount {
            let ip = IndexPath(item: i,section: 0)
            let attrs = UICollectionViewLayoutAttributes(forCellWith: ip)
            let h: CGFloat
            // [2026-09-12 抖动根因·兜底值按类型] 这里原先对**任何**无条目的 item 都用
            // `estimatedItemHeight`(200pt)。但块级 cell（`b:` 前缀，含工具胶囊 `readImageTool`36 /
            // `file`40 / `default`36）只可能几十 pt —— 兜底 200 意味着**每个这类块凭空多出 ~160pt**，
            // 被真正量到后逐个收缩，视口上方累计即整屏平移（真机实录 aboveΣ=-648.6pt，
            // `liveShrink` 19 条各 −160.3/−164.0，恰好 = 200−39.7 / 200−36）。
            // 该缺口在本文件既有注释里已被记录过（「落到 estimatedItemHeight(200pt) 首次自测大修正」），
            // 但当时只补了重播种路径，没堵住兜底本身。此处按内容键前缀给**同量级的**兜底：
            // 块类 44（块级真实高度 16~40 量级，只可能低估不可能 6 倍高估），其余维持原值。
            // [2026-09-13 行间空白根因·兜底按类型细化] 真机实录同一会话存在两种状态交替：
            //   紧: totalH=2390 flow=[w:118, h:25,  b:40, b:36 …]
            //   胀: totalH=2675 flow=[w:200, h:200, b:44, b:44 …]
            // 胀态的每一项都**恰好等于兜底值** ⇒ 那些 index 的高度条目**丢失了**，布局回落到
            // `estimatedItemHeight`(200) ⇒ 列表凭空长出 285pt（= 肉眼看到的"行间空行"），条目
            // 回来后又缩回去（= "内容缩小、视图变了"）。**与拖动/停手无关**（idle 里也交替出现）。
            // 其中最离谱的是 header：它的真实高度是**常量 28**（播种分支写死 28），却被兜底成 200。
            // 这里按内容键前缀给同量级兜底 —— 需注意这只能"减轻伤害"，条目为何丢失是**独立根因**，另行定位。
            let key = contentKeyByIndex[i]
            if let e = currentEntry(at: i)?.height {
                h = e
                // [2026-09-12 兜底对「条目丢失」免疫] 顺手记住「该内容键上次的真实高度」。
                // 为什么必须这样兜底：条目是**按 index** 存的，而 `remapHeights`
                // 按 item 身份重建时会丢掉未匹配 index 的条目（真机实录同一会话两种形态交替：
                // `[w:118,h:25,b:40,b:36…]` ↔ `[w:200,h:200,b:44,b:44…]`，totalH 2390 ↔ 2675）。
                // 逐个去堵丢点是无底洞，而**内容键是稳定的** —— 用它记住的高度做兜底，
                // 即使条目丢了也不会回落到 200 那种 6 倍误差的常量。
            // 注：原「按键记忆 lastHeightByKey」一层已于 2026-09-13 删除（全库无写入点 ⇒ 分支恒不执行）。
            } else if let k = key, let memo = peekMeasuredHeight(forKey: k, width: width) {
                // [2026-09-13 顶部抖动根因] 再退一层到**进程级实测 memo**（同源、按键）。
                // 真机实录：拖动期 `flow=[w:200, h:28, …]` / 停手 `flow=[w:118, h:25, …]`，
                // 顶部两项差 **82pt** —— 肉眼就是"顶部用户消息与 AI 回复在抖"。
                // 200 是 `estimatedItemHeight` 兜底（`w:` 先前没在下面的 switch 里，直接落 200），
                // 而 memo 里该内容键的实测值就是 118 ⇒ 取它即可，无需任何常量。
                h = memo
            } else {
                // 首次见到该内容键（连记忆都没有）才用类型化常量兜底。
                // [2026-09-13 实测校准] 像素级量测（3× 截图）：胶囊**高度是 36.0pt**，
                // 正常态项间距 10.3pt、异常态 16.3pt —— 差值 6.0pt 恰好是"兜底 44 与真实 36/40 之差"。
                // 故块类兜底取 **36**（最常见值：胶囊 36；思考头 40 仅多 4），不再用 44（每块多 8）。
                switch key?.prefix(2) {
                case "b:":
                    // [2026-09-13 残留抖动（+4pt×N）] 块级里有两种高度：**思考块 40**（`b:…:e0/:e1`）
                    // 与**其他块 36**（胶囊/文件 36~40）。先前一律给 36，于是缺条目的那些思考块
                    // 拖动期是 36、条目到位后变 40 ⇒ 每块 +4，实测 `totalH 2344 → 2394`（+50），
                    // 肉眼即"停手时自动校正一下"。**判别信息就在内容键里**：只有 thinking 块带 `:eN` 后缀。
                    h = (key?.contains(":e") ?? false) ? 40 : 36
                case "h:": h = 28     // header 是常量行
                case "f:": h = 4      // footer 空态
                case "w:":
                    // [2026-09-13 顶部抖动根因] 用户气泡。格式 `w:<msgId>:<字数>:<附件数>`，
                    // **末段是附件数**：附件异步挂载时它 0→1 会让整个内容键变化，于是新键既无条目、
                    // 也无 memo 记忆 ⇒ 先前直接落 default 的
                    // `estimatedItemHeight`(200)，而真值是 118 ⇒ 顶部整块差 82pt（肉眼=顶部抖动）。
                    // 带附件的用户气泡高度由附件主导（实测 118~185），纯文本约 44~70。
                    // ⚠️ 解析内容键末段与 `contentKey(for:)` 的格式**成对耦合**，改格式须同步改此处。
                    let parts = key?.split(separator: ":") ?? []
                    h = (Int(parts.last ?? "0") ?? 0) > 0 ? 118 : 48
                default:   h = estimatedItemHeight
                }
            }
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
            AppLogger.shared.debug("[prepare] #\(Self.prepareCallCount) \(String(format: "%.1f", elapsed))ms items=\(itemCount) totalH=\(String(format: "%.0f", totalHeight)) cacheHits=\(self.heightEntries.count)", category: "ChatList.Stall")
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
    /// 返回**视口上方**的高度变化合计（`aboveSum`）。调用方须把它加到 `contentOffset.y` 上：
    /// 解冻后 offset 是数值恢复的，视口上方的高度变化会 1:1 平移可见内容；不锚定就会
    /// 看到「停下瞬间整屏跳一下」（真机实录 aboveSum = −648.6pt）。
    @discardableResult
    public func applyDeferredHeights() -> CGFloat {
        guard !deferredHeights.isEmpty else { return 0 }
        let vpTop = collectionView?.contentOffset.y ?? 0
        let vpBottom = vpTop+(collectionView?.bounds.height ?? 0)
        var aboveSum: CGFloat = 0,insideSum: CGFloat = 0,dropped = 0
        var detail: [String] = []
        for (idx,h) in deferredHeights {
            let old = heightEntries[idx]?.height ?? estimatedItemHeight
            // [2026-09-12 修复「延后即丢弃」] 闸门只在 `heightEntries[idx]?.source == .measured`
            // （**已有条目**）时才延后，而这里原先只在 `heightEntries[idx] == nil`（**没有条目**）
            // 时才应用 —— 两条件互斥 ⇒ **每一条延后项都被丢弃**：浏览期间该收缩的 cell 会一直
            // 保持旧的高帧，直到别的路径触发重排。症状就是本函数末尾那行聚合日志恒为
            // `dropped=n aboveΣ=+0.0 insideΣ=+0.0`（n 条全部被丢，没有任何位置分类被累加）。
            // 解冻时应用才是**构造上安全**的时机（这正是延后机制在等的那一刻），故改为
            // 「与现值有实质差异就应用」；`dropped` 保留，用于统计真正无差异的项。
            let cur = heightEntries[idx]?.height
            if cur == nil || abs((cur ?? 0) - h) > 0.5 {
                setEntry(h, source: .measured, at: idx)
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
            // [2026-09-12] 原为 `AppLogger(category:).info(…)` 内联临时实例 ⇒ **整行被静默丢弃**
            // （真机实录：同一批 28 条 `inv` 事件，本行 0 条）。改用 `AppLogger.shared` 写法。
            AppLogger.shared.info(
                "[SettleJitter][flush] n=\(deferredHeights.count) dropped=\(dropped) aboveΣ=\(String(format: "%+.1f", aboveSum)) insideΣ=\(String(format: "%+.1f", insideSum)) :: \(detail.prefix(12).joined(separator: "|"))",
                category: "ChatList.Settle")
        }
        deferredHeights.removeAll()
        return aboveSum
    }

    public override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        let index = preferredAttributes.indexPath.item
        let prefH = preferredAttributes.size.height
        let origH = originalAttributes.size.height

        if deferSelfSizing {
            // [2026-09-12 抖动根因·闸门语义修正] 原先只把 `source == .measured` 视为「已缓存」，
            // 于是**条目源是 .estimated / .precalc 的 cell 完全不被保护** —— 而真机事故里
            // 正是这类 cell：工具胶囊的估算条目是 .estimated(36)，但布局在它们身上先用了兜底
            // `estimatedItemHeight`(200)，等 PLAF 给回真实值时就产生 200→36 的收缩，且**在手势中
            // 被放行**（`[ScrollMetrics] liveShrink … phase=decel` 19 条、各 −160.3/−164.0pt）。
            // 判据改为「**任何已有条目**都算已缓存」：延后机制的目的就是「手势期间不改几何」，
            // 与条目来源无关；解冻后由 `applyDeferredHeights` 原子应用并做 offset 锚定。
            let hasCached = currentEntry(at: index) != nil
            if hasCached {
                if prefH <= origH+0.5 {
                    if abs(prefH-origH)>0.5 {
                        deferredHeights[index] = prefH
                        // [2026-09-13 空白量化] 本分支＝「拖动期拒绝收缩」，被拒的幅度就是
                        // 「cell 保留的虚高帧」＝**空白的上限**。此门是 2026-09-12 为修
                        // `liveShrink -160pt` 抖动而加（见上方注释），不能凭"看起来多余"就放宽；
                        // 必须先量化：若本次拖动 Σ|delta| 只有几十 pt ⇒ 它不是"大片空白"的成因；
                        // 若达数百 pt ⇒ 确认，且可据 `pos` 决定可否只对"视口内"放行。
                        // 只读、不回写；用 AppLogger.shared（内联实例会整行丢日志）。
                        if let cv = collectionView, index < itemAttributes.count {
                            let f = itemAttributes[index].frame
                            let viewTop = cv.contentOffset.y
                            let viewBottom = viewTop + cv.bounds.height
                            let pos = f.maxY <= viewTop ? "above" : (f.minY >= viewBottom ? "below" : "inside")
                            AppLogger.shared.info(
                                "[DeferShrink] idx=\(index) orig=\(String(format: "%.1f", origH))→pref=\(String(format: "%.1f", prefH)) delta=\(String(format: "%+.1f", prefH-origH)) pos=\(pos) src=\(heightEntries[index]?.source.rawValue ?? "?") key=\(contentKeyByIndex[index] ?? "??")",
                                category: "ChatList.Blank")
                        }
                    }
                    return false
                }
            } else {
            }
        }

        let delta = abs(prefH-origH)

        let mustInvalidate: Bool
        if currentEntry(at: index)?.source == .measured {
            mustInvalidate = delta>2
        } else {
            mustInvalidate = delta>0.5
        }
        if mustInvalidate && delta>100 {
            // [2026-09-09] key 从 2 字符前缀扩为完整 contentKey（含 messageId/blockId/
            // contentCount）——高度裁切类「丢字」复盘时直接指认块，不再需要反查。
            AppLogger.shared.info("[CellSizing] INVALIDATE idx=\(index) delta=\(String(format: "%.0f", delta)) est=\(String(format: "%.0f", origH)) → pref=\(String(format: "%.0f", prefH)) cached=\(heightEntries[index]?.source == .measured) key=\(contentKeyByIndex[index] ?? "??")", category: "ChatList.CellMetrics")
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
        // [2026-09-12 写入口收敛] 写入统一走 `setEntry`（优先级 + 有限非负闸门单一入口），
        // 不再直接对字典赋值 —— 此处曾是绕过闸门的「第四写入口」，9-09 的 -40 负高度
        // （SwiftUI hosting 损坏测量）就是从这里回流进布局的。
        if !setEntry(newH, source: .measured, at: index) {
            AppLogger.shared.warning(
                "[CellSizing] REJECT nonfinite/negative preferred height=\(String(format: "%.0f", newH)) idx=\(index)（保留原条目，负高度防御）",
                category: "ChatList.CellMetrics")
        }

        if let cv = collectionView {
            let cellTopY = originalAttributes.frame.minY
            let vpTop = cv.contentOffset.y
            let pos = originalAttributes.frame.maxY <= vpTop ? "above"
                : (cellTopY<vpTop+cv.bounds.height ? "inside" : "below")
            // [2026-09-13 顶部极细微抖动·第四修] **只在真的有内容在视口上方时才锚定**。
            // 前三次修的教训链：只补 above → 顶部因"没有 above"而漏 → 补 inside 收缩 →
            // 补 inside 双向。补到 inside 双向后日志暴露了新问题（`[SettleAnchor]`，见调试行）：
            //   pendingΣ=+20.0  offset 0.0→20.0   ← **已经在最顶部**，却把 offset 推了 20pt，
            //   pendingΣ=-9.3   offset 0.0→-9.3      把首项的顶部藏起来 ⇒ 肉眼就是那一下轻抖。
            // 语义上：offset == 0 时顶部边界**就是内容起点**，条目变高不会改变"offset 0 处是什么"
            // ⇒ 此时锚定没有意义，反而制造位移。故加 `cv.contentOffset.y > 0.5` 前置条件。
            // [Fix 2026-09-14] `pos == "above"` 已在上面用 `contentOffsetAdjustment` **立即补偿**
            //（且与手势无关）⇒ 这里**不再累加**，否则解冻时 `applyDeferredHeights` 会再锚一次
            // ⇒ 双重补偿 ⇒ 反跳。`inside` 的累加保留：它的立即补偿只在非手势期做，
            // 手势期仍走"延后到解冻锚定"这条原路，口径不变、两者互不重叠。
            if cv.contentOffset.y > 0.5, pos == "inside", !isStreamingCell(index) {
                pendingAboveShift += delta
            }
            #if DEBUG
            let phase = cv.isDecelerating ? "decel" : (cv.isTracking ? "drag" : "idle")
            // Record EVERY correction (no threshold)
            ScrollMetricsRecorder.shared.record(
                kind: "inv", idx: index, a: oldH, b: newH,
                key: contentKeyByIndex[index] ?? "",
                src: estimateSrc,pos: pos,offset: vpTop,note: phase,
                tag: metricsTagByIndex[index] ?? "")
            #endif
            // [2026-09-12 抖动探针·补盲区] 原条件只覆盖 `isDecelerating` ⇒ **拖动中（isTracking）
            // 一条日志都不打**。而真机现象「只有首次上滑抖、滑得越快抖得越快、滑到顶后再往下正常」
            // 正指向拖动期间发生的位移：视口**上方**的块首次被实测（估算高 → 实测高）会让下方内容
            // 整体平移；到过顶部后全部已实测 ⇒ 不再位移。故覆盖 drag+decel，并把相位与位置分类
            // 一起打出 —— `pos=above` 的 Δ 累加即内容被平移的量。
        }

        // memo here could capture a mid-stream height. See.

        if let cv = collectionView,!suppressContentOffsetAdjustment {
            let cellTopY = originalAttributes.frame.minY
            let cellBottom = originalAttributes.frame.maxY
            let vpTop = cv.contentOffset.y
            let vpBottom = vpTop+cv.bounds.height
            if cellTopY<vpTop && cellBottom <= vpTop {
                // [Fix 2026-09-14] **视口上方**的变高补偿：与手势无关，必须做。
                // Apple 官方对这种"高度变化导致位置跳变"给的唯一专门机制就是 `contentOffsetAdjustment`
                //（WWDC2014/226：「so you don't see jump from one position to another」）。
                // 原实现把整段补偿门控在 `!isTracking && !isDecelerating` 内 ⇒ 手势期完全不补偿；
                // 而本次已放行"拖动期内容长高" ⇒ 上方块变高会把可见内容整体平移 = 手指下那阵抖动。
                // 语义澄清：这不是"手势期改几何"，而是**保持屏幕内容不变** ⇒ 必须与手势无关。
                // ⚠️ 与之互补：下面的 `pendingAboveShift` 在"已立即补偿"时**不再累加**（防双重补偿 ⇒ 反跳）。
                ctx.contentOffsetAdjustment = CGPoint(x: 0,y: delta)
            } else if !cv.isTracking,!cv.isDecelerating {
                // 视口内/下方的补偿仍只在非手势期做（避免与用户手势竞争，原意保留）。
                if cellTopY >= vpTop && cellTopY<vpBottom && !isStreamingCell(index) {
                    ctx.contentOffsetAdjustment = CGPoint(x: 0,y: delta)
                } else if isStreamingCell(index) && isAutoScrollPinning && delta>0 {
                    // Actively streaming cell
                    ctx.contentOffsetAdjustment = CGPoint(x: 0,y: delta)
                }
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

    /// 索引高度被「宽度变更」**整表清空**后的回调（由 Coordinator 接上，用来**重播种**）。
    ///
    /// 为什么必须有：`purgeIndexHeightsForWidthChange()` 之后本类**无法**重建条目
    ///（重建需要 `messages`，只有 Coordinator 有）。缺了这一步，每个 index 都成"无条目"，
    /// 而宽度变更**没有重播种路径**（旋转/首次布局 settle 都不触发 `applySnapshot`）⇒
    /// 下一次 `configureCell` 的兜底守卫（`!hasMeasuredHeight && !hasPrecalcHeight`）失守，
    /// 就会在**滚动路径上**跑昂贵测量 —— 用户气泡那条是**主线程 cmark 渲染**
    /// ⇒ 用户实测「滑到用户消息处卡顿一下」。
    ///
    /// ⚠️ 触发时机比想象的早：`lastSettledWidth` 初值 0，故**进会话后的第一次布局 settle
    /// 就会清一次整表**（`scheduleWidthPurge` 的 `abs(width - 0) >= 0.5` 必然成立）。
    public var onIndexHeightsPurged: (() -> Void)?

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

            // [2026-09-13 修正此前一步的错法] 曾把这里改成 `clearHeightCache(keepingSharedMemo: true)`，
            // **那是错的**：该入口是给「会话切换 / 字体变更」用的，会**连 `contentKeyByIndex` 与
            // `footerHugByIndex` 一起清**。而宽度变更**不改变内容与块的身份** —— 这两个表是
            // **宽度无关**的，清掉纯属有害：清完**没有任何路径会重播种**（旋转不触发
            // `applySnapshot`，`$messages` 也不变），于是离屏 item 在 `prepare()` 里连
            // 「按内容键前缀选类型常量」的兜底都拿不到，**全部落到默认 200pt** ⇒
            // contentSize 虚高、滚动位置错乱（每项约 +150pt）。
            // 宽度变更真正失效的只有两样：索引高度条目、以及**键含宽度**的 user bubble memo
            //（旧键永不命中，不清只会随旋转/分屏单调增长 —— 与 2026-09-08 那次"从不清理"同型）。
            // 故用**语义专用**的入口，而不是复用为"内容身份失效"设计的那个。
            self.purgeIndexHeightsForWidthChange()
            self.lastSettledWidth = cv.bounds.width
            // 清空之后**立刻**请 Coordinator 重播种（唯一入口），且必须在 `invalidateLayout()` 之前 ——
            // 否则紧随其后的那次布局 pass 仍然读到"无条目"，会退到块间通用常量
            //（`b:` → 36/40）⇒ 离屏内容被算成几十点、contentSize 塌缩、滚动位置错乱。
            self.onIndexHeightsPurged?()
            self.invalidateLayout()
        }
    }

    // [2026-09-13 出入口统一·删除冗余实现] 此处原有 `updateCacheForSnapshot(oldIds:newIds:)`：
    // 与下方 `remapHeights(oldIds:newIds:)` 做**同一件事**（按 item 身份搬 index 条目），
    // 而后者是其**严格超集**（额外搬 contentKeyByIndex / footerHugByIndex / metricsTagByIndex）。
    // 二者原本在 `applySnapshot` 里对**同一映射连跑两次**，前者结果被后者完全覆盖。
    // 按「一个功能一个出入口」删除本方法 —— 重映射只保留 `remapHeights` 一处。

    /// 索引高度失效的**唯一入口**（2026-09-13 出入口统一）。
    ///
    /// 原先是**两个方法做同一件事**：`invalidateHeight`（条目 + 进程 memo 一起剔）与
    /// `purgeIndexEntry`（只剔条目、保留 memo）—— 同一语义两个出入口，调用方必须记住用哪个，
    /// 用错就出事：用 `invalidateHeight` 会把**紧接着重播种要读的 memo** 也剔掉
    /// → 种子退化为粗估 → 上滑抖动（2026-09-06 真机复现）。
    /// 现收敛为**一个方法 + 一个显式策略参数**，语义差异成为参数而非"另一条隐式路径"：
    ///   - `.indexOnly`：只剔索引条目，**保留** content-keyed memo。
    ///     用于 applySnapshot 清理「旧 cell 在 apply 期间写脏的索引高度」——该高度属于旧内容，
    ///     但 memo 中该 contentKey 的实测高度仍然有效（紧接着的重播种要读它）。
    ///   - `.withMemo`（默认）：连 memo 一起剔。内容真换了、不希望旧实测被复用时用。
    public enum MemoPolicy { case indexOnly, withMemo }

    public func invalidateHeight(at index: Int, memo: MemoPolicy = .withMemo) {
        // 统一条目：一次移除即完成原三字典的清空（measured/precalc/estimated 同源）。
        heightEntries.removeValue(forKey: index)
        if memo == .withMemo, let key = contentKeyByIndex[index] {
            // 连带剔除该内容键的进程级实测 memo（原 `invalidateHeight` 语义）。
            invalidateMemo(forKey: key)
        }
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
        var newKeys: [Int: String] = [:]
        var newHug: [Int: Bool] = [:]
        var newTags: [Int: String] = [:]
        for (newIndex,item) in newIds.enumerated() {
            guard let oldIndex = oldIndexByItem[item] else { continue }
            if let e = heightEntries[oldIndex] { newEntries[newIndex] = e }
            if let k = contentKeyByIndex[oldIndex] { newKeys[newIndex] = k }
            if let h = footerHugByIndex[oldIndex] { newHug[newIndex] = h }
            #if DEBUG
            if let t = metricsTagByIndex[oldIndex] { newTags[newIndex] = t }
            #endif
        }
        heightEntries = newEntries
        contentKeyByIndex = newKeys
        footerHugByIndex = newHug
        #if DEBUG
        metricsTagByIndex = newTags
        #endif
    }

    /// 该索引**当前记录**的高度（来源不限：measured / precalc / estimated）。
    ///
    /// 全库唯一入口：此前另有 `precalcHeight(at:)` 与本方法逐字相同（纯重复），
    /// 已删除，其唯一调用点统一到本方法。**按来源分档**请用 `hasMeasuredHeight` /
    /// `hasPrecalcHeight`。
    public func cachedHeight(at index: Int) -> CGFloat? {
        // 走 currentEntry：**内容已变的陈旧条目视为无条目** ⇒ `applySnapshot` 的
        // 「缺失条目全扫」（判据就是 `cachedHeight(at:) == nil`）会重新播种它，
        // 而不是被一条过期值骗过（此前 `.measured` 陈旧条目既不被全量播种刷新、
        // 也不被全扫覆盖 ⇒ 永久滞留，拖动期被冻结成空白）。
        currentEntry(at: index)?.height
    }

    public func hasPrecalcHeight(at index: Int) -> Bool {
        currentEntry(at: index)?.source == .precalc
    }

    /// 该索引是否已有「实测」高度（source == .measured）。
    /// 合并字典后 cachedHeight 对任意来源条目都返回值，
    /// 旧三字典时代「仅实测高度才挡住估算/预演」的语义分界由本访问器承接：
    /// 种子循环、configureCell 与 prefetch 兜底必须用它做守卫——否则流式
    /// chunk 的逐次重播种（估高随内容增长刷新）会被首帧估算永久冻结，
    /// 流式 cell 停在首帧高度，正文与下方工具卡/思考块重叠（2026-09-05 回归）。
    public func hasMeasuredHeight(at index: Int) -> Bool {
        // 关键后果：内容已变的陈旧 `.measured` 条目不再算"已实测" ⇒ `seedHeight` 的
        // `guard !hasMeasuredHeight(at:) else { return }`（`+Snapshot.swift` 的 `seedHeight`）不再
        // 拦住内容已变的块，它会带**当前内容键**重新播种（这正是 I11 缺的那条失效路径）。
        // [2026-09-13] 此处原先写死行号 `+Snapshot.swift:579`，已因搬移失效；跨文件引用一律用
        // 符号名而非行号 —— 行号引用正是这些注释反复过期的根因。
        currentEntry(at: index)?.source == .measured
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

    /// [2026-09-13] **静默版** memo 查询：语义与 `measuredHeight(forKey:width:)` 完全相同，
    /// 但**不打日志**。用途：作为 `prepare()` 的兜底链一环 —— 那条路径每次布局都可能走到，
    /// 用带日志的版本会把 `[MEMO] MISS` 刷成海啸（该行是无节流打印的）。
    public func peekMeasuredHeight(forKey key: String,width: CGFloat) -> CGFloat? {
        os_unfair_lock_lock(&Self._memoLock)
        let entry = Self._sharedMeasuredHeights[key]
        os_unfair_lock_unlock(&Self._memoLock)
        guard let entry, abs(entry.width-width) < 1 else { return nil }
        return entry.height
    }

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
        // [2026-09-12] 内容键记忆表随条目一起清：它的语义是"上次布局真实用到的高度"，
        // 字体变更/会话切换后该口径失效（memo 的 contentKey 不含字体指纹，同理）。
        // 注：原 `lastHeightByKey.removeAll()` 已随该死机制一并删除（2026-09-13）。
        if !keepingSharedMemo { Self.clearSharedMemo() }
        contentKeyByIndex.removeAll()
        footerHugByIndex.removeAll()
        // [2026-09-08] user bubble 测量 memo 同为进程级静态字典，此前**从不清理**
        // → 随会话切换单调增长（长会话残留常驻）。统一在清高度缓存时释放。
        MessageCollectionView.Coordinator.clearUserBubbleMemo()
    }

    /// **宽度变更**（旋转 / 分屏）的失效入口 —— 只丢「与宽度有关」的两样。
    ///
    /// ⚠️ 它与 `clearHeightCache` 的区别是**语义级**的，不是"少清一点"：
    ///   · `clearHeightCache`（会话切换 / 字体变更）：那两种场景下**内容身份本身已失效**
    ///     （字体变了，同样的 contentKey 对应的排版高度不再可比），故连
    ///     `contentKeyByIndex`、`footerHugByIndex` 一起清是对的；
    ///   · 本方法（宽度变更）：内容与块的**身份完全没变**，只是可用宽变了。
    ///     若把内容键也清掉，`prepare()` 的兜底链会失去「按内容键前缀选类型常量」这一层，
    ///     离屏 item 直接落默认 200pt；而宽度变更**没有重播种路径**（旋转不触发
    ///     `applySnapshot`，`$messages` 也不变）⇒ contentSize 虚高、滚动位置错乱。
    /// 共享 memo 按 `(key,width)` 匹配，宽度不通即不命中 ⇒ 保留安全且是收益。
    /// user bubble memo 的键**含 `usableTextWidth`**（`+Heights`），宽度一变旧键永不命中，
    /// 不清只会在反复旋转/分屏时单调增长。
    public func purgeIndexHeightsForWidthChange() {
        heightEntries.removeAll()
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
/// [并发] 内部状态（环形缓冲 + head/count）全部由 `lock`（NSLock）保护，`isEnabled` 是纯 Bool
/// 热路径读（最坏情况漏记/多记一条，对诊断无影响）⇒ 用 `@unchecked Sendable` 标注。
/// 此前因为工程从未定义 `DEBUG`，这个类型从未参与编译，故 Swift 6 的并发检查也从未跑到它。
final class ScrollMetricsRecorder: @unchecked Sendable {
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

    /// [2026-09-12] 一次性哨兵检查标志。
    ///
    /// 为什么放在 `record` 里：先前把它挂在「场景相位变化」与「进入会话（attach）」两处，
    /// 真机两次都**一条日志都没有** —— 相位回调对初始值不触发，而 `attach` 已不是活路径。
    /// 改挂在这里：**只要发生任何一次记录尝试，就必然检查一次**，且不依赖任何生命周期钩子。
    /// `isEnabled` 为 false 时 record 每帧都会走到这里，所以必须用标志位保证只做一次文件 stat。
    private var sentinelChecked = false

    /// [2026-09-13 P0 降噪] 把「一次性哨兵检查」抽成方法：既供本类 `record`，
    /// 也供**不走 record 的热路径探针**（`traceSet`/`tracePLAF`）复用同一个开关。
    /// 若各写一份，那些探针会永远等不到开关（`refreshFromSentinel` 原本只在 `record` 里跑）。
    /// 仍然只做**一次**文件 stat（`sentinelChecked` 标志），此后热路径只剩一次 Bool 读。
    func ensureEnabledChecked() {
        if !sentinelChecked {
            sentinelChecked = true
            refreshFromSentinel()
        }
    }

    func record(kind: String,idx: Int = -1,a: Double = 0,b: Double = 0,
                key: String = "", src: String = "", pos: String = "",
                offset: Double = 0, note: String = "", tag: String = "") {
        ensureEnabledChecked()
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
    /// [2026-09-12 出口] 把环内事件整体落盘为 JSON —— 让「滑一次 → 取全量」取代
    /// 「加探针 → 装机 → 人肉 grep 日志」。落盘位置与 AppLogger 同目录
    /// （`<miniClawRoot>/logs/scroll-metrics.json`），文件名固定、每次覆盖。
    ///
    /// 只读：`snapshot(clear: false)` 不清环，故可反复落盘。
    @discardableResult
    func dumpToFile() -> URL? {
        let events = snapshot(clear: false)
        guard !events.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted])
        else { return nil }
        let dir = FileSystemManager.shared.miniClawRoot.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scroll-metrics.json")
        let wrote = (try? data.write(to: url, options: .atomic)) != nil
        // [2026-09-12] 落盘之外**同时把分析结论写进主日志**：真机 `devicectl copy from` 对这份
        // JSON 会报 `Failed to retrieve the file node`（同一目录的主日志却能正常拉取），
        // 若结论只留在文件里就等于拿不到。分析器是纯函数，这里直接跑，把 kind 直方图与发现项打进日志。
        var byKind: [String: Int] = [:]
        for e in events { byKind[(e["kind"] as? String) ?? "?", default: 0] += 1 }
        let hist = byKind.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        AppLogger.shared.info("[ScrollMetrics] dump n=\(events.count) wrote=\(wrote ? 1 : 0) \(hist)",
                              category: "ChatList.CellMetrics")
        let findings = ScrollMetricsAnalyzer.analyze(events: events)
        AppLogger.shared.info("[ScrollMetrics] findings=\(findings.count) kinds=\(Set(findings.map(\.kind)).sorted().joined(separator: ","))",
                              category: "ChatList.CellMetrics")
        for f in findings.prefix(24) {
            AppLogger.shared.info("[ScrollMetrics] \(f.kind): \(f.detail)", category: "ChatList.CellMetrics")
        }
        return wrote ? url : nil
    }

    /// [2026-09-12 开关] 容器内存在 `logs/.scroll-metrics-on` 时启用录制，文件消失即停。
    ///
    /// 用**哨兵文件**而不是 UI 或启动参数：真机上 `devicectl copy to` 即可开关，
    /// 不需要为它加任何界面；哨兵不存在时录制保持关闭，热路径只剩 `guard isEnabled`
    /// 一次 Bool 读（与改动前一致，故不影响性能与现有行为）。
    func refreshFromSentinel() {
        let sentinel = FileSystemManager.shared.miniClawRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(".scroll-metrics-on")
        let on = FileManager.default.fileExists(atPath: sentinel.path)
        // [2026-09-12] 每次调用都留证据（相位变化很少，一次会话几行）。原先只在状态变化时打，
        // 于是「文件没找到」与「函数没被调用」两种情况都表现为**没有任何日志**，无法区分 ——
        // 这正是上次导出拿不到数据却查不出原因的地方。这里把 on / isEnabled / 解析出的路径
        // 全部打出，一眼可对照文件到底该放哪。
        AppLogger.shared.info(
            "[ScrollMetrics] 哨兵 on=\(on ? 1 : 0) isEnabled=\(isEnabled ? 1 : 0) root=\(FileSystemManager.shared.miniClawRoot.path)",
            category: "ChatList.CellMetrics")
        if on != isEnabled { setEnabled(on) }
    }
}

#endif

/// 滚动抖动分析器：**纯函数**，输入 = `ScrollMetricsRecorder` 落盘的 JSON 事件数组，
/// 输出 = 发现项。让「抖」从肉眼判断变成可断言的结果 —— 取一次导出即可回归。
///
/// 判据全部来自本项目真实事故，只报**结构性异常**，不报正常流式增长：
///  1. `flapping`    —— 同一 key 的高度被反复改成不同值（≥3 次且极差 >0.5pt）。
///                      对应「同一块在滑动中被反复提交不同高度」。
///  2. `aboveShift`  —— 视口**上方**的高度变化合计非零。解冻后 offset 是数值恢复的，
///                      故上方变化会 1:1 平移可见内容（这是「整屏位移」的量化判据）。
///  3. `liveShrink`  —— drag/decel 相位内发生高度**收缩**。增长属正常（流式），
///                      收缩意味着手势中旧高帧被撤掉 ⇒ 内容在手势里跳动。
///
/// 不判「延后项被丢弃」：被丢弃的条目不会产生 flush 事件，导出里没有痕迹
/// （该缺陷由 `applyDeferredHeights` 的条件本身保证，见其注释）。
enum ScrollMetricsAnalyzer {
    struct Finding {
        let kind: String
        let detail: String
    }

    static func analyze(events: [[String: Any]]) -> [Finding] {
        var findings: [Finding] = []

        // 1) 同一 key 反复改高
        var heightsByKey: [String: [Double]] = [:]
        for e in events {
            guard let kind = e["kind"] as? String, kind == "inv" || kind == "flush",
                  let b = e["b"] as? Double else { continue }
            heightsByKey[(e["key"] as? String) ?? "?", default: []].append(b)
        }
        for (key, hs) in heightsByKey.sorted(by: { $0.key < $1.key }) where hs.count >= 3 {
            let span = (hs.max() ?? 0) - (hs.min() ?? 0)
            if span > 0.5 {
                findings.append(Finding(
                    kind: "flapping",
                    detail: "key=\(key) 高度被改 \(hs.count) 次，极差 \(fmt(span))pt（\(fmt(hs.min() ?? 0))~\(fmt(hs.max() ?? 0))）"))
            }
        }

        // 2) 视口上方变化合计
        var aboveSum: Double = 0
        for e in events {
            guard let kind = e["kind"] as? String, kind == "inv" || kind == "flush",
                  (e["pos"] as? String) == "above",
                  let a = e["a"] as? Double, let b = e["b"] as? Double else { continue }
            aboveSum += b - a
        }
        if abs(aboveSum) > 0.5 {
            findings.append(Finding(
                kind: "aboveShift",
                detail: "视口上方高度变化合计 \(fmt(aboveSum))pt — 解冻后会 1:1 平移可见内容"))
        }

        // 3) 手势相位内的收缩
        for e in events {
            guard let kind = e["kind"] as? String, kind == "inv",
                  let phase = e["note"] as? String, phase == "drag" || phase == "decel",
                  let a = e["a"] as? Double, let b = e["b"] as? Double,
                  a - b > 0.5 else { continue }
            findings.append(Finding(
                kind: "liveShrink",
                detail: "\(phase) 中高度收缩 \(fmt(b - a))pt idx=\(e["idx"] ?? "?") key=\((e["key"] as? String) ?? "?")"))
        }

        return findings
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
