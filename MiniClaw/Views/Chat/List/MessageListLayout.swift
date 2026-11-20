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
    /// `contentKey(at: index)`。此前条目**按 index 存、完全不含内容版本**，于是"内容变了"
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
    /// [治本·步1 2026-09-17] `provenance` = **这条高度的生产者身份**。
    ///
    /// 为什么必须加：真机 M21 实测 `src=estimated` 的"种子值"出现了 `18/28/30/42/71`
    /// —— 而 `seedFallbackHeight` 只能产出 `36/40/20+n*16` ⇒ **同一个 `src` 标签下藏着多个生产者**，
    /// 于是"违约该归因给谁"根本无法回答，任何修复都只能靠猜。
    /// 该字段只**记录身份**，不参与 rank 闸门与任何判定 ⇒ 零行为变更。
    struct HeightEntry {
        var height: CGFloat
        var source: HeightSource
        var key: String? = nil
        /// 生产者（例：`est.literal28` / `est.footer` / `est.perKind` / `precalc.memo`）。
        /// `nil` = 未知来源（旧路径），诊断时回落到 `source.rawValue`。
        var provenance: String? = nil
    }
    /// 高度存储（身份键）。行号只是语法糖：每次读写都先翻译成 `MessageListItem`，
    /// 因此插入/删除导致的行号位移**不会**再丢条目 —— 旧实现需要 `remapHeights` 做二次映射，
    /// 映射失败即 `continue`（= 丢一条），落到兜底常量后就是用户看到的间距异常。
    private let heightCache = MessageHeightCache()
    /// 行身份 → 当前内容键（用于判断条目是否过期）
    private var contentKeyByItem: [MessageListItem: String] = [:]
    /// 行身份 → footer 是否贴合（间距策略）
    private var footerHugByItem: [MessageListItem: Bool] = [:]

    /// 该 index 的**已记录**条目（**注意：内容过期也返回**）。
    ///
    /// 2026-11-15 高度重写后语义变了：过期不再等于"没有条目"，而是由 `isStaleEntry`
    /// 单独表达——高度继续可用（避免跳回兜底常量），只影响"要不要重新估算"。
    /// 下面这段描述的是**改造前**的行为，保留作历史背景，不要再按它写新代码。这样调用方会走兜底链，并且：
    /// - `setEntry` 的"低不覆盖高"不会再被旧值压住（陈旧矮条目可被新值覆盖）；
    /// - `applySnapshot` 的「缺失条目全扫」（`cachedHeight == nil`）会重新播种它；
    /// - `seedHeight` 的 `hasMeasuredHeight` 早退不再拦住内容已变的块。
    /// 键任一为 nil 时不 demote（信息不足，保守当作有效）。
    /// 该行**已记录**的高度条目（过期也返回：过期只影响"要不要重算"，不影响"能不能用"）。
    private func currentEntry(at index: Int) -> HeightEntry? {
        guard let entry = heightCache.entry(at: index) else { return nil }
        return HeightEntry(
            height: entry.height,
            source: entry.source == .measured ? .measured
                  : entry.source == .precalc ? .precalc : .estimated,
            key: entry.contentKey,
            provenance: entry.provenance
        )
    }

    /// 条目内容键是否已过期（= 内容变了、需要重新估算；此时旧高度仍可用）。
    private func isStaleEntry(at index: Int) -> Bool {
        heightCache.isStale(at: index, currentContentKey: contentKey(at: index))
    }

    /// 行号 → 行身份（存储层唯一的行号消费者）。
    private func rowItem(at index: Int) -> MessageListItem? { heightCache.item(at: index) }

    private func contentKey(at index: Int) -> String? {
        guard let item = rowItem(at: index) else { return nil }
        return contentKeyByItem[item]
    }

    #if DEBUG
    private func metricsTag(at index: Int) -> String? {
        guard let item = rowItem(at: index) else { return nil }
        return metricsTagByItem[item]
    }
    #endif

    private func footerHug(at index: Int) -> Bool? {
        guard let item = rowItem(at: index) else { return nil }
        return footerHugByItem[item]
    }

    /// 同步行顺序（快照变化时由 Coordinator 在 apply 之前调用）。
    public func setOrder(_ items: [MessageListItem]) {
        heightCache.setOrder(items)
    }

    /// [治本·步1] `provenance` 标明**谁产出了这个估算值**（7 个调用点各不同）。
    /// 默认 `nil` 表示"未知生产者"，诊断时回落 `source`。
    public func setEstimatedHeight(_ height: CGFloat,provenance: String? = nil,at index: Int) {
        setEntry(height, source: .estimated, provenance: provenance, at: index)
    }

    public func setPrecalcHeight(_ height: CGFloat,provenance: String? = nil,at index: Int) {
        setEntry(height, source: .precalc, provenance: provenance, at: index)
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
    private func setEntry(_ height: CGFloat, source: HeightSource,
                          provenance: String? = nil, at index: Int) -> Bool {
        let rank: (HeightSource) -> Int = { $0 == .measured ? 3 : $0 == .precalc ? 2 : 1 }
        // [2026-09-13 S15 闭环·闸门必须按"当期"条目判] 原先比的是**裸条目**
        // `currentEntry(at: index)`。于是内容已变的陈旧 `.measured`（其 `key` 与
        // `contentKey(at: index)` 不一致）会出现一个自相矛盾的组合：
        //   · `currentEntry` 认为它**已不是条目**（键不一致 ⇒ nil）；
        //   · `hasMeasuredHeight` 因此返回 false ⇒ `seedHeight` 的 measured 早退**不拦**它，
        //     播种会照常算出一个新的 `.precalc`/`.estimated`；
        //   · 但闸门这里仍按 rank 3 比较 ⇒ 新值**被静默拒绝**（调用方不看返回值，没有任何信号）。
        // 净效果：陈旧高度永久压住新内容，且 `.missing` 每轮重试、每轮失败。这正是 S15
        // 想消灭的"旧实测值永久滞留"，只是断点藏在这个闸门里。
        // 判据与 `currentEntry` **同源**：键不一致即视为无条目 ⇒ 允许覆盖。
        if let existing = currentEntry(at: index), !isStaleEntry(at: index),
           rank(existing.source) > rank(source) {
            #if DEBUG
            // [Stage 0 · M17] **静默拒绝**观测（只观测；拒绝本身是设计正确的，不予取消）。
            // 上方注释自述：「新值**被静默拒绝**（调用方不看返回值，没有任何信号）」——
            // 而 `setEntry` 的四个调用点里有**三个丢弃返回值**：
            //   `:80 setEstimatedHeight` / `:84 setPrecalcHeight` / `:418 applyDeferredHeights`
            // （只有 `:613` 检查并打 warn）。被拒时 `heightEntries` 保持旧值，而调用方以为已写入
            // ⇒ 这正是"调用方意图"与"存储实际值"失配、且**日志完全看不见**的那一类。
            // 本探针只把这条通道变成可观测：统计两个拒绝原因 + 1s 节流明细。
            Self.noteSetEntryRejected(index: index, source: source, height: height,
                                      reason: "priority", existing: existing)
            #endif
            return false
        }
        // [2026-09-09 NaN 治理·单一入口闸门] 高度必须是**有限非负值**。
        // 布局循环这里做 `attrs.frame = …; y += h` 累加，一个 inf 条目就会让
        // 后续全部 y 与 collectionViewContentSize 变成 inf；下游
        // `contentSize.height - bounds.height` 得到 inf-inf = NaN，CoreGraphics
        // 便打出成片的 "invalid numeric value (NaN) passed to CoreGraphics"。
        // [2026-11-15 流式跳动/掉帧治本] 流式行**只长不缩**。
        //
        // 真机日志（20:13，一次长回复）：
        //   [CellSizing] INVALIDATE idx=21 delta=165 est=338 → pref=503
        //   [CellSizing] INVALIDATE idx=21 delta=933 est=3718 → pref=4651
        // 每条 chunk 都把正文块重播种成一个**偏小的估算**，布局先按它框矮；
        // 紧接着 PLAF 实测出真实高度，要求长高 100–900pt ⇒ 失效重排 ⇒ 贴底滚动跟着挪
        // ⇒ 肉眼"一直跳动"，且每次都要重跑 TextKit 全量测量 ⇒ 帧率崩。
        //
        // 判据：正在流式的行，拒绝**任何比当前条目更矮**的写入（估算/预演都算）。
        // 实测变高（PLAF）照常放行 ⇒ 高度单调增长，delta 从数百 pt 降到几十 pt。
        // 流式结束后 `streamingCellRanges` 清空，本闸门自动失效，收缩恢复正常。
        //
        // ⚠️ 只拦**非实测**的收缩。PLAF 的 `.measured` 是唯一真值来源 —— 早期版本把实测收缩
        // 也拦了，后果是：某行先被兜底/估算撑大（如 200pt），实测说它其实只有 42pt 时被拒绝，
        // 于是那行永久停在虚高值上，直到流式结束才允许收缩 ⇒ 界面上就是一大片空白
        // （真机 2026-11-15 20:26 复现，日志 `[CellSizing] REJECT ... height=42`）。
        if isStreamingCell(index),
           source != .measured,
           let existing = currentEntry(at: index),
           height < existing.height {
            return false
        }
        guard height.isFinite, height >= 0 else {
            #if DEBUG
            // [Stage 0 · M17] 第二个拒绝原因（非有限/负高度）。同样只观测。
            Self.noteSetEntryRejected(index: index, source: source, height: height,
                                      reason: height.isFinite ? "negative" : "nonfinite", existing: nil)
            #endif
            return false
        }
        heightCache.set(
            height: height,
            source: source == .measured ? .measured : source == .precalc ? .precalc : .estimated,
            contentKey: contentKey(at: index),
            provenance: provenance,
            at: index
        )
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


    private var itemAttributes: [UICollectionViewLayoutAttributes] = []

    private var totalHeight: CGFloat = 0
    /// 上次上报的贴底垫高（仅用于探针去重，避免每次布局刷一条日志）
    private var lastReportedTotal: CGFloat = -1
    /// 贴底/几何专用日志（不参与诊断静默，见使用处说明）。
    private static let bottomPadLogger = AppLogger(category: "BottomPad")


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
            let key = contentKey(at: i)
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
                // [Stage 1 · R6] 主语由 `key?.prefix(2)`（裸字符串前缀）改为**类型化语义入口**
                // `ContentKeyKind.of(key)`。等价性：`of` 只做 `String(key.prefix(2))` 再查 rawValue，
                // 故 `"b:"`→.assistantBlock 等四例与原先逐字相同；而 `nil`（键缺失）与"未知前缀"
                // 都返回 nil，与原先的 `default:` 落点**完全一致**（潜在耦合不变，见该枚举注释）。
                switch MessageCollectionView.Coordinator.ContentKeyKind.of(key) {
                case .assistantBlock:
                    // [2026-09-13 残留抖动（+4pt×N）] 块级里有两种高度：**思考块 40**（`b:…:e0/:e1`）
                    // 与**其他块 36**（胶囊/文件 36~40）。先前一律给 36，于是缺条目的那些思考块
                    // 拖动期是 36、条目到位后变 40 ⇒ 每块 +4，实测 `totalH 2344 → 2394`（+50），
                    // 肉眼即"停手时自动校正一下"。**判别信息就在内容键里**：只有 thinking 块带 `:eN` 后缀。
                    h = (key?.contains(":e") ?? false) ? 40 : 36
                case .assistantHeader: h = 28     // header 是常量行
                case .assistantFooter: h = 4      // footer 空态
                case .wholeMessage:
                    // [2026-09-13 顶部抖动根因] 用户气泡。格式 `w:<msgId>:<字数>:<附件数>`，
                    // **末段是附件数**：附件异步挂载时它 0→1 会让整个内容键变化，于是新键既无条目、
                    // 也无 memo 记忆 ⇒ 先前直接落 default 的
                    // `estimatedItemHeight`(200)，而真值是 118 ⇒ 顶部整块差 82pt（肉眼=顶部抖动）。
                    // 带附件的用户气泡高度由附件主导（实测 118~185），纯文本约 44~70。
                    // ⚠️ 解析内容键末段与 `contentKey(for:)` 的格式**成对耦合**，改格式须同步改此处。
                    let parts = key?.split(separator: ":") ?? []
                    h = (Int(parts.last ?? "0") ?? 0) > 0 ? 118 : 48
                case nil:   h = estimatedItemHeight
                }
            }
            attrs.frame = CGRect(x: 0,y: y,width: width,height: h)
            itemAttributes.append(attrs)
            y += h
            // Suppress the inter-cell spacing when the NEXT
            let isLast = (i+1 == itemCount)
            let nextIsFooter = !isLast
                && MessageCollectionView.Coordinator.ContentKeyKind.of(contentKey(at: i+1)) == .assistantFooter
                && (footerHug(at: i+1) ?? true)
                && !isStreamingCell(i+1)
            //
            if !isLast,!nextIsFooter,h>0 { y += itemSpacing }
        }
        // [2026-11-15 撤回贴底] 曾把整表下移 (可见高 − 内容高) 让短内容贴底，
        // 真机 20:58 截图证明这会把空白从"下方"搬到"上方"（用户气泡离导航栏一大段），
        // 属治标反噬，已撤回。真正的异常是 contentSize 偶发远大于内容高（1584 vs 544），
        // 见下方 [GiantRow] 探针定位。
        totalHeight = y

        // [2026-11-15 空白定位] 赋值**之后**再打，且内容高度一变就打全部行。
        // 之前打在赋值前，`total` 显示的是上一轮的值，导致误判为"contentSize 虚高"。
        if abs(totalHeight - lastReportedTotal) > 1 {
            lastReportedTotal = totalHeight
            var pieces: [String] = []
            for idx in 0..<itemAttributes.count {
                let e = currentEntry(at: idx)
                pieces.append("\(idx):h=\(String(format: "%.0f", itemAttributes[idx].frame.height))"
                              + "/\(e?.source.rawValue ?? "nil")")
            }
            Self.bottomPadLogger.info(
                "[Geom] bh=\(String(format: "%.0f", cv.bounds.height)) contentH=\(String(format: "%.0f", y)) total=\(String(format: "%.0f", totalHeight)) items=\(itemCount) offY=\(String(format: "%.0f", collectionView?.contentOffset.y ?? .nan)) adjT=\(String(format: "%.0f", cv.adjustedContentInset.top)) adjB=\(String(format: "%.0f", cv.adjustedContentInset.bottom)) ‖ \(pieces.joined(separator: " "))")
        }
        #if DEBUG
        // [Stage 0 · M13] **帧重叠终审探针**（只观测，不改返回值、不改几何）。
        //
        // 动机：用户症状 1「拖动期重叠」的几何类解释此前只是**推理**被排除（§2.7.2：cell 一定裁剪、
        // `itemAttributes` 只有 `:271` 一个写入点、`prepare()` 用单调 `y += h`）。这里是**直接检测**：
        // 本函数既然是唯一的帧写入者，逐对检查相邻帧即可一次性判定"重叠是不是帧层面的"。
        // 恒不报 ⇒ 几何路径整条彻底关闭，重叠必在 cell 内部绘制或图层层面。
        // 报出 ⇒ §2.7.2 的推理有漏，须立即复核（那将是最有价值的一条数据）。
        if itemAttributes.count > 1 {
            Self.frameOverlapChecks &+= 1
            var worstOverlap: CGFloat = 0
            var worstIdx = -1
            for i in 1..<itemAttributes.count {
                let ov = itemAttributes[i-1].frame.maxY - itemAttributes[i].frame.minY
                if ov > worstOverlap { worstOverlap = ov; worstIdx = i }
            }
            if worstOverlap > 0.5 {
                Self.frameOverlapCount &+= 1
                let ovTs = CFAbsoluteTimeGetCurrent()
                if ovTs - Self.frameOverlapLastLogAt >= 1.0 {
                    Self.frameOverlapLastLogAt = ovTs
                    AppLogger.shared.warning("[Stage0][M13] ⚠️ prepare() 产出重叠帧 overlapHits=\(Self.frameOverlapCount) 最坏=\(String(format: "%.1f", worstOverlap))pt @idx=\(worstIdx) items=\(itemAttributes.count) totalH=\(String(format: "%.0f", totalHeight)) — 帧层面确实重叠（与 §2.7.2 的推理矛盾，须立即复核）", category: "ChatList.CellMetrics")
                }
            }
        }
        #endif
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
            AppLogger.shared.debug("[prepare] #\(Self.prepareCallCount) \(String(format: "%.1f", elapsed))ms items=\(itemCount) totalH=\(String(format: "%.0f", totalHeight)) cacheHits=\(self.heightCache.count)", category: "ChatList.Stall")
        }
    }
    #if DEBUG
    /// [治本·步1] 不变式「播种 ≤ 真值」的违约聚合（只观测）。
    /// key = 种子值（四舍五入到整数），value = (次数, 最坏 pref, 一条 src 样本)。
    /// **按生产者聚合**（不是按种子值）：这样"改哪一份实现"才有答案。
    /// 值 = (次数, 最坏真值, 该生产者产出的种子值集合, 来源标签)。
    private static var seedViolations: [String: (n: Int,worstPref: CGFloat,seeds: Set<Int>,src: String)] = [:]
    private static var seedViolationLastLogAt: CFAbsoluteTime = 0
    private static var seedViolationTotal = 0
    /// [第三刀前置] 固定形状行的成型构成对照（只观测）。
    private static var fixedRowSamples: [String: (orig: CGFloat,pref: CGFloat,entryH: CGFloat,producer: String)] = [:]
    private static var fixedRowLastLogAt: CFAbsoluteTime = 0
    /// [2026-09-17] 追加 `entryH` = **条目里实际写入的值**。动机：M24 首轮机显示 footer
    /// `播种18.0 / PLAF成型16.3`，而 `estimateItemHeight` 的 `.assistantFooter` 分支**返回的是 4**
    /// ⇒ 帧（`origH`）与条目（`e.height`）**不是同一个来源**。不打出 `entryH` 就无法判断
    /// "18 是谁写的"，也就无法确定该改哪一行（否则又是一次按标签改错地方）。
    static func noteFixedRowBreakdown(kind: String,orig: CGFloat,pref: CGFloat,
                                      entryH: CGFloat,producer: String) {
        fixedRowSamples[kind] = (orig,pref,entryH,producer)
        let now = CFAbsoluteTimeGetCurrent()
        guard now-fixedRowLastLogAt >= 5.0 else { return }
        fixedRowLastLogAt = now
        let captionH = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        let bodyH = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let captionScaled = FontSettings.shared.scaledMessage(captionH)
        let body = fixedRowSamples.sorted { $0.key < $1.key }.map { k,v in
            "\(k) 帧\(String(format: "%.1f", v.orig)) / 条目\(String(format: "%.1f", v.entryH)) / PLAF成型\(String(format: "%.1f", v.pref)) src=\(v.producer)"
        }.joined(separator: " | ")
        AppLogger.shared.warn("[Stage0][M24] 固定形状行成型对照 ‖ caption行高=\(String(format: "%.2f", captionH)) 缩放后=\(String(format: "%.2f", captionScaled)) caption+2=\(String(format: "%.2f", captionScaled+2)) body行高=\(String(format: "%.2f", bodyH)) ‖ \(body) — 用来判「推导式该由哪几项构成」，避免把 16.3 写成新的字面量", category: "ChatList.CellMetrics")
    }
    /// [判据修正 2] `pref ≈ 0`（PLAF 返回 0 高度）的计数：与"播种偏高""测量偏矮"是**三个**缺陷。
    private static var zeroPrefTotal = 0
    private static var zeroPrefByProducer: [String: Int] = [:]
    private static var zeroPrefLastLogAt: CFAbsoluteTime = 0
    static func noteZeroPreferredHeight(producer: String,orig: CGFloat) {
        zeroPrefTotal &+= 1
        zeroPrefByProducer[producer,default: 0] &+= 1
        let now = CFAbsoluteTimeGetCurrent()
        guard now-zeroPrefLastLogAt >= 5.0 else { return }
        zeroPrefLastLogAt = now
        let body = zeroPrefByProducer.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key) n=\($0.value)" }.joined(separator: " | ")
        AppLogger.shared.warn("[Stage0][M23] ⚠️ PLAF 返回 0 高度（会先塌成 0 再长回）：共\(zeroPrefTotal)次 ‖ \(body) — 与「播种偏高」「测量偏矮」分开记账", category: "ChatList.CellMetrics")
    }
    /// [判据修正] "声明了固定高度的类型被测量压低"的计数（与"播种偏高"是**两个**缺陷）。
    private static var authoredUnderTotal = 0
    private static var authoredUnderWorst: [String: CGFloat] = [:]
    private static var authoredUnderLastLogAt: CFAbsoluteTime = 0
    static func noteAuthoredUnderMeasurement(producer: String,declared: CGFloat,measured: CGFloat) {
        authoredUnderTotal &+= 1
        let gap = declared-measured
        if gap > (authoredUnderWorst[producer] ?? 0) { authoredUnderWorst[producer] = gap }
        let now = CFAbsoluteTimeGetCurrent()
        guard now-authoredUnderLastLogAt >= 5.0 else { return }
        authoredUnderLastLogAt = now
        let body = authoredUnderWorst.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key) 最坏低\(String(format: "%.1f", $0.value))pt" }.joined(separator: " | ")
        AppLogger.shared.warn("[Stage0][M22] ⚠️ **测量低于类型声明高度**（会裁切固定高度视图）：共\(authoredUnderTotal)次 ‖ \(body) — 与「播种偏高」是两个缺陷，分开记账", category: "ChatList.CellMetrics")
    }
    static func noteSeedViolation(seed: CGFloat,entryH: CGFloat,pref: CGFloat,producer: String) {
        var v = seedViolations[producer] ?? (0,pref,[],producer)
        v.n &+= 1
        if pref < v.worstPref { v.worstPref = pref }
        v.seeds.insert(Int(seed.rounded()))
        seedViolations[producer] = v
        seedViolationTotal &+= 1
        let now = CFAbsoluteTimeGetCurrent()
        guard now-seedViolationLastLogAt >= 5.0 else { return }
        seedViolationLastLogAt = now
        let body = seedViolations.sorted { $0.value.n > $1.value.n }.prefix(8).map { k,v in
            "\(k) 帧种子\(v.seeds.sorted())→最坏真值\(String(format: "%.1f", v.worstPref)) n=\(v.n)"
        }.joined(separator: " | ")
        AppLogger.shared.warn("[Stage0][M21] ⚠️ 播种高于真值的违约：共\(seedViolationTotal)次（**按生产者**） ‖ \(body)", category: "ChatList.CellMetrics")
    }
    #endif

    private static var prepareCallCount: Int = 0

    public override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let t0 = CACurrentMediaTime()
        guard !itemAttributes.isEmpty else { return nil }
        #if DEBUG
        // [Stage 0 · M15] **屏上帧 vs 布局帧一致性**（只观测，1s 节流）。
        //
        // 为什么需要它：M13 检查的是 `prepare()` 的产物 `itemAttributes` —— 而集合视图实际使用的帧
        // 还可能来自 **PLAF 提交路径**：`invalidationContext(forPreferredLayoutAttributes:…)` 拿的是
        // cell 自己算出的 `preferredAttributes` **副本**，其高度**不经过 `prepare()`**。
        // ⇒ `itemAttributes` 可以完全自洽（M13 读到 0 重叠），而**屏上真实帧互不一致**。
        // 也就是说：重叠可能发生在 `prepare()` 之外，而 M13 结构上看不见它。
        //
        // 本探针在集合视图**即将取用**这些帧的时刻（本方法每次布局都被调用），把
        // `cv.visibleCells` 的真实 frame 与 `itemAttributes` 逐项比对。两者一旦背离，
        // 就说明"帧自洽"与"屏上不重叠"是两回事 —— 那将同时解释症状 1 与 M13=0。
        if let cv = collectionView {
            let dvTs = CFAbsoluteTimeGetCurrent()
            if dvTs - Self.frameDivergenceLastLogAt >= 1.0 {
                Self.frameDivergenceLastLogAt = dvTs
                var diverged = 0
                var worst: CGFloat = 0
                var worstIdx = -1
                // [Stage 0 · M18] **判别 M15 的背离是「应用时序」还是「真分叉」**（只观测）。
                //
                // 动机（本会话第 11 次自纠）：M15 埋在本方法里，而本方法是**产出属性**的时刻 ——
                // 集合视图**尚未**把本轮返回的属性应用到 cell 上。因此只要本轮几何变过，
                // `cell.frame` 必然还是上一轮的 ⇒ M15 读到的"背离"结构上必然非零，
                // 与"帧模型到底有没有分叉"无关。真机日志的形状正是如此：
                //   `M15 最坏=24.0pt @idx=25 :: M16 最近一次提交 idx=25 delta=24.0`
                // 背离值**逐位等于刚刚提交的 delta**；而 `.measured` 提交**不可能被 `setEntry` 拒绝**
                //（`rank(.measured)==3` 已最高，闸门条件 `rank(existing)>rank(source)` 恒假）
                // ⇒ `heightEntries` 必已是新值 ⇒ 若 `prepare()` 已重跑，`itemAttributes` 也是新值
                // ⇒ 与 `cell.frame` 之差只可能是"本轮还没应用"，不是存储与模型的分叉。
                //
                // 判别键 = **上一轮本方法实际返回过的 frame**（`lastEmittedFrames`）：
                //   · `cell.frame ≈ lastEmitted` ⇒ 集合视图**如实采用**了我们给它的帧
                //     ⇒ 与 `itemAttributes` 的差 = 本轮尚未应用 ⇒ `lag`（非分叉）；
                //   · 两者都不等 ⇒ 屏上帧既不等于旧模型、也不等于新模型 ⇒ `fork`（真分叉）。
                // 只有 `fork > 0` 才构成 S2.12 的准入证据。
                var lag = 0
                var fork = 0
                for cell in cv.visibleCells {
                    guard let ip = cv.indexPath(for: cell), ip.item < itemAttributes.count else { continue }
                    let a = itemAttributes[ip.item].frame
                    let d = max(abs(cell.frame.minY - a.minY), abs(cell.frame.height - a.height))
                    if d > 1 {
                        diverged += 1
                        if d > worst { worst = d; worstIdx = ip.item }
                        if let prev = Self.lastEmittedFrames[ip.item] {
                            let dp = max(abs(cell.frame.minY-prev.minY), abs(cell.frame.height-prev.height))
                            if dp <= 1 { lag += 1 } else { fork += 1 }
                        } else {
                            fork += 1
                        }
                    }
                }
                if diverged > 0 {
                    Self.frameDivergenceHits &+= 1
                    // [Stage 0 · M16] 判别"提交之后 prepare() 有没有重跑"（见 invalidationContext 内说明）。
                    let ranPrepare = Self.prepareCallCount != Self.lastCommitPrepareCount
                    AppLogger.shared.warning("[Stage0][M15] ⚠️ 屏上帧与布局帧背离 divergedCells=\(diverged)/\(cv.visibleCells.count) 最坏=\(String(format: "%.1f", worst))pt @idx=\(worstIdx) scroll=\((cv.isDragging) ? "drag" : (cv.isDecelerating ? "decel" : "idle")) :: M16 最近一次提交 idx=\(Self.lastCommitIdx) delta=\(String(format: "%.1f", Self.lastCommitDelta)) preparesThen=\(Self.lastCommitPrepareCount) preparesNow=\(Self.prepareCallCount) ⇒ \(ranPrepare ? "提交后【已】重跑 prepare（背离另有原因）" : "提交后【未】重跑 prepare ⇒ itemAttributes 未跟上") :: M18 应用滞后=\(lag) 真分叉=\(fork)（分叉>0 才是 S2.12 的准入证据）", category: "ChatList.CellMetrics")
                } else {
                    Self.frameDivergenceClean &+= 1
                    // [Stage 0 · M18] **干净的读数也必须可关闭假设**。原先 `diverged==0` 时一行不打，
                    // 于是"日志里没有 M15"既可能是「真分叉=0」，也可能是「根本没采样到」，两者不可区分——
                    // 首轮机（2026-09-17 10:15）正是这种沉默：全窗口 0 条 M15，无法据此撤回 S2.12。
                    // 故每 5s 至少打一条 0 读数明细，使 `真分叉=0` 成为**正面证据**。
                    if dvTs - Self.frameDivergenceCleanLogAt >= 5.0 {
                        Self.frameDivergenceCleanLogAt = dvTs
                        AppLogger.shared.info("[Stage0][M18] 屏上帧与布局帧**一致** diverged=0/\(cv.visibleCells.count) scroll=\((cv.isDragging) ? "drag" : (cv.isDecelerating ? "decel" : "idle")) 自洽采样累计=\(Self.frameDivergenceClean) :: M18 应用滞后=0 真分叉=0", category: "ChatList.CellMetrics")
                    }
                }
            }
        }
        #endif

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

        #if DEBUG
        // [Stage 0 · M18] 记录**本轮实际返回给集合视图的帧**（下一轮据此判别
        // "应用滞后 vs 真分叉"）。只读观测：不改返回值、不改几何。
        for attrs in result { Self.lastEmittedFrames[attrs.indexPath.item] = attrs.frame }
        #endif

        return result
    }

    public override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item<itemAttributes.count else { return nil }
        return itemAttributes[indexPath.item]
    }

    /// was scrolling. Stored here (not in heightCache) so prepare() keeps
    /// using the old height → contentSize stays frozen. Applied on thaw
    private var deferredHeights: [Int: CGFloat] = [:]

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
            let old = currentEntry(at: idx)?.height ?? estimatedItemHeight
            // [2026-09-12 修复「延后即丢弃」] 闸门只在 `currentEntry(at: idx)?.source == .measured`
            // （**已有条目**）时才延后，而这里原先只在 `currentEntry(at: idx) == nil`（**没有条目**）
            // 时才应用 —— 两条件互斥 ⇒ **每一条延后项都被丢弃**：浏览期间该收缩的 cell 会一直
            // 保持旧的高帧，直到别的路径触发重排。症状就是本函数末尾那行聚合日志恒为
            // `dropped=n aboveΣ=+0.0 insideΣ=+0.0`（n 条全部被丢，没有任何位置分类被累加）。
            // 解冻时应用才是**构造上安全**的时机（这正是延后机制在等的那一刻），故改为
            // 「与现值有实质差异就应用」；`dropped` 保留，用于统计真正无差异的项。
            let cur = currentEntry(at: idx)?.height
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
                    key: String(contentKey(at: idx)?.prefix(2) ?? ""),
                    pos: pos,offset: vpTop,
                    tag: metricsTag(at: idx) ?? "")
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

    #if DEBUG
    /// [Stage 0 · M15] 屏上帧 vs 布局帧的背离计数（见 `layoutAttributesForElements` 内说明）。
    /// `Clean` 用于给出"抽查了 N 次、0 次背离"这种**可关闭假设**的证据。
    private static var frameDivergenceHits = 0
    private static var frameDivergenceClean = 0
    private static var frameDivergenceLastLogAt: CFAbsoluteTime = 0
    /// [Stage 0 · M18] 「一致」读数自身的节流时间戳（见 `diverged == 0` 分支内说明）。
    private static var frameDivergenceCleanLogAt: CFAbsoluteTime = 0
    /// [Stage 0 · M18] **上一轮 `layoutAttributesForElements` 实际返回过的帧**（见 M18 内说明）。
    /// 这是判别"应用时序 vs 真分叉"的唯一判据键：集合视图只能应用我们**给过**的帧。
    private static var lastEmittedFrames: [Int: CGRect] = [:]
    static func frameDivergenceSummary() -> String {
        "M15屏上背离=\(frameDivergenceHits)/自洽\(frameDivergenceClean)次"
    }
    #endif

    #if DEBUG
    /// [Stage 0 · M13] 帧重叠探测计数。`checks` = 检查过的 prepare() 次数（items>1 时）。
    /// 供 harness END 汇总输出，从而给出"检查了 N 次、0 次重叠"这种**可关闭假设**的证据。
    private static var frameOverlapCount = 0
    private static var frameOverlapChecks = 0
    private static var frameOverlapLastLogAt: CFAbsoluteTime = 0
    static func frameOverlapSummary() -> String {
        "M13帧重叠=\(frameOverlapCount)/检查\(frameOverlapChecks)次"
    }
    #endif

    #if DEBUG
    /// [Stage 0 · M10] 拖动期收缩绕过闸门的计数（见 `shouldInvalidateLayout` 内的说明）。
    /// 只读观测状态，不参与任何判定。
    private static var gateBypassKeyStaleCount = 0
    private static var gateBypassNoEntryCount = 0
    private static var gateBypassLastLogAt: CFAbsoluteTime = 0
    #endif

    public override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        let index = preferredAttributes.indexPath.item
        let prefH = preferredAttributes.size.height
        let origH = originalAttributes.size.height

        #if DEBUG
        // [治本·第三刀前置 2026-09-17] **固定形状行（header `h:` / footer `f:`）的成型构成对照**。
        //
        // 为什么必须先测：M21 的首名是 `种子[18,28]→真值16.3`（footer 给 18 / header 给 28）。
        // "把 18/28 改成 16" 就是 S5 反例库 #1 那条补丁；正确做法是**从视图自己用的度量推导**。
        // 但推导式里"哪几项真实参与了成型"尚未判清：`Text("replying").font(.caption)` +
        // `.padding(.top,2)` 的算术给 ≈18，而实测真值是 16.3 ⇒ **推出来的值仍高于真值**。
        // 到底是 caption 的实际行高不同、还是 padding 未计入、抑或成型另有来源 —— 需要三条并排才判得清。
        // 本探针把三者放在同一行：实测成型高 / caption 行高 / caption+2 推算值（外加种子，便于对照）。
        if let key = contentKey(at: index),key.hasPrefix("h:") || key.hasPrefix("f:"),
           let e = currentEntry(at: index),e.source != .measured,origH > 1 {
            Self.noteFixedRowBreakdown(kind: key.hasPrefix("h:") ? "h(header)" : "f(footer)",
                                       orig: origH,pref: prefH,entryH: e.height,
                                       producer: e.provenance ?? e.source.rawValue)
        }
        // [治本·步1 2026-09-17] **不变式「播种 ≤ 真值」的违约观测**（只观测）。
        //
        // 为什么需要它：流式期空白的机制是「帧偏高 ∧ 收缩被延后」。而"偏高"有两种可能：
        //   ① **播种偏高**（帧来自错误的估算）⇒ 该改播种；
        //   ② **测量偏矮**（`pref` 本身不对）⇒ 改播种就是错的方向，越改越糟。
        // 二者在旧日志里**无法区分**（`[DeferShrink]` 只有 orig/pref）。所以先把它们分开：
        // 按**种子值**（= `origH`，每个 kind 的种子值不同 ⇒ 可反推族）聚合，并同时记录
        // `pref`，从而一眼看出"是种子大了"还是"测量小了"。
        //
        // ⚠️ 已发生的教训：我一开始判定"胶囊播种 36 偏高、真值 26"，
        // 而 `ToolCapsuleView` 里写的是 `.frame(height: 36)` ⇒ **36 才是权威值，26 是测量偏矮**。
        // 若照原方案把种子改成 26，就是主动把种子压到视图声明高度之下（S5 反例库 #1 的补丁）。
        // 这枚探针就是为了让"谁对"先有数据、再动手。
        if let e = currentEntry(at: index),e.source != .measured,origH > 1,
           prefH < origH-0.5 {
            let producer = e.provenance ?? "unknown(\(e.source.rawValue))"
            if prefH <= 1 {
                // [判据修正 2026-09-17 第二次] `pref ≈ 0` = **PLAF 返回了 0 高度**，那是**另一个缺陷**
                //（cell 尚未承载内容就被问成型高度，或成型测量真的返回 0），不是"播种偏高"。
                // 首轮机它占了 32/43 = 74% 的账面，把真 offender 挤到了看不见 —— 故必须单列。
                Self.noteZeroPreferredHeight(producer: producer,orig: origH)
            } else if producer.hasPrefix("authored#") {
                // [判据修正 2026-09-17] 对"高度由视图声明"的类型，`pref` **不是真值** ——
                // 真值就是声明值本身。此时 `pref < orig` 反映的是**测量偏矮**（会把胶囊裁掉），
                // 是**另一个缺陷**，必须单列，不能混进"播种偏高"的账里（否则读数是假的）。
                Self.noteAuthoredUnderMeasurement(producer: producer,declared: origH,measured: prefH)
            } else {
                Self.noteSeedViolation(seed: origH,entryH: e.height,pref: prefH,producer: producer)
            }
        }
        #endif

        if deferSelfSizing {
            // [2026-09-12 抖动根因·闸门语义修正] 原先只把 `source == .measured` 视为「已缓存」，
            // 于是**条目源是 .estimated / .precalc 的 cell 完全不被保护** —— 而真机事故里
            // 正是这类 cell：工具胶囊的估算条目是 .estimated(36)，但布局在它们身上先用了兜底
            // `estimatedItemHeight`(200)，等 PLAF 给回真实值时就产生 200→36 的收缩，且**在手势中
            // 被放行**（`[ScrollMetrics] liveShrink … phase=decel` 19 条、各 −160.3/−164.0pt）。
            // 判据改为「**任何已有条目**都算已缓存」：延后机制的目的就是「手势期间不改几何」，
            // 与条目来源无关；解冻后由 `applyDeferredHeights` 原子应用并做 offset 锚定。
            let hasCached = currentEntry(at: index) != nil
            #if DEBUG
            // [Stage 0 · M10] **收缩闸门「有效性 vs 保护性」错位探测**（只观测，不改变任何返回值）。
            //
            // 机制：`currentEntry(at:)` 是**有效性**判据（条目键 == 当前内容键），却被 `hasCached`
            // 当作**保护性**判据用。而 `setContentKey(_:at:)` 只写 `contentKeyByIndex`、
            // **不同步** `currentEntry(at: index).key`；它的两个调用点之一是
            // `MessageCollectionView.swift:444`（`configureCell` 路径）。于是：
            //   拖动 → 新 cell 进视口 / 流式块内容变化 → configureCell → setContentKey(新键)
            //   → heightEntries[i] 仍是旧键 → currentEntry 返回 nil → hasCached=false
            //   → 本闸门整块被跳过 → 返回 mustInvalidate → **拖动期真实收缩**（正是它要防的事）。
            // 上方 :395-401 的注释显示该闸门曾因同类事故被加宽过一次（`.measured`-only → 任何条目），
            // 但那次加宽**救不了 `currentEntry` 自己返回 nil 的情形** ⇒ 修正不完整。
            //
            // `keyStale` = 有条目但键过期（闸门本该保护却跳过）；
            // `noEntry`  = 连条目都没有（`prepare()` 不写条目，只有 4 个 setEntry 写入口）。
            if !hasCached, prefH < origH - 0.5 {
                if currentEntry(at: index) != nil {
                    Self.gateBypassKeyStaleCount &+= 1
                } else {
                    Self.gateBypassNoEntryCount &+= 1
                }
                let nowTs = CFAbsoluteTimeGetCurrent()
                if nowTs - Self.gateBypassLastLogAt >= 1.0 {
                    Self.gateBypassLastLogAt = nowTs
                    AppLogger.shared.warning(
                        "[Stage0][M10] 拖动期收缩绕过闸门 keyStale=\(Self.gateBypassKeyStaleCount) noEntry=\(Self.gateBypassNoEntryCount) idx=\(index) orig=\(String(format: "%.1f", origH))→pref=\(String(format: "%.1f", prefH)) delta=\(String(format: "%+.1f", prefH-origH)) key=\(contentKey(at: index) ?? "nil") entryKey=\(currentEntry(at: index)?.key ?? "nil") — hasCached=false 致 deferSelfSizing 保护被跳过",
                        category: "ChatList.CellMetrics")
                }
            }
            #endif
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
                                "[DeferShrink] idx=\(index) orig=\(String(format: "%.1f", origH))→pref=\(String(format: "%.1f", prefH)) delta=\(String(format: "%+.1f", prefH-origH)) pos=\(pos) src=\(currentEntry(at: index)?.source.rawValue ?? "?") key=\(contentKey(at: index) ?? "??")",
                                category: "ChatList.Blank")
                        }
                    }
                    return false
                }
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
            AppLogger.shared.info("[CellSizing] INVALIDATE idx=\(index) delta=\(String(format: "%.0f", delta)) est=\(String(format: "%.0f", origH)) → pref=\(String(format: "%.0f", prefH)) cached=\(currentEntry(at: index)?.source == .measured) key=\(contentKey(at: index) ?? "??")", category: "ChatList.CellMetrics")
        }
        return mustInvalidate
    }

    #if DEBUG
    /// [Stage 0 · M17] `setEntry` 静默拒绝的计数与节流（见 `setEntry` 内说明）。
    /// 只读观测状态，不参与任何判定。
    private static var setEntryRejectedPriority = 0
    private static var setEntryRejectedInvalid = 0
    private static var setEntryRejectedLastLogAt: CFAbsoluteTime = 0
    private static func noteSetEntryRejected(index: Int,source: HeightSource,height: CGFloat,
                                            reason: String,existing: HeightEntry?) {
        if reason == "priority" { setEntryRejectedPriority &+= 1 } else { setEntryRejectedInvalid &+= 1 }
        let ts = CFAbsoluteTimeGetCurrent()
        guard ts - setEntryRejectedLastLogAt >= 1.0 else { return }
        setEntryRejectedLastLogAt = ts
        let have = existing.map { "\($0.source.rawValue)@\(String(format: "%.1f", $0.height))" } ?? "nil"
        AppLogger.shared.warning("[Stage0][M17] setEntry 静默拒绝 reason=\(reason) idx=\(index) want=\(source.rawValue)@\(String(format: "%.1f", height)) have=\(have) 累计priority=\(setEntryRejectedPriority) invalid=\(setEntryRejectedInvalid) — 被拒时 heightEntries 保持旧值，而三个调用点（setEstimatedHeight/setPrecalcHeight/applyDeferredHeights）丢弃返回值、以为已写入", category: "ChatList.CellMetrics")
    }

    /// [Stage 0 · M16] 「提交之后 `prepare()` 有没有重跑」的判别状态（见 `invalidationContext` 与
    /// `layoutAttributesForElements` 内的说明）。**判别键是现成的 `prepareCallCount`** ——
    /// 满足 §2.9.7 立下的纪律：跨日志行建因果链必须有共同关联键，此处键 = 索引 + prepare 次数。
    private static var lastCommitIdx = -1
    private static var lastCommitDelta: CGFloat = 0
    private static var lastCommitPrepareCount = 0
    #endif

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

        // [Stage 1 · §6.3 A16] 原 `let estimateSrc = …` 声明在此处（**#if DEBUG 之外**），
        // 而它唯一的消费者是下方 `#if DEBUG` 里的 `ScrollMetricsRecorder.record(src:)`
        // ⇒ Release 构建里它是一次**纯浪费**的字典查表 + 字符串拼接。已随其消费者移入 `#if DEBUG`。
        #if DEBUG
        // [Stage 0 · M16] 记录"这次提交"的时刻（用 `prepareCallCount` 当时间戳）。
        // 与 M15 的背离检测配对，用来判定：**提交之后 `prepare()` 到底有没有重跑**。
        //   · 若背离发生时 `prepareCallCount == lastCommitPrepareCount` ⇒ 提交后**没跑过** prepare
        //     ⇒ `itemAttributes` 仍是旧的 ⇒ S2.12 的修法是"提交后强制同步/重跑"；
        //   · 若已跑过而仍背离 ⇒ 说明 `prepare()` 读了 `heightEntries` 却得出不同结果
        //     ⇒ 修法转向"检查 setEntry 是否被优先级闸门拒绝"。
        // 两条分支的改法完全不同，故必须先判别再动手。
        Self.lastCommitIdx = index
        Self.lastCommitDelta = delta
        Self.lastCommitPrepareCount = Self.prepareCallCount
        #endif

        // [NegMeasure 2026-09-10] 与 SelfSizingCell 的负测量闸门配对：PLAF 返回的
        // preferred 高度必须有限且非负才允许写 .measured。9-09 的 NaN 闸门只盖住了
        // setEntry 三个写入口，这里是**第四写入口**（直接字典赋值），曾放进过 -40
        // （SwiftUI hosting 损坏测量）→ 负高度回流布局 → ViewGraph 二次损坏崩溃。
        // [2026-09-12 写入口收敛] 写入统一走 `setEntry`（优先级 + 有限非负闸门单一入口），
        // 不再直接对字典赋值 —— 此处曾是绕过闸门的「第四写入口」，9-09 的 -40 负高度
        // （SwiftUI hosting 损坏测量）就是从这里回流进布局的。
        if !setEntry(newH, source: .measured, at: index) {
            // 两种拒绝原因要分开报，否则日志会把"流式期拒绝收缩"误标成"负高度"。
            let reason: String
            if !newH.isFinite || newH < 0 {
                reason = "nonfinite/negative"
            } else if isStreamingCell(index) {
                reason = "streaming-shrink"
            } else {
                reason = "rank-guard"
            }
            AppLogger.shared.warning(
                "[CellSizing] REJECT \(reason) preferred height=\(String(format: "%.0f", newH)) idx=\(index)（保留原条目）",
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
            // [Stage 1 · A16] `estimateSrc` 只服务本行 ⇒ 声明也放在本 `#if DEBUG` 内。
            let estimateSrc = currentEntry(at: index).map { $0.source.rawValue + "!" } ?? "def"
            ScrollMetricsRecorder.shared.record(
                kind: "inv", idx: index, a: oldH, b: newH,
                key: contentKey(at: index) ?? "",
                src: estimateSrc,pos: pos,offset: vpTop,note: phase,
                tag: metricsTag(at: index) ?? "")
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
                // [Fix 2026-09-14 「内容往上顶、盖住上方工具指示器」] **删掉视口内 cell 的 +delta 补偿**。
                // 真机描述（TopFlow）：拖动正在流式的消息时，「思考指示器停在原地，而内容往上顶、
                // 文字冲到工具指示器上面」；而**正确形态是"横线处锚定、向下展开"**。
                // 原因：`contentOffsetAdjustment = +delta` 的语义是"把可见内容**整体上移** delta"。
                // 而**视口内**的 cell 变高时它的**顶边并没有动** —— 下方内容自然被推下就够了；
                // 此时再补 `+delta` ⇒ 可见内容被上移 ⇒ 正好盖住它上方的块（chip）。
                // ⇒ 补偿只应服务于「**顶边在视口之外**（above）」这一类：那时不补才会看到跳动。
                // ⚠️ 保留下面这条：贴底（autoScrolling）时让流式块跟随，属既有"钉底"语义。
                if isStreamingCell(index) && isAutoScrollPinning && delta>0 {
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
        // [P1-10] 删除"index >= 最后一个区间起点就算流式"的短路：它把最后一段之后的所有行
        // 都判成流式，导致这些行的非实测收缩被"只长不缩"闸门永久拒绝（footer 回落时留空白）。
        // 区间本身已是精确的 start..<end。
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
        // 只删这一行的身份条目；行号本身不再被存储，所以不存在"错位"。
        heightCache.invalidate(at: index)
        if memo == .withMemo, let key = contentKey(at: index) {
            // 连带剔除该内容键的进程级实测 memo（原 `invalidateHeight` 语义）。
            invalidateMemo(forKey: key)
        }
    }

    /// 该索引**当前记录**的高度（来源不限：measured / precalc / estimated）。
    ///
    /// 全库唯一入口：此前另有 `precalcHeight(at:)` 与本方法逐字相同（纯重复），
    /// 已删除，其唯一调用点统一到本方法。**按来源分档**请用 `hasMeasuredHeight` /
    /// `hasPrecalcHeight`。
    public func cachedHeight(at index: Int) -> CGFloat? {
        // 走 currentEntry：**过期条目仍然返回高度**（2026-11-15 起）。
        // 这样流式/内容变化时不会先塌回兜底常量；是否重新播种由 `hasMeasuredHeight`
        // 与 `isStaleEntry` 判定，不再依赖 `cachedHeight == nil`。
        currentEntry(at: index)?.height
    }

    public func hasPrecalcHeight(at index: Int) -> Bool {
        currentEntry(at: index)?.source == .precalc && !isStaleEntry(at: index)
    }

    /// 该索引是否已有「实测」高度（source == .measured）。
    /// 合并字典后 cachedHeight 对任意来源条目都返回值，
    /// 旧三字典时代「仅实测高度才挡住估算/预演」的语义分界由本访问器承接：
    /// 种子循环、configureCell 与 prefetch 兜底必须用它做守卫——否则流式
    /// chunk 的逐次重播种（估高随内容增长刷新）会被首帧估算永久冻结，
    /// 流式 cell 停在首帧高度，正文与下方工具卡/思考块重叠（2026-09-05 回归）。
    public func hasMeasuredHeight(at index: Int) -> Bool {
        // 判据 = 「来源是实测」且「内容键未过期」。过期条目**仍有高度但不算实测**，
        // 于是 `seedHeight` 的 `guard !hasMeasuredHeight` 会放行，带当前内容键重新播种。
        // [2026-09-13] 此处原先写死行号 `+Snapshot.swift:579`，已因搬移失效；跨文件引用一律用
        // 符号名而非行号 —— 行号引用正是这些注释反复过期的根因。
        currentEntry(at: index)?.source == .measured && !isStaleEntry(at: index)
    }

    // MARK: - Content-keyed real-height memo

    public func setContentKey(_ key: String,at index: Int) {
        guard let item = rowItem(at: index) else { return }
        contentKeyByItem[item] = key
    }

    /// Per-footer spacing policy, decided by the Coordinator
    public func setFooterHug(_ hug: Bool,at index: Int) {
        guard let item = rowItem(at: index) else { return }
        footerHugByItem[item] = hug
    }

    #if DEBUG
    /// index → stable content-hash tag, so layout-
    private var metricsTagByItem: [MessageListItem: String] = [:]
    public func setMetricsTag(_ tag: String,at index: Int) {
        guard let item = rowItem(at: index) else { return }
        metricsTagByItem[item] = tag
    }
    #endif

    /// 进程级存储（方案 C）——跨 Layout 实例、跨会话存活。
    /// [缓存观测 2026-09-10] TopFlow要求 memo 读写全量可见于日志：STORE/MISS 全打
    /// （每 key 每次播种/配置各一次，量可控），HIT 同 key 1s 节流。
    private static let memoLogger = AppLogger(category: "RenderCache")
    private nonisolated(unsafe) static var memoHitLogAt: [String: CFAbsoluteTime] = [:]

    /// [Stage 1 · R2] 两个查询变体合一。证明见计划 §6.2.1：原 `peekMeasuredHeight` 与
    /// `measuredHeight` 对**所有输入返回相同值**，差异仅在 `logging == true` 时打
    /// `[MEMO] MISS`/`[MEMO] HIT` 并推进 `memoHitLogAt` 节流表。
    ///
    /// ⚠️ `logging == false` 分支**不写任何状态、不构造任何插值字符串**——这**不是**可有可无的
    /// 优化：`measuredHeight` 原实现除日志外还有副作用（写 `memoHitLogAt[key]`），且它的
    /// `\(…)` 插值在**调用点**就已付出（`RenderCache` 虽在 quietInfoCategories 里，但那只短路了
    /// `formatLine`，省不掉插值）。而"省掉这份插值"正是 `peekMeasuredHeight` 存在的理由——
    /// `prepare()` 的兜底链每次布局都可能走到，用带日志的版本会把 `[MEMO] MISS` 刷成海啸。
    private func memoHeight(forKey key: String,width: CGFloat,logging: Bool) -> CGFloat? {
        os_unfair_lock_lock(&Self._memoLock)
        let entry = Self._sharedMeasuredHeights[key]
        os_unfair_lock_unlock(&Self._memoLock)
        guard let entry,abs(entry.width-width)<1 else {
            if logging {
                Self.memoLogger.info("[MEMO] MISS key=\(key) w=\(String(format: "%.0f", width))")
            }
            return nil
        }
        if logging {
            let now = CFAbsoluteTimeGetCurrent()
            if Self.memoHitLogAt[key].map({ now-$0 >= 1.0 }) ?? true {
                Self.memoHitLogAt[key] = now
                Self.memoLogger.info("[MEMO] HIT key=\(key) h=\(String(format: "%.0f", entry.height))")
            }
        }
        return entry.height
    }

    /// [2026-09-13] **静默版** memo 查询（`logging: false`）。
    public func peekMeasuredHeight(forKey key: String,width: CGFloat) -> CGFloat? {
        memoHeight(forKey: key,width: width,logging: false)
    }

    public func measuredHeight(forKey key: String,width: CGFloat) -> CGFloat? {
        memoHeight(forKey: key,width: width,logging: true)
    }

    /// Record a real height a cell just
    public func recordMeasuredHeight(forKey key: String,height: CGFloat,boundsWidth: CGFloat) {
        guard height >= 4,boundsWidth>1 else { return }
        // NEVER memoize footer heights. The footer's
        guard MessageCollectionView.Coordinator.ContentKeyKind.of(key) != .assistantFooter else { return }
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
        heightCache.clear(keepingContent: keepingSharedMemo)
        // [2026-09-12] 内容键记忆表随条目一起清：它的语义是"上次布局真实用到的高度"，
        // 字体变更/会话切换后该口径失效（memo 的 contentKey 不含字体指纹，同理）。
        // 注：原 `lastHeightByKey.removeAll()` 已随该死机制一并删除（2026-09-13）。
        if !keepingSharedMemo { Self.clearSharedMemo() }
        contentKeyByItem.removeAll()
        footerHugByItem.removeAll()
        #if DEBUG
        metricsTagByItem.removeAll()
        #endif
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
        // 宽度变了：身份条目与内容键 memo 都要重算（memo 键含宽度，天然不命中）。
        heightCache.clear(keepingContent: false)
        MessageCollectionView.Coordinator.clearUserBubbleMemo()
    }

    public var debugCachedHeightCount: Int { heightCache.count }
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
    /// 哨兵最长有效期（秒）。见 `refreshFromSentinel` 的「可关闭化」说明。
    /// [降噪 2026-09-17] **72h → 2h**：真机实测这个开关被遗留了 25 小时（`age=25h` < 72h ⇒
    /// 一直"合法地"开着），期间 `[PLAF]`/`[PLAF-SET]` 按 cell×pass 打点，单轮 1864 行（占日志 30%）。
    /// 72h 的调试开关**等于没有过期机制**。诊断窗按"一次会话"计，2h 足够；要更久就重新放一次哨兵
    /// （`copy to` 会刷新 mtime，语义即"再续 2 小时"）。
    static let sentinelTTL: TimeInterval = 2 * 3600

    /// [2026-09-14 可关闭化] 实测发现 **`devicectl` 没有删除文件的能力**（只有 `copy to` / `copy from`）
    /// —— 于是"存在即开启"的判据意味着**一旦放上去就关不掉**，只能靠重装 App。
    /// 而它 gate 的 `[PLAF]`/`[PLAF-SET]`/`[JITTER]` 是高度热路径探针（实测占单日日志 1.1k 行），
    /// 忘掉一次就把日志长期放大 —— 与"减少日志"直接冲突。故补两条关闭途径：
    ///   ① **内容写 `off`**：`devicectl copy to` 覆盖同一路径即可关（不需要删除）；
    ///   ② **自动过期**（`sentinelTTL`，默认 72h）：重新 `copy to` 一次即刷新有效期。
    /// 日志里新增 `why=` 字段说明本次为何开/关，避免"到底哪条判据生效"再次要靠猜。
    func refreshFromSentinel() {
        let sentinel = FileSystemManager.shared.miniClawRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(".scroll-metrics-on")
        let fm = FileManager.default
        var on = fm.fileExists(atPath: sentinel.path)
        var why = on ? "present" : "absent"
        if on {
            let mtime = (try? fm.attributesOfItem(atPath: sentinel.path))?[.modificationDate] as? Date
            let age = Date().timeIntervalSince(mtime ?? .distantPast)
            let cmd = ((try? String(contentsOf: sentinel,encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if cmd == "off" {
                on = false
                why = "content=off"
            } else if age > Self.sentinelTTL {
                on = false
                why = "EXPIRED age=\(Int(age/3600))h>\(Int(Self.sentinelTTL/3600))h"
            } else {
                why = "age=\(Int(age/3600))h\(cmd.isEmpty ? "" : " content=\(cmd)")"
            }
        }
        // [2026-09-12] 每次调用都留证据（相位变化很少，一次会话几行）。原先只在状态变化时打，
        // 于是「文件没找到」与「函数没被调用」两种情况都表现为**没有任何日志**，无法区分 ——
        // 这正是上次导出拿不到数据却查不出原因的地方。这里把 on / isEnabled / 判定理由 /
        // 解析出的路径全部打出，一眼可对照文件到底该放哪。
        // [降噪修正 2026-09-17] 原先本行在 `setEnabled` **之前**打印 ⇒ 真机出现
        // `哨兵 on=1 isEnabled=0` 这种自相矛盾的行（读的是**赋值前**的旧值）。
        // 改为先应用再打印，且**只在状态真的变化时**才打（本行不需要每次调用都留证据：
        // `ensureEnabledChecked` 保证每进程只跑一次，而"没跑"与"没找到"已由本行的存在本身区分）。
        if on != isEnabled {
            setEnabled(on)
            AppLogger.shared.info(
                "[ScrollMetrics] 哨兵 on=\(on ? 1 : 0) → isEnabled=\(isEnabled ? 1 : 0) why=\(why) root=\(FileSystemManager.shared.miniClawRoot.path)",
                category: "ChatList.CellMetrics")
        }
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
