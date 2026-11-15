import CoreGraphics

/// 会话列表高度缓存：**按行身份存，不按行号存**。
///
/// 为什么重写：旧实现是 `[Int: HeightEntry]`（行号 → 高度），行号在插入/删除后会整体错位，
/// 于是每次快照变化都要 `remapHeights(oldIds:newIds:)` 把旧行号映射到新行号。映射是靠
/// `oldIndexByItem[item]` 查的，查不到就 `continue` 跳过 —— **那一次跳过就是一条高度条目丢失**，
/// 布局随即落到兜底常量（块 36/44、未知 200），兜底与真值之间的差额就是用户看到的"间距异常"。
///
/// 新实现把"行号"彻底移出存储层：
/// - 主存储 `byItem`：`MessageListItem` 是稳定身份（messageId + blockId），插入删除天然免疫；
/// - `order` 只用于把"调用方给的行号"翻译成身份，是一次 O(1) 查表，**不参与存储**。
/// - 跨会话复用交给布局的进程级 memo（按 contentKey + 宽度），本类不重复存一份。
///
/// 三条不变式（重写的验收标准）：
/// I1 任何写入都挂在身份上，行号变化不会丢条目；
/// I2 `height(at:)` 在有条目时**永不**返回 nil 给"曾经量过的同一内容"（内容键命中即返回）；
/// I3 内容变了靠内容键不匹配自然失效，不需要外部调用 invalidate。
final class MessageHeightCache {

    struct Entry {
        var height: CGFloat
        var source: Source
        /// 写入时的内容键；与当前内容键不一致 ⇒ 视为过期（内容变了）
        var contentKey: String?
        /// 生产者身份（`est.footer` / `precalc.memo` / `precalc.ct` …）。
        /// 只用于诊断归因，不参与任何判定 —— 但必须一路带到底，
        /// 否则 M17/M21/M24 三套探针会退化成 "unknown"，等于把归因能力删了。
        var provenance: String?
    }

    enum Source: String, Comparable {
        case estimated, precalc, measured
        private var rank: Int {
            switch self {
            case .estimated: return 1
            case .precalc: return 2
            case .measured: return 3
            }
        }
        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rank < rhs.rank }
    }

    /// 行顺序（由 Coordinator 在每次快照前同步）。只用于行号 ↔ 身份翻译。
    private(set) var order: [MessageListItem] = []
    /// 身份 → 条目
    private var byItem: [MessageListItem: Entry] = [:]

    // MARK: - 顺序

    func setOrder(_ items: [MessageListItem]) {
        order = items
    }

    func item(at index: Int) -> MessageListItem? {
        guard index >= 0, index < order.count else { return nil }
        return order[index]
    }

    // MARK: - 读

    /// 该行的高度：**只要有记录就返回**，即使内容已变（`isStale` 另行查询）。
    ///
    /// 为什么不返回 nil：返回 nil 会让 `prepare()` 掉到兜底常量（块 36/思考 40/未知 200），
    /// 而"旧高度"对同一行的误差远小于常量（一段文字多两行，旧值最多差几十 pt；
    /// 常量可能差 160pt）。内容变了要靠**重播种 + 实测**修正，不能靠"消失"。
    func height(at index: Int) -> CGFloat? {
        guard let item = item(at: index) else { return nil }
        return byItem[item]?.height
    }

    /// 内容键是否已与条目记录的不一致（= 需要重新估算，但不该丢弃高度）。
    func isStale(at index: Int, currentContentKey: String?) -> Bool {
        guard let item = item(at: index), let entry = byItem[item] else { return false }
        guard let stored = entry.contentKey, let current = currentContentKey else { return false }
        return stored != current
    }

    /// 一次取出完整条目（height + source + contentKey），供布局层直接用。
    /// 内容过期不影响返回，过期与否请查 `isStale(at:currentContentKey:)`。
    func entry(at index: Int) -> Entry? {
        guard let item = item(at: index) else { return nil }
        return byItem[item]
    }

    /// 条目数量（诊断用）。
    var count: Int { byItem.count }

    /// 来源（用于"实测算不算数"的判定；过期判断请配合 `isStale`）。
    func source(at index: Int) -> Source? {
        guard let item = item(at: index) else { return nil }
        return byItem[item]?.source
    }

    // MARK: - 写

    /// 写入一行的高度。低优先级不覆盖高优先级（实测 > 预计算 > 估算），
    /// 但**过期条目不算数**（内容键不一致 ⇒ 允许覆盖）。
    @discardableResult
    func set(
        height: CGFloat,
        source: Source,
        contentKey: String?,
        provenance: String? = nil,
        at index: Int
    ) -> Bool {
        guard height.isFinite, height >= 0 else { return false }
        guard let item = item(at: index) else { return false }
        if let existing = byItem[item], !isStale(existing, current: contentKey),
           existing.source > source {
            return false
        }
        byItem[item] = Entry(height: height, source: source, contentKey: contentKey, provenance: provenance)
        return true
    }

    // MARK: - 失效

    /// 失效该行：**保留高度，降级来源**。
    ///
    /// 旧实现是 `removeValue`，于是"失效了但没人重新播种"的路径（附件通知、思考折叠、
    /// 字体变更清表、前台回写…）会在下一帧让该行落到兜底常量 —— 这就是间距异常的来源之一。
    /// 降级语义：高度仍可用（不跳变），但 `source` 降为 estimated ⇒ 任何新估算/实测都能覆盖，
    /// 且 `seedHeight` 的 `hasMeasuredHeight` 早退不再拦住重新播种。
    func invalidate(at index: Int) {
        guard let item = item(at: index), var entry = byItem[item] else { return }
        entry.source = .estimated
        entry.contentKey = nil
        byItem[item] = entry
    }

    /// 全清（切换会话、字体变更）。`keepingContent` = true 时保留跨会话 memo。
    func clear(keepingContent: Bool) {
        // 跨会话复用由布局的进程级 memo 负责，这里只清本实例。
        _ = keepingContent
        byItem.removeAll(keepingCapacity: true)
    }

    // MARK: - 内部

    private func isStale(_ entry: Entry, current: String?) -> Bool {
        guard let stored = entry.contentKey, let current else { return false }
        return stored != current
    }

}
