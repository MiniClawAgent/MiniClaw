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

        var decelDisplayLink: CADisplayLink?

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
        var snapshotMessages: [RenderMessage] = []

        var cellBridgeMap: [UUID: CellStateBridge] = [:]

        var attrStringHeightCache: [ObjectIdentifier: CGFloat] = [:]
        /// Caches accurate user-bubble
        var userBubbleHeightCache: [String: CGFloat] = [:]

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
                    AppLogger(category: "ChatList.Keyboard").info("[Keyboard] adjustedInset.bottom=\(String(format: "%.1f", new.bottom)) safeArea.bottom=\(String(format: "%.1f", cv.safeAreaInsets.bottom)) bounds.h=\(String(format: "%.1f", cv.bounds.height)) contentInset.bottom=\(String(format: "%.1f", cv.contentInset.bottom)) offset.y=\(String(format: "%.1f", cv.contentOffset.y)) mode=\(self.scrollMode)")
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

                if delta>0 && self.scrollMode == .autoScrolling {
                    if self.isAnimatingScrollToBottom {
                        self.scheduleCoalescedScroll()
                    } else {
                        let maxOff = newH-cv.bounds.height+cv.adjustedContentInset.bottom
                        if maxOff>0 {
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
                    AppLogger(category: "ChatList.Stream").info("[KVO] contentSize grew +\(String(format: "%.0f", delta)) IN BROWSE MODE — no pin. offset=\(String(format: "%.0f", cv.contentOffset.y)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating)")
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

        func currentIndex(for item: MessageListItem) -> Int? {
            return itemToIndex[item]
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
                let est = Self.estimateItemHeight(item,messages: messages,
                                                  width: viewController?.collectionView.bounds.width ?? 390)
                layout.setEstimatedHeight(est,at: indexPath.item)
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
            AppLogger(category: "ChatList.Scroll").info("[Scroll][rebind] coordinator vm \(hadOld ? "changed" : "was nil") → rebinding subscriptions + resyncing flags")
            // [回看裁剪修复 2026-09-10] rebind = 离开会话再回来（同挂载视图换会话/
            // 换 vm）。索引高度条目按 item 身份重映射会原样带走旧实测值，而块内容
            // 可能已在离屏期间原地增长——旧矮高度被 .measured 优先级永久压住。
            // 清索引条目（**保留进程级 contentKey memo**，方案 C 设计如此），
            // 让随后的播种直接读 memo：回到任意一段 = 直接读该内容完成时的缓存。
            viewController?.messageListLayout?.clearHeightCache(keepingSharedMemo: true)
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
                let work = {
                    // Flush regardless
                    guard self.pendingSnapshotFlag else { return }
                    AppLogger(category: "ChatList.SnapQueue").info("[SnapQueue] suspend-resume flush (pendingSnapshotFlag=true, isProcessing=\(self.vm?.isProcessing == true))")
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
                        AppLogger(category: "BlocksLost").info("[BlocksLost] SNAPSHOT REBUILT snapshotItems \(oldCount)→\(newCount) memoryBlocks=\(totalBlocks)")
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
                        self.attrStringHeightCache.removeAll()
                        self.userBubbleHeightCache.removeAll()
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
                    guard let self else { return }
                    self.vm?.invalidateAttributedStringCaches()
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
                    self.applySnapshot(messages: vm.messages)
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
        coord.onRevertCompact = onRevertCompact
        coord.onForceSync = onForceSync
        coord.onScreenshotImage = onScreenshotImage
        coord.maxContentWidth = maxContentWidth

        // it reads coord.baseBottomInset and adds overflowH on top when needed.
        //
        // dead space — observed as ~100pt gapH between the last bubble
        let bottomPadVal: CGFloat = inputBarHeight+floatingBarHeight+8
        let baseChanged = abs(coord.baseBottomInset-bottomPadVal)>0.5
        if baseChanged {
            let cv = vc.collectionView!
            let wasSmaller = coord.baseBottomInset<bottomPadVal
            let wasNearBottomBefore = coord.isNearBottom()
            coord.baseBottomInset = bottomPadVal
            // [KbdDiag 2026-08-11] baseBottomInset 写入打点:base = inputBarHeight + floatingBarHeight + 8。
            AppLogger(category: "ChatList.Keyboard").info("[Keyboard] baseBottomInset \(String(format: "%.1f", coord.baseBottomInset))←\(String(format: "%.1f", bottomPadVal)) inputBarHeight=\(String(format: "%.1f", inputBarHeight)) floatingBarHeight=\(String(format: "%.1f", floatingBarHeight))")
            cv.contentInset.bottom = bottomPadVal
            if wasSmaller && (coord.scrollMode == .autoScrolling || wasNearBottomBefore) {
                coord.scrollMode = .autoScrolling
                coord.scrollToBottomNow(animated: false)
            }
        }

        // [T-first-msg-top-gapH 2026-07-18] Apply the top inset. User report
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
    static let messageListNeedsResnapshot = Notification.Name("messageListNeedsResnapshot")
}

// MARK: - MessageCollectionView

/// Message list: cell-per-block model with a simplified
/// scroll stability architecture:
///
/// - **2-state scroll model**: autoScrolling / userBrowsing
private final class AssistantHeaderCell: SelfSizingCell {}