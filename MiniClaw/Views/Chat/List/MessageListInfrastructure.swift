//
// MessageListInfrastructure.swift
// MiniClawApp
//
// Shared types for the collection-view-based chat message list.
// Shared infrastructure types used by the message list.
// MarkdownView walks the view hierarchy
// looking for `NoAnimationCollectionView` and `SelfSizingCell`.
//

import Combine
import SwiftUI
import UIKit

public enum MessageListItem: Hashable, @unchecked Sendable {
    case wholeMessage(UUID)
    /// The "sparkles MiniClaw" label row at the top of an assistant turn.
    case assistantHeader(UUID)
    case assistantBlock(UUID,UUID) // (messageId, blockId)
    case assistantFooter(UUID)

    var messageId: UUID {
        switch self {
        case .wholeMessage(let id),.assistantHeader(let id),
             .assistantFooter(let id): return id
        case .assistantBlock(let msgId,_): return msgId
        }
    }
}

final class CellStateBridge: ObservableObject {
    @Published var isActiveMessage: Bool = false
    @Published var commandStartTime: Date?
    @Published var onStop: (() -> Void)?
    @Published var onRetry: (() -> Void)?
    @Published var onEdit: (() -> Void)?
    @Published var onWithdraw: (() -> Void)?
    /// 排队消息「立即发送」回调:中断当前回复并立即发送(2026-08-10 新增)。
    @Published var onSendQueued: (() -> Void)?
    @Published var autoRetryAttempt: Int = 0
    @Published var autoRetryCountdown: Int = 0
    @Published var canResume: Bool = false
    @Published var onResume: (() -> Void)?
    @Published var onCompact: (() -> Void)?
    @Published var onForceSync: (() -> Void)?
    @Published var onCopyScreenshot: (() -> Void)?
    @Published var onReadAloud: (() -> Void)?
    /// Speak an arbitrary text snippet (the
    /// selection-menu "Read Selection" action) via the MiniClaw TTS stack.
    @Published var onSpeakText: ((String) -> Void)?
    @Published var isStreaming: Bool = false
    @Published var browserPool: MiniClawTabPool?
    @Published var toolSnapshots: [ToolSnapshotItem] = []
    @Published var detailBlock: AssistantBlock?
    @Published var showUsage: Bool = false
    @Published var usageContentVisible: Bool = false
    var onShowCompactSummary: ((String) -> Void)?
}

/// 顶栏总高（状态栏 + 导航栏）的**稳定常量**。
///
/// 用途：顶部磨砂（第三版）要求列表**穿过顶栏**（内容才能滑到栏下、系统才会换栏背景），
/// frame 一穿过，首条消息就必须让开这一段 = `contentInset.top`。
///
/// [2026-09-14] 取值纪律（与本文件 :81-92 记的事故同源）：
/// **必须是"不切换的常量"** —— 只在方向变化/首次出现时刷新，其余时间沿用旧值。
/// 反面教材：用「容器瞬时安全区」当数据源 ⇒ 入口转场期它在 116 ↔ 0 之间切换 ⇒
/// `.never` 下 UIKit 逐帧补偿 `contentOffset` ⇒ 整屏位移。故这里只在"真的有窗口、
/// 且值落在合理区间"时接受新值，异常值一律丢弃（宁可沿用旧常量）。
enum TopBarInset {
    /// `nonisolated(unsafe)`：Swift 6 对"可变的静态状态"一律报错。这里显式声明**只由主线程读写**：
    /// 写点只有 VC 生命周期（均在主线程），读点是主线程上的布局数学与 SwiftUI body ⇒ 无竞态。
    nonisolated(unsafe) private(set) static var height: CGFloat = 0

    static func refresh(from vc: UIViewController) {
        guard vc.view.window != nil else { return }
        // 顶栏底边在**窗口坐标**里的位置 = 状态栏 + 导航栏高度（正是"CV 缺失的覆盖量"）。
        let navBar = vc.navigationController?.navigationBar
        let barBottom = navBar.map { $0.convert($0.bounds, to: nil).maxY } ?? 0
        let candidate = max(barBottom, vc.view.safeAreaInsets.top)
        guard candidate > 20, candidate < 200 else { return }   // 未布局 / 异常值：不采纳
        guard abs(candidate - height) > 0.5 else { return }
        height = candidate
    }
}

public final class MessageListViewController: UIViewController {
    public var collectionView: UICollectionView!
    public var messageListLayout: MessageListLayout!
    /// 关联的 Coordinator(键盘高度等运行时状态读取,2026-08-11 新增)。
    public weak var messageListCoordinator: MessageCollectionView.Coordinator?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        messageListLayout = MessageListLayout()
        messageListLayout.itemSpacing = 8
        let cv = NoAnimationCollectionView(frame: view.bounds,collectionViewLayout: messageListLayout)
        cv.owningViewController = self
        collectionView = cv
        // [2026-09-13 撤销] 恢复 CV 自己跟随容器 bounds（原行为）。曾改为 Auto Layout 约束并把底边
        // 上移 34pt，导致小横条区域露出背景、键盘顶起距离变化 —— 已撤销。
        collectionView.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .onDrag
        collectionView.alwaysBounceVertical = true
        // [T2 修正 2026-09-12 · 单一所有权 + 常量数据源]
        // 「重进会话首次上滑整屏弹」的位移源 = 容器 `safeAreaInsets.top` 在 116 ↔ 0 之间切换，
        // UIKit 按 `adjustedContentInset` 变化自动补偿 `contentOffset`（同一 CV、frame 不变、
        // 我们的代码不动）。两件事必须同时成立才能根治：
        //   ① `.never` —— 留白只由 App 决定，UIKit 不介入补偿；
        //   ② 数据源为**不切换的量** —— 顶部留白 = `appBaseContentInsetTop`（iOS26+ 为 0）。
        // 曾用「容器瞬时安全区」当数据源（会切）或用 `navBar.frame.maxY`(=116) 当留白
        // （那是导航栏在窗口中的位置，而稳态 `safeAreaInsets.top == 0` 已证明 CV 的 frame
        // 本就在导航栏下方 ⇒ 留白本就应为 0），后者会多出 116pt 空白。
        // `.never` 下底部安全区由 CV 的**底边约束**让出（见下方 `bottomAnchor`），
        // 不再叠加进 `contentInset.bottom` —— 同一份留白只能有一处。
        collectionView.contentInsetAdjustmentBehavior = .never
        view.addSubview(collectionView)

        // [2026-09-13 撤销·勿重犯] 曾把 CV 底边**缩短 34pt**（钉在 `view.bottomAnchor` − 常量），
        // 目的是避开「cell 底边落入 CV 最后 34pt 时被 UIKit 授予安全区，宿主自 sizing 把它计进高度」
        // 造成的 ±34 污染。**已撤销**，因为它付出了不该付的代价：
        //   ① 底部 34pt 不再被 CV 覆盖 ⇒ **小横条区域重新露出容器背景**（这是唐唐此前特意去掉的）；
        //   ② 因此改变了键盘顶起时内容上推的距离。
        // 现恢复 CV **全幅铺到底**（原行为），污染改由 **cell 内部**把安全区归零来解决
        // （见 `SelfSizingCell.safeAreaInsets`），不再触碰 CV 几何。
        // 历史错路（勿再回头）：`.ignoresSafeArea()` 加在 hosting 内容上无效；`contentView
        //   .insetsLayoutMarginsFromSafeArea = false` 无效（margin 非载体）；`viewDidLayoutSubviews`
        //   里改 frame 会引发布局循环（真机 = 首页极卡顿）；`safeAreaLayoutGuide.bottomAnchor`
        //   会被键盘撑大（CV 高度塌 340pt、offset 不动 ⇒ 整屏跳位）。
    }

    /// [2026-09-14 顶部磨砂·第三版] 顶部留白的数据源 = `TopBarInset`（常量、只在方向变化时刷新）。
    /// `viewWillAppear` **早于首次布局**，可以避开入口转场期"瞬时安全区在 116 ↔ 0 之间切换"那个窗口。
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        TopBarInset.refresh(from: self)
    }

    /// 只读刷新 + 把注册补上（`setContentScrollView` 要在 parent 链完整后才有效）。
    /// **只读**——这里绝不动 frame（历史事故：`viewDidLayoutSubviews` 里改 frame 会引发布局循环）。
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        TopBarInset.refresh(from: self)
        // `TopBarInset` 变化后立刻同步给 CV，避免"下一帧才补上"造成首条消息被顶栏盖住一帧。
        // 用 `.never` 下"直接赋值 + 不锚定"的既有口径（该常量本就不切换，无需锚定）。
        if let cv = collectionView, abs(cv.contentInset.top - TopBarInset.height) > 0.5 {
            cv.contentInset.top = TopBarInset.height
        }
        registerCollectionViewForNavBarScrollEdge()
    }

    /// [2026-09-14 顶部磨砂·第三版 · 本方案的核心一步] 把本页的 collection view **注册给导航栏**，
    /// 让**系统**自己去切换栏的背景（这才是首页那层"玻璃"的真正来源）：
    ///   · 滚动到顶部 / 栏下没有内容 ⇒ 栏用 `scrollEdgeAppearance` = **透明** ⇒ 直接映射背景色（纯黑/纯白）
    ///   · 内容滑到栏下 ⇒ 栏用 `standardAppearance` = **材质** ⇒ 内容隐约透出来
    ///
    /// 为什么必须手工注册：首页是 SwiftUI `List`，导航栈能自动发现它并盯住它的滚动位置；
    /// 而本页列表是藏在 representable 里的 UIKit `UICollectionView`，**SwiftUI 的导航栈看不见它**
    /// ⇒ 不注册的话系统永远不会切换栏背景：静止时透明（看起来"没有效果"）、
    /// 内容滑过时也依然透明（标题直接压在**未模糊**的内容上）。
    ///
    /// 另一个坑：驱动栏的是**导航栈最上层**的 VC（SwiftUI 的宿主 VC），不是本层子 VC，
    /// 所以要沿 `parent` 链上溯到第一个拿得到 `navigationController` 的那一层再调。
    private func registerCollectionViewForNavBarScrollEdge() {
        guard let cv = collectionView else { return }
        var vc: UIViewController? = self
        while let cur = vc, cur.navigationController == nil { vc = cur.parent }
        guard let owner = vc else { return }
        if owner.contentScrollView(for: .top) !== cv {
            owner.setContentScrollView(cv, for: .top)
        }
    }

    /// scrolls them back into view the MarkdownTextView is hosted
    public override func viewWillTransition(to size: CGSize,with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size,with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.messageListLayout?.invalidateLayout()
            self.collectionView?.layoutIfNeeded()
        },completion: { [weak self] _ in
            self?.prewarmVisibleCellsAfterWidthChange()
        })
    }

    ///
    /// 1. Device / size-class rotation — `viewWillTransition`'s completion.
    /// 2. Sidebar collapse / expand (and any other NavigationSplitView detail
    /// column-width change) — `NoAnimationCollectionView.layoutSubviews`
    /// detects the bounds-width change and schedules this. That path has
    /// no UIKit transition coordinator, so before this hook the cells were
    /// only re-measured lazily as the user scrolled them in — the source
    /// of the iPad rotate→portrait→collapse scroll jank
    /// (T-ios-ipad-rotate-collapse-scroll-jank, GitHub #31 / #570).
    ///
    public func prewarmVisibleCellsAfterWidthChange() {
        guard let cv = collectionView else { return }
        for cell in cv.visibleCells {
            // SelfSizingCell's own lastCalcH survives until reuse).
            (cell as? SelfSizingCell)?.clearCachedHeight()
            _ = Self.invalidateTableAttachmentsInSubviews(of: cell)
        }
        messageListLayout?.invalidateLayout()
    }

    /// MarkdownTextView, then invalidates each TableAttachment in
    private static func invalidateTableAttachmentsInSubviews(of view: UIView) -> Int {
        var count = 0
        if let tv = view as? MarkdownTextView,let storage = tv.textStorage as? NSTextStorage,storage.length>0 {
            storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { value,range,_ in
                if let table = value as? TableAttachment {
                    table.invalidateCachedLayoutForWidthChange()
                    count += 1
                    if let lm = tv.layoutManager as? MiniClawLayoutManager {
                        lm.invalidateLayout(forCharacterRange: range,actualCharacterRange: nil)
                    }
                }
            }
            tv.setNeedsLayout()
            tv.invalidateIntrinsicContentSize()
        }
        for sub in view.subviews {
            count += invalidateTableAttachmentsInSubviews(of: sub)
        }
        return count
    }
}

/// Cell state bridge: per-message published state driving list cells.
final class NoAnimationCollectionView: UICollectionView {
    var isApplyingSnapshot = false

    // [2026-09-13 死代码清理] 原处有 `var streamingGrowAnimationEnabled = true`：
    // 全库仅「此处声明 + 下方读取」两处，**无任何写入点** ⇒ 恒真、永不可配 —— 是死开关。
    // 读取点已按"恒真"内联（该分支本意即"只在流式期走 grow 动画"）。

    /// Reentrancy guard: the grow path calls
    private var inStreamGrow = false

    weak var owningViewController: MessageListViewController?

    /// `lastBounds` so the prewarm path compiles in every configuration.
    ///
    private var lastPreWarmW: CGFloat = 0

    /// [恢复 2026-09-13] **稳定的底部安全区**（home indicator）：优先取 **window** 的值
    /// （键盘不会改 window，容器瞬时态才会 ⇒ 用 window 才不会随键盘跳动）。
    /// 曾随「CV 底边上移」一并删除，撤销后必须还原（`bottomPadVal` 依赖它）。
    var stableBottomSafeArea: CGFloat {
        if let w = window, w.safeAreaInsets.bottom > 0 { return w.safeAreaInsets.bottom }
        return safeAreaInsets.bottom
    }

    /// [抖动诊断 2026-09-12] CV 的 **frame.origin** 上一次的值。
    /// 既有 `[WatchdogProbe][cv-bounds]` 只在**尺寸**变化时打；**位置**变化不打 —— 而
    /// 「整屏内容一起小幅上下弹」正是「CV 自身被移动」的典型表现（尺寸不变、位置在动）。

    #if DEBUG
    private var lastBounds: CGSize = .zero
    private static let watchdogProbe = AppLogger(category: "ChatList.Watchdog")
    #endif

    override func layoutSubviews() {

        guard !isApplyingSnapshot else { return }
        guard UIApplication.shared.applicationState != .background else {
            return
        }
        guard window != nil else { return }

        #if DEBUG
        let newSize = bounds.size
        let widthChanged = abs(newSize.width-lastBounds.width)>0.5
        let heightChanged = abs(newSize.height-lastBounds.height)>0.5
        if widthChanged || heightChanged {
            let visibleCount = visibleCells.count
            Self.watchdogProbe.info("[WatchdogProbe][cv-bounds] \(widthChanged ? "W" : " ")\(heightChanged ? "H" : " ") old=\(Int(lastBounds.width))x\(Int(lastBounds.height)) new=\(Int(newSize.width))x\(Int(newSize.height)) visibleCells=\(visibleCount) tracking=\(isTracking ? 1 : 0) decel=\(isDecelerating ? 1 : 0)")
            lastBounds = newSize
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif

        // Animate ONLY while a message is actively
        let isStreamingNow = (collectionViewLayout as? MessageListLayout)?.streamingCellIndex != nil

        // Only animate when the content actually
        let scrollableRange = contentSize.height-bounds.height+adjustedContentInset.bottom
        let contentOverflowsViewport = scrollableRange>1

        if isTracking || isDecelerating {
            super.layoutSubviews()
        } else if isStreamingNow,contentOverflowsViewport,
                  !isApplyingSnapshot,!inStreamGrow {
            // The smooth-streaming trick, done right:
            //
            // streaming one (the "MiniClaw" header) drift — the header↔body spacing
            //
            inStreamGrow = true
            defer { inStreamGrow = false }

            let preOffset = contentOffset
            var finalOffset = preOffset
            UIView.performWithoutAnimation {
                super.layoutSubviews()
                finalOffset = self.contentOffset
            }
            let delta = finalOffset.y-preOffset.y
            if delta.isFinite && finalOffset.y.isFinite && abs(delta)>0.5 {
                // [抖动诊断 2026-09-12] 只在本分支**真的触发 offset 动画**时打（低频）。
                // 本分支会用 0.2s 动画**主动改 contentOffset**；若「并非真正流式」时
                // `streamingCellIndex` 仍非 nil（状态陈旧），就会在手指间隙反复触发 ⇒ 可见抖动。
                // 真机判据：抖动若源于此，日志将成串出现本行；且 `tracking=0 decel=0`。
                AppLogger.shared.info(
                    "[ScrollGrow] animateOffset \(String(format: "%.1f", preOffset.y))→\(String(format: "%.1f", finalOffset.y)) delta=\(String(format: "%+.1f", delta)) tracking=\(isTracking ? 1 : 0) decel=\(isDecelerating ? 1 : 0) streamingIdx=\((collectionViewLayout as? MessageListLayout)?.streamingCellIndex.map(String.init) ?? "nil") contentH=\(String(format: "%.0f", contentSize.height))",
                    category: "ScrollGrow")
                setContentOffset(preOffset,animated: false)
                UIView.animate(withDuration: 0.20,
                               delay: 0,
                               options: [.curveEaseOut,.beginFromCurrentState,.allowUserInteraction]) {
                    self.setContentOffset(finalOffset,animated: false)
                }
            } else if finalOffset.y.isFinite && finalOffset.x.isFinite && finalOffset != contentOffset {
                // [2026-09-09 NaN 治理] 上面动画分支判了限性，这里原本没判：
                // finalOffset 一旦含 inf/NaN 就落进本分支并被**无条件**写进
                // contentOffset，UIKit 用 `bounds.origin = -contentOffset` 算可见
                // 矩形时 inf-inf 得到 NaN → CoreGraphics 告警。NaN/inf 一律跳过。
                setContentOffset(finalOffset,animated: false)
            }
        } else {
            UIView.performWithoutAnimation {
                super.layoutSubviews()
            }
        }

        // Front-load the visible-cell
        let w = bounds.width
        if w>0,abs(w-lastPreWarmW)>0.5,!isTracking,!isDecelerating,!isApplyingSnapshot {
            lastPreWarmW = w
            DispatchQueue.main.async { [weak self] in
                self?.owningViewController?.prewarmVisibleCellsAfterWidthChange()
            }
        }

        #if DEBUG
        let elapsed = (CFAbsoluteTimeGetCurrent()-t0)*1000
        if elapsed >= 200 {
            Self.watchdogProbe.warning("[WatchdogProbe][cv-layout] slow layoutSubviews elapsed=\(String(format: "%.1f", elapsed))ms visibleCells=\(visibleCells.count) bounds=\(Int(newSize.width))x\(Int(newSize.height)) widthChanged=\(widthChanged ? 1 : 0)")
        }
        #endif
    }

    override func scrollRectToVisible(_ rect: CGRect,animated: Bool) {
    }

    var offsetLocked: Bool = false

    override func setContentOffset(_ contentOffset: CGPoint,animated: Bool) {
        if offsetLocked {
            let delta = abs(contentOffset.y-self.contentOffset.y)
            if delta>1 {
                return
            }
        }
        super.setContentOffset(contentOffset,animated: animated)
    }

    /// Tracks whether a MarkdownTextView currently has an active text selection.
    var hasActiveTextSelection: Bool = false

    //
    // UITextView's native
    //
    //

    private static let selectionAutoScrollEdgeInset: CGFloat = 80
    private static let selectionAutoScrollStep: CGFloat = 12

    private var selectionAutoScrollLink: CADisplayLink?
    ///
    /// Stores the full point (not just
    private var selectionDragTouchPoint: CGPoint?

    /// Called by the active MarkdownTextView while its selection-handle
    func updateSelectionAutoScroll(touchPoint: CGPoint) {
        selectionDragTouchPoint = touchPoint
        guard hasActiveTextSelection,selectionAutoScrollDirection(forTouchY: touchPoint.y) != 0 else {
            stopSelectionAutoScroll()
            return
        }
        if selectionAutoScrollLink == nil {
            let link = CADisplayLink(target: self,selector: #selector(stepSelectionAutoScroll))
            link.add(to: .main,forMode: .common)
            selectionAutoScrollLink = link
        }
    }

    func stopSelectionAutoScroll() {
        selectionAutoScrollLink?.invalidate()
        selectionAutoScrollLink = nil
        selectionDragTouchPoint = nil
        onAutoScrollStep = nil
    }

    private func selectionAutoScrollDirection(forTouchY touchY: CGFloat) -> CGFloat {
        guard bounds.height>0 else { return 0 }
        let topThreshold = bounds.minY+Self.selectionAutoScrollEdgeInset
        let bottomThreshold = bounds.maxY-Self.selectionAutoScrollEdgeInset
        if touchY<topThreshold {
            if contentOffset.y <= -adjustedContentInset.top+0.5 { return 0 }
            return -1
        }
        if touchY>bottomThreshold {
            let maxOffset = max(-adjustedContentInset.top,
                                contentSize.height-bounds.height+adjustedContentInset.bottom)
            if contentOffset.y >= maxOffset-0.5 { return 0 }
            return 1
        }
        return 0
    }

    @objc private func stepSelectionAutoScroll() {
        guard hasActiveTextSelection,let touchPoint = selectionDragTouchPoint else {
            stopSelectionAutoScroll(); return
        }
        let dir = selectionAutoScrollDirection(forTouchY: touchPoint.y)
        guard dir != 0 else { stopSelectionAutoScroll(); return }
        let maxOffset = max(-adjustedContentInset.top,
                            contentSize.height-bounds.height+adjustedContentInset.bottom)
        let proposed = contentOffset.y+dir*Self.selectionAutoScrollStep
        let clamped = min(max(proposed,-adjustedContentInset.top),maxOffset)
        // Already at the content
        guard abs(clamped-contentOffset.y)>0.5 else { stopSelectionAutoScroll(); return }
        setContentOffset(CGPoint(x: contentOffset.x,y: clamped),animated: false)
        onAutoScrollStep?(touchPoint)
    }

    var onAutoScrollStep: ((CGPoint) -> Void)?
}

class SelfSizingCell: UICollectionViewCell {
    /// [2026-09-13] **让 cell 永不感知窗口底部安全区**。
    ///
    /// 这是「±34 污染」在**不触碰 CV 几何**前提下的替代修法。陈因：CV 全幅铺到屏幕底时它自身
    /// `safeAreaInsets.bottom == 34`，凡是**底边落入这最后 34pt** 的 cell 都会被 UIKit 授予同样的
    /// 底部安全区，而 `UIHostingConfiguration` 的宿主自 sizing 会**把它原样计进 cell 高度**
    /// （真机实证 `[JITTER] delta ≡ cvSafeB`，20/20 条严格同值）⇒ 相邻块凭空多出间距、且随滚动位置变化。
    ///
    /// 曾用「把 CV 底边上移 34pt」来规避，但代价是**小横条区域露出容器背景**（唐唐此前特意去掉的）
    /// 且改变了键盘顶起距离 ⇒ 已撤销。此处改从**入口**切断：cell 内容本就不该为窗口安全区预留空间
    /// （底部留白由 CV 的 `contentInset.bottom` 统一负责）。若 UIKit 不采纳此覆写也不会更差 ——
    /// 回到与覆写前完全相同的行为。
    override var safeAreaInsets: UIEdgeInsets { .zero }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        contentView.clipsToBounds = true
    }

    /// Incremented each time contentConfiguration is applied. Used by
    private var cfgGen: UInt = 0

    private var lastCalcH: CGFloat?

    /// `lastCalcH` 是在哪个宽度下测得的。**去重判据只看宽度**：宽度变了就必须重测。
    private var lastCalcW: CGFloat?

    /// CACurrentMediaTime() of the last successful self-measure。**仅诊断用**。
    ///
    /// [2026-09-12] 它原先还参与「50ms 内复用缓存」的判据（`measureDedupWindow`），该判据已删除：
    /// 宽度匹配的缓存不会因「旧」而失效，时间窗只制造额外的 view-graph 重入（FB13213926 崩溃窗口）。
    /// 字段照旧在 seed/smooth/live 三处写入、在 applyContentConfiguration / clearCachedHeight /
    /// prepareForReuse 三处清空，供日志与断点判断「最后一次真实测量是什么时候」。
    private var lastMeasureMedia: CFTimeInterval?

    /// markdown 块在 cell 内的**固定垂直装饰**（不含文本本身）：`AssistantBlockView` 的
    /// `.padding(.vertical, 2)` × 2 = 4pt，与 `seedHeight` 的 `setPrecalcHeight(height+4)`、
    /// `estimateItemHeight` 的 `uH+4` 同源；此前该值散落在多处硬编码，收敛到此处单点定义。
    /// 用途：`preferredLayoutAttributesFitting` 的引擎下限 = 屏上文本实测 + 本值。
    static let assistantBlockVerticalChrome: CGFloat = 4

    /// Pre-seeded height from the layout's
    /// measured on a previous appearance. Unlike `lastCalcH`, this is
    ///
    private var seedH: CGFloat?
    private var seedW: CGFloat?

    /// Stable content key for the item this
    var contentKey: String?

    /// [2026-09-12 裁尾修复·引擎实测文本高] 屏上 `MarkdownTextView` 自测出的**文本高度**
    /// （不含 cell 装饰）。由 `invalidateCellSizeIfChanged` 单调取大写入，
    /// `preferredLayoutAttributesFitting` 提交时用 `本值 + assistantBlockVerticalChrome`
    /// 作为下限。
    ///
    /// 为什么必须只依赖它（而不含 cell 当前高度）：cell 被抬高后 **SwiftUI 不会跟着抬高
    /// 文本视图**（真机实证：cell 1365→1455 期间 `bounds.height` 恒为 1361）。任何把
    /// 「cell 当前高」计入增量的公式都会每轮再叠一次差值 → **跑飞**（实测 1365→1383→1401
    /// →1419→1437→1455，消息中间出现大块空白）。本值只来自视图自身测量，增量恒定 ⇒ 收敛。
    var engineTextHeight: CGFloat = 0
    /// 该实测值是在**哪个内容键**下取得的。PLAF 只在 `本字段 == 当前 contentKey` 时应用下限。
    ///
    /// 为什么不能只看 `contentKey != nil`：`configureCell` 对流式 cell 会显式把
    /// `contentKey` 置 nil，于是「非 nil」守卫恰好把**流式 cell**（最需要下限的地方）
    /// 全部挡掉 —— 真机实证：`UNDER-HEIGHT` 48 条而 `HOST-FLOOR` 0 条，流式末句被截
    /// 且下一轮更新才自愈。改为键相等判定后，流式时两侧同为 nil 亦成立；而 cell 被
    /// 重新配置成别的条目时键不等 → 不套用上一内容的实测（防虚高）。
    var engineTextContentKey: String?
    var engineTextValid: Bool = false

    /// [抖动诊断 2026-09-12] 上一次提交的高度 + 对应的完整内容键。
    /// **按 key 变化重置**（不挂在 `applyContentConfiguration`：滑动时每 pass 都重新配置，
    /// 会每次清零导致探针恒不触发 —— 真机实证 0 条）。
    private var jitterPrevH: CGFloat = 0
    private var jitterPrevKey: String?

    #if DEBUG
    /// Stable content-hash identity (set by
    var metricsTag: String?
    #endif

    func seedMeasuredHeight(_ height: CGFloat,width: CGFloat) {
        guard height >= 4,width>1 else { return }
        seedH = height
        seedW = width
        traceSet("configureCell→seed", height, width)
    }

    func applyContentConfiguration(_ config: any UIContentConfiguration) {
        contentConfiguration = config
        cfgGen &+= 1
        lastCalcH = nil
        lastCalcW = nil
        lastMeasureMedia = nil
        // Drop any prior seed — content just
        seedH = nil
        seedW = nil
        // [2026-09-12 裁尾修复] 引擎文本实测属于「上一版内容」的值，必须与 lastCalcH/seedH
        // 同生命周期清零，否则会把旧内容的最小高度带给新内容（→ 空白）。
        engineTextHeight = 0
        engineTextContentKey = nil
        engineTextValid = false
        // [Single height source] 同理：cell 被**就地重配**到另一块内容时（流式追加 / reconfigureItems /
        // 只重配受影响行），上一版内容提交的高度/指纹/宽度必须一并作废 —— 否则正文侧的三道校验里
        // 只剩"内容指纹"一道是真正内容级的（宽度与高度都是旧值），防线退化。
        // 生命周期与上面几个字段一致（此前只在 `prepareForReuse` 清零，属遗漏）。
        committedTextHeight = 0
        committedFingerprint = 0
        committedTextWidth = 0
    }

    private static let sizingLogger = AppLogger(category: "ChatList.CellMetrics")

    /// [PLAF 诊断 2026-09-12] 只读探针：标记本次 cell 高度来自哪条短路分支。
    /// 用于定位「cell 提交高度恒为 1703.0 而实测 1711.3 → 尾部半行被裁」。
    /// 只读、不写任何状态，不可能引发循环；定位完成后删除。
    private func tracePLAF(_ branch: String,_ h: CGFloat,_ w: CGFloat,_ reqW: CGFloat? = nil) {
        #if DEBUG
        // [2026-09-13 P0 降噪] 同 `traceSet`：挂到 `logs/.scroll-metrics-on` 哨兵。
        // 本函数在 PLAF 的每个分支上各打一行，属最热路径之一；默认静默，
        // 需要细查时放哨兵即可恢复全量（含 `[JITTER]` 专报）。
        ScrollMetricsRecorder.shared.ensureEnabledChecked()
        guard ScrollMetricsRecorder.shared.isEnabled else { return }
        #endif
        let r = reqW.map { String(format: " reqW=%.1f", $0) } ?? ""
        let full = contentKey ?? "nil"
        // key 放宽到 90 字符：`b:<mid>:<bid>:<n>` 全长 > 76，截断到 20 就看不到内容长度 `n`，
        // 而「内容在两版之间来回」正是抖动的一种根因 —— 必须能看到 n。
        Self.sizingLogger.info("[PLAF] branch=\(branch) h=\(String(format: "%.1f", h)) w=\(String(format: "%.1f", w))\(r)\(Self.scrollPhaseTag(from: self)) key=\(String(full.prefix(90)))")
        // [抖动专报 2026-09-12 修正版] **按内容键变化重置**（旧版挂在 applyContentConfiguration，
        // 而滑动时每个 pass 都重新配置 cell ⇒ 每次清零 ⇒ 永远没有「上一次」可比 ⇒ 0 条）。
        // 不再限制在 drag/decel：真机实证该抖动在 `scroll=idle off=0` 时同样发生。
        // [2026-09-14 误报修复] **流式 cell 没有内容身份可比** —— 它的 `contentKey` 恒为 nil
        //（内容每 chunk 都在变，长度是刻意排除的），于是 `full` 恒为 "nil" ⇒
        // `jitterPrevKey == full` 恒成立 ⇒ **每一次正常的流式增长都被判成抖动**。
        // 真机实录（G26 装机后）：25 条 `[JITTER]` 的高度序列**严格单调递增**（32→79.3→245.7
        // →…→1036.3，与内容增长同步），全属误报 —— 与 skill「先怀疑探针」同一条教训。
        // 修法：只有**存在内容键**时才做比较（键 = "同一版内容"的身份，nil 不构成身份）。
        // `else` 分支照旧写 `jitterPrevKey`，故从 nil 段切到真实键时不会跨段比较。
        if contentKey != nil,jitterPrevKey == full {
            if jitterPrevH > 1, abs(h - jitterPrevH) > 0.5 {
                // [±34 归因探针 2026-09-12] 真机实证「同一 key 高度恰好差 34.0」（34 = home
                // indicator 安全区高）。假设：cell 落入底部安全区带时，其 contentView 的
                // safeAreaInsets.bottom 变 34，而宿主 SwiftUI 自 sizing 把它计进了内容高。
                // 三者必须同时打印才能证伪：`cvSafeB`（cell 实际看到的底部安全区）、
                // `cellBot`（cell 底边在 CV 内容坐标中的位置）、`cvH`（CV 视口高）。
                // 若 `cvSafeB` 与 h 的 +34 同相 ⇒ 假设成立；若恒为 0 ⇒ 另寻来源。
                let cvSafeB: CGFloat
                let cvMarginB: CGFloat
                let cellBot: CGFloat
                let cvH: CGFloat
                if let cv = self.superview as? UICollectionView {
                    cvSafeB = self.contentView.safeAreaInsets.bottom
                    // `UICollectionViewCell.contentView.insetsLayoutMarginsFromSafeArea` 默认 true：
                    // 落在 home indicator 区带的 cell，其 layoutMargins.bottom 会被自动 +34，
                    // 任何锚到 layoutMarginsGuide 的约束即多 34pt。这是自 sizing 的经典坑。
                    cvMarginB = self.contentView.layoutMargins.bottom
                    cellBot = self.frame.maxY - cv.contentOffset.y
                    cvH = cv.bounds.height
                } else {
                    cvSafeB = -1; cvMarginB = -1; cellBot = -1; cvH = -1
                }
                Self.sizingLogger.warning("[JITTER] key=\(full) prevH=\(String(format: "%.1f", jitterPrevH)) newH=\(String(format: "%.1f", h)) delta=\(String(format: "%+.1f", h - jitterPrevH)) branch=\(branch)\(Self.scrollPhaseTag(from: self)) cvSafeB=\(String(format: "%.1f", cvSafeB)) cvMarginB=\(String(format: "%.1f", cvMarginB)) cellBot=\(String(format: "%.1f", cellBot)) cvH=\(String(format: "%.1f", cvH))")
            }
        } else {
            jitterPrevKey = full
        }
        jitterPrevH = h
    }

    /// [抖动诊断 2026-09-12] 滚动状态标签。抖动 = **滑动期间**同一 cell 被反复提交不同高度，
    /// 故必须把「当时是否在拖动/惯性」写进台账，才能从日志里筛出滑动窗口内的震荡序列。
    /// 取 cpuType 无开销；只读。
    static func scrollPhaseTag(from view: UIView) -> String {
        guard let cv = view.superview as? UICollectionView else { return " scroll=none" }
        let phase = cv.isDragging ? "drag" : (cv.isDecelerating ? "decel" : "idle")
        return " scroll=\(phase) off=\(Int(cv.contentOffset.y))"
    }

    /// [PLAF 写入台账 2026-09-12] 记录每个「高度缓存被写入」的时刻与当时的宽度，
    /// 用于定位「height 在宽度 A 测出、却在宽度 B 被使用」的张冠李戴。
    /// 只读、不写状态。
    ///
    /// [2026-09-13 空白定位] 增补 `idx` 与**内容键尾部**：原键被 `prefix(20)` 截断，
    /// 恰好切掉了 `b:<mid>:<bid>:<n>` 里的 `:n`（内容长度），而「小内容配大高度」
    /// （如 `:4` 的块拿到 1000+ 高度）正是「消息中间大块空白」的判别特征。
    private func traceSet(_ src: String,_ h: CGFloat,_ w: CGFloat) {
        #if DEBUG
        // [2026-09-13 P0 降噪] 挂到工程既有的哨兵开关（`logs/.scroll-metrics-on`，
        // 见 `ScrollMetricsRecorder.refreshFromSentinel`）。此探针**无差别**打在高度热路径上
        // （每次 cell 配置/测量各一行，实测 12 分钟 15k 行 `ChatList.CellMetrics`），把真异常
        // （UNDER-HEIGHT / HOST-FLOOR / SEED-FLOOR）淹掉——这是"定位不到根因"的直接原因之一。
        // 哨兵不存在 ⇒ 静默（默认）；`devicectl copy to` 放入哨兵 ⇒ 全量明细。
        ScrollMetricsRecorder.shared.ensureEnabledChecked()
        guard ScrollMetricsRecorder.shared.isEnabled else { return }
        #endif
        let idxTag = (superview as? UICollectionView)?.indexPath(for: self).map { " idx=\($0.item)" } ?? ""
        let keyTag = contentKey.map { "\($0.prefix(14))…\($0.suffix(8))" } ?? "nil"
        Self.sizingLogger.info("[PLAF-SET] src=\(src) h=\(String(format: "%.1f", h)) w=\(String(format: "%.1f", w))\(Self.scrollPhaseTag(from: self))\(idxTag) key=\(keyTag)")
    }


    /// [Single height source] 本 cell **已提交**的正文高度（= cell 提交高 − assistantBlockVerticalChrome）。
    /// 正文侧（`MarkdownView.sizeThatFits`）读它并原样返回 ⇒ 宿主据此写 textView 的 frame ⇒
    /// 「cell 高度」与「正文 view 高度」**同源**，不再是两条链各自取数、互相追。
    /// 0 = 尚未提交（正文侧走正常测量）。
    private(set) var committedTextHeight: CGFloat = 0
    /// 上面那个值对应的**内容指纹**（`ContentFingerprint.of(rawMarkdown)`，`Int`）。
    /// 硬前提：cell 复用后旧值**绝不能**被当成新内容的高度（历史事故：跨 cell 累积 495pt）。
    private(set) var committedFingerprint: Int = 0
    /// 上面那个值对应的**内容宽度**（正文可用宽）。高度与宽度都相关，宽度变了旧值不可用。
    private(set) var committedTextWidth: CGFloat = 0
    /// 只有**助手正文块**才允许把 cell 高度反推为正文高度。
    /// 用户气泡同样内嵌 `MarkdownTextView`，但其 cell 高度含气泡内边距，直接反推会每帧叠加而跑飞。
    /// 由 `configureCell` 按块类型每次重设（不残留）。
    var commitsTextHeightAsCellContent = false

    /// [Single height source] **唯一**的高度提交出口：写 cell 高度，并把「正文部分高度 + 内容指纹」
    /// 记为权威值供正文侧回灌。
    /// ⚠️ 这里**绝不写 textView 的 frame** —— frame 物理上由 SwiftUI hosting 每次重排时按
    /// `MarkdownView.sizeThatFits` 的返回值写入，手写会被同帧改回（历史事故形状：跨 cell 累积 495pt）。
    @discardableResult
    private func commitHeight(_ h: CGFloat, into attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attrs.size.height = h
        guard commitsTextHeightAsCellContent,
              let tv = firstMarkdownTextView(in: contentView) else { return attrs }
        let textHeight = h - Self.assistantBlockVerticalChrome
        if textHeight > 1 {
            committedTextHeight = textHeight
            committedFingerprint = ContentFingerprint.of(tv.rawMarkdown)
            committedTextWidth = tv.bounds.width > 1 ? tv.bounds.width : tv.textContainer.size.width
        }
        return attrs
    }

    /// 在 contentView 子树里找正文视图（广度优先，命中即停）。
    private func firstMarkdownTextView(in root: UIView) -> MarkdownTextView? {
        var queue: [UIView] = [root]
        var head = 0
        while head < queue.count {
            let v = queue[head]
            head += 1
            if let tv = v as? MarkdownTextView { return tv }
            queue.append(contentsOf: v.subviews)
        }
        return nil
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        // [2026-09-12 去重判据收紧] 缓存命中**只按宽度匹配**判定，取消原先的 50ms 时间窗。
        //
        // 判据：宽度仍匹配的缓存高度**不会因为「旧」而失效**。所有真正的失效都是**显式**的 ——
        // `applyContentConfiguration`（换内容）、`prepareForReuse`（复用）、`clearCachedHeight`
        // （异步图片/重排/字体变化）三处都无条件把 `lastCalcH` 置 nil，无遗漏。
        // 所以时间窗买不到任何正确性，只在**已静止的界面**上买来更多
        // `super.preferredLayoutAttributesFitting` 重入 —— 而那条路径正是 FB13213926
        // 崩溃窗口（本项目亦多次命中）。`lastMeasureMedia` 保留为诊断字段（照旧写、照旧清）。
        if let cached = lastCalcH,
           let cachedW = lastCalcW,
           abs(layoutAttributes.size.width-cachedW)<1 {
            let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
            copy.size.width = cachedW
            _ = commitHeight(cached, into: copy)
            tracePLAF("dedup", cached, cachedW, layoutAttributes.size.width)
            return copy
        }

        //
        //
        // neither write lastCalcH nor mutate the height (which previously
        guard superview is UICollectionView,window != nil,contentConfiguration != nil else {
            tracePLAF("guard-fail", layoutAttributes.size.height, layoutAttributes.size.width)
            return layoutAttributes
        }

        // [2026-09-12 裁尾修复·引擎实测下限] 只在「实测时的内容键 == 当前内容键」时成立。
        // 流式 cell 的 contentKey 恒为 nil（configureCell 显式置 nil）⇒ 两侧同为 nil 也成立，
        // 故流式 cell 同样受下限保护（此前用「非 nil」守卫把流式全挡掉，导致流式末句被截、
        // 下一轮更新才自愈）。cell 被重新配置成别的条目时键不等 → 不套用旧实测（防虚高）。
        let engineFloor: CGFloat = {
            guard engineTextValid, engineTextContentKey == contentKey, engineTextHeight > 0 else { return 0 }
            return engineTextHeight + Self.assistantBlockVerticalChrome
        }()

        // A. non-streaming cells ALSO short-circuit while streaming is
        // active (their content isn't changing mid-stream; an in-place
        // change like an async image load clears the cache via
        // clearCachedHeight() and falls through to a live measure);
        // B. the streaming cell itself returns the layout's precalc height —
        // the real-TextKit-engine calibration reseeded on every chunk,
        // i.e. the exact value prepare() already laid out — so per-chunk
        // growth stays graph-free too. Cells without a precalc (tool
        // capsules, thinking, footer) keep the live measure; the
        // stream-end settle (ranges cleared → guards inert) re-measures
        // everything authoritatively.
        if let cv = superview as? UICollectionView,
           let layout = cv.collectionViewLayout as? MessageListLayout {
            let item = layoutAttributes.indexPath.item
            let streamingActive = layout.hasActiveStreaming
            let isStreamingItem = streamingActive && layout.isStreamingCell(item)
            if layout.deferSelfSizing || streamingActive,
               !isStreamingItem,
               let cached = lastCalcH,let cachedW = lastCalcW,
               abs(layoutAttributes.size.width-cachedW)<1 {
                // 仅实测（lastCalcH）短路。**禁止回退 contentKey memo**（2026-09-08
                // 排版叠加回归）：后台渲染完成后 content 未变 → contentKey 不变 →
                // memo 命中渲染前的旧高度 → 真实高度被永久压制 → 全列表排版叠加。
                // 当前测量本身便宜（与屏上渲染同源的 MarkdownTextView），实测不再昂贵。
                let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
                copy.size.width = cachedW
                _ = commitHeight(max(cached, engineFloor), into: copy)
                tracePLAF("defer-cached", copy.size.height, cachedW, layoutAttributes.size.width)
                return copy
            }
            if isStreamingItem,
               // 只短路在 precalc 来源上（种子循环每个 chunk 重播种的
               // TextKit 校准值）。合并字典后 cachedHeight 对任意来源返回值，
               // 不加来源判定会把首帧陈旧估高当 precalc 返回并跳过实测——
               // 流式 cell 冻结在首帧高度，正文与下方内容重叠（2026-09-05 回归）。
               // 无 precalc（工具胶囊/思考块/footer）保持实测，与旧
               // precalcHeights 字典语义一致。
               layout.hasPrecalcHeight(at: item),
               let precalc = layout.cachedHeight(at: item) {
                let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
                // [2026-09-12 裁尾修复] 流式 cell 走这条短路；precalc 由每个 chunk 重新播种，
                // 但播种值可能滞后于引擎实测（含附件块尤其），故同样取引擎下限。
                _ = commitHeight(max(precalc, engineFloor), into: copy)
                tracePLAF("precalc", copy.size.height, layoutAttributes.size.width, layoutAttributes.size.width)
                return copy
            }
        }

        // Seed short-circuit: this cell was
        // Promote the seed to lastCalcH so the broad/window caches
        //
        if let sh = seedH,let sw = seedW,
           let cv = superview as? UICollectionView,
           abs(cv.bounds.width-sw)<1 {
            seedH = nil
            seedW = nil
        // [2026-09-12 裁尾修复] 播种值可能比引擎实测矮（同内容下播种源自
        // block.cachedAttributedString，渲染路径对含附件块会重新渲染；真机 1361 vs 1379）。
        // 播种短路会跳过一切实测，故必须在此取引擎下限 = 文本实测 + 固定装饰。
        // 守卫 `contentKey != nil`：未登记内容键的 cell（复用/过渡态）其 engineTextHeight
        // 可能属于**上一个内容**（真机 `[PLAF] HOST-FLOOR … key=nil` 与
        // `UNDER-HEIGHT cellH=91.3 textNeed=184.7` 即此类），用之抬升会虚高。
        let engineMinCell = engineFloor
            let seededH = max(sh, engineMinCell)
            if seededH > sh + 0.5 {
                Self.sizingLogger.info("[PLAF] SEED-FLOOR seed=\(String(format: "%.1f", sh))→\(String(format: "%.1f", seededH)) textH=\(String(format: "%.1f", engineTextHeight)) key=\(contentKey ?? "nil") — 播种值低于引擎实测，按同源下限抬高")
            }
            lastCalcH = seededH
            lastCalcW = layoutAttributes.size.width
            lastMeasureMedia = CACurrentMediaTime()
            traceSet("seed→lastCalc", seededH, layoutAttributes.size.width)
            let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
            _ = commitHeight(seededH, into: copy)
            tracePLAF("seed", seededH, layoutAttributes.size.width, layoutAttributes.size.width)
            return copy
        }

        var hostingSubtree: [UIView] = []
        Self.collectSubtree(self.contentView,into: &hostingSubtree)
        var superAttrs: UICollectionViewLayoutAttributes = layoutAttributes
        let superOk = noff_try_objc {
            withExtendedLifetime(hostingSubtree) {
                superAttrs = super.preferredLayoutAttributesFitting(layoutAttributes)
            }
        }
        if !superOk {
            Self.sizingLogger.info("[CellSizing] ⚠️ super.preferredLayoutAttributesFitting threw — using fallback height")
            if let cached = lastCalcH {
                let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
                _ = commitHeight(cached, into: copy)
                tracePLAF("super-throw-cached", cached, copy.size.width)
                return copy
            }
            tracePLAF("super-throw-none", layoutAttributes.size.height, layoutAttributes.size.width)
            return layoutAttributes
        }
        let attrs = superAttrs
        // 内容配置代际：`applyContentConfiguration` 每次换内容就 +1。**同一 gen 内
        // 内容未变**，是判定「实测值可信度」的依据（见下方 smooth 分支的塌行守卫）。
        let gen = cfgGen

        if let cached = lastCalcH,
           abs(layoutAttributes.size.width-attrs.size.width)<1 {
            // [2026-09-11 崩溃修复] super.PLAF 的 hosting 实测与 NegMeasure 家族
            // 同源——可能返回损坏值（2026-09-09 真机实录 -40，EXC_BAD_ACCESS 同在
            // ViewGraphGeometryObservers.needsUpdate）。损坏值原被 cached 短路掩盖；
            // 放行分支必须同样拦截：非有限/负值一律弃用实测、维持 cached。
            let measured = attrs.size.height
            guard measured.isFinite,measured >= 0,cached.isFinite,cached >= 0 else {
                _ = commitHeight(max(cached.isFinite ? cached : 0,0), into: attrs)
                tracePLAF("nonfinite-clamp", attrs.size.height, attrs.size.width, layoutAttributes.size.width)
                return attrs
            }
            // [回看裁剪修复 2026-09-10] lastCalcH 只做 ≤2pt 微差平滑；实测与缓存差
            // >2pt（典型=块内容离屏期间原地增长）放行真实高度，并推进 lastCalcH
            // 让短窗 dedup(:401) 与后续 pass 读到新值，避免振荡。
            if abs(measured-cached) > 2 {
                // [2026-09-12 用户气泡塌行修复] 同一内容配置（gen 未变）内，宿主实测
                // **小于**已知高度时**不得采纳**。真机实证：用户气泡是
                // `HStack { Spacer(minLength: 60); Text }`，SwiftUI 的「理想尺寸」pass 会以
                // 不受约束的宽度量该 Text → 19 个字排成 1 行（48.0），而真实约束下是
                // 2 行（67.7）；此前直接采纳 → 气泡边滑边塌成一行（IMG_4695/4697，
                // `[PLAF] smooth h=48.0` 与 `[PLAF] seed h=67.7` 反复交替）。
                // 判据只用**同内容内**的已知值（不涉及跨内容代际的量差，故不会像
                // engineMinHeight 那样算出荒谬偏移）：同内容内高度只会增长，
                // 真正变短必然换 contentKey（key 含内容长度 `w:<mid>:<n>:<a>`）
                // → 新内容走 applyContentConfiguration 重置 → 本守卫自然失效。
                if measured < cached - 2, cfgGen == gen {
                    _ = commitHeight(cached, into: attrs)
                    tracePLAF("smooth-keep-shorter", cached, attrs.size.width, layoutAttributes.size.width)
                    return attrs
                }
                lastCalcH = measured
                lastMeasureMedia = CACurrentMediaTime()
                traceSet("smooth→lastCalc(lastCalcW未更新)", measured, -1)
            } else {
                _ = commitHeight(cached, into: attrs)
            }
            tracePLAF("smooth", attrs.size.height, attrs.size.width, layoutAttributes.size.width)
            return attrs
        }

        let targetSize = CGSize(width: layoutAttributes.size.width,height: UIView.layoutFittingCompressedSize.height)
        let start = CACurrentMediaTime()
        //
        //
        var fittingSize = CGSize(width: targetSize.width,height: attrs.size.height)
        let measureOk = noff_try_objc {
            withExtendedLifetime(hostingSubtree) {
                fittingSize = self.contentView.systemLayoutSizeFitting(
                    targetSize,
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                )
            }
        }
        if !measureOk {
            Self.sizingLogger.info("[CellSizing] ⚠️ systemLayoutSizeFitting threw — using fallback height \(String(format: "%.0f", attrs.size.height))")
            return attrs
        }
        let elapsed = (CACurrentMediaTime()-start)*1000
        let sinceAppear = (CFAbsoluteTimeGetCurrent()-MessageListModel.onAppearTimestamp)*1000
        let idx = (superview as? UICollectionView)?.indexPath(for: self)?.item ?? -1
        // [Stall] Only log measurements that actually cost time. Streaming
        let est = layoutAttributes.size.height
        let fit = fittingSize.height
        #if DEBUG
        // Record EVERY self-size (no cost/delta
        if let cv = superview as? UICollectionView {
            let phase = cv.isDecelerating ? "decel" : (cv.isTracking ? "drag" : "idle")
            ScrollMetricsRecorder.shared.record(
                kind: "measure", idx: idx, a: est, b: fit,
                key: contentKey ?? "",
                src: lastCalcH == nil ? "first" : "re",
                pos: phase,offset: cv.contentOffset.y,
                note: String(format: "%.1fms", elapsed),
                tag: metricsTag ?? "")
        }
        #endif
        if elapsed >= 5 {
            Self.sizingLogger.info("[SessionLoad] sizing idx=\(idx) \(String(format: "%.1f", elapsed))ms T+\(String(format: "%.0f", sinceAppear))ms est=\(String(format: "%.0f", est))→\(String(format: "%.0f", fit))")
        }
        if elapsed>50 {
            let cfg = self.contentConfiguration
            let cfgKind = cfg.map { String(describing: type(of: $0)) } ?? "nil"
            Self.sizingLogger.info("[CellSizing] ⚠️ SLOW MEASURE \(String(format: "%.0f", elapsed))ms idx=\(idx) width=\(String(format: "%.0f", layoutAttributes.size.width)) est=\(String(format: "%.0f", layoutAttributes.size.height))→\(String(format: "%.0f", fittingSize.height)) cfg=\(cfgKind)")
        }
        #if DEBUG
        // [Decel] Log every measure that happens during an active scroll
        if elapsed >= 3,let cv = superview as? UICollectionView,cv.isDecelerating || cv.isDragging {
            let cfgKind = self.contentConfiguration.map { String(describing: type(of: $0)) } ?? "nil"
            let phase = cv.isDecelerating ? "decel" : "drag"
            let firstTime = (lastCalcH == nil) ? "FIRST" : "recompute"
            Self.sizingLogger.info("[Decel][cell-measure] phase=\(phase) \(firstTime) idx=\(idx) cost=\(String(format: "%.1f", elapsed))ms est=\(String(format: "%.0f", est))→\(String(format: "%.0f", fit)) offset=\(String(format: "%.0f", cv.contentOffset.y)) cfg=\(cfgKind)")
        }
        #endif
        if layoutAttributes.size.height<4 && fittingSize.height>20 {
            Self.sizingLogger.info("[TextDrift] ⚠️ CELL GREW FROM ~0: idx=\(idx) \(String(format: "%.0f", layoutAttributes.size.height))→\(String(format: "%.0f", fittingSize.height))pt — potential text overlap during this transition")
        }
        guard cfgGen == gen else {
            tracePLAF("cfggen-changed", attrs.size.height, attrs.size.width)
            return attrs
        }
        // [NegMeasure 2026-09-10] SwiftUI hosting 在「思考块收起 + 同帧子代理活动卡
        // 更新」时会返回**负测量值**（真机实测 -40，崩溃现场 idx=44 est=340→pref=-40，
        // EXC_BAD_ACCESS in ViewGraphGeometryObservers.needsUpdate）。负高度一旦回流
        // 进高度体系再喂回 SwiftUI hosting 会二次损坏 ViewGraph。此处 clamp 到 0 并
        // 用上一有效高度兜底；不缓存负值（下方 >=4 的守卫本来就不收）。
        let clampedFit: CGFloat
        if !fittingSize.height.isFinite || fittingSize.height < 0 {
            let fallback = max(lastCalcH ?? 0, 0)
            Self.sizingLogger.warning("[CellSizing] REJECT neg/inf measure \(String(format: "%.0f", fittingSize.height))→\(String(format: "%.0f", fallback)) idx=\(idx)（SwiftUI hosting 损坏测量，负高度防御）")
            clampedFit = fallback
        } else {
            clampedFit = fittingSize.height
        }
        // [2026-09-12 裁尾修复·引擎实测下限] 宿主实测（SwiftUI hosting 的
        // systemLayoutSizeFitting）**不得低于屏上渲染引擎实测所需**。
        // 下限 = `engineTextHeight`（屏上 MarkdownTextView 自测的文本高，**只取该值本身**）
        //        + `assistantBlockVerticalChrome`（固定装饰常量）。
        // **绝不含「cell 当前高」**：cell 被抬高后 SwiftUI 不会跟着抬高文本视图
        // （真机：cell 1365→1455 期间 bounds.height 恒 1361），任何含 cell 当前高的公式
        // 都会每轮再叠一次差值 → 跑飞（1365→1383→1401→1419→1437→1455，中间大块空白）。
        // 本式增量恒定 ⇒ 必然收敛。守卫 `contentKey != nil` 防复用态用旧内容实测虚抬。
        let engineMinCell = engineFloor
        let flooredFit = engineMinCell > 0 ? max(clampedFit, engineMinCell) : clampedFit
        if flooredFit > clampedFit + 0.5 {
            Self.sizingLogger.info("[PLAF] HOST-FLOOR idx=\(idx) host=\(String(format: "%.1f", clampedFit))→\(String(format: "%.1f", flooredFit)) textH=\(String(format: "%.1f", engineTextHeight)) key=\(contentKey ?? "nil") — 宿主实测低于引擎实测，按同源下限抬高")
        }
        _ = commitHeight(flooredFit, into: attrs)
        if fittingSize.height >= 4 {
            lastCalcH = flooredFit
            lastCalcW = layoutAttributes.size.width
            lastMeasureMedia = CACurrentMediaTime()
            traceSet("live→lastCalc req=\(String(format: "%.1f", layoutAttributes.size.width)) actual=W", flooredFit, fittingSize.width)
            // Memoize the real height under the
            if let key = contentKey,
               let cv = superview as? UICollectionView,
               let layout = cv.collectionViewLayout as? MessageListLayout {
                layout.recordMeasuredHeight(forKey: key,height: flooredFit,boundsWidth: cv.bounds.width)
            }
        }
        // [2026-09-12 删除死代码] 此处原有 `#if DEBUG` 的 `MessageListSnapshotCollector
        // .captureIfEnabled(from:trigger:triggerDetail:)` 调用，而该类型**在整个工程里已不存在**
        //（2026-09-16 复核：`git grep -n MessageListSnapshotCollector -- .` 仅命中本注释自身）。
        // ⚠️ 但原文后半句「工程的 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 里从来没有 `DEBUG` 定义
        // ⇒ 所有 `#if DEBUG` 从未参与编译」**是错的，已删除**：`project.pbxproj:2317` 的 Debug
        // 配置是 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG ISH_ENABLED"` ⇒ `DEBUG` **有**定义，
        // 全部 `#if DEBUG` 参与编译（这也是当前所有布局探针能生效的前提）。
        // ⚠️ 真正需要警惕的是相反方向：`project.yml:34-35` 只声明了 `["ISH_ENABLED"]`，与
        // pbxproj **不一致**。按纪律 B4 不跑 `xcodegen generate`（它会产出编不过的工程），
        // 但一旦有人跑了，Debug 的 `DEBUG` 会消失 ⇒ 约 46 处 `#if DEBUG` 整块静默消失
        //（含 ScrollMetricsRecorder、metricsTagByIndex 与布局 Stage 0 全部探针）。
        tracePLAF("live", attrs.size.height, attrs.size.width, layoutAttributes.size.width)
        return attrs
    }

    private static func collectSubtree(_ view: UIView,into out: inout [UIView]) {
        out.append(view)
        for sub in view.subviews {
            collectSubtree(sub,into: &out)
        }
    }

    func clearCachedHeight() {
        lastCalcH = nil
        lastCalcW = nil
        lastMeasureMedia = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        lastCalcH = nil
        lastCalcW = nil
        lastMeasureMedia = nil
        // [Single height source] 复用即作废权威值 —— 绝不让上一个内容的提交高被当成新内容的高度
        //（历史事故形状：跨 cell 累积 495pt）。正文侧另有指纹校验兜底，这里是第一道。
        commitsTextHeightAsCellContent = false
        committedTextHeight = 0
        committedFingerprint = 0
        committedTextWidth = 0
    }
}
