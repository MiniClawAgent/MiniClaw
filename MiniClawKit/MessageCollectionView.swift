import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

private final class AssistantBlockCell: SelfSizingCell {}
private final class WholeMessageCell: SelfSizingCell {}
private struct BridgedAssistantHeader: View {
    @ObservedObject var message: ChatMessage
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
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soulMeta = SoulStore.cachedMetadata
        }
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

/// Single block within an assistant turn — text, tool capsule, or info.
/// No GeometryReader — UIKit self-sizing is the sole height source.
extension MessageCollectionView {

    /// Scroll mode: the only two states the list needs.
    public enum ScrollMode {
        /// Content growth pins offset to bottom. Self-sizing accepted normally.
        case autoScrolling
        /// User is reading above the bottom. Layout changes preserve offset.
        case userBrowsing
    }

    public final class Coordinator: NSObject,UICollectionViewDelegate,UIScrollViewDelegate,UICollectionViewDataSourcePrefetching {
        // ── 状态存储（结构重组：自扩展文件归位）──
        /// When a snapshot is deferred (e.g. streaming UI updates suspendedFlag),
        /// set to true so we know to re-apply later.
        var pendingSnapshotFlag: Bool = false

        let nearBottomThreshold: CGFloat = 20

        /// Tighter threshold for *re-acquiring* `.autoScrolling` after a
        /// deliberate user interaction settles. `nearBottomThreshold` (20pt)
        /// is right for *maintaining* the bottom-pin during streaming, but
        /// reusing it to re-arm auto-scroll caused trackpad jitter on iPad:
        /// a tiny two-finger scroll up leaves the offset well within 20pt of
        /// the bottom, so settle flipped straight back to `.autoScrolling`,
        /// the contentSize KVO re-pinned to the bottom, and that fought the
        /// next small scroll — the scrollbar darted up and down. Requiring the
        /// content to be essentially flush with the bottom (≤4pt) means a
        /// deliberate small scroll stays in `.userBrowsing`, while a scroll
        /// that genuinely lands at the bottom still resumes follow-along.
        ///
        let reacquireAutoScrollThreshold: CGFloat = 4

        /// The user-message id the up-button last jumped to, so a repeated tap
        /// walks one turn further back. Reset (nil) whenever the anchoring
        /// context changes — manual drag, jump-to-bottom, snapshot change, or
        /// session load — so the next tap re-anchors to the current viewport
        /// instead of continuing from a stale turn.
        public var lastJumpedUserId: UUID?

        /// Base contentInset.bottom = inputBarHeight + floatingBarHeight + 8.
        /// Set by updateUIViewController; the actual cv.contentInset.bottom
        /// equals this plus the current sub-viewport compensation (if any).
        /// `applySubViewportCompensation` is the only place that writes
        /// contentInset.bottom — it reads this base and adds overflowH.
        public var baseBottomInset: CGFloat = 0

        var decelDisplayLink: CADisplayLink?

        var decelDLLastTimestamp: CFTimeInterval = 0

        var decelDLFrames: Int = 0

        var decelDLDrops: Int = 0

        var decelDLMinGapMs: Double = .infinity

        var decelDLMaxGapMs: Double = 0

        var decelDLExpectedMs: Double = 16.67

        /// Track last logged offset to detect jumps after settle.
        var lastLoggedOffset: CGFloat = 0

        var settleJustFinished = false

        var scrollSamples = 0

        var lastScrollFlushOffset: CGFloat = 0

        var lastScrollFlush: CFTimeInterval = 0

        // [Decel] Deceleration-phase instrumentation. Lets us pin a
        // dropped frame to "Xms into the decel, at offset Y" so the
        // scroll-jank trace's micro-hangs can be aligned to the exact moment
        // and content region where the costly render started.
        var decelStartTime: CFTimeInterval = 0

        var decelStartOffset: CGFloat = 0

        var decelTargetOffset: CGFloat = 0

        var decelLastFrameTime: CFTimeInterval = 0

        var decelFrameCount = 0

        var decelSlowFrameCount = 0

        /// A frame gapH above this (seconds) during deceleration is a dropped
        /// frame worth logging. ~32ms ≈ two missed frames at 60Hz / several at
        /// 120Hz — low enough to catch the jitter, high enough to stay quiet
        /// on smooth scrolls.
        let decelSlowFrameThreshold: CFTimeInterval = 0.032

        // Callbacks
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

        #if DEBUG
        deinit {
            // [DecelDisplayLink] CADisplayLink retains its target — must
            // invalidate on Coordinator teardown to break the cycle.
            decelDisplayLink?.invalidate()
        }
        #endif

        // === Scroll mode（两态模型） ===
        public var scrollMode: ScrollMode = .autoScrolling {
            didSet {
                // Mirror to the layout so its invalidationContext can glue the
                // streaming cell's bottom to the viewport while pinned (smooth
                // grow) and skip that adjustment while the user browses.
                //
                viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            }
        }
        /// True during settleAfterInteraction flush — suppresses contentSize KVO offset changes.
        var flushingNow = false
        /// True while an animated setContentOffset is in flight. KVO grow events must not
        /// directly mutate contentOffset during this window — UIKit animation interpolation
        /// can produce a corrupted final offset. Instead, defer via scheduleCoalescedScroll().
        var isAnimatingScrollToBottom = false

        // === O(1) Lookup Indices ===
        var messageIndex: [UUID: Int] = [:]
        var itemToIndex: [MessageListItem: Int] = [:]

        // === Snapshot State ===
        var prevSnapshotIds: [MessageListItem] = []
        var snapshotMessages: [ChatMessage] = []

        // === Bridges ===
        var cellBridgeMap: [UUID: CellStateBridge] = [:]

        // === Height Measurement Cache ===
        /// Caches measureAttributedStringHeight results by NSAttributedString identity.
        /// Avoids redundant TextKit layout on repeated snapshots for the same content.
        var attrStringHeightCache: [ObjectIdentifier: CGFloat] = [:]
        /// Caches accurate user-bubble
        /// heights keyed by "content|width|fontsize" (user text has no
        /// cachedAttributedString identity to key on). Cleared alongside
        /// attrStringHeightCache on session change / font change.
        var userBubbleHeightCache: [String: CGFloat] = [:]

        // === Thinking Block Toggle ===
        var thinkingToggleSub: AnyCancellable?

        // === Async attachment size invalidate ===
        // [T-attachment-size-invalidate 2026-05-21] Image / video / thumbnail
        // async loads cause cell SwiftUI body to grow from placeholder to fit
        // size, but SelfSizingCell's broad-width cache short-circuits
        // preferredLayoutAttributesFitting so the cell never re-measures —
        // bottom of content gets clipped until the chat is re-entered.
        var attachmentSizeChangedSub: AnyCancellable?

        // === Foreground/Background Content Tracking ===
        /// Total character count of the last assistant message's blocks when the app entered background.
        /// Used to decide whether layout invalidation is needed on foreground return.
        var contentLengthAtBackground: Int?

        // === Streaming ===
        var lastMessageId: UUID?
        var lastMessageSub: AnyCancellable?
        var lastMessageBlockCountSub: AnyCancellable?

        /// Last observed value of the vm's
        /// `streamingUIUpdatesSuspended`, tracked so the vm-state subscription can
        /// detect a true→false transition and flush a snapshot deferred during the
        /// suspend window (see `suspendResumeSub`).
        var lastSuspendedValue: Bool = false
        /// Watches the vm for the moment
        /// `streamingUIUpdatesSuspended` clears, then flushes the pending snapshot.
        var suspendResumeSub: AnyCancellable?

        /// Adaptive streaming throttle: last time flushStreamingLayout actually ran.
        var lastStreamingLayoutTime: Date = .distantPast
        /// Trailing-edge work item so the final streaming update isn't lost.
        var pendingStreamingLayout: DispatchWorkItem?


        /// Scroll coalescing: batches rapid scroll signals into one 80ms action.
        var pendingScrollWork: DispatchWorkItem?

        // === Session Load ===
        /// When true, contentSize KVO keeps pinning to bottom until layout stabilizes.
        var clampAfterSessionLoad: Bool = false
        /// Hard deadline to stop clamping (2s after session load).
        var clampDeadline: Date = .distantPast

        // === Sheet Presenters ===
        let sheetPresenter = ToolSheetPresenter()
        let compactSummaryPresenter = CompactSummaryPresenter()
        var sheetOverlayHost: UIHostingController<SheetOverlayView>?

        // === References ===
        weak var viewController: MessageListViewController?
        weak var vm: MessageListModel?
        var dataSource: UICollectionViewDiffableDataSource<Section,MessageListItem>!
        var subscriptions = Set<AnyCancellable>()
        var contentSizeObservation: NSKeyValueObservation?
        /// [KbdDiag 2026-08-11] 观察 adjustedContentInset 变化(键盘弹出/收起时系统注入
        /// safeAreaInsets.bottom → adjustedContentInset 变化),打印键盘让位全链路证据。
        var adjustedInsetObservation: NSKeyValueObservation?

        // MARK: - Setup

        public func attach(to vc: MessageListViewController,vm: MessageListModel) {
            self.viewController = vc
            self.vm = vm
            vc.messageListCoordinator = self
            vc.loadViewIfNeeded()
            guard let collectionView = vc.collectionView else { return }
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            // Disable UIKit's main-thread cell prefetch. Profile (Time Profiler)
            // showed -[UICollectionView _prefetchItemsForPrefetchingContext:]
            // chains through _createPreparedCellForItemAtIndexPath → +UIView
            // performWithoutAnimation → _checkForPreferredAttributesInView →
            // SelfSizingCell.preferredLayoutAttributesFitting →
            // UIHostingContentView.systemLayoutSizeFitting, eating ~44ms (30%)
            // of one main-thread sample for a single offY-screen BIG-CELL.
            // That's the 2-3 frame hitch users perceive as a sudden stutter
            // right before scrolling exposes a large text/table cell.
            // Disabling prefetch lets cells be sized only when they actually
            // come on-screen. Heights are still pre-estimated via setEstimatedHeight
            // in applySnapshot / configureCell, so layout positions don't shift.
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

            // Install sheet overlay (outside UIHostingConfiguration cell tree)
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
                    AppLogger(category: "ChatList.Keyboard").info("[Keyboard] adjustedInset.bottom=\(String(format: "%.1f", new.bottom)) safeArea.bottom=\(String(format: "%.1f", cv.safeAreaInsets.bottom)) bounds.h=\(String(format: "%.1f", cv.bounds.height)) contentInset.bottom=\(String(format: "%.1f", cv.contentInset.bottom)) offset.y=\(String(format: "%.1f", cv.contentOffset.y)) mode=\(self.scrollMode)")
                }
            }

            // ContentSize KVO — pin to bottom during autoScrolling
            contentSizeObservation = collectionView.observe(\.contentSize,options: [.new,.old]) {
                [weak self] cv,change in
                guard let self,!self.flushingNow else { return }
                let newH = change.newValue?.height ?? 0
                let oldH = change.oldValue?.height ?? 0
                guard newH != oldH else { return }
                let delta = newH-oldH

                // Session load stability: keep pinning to bottom until layout settles.

                // Session load stability: keep pinning to bottom until layout settles.
                // Use time-based deadline only — fire-count was too fragile on iPad
                // where width changes (sidebar) and async image loads produce many
                // contentSize KVO fires before the layout truly stabilizes.
                if self.clampAfterSessionLoad {
                    let maxOff = max(0,newH-cv.bounds.height+cv.adjustedContentInset.bottom)
                    if maxOff>0 { cv.contentOffset.y = maxOff }
                    if Date() >= self.clampDeadline {
                        self.clampAfterSessionLoad = false
                    }
                    self.vm?.contentSizeDeltaSignal.send(delta)
                    return
                }

                if delta>0 && self.scrollMode == .autoScrolling {
                    // Pin to bottom — but if an animated scroll is in flight, directly
                    // mutating contentOffset corrupts UIKit's animation interpolation.
                    // Defer to a coalesced scroll that fires after the animation ends.
                    if self.isAnimatingScrollToBottom {
                        self.scheduleCoalescedScroll()
                    } else {
                        let maxOff = newH-cv.bounds.height+cv.adjustedContentInset.bottom
                        if maxOff>0 {
                            // [DIAG-3] If tracking/decel, auto-scroll mode is fighting user gesture
                            if cv.isTracking || cv.isDecelerating {
                                AppLogger(category: "ChatList.Stream").info("[KVO] ⚠️ PIN-WHILE-SCROLLING contentSize grew +\(String(format: "%.0f", delta)) offset \(String(format: "%.0f", cv.contentOffset.y))→\(String(format: "%.0f", maxOff)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) — MODE SHOULD BE userBrowsing")
                            }
                            // 手指按住（tracking）时绝不写 offset：与拖动手势抢滚动位置
                            // 造成流式 cell 整块抖动。decel 保持跟随（用户已松手，贴底是预期）。
                            if !cv.isTracking {
                                cv.contentOffset.y = max(cv.contentOffset.y,maxOff)
                            }
                        }
                    }
                } else if delta>0 && self.scrollMode == .userBrowsing {
                    // [DIAG-3b] Content grew while user is browsing — no pin.
                    // If a cell ABOVE viewport grew, all cells below shift down.
                    AppLogger(category: "ChatList.Stream").info("[KVO] contentSize grew +\(String(format: "%.0f", delta)) IN BROWSE MODE — no pin. offset=\(String(format: "%.0f", cv.contentOffset.y)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating)")
                } else if delta<0 && self.scrollMode == .autoScrolling {
                    // Content shrank while auto-scrolling — clamp to prevent overscroll.
                    // Skip during deceleration: settleAfterInteraction will handle it.
                    let maxOff = max(0,newH-cv.bounds.height+cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y>maxOff && !cv.isDecelerating {
                        cv.contentOffset.y = maxOff
                    }
                } else if delta<0 && self.scrollMode != .autoScrolling {
                    // Content shrank while user is browsing — clamp to prevent overscroll.
                    let maxOff = max(0,newH-cv.bounds.height+cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y>maxOff && !cv.isTracking && !cv.isDecelerating {
                        cv.contentOffset.y = maxOff
                    }
                }
                // After settle, deferred heights are flushed and UIKit re-layouts
                // with real heights. If contentSize shrinks, the current offset may
                // exceed the new max — UIKit will hard-clamp it, causing a visible jump.
                // Pre-emptively clamp with performWithoutAnimation to avoid the jitter.
                // [A 2026-08-11] 仅 autoScrolling 模式执行:用户在浏览(browse)时上滑松手,
                // settle 后内容被 UIKit 硬 clamp 回 3-8pt 造成抖动——browse 模式下不主动
                // clamp,让 UIKit 自然处理,避免"用户浏览却被拉回"的跳动感。
                if self.settleJustFinished && delta < -1 && self.scrollMode == .autoScrolling && !cv.isTracking && !cv.isDecelerating {
                    let maxOff = max(0,newH-cv.bounds.height+cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y>maxOff {
                        AppLogger(category: "ChatList.Settle").debug("[Settle] POST-SETTLE SHRINK clamp offset \(String(format: "%.1f→%.1f", cv.contentOffset.y, maxOff)) contentSize \(String(format: "%.1f→%.1f", oldH, newH))")
                        UIView.performWithoutAnimation {
                            cv.contentOffset.y = maxOff
                        }
                    }
                }
                // Forward contentSize changes to downstream observers.
                self.vm?.contentSizeDeltaSignal.send(delta)

                // Re-evaluate sub-viewport overflowH compensation. When content
                // overflows the visible area but UIKit thinks no scroll is
                // needed, this inflates inset.top so we can pin past UIKit's
                // default clamp.
                self.applySubViewportCompensation(caller: "contentSizeKVO")

                // Sync vm.isNearBottom on every contentSize change. UIKit only
                // dispatches scrollViewDidScroll when contentOffset moves; in
                // sub-viewport streaming (offset clamped at -insetTop while
                // contentSize grows past the visible area), the published value
                // would otherwise stay stuck at its prior reading and the
                // scroll-to-bottom button never appears.
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

        // MARK: - Cell Configuration

        func currentIndex(for item: MessageListItem) -> Int? {
            return itemToIndex[item]
        }

        static let cellLogger = AppLogger(category: "CellPerf")
        let screenshotLogger = AppLogger(category: "ChatList.TurnShot")
        /// Verbose stage-by-stage trace of
        /// captureScrollingTurnScreenshot used to chase the "top blank when
        /// long-press from middle/bottom" symptom that the first repair
        /// (5e3c6160) didn't fully eliminate. Separate category from
        /// TurnScreenshot so users can `grep ChatScreenshot` cleanly to
        /// pull just the diagnostic frames without the noisier turn-level
        /// summary lines.
        let chatScreenshotLogger = AppLogger(category: "ChatScreenshot")
        /// Counts cells configured since last applySnapshot to detect first-cell timing.
        var cellConfigCount: Int = 0
        var firstCellConfigTime: CFAbsoluteTime = 0

        func configureCell(_ cell: SelfSizingCell,item: MessageListItem,indexPath: IndexPath) {
            guard let vm else { return }
            let configStart = CACurrentMediaTime()
            cellConfigCount += 1
            if cellConfigCount == 1 {
                firstCellConfigTime = CFAbsoluteTimeGetCurrent()
            }
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth

            // [T-viewgraph-race-lifetime 2026-05-20] All 4 cell config sites
            // route through `cell.applyContentConfiguration(_:)` (not raw
            // `cell.contentConfiguration =`) so the SelfSizingCell bumps its
            // configGeneration and clears the height cache when the hosting
            // configuration is swapped. Without it, the preferredLayoutAttributesFitting
            // generation guard never trips (gen never changes) and the
            // broad cache may return a stale height for the swapped content.
            // Both reduce the window for the ViewGraphGeometryObservers race.
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
                    // Suppress SwiftUI async display-link geometry observation
                    // to prevent use-after-free in ViewGraphGeometryObservers
                    // when UICollectionView recycles the cell.
                    .transaction { $0.disablesAnimations = true }
                    // UIHostingConfiguration creates an independent SwiftUI
                    // environment — it does NOT inherit EnvironmentObjects
                    // from the outer ChatView. Descendant views inside the
                    // cell (notably ToolCapsuleView, which reads
                    // `@EnvironmentObject vm: MessageListModel` for its long-
                    // press menu's `vm.isProcessing` check) would trigger
                    // SwiftUI's "No ObservableObject of type MessageListModel
                    // found" fatal (EXC_BREAKPOINT) the moment the body
                    // evaluates — symptom: app crashes when waking from
                    // lock + tapping a session-complete notification, since
                    // the deep-link forces an immediate cell rebuild before
                    // any other view layer can re-inject the vm. Re-inject
                    // explicitly on every hosting config.
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
                    AppLogger(category: "ChatList.Snapshot").warning("[Snapshot] configureCell MISS msgId=\(msgId.uuidString.prefix(8)) — messageIndex miss or OOB")
                    return
                }
                let message = messages[msgIdx]
                guard let block = message.blocks.first(where: { $0.id == blockId }) else {
                    AppLogger(category: "ChatList.Snapshot").warning("[Snapshot] configureCell MISS blockId=\(blockId.uuidString.prefix(8)) in msg blocks=\(message.blocks.count) — block ID mismatch (vm.messages mutated since snapshot?)")
                    return
                }
                let bridge = getOrCreateBridge(for: message,in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantBlock(
                        block: block,
                        message: message,
                        bridge: bridge,
                        maxWidth: width
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
            // height the SAME content measured on a prior appearance (if any),
            // so its first self-size after reuse skips the 2.5–3.8ms
            // systemLayoutSizeFitting that produced the decel "settle jitter".
            // Must run AFTER applyContentConfiguration (which clears the seed).
            // Width-matched inside the memo so a stale portrait height isn't
            // reused after rotation. No measurement is performed here.
            if let layout = viewController?.messageListLayout {
                let cvW = viewController?.collectionView.bounds.width ?? 390
                let key = Self.contentKey(for: item,messages: messages,messageIndex: messageIndex)

                // Register the index→key map
                // on EVERY cell config, not just snapshot apply. The memo write
                // in invalidationContext keys offY contentKeyByIndex[index]; if
                // it's only set during updateMessages (snapshot change), then
                // pure scrolling — where snapshot is unchanged and the jitter
                // actually happens — leaves the map stale/empty, so the measured
                // height is never memoized (observed: memoForKey=none on every
                // re-entry). Setting it here, where index↔item is authoritative
                // for the cell about to be measured, makes the memo actually
                // capture the self-size that follows.
                layout.setContentKey(key,at: indexPath.item)

                #if DEBUG
                // Stamp the stable cell tag on the
                // cell and the layout's index map (only while recording — the
                // hash costs a string scan per configure).
                if ScrollMetricsRecorder.shared.isEnabled {
                    let tag = Self.stableCellTag(for: item,messages: messages,messageIndex: messageIndex)
                    cell.metricsTag = tag
                    layout.setMetricsTag(tag,at: indexPath.item)
                }
                #endif

                // STREAMING EXCLUSION. A cell
                // belonging to the actively-streaming (last assistant) message
                // changes height every token (tool capsule + code block grow as
                // output arrives). It must NEVER be seeded or memoized: a seed
                // would short-circuit self-size and freeze the cell at a stale
                // mid-stream height, leaving the tool cell / code block overlapping
                // adjacent content until the NEXT turn reconfigures it (observed
                // regression). The content-length key already differs per token,
                // but seeding ANY prior length is wrong while it's still growing —
                // so gate it out entirely. Non-streaming history cells keep the
                // seed benefit. Clearing contentKey also disables the memo write
                // on this cell's self-size path.
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
                // The seed short-circuit in SelfSizingCell.preferredLayoutAttributes-
                // Fitting RETURNS the seeded height and SKIPS the real
                // systemLayoutSizeFitting — so the seed value becomes the cell's
                // hard height. That is only safe for a height we ACTUALLY MEASURED
                // before (the `memo` above, from a prior real self-size at this
                // width). `precalcHeight` is an ESTIMATE (boundingRect /
                // char-count) that runs ~4-7pt SHORT of the real height for user
                // bubbles (TextKit line height is tighter than SwiftUI Text's
                // rendered line box). Seeding it locked
                // the cell at the short value, so the SwiftUI Text inside was
                // clipped to "…" while processing, and only expanded once a later
                // reconfigure forced a real measure — exactly the user-reported
                // truncate-then-expand. precalc still serves as prepare()'s
                // layout height (set via setPrecalcHeight in applySnapshot) so the
                // cell's initial POSITION is approximately right, but the cell's
                // real height is always decided by an actual measure, never frozen
                // at an estimate. (The first-mount-measure-storm 方案 D was trading
                // correctness for fewer measures here; correctness wins — a too-
                // short estimate that truncates content is worse than a measure.)
            }

            // Height estimation for items not yet measured — skip if we already
            // have a measured height OR a precalculated height from applySnapshot.
            if let layout = viewController?.messageListLayout,
               !layout.hasMeasuredHeight(at: indexPath.item),
               !layout.hasPrecalcHeight(at: indexPath.item) {
                let est = Self.estimateItemHeight(item,messages: messages,
                                                  width: viewController?.collectionView.bounds.width ?? 390)
                layout.setEstimatedHeight(est,at: indexPath.item)
            }
        }

        /// Subscriptions for bridge detailBlock → sheet presenter forwarding.
        var bridgeSheetSubs: [UUID: AnyCancellable] = [:]

        func getOrCreateBridge(for message: ChatMessage,in messages: [ChatMessage]) -> CellStateBridge {
            if let existing = cellBridgeMap[message.id] { return existing }
            let bridge = CellStateBridge()
            cellBridgeMap[message.id] = bridge
            updateBridge(bridge,message: message,in: messages)
            // Forward detailBlock changes to the VC-level sheet presenter
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

        // MARK: - Bridge Updates

        func updateBridge(_ bridge: CellStateBridge,message: ChatMessage,in messages: [ChatMessage]) {
            guard let vm else { return }
            let isLast = message.id == messages.last?.id
            let isActive = isLast && vm.isProcessing

            bridge.isActiveMessage = isActive
            bridge.commandStartTime = vm.commandStartTime
            bridge.onStop = isActive ? { [weak self] in self?.onStop?() } : nil
            bridge.browserPool = vm.browserTabPool
            bridge.toolSnapshots = vm.toolSnapshots
            bridge.autoRetryAttempt = isLast ? vm.autoRetryAttempt : 0
            bridge.autoRetryCountdown = isLast ? vm.autoRetryCountdown : 0
            // Defense-in-depth: even if vm.canResume
            // is somehow stale-true and vm.isProcessing hasn't flipped yet, do NOT
            // show the "Interrupted — tap Resume" banner while SessionActivityTracker
            // still lists this session as active (same signal the home list spinner
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
            // "Read from Start": replay this whole reply via TTS. Only for assistant
            // messages; disabled while it's the actively-streaming reply.
            bridge.isStreaming = isActive
            bridge.onReadAloud = (message.role == .assistant)
                ? { [weak vm] in vm?.readReplyFromStart(message) }
                : nil
            // "Read Selection" from the text
            // selection menu — speaks the selected snippet via the MiniClaw TTS
            // stack (sanitizer + provider voices + fail-over).
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
                // menu callback so the user's grep of "ChatScreenshot"
                // catches the FULL chain, including which message they
                // long-pressed and the resolved user→assistant pair.
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
                // Update the presenter's revert callback every time the sheet
                // opens so it always points at the current vm. Captured weakly
                // so a closed-over coordinator that's been discarded can't
                // pin the view-model's lifetime.
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

        // MARK: - Bindings

        /// Re-point the coordinator at a NEW view
        /// model instance when SwiftUI hands the (reused) representable a
        /// different MessageListModel for the same mounted chat view. All
        /// Combine subscriptions live in bindViewModel and are keyed to the
        /// old instance — cancel them wholesale and re-subscribe, then push
        /// the current snapshot + scroll flags into the new VM so its
        /// isNearBottom/messages state reflects reality instead of the
        /// initial defaults nobody would otherwise ever update.
        public func rebindViewModelIfNeeded(_ newVM: MessageListModel) {
            if let current = vm,current === newVM { return }
            let hadOld = vm != nil
            #if DEBUG
            ScrollMetricsRecorder.shared.record(
                kind: "rebind", a: hadOld ? 1 : 0,
                note: Self.nbDump(viewController?.collectionView))
            #endif
            AppLogger(category: "ChatList.Scroll").info("[Scroll][rebind] coordinator vm \(hadOld ? "changed" : "was nil") → rebinding subscriptions + resyncing flags")
            subscriptions.removeAll()
            lastMessageSub?.cancel(); lastMessageSub = nil
            lastMessageBlockCountSub?.cancel(); lastMessageBlockCountSub = nil
            lastMessageId = nil
            vm = newVM
            bindViewModel(newVM)
            // Re-apply from the new VM's authoritative messages (identity may
            // be equal content-wise; applySnapshot no-ops on identical ids)
            // and push the CURRENT geometry into the new VM's published flags.
            if !newVM.isLoadingSession {
                applySnapshot(messages: newVM.messages, caller: "rebind")
            }
            syncScrollFlags()
        }

        func bindViewModel(_ vm: MessageListModel) {
            // 1. Messages → snapshot
            // Skip while isLoadingSession — binding 3 handles the post-load apply.
            // This prevents a redundant apply when $messages and $isLoadingSession
            // dispatch to main queue in the same runloop cycle.
            vm.$messages
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msgs in
                    guard let self else { return }
                    // If a load is in flight,
                    // DON'T silently drop this update — applySnapshot would no-op
                    // (it early-returns while isLoadingSession). Record it as
                    // pending so binding 3's true→false edge flushes it. Dropping
                    // it was the empty-list bug: when $messages changed during a
                    // foreground-recovery reload but binding 3's edge was collapsed
                    // by removeDuplicates (or $messages landed just after loading
                    // flipped false in the same cycle), nothing ever re-applied —
                    // the list stayed on its stale/empty snapshot while the VM
                    // (and toolbar) had the full messages.
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
                    // Only act on a genuine true→false transition.
                    guard was,!now else { return }
                    // Flush REGARDLESS
                    // of isProcessing. The old `isProcessing == false` guard left
                    // a mid-loop foreground-resume unflushed: when the app returns
                    // to foreground (resumeAllStreamingUI clears the flag) while
                    // the agent loop is STILL running, the deferred snapshot was
                    // skipped and — because the loop never hits stream-end — the
                    // UI stayed frozen on the last-rendered tool for minutes while
                    // many loop turns ran un-rendered, until an unrelated
                    // sheetDismiss/settle happened to flush. Resume always runs
                    // foreground, so applying the snapshot here is safe.
                    guard self.pendingSnapshotFlag else { return }
                    AppLogger(category: "ChatList.SnapQueue").info("[SnapQueue] suspend-resume flush applied (pendingSnapshotFlag=true, isProcessing=\(vm.isProcessing))")
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
                // Always main-thread: the chokepoint runs on the main actor, but
                // hop defensively so flush never races a background caller.
                let work = {
                    // Flush regardless
                    // of isProcessing — see the objectWillChange sub above. A
                    // foreground-resume while the loop is still running must
                    // re-apply the deferred snapshot, or the UI freezes on the
                    // last-rendered tool until an unrelated sheetDismiss/settle.
                    guard self.pendingSnapshotFlag else { return }
                    AppLogger(category: "ChatList.SnapQueue").info("[SnapQueue] suspend-resume flush (pendingSnapshotFlag=true, isProcessing=\(self.vm?.isProcessing == true))")
                    self.flushPendingSnapshotIfNeeded(caller: "suspend-resume")
                }
                if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
            }

            // 1b. Retry truncation signal — `retryFromToolBlock`'s sub-message
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
                        AppLogger(category: "BlocksLost").info("[BlocksLost] SNAPSHOT REBUILT snapshotItems \(oldCount)→\(newCount) memoryBlocks=\(totalBlocks)")
                    }
                }
                .store(in: &subscriptions)

            // 2. Scroll signals
            vm.scrollToBottomSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self,self.scrollMode == .autoScrolling else { return }
                    self.scrollToBottomNow()
                }
                .store(in: &subscriptions)

            // 2b. Force scroll
            vm.forceScrollToBottom
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self else { return }
                    let cv = self.viewController?.collectionView
                    let layout = self.viewController?.messageListLayout
                    let cachedCount = layout?.debugCachedHeightCount ?? 0
                    let precalcCount = layout?.debugPrecalcHeightCount ?? 0
                    AppLogger(category: "ChatList.Scroll").info("[Scroll][forceScrollToBottom] window=\(cv?.window != nil) contentSize=\(String(format: "%.0f", cv?.contentSize.height ?? 0)) bounds=\(String(format: "%.0f", cv?.bounds.height ?? 0)) adjInsetBot=\(String(format: "%.0f", cv?.adjustedContentInset.bottom ?? 0)) heightCache=\(cachedCount) precalc=\(precalcCount) visibleCells=\(cv?.visibleCells.count ?? 0)")
                    self.vm?.setStreamingUIUpdatesSuspended(false)
                    self.scrollMode = .autoScrolling
                    // Jumping to the bottom resets the up-button's turn-walk.
                    self.lastJumpedUserId = nil
                    self.scrollToBottomNow(animated: true)
                }
                .store(in: &subscriptions)

            // 2c. Up-button: walk back one user turn at a time. Browse action —
            // do NOT re-enable auto-scroll (leave scrollMode as-is so streaming
            // doesn't yank the user back down after they jump up).
            vm.forceScrollToTop
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.scrollToPreviousUserTurn(animated: true)
                }
                .store(in: &subscriptions)

            // 3. Session load
            vm.$isLoadingSession
                .removeDuplicates()
                .dropFirst() // skip initial false — only react to true→false after actual load
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isLoading in
                    guard let self,!isLoading else { return }
                    // Switching into a session resets the up-button turn-walk.
                    self.lastJumpedUserId = nil
                    let isFirstLoad = self.prevSnapshotIds.isEmpty
                    // Only clear caches when items will actually change — prevents
                    // a duplicate dispatch from clearing caches that won't be rebuilt.
                    if let msgs = self.vm?.messages {
                        self.viewController?.messageListLayout?.clearHeightCache()
                        self.attrStringHeightCache.removeAll()
                        self.userBubbleHeightCache.removeAll()
                        // This is the authoritative post-load apply; it carries the
                        // latest messages, so any snapshot deferred during the load
                        // window (bind1 set pendingSnapshotFlag) is now satisfied.
                        //
                        self.pendingSnapshotFlag = false
                        self.applySnapshot(messages: msgs, caller: "bind3-sessionLoad")
                    }
                    if isFirstLoad {
                        // First load: scroll to bottom and clamp.
                        // 8s window (was 2s) so async video thumbnail
                        // generation can complete and the cell-height
                        // correction reaches the user before we release
                        // the bottom pin.
                        self.scrollMode = .autoScrolling
                        self.clampAfterSessionLoad = true
                        self.clampDeadline = Date().addingTimeInterval(8.0)
                        self.scrollToLastItem()
                    }
                    // Sync reload: keep current scroll position, just update data
                }
                .store(in: &subscriptions)

            // 4. Streaming: subscribe to last assistant message + block count changes.
            // Use the last assistant message (not msgs.last) because queued user
            // messages can be appended while an assistant is still streaming.
            vm.$messages
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msgs in
                    let lastAIMsg = msgs.last(where: { $0.role == .assistant })
                    self?.subscribeToLastMessage(lastAIMsg)
                }
                .store(in: &subscriptions)

            // 4b. Re-subscribe when isProcessing transitions to true (retry/resume).
            // Retry reuses the existing assistant message without mutating the messages
            // array, so $messages won't fire. The block-count subscription was torn down
            // when processing stopped; re-establish it here.
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

            // 5. State changes → bridge updates
            Publishers.CombineLatest4(
                vm.$isProcessing,vm.$autoRetryAttempt,
                vm.$autoRetryCountdown,vm.$canResume
            )
            .removeDuplicates { a,b in a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLastCellBridge() }
            .store(in: &subscriptions)

            // 6. Compact finished → reconfigure all cells to update opacity/divider
            vm.$isCompacting
                .removeDuplicates()
                .dropFirst() // skip initial value — only react to actual true→false transitions
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isCompacting in
                    guard let self,!isCompacting else { return }
                    // Compact just ended — apply snapshot for new divider/removed messages,
                    // then reconfigure visible cells so opacity updates. Do NOT clear height
                    // cache — compacted messages retain their measured heights to prevent
                    // scroll jitter when scrolling back into the compacted zone.
                    if let msgs = self.vm?.messages { self.applySnapshot(messages: msgs, caller: "bind6-compact") }
                    self.reconfigureVisibleCells()
                }
                .store(in: &subscriptions)

            // 7. Font size changes
            NotificationCenter.default.publisher(for: .fontSettingsMessageBaseChanged)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.vm?.invalidateAttributedStringCaches()
                    self.reconfigureAllCells()
                }
                .store(in: &subscriptions)

            // 8a. Background entry — snapshot content length so we can detect
            // whether significant content accumulated while backgrounded.
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    let len = self.lastAssistantContentLength()
                    self.contentLengthAtBackground = len
                    AppLogger(category: "ChatList.Layout").info("[FGLayout] → background, snapshotLen=\(len)")
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
                    AppLogger(category: "ChatList.Layout").info("[FGLayout] → foreground, bgLen=\(bgLen) currentLen=\(currentLen) accumulated=\(accumulated)")
                    guard accumulated >= 200 else {
                        AppLogger(category: "ChatList.Layout").info("[FGLayout] skip layout (accumulated \(accumulated) < 200)")
                        return
                    }
                    AppLogger(category: "ChatList.Layout").info("[FGLayout] invalidating layout for \(self.viewController?.collectionView.indexPathsForVisibleItems.count ?? 0) visible cells")
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

            // 9. Text block filled — reconfigure the cell so UIHostingConfiguration
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

                    // Invalidate the height cache BEFORE reconfiguring so the
                    // layout doesn't reuse the stale empty-content height.
                    // Without this, the cell briefly keeps its ~0pt height from
                    // the empty block, causing overlap with the tool block above.
                    self.viewController?.messageListLayout?.invalidateHeight(at: idx)

                    snapshot.reconfigureItems([item])
                    ds.apply(snapshot,animatingDifferences: false)
                }
                .store(in: &subscriptions)

            // Re-snapshot when toggleUsage inserts/removes a footer cell.
            NotificationCenter.default.publisher(for: .messageListNeedsResnapshot)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self,let vm = self.vm else { return }
                    self.applySnapshot(messages: vm.messages)
                }
                .store(in: &subscriptions)
        }

        // MARK: - Content Length Helper

        /// Total character count across all blocks of the last assistant message.
        func lastAssistantContentLength() -> Int {
            guard let msg = vm?.messages.last(where: { $0.role == .assistant }) else { return 0 }
            return msg.blocks.reduce(0) { $0+$1.content.count }
        }

    }
}
public struct MessageCollectionView: UIViewControllerRepresentable {
    @ObservedObject public var vm: MessageListModel
    public var inputFocused: Bool
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
        // The coordinator captured `vm` once in
        // makeUIViewController → attach. SwiftUI reuses this representable's
        // platform VC (and coordinator) across ChatView re-creations, so when
        // the ViewModelCache hands the re-created view a NEW MessageListModel
        // instance for the same session, the coordinator kept driving the OLD
        // one: every isNearBottom write landed on a VM nothing was observing,
        // while the overlay's VM stayed at its initial isNearBottom=true — the
        // floating ↑/↓ buttons never appeared again for the whole session
        // (device ring trace: coordinator vm read false at every sync while
        // the buttons stayed hidden at diff≈2700pt from the bottom).
        coord.rebindViewModelIfNeeded(vm)
        coord.onRetryMessage = onRetryMessage
        coord.onRetryLast = onRetryLast
        coord.onEdit = onEdit
        coord.onWithdraw = onWithdraw
        coord.onSendQueued = onSendQueued
        coord.onResume = onResume
        coord.onStop = onStop
        coord.onCompact = onCompact
        coord.onRevertCompact = onRevertCompact
        coord.onForceSync = onForceSync
        coord.onScreenshotImage = onScreenshotImage
        coord.maxContentWidth = maxContentWidth

        // Bottom inset base = input bar + tool bar overlay height + breathing room.
        // applySubViewportCompensation is the only writer of cv.contentInset.bottom;
        // it reads coord.baseBottomInset and adds overflowH on top when needed.
        //
        // [T-bottom-occluded 0a6d3c92] introduced +16 to fix a perceived
        // clip of the last bubble's bottom text. That report turned out
        // to be the cell-height bug fixed in [ClipFix 2026-05-16]
        // (boundingRect / mtv missing textContainerInset). With cell
        // heights now accurate the +16 breathing room becomes pure
        // dead space — observed as ~100pt gapH between the last bubble
        // and the composer top. Restored to the historical +8.
        let bottomPadVal: CGFloat = inputBarHeight+floatingBarHeight+8
        let baseChanged = abs(coord.baseBottomInset-bottomPadVal)>0.5
        if baseChanged {
            let cv = vc.collectionView!
            let wasSmaller = coord.baseBottomInset<bottomPadVal
            // Capture follow-intent BEFORE mutating the inset: enlarging the
            // inset enlarges maxOffset, so a user pinned at the bottom would
            // measure as >20pt away from it and fail the isNearBottom() guard.
            let wasNearBottomBefore = coord.isNearBottom()
            coord.baseBottomInset = bottomPadVal
            // [KbdDiag 2026-08-11] baseBottomInset 写入打点:base = inputBarHeight + floatingBarHeight + 8。
            AppLogger(category: "ChatList.Keyboard").info("[Keyboard] baseBottomInset \(String(format: "%.1f", coord.baseBottomInset))←\(String(format: "%.1f", bottomPadVal)) inputBarHeight=\(String(format: "%.1f", inputBarHeight)) floatingBarHeight=\(String(format: "%.1f", floatingBarHeight))")
            // Apply the base immediately so contentInset.bottom reflects the
            // new base before applySubViewportCompensation runs (which may
            // further inflate it). Compensation will overwrite if needed.
            cv.contentInset.bottom = bottomPadVal
            if wasSmaller && (coord.scrollMode == .autoScrolling || wasNearBottomBefore) {
                coord.scrollMode = .autoScrolling
                coord.scrollToBottomNow(animated: false)
            }
        }

        // [T-first-msg-top-gapH 2026-07-18] Apply the top inset. User report
        // (iOS 16 screenshot): the first user bubble sat flush against the
        // opaque navbar — common to ALL of iOS 16-18, because
        // `baseContentInsetTop` (designed as "8pt manual padding on older
        // iOS", see its doc) was defined but never written into
        // cv.contentInset.top anywhere; the legacy nav layout doesn't extend
        // content behind the bar, so the collection view's own top edge IS
        // the navbar bottom and the first row rendered with zero breathing
        // room. iOS 26 returns 0 here (liquid-glass + .automatic adjustment
        // already position content), so this is a no-op there.
        let cvTop = vc.collectionView!
        if abs(cvTop.contentInset.top-coord.baseContentInsetTop)>0.5 {
            cvTop.contentInset.top = coord.baseContentInsetTop
        }

        coord.applySubViewportCompensation(caller: "updateUIVC")

        // Backstop: if a snapshot was
        // deferred during a load (bind1) but binding 3's true→false edge was
        // missed (removeDuplicates collapse, or $isLoadingSession settling in
        // the same runloop cycle the snapshot was deferred), the list would be
        // stranded empty while the VM has messages. updateUIViewController runs
        // on every SwiftUI re-render (e.g. the toolbar updating — exactly the
        // observed "toolbar updates, list blank" symptom), so flush here once
        // loading has finished. Gated on NOT being in a streaming-suspend window
        // so we never pre-empt the suspend-resume machinery (which intentionally
        // holds pendingSnapshotFlag during scroll-settle / background streaming);
        // that path has its own flush on resume. flushPendingSnapshotIfNeeded
        // no-ops when nothing is pending, so this is free on the happy path.
        if !vm.isLoadingSession && !vm.streamingUIUpdatesSuspended {
            coord.flushPendingSnapshotIfNeeded(caller: "updateUIVC-backstop")
        }

        if inputFocused != coord.lastInputFocused {
            let wasNearBottom = coord.scrollMode == .autoScrolling && coord.isNearBottom()
            coord.lastInputFocused = inputFocused
            if inputFocused {
                // [B2 2026-08-11] 键盘弹出(用户点击输入框)时延迟贴底:
                // 打字刷新的效果(=updateUIViewController 重跑→re-pin)提前到点击时刻。
                // 关键参数(2026-08-11 实测调整):
                // · 延迟 0.6s:必须大于键盘弹出动画(约 0.35-0.4s),等 bounds 完全稳定
                // 后再算 maxOff,否则按动画中间帧的 bounds 贴到错误位置;
                // · animated: false:瞬时跳转,避免动画滚动被 bounds 变化打断
                // (曾导致 2-5 秒卡顿 + 位置不对)。
                DispatchQueue.main.asyncAfter(deadline: .now()+0.6) { [weak coord] in
                    coord?.scrollMode = .autoScrolling
                    coord?.scrollToBottomNow(animated: false)
                    AppLogger(category: "ChatList.Scroll").info("[Scroll][B2-focus] keyboard shown → re-pin bottom (delayed 0.6s, no anim)")
                }
            } else if wasNearBottom {
                // 键盘收起:维持原逻辑(仅近底时贴底,浏览历史不打扰)。
                DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { [weak coord] in
                    coord?.scrollToBottomNow(animated: true)
                }
            }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    enum Section { case main }
}

// MARK: - Bridged Cell Views (no GeometryReader)

/// Header: "✦ MiniClaw" label at the top of each assistant turn.
/// Name comes from SOUL.md (user-editable in Soul Settings); the
/// sparkles glyph is fixed — custom emoji is no longer supported,
/// matching the Soul Settings UI.
extension Notification.Name {
    /// Posted by toggleUsage to tell the Coordinator to re-snapshot so the
    /// footer cell is inserted or removed on demand.
    static let messageListNeedsResnapshot = Notification.Name("messageListNeedsResnapshot")
}

// MARK: - MessageCollectionView

/// Message list: cell-per-block model with a simplified
/// scroll stability architecture:
///
/// - **Single height source**: UIKit self-sizing only (no GeometryReader)
/// - **3-tier height resolution**: measured cache → precalc (NSAttributedString) → estimate
/// - **2-state scroll model**: autoScrolling / userBrowsing
/// - **O(1) message lookup**: UUID index rebuilt on each snapshot
private final class AssistantHeaderCell: SelfSizingCell {}