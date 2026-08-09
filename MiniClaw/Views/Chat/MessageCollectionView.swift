import SwiftUI
import UIKit

// MARK: - 会话消息列表的 UICollectionView 容器（2026-08-09 重构）

/// diffable 列表项：banner（未配置模型提示）/ 会话消息 / 排队气泡。
/// 消息级 cell：每条消息一个 cell（UIHostingConfiguration 承载 MessageBubbleView），
/// 由 UICollectionView 虚拟化 —— 长会话只实例化可见区，首帧 O(可见) 而非 O(全部)。
enum MessageListSection: Hashable {
    case main
}

enum MessageListItem: Hashable {
    case banner
    /// 展开指纹进 item 身份（2026-08-09 定稿）：展开/折叠 → diffable apply 重新
    /// 配置该 cell（渲染及时）。此前「item 稳定 + reloadItems」配置后内容渲染延迟
    /// （真机实测要触摸才出现）；「手动 applyContent」不触发测量协议。
    case message(UUID, String)
    case pending(UUID)
    /// 块级拆分（2026-08-09）：非流式智能体消息展开为 header + block* + footer。
    /// block 带展开指纹：思考/工具块展开/折叠 → diffable 只重配该块 cell（局部性）。
    case header(UUID)
    case block(UUID, Int, String)
    case footer(UUID)
}

/// @unchecked Sendable 盒子：UIHostingConfiguration 的 content 闭包要求 @Sendable，
/// 而 MessageBubbleView 工厂闭包捕获 ChatView（非 Sendable）——盒子隔离，运行时全在主线程。
final class BubbleFactoryBox: @unchecked Sendable {
    // 普通闭包类型（非 @MainActor 标注）：@MainActor 函数类型在 Swift 6 隐式 @Sendable，
    // 会拒绝捕获 ChatView 的非 Sendable 闭包。运行时调用点均在主线程。
    let make: (ChatMessage) -> MessageBubbleView
    init(_ make: @escaping (ChatMessage) -> MessageBubbleView) { self.make = make }
}

final class PendingFactoryBox: @unchecked Sendable {
    let make: (PendingUserMessage) -> PendingMessageBubble
    init(_ make: @escaping (PendingUserMessage) -> PendingMessageBubble) { self.make = make }
}

/// 消息列表容器（替代 SwiftUI ScrollView+VStack 全量渲染）。
/// - 数据驱动：items 变化时 diffable 只重配变化的 cell（流式消息在 cell 内订阅 runtime 自刷新，
///   不触发 snapshot，避免每帧全列表 diff）。
/// - 滚动跟随：外部通过 scrollSignal（shouldAutoFollow 守卫后递增）触发 scrollToBottom；
///   用户拖动经 onUserDrag 通知外部关闭自动跟随。
struct MessageCollectionView: UIViewRepresentable {
    let items: [MessageListItem]
    let scrollSignal: Int
    let scrollToMessageID: UUID?
    /// 流式有效内容长度（2026-08-09 修复 P0）：key 纳入 runtime.streamingContent 长度，
    /// 流式期间高度 key 每帧变化 → 不命中旧缓存 → self-sizing 跟随新内容。
    let streamingLengths: [UUID: Int]
    /// 强制重配信号（2026-08-09 修复 P1）：恢复路径重建 runtime 后递增，
    /// 即使 snapshot 相同也强制 reload，让 cell 拿到新 runtime 引用。
    let reloadToken: Int
    let messages: [ChatMessage]
    let pending: [PendingUserMessage]
    /// 受控展开状态（2026-08-09）：进 cell 高度缓存 key，展开/折叠触发重配重测。
    let expandedReasoningKeys: Set<String>
    let expandedToolIDs: Set<UUID>
    let expandedErrorIDs: Set<UUID>
    /// 块级拆分：消息 id → 穿插段数组（ChatView 缓存传入，避免重复切分）
    let segments: [UUID: [AssistantSegment]]
    /// cell 垂直间距：块级模式下块组内部需要 8pt 呼吸（与消息级 VStack spacing 一致）；
    /// 消息级模式保持 0（cell 自带 vertical padding，间距不变）。
    var itemSpacing: CGFloat = 0
    /// 键盘高度（P15 沉浸：列表延伸到屏幕底后，键盘弹出时用它把最后内容顶到键盘上方）
    var keyboardInset: CGFloat = 0
    /// 悬浮输入栏总高(P18):自动贴底时最后消息锚到输入框上缘,不被输入框遮挡
    var bottomAnchorInset: CGFloat = 0
    @MainActor let makeBubble: (ChatMessage) -> MessageBubbleView
    @MainActor let makePending: (PendingUserMessage) -> PendingMessageBubble
    @MainActor let makeHeader: (ChatMessage) -> AnyView
    @MainActor let makeBlock: (ChatMessage, AssistantSegment) -> AnyView
    @MainActor let makeFooter: (ChatMessage) -> AnyView
    @MainActor let bannerView: AnyView
    @MainActor let onUserDrag: () -> Void
    /// 用户手动滚动到接近底部（2026-08-09：拖回底部 = 重新钉住，恢复自动跟随）。
    @MainActor let onNearBottom: (() -> Void)?
    /// 贴底状态双向回调（开源参考实现对齐 2026-08-09：浮动「回到底部」按钮显隐用）
    @MainActor let onNearBottomChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        // 自定义布局（2026-08-09 重构）：全量同步布局，高度 3 层解析
        // （实测缓存 → 预置 seed → 默认估计），不依赖 flow layout 的逐 cell self-sizing 布局
        // —— 那是「进入会话弹一下/展开思考弹上」的根因：复用 cell 测量旧内容 → 高度缓存
        // 被污染 → contentSize 突变 → offset 被 UIKit clamp/重置。
        let layout = MessageListLayout()
        layout.itemSpacing = itemSpacing
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        // 开源参考实现对齐：禁用 prefetch——prefetch 会在主线程同步测量离屏 cell
        // （PLAF→systemLayoutSizeFitting ~44ms/个）并写 heightCache → contentSize 突变
        // → offset 被 UIKit clamp，滚动开头/中途跳动；我们已有全量 premeasure，纯属多余。
        cv.isPrefetchingEnabled = false
        cv.keyboardDismissMode = .interactive
        cv.alwaysBounceVertical = true
        // P22:显式接管 inset——.automatic 会把 home indicator 安全区(34pt)自动并入
        // adjustedContentInset,与贴底锚点公式冲突(日志 decelEnd = maxY+38 证实)。
        // .never 后 adjustedInset = contentInset,完全由我们控制。
        cv.contentInsetAdjustmentBehavior = .never
        // 诊断日志（2026-08-09 左半边/长拉问题排查）：首帧容器宽
        AppLogger.shared.info("[List] makeUIView: frame=" + cv.bounds.debugDescription + " v=P12(同步预测量+失效重测)", category: "List")
        cv.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        cv.delegate = context.coordinator
        context.coordinator.setup(cv: cv, bubbleBox: BubbleFactoryBox(makeBubble), pendingBox: PendingFactoryBox(makePending), blockBox: BlockFactoryBox(makeHeader, makeBlock, makeFooter), bannerView: bannerView, onUserDrag: onUserDrag, onNearBottom: onNearBottom, onNearBottomChanged: onNearBottomChanged)
        return cv
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        context.coordinator.update(bubbleBox: BubbleFactoryBox(makeBubble), pendingBox: PendingFactoryBox(makePending), blockBox: BlockFactoryBox(makeHeader, makeBlock, makeFooter), bannerView: bannerView, onUserDrag: onUserDrag, onNearBottom: onNearBottom, onNearBottomChanged: onNearBottomChanged)
        context.coordinator.cache(messages: messages, pending: pending, streamingLengths: streamingLengths, segments: segments,
                                  expandedReasoningKeys: expandedReasoningKeys, expandedToolIDs: expandedToolIDs, expandedErrorIDs: expandedErrorIDs)
        // P15：列表延伸到底部后，键盘弹出时底部会被遮住——动态 inset 把最后内容顶到键盘上方
        // P22:contentInset.bottom = 输入框顶边到屏幕底的实测值 → 滚动到底即
        // 「内容底边贴输入框顶边」(adjustedInset = contentInset,.never 后无叠加)。
        // bottomAnchorInset 由 GeometryReader 实测,键盘弹出输入框上移时自动增大。
        uiView.contentInset.bottom = bottomAnchorInset
        context.coordinator.bottomAnchorInset = bottomAnchorInset
        context.coordinator.apply(items: items, scrollSignal: scrollSignal, scrollToMessageID: scrollToMessageID, reloadToken: reloadToken)
        AppLogger.shared.info("[List] updateUIView items=" + String(items.count)
            + " sig=" + String(scrollSignal) + " messages=" + String(messages.count)
            + " streaming=" + String(streamingLengths.count), category: "List")
    }

    /// 自定义布局（2026-08-09 重构）：全量同步布局，高度 3 层解析
    /// （实测缓存 → 预置 seed → 默认估计），布局结果不依赖逐 cell self-sizing——
    /// self-sizing 只负责「实测回报」，由 shouldInvalidateLayout 门控是否采用。
    ///
    /// 设计目标（根因修复「进入会话弹一下 / 展开思考弹上 / 滚动乱跳」）：
    /// - 高度来源单一且稳定：实测高度按内容 key 记忆，复用/重入免测量（不再有
    ///   「复用 cell 测量旧内容 → 缓存被污染 → contentSize 突变」）。
    /// - 滚动位置由 contentSize KVO 按模式管理（钉底贴底 / 浏览保持），
    ///   不再依赖 UIKit 对 self-sizing 的隐式 clamp/重置。
    /// - 浏览期间的高度修正延迟到滚动停止（applyDeferredHeights），滚动途中内容不跳。
    final class MessageListLayout: UICollectionViewLayout {
        /// 未测量 cell 的默认估计高度（首帧兜底，实测/seed 到达后即修正）
        var estimatedItemHeight: CGFloat = 120
        var itemSpacing: CGFloat = 0
        /// 浏览模式：已缓存高度的 cell 缩小/稳定 → 延迟修正（滚动停止统一刷新）
        var deferSelfSizing = false
        /// 进入会话稳定化窗口（P7）：首次 apply 后 0.4s 内，一切首测高度变化 defer，
        /// 统一落实 —— 消除「重进会话 → cell 逐块首测 → 120→实际高度串行重排风暴
        /// → 内容逐块撑开」的进入抖动。由 Coordinator 首次 apply 设置。
        var enterStabilizeUntil: Date = .distantPast
        /// 钉底模式：增长 cell 的 self-sizing 回报里做内容偏移补偿，
        /// 同一布局 pass 内底部保持贴合（不做「先长高再追滚」的抖动）
        var isAutoScrollPinning = false

        /// 实测高度（按 item index，会话内有效；消息增删时失效）
        private var heightCacheByIndex: [Int: CGFloat] = [:]
        /// 预置高度（来自内容 key 记忆，复用/重入免测量）
        private var precalcByIndex: [Int: CGFloat] = [:]
        /// item index → 内容 key（本次 snapshot 的映射，self-sizing 回报写回用）
        var contentKeyByIndex: [Int: String] = [:]
        /// 内容 key(+宽度) → 实测高度记忆：跨 apply/跨会话稳定，cell 复用 seed 用
        private var measuredByContentKey: [String: CGFloat] = [:]
        /// cell 自身上报的「当前内容 key」（测量/写回用）：invalidationContext 写回
        /// 必须以 cell 实际测量的内容为准，不能查全局 contentKeyByIndex —— 异步测量回报
        /// 与 apply 的 key 表更新错位时，会把展开高度写进折叠 key（2026-08-09 修复 P5：
        /// fr0 seed 被污染为展开高度 → 折叠命中污染 seed → 高度不缩 → 留白）。
        private var reportedKeyByIndex: [Int: String] = [:]
        /// 浏览期间延迟的高度修正（滚动停止后 applyDeferredHeights 统一写入）
        private var deferredHeights: [Int: CGFloat] = [:]
        /// P34:屏内渲染的系统安全区加成——UIHostingView 会把宿主视图的底部安全区
        /// (沉浸布局下 = home indicator 34pt)计入布局/测量高度,而离屏 probe 不会
        /// (实测 real−probe=34.0pt,ignoresSafeArea 对 UIHostingView 测量无效)。
        /// 约定:各高度存储(measuredByContentKey/precalcByIndex/heightCacheByIndex)
        /// 一律存「内容纯高」,prepare 布局与 preferredLayoutAttributesFitting 返回
        /// 时统一 +pad,写回时统一 −pad → 测量=布局=渲染,零 REJECT 零弹跳。
        var safeAreaPad: CGFloat {
            if let cv = collectionView, cv.safeAreaInsets.bottom > 0 { return cv.safeAreaInsets.bottom }
            // premeasure 阶段 cv 未布局(安全区=0):用 window 级屏幕安全区兜底
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
               let keyWindow = scene.keyWindow {
                return keyWindow.safeAreaInsets.bottom
            }
            return 0
        }

        private var itemAttributes: [UICollectionViewLayoutAttributes] = []
        private var totalHeight: CGFloat = 0

        var deferredHeightCount: Int { deferredHeights.count }

        /// 内容 key 记忆的实测高度（供 cell 复用 seed，免重新测量）
        func measuredHeight(forKey key: String, width: CGFloat) -> CGFloat? {
            guard !key.isEmpty else { return nil }
            let h = measuredByContentKey[key + "-w\(Int(width))"]
            if h == nil {
                AppLogger.shared.info("[List] seedMiss key=" + key + " w=" + String(Int(width)), category: "List")
            }
            return h
        }

        /// 消息增删/会话切换：index 高度缓存失效（防 index 错位）
        func invalidateIndexCaches() {
            heightCacheByIndex.removeAll(keepingCapacity: true)
            precalcByIndex.removeAll(keepingCapacity: true)
            deferredHeights.removeAll(keepingCapacity: true)
            reportedKeyByIndex.removeAll(keepingCapacity: true)
        }

        /// 内容变化（展开/折叠等指纹变）→ 该 index 的高度缓存与延迟修正失效：
        /// 新内容必须走完整重测链路并立即重排，不被浏览模式的 defer 拦截
        /// （2026-08-09 修复 P3：此前折叠被 defer 延迟、applyDeferredHeights 又跳过
        /// 已有缓存项 → 折叠高度永久丢失，上下留下被撑开的空白）。
        func invalidateHeights(at index: Int) {
            heightCacheByIndex[index] = nil
            precalcByIndex[index] = nil
            deferredHeights[index] = nil
            reportedKeyByIndex[index] = nil
        }

        /// cell 测量时上报自身内容 key（2026-08-09 P5）：写回高度必须与「正在测量的
        /// 内容」严格绑定，杜绝测量回报与 apply key 表错位导致的跨指纹污染。
        func noteHeightKey(_ key: String, at index: Int) {
            reportedKeyByIndex[index] = key
        }

        /// 进入会话离屏预测量结果（P8）：写入预置高度表（prepare 直接用真实高度，
        /// 滚动中 cell 不再以 120 估计高度占位）与内容 key 记忆（cell 命中 seed 一致）。
        func notePremeasured(key: String, width: CGFloat, height: CGFloat, index: Int) {
            // 开源参考实现对齐：probe 值只写 precalcByIndex（prepare 定位用），
            // 不再写 measuredByContentKey——seed 只应来自「屏内 UIKit 实测」写回，
            // 否则离屏 probe(+3pt 容差、无屏内安全区)污染 seed → 首测核实 REJECT 重排
            // → 滚动中跳动（根因 5）。
            precalcByIndex[index] = height
        }

        // MARK: - 布局

        override var collectionViewContentSize: CGSize {
            CGSize(width: collectionView?.bounds.width ?? 0, height: totalHeight)
        }

        override func prepare() {
            super.prepare()
            guard let cv = collectionView else { return }
            let count = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
            let width = cv.bounds.width
            guard width > 0 else { return }
            itemAttributes.removeAll(keepingCapacity: true)
            itemAttributes.reserveCapacity(count)
            var y: CGFloat = 0
            for i in 0..<count {
                let attrs = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
                let h: CGFloat
                // P34:存储均为内容纯高,布局时统一 + 屏内安全区加成(= 真实渲染需求)
                if let cached = heightCacheByIndex[i] { h = cached + safeAreaPad }
                else if let pre = precalcByIndex[i] { h = pre + safeAreaPad }
                else { h = estimatedItemHeight }
                attrs.frame = CGRect(x: 0, y: y, width: width, height: h)
                itemAttributes.append(attrs)
                y += h
                if i < count - 1, h > 0 { y += itemSpacing }
            }
            totalHeight = y
        }

        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            // 可见区上下各加半屏：全屏 margin 会同时创建太多 hosting cell（滚动 hitch 来源）
            let expanded = rect.insetBy(dx: 0, dy: -max(rect.height, 0) * 0.5)
            return itemAttributes.filter { $0.frame.intersects(expanded) }
        }

        override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            guard indexPath.item < itemAttributes.count else { return nil }
            return itemAttributes[indexPath.item]
        }

        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }

        // MARK: - self-sizing 协作（防振荡）

        override func shouldInvalidateLayout(
            forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
            withOriginalAttributes original: UICollectionViewLayoutAttributes
        ) -> Bool {
            let index = preferred.indexPath.item
            let preferredH = preferred.size.height
            let originalH = original.size.height

            // 滚动中（deferSelfSizing=true）或进入稳定窗口（P7）：仅延迟「缩小/稳定」的高度
            // 变化（滚动中保持视觉稳定）；增长与首次测量放行实时生效——
            // 参考实现对齐（MessageListLayout defer 语义：`preferred <= original + 0.5`
            // 才入 deferredHeights，grow 放行走 REJECT 重排，避免「滚动中内容被裁、
            // 停止瞬间一次性弹高」）。
            if deferSelfSizing || Date() < enterStabilizeUntil {
                let isShrinkOrStable = preferredH <= originalH + 0.5
                if isShrinkOrStable {
                    if abs(preferredH - originalH) > 0.5 {
                        deferredHeights[index] = preferredH
                        AppLogger.shared.info("[List] selfSizing DEFER idx=" + String(index)
                            + " h=" + String(format: "%.1f", preferredH)
                            + " orig=" + String(format: "%.1f", originalH), category: "List")
                    }
                    return false
                }
                // grow：放行到下方 REJECT 路径（实时重排）
            }
            let delta = abs(preferredH - originalH)
            // 已实测的 cell 用宽松阈值（>2pt 才重排），未实测的首次测量从紧（>0.5pt）
            let accept = heightCacheByIndex[index] != nil ? delta > 2 : delta > 0.5
            if accept {
                AppLogger.shared.info("[List] selfSizing REJECT idx=" + String(index)
                    + " h=" + String(format: "%.1f", preferredH)
                    + " orig=" + String(format: "%.1f", originalH)
                    + " cached=" + (heightCacheByIndex[index] != nil ? "1" : "0")
                    + " defer=" + (deferSelfSizing ? "1" : "0"), category: "List")
            }
            return accept
        }

        override func invalidationContext(
            forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
            withOriginalAttributes original: UICollectionViewLayoutAttributes
        ) -> UICollectionViewLayoutInvalidationContext {
            let ctx = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
            let index = preferred.indexPath.item
            let oldH = original.size.height
            let newH = preferred.size.height
            let delta = newH - oldH
            // 写回实测高度：index 缓存 + 内容 key 记忆（跨会话/复用 seed 用）。
            // key 以 cell 自身上报为准（P5）：全局 contentKeyByIndex 在异步测量回报
            // 与 apply 更新错位时会写错 key（展开高度污染折叠 key → 折叠留白）。
            let writeKey = reportedKeyByIndex[index] ?? contentKeyByIndex[index]
            // P34:写回内容纯高(newH 含屏内安全区加成)——存储统一纯高口径
            let pureH = max(newH - safeAreaPad, 1)
            heightCacheByIndex[index] = pureH
            if let key = writeKey {
                measuredByContentKey[key + "-w\(Int(preferred.size.width))"] = pureH
            }
            AppLogger.shared.info("[List] heightWrite idx=" + String(index)
                + " h=" + String(format: "%.1f", newH)
                + " old=" + String(format: "%.1f", oldH)
                + " key=" + (writeKey ?? "nil"), category: "List")
            // 钉底模式：增长 cell 做内容偏移补偿 → 同一 pass 内底部贴合
            if isAutoScrollPinning, delta > 0 {
                ctx.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            }
            return ctx
        }

        /// 滚动停止后：把浏览期间延迟的高度修正写入缓存并触发重排。
        /// 无条件写入：deferred 高度就是滚动中实测的正确高度，必须落实。
        /// 内容变化（展开/折叠）项的 defer 已由 apply 的 invalidateHeights(at:) 清除，
        /// 不会用旧高度覆盖新内容（2026-08-09 修复 P3）。
        func applyDeferredHeights() {
            guard !deferredHeights.isEmpty else { return }
            for (idx, h) in deferredHeights {
                // P34:deferred 高度含屏内安全区加成,写回内容纯高
                let pureH = max(h - safeAreaPad, 1)
                heightCacheByIndex[idx] = pureH
                // key 以 cell 自身上报为准（P5），与测量写回保持一致。
                if let key = reportedKeyByIndex[idx] ?? contentKeyByIndex[idx],
                   let w = collectionView?.bounds.width {
                    measuredByContentKey[key + "-w\(Int(w))"] = pureH
                }
                AppLogger.shared.info("[List] deferredApply idx=" + String(idx)
                    + " h=" + String(format: "%.1f", h), category: "List")
            }
            deferredHeights.removeAll()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        private weak var cv: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<MessageListSection, MessageListItem>?
        private var lastItems: [MessageListItem]? = nil
        private var lastScrollSignal = 0
        private var lastScrollToMessageID: UUID?
        private var lastReloadToken = 0
        private weak var messageListLayout: MessageListLayout?

        // === 滚动模式（2026-08-09）：autoScrolling=钉底 / userBrowsing=浏览保持 ===
        /// autoScrolling=钉底（内容增长贴底）；userBrowsing=用户上滑浏览（增长保持 offset）。
        enum ScrollMode { case autoScrolling, userBrowsing }
        var scrollMode: ScrollMode = .autoScrolling {
            didSet {
                // 钉底模式由滚动模式驱动;deferSelfSizing 只跟随「滚动进行中」
                // （滚动中高度修正延迟到停止,静止时展开/折叠立即生效——否则
                //  浏览模式下关闭思考,收缩被延迟且永不 flush → 内容之间空一大截）。
                messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            }
        }
        /// contentSize KVO：内容变化时按模式贴底/clamp（替代旧 scrollSignal 轮询贴底）
        private var contentSizeObservation: NSKeyValueObservation?
        /// 布局诊断基准（2026-08-09 用户要求）：上一次打印的「最后一条用户消息 y /
        /// AI 回复高度 / 间距」，展开/折叠后对比差值，检查距离是否回收。
        private var diagLastUserY: CGFloat = -1
        private var diagLastAIH: CGFloat = -1
        private var diagLastAIY: CGFloat = -1
        private var diagLastGap: CGFloat = -1

        /// 会话加载期：持续钉底直到布局稳定（2s 硬上限）
        private var clampAfterSessionLoad = false
        private var clampDeadline = Date.distantPast
        /// 滚动锚点窗口（2026-08-09）：apply 前后记录「第一个可见消息」的屏幕偏移，
        /// 窗口内 contentSize 变化跳过 clamp 分支、直接恢复锚点——防止展开/折叠时
        /// 测量瞬时缩小（909 首测不完整）被 KVO clamp 到错误位置（「点击跳位置」根因）。
        private var anchorItemIndex: Int?
        private var anchorItemMid: UUID?
        private var anchorRelativeY: CGFloat = 0
        private var anchorWindowEnd: Date = .distantPast
        private var anchorActive: Bool { Date() < anchorWindowEnd }

        private var bubbleBox: BubbleFactoryBox?
        private var pendingBox: PendingFactoryBox?
        private var blockBox: BlockFactoryBox?
        private var bannerView: AnyView?
        private var onUserDrag: (() -> Void)?
        private var onNearBottom: (() -> Void)?
        private var onNearBottomChanged: ((Bool) -> Void)?
        private var lastNearBottom: Bool?
        /// 参考实现对齐：settle 落实延迟高度期间抑制 KVO（isFlushing），
        /// 防止 applyDeferredHeights→contentSize 变化立即触发贴底/Clamp 与
        /// restoreAnchor 竞争（「停止时跳一下」根因）
        private var isFlushing = false
        private var messageByID: [UUID: ChatMessage] = [:]
        private var pendingByID: [UUID: PendingUserMessage] = [:]
        /// cell 目标宽度（2026-08-09 修复「左半边」）：apply 时按容器实际宽更新，
        /// 配置 cell 时显式传入——不信任 flow layout 的估计帧宽（默认 itemSize 50×50）。
        var cellWidth: CGFloat = 0
        /// 悬浮输入栏总高(P18):贴底锚点 = 输入框上缘
        var bottomAnchorInset: CGFloat = 0

        func setup(cv: UICollectionView,
                   bubbleBox: BubbleFactoryBox,
                   pendingBox: PendingFactoryBox,
                   blockBox: BlockFactoryBox,
                   bannerView: AnyView,
                   onUserDrag: @escaping () -> Void,
                   onNearBottom: (() -> Void)? = nil,
                   onNearBottomChanged: ((Bool) -> Void)? = nil) {
            self.cv = cv
            self.bubbleBox = bubbleBox
            self.pendingBox = pendingBox
            self.blockBox = blockBox
            self.bannerView = bannerView
            self.onUserDrag = onUserDrag
            self.onNearBottom = onNearBottom
            self.onNearBottomChanged = onNearBottomChanged

            let bubbleRegistration = UICollectionView.CellRegistration<MessageCell, MessageListItem> { [weak self] cell, _, item in
                guard let self, case .message(let mid, _) = item, let msg = self.messageByID[mid], let make = self.bubbleBox?.make else { return }
                // 流式消息：cell 仅在 dequeue 时配置一次，key 是快照不会变化——
                // 必须绕过高度缓存（bypass），让 UIHostingConfiguration 内容更新自动重测高度
                // （2026-08-09 修复 P0：否则高度冻结在首帧，回复增长不可见）。
                let isStreamingMsg = self.streamingLengths[mid] != nil
                let key = self.messageHeightKey(mid, msg: msg)
                // seed：内容 key 记忆的真实高度 → 复用 cell 免重新测量（根治「复用测量旧内容」）
                cell.applyContent(AnyView(make(msg)), key: key, bypass: isStreamingMsg, width: self.cellWidth, messageID: mid, kind: "message")
            }
            let pendingRegistration = UICollectionView.CellRegistration<MessageCell, MessageListItem> { [weak self] cell, _, item in
                guard let self, case .pending(let pid) = item, let pending = self.pendingByID[pid], let make = self.pendingBox?.make else { return }
                let key = "pending-\(pid)-\(pending.text.count)"
                cell.applyContent(AnyView(make(pending)), key: key, width: self.cellWidth, kind: "pending")
            }
            let bannerRegistration = UICollectionView.CellRegistration<MessageCell, MessageListItem> { [weak self] cell, _, item in
                guard case .banner = item, let banner = self?.bannerView else { return }
                cell.applyContent(banner, key: nil, width: self?.cellWidth ?? 0, kind: "banner")
            }
            let headerRegistration = UICollectionView.CellRegistration<MessageCell, MessageListItem> { [weak self] cell, _, item in
                guard let self, case .header(let mid) = item, let msg = self.messageByID[mid], let make = self.blockBox?.makeHeader else { return }
                let key = "h-\(mid)-\(msg.content.count)"
                cell.applyContent(make(msg), key: key, width: self.cellWidth, messageID: mid, kind: "header")
            }
            let blockRegistration = UICollectionView.CellRegistration<MessageCell, MessageListItem> { [weak self] cell, _, item in
                guard let self, case .block(let mid, let idx, let fp) = item, let msg = self.messageByID[mid],
                      let segs = self.segmentsByID[mid], segs.indices.contains(idx), let make = self.blockBox?.makeBlock else { return }
                let seg = segs[idx]
                // 高度 key 带展开指纹（与 item 指纹一致）：展开/折叠 → key 变 → 重测
                let key = "b-\(mid)-\(idx)-\(seg.contentSignature)-f\(fp)"
                // 块级模式只承载非流式消息：内容恒稳定（展开/折叠已由指纹驱动重配重测），
                // bypass 恒 false → 滚动复用命中高度记忆免重新测量（2026-08-09 修复 P2：
                // 此前 tool/reasoning 每次现测，滚动中测量时序不稳 → 高度微变 → 交汇处抖动）。
                cell.applyContent(make(msg, seg), key: key, bypass: false, width: self.cellWidth, messageID: mid, kind: "block")
            }
            let footerRegistration = UICollectionView.CellRegistration<MessageCell, MessageListItem> { [weak self] cell, _, item in
                guard let self, case .footer(let mid) = item, let msg = self.messageByID[mid], let make = self.blockBox?.makeFooter else { return }
                let key = "f-\(mid)-\(msg.wasStopped ?? false)-\(msg.wasInterrupted)-\(msg.taskElapsedSeconds ?? -1)"
                cell.applyContent(make(msg), key: key, width: self.cellWidth, messageID: mid, kind: "footer")
            }

            let dataSource = UICollectionViewDiffableDataSource<MessageListSection, MessageListItem>(collectionView: cv) { collectionView, indexPath, item in
                switch item {
                case .banner:
                    return collectionView.dequeueConfiguredReusableCell(using: bannerRegistration, for: indexPath, item: item)
                case .message:
                    return collectionView.dequeueConfiguredReusableCell(using: bubbleRegistration, for: indexPath, item: item)
                case .pending:
                    return collectionView.dequeueConfiguredReusableCell(using: pendingRegistration, for: indexPath, item: item)
                case .header:
                    return collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: item)
                case .block:
                    return collectionView.dequeueConfiguredReusableCell(using: blockRegistration, for: indexPath, item: item)
                case .footer:
                    return collectionView.dequeueConfiguredReusableCell(using: footerRegistration, for: indexPath, item: item)
                }
            }
            self.dataSource = dataSource
            self.messageListLayout = cv.collectionViewLayout as? MessageListLayout
            cv.dataSource = dataSource
            // 初始化即建立合法数据源状态：含 .main section 的空 snapshot。
            // 否则首次 apply 前/空列表短路时，snapshot 无 section，后续查询会抛
            // NSInternalInconsistencyException（"Section identifier was not found"，2026-08-09 崩溃）。
            var initSnapshot = NSDiffableDataSourceSnapshot<MessageListSection, MessageListItem>()
            initSnapshot.appendSections([.main])
            dataSource.apply(initSnapshot, animatingDifferences: false)

            // 会话加载期：持续钉底直到布局稳定（2s 硬上限）。
            clampAfterSessionLoad = true
            clampDeadline = Date().addingTimeInterval(2)

            // contentSize KVO（2026-08-09）：内容增长/缩小按滚动模式处理，
            // 同一 pass 贴底或保持 offset，替代旧「invalidateLayout + 事后追滚」的抖动路径。
            contentSizeObservation = cv.observe(\.contentSize, options: [.new, .old]) { [weak self] cv, change in
                guard let self else { return }
                // 参考实现对齐：settle 落实延迟高度期间抑制 KVO（isFlushing）
                guard !self.isFlushing else { return }
                let newH = change.newValue?.height ?? 0
                let oldH = change.oldValue?.height ?? 0
                guard newH != oldH else { return }
                let delta = newH - oldH
                // 锚点窗口内：跳过现有 clamp/贴底分支，直接恢复锚点位置
                if self.anchorActive {
                    self.restoreAnchor(cv)
                    return
                }
                if self.clampAfterSessionLoad {
                    // P22:进入会话贴底 = 自然最大 offset(inset 已含输入框顶边)
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if maxOff > 0 { cv.contentOffset.y = maxOff }
                    if Date() >= self.clampDeadline { self.clampAfterSessionLoad = false }
                    checkNearBottom(cv)
                    return
                }
                if delta > 0, self.scrollMode == .autoScrolling {
                    // 钉底：增长直接贴底（同 pass，不做「先长高再追滚」）；
                    // P22:自然最大 offset(inset 已含输入框顶边)
                    let maxOff = newH - cv.bounds.height + cv.adjustedContentInset.bottom
                    if maxOff > 0 { cv.contentOffset.y = max(cv.contentOffset.y, maxOff) }
                    checkNearBottom(cv)
                } else if delta < 0 {
                    // 缩小：防 overscroll（performWithoutAnimation 防 UIKit 硬 clamp 抖动）
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y > maxOff, !cv.isTracking, !cv.isDecelerating {
                        UIView.performWithoutAnimation { cv.contentOffset.y = maxOff }
                    }
                }
            }
        }

        func update(bubbleBox: BubbleFactoryBox, pendingBox: PendingFactoryBox, blockBox: BlockFactoryBox, bannerView: AnyView, onUserDrag: @escaping () -> Void, onNearBottom: (() -> Void)? = nil, onNearBottomChanged: ((Bool) -> Void)? = nil) {
            self.bubbleBox = bubbleBox
            self.pendingBox = pendingBox
            self.blockBox = blockBox
            self.bannerView = bannerView
            self.onUserDrag = onUserDrag
            self.onNearBottom = onNearBottom
            self.onNearBottomChanged = onNearBottomChanged
        }

        /// 缓存消息/排队对象：cell 配置时按 id 取实例（SwiftData @Model 对象）。
        func cache(messages: [ChatMessage], pending: [PendingUserMessage], streamingLengths: [UUID: Int], segments: [UUID: [AssistantSegment]],
                   expandedReasoningKeys: Set<String>, expandedToolIDs: Set<UUID>, expandedErrorIDs: Set<UUID>) {
            var mm: [UUID: ChatMessage] = [:]
            for m in messages { mm[m.id] = m }
            messageByID = mm
            self.streamingLengths = streamingLengths
            self.expandedReasoningKeys = expandedReasoningKeys
            self.expandedToolIDs = expandedToolIDs
            self.expandedErrorIDs = expandedErrorIDs
            segmentsByID = segments
            var pp: [UUID: PendingUserMessage] = [:]
            for p in pending { pp[p.id] = p }
            pendingByID = pp
        }

        private var segmentsByID: [UUID: [AssistantSegment]] = [:]

        private var streamingLengths: [UUID: Int] = [:]
        private var expandedReasoningKeys: Set<String> = []
        private var expandedToolIDs: Set<UUID> = []
        private var expandedErrorIDs: Set<UUID> = []


        /// 消息级 cell 的内容 key：消息 id + 内容长度 + 工具/思考段数 + 展开指纹。
        /// 展开/折叠（指纹变化）→ key 变 → 新测量 → 布局只重排该 cell。
        private func messageHeightKey(_ mid: UUID, msg: ChatMessage) -> String {
            "\(mid)-\(msg.content.count)-\(msg.toolCalls.count)-\(msg.reasoningSegments.count)"
                + "-r\(expandedReasoningKeys.filter { $0.hasPrefix("\(mid)-") }.count)"
                + "-t\(expandedToolIDs.intersection(msg.toolCalls.map { $0.id }).count)"
                + "-e\(expandedErrorIDs.contains(mid) ? 1 : 0)"
        }

        /// 任意列表项的内容 key（与 cell 配置路径一致，供布局层 contentKeyByIndex 同步）
        /// 离屏预测量内容构造（P8）：与 cellProvider 同源（同一批工厂闭包 + 缓存表），
        /// 保证预测量高度与真实 cell 一致。pending/banner 也覆盖。
        private func content(for item: MessageListItem) -> AnyView? {
            switch item {
            case .banner:
                return bannerView
            case .message(let mid, _):
                guard let m = messageByID[mid], let box = bubbleBox else { return nil }
                return AnyView(box.make(m))
            case .pending(let mid):
                guard let p = pendingByID[mid], let box = pendingBox else { return nil }
                return AnyView(box.make(p))
            case .header(let mid):
                guard let m = messageByID[mid], let box = blockBox else { return nil }
                return box.makeHeader(m)
            case .block(let mid, let idx, _):
                guard let m = messageByID[mid], let segs = segmentsByID[mid],
                      segs.indices.contains(idx), let box = blockBox else { return nil }
                return box.makeBlock(m, segs[idx])
            case .footer(let mid):
                guard let m = messageByID[mid], let box = blockBox else { return nil }
                return box.makeFooter(m)
            }
        }

        /// 进入会话分批离屏预测量（P8）：把全部 item 的真实高度在进入后 ~0.8s 内测完
        /// 并写入布局预置表 —— 滚动中任何 cell 的 frame 从一开始就是正确高度，
        /// 彻底消除「屏幕外的折叠块以估计/展开距离占位，手离屏才刷新」。
        private var premeasureDone = false
        /// 同步全量预测量(P11):首次 apply 时同步执行(首帧 UIKit 布局前完成),
        /// prepare 第一帧就用预置真实高度 —— 进入会话零「估计→真实」收敛,
        /// 消除 contentH 多阶段变化导致的 offset 跳变(7255→7916→clamp)。
        /// 宽度用屏幕宽(容器宽=屏幕宽-inset,与首帧实际一致);probe 离屏测量。
        private func startPremeasure(_ items: [MessageListItem]) {
            guard !premeasureDone, !items.isEmpty else { return }
            premeasureDone = true
            let width = cellWidth > 0 ? cellWidth : UIScreen.main.bounds.width
            AppLogger.shared.info("[List] premeasure START items=" + String(items.count)
                + " w=" + String(format: "%.1f", width), category: "List")
            guard let layout = messageListLayout else { return }
            let probe = MessageCell(frame: .zero)
            // P27:probe 无 window 时动态字体 trait 冻结为 .large,与真实 cell(继承用户
            // 设置)不一致 → 测量行高/行数偏小 → cell 高度不足,文本底部被裁(「消息
            // 被截断成…」)。继承 cv 的字体分类让测量与渲染同源。
            if let cv = self.cv {
                probe.traitOverrides.preferredContentSizeCategory = cv.traitCollection.preferredContentSizeCategory
            }
            probe.contentView.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
            // P33:probe 预热——UIHostingConfiguration 首次布局可能未收敛(实测新闻会话
            // probe 比真实偏大 62pt),先 apply 一个最小内容让 hosting 完成初始化,
            // 再正式测量,消除「首帧未收敛」的系统偏差。
            probe.applyContent(AnyView(Text("warmup").font(.body)), key: "warmup", bypass: true, width: width, kind: "warmup")
            probe.contentView.layoutIfNeeded()
            probe.contentView.layoutIfNeeded()
            AppLogger.shared.info("[List] premeasure env: probe.safeArea=("
                + String(format: "%.1f", probe.safeAreaInsets.top) + ","
                + String(format: "%.1f", probe.safeAreaInsets.bottom)
                + ") cv.safeArea=(" + String(format: "%.1f", self.cv?.safeAreaInsets.top ?? -1)
                + "," + String(format: "%.1f", self.cv?.safeAreaInsets.bottom ?? -1)
                + ") cv.window=" + (self.cv?.window != nil ? "1" : "0"), category: "List")
            var measured = 0
            for (i, item) in items.enumerated() {
                guard let content = self.content(for: item), let key = self.heightKey(for: item) else { continue }
                probe.applyContent(content, key: key, bypass: false, width: width, kind: "premeasure")
                probe.contentView.layoutIfNeeded()
                probe.contentView.layoutIfNeeded()
                let size = probe.contentView.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                )
                // P27:+3pt 容差吸收行高渲染差异(Text 行高在不同环境的 1-2pt 浮动),
                // 避免「测量高度 < 渲染高度」导致的底部裁剪
                let seedH = max(size.height + 3, 1)
                layout.notePremeasured(key: key, width: width, height: seedH, index: i)
                AppLogger.shared.info("[List] premeasure item idx=" + String(i)
                    + " h=" + String(format: "%.1f", seedH)
                    + " kind=" + String(describing: item), category: "List")
                measured += 1
            }
            AppLogger.shared.info("[List] premeasure DONE items=" + String(items.count) + " measured=" + String(measured), category: "List")
            // 兜底:若首帧 prepare 已提前跑过(罕见),重排一次让预置高度生效;
            // 正常路径首帧 prepare 尚未执行,本次调用无实际效果(幂等)。
            layout.invalidateLayout()
        }

        /// P12:对指定 index 同步重新预测量(展开/折叠失效缓存后调用)。
        /// 覆盖写 precalcByIndex → 屏幕外 block 滚动进入视野时第一帧即真实高度,
        /// 不再经历「估计 120 → 手停实测」的占位刷新。probe 离屏测量,数毫秒级。
        private func rePremeasure(_ items: [MessageListItem], indices: [Int]) {
            guard let layout = self.messageListLayout else { return }
            let width = self.cellWidth > 0 ? self.cellWidth : UIScreen.main.bounds.width
            let probe = MessageCell(frame: .zero)
            // P27:同 premeasure——继承真实字体 trait,测量与渲染同源
            if let cv = self.cv {
                probe.traitOverrides.preferredContentSizeCategory = cv.traitCollection.preferredContentSizeCategory
            }
            probe.contentView.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
            var measured = 0
            for i in indices {
                guard i < items.count, let content = self.content(for: items[i]), let key = self.heightKey(for: items[i]) else { continue }
                probe.applyContent(content, key: key, bypass: false, width: width, kind: "remeasure")
                probe.contentView.layoutIfNeeded()
                probe.contentView.layoutIfNeeded()
                let size = probe.contentView.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                )
                // P27:同 premeasure,+3pt 容差
                layout.notePremeasured(key: key, width: width, height: max(size.height + 3, 1), index: i)
                measured += 1
            }
            if measured > 0 {
                AppLogger.shared.info("[List] remeasure DONE idx=" + indices.map(String.init).joined(separator: ",") + " measured=" + String(measured), category: "List")
            }
        }
        /// (P11 同步化后不再使用分批测量)

        /// 诊断：item 的人类可读描述（展开/折叠指纹变化定位用，2026-08-09 P4）。
        private static func describe(item: MessageListItem) -> String {
            switch item {
            case .banner: return "banner"
            case .message(let mid, let fp): return "msg:" + mid.uuidString.prefix(8) + ":" + fp
            case .pending(let mid): return "pending:" + mid.uuidString.prefix(8)
            case .header(let mid): return "header:" + mid.uuidString.prefix(8)
            case .block(let mid, let idx, let fp): return "block:" + mid.uuidString.prefix(8) + ":" + String(idx) + ":" + fp
            case .footer(let mid): return "footer:" + mid.uuidString.prefix(8)
            }
        }

        private func heightKey(for item: MessageListItem) -> String? {
            switch item {
            case .banner:
                return nil
            case .message(let mid, _):
                guard let msg = messageByID[mid] else { return nil }
                return messageHeightKey(mid, msg: msg)
            case .pending(let pid):
                guard let p = pendingByID[pid] else { return nil }
                return "pending-\(pid)-\(p.text.count)"
            case .header(let mid):
                guard let msg = messageByID[mid] else { return nil }
                return "h-\(mid)-\(msg.content.count)"
            case .block(let mid, let idx, let fp):
                guard let segs = segmentsByID[mid], segs.indices.contains(idx) else { return nil }
                return "b-\(mid)-\(idx)-\(segs[idx].contentSignature)-f\(fp)"
            case .footer(let mid):
                guard let msg = messageByID[mid] else { return nil }
                return "f-\(mid)-\(msg.wasStopped ?? false)-\(msg.wasInterrupted)-\(msg.taskElapsedSeconds ?? -1)"
            }
        }

        /// 布局诊断（2026-08-09 用户要求）：以「最后一条 AI 回复」为位移锚点——
        /// 它在列表最下方，任何上方消息的展开/折叠都会让它整体下移/回位，
        /// 因此 dAIY（它的顶部位置变化）直接回答「距离有没有回收」：
        /// 展开 → dAIY ≈ 展开高度增量；折叠后 dAIY 应回到 ≈0（回收）；残留 >0 = 没回收。
        private func logLayoutDiag(_ cv: UICollectionView, reason: String) {
            guard let dataSource, cv.numberOfSections > 0 else { return }
            let count = cv.numberOfItems(inSection: 0)
            var lastAIRect: CGRect?
            var upperUserRect: CGRect?
            var foundAI = false
            for i in 0..<count {
                guard let item = dataSource.itemIdentifier(for: IndexPath(item: i, section: 0)) else { continue }
                guard case .message(let mid, _) = item, let msg = messageByID[mid] else { continue }
                if msg.role == .user {
                    upperUserRect = cv.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame
                } else if msg.role == .assistant {
                    lastAIRect = cv.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame
                    foundAI = true
                }
            }
            let aiY = lastAIRect?.minY ?? -1
            let aiH = lastAIRect?.height ?? -1
            let userY = upperUserRect?.minY ?? -1
            let userH = upperUserRect?.height ?? -1
            let gap = (userY >= 0 && aiY >= 0 && foundAI) ? aiY - (userY + max(userH, 0)) : -1
            let dUserY = diagLastUserY >= 0 ? userY - diagLastUserY : 0
            let dAIH = diagLastAIH >= 0 ? aiH - diagLastAIH : 0
            let dAIY = diagLastAIY >= 0 ? aiY - diagLastAIY : 0
            let dGap = diagLastGap >= 0 ? gap - diagLastGap : 0
            diagLastUserY = userY
            diagLastAIH = aiH
            diagLastAIY = aiY
            diagLastGap = gap
            AppLogger.shared.info("[LayoutDiag] " + reason
                + ": lastAIY=" + String(format: "%.1f", aiY)
                + " lastAIH=" + String(format: "%.1f", aiH)
                + " upperUserY=" + String(format: "%.1f", userY)
                + " gap=" + String(format: "%.1f", gap)
                + " | dAIY=" + String(format: "%.1f", dAIY)
                + " dAIH=" + String(format: "%.1f", dAIH)
                + " dGap=" + String(format: "%.1f", dGap), category: "List")
        }


        func apply(items: [MessageListItem], scrollSignal: Int, scrollToMessageID: UUID?, reloadToken: Int) {
            guard let cv, let dataSource else { return }
            // 更新 cell 目标宽度（容器实际宽 - 左右 inset）；dequeue 时经 configure 传入 cell。
            if cv.bounds.width > 0 {
                cellWidth = cv.bounds.width - cv.contentInset.left - cv.contentInset.right
            }
            let forceReload = reloadToken != lastReloadToken
            if forceReload { lastReloadToken = reloadToken }
            // 诊断（2026-08-09 回弹排查）：数据源同步轨迹
            let changed = items != lastItems || forceReload
            if changed {
                AppLogger.shared.info("[List] apply items=" + String(items.count) + " sig=" + String(scrollSignal)
                    + " contentH=" + String(format: "%.1f", cv.contentSize.height), category: "List")
            }
            // lastItems 为 Optional：nil = 从未 apply。空列表也会走首次 apply，
            // 保证数据源始终持有 .main section（2026-08-09 崩溃根因修复）。
            if items != lastItems || forceReload {
                let prevItems = lastItems
                let diagReason: String = forceReload ? "reload" : (prevItems == nil ? "enter" : "toggle")
                // 展开/折叠（items 变化）前捕获滚动锚点
                if prevItems != nil && !forceReload {
                    captureAnchor(cv)
                }
                lastItems = items
                var snapshot = NSDiffableDataSourceSnapshot<MessageListSection, MessageListItem>()
                snapshot.appendSections([.main])
                snapshot.appendItems(items)
                if forceReload {
                    // 恢复路径：snapshot 相同也要强制重配全部 cell（新 runtime 引用）
                    dataSource.applySnapshotUsingReloadData(snapshot)
                } else {
                    dataSource.apply(snapshot, animatingDifferences: false)
                }
                // 展开/折叠（指纹变化）已由 diffable apply 重配 cell，高度按指纹 key
                // 记忆化（bypass=false）：内容稳定时复用免测量；内容再变（指纹变）→
                // invalidateHeights 清缓存 → 完整重测。0.35s 定时器仅做布局诊断
                // （settled 对比），不做二次 apply —— 测量完整性由「两遍 layoutIfNeeded +
                // 指纹失效重测」保证（2026-08-09 与实现对齐修正）。
                // 布局诊断：进入会话/展开折叠/恢复后打印基准与差值；
                // 布局可能未完全稳定（测量在下一轮），0.35s 后补打一次 settled。
                logLayoutDiag(cv, reason: diagReason)
                // 展开/折叠后开启锚点窗口（0.8s），窗口内 KVO 恢复锚点位置
                if prevItems != nil && !forceReload {
                    anchorWindowEnd = Date().addingTimeInterval(0.8)
                    restoreAnchor(cv)
                }
                // P24:纯流式增长立即关闭锚点窗口(见 diff 后 pureStreaming 判断)。
                // 窗口是为展开/折叠的瞬时测量修正设计的;流式每 token 都会续期窗口,
                // 把 KVO 增长钉底短路(指示器沉到输入框后面)——流式必须走钉底。
                let weakCV = cv
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    self.logLayoutDiag(weakCV, reason: diagReason + "-settled")
                }
                // 进入会话（首次 apply）：开启稳定化窗口，首测 defer 化；0.45s 后统一落实
                //（期间 KVO clampAfterSessionLoad 持续贴底，落实后无跳动）。
                if prevItems == nil {
                    messageListLayout?.enterStabilizeUntil = Date().addingTimeInterval(0.4)
                    // P11:首次 apply 时同步全量预测量 —— 首帧 UIKit 布局前 precalc 已就绪,
                    // prepare 第一帧即真实高度,进入会话零收敛跳变、零占位。
                    // P32:重置标记 —— 第二次进入同一会话必须重跑 premeasure,
                    // 覆盖跨会话记忆(measuredByContentKey)中可能被污染的旧高度。
                    premeasureDone = false
                    startPremeasure(items)
                }
                // 同步布局层的内容 key 表（self-sizing 回报/seed 查询用）
                if let layout = messageListLayout {
                    layout.contentKeyByIndex.removeAll(keepingCapacity: true)
                    for (i, item) in items.enumerated() {
                        layout.contentKeyByIndex[i] = heightKey(for: item)
                    }
                    // 消息增删（数量/首项变化）→ index 高度缓存失效，防错位。
                    // P13：首次进入（prevItems == nil）跳过 —— 此时没有旧缓存可错位，
                    // 且 startPremeasure 刚同步写入的 precalc 必须保留（此前全清导致
                    // 首帧回落估计高度 120，屏幕外指示器滚动中占位、手停才刷新）。
                    if prevItems != nil, items.count != prevItems?.count || items.first != prevItems?.first {
                        layout.invalidateIndexCaches()
                        // P24:结构切换(流式结束拆块/消息增删)后全量预测量——
                        // 否则 precalc 空缺回落 120,屏幕外块 cell 滚动中占位错位。
                        // 同步完成,~0.2s(完成瞬间,可接受)。
                        rePremeasure(items, indices: Array(items.indices))
                    }
                    // 内容变化（展开/折叠指纹、流式长度）→ 该 index 高度缓存失效：
                    // 新内容必须完整重测并立即重排（2026-08-09 修复 P3 折叠留白）。
                    // P4（2026-08-09）：diffable apply 重配 cell 后，UIKit 不保证对自定义
                    // layout 重新测量该 cell（实测折叠后 frame 保留旧高度）→ 除失效缓存外，
                    // 还必须 invalidateItems 强制该 item 重新布局 + 触发 self-sizing 回报。
                    if let prev = prevItems, items.count == prev.count {
                        var changedPaths: [IndexPath] = []
                        var changedIndices: [Int] = []
                        for i in items.indices where items[i] != prev[i] {
                            layout.invalidateHeights(at: i)
                            changedPaths.append(IndexPath(item: i, section: 0))
                            changedIndices.append(i)
                            AppLogger.shared.info("[List] invalidateHeights idx=" + String(i) + " item=" + Self.describe(item: items[i]), category: "List")
                        }
                        if !changedPaths.isEmpty {
                            // P24:全量失效重排——局部失效(invalidateItems)与 prepare 全量
                            // 重排脱节:未失效的可见 cell 保留旧 frame,与失效 cell 的新 y
                            // 重叠(滚动中相邻文字叠在一起、停稳才恢复)。prepare 本就是
                            // 全量同步布局,局部失效无收益只有脱节风险。
                            layout.invalidateLayout()
                            // P12:失效缓存后立即同步重新预测量 —— 否则屏幕外(未进入视野)的
                            // block cell 没有首测机会,precalc 空缺 → 滚动中回落到估计高度
                            // (120)占位,手停才刷新成真实距离(用户报告的「刷到屏幕外指示器
                            // 显示展开距离,手离屏才刷新」)。受影响只是当前消息的 block
                            // (几毫秒),同步完成,布局下一轮 prepare 即用新真实高度。
                            rePremeasure(items, indices: changedIndices)
                        }
                        // P24:判断本次变化是否「纯流式增长」(changed 全部是流式消息)——
                        // 是则关闭刚开启的锚点窗口,让 KVO 增长钉底生效(流式跟随);
                        // 展开/折叠(非流式消息指纹变化)保留窗口做锚点恢复。
                        let pureStreaming = changedIndices.allSatisfy { i in
                            guard i < items.count else { return false }
                            switch items[i] {
                            case .message(let mid, _), .header(let mid), .footer(let mid),
                                 .block(let mid, _, _):
                                return streamingLengths[mid] != nil
                            default: return false
                            }
                        }
                        if pureStreaming { anchorWindowEnd = .distantPast }
                    }
                }
            }
            // 流式增长期间:由 ChatView 指纹版本号驱动（指纹含流式长度 → diffable apply
            // 重配流式 cell → self-sizing 重测新高度）。这里不需要任何直接 mutation
            // （diffable dataSource 禁止 reloadItems/reloadData 等直接调用）。
            // 静止时若有残留的延迟高度修正(滚动中 defer 的),立即 flush 并重排
            // （参考实现对齐：isFlushing 抑制 KVO 重入，与 settleAfterInteraction 一致）
            if let layout = messageListLayout, layout.deferredHeightCount > 0, !isUserScrolling {
                isFlushing = true
                layout.applyDeferredHeights()
                layout.invalidateLayout()
                cv.layoutIfNeeded()
                isFlushing = false
            }
            if let targetID = scrollToMessageID, targetID != lastScrollToMessageID {
                lastScrollToMessageID = targetID
                scrollToMessage(targetID, cv: cv)
            } else if scrollSignal != lastScrollSignal {
                lastScrollSignal = scrollSignal
                scrollToBottom(cv)
            }
        }

        /// 捕获滚动锚点：视野内第一个可见 item 的 index + 消息 id + 屏幕相对偏移。
        /// P14：必须锚定「具体 item」而非「消息 id」——restore 若按消息 id 找第一个
        /// 匹配 item，会锚到该消息的 header；而 capture 捕获的可能是长消息中部的
        /// block（header 在视野上方）→ 恢复时 offset 被上移「block 与 header 的距离」，
        /// 表现为「点击长思考段跳到另一个位置」。
        private func captureAnchor(_ cv: UICollectionView) {
            guard let dataSource, cv.numberOfSections > 0 else { anchorItemIndex = nil; return }
            let count = cv.numberOfItems(inSection: 0)
            for i in 0..<count {
                guard let item = dataSource.itemIdentifier(for: IndexPath(item: i, section: 0)) else { continue }
                let mid: UUID?
                switch item {
                case .message(let m, _): mid = m
                case .header(let m), .footer(let m), .block(let m, _, _): mid = m
                default: mid = nil
                }
                guard let mid, let attrs = cv.layoutAttributesForItem(at: IndexPath(item: i, section: 0)) else { continue }
                // P11:必须取「视野内第一个可见 item」——自定义 layout 的 layoutAttributesForItem
                // 对全部 item 返回 attrs,若不判断可见性会锚定到列表顶部(idx=0),
                // 高度收敛时顶部位置不变 → 底部内容仍被推走(跳动)。
                let visible = CGRect(origin: cv.contentOffset, size: cv.bounds.size)
                guard attrs.frame.intersects(visible) else { continue }
                anchorItemIndex = i
                anchorItemMid = mid
                anchorRelativeY = attrs.frame.minY - cv.contentOffset.y
                return
            }
            anchorItemIndex = nil
        }

        /// 恢复锚点：把捕获的「具体 item」恢复到捕获时的屏幕偏移（clamp 到合法范围）。
        /// 优先按 index 恢复（toggle 为同 count 同序 diff，index 稳定且与捕获同 item）；
        /// 若 index 处内容已变（增删错位），兜底按消息 id 找第一个匹配 item。
        private func restoreAnchor(_ cv: UICollectionView) {
            guard let idx = anchorItemIndex, let mid = anchorItemMid,
                  let dataSource, cv.numberOfSections > 0 else { return }
            let count = cv.numberOfItems(inSection: 0)
            var restoreIndex = -1
            if idx < count,
               let item = dataSource.itemIdentifier(for: IndexPath(item: idx, section: 0)) {
                let itemMid: UUID?
                switch item {
                case .message(let m, _): itemMid = m
                case .header(let m), .footer(let m), .block(let m, _, _): itemMid = m
                default: itemMid = nil
                }
                if itemMid == mid { restoreIndex = idx }
            }
            if restoreIndex < 0 {
                // 兜底：按消息 id 找第一个匹配 item
                for i in 0..<count {
                    guard let item = dataSource.itemIdentifier(for: IndexPath(item: i, section: 0)) else { continue }
                    let itemMid: UUID?
                    switch item {
                    case .message(let m, _): itemMid = m
                    case .header(let m), .footer(let m), .block(let m, _, _): itemMid = m
                    default: itemMid = nil
                    }
                    if itemMid == mid { restoreIndex = i; break }
                }
            }
            guard restoreIndex >= 0,
                  let attrs = cv.layoutAttributesForItem(at: IndexPath(item: restoreIndex, section: 0)) else { return }
            let target = max(0, attrs.frame.minY - anchorRelativeY)
            let maxOff = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            cv.contentOffset.y = min(target, maxOff)
        }

        /// 搜索定位：滚动到指定消息（居中显示）。块级消息是 header/block/footer 多 item，
        /// 优先 header 居中（2026-08-09 修复 P1：消息级 .message 匹配不到时 fallback）。
        /// 查询以 UICollectionView 实际内容为真相（容错返回 0，不抛异常）。
        func scrollToMessage(_ messageID: UUID, cv: UICollectionView) {
            guard cv.numberOfSections > 0 else { return }
            var idx: Int?
            for i in 0..<cv.numberOfItems(inSection: 0) {
                guard let item = dataSource?.itemIdentifier(for: IndexPath(item: i, section: 0)) else { continue }
                if case .message(let mid, _) = item, mid == messageID { idx = i; break }
                if item == .header(messageID) || item == .footer(messageID) {
                    idx = i
                    break
                }
            }
            guard let idx else {
                AppLogger.shared.info("[List] scrollToMessage miss mid=" + messageID.uuidString, category: "List")
                return
            }
            AppLogger.shared.info("[List] scrollToMessage idx=" + String(idx) + " mid=" + messageID.uuidString, category: "List")
            cv.layoutIfNeeded()
            cv.scrollToItem(at: IndexPath(item: idx, section: 0), at: .centeredVertically, animated: true)
        }

        func scrollToBottom(_ cv: UICollectionView) {
            // 用户在拖动/惯性滚动期间绝不抢滚动（同步闸门）。
            AppLogger.shared.info("[List] scrollToBottom lastSig=" + String(lastScrollSignal)
                + " guard=" + (isUserScrolling ? "1" : "0")
                + " items=" + String(cv.numberOfItems(inSection: 0))
                + " contentH=" + String(format: "%.1f", cv.contentSize.height)
                + " y=" + String(format: "%.1f", cv.contentOffset.y), category: "List")
            guard !isUserScrolling else { return }
            guard cv.numberOfSections > 0 else { return }
            let count = cv.numberOfItems(inSection: 0)
            guard count > 0 else { return }
            cv.layoutIfNeeded()
            // P22:contentInset.bottom 已 = 输入框顶边距底,自然最大 offset 即锚点
            let maxOff = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            AppLogger.shared.info("[List] scrollToBottom targetY=" + String(format: "%.1f", maxOff)
                + " anchor=" + String(format: "%.1f", bottomAnchorInset)
                + " contentH=" + String(format: "%.1f", cv.contentSize.height)
                + " boundsH=" + String(format: "%.1f", cv.bounds.height)
                + " y=" + String(format: "%.1f", cv.contentOffset.y), category: "List")
            cv.setContentOffset(CGPoint(x: 0, y: maxOff), animated: false)
            // review 2026-08-09：程序化滚动后补报贴底状态（否则浮动「回到底部」按钮
            // 在回底后不消失、进入会话首帧误显示）
            checkNearBottom(cv)
        }

        // MARK: - UIScrollViewDelegate

        /// 用户是否正在拖动/惯性滚动（同步状态，滚动前即时拦截）。
        /// 2026-08-09「上滑回弹」根因修复：此前仅靠 ChatView 异步回传 shouldAutoFollow，
        /// 存在竞态窗口——用户上滑后、异步状态生效前，scrollSignal 触发的 scrollToBottom 仍会执行。
        private var isUserScrolling = false

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserScrolling = true
            messageListLayout?.deferSelfSizing = true
            anchorWindowEnd = .distantPast
            scrollMode = .userBrowsing
            AppLogger.shared.info("[List] dragBegin y=" + String(format: "%.1f", scrollView.contentOffset.y), category: "List")
            onUserDrag?()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            // 无惯性时拖动结束即释放；有惯性则等减速结束再释放。
            if !decelerate {
                isUserScrolling = false
                messageListLayout?.deferSelfSizing = false
                checkNearBottom(scrollView)
                if let cv = scrollView as? UICollectionView { settleAfterInteraction(cv) }
            }
            AppLogger.shared.info("[List] dragEnd decel=" + (decelerate ? "1" : "0")
                + " y=" + String(format: "%.1f", scrollView.contentOffset.y)
                + " guard=" + (isUserScrolling ? "1" : "0"), category: "List")
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isUserScrolling = false
            messageListLayout?.deferSelfSizing = false
            checkNearBottom(scrollView)
            if let cv = scrollView as? UICollectionView { settleAfterInteraction(cv) }
            AppLogger.shared.info("[List] decelEnd y=" + String(format: "%.1f", scrollView.contentOffset.y), category: "List")
        }

        /// 滚动停止后：把浏览期间延迟的高度修正统一写入缓存并重排
        /// （缩小/稳定 cell 的高度修正延迟到停止，避免滚动途中内容跳动）。
        private func settleAfterInteraction(_ cv: UICollectionView) {
            guard let layout = messageListLayout, layout.deferredHeightCount > 0 else { return }
            // 停止瞬间锚定（P6）：落实延迟高度前先捕获锚点，布局更新后恢复原位置，
            // 避免 contentSize 突变把当前视野内容推走（「停止时跳一下」）。
            // 参考实现对齐：isFlushing 抑制期间 KVO 不介入，杜绝与 restoreAnchor 竞争。
            captureAnchor(cv)
            anchorWindowEnd = Date().addingTimeInterval(0.8)
            isFlushing = true
            layout.applyDeferredHeights()
            layout.invalidateLayout()
            cv.layoutIfNeeded()
            isFlushing = false
            restoreAnchor(cv)
        }

        /// 用户手动滚动停在接近底部（≤24pt）→ 视为重新钉住底部，恢复自动跟随
        /// （2026-08-09 修复「拉到最底部也不自动跟随」：此前 shouldAutoFollow 一旦
        /// 被拖动置 false 就永久关闭，流式内容增长无滚动补偿 → 消息一直弹）。
        private func checkNearBottom(_ scrollView: UIScrollView) {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let isNear = scrollView.contentOffset.y >= maxY - 24
            // 开源参考实现对齐：恢复 autoScrolling 的阈值收紧到 4pt（原 24pt 过宽，
            // 用户停在离底 5-24pt 处被 KVO 贴底拉回 →「上滑被拽回/回弹」）；
            // 24pt 仍用于浮动按钮显隐（isNear）。
            if scrollView.contentOffset.y >= maxY - 4 {
                scrollMode = .autoScrolling
                onNearBottom?()
            }
            // 开源参考实现对齐：贴底状态双向上报（浮动「回到底部」按钮显隐）
            if lastNearBottom != isNear {
                lastNearBottom = isNear
                onNearBottomChanged?(isNear)
            }
        }

        /// 诊断（2026-08-09 回弹排查）：offset/contentSize 轨迹，节流（变化 > 80pt 才打）。
        private var lastLoggedOffset: CGFloat = -99999
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let y = scrollView.contentOffset.y
            if abs(y - lastLoggedOffset) > 80 {
                lastLoggedOffset = y
                AppLogger.shared.info("[List] didScroll y=" + String(format: "%.1f", y)
                    + " contentH=" + String(format: "%.1f", scrollView.contentSize.height)
                    + " boundsH=" + String(format: "%.1f", scrollView.bounds.height)
                    + " maxY=" + String(format: "%.1f", max(0, scrollView.contentSize.height - scrollView.bounds.height)),
                    category: "List")
            }
        }
    }

    /// 复用的 self-sizing cell：UIHostingConfiguration 承载 SwiftUI 内容。
    @MainActor
    final class MessageCell: UICollectionViewCell {
        /// 配置代数：每次内容更新 +1；preferredLayoutAttributesFitting 据此识别
        /// 「内容已变但还没重新测量」的复用 cell → 清空上一配置的测量缓存强制重测。
        private var configGeneration: UInt = 0
        /// 最近一次实测高度/宽度/时刻：短窗口内重复 self-sizing 询问直接返回缓存，
        /// 免每帧反复进入 SwiftUI 布局（流式/滚动的布局抖动与卡顿来源）。
        private var lastComputedHeight: CGFloat?
        private var lastComputedWidth: CGFloat?
        private var lastMeasureTime: CFTimeInterval?
        // P29:seed(预置高度)首测核实——probe 离屏测量与真实 cell 渲染若不一致
        // (字体/宽度环境差异),seed 偏矮 → cell 高度不足 → 文本末行被裁(「消息
        // 折叠/截断」)。每个内容 key 首次显示时实测一次核实:一致用 seed(免重排),
        // 不一致用实测(REJECT 重排修正);之后滚动复用命中核实记录免测。
        private var verifiedHeight: CGFloat?
        private var verifiedKey: String?
        private static let measureDedupWindow: CFTimeInterval = 0.05
        /// 绕过预置/去重（流式消息、可展开工具卡/思考块）：内容每帧变化，必须现测。
        private var bypassMeasure = false
        private var heightKey: String?
        private var loggedWidth: CGFloat = -1
        private var loggedKey: String? = nil
        private var containerWidth: CGFloat = 0
        /// 当前承载的消息 id / 类型（展开/折叠局部刷新定位用）
        private(set) var hostedMessageID: UUID?
        private(set) var hostedKind: String = ""

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.clipsToBounds = true
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            contentView.clipsToBounds = true
        }

        func applyContent(_ content: AnyView, key: String?, bypass: Bool = false, width: CGFloat,
                          messageID: UUID? = nil, kind: String = "") {
            self.heightKey = key
            self.bypassMeasure = bypass
            self.containerWidth = width
            self.hostedMessageID = messageID
            self.hostedKind = kind
            configGeneration &+= 1
            // 内容已换：清掉上一配置的测量缓存，强制重新测量
            lastComputedHeight = nil
            lastComputedWidth = nil
            lastMeasureTime = nil
            verifiedHeight = nil
            verifiedKey = nil
            // P32:统一忽略底部安全区——聊天页沉浸布局(.ignoresSafeArea bottom)使
            // collectionView 延伸到屏幕底,屏内 cell 的 safeAreaInsets.bottom=34
            // (home indicator),UIHostingView 布局/测量会把底部安全区计入高度
            // (实测 real−probe=34.0pt 精确吻合,iPhone 15 Pro),导致 probe 测的
            // seed 比屏内渲染需求少 31pt → cell 高度不足 → 文本底部被裁(折叠成…)。
            // 在 hosting 内容统一忽略:probe/复用池(安全区=0)不受影响,
            // 屏内 cell 布局回到内容纯高 → 三环境测量一致,seed=渲染,零折叠。
            contentConfiguration = UIHostingConfiguration {
                content.ignoresSafeArea(.container, edges: .bottom)
            }
            .margins(.all, 0)
            if (width > 0 && width != loggedWidth) || (key != loggedKey) {
                loggedWidth = width
                loggedKey = key
                AppLogger.shared.info("[List] cell.configure: containerW=" + String(format: "%.1f", width)
                    + " key=" + (key ?? "nil") + " bypass=" + (bypass ? "1" : "0") + " kind=" + kind, category: "List")
            }
        }

        override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
            guard let attrs = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else { return layoutAttributes }
            // 上报自身内容 key（P5）：写回高度必须绑定「正在测量的内容」，
            // 不能用全局 contentKeyByIndex（异步回报与 apply 更新错位 → 跨指纹污染）。
            if let layout = (superview as? UICollectionView)?.collectionViewLayout as? MessageListLayout,
               let key = heightKey {
                layout.noteHeightKey(key, at: attrs.indexPath.item)
            }
            // 宽度：containerWidth（按容器实际宽传入）优先，不信任布局估计帧宽
            var width = containerWidth
            if width <= 0 || width.isInfinite {
                if let cv = superview as? UICollectionView, cv.bounds.width > 0 {
                    width = cv.bounds.width - cv.contentInset.left - cv.contentInset.right
                } else if layoutAttributes.frame.width > 0 {
                    width = layoutAttributes.frame.width
                } else {
                    width = UIScreen.main.bounds.width
                }
            }
            // 1) 短窗口去重：同一配置同一帧的重复询问直接返回
            if let h = lastComputedHeight, let w = lastComputedWidth, let t = lastMeasureTime,
               abs(width - w) < 1, CACurrentMediaTime() - t < Self.measureDedupWindow {
                attrs.frame.size = CGSize(width: width, height: h)
                return attrs
            }
            // 2) 预置高度：从布局层按内容 key 记忆查询（此时宽度已解析为真实容器宽；
            //    复用 cell 免重新测量。configure 时 cellWidth 可能还是 0（滚动期间
            //    无 apply），所以不能在 configure 里查——那会导致 key 宽度后缀对不上、
            //    seed 永远 miss、每次复用全量重测（「点击思考指示器卡顿」根因）。
            if !bypassMeasure, let key = heightKey,
               let layout = (superview as? UICollectionView)?.collectionViewLayout as? MessageListLayout,
               let seed = layout.measuredHeight(forKey: key, width: width), seed > 0 {
                // P34:seed 为内容纯高,屏内渲染需求 = seed + 安全区加成
                let h = seed + layout.safeAreaPad
                // P29:首测核实——已核实同 key 同高 → 免测返回(滚动复用零成本);
                // 未核实 → 实测一次与 seed 比对,差异大用实测(触发重排修正高度),
                // 差异小(≤4pt)记核实用 seed(免重排抖动)。
                if verifiedKey == key, verifiedHeight == h {
                    attrs.frame.size = CGSize(width: width, height: h)
                    return attrs
                }
                contentView.layoutIfNeeded()
                contentView.layoutIfNeeded()
                let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
                let real = max(contentView.systemLayoutSizeFitting(
                    target,
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height, 1)
                let useReal = abs(real - h) > 4
                verifiedHeight = useReal ? real : h
                verifiedKey = key
                if useReal {
                    AppLogger.shared.info("[List] seedMismatch seed=" + String(format: "%.1f", h)
                        + " real=" + String(format: "%.1f", real)
                        + " env: cell.safeArea=(" + String(format: "%.1f", self.safeAreaInsets.top)
                        + "," + String(format: "%.1f", self.safeAreaInsets.bottom)
                        + ") cellW=" + String(format: "%.1f", self.bounds.width)
                        + " cvSafeBottom=" + String(format: "%.1f", (superview as? UICollectionView)?.safeAreaInsets.bottom ?? -1)
                        + " key=" + key, category: "List")
                }
                attrs.frame.size = CGSize(width: width, height: useReal ? real : h)
                return attrs
            }
            // 3) 实测：宽度 required 锁死换行，高度自适应。
            //    两遍 layoutIfNeeded：SwiftUI 长文本首遍布局可能未完成换行计算，
            //    单遍测量会拿到不完整高度（同一 key 两次测量 909→3037 的跳动来源）。
            contentView.layoutIfNeeded()
            contentView.layoutIfNeeded()
            let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
            let size = contentView.systemLayoutSizeFitting(
                target,
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            let h = max(size.height, 1)
            lastComputedHeight = h
            lastComputedWidth = width
            lastMeasureTime = CACurrentMediaTime()
            attrs.frame.size = CGSize(width: width, height: h)
            AppLogger.shared.info("[List] measure w=" + String(format: "%.1f", width)
                + " h=" + String(format: "%.1f", h)
                + " key=" + (heightKey ?? "nil") + " bypass=" + (bypassMeasure ? "1" : "0"), category: "List")
            return attrs
        }
    }

}

final class BlockFactoryBox: @unchecked Sendable {
    let makeHeader: (ChatMessage) -> AnyView
    let makeBlock: (ChatMessage, AssistantSegment) -> AnyView
    let makeFooter: (ChatMessage) -> AnyView
    init(_ header: @escaping (ChatMessage) -> AnyView,
         _ block: @escaping (ChatMessage, AssistantSegment) -> AnyView,
         _ footer: @escaping (ChatMessage) -> AnyView) {
        self.makeHeader = header
        self.makeBlock = block
        self.makeFooter = footer
    }
}
