import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

private final class AssistantBlockCell: SelfSizingCell {}
private final class WholeMessageCell: SelfSizingCell {}
private struct BridgedAssistantHeader: View {
    @ObservedObject var message: RenderMessage
    var maxWidth: CGFloat = 0
    @State private var soulMeta: SoulMetadata = SoulStore.cachedMetadata
    var body: some View {
        HStack(spacing: 6) {
            // 2026-08-10 用户要求:AI 名字前的星星改为 emoji ✨(原 sparkles SF 符号)。
            Text("✨")
                .font(.system(size: 18))
            Text(soulMeta.name.isEmpty ? "MiniClaw" : soulMeta.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(ChatColors.primaryText)
        }
        .legibleTextShadow()
        .padding(.top,4)
        .padding(.bottom,0)
        .frame(maxWidth: .infinity,alignment: .leading)
        .frame(maxWidth: maxWidth>0 ? maxWidth : .infinity,alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal,16)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantHeader")
    }
}

/// No GeometryReader — UIKit self-sizing is the sole height source.
extension MessageCollectionView {

    /// Scroll mode: the only two states the list needs.
    public enum ScrollMode {
        case autoScrolling
        case userBrowsing
    }

    public final class Coordinator: NSObject,UICollectionViewDelegate,UIScrollViewDelegate,UICollectionViewDataSourcePrefetching {
        // ── 状态存储（结构重组：自扩展文件归位）──
        /// When a snapshot is deferred (e.g. streaming UI updates suspendedFlag),
        var pendingSnapshotFlag: Bool = false

        let nearBottomThreshold: CGFloat = 20

        ///
        let reacquireAutoScrollThreshold: CGFloat = 4

        public var lastJumpedUserId: UUID?

        /// contentInset.bottom — it reads this base and adds overflowH.
        public var baseBottomInset: CGFloat = 0

        private var keyboardDismissPan: UIPanGestureRecognizer?

        /// 键盘展开时：禁用列表自身的拖动，改由本手势接管——
        /// 识别到任意滑动就收起键盘（走正常动画路径），不滚动内容。
        /// 之所以不用 `isScrollEnabled = false`：那会在手势中途打断，
        /// 表现为键盘和内容"啪"地瞬间掉下去（用户 04:00 实测无动画）。
        func installKeyboardDismissPan(on cv: UICollectionView) {
            guard keyboardDismissPan == nil else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleKeyboardDismissPan(_:)))
            pan.cancelsTouchesInView = false
            // [2026-11-16 04:03] 默认必须禁用：装上即参与识别会抢走列表拖动 ⇒ 整页不能滑。
            pan.isEnabled = false
            cv.addGestureRecognizer(pan)
            keyboardDismissPan = pan
        }

        @objc private func handleKeyboardDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard keyboardHeight > 0 else { return }
            if gesture.state == .began {
                AppLogger.shared.info("[Scroll] keyboard up pan → dismiss keyboard (no scroll)",
                                      category: "ChatList.Keyboard")
                onRequestDismissKeyboard?()
            }
        }

        /// 键盘展开时用户试图拖动列表 → 请求宿主收起键盘（不滚动）。
        public var onRequestDismissKeyboard: (() -> Void)?

        /// 用户是否停在底部（持续维护；只在拖动/惯性期间更新）。
        /// 键盘事件只读它，不在回调里临时计算——那时 bounds 可能已被压缩，算了也是错的。
        var lastKnownPinned: Bool = true

        /// 键盘遮挡高度。[2026-11-16 视口单源] 由键盘通知写入，直接进 inset 公式。
        /// 旧实现按 `kbUp ? 0 : …` 做减法（假设列表被系统压缩），真机 cvH 恒 874 证明没有压缩。
        public var keyboardHeight: CGFloat = 0
        /// 键盘弹起**之前**用户是否贴在底部（来自 lastKnownPinned 的快照）。
        private var preKeyboardPinned: Bool?
        /// 键盘弹起前一刻的列表高度（用于准确推算压缩后的底边）。
        private var preKeyboardBoundsHeight: CGFloat?


        private var keyboardObserver: NSObjectProtocol?

        /// 观察键盘：只记录"键盘遮挡了多少"，不在这里改 offset（改 offset 由 inset 变化统一驱动）。
        func startKeyboardObservation() {
            guard keyboardObserver == nil else { return }
            keyboardObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                      let cv = self.viewController?.collectionView,
                      let window = cv.window else { return }
                let newH = max(0, window.bounds.maxY - window.convert(frame, from: nil).minY)
                // [2026-11-16] 必须在 **bounds 收缩之前** 记录用户是否贴底：
                // 键盘一弹，cvH 874→546，maxOff 立刻增大 328，事后再判 isNearBottom 必然为 false
                // ⇒ 之前"补一次贴底"永远不执行，表现为"输入法弹出但消息不动"。
                if newH > self.keyboardHeight {
                    // 只读持续维护的状态，不在此时计算（此时 bounds 可能已被压缩）。
                    self.preKeyboardPinned = self.lastKnownPinned
                    // [2026-11-16 04:09] 同时记下**压缩前**的高度：目标 offset 必须用它算，
                    // 否则若 SwiftUI 已经缩过，再减一次 overlap ⇒ 目标过高 ⇒ 先冲上去再被兜底拉回。
                    self.preKeyboardBoundsHeight = cv.bounds.height
                }
                self.keyboardHeight = newH
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? -1
                let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? -1
                AppLogger.shared.info(
                    "[Keyboard] height=\(String(format: "%.0f", self.keyboardHeight)) dur=\(String(format: "%.3f", duration)) curve=\(curve) focused=\(self.lastInputFocused ? 1 : 0) cvH=\(String(format: "%.0f", cv.bounds.height))",
                    category: "ChatList.Keyboard")
                // [2026-11-16 03:38] 弹出时必须**直接**重算 inset：
                // 第二次弹键盘时焦点没变化 ⇒ SwiftUI 不重绘 ⇒ updateUIViewController 不跑
                // ⇒ inset 停在上一次的值（真机日志：第二次没有 [ChatUI] 行，仍是 103）。
                //
                // [2026-11-16 03:41] 收起时**不能立刻改**：那一刻列表还在放大，
                // 先改 inset 会让 UIKit 按旧 bounds 调整 offset，随后 0.3s 补贴底再改一次
                // ⇒ 收起时可见"抖一下"（弹出时不抖，因为方向相反、两步落在同一侧）。
                // 收起改为等动画结束、一次性完成 inset + 贴底，且不带动画。
                // [2026-11-16 03:50] 两条收起路径唯一的差别是 **焦点是否变化**
                // （下滑=0、点外面=1，日志实证），而 inset 的硬改没有动画衔接，
                // 所以只有"点外面"这条路看得出抖。
                // 统一：inset 变化跟随系统键盘动画（dur/curve 取自通知），两条路径一致。
                // [2026-11-16 03:51 回退] 把 inset 包进键盘动画会让两条路径都抖
                // （与系统自己的 offset 调整叠加）。退回"延迟一次性、不带动画"：
                // 下滑收起时这条是顺的，点外面另从**焦点同步**解决。
                // 键盘展开：列表 pan 关闭、专用手势启用（滑动＝收键盘）；
                // 键盘收起：反过来。两者始终互斥，避免平时抢走滚动。
                let kbUp = newH > 0
                self.viewController?.collectionView.panGestureRecognizer.isEnabled = !kbUp
                self.keyboardDismissPan?.isEnabled = kbUp
                if newH > 0 {
                    self.applyInsetForKeyboardState()
                    // [2026-11-16 04:14] 立即开始、只做一次：
                    // 目标用「压缩前高度 − 键盘高度」算，不依赖此刻 bounds 是否已缩
                    // ⇒ 既不用等 0.3s（慢半拍），也不会重复减一次（冲一下）。
                    self.animatePinForKeyboard(overlap: newH, duration: duration, curve: curve)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, let cv = self.viewController?.collectionView else { return }
                        UIView.performWithoutAnimation {
                            self.applyInsetForKeyboardState()
                            if self.preKeyboardPinned ?? self.lastKnownPinned {
                                self.scrollToBottomNow(animated: false)
                                self.lastKnownPinned = true
                            } else if cv.contentOffset.y > cv.contentSize.height {
                                cv.contentOffset.y = max(0, cv.contentSize.height - cv.bounds.height)
                            }
                        }
                    }
                }
            }
        }

        /// 键盘态直接重算底部留白（与 updateUIViewController 同一公式，不依赖重绘）。
        private func applyInsetForKeyboardState() {
            guard let cv = viewController?.collectionView else { return }
            let safe = (cv as? NoAnimationCollectionView)?.stableBottomSafeArea ?? cv.safeAreaInsets.bottom
            let base = inputBarHeightCache + floatingBarHeightCache + 8
                + (keyboardHeight > 0 ? 0 : safe)
            AppLogger.shared.info(
                "[ChatUI] kb-path inset=\(String(format: "%.0f", base)) kb=\(String(format: "%.0f", keyboardHeight)) bar=\(String(format: "%.0f", inputBarHeightCache))",
                category: "ChatList.Keyboard")
            if abs(cv.contentInset.bottom - base) > 0.5 {
                cv.contentInset.bottom = base
                baseBottomInset = base
            }
        }

        /// inset 变化后：贴底就重新贴底（键盘顶起内容 = 用户要的行为）。
        /// 键盘弹出时把内容**动画**顶上去（只动 offset，不动 inset）。
        /// 目标按"压缩后的高度"估算：此刻 bounds 还是旧值，用 overlap 预推。
        func animatePinForKeyboard(overlap: CGFloat, duration: Double, curve: Int) {
            guard let cv = viewController?.collectionView, keyboardHeight > 0,
                  preKeyboardPinned ?? lastKnownPinned else { return }
            // [2026-11-16 04:16] 不再依赖任何 bounds：键盘挡住多少，内容就上移多少。
            // 之前用「压缩前高度 − 键盘高度」算目标，但那一刻列表往往已被 SwiftUI 缩过，
            // 记录到的"压缩前高度"其实是压缩后的 ⇒ 再减一次 ⇒ 目标过高 ⇒ 冲高。
            // 现在只用两个稳定量：当前 offset + 键盘遮挡高度。
            let rawTarget = cv.contentOffset.y + overlap
            let hardLimit = max(0, cv.contentSize.height - 1)
            let target = min(rawTarget, hardLimit)
            AppLogger.shared.info(
                "[Keyboard] animate pin \(String(format: "%.0f", cv.contentOffset.y))→\(String(format: "%.0f", target)) dur=\(String(format: "%.3f", duration))",
                category: "ChatList.Keyboard")
            // [2026-11-16 04:11] 不用 UIView.animate 改 contentOffset：
            // 它与系统压缩列表的动画是两套，叠加后会出现"先冲高再回落"。
            // 改用 UIScrollView 自带的动画，UIKit 会按自己的几何/时间曲线处理。
            cv.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        }

        private func reapplyInsetAfterKeyboardChange() {
            // [2026-11-16 真机实测] 键盘弹起时 cvH 874→546：列表**已被系统压缩**，
            // 因此这里只按新的 bounds 补一次贴底，绝不把键盘高度再写进 inset（那是重复计入）。
            guard let cv = viewController?.collectionView else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let cv = self.viewController?.collectionView else { return }
                let shouldPin = self.preKeyboardPinned ?? self.lastKnownPinned
                AppLogger.shared.info(
                    "[Keyboard] repin cvH=\(String(format: "%.0f", cv.bounds.height)) prePinned=\(self.preKeyboardPinned.map(String.init) ?? "nil") nearBottom=\(self.isNearBottom(80)) → pin=\(shouldPin)",
                    category: "ChatList.Keyboard")
                guard shouldPin, !cv.isTracking, !cv.isDecelerating else { return }
                // [2026-11-16 04:13] 只动作一次且用 UIScrollView 自带动画：
                // 之前是"立即动画 + 0.3s 硬贴"两次动作，第二次在动画尾部硬拽一下 = 冲一下。
                let maxOff = cv.contentSize.height - cv.bounds.height + cv.contentInset.bottom
                guard maxOff > 0 else { return }
                cv.setContentOffset(CGPoint(x: 0, y: maxOff), animated: true)
                self.lastKnownPinned = true
            }
        }

        /// 最近一次由 SwiftUI 传入的两个高度（键盘回调里无法直接读 updateUIViewController 的入参）。
        fileprivate var inputBarHeightCache: CGFloat = 0
        fileprivate var floatingBarHeightCache: CGFloat = 0

        /// [Swift 6] `deinit` 是 nonisolated，而本类因服从 `UICollectionViewDelegate`（该协议在
        /// iOS 26 SDK 中为 `@MainActor`）被主线程隔离 ⇒ 无法从 `deinit` 访问隔离存储属性。
        /// 该链表的创建/失效**只在主线程**（`startDecelDisplayLink` / `stopDecelDisplayLink` 均由
        /// 滚动回调调用），故用 `nonisolated(unsafe)` 标注，让 `deinit` 里那一次 `invalidate()`
        /// 合法（它只是尽力清理；正常路径由 `stopDecelDisplayLink` 显式失效）。
        nonisolated(unsafe) var decelDisplayLink: CADisplayLink?

        var decelDLLastTimestamp: CFTimeInterval = 0

        var decelDLFrames: Int = 0

        var decelDLDrops: Int = 0

        var decelDLMinGapMs: Double = .infinity

        var decelDLMaxGapMs: Double = 0

        var decelDLExpectedMs: Double = 16.67

        /// settle 刚结束的窗口标记：内容收缩时由 contentSize KVO 主动 clamp
        /// （防 UIKit 硬 clamp 造成跳动）。属行为状态，不是日志开关。
        var settleJustFinished = false

        // [Decel] Deceleration-phase instrumentation. Lets us pin a
        var decelStartTime: CFTimeInterval = 0

        var decelStartOffset: CGFloat = 0

        var decelTargetOffset: CGFloat = 0

        var decelLastFrameTime: CFTimeInterval = 0

        var decelFrameCount = 0

        var decelSlowFrameCount = 0

        /// A frame gapH above this (seconds) during deceleration is a dropped
        let decelSlowFrameThreshold: CFTimeInterval = 0.032

        public var onRetryMessage: ((UUID) -> Void)?
        public var onRetryLast: (() -> Void)?
        public var onEdit: ((UUID) -> Void)?
        public var onWithdraw: ((UUID) -> Void)?
        /// 排队消息「立即发送」:中断当前回复并立即发送该条(2026-08-10 新增)。
        public var onSendQueued: ((UUID) -> Void)?
        public var onResume: (() -> Void)?
        public var onStop: (() -> Void)?
        public var onCompact: ((UUID) -> Void)?
        public var onRevertCompact: (() -> Void)?
        public var onForceSync: (() -> Void)?
        public var onScreenshotImage: ((UIImage) -> Void)?
        public var maxContentWidth: CGFloat = 0
        public var lastInputFocused: Bool = false

        /// [T1 2026-09-12] 转场期间被推迟的贴底请求（`nil` = 无；见 `scrollToBottomNow` 的说明）。
        var pendingEntryPin: Bool?

        /// [P5 2026-09-13] **冻结起始时刻**（`nil` = 当前未冻结）。仅供「冻结泄漏」兜底判定。
        ///
        /// 为什么需要它：冻结两轴（`MessageListLayout.deferSelfSizing` 与
        /// `MessageListModel.streamingUIUpdatesSuspended`）的**关闭点与开启点不在同一函数栈上** ——
        /// 开于 `scrollViewWillBeginDragging`，关于 `settleAfterInteraction`，而后者只在
        /// `scrollViewDidEndDragging(willDecelerate: false)` 与 `scrollViewDidEndDecelerating`
        /// 两处被调用。**`defer` 语法覆盖不到这种跨回调的生命周期**：只要这两个回调都没来
        /// （减速被程序化 `setContentOffset` 打断、转场、CV 被移除），冻结就永久滞留 ⇒
        /// 几何永不再收缩（拖动期空白不再自愈）+ 快照永不上屏。
        ///
        /// 判据见 `resetLeakedFreezeIfNeeded(_:)`：**冻结只在「正在手势或减速中」合法**。
        var freezeStartedAt: CFAbsoluteTime?

        #if DEBUG
        deinit {
            decelDisplayLink?.invalidate()
        }
        #endif

        // === Scroll mode（两态模型） ===
        public var scrollMode: ScrollMode = .autoScrolling {
            didSet {
                //
                viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            }
        }
        var flushingNow = false
        var isAnimatingScrollToBottom = false

        var messageIndex: [UUID: Int] = [:]
        var itemToIndex: [MessageListItem: Int] = [:]

        var prevSnapshotIds: [MessageListItem] = []
        /// 上一次 applySnapshot 时「整轮是否仍在跑」（用于检测整轮结束这一时刻，
        /// 触发最终回复块的重测——最终回复后面不接指示器，借不到那个节律）。
        var lastWasProcessing: Bool = false
        var snapshotMessages: [RenderMessage] = []

        var cellBridgeMap: [UUID: CellStateBridge] = [:]

        /// Caches accurate user-bubble

        var thinkingToggleSub: AnyCancellable?

        var attachmentSizeChangedSub: AnyCancellable?

        var contentLengthAtBackground: Int?

        var lastMessageId: UUID?
        var lastMessageSub: AnyCancellable?
        var lastMessageBlockCountSub: AnyCancellable?

        /// Last observed value of the vm's
        var lastSuspendedValue: Bool = false
        /// Watches the vm for the moment
        var suspendResumeSub: AnyCancellable?

        var lastStreamingLayoutTime: Date = .distantPast
        var pendingStreamingLayout: DispatchWorkItem?

        var pendingScrollWork: DispatchWorkItem?

        var clampAfterSessionLoad: Bool = false
        var clampDeadline: Date = .distantPast

        let sheetPresenter = ToolSheetPresenter()
        let compactSummaryPresenter = CompactSummaryPresenter()
        var sheetOverlayHost: UIHostingController<SheetOverlayView>?

        weak var viewController: MessageListViewController?
        weak var vm: MessageListModel?
        var dataSource: UICollectionViewDiffableDataSource<Section,MessageListItem>!
        var subscriptions = Set<AnyCancellable>()
        var contentSizeObservation: NSKeyValueObservation?
        /// [KbdDiag 2026-08-11] 观察 adjustedContentInset 变化(键盘弹出/收起时系统注入
        /// safeAreaInsets.bottom → adjustedContentInset 变化),打印键盘让位全链路证据。
        var adjustedInsetObservation: NSKeyValueObservation?

        public func attach(to vc: MessageListViewController,vm: MessageListModel) {
            self.viewController = vc
            self.vm = vm
            vc.messageListCoordinator = self
            vc.loadViewIfNeeded()
            guard let collectionView = vc.collectionView else { return }
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            // of one main-thread sample for a single offY-screen BIG-CELL.
            collectionView.isPrefetchingEnabled = false

            let wholeReg = UICollectionView.CellRegistration<WholeMessageCell,MessageListItem> {
                [weak self] cell,indexPath,item in
                self?.configureCell(cell,item: item,indexPath: indexPath)
            }
            let headerReg = UICollectionView.CellRegistration<AssistantHeaderCell,MessageListItem> {
                [weak self] cell,indexPath,item in
                self?.configureCell(cell,item: item,indexPath: indexPath)
            }
            let blockReg = UICollectionView.CellRegistration<AssistantBlockCell,MessageListItem> {
                [weak self] cell,indexPath,item in
                self?.configureCell(cell,item: item,indexPath: indexPath)
            }
            let footerReg = UICollectionView.CellRegistration<AssistantFooterCell,MessageListItem> {
                [weak self] cell,indexPath,item in
                self?.configureCell(cell,item: item,indexPath: indexPath)
            }

            dataSource = UICollectionViewDiffableDataSource<Section,MessageListItem>(
                collectionView: collectionView
            ) { cv,indexPath,item in
                switch item {
                case .wholeMessage:
                    return cv.dequeueConfiguredReusableCell(using: wholeReg,for: indexPath,item: item)
                case .assistantHeader:
                    return cv.dequeueConfiguredReusableCell(using: headerReg,for: indexPath,item: item)
                case .assistantBlock:
                    return cv.dequeueConfiguredReusableCell(using: blockReg,for: indexPath,item: item)
                case .assistantFooter:
                    return cv.dequeueConfiguredReusableCell(using: footerReg,for: indexPath,item: item)
                }
            }

            if sheetOverlayHost == nil {
                let overlay = SheetOverlayView(toolPresenter: sheetPresenter,compactPresenter: compactSummaryPresenter)
                let host = UIHostingController(rootView: overlay)
                host.view.backgroundColor = .clear
                host.view.isUserInteractionEnabled = true
                host.view.frame = .zero
                vc.addChild(host)
                vc.view.addSubview(host.view)
                host.didMove(toParent: vc)
                sheetOverlayHost = host

                sheetPresenter.onDismiss = { [weak self] in
                    self?.flushPendingSnapshotIfNeeded(caller: "sheetDismiss")
                }
            }

            // [KbdDiag 2026-08-11] 键盘让位全链路证据:adjustedContentInset 变化
            // (键盘弹出/收起时系统注入 safeAreaInsets.bottom → adjustedContentInset)。
            // 仅打变化值,不打重复;attach 只注册一次,避免重复注册泄漏。
            adjustedInsetObservation = collectionView.observe(\.adjustedContentInset,options: [.new]) {
                [weak self] cv,chg in
                guard let self else { return }
                if let new = chg.newValue {
                    AppLogger.shared.info("[Keyboard] adjustedInset.bottom=\(String(format: "%.1f", new.bottom)) safeArea.bottom=\(String(format: "%.1f", cv.safeAreaInsets.bottom)) bounds.h=\(String(format: "%.1f", cv.bounds.height)) contentInset.bottom=\(String(format: "%.1f", cv.contentInset.bottom)) offset.y=\(String(format: "%.1f", cv.contentOffset.y)) mode=\(self.scrollMode)", category: "ChatList.Keyboard")
                }
            }

            contentSizeObservation = collectionView.observe(\.contentSize,options: [.new,.old]) {
                [weak self] cv,change in
                guard let self,!self.flushingNow else { return }
                let newH = change.newValue?.height ?? 0
                let oldH = change.oldValue?.height ?? 0
                guard newH != oldH else { return }
                let delta = newH-oldH

                if self.clampAfterSessionLoad {
                    let maxOff = max(0,newH-cv.bounds.height+cv.adjustedContentInset.bottom)
                    if maxOff>0 { cv.contentOffset.y = maxOff }
                    if Date() >= self.clampDeadline {
                        self.clampAfterSessionLoad = false
                    }
                    self.vm?.contentSizeDeltaSignal.send(delta)
                    return
                }

                // [2026-11-16 底部增长未锚定·真因] 原判据只认 `scrollMode == .autoScrolling`。
                // 用户往上拖过一次后模式变 .userBrowsing，此时底部新增一行（暂停横幅 16.3→40pt、
                // 工具胶囊、状态行）只打一条 "IN BROWSE MODE — no pin" 日志，**offset 不动** ⇒
                // 新增的这部分就露到输入框下面（真机 02:04 两张截图：横幅下半截被输入栏盖住）。
                // 数字证据：贴底时 offset=1289.7 = 2060.7−874+103（正确）；横幅 +24pt 后
                // maxOff=1313.7，offset 仍是 1289.7 ⇒ 差 24pt。
                //
                // 语义修正（对齐用户的"队列"模型）：**内容在底部增长时，只要用户仍在底部附近，
                // 就把底边锚住**——与当前是 autoScrolling 还是 userBrowsing 无关；
                // 真正翻历史（离底部远）时才不打扰。
                let grewWhileNearBottom = delta > 0 && !cv.isTracking && cv.isDecelerating == false
                    && self.isNearBottom(80)
                if delta>0 && (self.scrollMode == .autoScrolling || grewWhileNearBottom) {
                    if self.isAnimatingScrollToBottom {
                        self.scheduleCoalescedScroll()
                    } else {
                        let maxOff = newH-cv.bounds.height+cv.adjustedContentInset.bottom
                        if maxOff>0 {
                            if cv.isTracking || cv.isDecelerating {
                                AppLogger.shared.info("[KVO] ⚠️ PIN-WHILE-SCROLLING contentSize grew +\(String(format: "%.0f", delta)) offset \(String(format: "%.0f", cv.contentOffset.y))→\(String(format: "%.0f", maxOff)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) — MODE SHOULD BE userBrowsing", category: "ChatList.Stream")
                            }
                            // 手指按住（tracking）时绝不写 offset：与拖动手势抢滚动位置
                            // 造成流式 cell 整块抖动。decel 保持跟随（用户已松手，贴底是预期）。
                            if !cv.isTracking {
                                cv.contentOffset.y = max(cv.contentOffset.y,maxOff)
                            }
                        }
                    }
                } else if delta>0 && self.scrollMode == .userBrowsing {
                    AppLogger.shared.info("[KVO] contentSize grew +\(String(format: "%.0f", delta)) IN BROWSE MODE (far from bottom) — no pin. offset=\(String(format: "%.0f", cv.contentOffset.y)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating)", category: "ChatList.Stream")
                } else if delta<0 && self.scrollMode == .autoScrolling {
                    let maxOff = max(0,newH-cv.bounds.height+cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y>maxOff && !cv.isDecelerating {
                        cv.contentOffset.y = maxOff
                    }
                } else if delta<0 && self.scrollMode != .autoScrolling {
                    let maxOff = max(0,newH-cv.bounds.height+cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y>maxOff && !cv.isTracking && !cv.isDecelerating {
                        cv.contentOffset.y = maxOff
                    }
                }
                // [A 2026-08-11] 仅 autoScrolling 模式执行:用户在浏览(browse)时上滑松手,
                // settle 后内容被 UIKit 硬 clamp 回 3-8pt 造成抖动——browse 模式下不主动
                // clamp,让 UIKit 自然处理,避免"用户浏览却被拉回"的跳动感。
                if self.settleJustFinished && delta < -1 && self.scrollMode == .autoScrolling && !cv.isTracking && !cv.isDecelerating {
                    let maxOff = max(0,newH-cv.bounds.height+cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y>maxOff {
                        UIView.performWithoutAnimation {
                            cv.contentOffset.y = maxOff
                        }
                    }
                }
                self.vm?.contentSizeDeltaSignal.send(delta)

                // Re-evaluate sub-viewport overflowH compensation. When content
                self.applySubViewportCompensation(caller: "contentSizeKVO")

                if let vm = self.vm {
                    let nbFlag = self.isNearBottom()
                    if vm.isNearBottom != nbFlag {
                        vm.isNearBottom = nbFlag
                    }
                }
                self.syncScrollFlags()
            }

            bindViewModel(vm)
        }


        static let cellLogger = AppLogger(category: "CellPerf")
        let screenshotLogger = AppLogger(category: "ChatList.TurnShot")
        /// Verbose stage-by-stage trace of
        let chatScreenshotLogger = AppLogger(category: "ChatScreenshot")
        var cellConfigCount: Int = 0
        var firstCellConfigTime: CFAbsoluteTime = 0

        func configureCell(_ cell: SelfSizingCell,item: MessageListItem,indexPath: IndexPath) {
            guard let vm else { return }
            cellConfigCount += 1
            if cellConfigCount == 1 {
                firstCellConfigTime = CFAbsoluteTimeGetCurrent()
            }
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth

            switch item {
            case .wholeMessage(let msgId):
                guard let msgIdx = messageIndex[msgId],msgIdx<messages.count else { return }
                let message = messages[msgIdx]
                let bridge = getOrCreateBridge(for: message,in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedWholeMessage(
                        message: message,
                        bridge: bridge,
                        maxWidth: width
                    )
                    .transaction { $0.disablesAnimations = true }
                    // from the outer ChatView. Descendant views inside the
                    // `@EnvironmentObject vm: MessageListModel` for its long-
                    // SwiftUI's "No ObservableObject of type MessageListModel
                    //
                    .environmentObject(vm)
                }.minSize(width: 0,height: 0).margins(.all,0)
                cell.applyContentConfiguration(config)

            case .assistantHeader(let msgId):
                guard let msgIdx = messageIndex[msgId],msgIdx<messages.count else { return }
                let message = messages[msgIdx]
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantHeader(message: message,maxWidth: width)
                        .transaction { $0.disablesAnimations = true }
                        .environmentObject(vm)
                }.minSize(width: 0,height: 0).margins(.all,0)
                cell.applyContentConfiguration(config)

            case .assistantBlock(let msgId,let blockId):
                guard let msgIdx = messageIndex[msgId],msgIdx<messages.count else {
                    AppLogger.shared.warning("[Snapshot] configureCell MISS msgId=\(msgId.uuidString.prefix(8)) — messageIndex miss or OOB", category: "ChatList.Snapshot")
                    return
                }
                let message = messages[msgIdx]
                guard let block = message.blocks.first(where: { $0.id == blockId }) else {
                    AppLogger.shared.warning("[Snapshot] configureCell MISS blockId=\(blockId.uuidString.prefix(8)) in msg blocks=\(message.blocks.count) — block ID mismatch (vm.messages mutated since snapshot?)", category: "ChatList.Snapshot")
                    return
                }
                let bridge = getOrCreateBridge(for: message,in: messages)
                cell.backgroundColor = .clear
                // [Single height source] 只有助手**正文**块才把 cell 高度反推为正文高度。
                // 用户气泡也内嵌 `MarkdownTextView`，但其 cell 高含气泡内边距（约 +20~40pt），
                // 直接反推会让正文 view 撑高 → cell 再长 → 每帧叠加跑飞。
                cell.commitsTextHeightAsCellContent = (block.kind == .text)
                let config = UIHostingConfiguration {
                    BridgedAssistantBlock(
                        block: block,
                        message: message,
                        bridge: bridge,
                        maxWidth: width,
                        // [2026-09-12 裁尾修复] 显式给真实 cell 宽度（maxContentWidth 为 0，
                        // 无法据此推内容宽）→ 内容宽 = cvW − 2×16，与渲染宽度按构造一致。
                        cellWidth: viewController?.collectionView.bounds.width ?? 0
                    )
                    .transaction { $0.disablesAnimations = true }
                    .environmentObject(vm)
                }.minSize(width: 0,height: 0).margins(.all,0)
                cell.applyContentConfiguration(config)

            case .assistantFooter(let msgId):
                guard let msgIdx = messageIndex[msgId],msgIdx<messages.count else { return }
                let message = messages[msgIdx]
                let bridge = getOrCreateBridge(for: message,in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantFooter(
                        message: message,
                        bridge: bridge,
                        maxWidth: width
                    )
                    .transaction { $0.disablesAnimations = true }
                    .environmentObject(vm)
                }.minSize(width: 0,height: 0).margins(.all,0)
                cell.applyContentConfiguration(config)
            }

            // Seed this cell with the real
            if let layout = viewController?.messageListLayout {
                let cvW = viewController?.collectionView.bounds.width ?? 390
                let key = Self.contentKey(for: item,messages: messages,messageIndex: messageIndex)

                // Register the index→key map
                // in invalidationContext keys offY contentKeyByIndex[index]; if
                layout.setContentKey(key,at: indexPath.item)

                #if DEBUG
                // Stamp the stable cell tag on the
                if ScrollMetricsRecorder.shared.isEnabled {
                    let tag = Self.stableCellTag(for: item,messages: messages,messageIndex: messageIndex)
                    cell.metricsTag = tag
                    layout.setMetricsTag(tag,at: indexPath.item)
                }
                #endif

                // STREAMING EXCLUSION. A cell
                let itemMsgId = Self.messageId(of: item)
                let isStreamingCell = vm.isProcessing && itemMsgId != nil
                    && itemMsgId == messages.last?.id && messages.last?.role == .assistant
                if isStreamingCell {
                    cell.contentKey = nil
                    layout.invalidateMemo(forKey: key)
                }

                let memo = isStreamingCell ? nil : layout.measuredHeight(forKey: key,width: cvW)
                if !isStreamingCell {
                    cell.contentKey = key
                }
                if let memo {
                    cell.seedMeasuredHeight(memo,width: cvW)
                }
                // DO NOT seed from precalc.
                //
            }

            if let layout = viewController?.messageListLayout,
               !layout.hasMeasuredHeight(at: indexPath.item),
               !layout.hasPrecalcHeight(at: indexPath.item) {
                // [2026-09-13 滚动卡顿修复] `allowRenderBubble: false` —— **这里是滚动路径**
                //（`cellForItemAt` → `configureCell`）。默认值会为**用户气泡**跑一次真正的 cmark
                // 渲染（主线程、单条数十毫秒，含富语法时再叠 TextKit 全量排版）⇒ 真机表现为
                // 「滑到用户消息处卡顿一下」。粗估足够，精度由 cell 首次自 sizing 修正。
                // assistant 块不受影响：它们走 `cachedAttributedString` / 统一缓存短路，本就廉价。
                let est = Self.estimateItemHeight(item,messages: messages,
                                                  width: viewController?.collectionView.bounds.width ?? 390,
                                                  allowRenderBubble: false)
                layout.setEstimatedHeight(est,provenance: "est.estimateItemHeight(滚动路径)",at: indexPath.item)
            }
        }

        var bridgeSheetSubs: [UUID: AnyCancellable] = [:]

        func getOrCreateBridge(for message: RenderMessage,in messages: [RenderMessage]) -> CellStateBridge {
            if let existing = cellBridgeMap[message.id] { return existing }
            let bridge = CellStateBridge()
            cellBridgeMap[message.id] = bridge
            updateBridge(bridge,message: message,in: messages)
            bridgeSheetSubs[message.id] = bridge.$detailBlock
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] block in
                    guard let self else { return }
                    if let block {
                        let toolBlocks = message.blocks.filter { $0.toolStatus != nil }
                        // 2026-09-01 唐唐拍板：工具卡片浮层改为独立 UIWindow 呈现层
                        //（ToolCardWindowPresenter），**不再触碰会话页的宿主视图**——
                        // 原全屏 sheet 与 0×0 锚点宿主两条路都会影响消息列表布局/滑动。
                        ToolCardWindowPresenter.shared.present(
                            toolBlocks: toolBlocks,
                            initialBlockID: block.id,
                            toolSnapshots: bridge.toolSnapshots,
            snapshotBridge: bridge,
                            browserPool: bridge.browserPool,
                            browserContentProvider: self.vm?.browserContentProvider,
                            onDismiss: { [weak self] in
                                self?.flushPendingSnapshotIfNeeded(caller: "toolCardDismiss")
                            }
                        )
                    }
                }
            return bridge
        }

        func updateBridge(_ bridge: CellStateBridge,message: RenderMessage,in messages: [RenderMessage]) {
            guard let vm else { return }
            let isLast = message.id == messages.last?.id
            let isActive = isLast && vm.isProcessing

            #if DEBUG
            // [Stage 2 · A1 收口·第三轮] 本函数一次写 ~10 个 `CellStateBridge` 的 `@Published`，
            // 而它由 `cellForItemAt`/`configureCell` 驱动 —— 若某次 cell 配置发生在
            // `updateUIViewController` 的更新事务内（新 cell 进视口），这 10 个写就会连打 fault。
            SwiftUIUpdatePhase.reportIfInUpdate("updateBridge(\(bridge.isActiveMessage ? "active" : "idle"))")
            #endif
            bridge.isActiveMessage = isActive
            bridge.commandStartTime = vm.commandStartTime
            bridge.onStop = isActive ? { [weak self] in self?.onStop?() } : nil
            bridge.browserPool = vm.browserTabPool
            bridge.toolSnapshots = vm.toolSnapshots
            bridge.autoRetryAttempt = isLast ? vm.autoRetryAttempt : 0
            bridge.autoRetryCountdown = isLast ? vm.autoRetryCountdown : 0
            // Defense-in-depth: even if vm.canResume
            // reads). This closes the residual gapH where a new/reloaded VM sees a
            // toolResult-tail during a live loop's tool_result → next-model-call gapH.
            let trackerActive: Bool = {
                guard isLast,let sid = vm.sessionId else { return false }
                return SessionActivityTracker.shared.isActive(sid)
            }()
            bridge.canResume = isLast ? (vm.canResume && !vm.isProcessing && !trackerActive) : false
            bridge.onResume = isLast ? { [weak self] in self?.onResume?() } : nil
            bridge.onWithdraw = message.isQueued ? { [weak self] in self?.onWithdraw?(message.id) } : nil
            bridge.onSendQueued = message.isQueued ? { [weak self] in self?.onSendQueued?(message.id) } : nil
            bridge.isStreaming = isActive
            bridge.onReadAloud = (message.role == .assistant)
                ? { [weak vm] in vm?.readReplyFromStart(message) }
                : nil
            // "Read Selection" from the text
            // selection menu — speaks the selected snippet via the MiniClaw TTS
            bridge.onSpeakText = { [weak vm] text in vm?.speakText(text) }
            bridge.onCopyScreenshot = { [weak self,weak vm] in
                guard let self,let vm else { return }
                let msgs = vm.messages
                guard let anchorIdx = msgs.firstIndex(where: { $0.id == message.id }) else { return }
                let anchorY = msgs[anchorIdx]
                let userId: UUID?
                let assistantId: UUID?
                switch anchorY.role {
                case .user:
                    userId = anchorY.id
                    assistantId = msgs[(anchorIdx+1)...].first(where: { $0.role == .assistant })?.id
                case .assistant:
                    userId = msgs[..<anchorIdx].reversed().first(where: { $0.role == .user })?.id
                    assistantId = anchorY.id
                default:
                    return
                }
                guard let userId else { return }
                // Entry-trace from the
                self.chatScreenshotLogger.info("[Entry-MenuCallback] anchorY=\(message.id.uuidString.prefix(8)) role=\(anchorY.role) anchorIdx=\(anchorIdx)/\(msgs.count) → userId=\(userId.uuidString.prefix(8)) assistantId=\(assistantId?.uuidString.prefix(8) ?? "nil")")
                if let image = self.captureScrollingTurnScreenshot(userMessageId: userId,assistantMessageId: assistantId) {
                    self.onScreenshotImage?(image)
                }
            }

            let retryMsg = onRetryMessage
            let retryLast = onRetryLast
            let edit = onEdit
            let compact = onCompact
            let forceSync = onForceSync
            bridge.onForceSync = forceSync

            bridge.onShowCompactSummary = { [weak self] summary in
                guard let self else { return }
                self.compactSummaryPresenter.onRevert = { [weak self] in
                    self?.onRevertCompact?()
                }
                self.compactSummaryPresenter.summary = summary
            }

            if message.isCompactedHistory || message.role == .compactDivider || message.role == .systemInfo {
                bridge.onRetry = nil; bridge.onEdit = nil; bridge.onCompact = nil
            } else if !vm.isProcessing && !vm.isCompacting {
                if message.role == .user {
                    bridge.onRetry = { retryMsg?(message.id) }
                } else if isLast {
                    bridge.onRetry = { retryLast?() }
                } else {
                    bridge.onRetry = nil
                }
                bridge.onEdit = message.role == .user ? { edit?(message.id) } : nil
                bridge.onCompact = { compact?(message.id) }
            } else {
                bridge.onRetry = nil; bridge.onEdit = nil; bridge.onCompact = nil
            }
        }

        func updateLastCellBridge() {
            guard let vm else { return }
            let messages = vm.messages
            guard let lastMsg = messages.last else { return }
            if let bridge = cellBridgeMap[lastMsg.id] {
                updateBridge(bridge,message: lastMsg,in: messages)
            }
            if messages.count >= 2 {
                let prev = messages[messages.count-2]
                if let prevBridge = cellBridgeMap[prev.id],prevBridge.canResume {
                    prevBridge.canResume = false
                    prevBridge.onResume = nil
                }
            }
            for msg in messages.dropLast() {
                if msg.role == .assistant,let b = cellBridgeMap[msg.id],b.isActiveMessage {
                    b.isActiveMessage = false
                }
            }
            for msg in messages where msg.role == .user {
                if let b = cellBridgeMap[msg.id] {
                    updateBridge(b,message: msg,in: messages)
                }
            }
        }

        /// footer 的"显眼形态"（暂停横幅 / 回复中 / 错误）变化时，**强制那一行重测**。
        ///
        /// 为什么必需：`canResume` / `isProcessing` 翻转只写 `CellStateBridge`，不重建消息、
        /// 也就不走 `applyContentConfiguration`；而 PLAF 的第一道去重分支按宽度命中
        /// `lastCalcH` ⇒ 直接返回**暂停前**的高度（≈16.3 或 4pt），36pt 的暂停横幅被 cell
        /// 从下方裁掉（真机 20:29 截图：横条偏矮、「继续」胶囊贴死在右上角）。
        /// 这里显式失效该行条目 + reconfigure 一次，让 PLAF 重新量。
        private var lastFooterSignature: String?
        private func refreshFooterHeightIfProminenceChanged() {
            guard let vm,
                  let layout = viewController?.messageListLayout,
                  let lastAI = vm.messages.last(where: { $0.role == .assistant }) else { return }
            // [真机 01:46 复现] 原先用「显眼/不显眼」布尔做边沿判定：
            // 暂停时 `isProcessing`(true→false) 与 `canResume`(false→true) 是**分两次**翻转的，
            // 中间那一刻 prominent 一直是 true ⇒ 一次边沿都不触发 ⇒ 状态行/暂停横幅继续用
            // 16.3pt 的旧高度 ⇒ 被 cell 裁成一条细缝（橙色按钮看着像戳出条外）。
            // 改为按**完整状态签名**判定，任一字段变化都重测。
            let signature = [
                vm.isProcessing ? "run" : "idle",
                vm.canResume ? "resume" : "-",
                lastAI.error != nil ? "err" : "-",
                String(lastAI.streamInterruptCount),
                lastAI.footerShowsQuietStatusRow ? "quiet" : "-",
            ].joined(separator: "|")
            guard lastFooterSignature != signature else { return }
            lastFooterSignature = signature

            let item = MessageListItem.assistantFooter(lastAI.id)
            guard let idx = itemToIndex[item] ?? prevSnapshotIds.firstIndex(of: item),
                  let cv = viewController?.collectionView else { return }
            let hBefore = layout.cachedHeight(at: idx) ?? -1
            layout.invalidateHeight(at: idx)
            AppLogger(category: "BottomPad").info(
                "[FooterRefresh] sig=\(signature) idx=\(idx) hBefore=\(String(format: "%.1f", hBefore))")
            // 双保险：直接清掉该 cell 的本地高度缓存（PLAF 的 dedup 命中 lastCalcH 就会返回旧值，
            // 只 invalidate 布局层不够）。
            if let cell = cv.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell {
                cell.clearCachedHeight()
            }
            var snapshot = dataSource.snapshot()
            guard snapshot.itemIdentifiers.contains(item) else { return }
            snapshot.reconfigureItems([item])
            (cv as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            dataSource.apply(snapshot, animatingDifferences: false)
            (cv as? NoAnimationCollectionView)?.isApplyingSnapshot = false
            layout.invalidateLayout()
            // 形态变化会改变 footer 行高（16.3 ↔ 40/48）：若用户就在底部，
            // 立刻把底边重新锚住，避免新增高度露到输入栏下面。
            if self.isNearBottom(80), !cv.isTracking, !cv.isDecelerating {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToBottomNow(animated: false)
                }
            }
        }

        /// Re-point the coordinator at a NEW view
        /// different MessageListModel for the same mounted chat view. All
        public func rebindViewModelIfNeeded(_ newVM: MessageListModel) {
            if let current = vm,current === newVM { return }
            let hadOld = vm != nil
            #if DEBUG
            ScrollMetricsRecorder.shared.record(
                kind: "rebind", a: hadOld ? 1 : 0,
                note: Self.nbDump(viewController?.collectionView))
            #endif
            AppLogger.shared.info("[Scroll][rebind] coordinator vm \(hadOld ? "changed" : "was nil") → rebinding subscriptions + resyncing flags", category: "ChatList.Scroll")
            // [2026-09-11 回滚] 昨晚在此加的 clearHeightCache(keepingSharedMemo: true)
            // 会把重进会话变成「高度全空 + 同帧全量重播种」，与 PLAF 放行分支叠加时
            // SwiftUI ViewGraph 报 EXC_BREAKPOINT（DictionaryStorage 过度释放）。
            // 双 memo 合并后种子直读静态 memo（content-keyed、自带失效），此清理无收益。
            subscriptions.removeAll()
            lastMessageSub?.cancel(); lastMessageSub = nil
            lastMessageBlockCountSub?.cancel(); lastMessageBlockCountSub = nil
            lastMessageId = nil
            vm = newVM
            bindViewModel(newVM)
            if !newVM.isLoadingSession {
                applySnapshot(messages: newVM.messages, caller: "rebind")
            }
            syncScrollFlags()
        }

        func bindViewModel(_ vm: MessageListModel) {
            // Skip while isLoadingSession — binding 3 handles the post-load apply.
            // This prevents a redundant apply when $messages and $isLoadingSession
            // dispatch to main queue in the same runloop cycle.

            // [2026-09-13 滚动卡顿修复·治本] 宽度变更会**整表清空**索引高度条目，而清空后
            // 没有任何路径重播种（旋转/首次布局 settle 都不触发 `applySnapshot`）
            // ⇒ `configureCell` 的兜底守卫失守 ⇒ 滑到用户气泡时在**主线程**跑 cmark 渲染。
            // 这里把「清空 → 立刻重播种」接上（唯一入口 `seedHeights(.all)`）。
            // 与 `.miniClawAttachmentSizeChanged` 那条同源纪律：**凡整表失效，必须立刻重播种**。
            viewController?.messageListLayout?.onIndexHeightsPurged = { [weak self] in
                guard let self,let cv = self.viewController?.collectionView else { return }
                let msgs = self.snapshotMessages.isEmpty ? (self.vm?.messages ?? []) : self.snapshotMessages
                self.seedHeights(.all,rows: self.prevSnapshotIds,messages: msgs,width: cv.bounds.width)
                AppLogger.shared.info("[WidthPurge] 整表清空后重播种 rows=\(self.prevSnapshotIds.count)", category: "ChatList.Heights")
            }

            vm.$messages
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msgs in
                    guard let self else { return }
                    // If a load is in flight,
                    if self.vm?.isLoadingSession == true {
                        self.pendingSnapshotFlag = true
                        return
                    }
                    // 拖动/减速挂起期间冻结快照应用：流式内容继续在 vm 累积，松手
                    // settle 由 suspend-resume 边缘一次性 flush——消除拖动中流式 cell
                    // 每 0.25s 被 reconfigure/重测造成的整块抖动（bind4b 已有同款
                    // 守卫，bind1 此前漏了，内容增长路径绕过了挂起）。
                    if self.vm?.streamingUIUpdatesSuspended == true {
                        self.pendingSnapshotFlag = true
                        return
                    }
                    self.flushPendingSnapshotIfNeeded(caller: "bind1-messages")
                    self.applySnapshot(messages: msgs, caller: "bind1-messages")
                }
                .store(in: &subscriptions)

            // 1c. Suspend-resume flush.
            // `streamingUIUpdatesSuspended` is a plain (private(set)) var on
            // the vm — not @Published — but every state change that clears it
            // (scroll-settle resume, session-transition resume, the SSE final
            // flush) runs through the vm's @Published/objectWillChange surface.
            // We piggy-back on `vm.objectWillChange` and edge-detect the
            // true→false transition ourselves via `lastSuspendedValue`.
            //
            // Why this is the missing path: during a long multi-tool agent
            // loop, blocks appended while suspendedFlag only set
            // `pendingSnapshotFlag = true` (bind4b); the stream then ends and
            // cancels the per-message subs, and the terminal rescue at
            // stream-end skips the flush because suspend is still true (see
            // the "STREAM-END left pending (still suspendedFlag)" log). After that
            // nothing re-applies — `$messages` won't fire (blocks grew, the
            // array didn't) and the block-count sub is gone. This hook fires
            // the instant suspend lifts. Gated on `!isProcessing` so a
            // mid-stream resume is left to the live subscriptions / settle
            // path; only the stranded post-stream case is rescued here.
            lastSuspendedValue = vm.streamingUIUpdatesSuspended
            suspendResumeSub = vm.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self,let vm = self.vm else { return }
                    let now = vm.streamingUIUpdatesSuspended
                    let was = self.lastSuspendedValue
                    self.lastSuspendedValue = now
                    guard was,!now else { return }
                    // Flush REGARDLESS
                    guard self.pendingSnapshotFlag else { return }
                    AppLogger.shared.info("[SnapQueue] suspend-resume flush applied (pendingSnapshotFlag=true, isProcessing=\(vm.isProcessing))", category: "ChatList.SnapQueue")
                    self.flushPendingSnapshotIfNeeded(caller: "suspend-resume")
                }
            suspendResumeSub?.store(in: &subscriptions)

            // 1c. Resume hook. When the vm
            // clears `streamingUIUpdatesSuspended` (true→false) from ANY path,
            // rebuild a snapshot that was deferred during the suspend window.
            // Failure chain this fixes: during a multi-tool agent loop, new
            // blocks append while suspendedFlag → blockCountSub only sets
            // pendingSnapshotFlag=true; the stream then ends and cancels the
            // per-message subs; the terminal rescue sees still-suspendedFlag and
            // skips the flush; nothing else can fire it. This hook is the
            // missing trigger when suspend finally lifts. Only flush when the
            // loop is no longer processing (a mid-stream resume is handled by
            // the live subscriptions / settle path).
            vm.onStreamingUIUpdatesResumed = { [weak self] in
                guard let self else { return }
                let work = {
                    // Flush regardless
                    guard self.pendingSnapshotFlag else { return }
                    AppLogger.shared.info("[SnapQueue] suspend-resume flush (pendingSnapshotFlag=true, isProcessing=\(self.vm?.isProcessing == true))", category: "ChatList.SnapQueue")
                    self.flushPendingSnapshotIfNeeded(caller: "suspend-resume")
                }
                if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
            }

            // path mutates `messages[i].blocks` in place without changing
            // the messages array count, so `$messages` won't fire and the
            // diffable snapshot keeps its pre-cut block identifiers.
            // This signal forces a re-apply so stale blocks are removed.
            vm.retrySnapshotReloadSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self,let msgs = self.vm?.messages else { return }
                    let oldCount = self.dataSource?.snapshot().itemIdentifiers.count ?? 0
                    self.applySnapshot(messages: msgs, caller: "retrySnapshotReload")
                    let newCount = self.dataSource?.snapshot().itemIdentifiers.count ?? 0
                    if newCount != oldCount {
                        let totalBlocks = msgs.reduce(0) { $0+$1.blocks.count }
                        AppLogger.shared.info("[BlocksLost] SNAPSHOT REBUILT snapshotItems \(oldCount)→\(newCount) memoryBlocks=\(totalBlocks)", category: "BlocksLost")
                    }
                }
                .store(in: &subscriptions)

            vm.scrollToBottomSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self,self.scrollMode == .autoScrolling else { return }
                    self.scrollToBottomNow()
                }
                .store(in: &subscriptions)

            // [2026-09-13 补读路径] `AppState.scrollToMessageID` 的唯一消费点。
            // 与贴底信号并列：定位到历史消息必须先关掉贴底闸门（在 `scrollToMessage` 内做），
            // 否则自动贴底会立刻把跳转拽回底部。
            vm.scrollToMessageSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] target in
                    guard let self else { return }
                    self.scrollToMessage(id: target)
                }
                .store(in: &subscriptions)

            vm.forceScrollToBottom
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self else { return }
                    let cv = self.viewController?.collectionView
                    let layout = self.viewController?.messageListLayout
                    let cachedCount = layout?.debugCachedHeightCount ?? 0
                    AppLogger.shared.info("[Scroll][forceScrollToBottom] window=\(cv?.window != nil) contentSize=\(String(format: "%.0f", cv?.contentSize.height ?? 0)) bounds=\(String(format: "%.0f", cv?.bounds.height ?? 0)) adjInsetBot=\(String(format: "%.0f", cv?.adjustedContentInset.bottom ?? 0)) heightCache=\(cachedCount) visibleCells=\(cv?.visibleCells.count ?? 0)", category: "ChatList.Scroll")
                    self.vm?.setStreamingUIUpdatesSuspended(false)
                    self.scrollMode = .autoScrolling
                    self.lastJumpedUserId = nil
                    self.scrollToBottomNow(animated: true)
                }
                .store(in: &subscriptions)

            vm.forceScrollToTop
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.scrollToPreviousUserTurn(animated: true)
                }
                .store(in: &subscriptions)

            vm.$isLoadingSession
                .removeDuplicates()
                .dropFirst() // skip initial false — only react to true→false after actual load
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isLoading in
                    guard let self,!isLoading else { return }
                    self.lastJumpedUserId = nil
                    let isFirstLoad = self.prevSnapshotIds.isEmpty
                    if let msgs = self.vm?.messages {
                        // 进程级 memo 保留（方案 C）：contentKey 跨会话稳定，
                        // 重进会话种子直接命中实测高度 → 上滑零修正零抖动。
                        // 字体变更走 reconfigureAllCells 全量清 memo。
                        self.viewController?.messageListLayout?.clearHeightCache(keepingSharedMemo: true)
                        // window (bind1 set pendingSnapshotFlag) is now satisfied.
                        //
                        self.pendingSnapshotFlag = false
                        self.applySnapshot(messages: msgs, caller: "bind3-sessionLoad")
                    }
                    if isFirstLoad {
                        self.scrollMode = .autoScrolling
                        self.clampAfterSessionLoad = true
                        self.clampDeadline = Date().addingTimeInterval(8.0)
                        self.scrollToLastItem()
                    }
                }
                .store(in: &subscriptions)

            vm.$messages
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msgs in
                    let lastAIMsg = msgs.last(where: { $0.role == .assistant })
                    self?.subscribeToLastMessage(lastAIMsg)
                }
                .store(in: &subscriptions)

            vm.$isProcessing
                .removeDuplicates()
                .filter { $0 } // only on false → true transition
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.lastMessageId = nil // force re-subscribe
                    let lastAIMsg = self.vm?.messages.last(where: { $0.role == .assistant })
                    self.subscribeToLastMessage(lastAIMsg)
                }
                .store(in: &subscriptions)

            Publishers.CombineLatest4(
                vm.$isProcessing,vm.$autoRetryAttempt,
                vm.$autoRetryCountdown,vm.$canResume
            )
            .removeDuplicates { a,b in a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLastCellBridge() }
            .store(in: &subscriptions)

            vm.$isCompacting
                .removeDuplicates()
                .dropFirst() // skip initial value — only react to actual true→false transitions
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isCompacting in
                    guard let self,!isCompacting else { return }
                    if let msgs = self.vm?.messages { self.applySnapshot(messages: msgs, caller: "bind6-compact") }
                    self.reconfigureVisibleCells()
                }
                .store(in: &subscriptions)

            NotificationCenter.default.publisher(for: .fontSettingsMessageBaseChanged)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // [2026-09-13 出入口统一 3/3] 删掉 `vm?.invalidateAttributedStringCaches()` ——
                    // 它是全库唯一的调用点，而该方法是 `MiniClawHostStubs` 里的**空桩**（`{}`）：
                    // 真正让字体变更生效的是紧随其后的 `reconfigureAllCells()`
                    //（清高度缓存 + 重配全部可见 cell）。保留空桩只会让下一轮排查
                    // 误以为"字体缓存有专门的失效入口"。
                    guard let self else { return }
                    self.reconfigureAllCells()
                }
                .store(in: &subscriptions)

            // whether significant content accumulated while backgrounded.
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    let len = self.lastAssistantContentLength()
                    self.contentLengthAtBackground = len
                    AppLogger.shared.info("[FGLayout] → background, snapshotLen=\(len)", category: "ChatList.Layout")
                }
                .store(in: &subscriptions)

            // 8b. Foreground return — only invalidate layout if ≥200 characters
            // accumulated while backgrounded, avoiding unnecessary layout passes
            // when the content didn't change meaningfully.
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    let currentLen = self.lastAssistantContentLength()
                    let bgLen = self.contentLengthAtBackground ?? currentLen
                    self.contentLengthAtBackground = nil
                    let accumulated = currentLen-bgLen
                    AppLogger.shared.info("[FGLayout] → foreground, bgLen=\(bgLen) currentLen=\(currentLen) accumulated=\(accumulated)", category: "ChatList.Layout")
                    guard accumulated >= 200 else {
                        AppLogger.shared.info("[FGLayout] skip layout (accumulated \(accumulated) < 200)", category: "ChatList.Layout")
                        return
                    }
                    AppLogger.shared.info("[FGLayout] invalidating layout for \(self.viewController?.collectionView.indexPathsForVisibleItems.count ?? 0) visible cells", category: "ChatList.Layout")
                    if let cv = self.viewController?.collectionView,
                       let layout = self.viewController?.messageListLayout {
                        for indexPath in cv.indexPathsForVisibleItems {
                            layout.invalidateHeight(at: indexPath.item)
                        }
                        layout.invalidateLayout()
                    }
                    self.reconfigureVisibleCells()
                }
                .store(in: &subscriptions)

            // re-measures height after transitioning from empty to non-empty.
            vm.blockContentFilledSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] (messageId,blockId) in
                    guard let self,
                          let ds = self.dataSource else { return }
                    let item = MessageListItem.assistantBlock(messageId,blockId)
                    var snapshot = ds.snapshot()
                    let items = snapshot.itemIdentifiers
                    guard let idx = items.firstIndex(of: item) else { return }

                    self.viewController?.messageListLayout?.invalidateHeight(at: idx)

                    snapshot.reconfigureItems([item])
                    ds.apply(snapshot,animatingDifferences: false)
                }
                .store(in: &subscriptions)

            NotificationCenter.default.publisher(for: .messageListNeedsResnapshot)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self,let vm = self.vm else { return }
                    // [P1-5] `showUsage` 只改 bridge（@Published），不改变 item 身份 ⇒
                    // `applySnapshot` 会在 identityUnchanged 处早退，footer 高度不重测；
                    // 而 PLAF 命中 dedup 会返回旧高度，多出来的用量胶囊被 cell 裁掉。
                    // 这里直接失效并重配最后一条 assistant 的 footer 行。
                    if let lastAI = vm.messages.last(where: { $0.role == .assistant }),
                       let layout = self.viewController?.messageListLayout {
                        let footerItem = MessageListItem.assistantFooter(lastAI.id)
                        if let idx = self.itemToIndex[footerItem] {
                            layout.invalidateHeight(at: idx)
                        }
                        var snapshot = self.dataSource.snapshot()
                        if snapshot.itemIdentifiers.contains(footerItem) {
                            snapshot.reconfigureItems([footerItem])
                            self.dataSource.apply(snapshot, animatingDifferences: false)
                        }
                        layout.invalidateLayout()
                    }
                }
                .store(in: &subscriptions)
        }

        func lastAssistantContentLength() -> Int {
            guard let msg = vm?.messages.last(where: { $0.role == .assistant }) else { return 0 }
            return msg.blocks.reduce(0) { $0+$1.content.count }
        }

    }
}
public struct MessageCollectionView: UIViewControllerRepresentable {
    @ObservedObject public var vm: MessageListModel
    public var inputFocused: Bool
    /// 键盘展开时拖动列表：交给宿主收键盘，本次不滚动。
    public var onRequestDismissKeyboard: (() -> Void)?
    public var onRetryMessage: ((UUID) -> Void)?
    public var onRetryLast: (() -> Void)?
    public var onEdit: ((UUID) -> Void)?
    public var onWithdraw: ((UUID) -> Void)?
    /// 排队消息「立即发送」:中断当前回复并立即发送该条(2026-08-10 新增)。
    public var onSendQueued: ((UUID) -> Void)?
    public var onResume: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onCompact: ((UUID) -> Void)?
    public var onRevertCompact: (() -> Void)?
    public var onForceSync: (() -> Void)?
    public var onScreenshotImage: ((UIImage) -> Void)?
    public var maxContentWidth: CGFloat
    public var floatingBarHeight: CGFloat
    public var inputBarHeight: CGFloat

    public init(vm: MessageListModel,
                inputFocused: Bool,
                onRequestDismissKeyboard: (() -> Void)? = nil,
                onRetryMessage: ((UUID) -> Void)? = nil,
                onRetryLast: (() -> Void)? = nil,
                onEdit: ((UUID) -> Void)? = nil,
                onWithdraw: ((UUID) -> Void)? = nil,
                onSendQueued: ((UUID) -> Void)? = nil,
                onResume: (() -> Void)? = nil,
                onStop: (() -> Void)? = nil,
                onCompact: ((UUID) -> Void)? = nil,
                onRevertCompact: (() -> Void)? = nil,
                onForceSync: (() -> Void)? = nil,
                onScreenshotImage: ((UIImage) -> Void)? = nil,
                maxContentWidth: CGFloat,
                floatingBarHeight: CGFloat,
                inputBarHeight: CGFloat) {
        self.vm = vm
        self.inputFocused = inputFocused
        self.onRequestDismissKeyboard = onRequestDismissKeyboard
        self.onRetryMessage = onRetryMessage
        self.onRetryLast = onRetryLast
        self.onEdit = onEdit
        self.onWithdraw = onWithdraw
        self.onSendQueued = onSendQueued
        self.onResume = onResume
        self.onStop = onStop
        self.onCompact = onCompact
        self.onRevertCompact = onRevertCompact
        self.onForceSync = onForceSync
        self.onScreenshotImage = onScreenshotImage
        self.maxContentWidth = maxContentWidth
        self.floatingBarHeight = floatingBarHeight
        self.inputBarHeight = inputBarHeight
    }

    public func makeUIViewController(context: Context) -> MessageListViewController {
        #if DEBUG
        // [Stage 2 · A1 收口·第三轮 补窗] SwiftUI 的**布局相**同样属于 view update 事务；
        // 上轮机排除了 7 个嫌疑点后，这里是最可能的剩余落点（`onRendered` 就在本函数内触发）。
        SwiftUIUpdatePhase.enter()
        defer { SwiftUIUpdatePhase.exit() }
        #endif

        // 统一渲染缓存的内存告警监听（进程内一次，幂等）。
        MarkdownRenderCache.installMemoryWarningObserver()
        let vc = MessageListViewController()
        context.coordinator.attach(to: vc,vm: vm)
        // 2026-08-11 对齐原版:键盘由系统自动键盘规避统一抬升(列表 .automatic
        // 注入键盘 + 悬浮层一起被顶起),消息距输入栏距离恒定。不再手动注入
        // keyboardHeight——手动注入在键盘展开时会把消息额外垫高,导致距离不一致。
        _ = vc
        return vc
    }

    public func updateUIViewController(_ vc: MessageListViewController,context: Context) {
        let coord = context.coordinator
        #if DEBUG
        // [Stage 2 · A1 收口·第三轮] 本函数是 SwiftUI **update 事务内**被调用的（representable 语义），
        // 故在此开一个"更新事务在栈上"的标记窗；窗内任何 `@Published` 写都会指名报点。
        SwiftUIUpdatePhase.enter()
        defer { SwiftUIUpdatePhase.exit() }
        #endif
        // [2026-09-13 键盘「被错误抬高」· 时序修复] **必须先写 `lastInputFocused`，再算留白**。
        // 该值被 `updateUIVC` 里两处读取：① `bottomPadVal` 的键盘门控（键盘展开不再计入被代替的 34）；
        // ② base 变化后的「重新贴底」条件。而它原先在本函数**更后方**（约 1070 行）才赋值
        // ⇒ 整个 pass 读到的是**上一轮的旧值**，键盘首帧恒为 `false`。
        // 真机实证（新构建）：`focused=1 base=69 cvH=758 offsetY=1737.7` 而 **`[PinToBottom]` 一条都没有**
        // ⇒ 重贴底从未触发，偏移一直停在按旧 base(103) 算出的 `cs−cvH+103`（正确值应为 +69，差 34pt）。
        // 「焦点是否变化」也在同处判定（下方 B2 贴底逻辑要用），避免被本行覆盖而失效。
        let focusChanged = inputFocused != coord.lastInputFocused
        coord.lastInputFocused = inputFocused
        // The coordinator captured `vm` once in
        // platform VC (and coordinator) across ChatView re-creations, so when
        // the ViewModelCache hands the re-created view a NEW MessageListModel
        coord.rebindViewModelIfNeeded(vm)
        coord.onRetryMessage = onRetryMessage
        coord.onRetryLast = onRetryLast
        coord.onEdit = onEdit
        coord.onWithdraw = onWithdraw
        coord.onSendQueued = onSendQueued
        coord.onResume = onResume
        coord.onStop = onStop
        coord.onCompact = onCompact
        coord.onRequestDismissKeyboard = onRequestDismissKeyboard
        coord.installKeyboardDismissPan(on: vc.collectionView)
        coord.onRevertCompact = onRevertCompact
        coord.onForceSync = onForceSync
        coord.onScreenshotImage = onScreenshotImage
        coord.maxContentWidth = maxContentWidth

        // it reads coord.baseBottomInset and adds overflowH on top when needed.
        //
        // dead space — observed as ~100pt gapH between the last bubble
        // [2026-09-13 撤销] 恢复「`contentInset.bottom` 显式包含底部安全区」的原行为 ——
        // CV 已恢复全幅铺到底（见 `MessageListViewController.viewDidLoad`），故这里必须把
        // 安全区加回来，否则末条消息会被输入栏/小横条压住。当初为配合"CV 底边上移 34pt"
        // 而删掉的那一项已还原，两处必须成对，不能只改一边。
        let bottomSafe = (vc.collectionView as? NoAnimationCollectionView)?.stableBottomSafeArea ?? 0
        coord.inputBarHeightCache = inputBarHeight
        coord.floatingBarHeightCache = floatingBarHeight
        // [2026-09-13 键盘展开距离修正] 键盘展开时 `floatingBarHeight`(48) 与 `bottomSafe`(34)
        // **都已被键盘取代**：浮动栏被收起、home indicator 被键盘盖住 ⇒ 再计入就会把内容多顶 ~82pt
        // （真机 `[Keyboard]` 实测：`151 = 61+48+8+34` 两项同时计入，而键盘展开时应为 `61+8 = 69`；
        //  截图里末条消息与输入栏之间多出的那段空隙正对应这 ~90pt）。
        // 信号用既有的 `coord.lastInputFocused`（由 ChatView 焦点态传入，非新造状态）。
        // 注意：**键盘自身高度不在本式内**（列表由系统推挤，手动注入会把消息额外垫高，见 980 行注释）。
        // [2026-11-16 视口单源] 底部遮挡 = 输入栏 + 浮动栏 + 底部安全区 + 键盘 + 8。
        // 不再按键盘态做减法：减法等于假设"列表会被系统压缩"，而真机日志（cvH 恒 874）说明没有。
        // 键盘高度由 Coordinator 观察 keyboardWillChangeFrame 维护。
        // [2026-11-16 03:30] 键盘展开时 home indicator 已被键盘盖住，安全区**不应**再计入：
        // 多算 34pt 正是"内容与输入栏之间那道空档"的来源（截图 03:28）。
        let safeContribution = coord.keyboardHeight > 0 ? 0 : bottomSafe
        let bottomPadVal: CGFloat = inputBarHeight
            + floatingBarHeight
            + 8
            + safeContribution
        AppLogger.shared.info("[ChatUI] build=0330 inset=\(String(format: "%.0f", bottomPadVal)) kb=\(String(format: "%.0f", coord.keyboardHeight)) safe=\(String(format: "%.0f", bottomSafe))", category: "ChatList.Keyboard")
        let baseChanged = abs(coord.baseBottomInset-bottomPadVal)>0.5
        if baseChanged {
            let cv = vc.collectionView!
            let wasNearBottomBefore = coord.isNearBottom()
            coord.baseBottomInset = bottomPadVal
            // [KbdDiag 2026-08-11] baseBottomInset 写入打点:base = inputBarHeight + floatingBarHeight + 8。
            // [2026-09-13] 改为 `AppLogger.shared` 写法：原为内联临时 logger（`AppLogger(category:)`），
            // **整行会被静默丢弃**（实例级缓冲未达阈值即释放）⇒ 「键盘展开时 inset 由哪几项组成」
            // 一直没有数据，导致只能靠猜。此行是判断「是否有哪一项被重复计入」的唯一依据。
            AppLogger.shared.info(
                "[Keyboard] focused=\(coord.lastInputFocused ? 1 : 0) baseBottomInset \(String(format: "%.1f", coord.baseBottomInset))←\(String(format: "%.1f", bottomPadVal)) inputBarHeight=\(String(format: "%.1f", inputBarHeight)) floatingBarHeight=\(String(format: "%.1f", floatingBarHeight)) bottomSafe=\(String(format: "%.1f", bottomSafe)) cvInsetB=\(String(format: "%.1f", vc.collectionView.contentInset.bottom)) adjB=\(String(format: "%.1f", vc.collectionView.adjustedContentInset.bottom)) cvH=\(String(format: "%.1f", vc.collectionView.bounds.height)) offsetY=\(String(format: "%.1f", vc.collectionView.contentOffset.y)) cs=\(String(format: "%.1f", vc.collectionView.contentSize.height)) winSafeB=\(String(format: "%.1f", vc.view.window?.safeAreaInsets.bottom ?? -1)) vcSafeB=\(String(format: "%.1f", vc.view.safeAreaInsets.bottom))",
                category: "ChatList.Keyboard")
            cv.contentInset.bottom = bottomPadVal
            // [2026-09-13 键盘「被错误抬高」· 最终修法] 键盘展开时 base 变小（103→69）后必须重新贴底。
            // 上一版只改了**调用点**的条件，但真正执行贴底的 `applySubViewportCompensation` 内部
            // 还有一道门控 `if scrollMode == .autoScrolling` —— 而键盘弹出这一路 `scrollMode`
            // 并非 `.autoScrolling` ⇒ 贴底被内层门控拦掉（真机实证：35 条 `[PinToBottom]` **全是 base=103**，
            // 一条 base=69 都没有；于是 offset 停在 `cs−cvH+103 = 2111.7`，正确值是 2077.7，差 34pt）。
            // 故这里显式带上键盘态：输入框聚焦（键盘/面板展开）时，base 一变就重新贴底。
            if coord.scrollMode == .autoScrolling || wasNearBottomBefore || coord.lastInputFocused {
                coord.scrollMode = .autoScrolling
                coord.scrollToBottomNow(animated: false)
            }
        }

        // [T-first-msg-top-gapH 2026-07-18] Apply the top inset. User report
        // [2026-09-12 F3(b) 回退] 曾在此加「inset 变化时平移 offset 锚定可见内容」——
        // **错误**：该 inset 的变化来自 CV frame 在入口期被布局两次，两态本就视觉等价
        //（CV 下移 116 + inset 0 ≡ CV 在 0 + inset 116）；再平移 offset 会打破等价并把
        // UIKit 的自动补偿重复计一次 ⇒ offset 被来回拉 ∓116（真机 `[Jitter] INSET-TOP`
        // 与 `SAFE-AREA` 交替成环）。T2 起 `baseContentInsetTop` 为**常量**、且 CV 为
        // `.never`，该 inset 根本不再变化 ⇒ 无需锚定，直接赋值即可。
        let cvTop = vc.collectionView!
        if abs(cvTop.contentInset.top-coord.baseContentInsetTop)>0.5 {
            cvTop.contentInset.top = coord.baseContentInsetTop
        }

        coord.applySubViewportCompensation(caller: "updateUIVC")

        // Backstop: if a snapshot was
        // holds pendingSnapshotFlag during scroll-settle / background streaming);
        if !vm.isLoadingSession && !vm.streamingUIUpdatesSuspended {
            coord.flushPendingSnapshotIfNeeded(caller: "updateUIVC-backstop")
        }

        // [P5 2026-09-13] **冻结泄漏兜底**。这是本类里唯一"不依赖滚动回调、也会周期性跑"的钩子
        //（每次 SwiftUI 更新跑一次），故把"两轴冻结是否还在合法窗口内"的检查挂在这里。
        // 正常路径下它什么也不做（`isTracking`/`isDecelerating` 为真，或宽限期未过）；
        // 命中即说明 `settleAfterInteraction` 那次关闭没来（见 `freezeStartedAt` 的说明）。
        coord.resetLeakedFreezeIfNeeded("updateUIVC")

        if focusChanged {
            let wasNearBottom = coord.isNearBottom()
            coord.lastInputFocused = inputFocused
            if inputFocused {
                // [2026-11-16 视口单源] 聚焦不再单独贴底：键盘高度进 inset，由
                // `reapplyInsetAfterKeyboardChange` 统一处理（一个变化 → 一次贴底）。
            } else if wasNearBottom {
                // 键盘收起:维持原逻辑(仅近底时贴底,浏览历史不打扰)。
                DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { [weak coord] in
                    coord?.scrollToBottomNow(animated: true)
                }
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.startKeyboardObservation()
        return c
    }

    enum Section { case main }
}

// MARK: - Bridged Cell Views (no GeometryReader)

/// Header: "✦ MiniClaw" label at the top of each assistant turn.
/// Name comes from SOUL.md (user-editable in Soul Settings); the
/// sparkles glyph is fixed — custom emoji is no longer supported,
/// matching the Soul Settings UI.
extension Notification.Name {
    static let messageListNeedsResnapshot = Notification.Name("messageListNeedsResnapshot")
}

// MARK: - MessageCollectionView

/// Message list: cell-per-block model with a simplified
/// scroll stability architecture:
///
/// - **2-state scroll model**: autoScrolling / userBrowsing
private final class AssistantHeaderCell: SelfSizingCell {}