//
// MessageListInfrastructure.swift
// MiniClawApp
//
// Shared types for the collection-view-based chat message list.
// Shared infrastructure types used by the message list.
// MarkdownView / MarkdownRenderView walk the view hierarchy
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
        collectionView.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .onDrag
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .automatic
        view.addSubview(collectionView)
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

    /// When true, non-snapshot programmatic layout
    var streamingGrowAnimationEnabled = true

    /// Reentrancy guard: the grow path calls
    private var inStreamGrow = false

    weak var owningViewController: MessageListViewController?

    /// `lastBounds` so the prewarm path compiles in every configuration.
    ///
    private var lastPreWarmW: CGFloat = 0

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
        } else if streamingGrowAnimationEnabled,isStreamingNow,contentOverflowsViewport,
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

    /// The width at which `lastCalcH` was measured. Used by the
    /// short-window dedup so a width change still re-measures.
    private var lastCalcW: CGFloat?

    /// CACurrentMediaTime() of the last successful self-measure. Within a
    /// short window after a measure, repeated `preferredLayoutAttributesFitting`
    /// calls (UICollectionView fires several per frame on bounds change /
    /// scroll begin / pinch / etc.) reuse the cached height *without* calling
    /// `super.preferredLayoutAttributesFitting` or `systemLayoutSizeFitting`.
    /// This shrinks the window where the main thread races with SwiftUI's
    /// async display-link thread mutating ViewGraphGeometryObservers
    /// (FB13213926) — the recurring crash on the
    /// `nswtsUU8p6mRY9Pj7c7tU.xccrashpoint`. Set high enough to absorb the
    /// burst of measure calls one collection-view layout pass triggers,
    /// low enough that genuine content/state changes still re-measure
    /// promptly (applyContentConfiguration / clearCachedHeight reset it
    /// to nil unconditionally).
    private var lastMeasureMedia: CFTimeInterval?
    private static let measureDedupWindow: CFTimeInterval = 0.050 // 50 ms

    /// Pre-seeded height from the layout's
    /// measured on a previous appearance. Unlike `lastCalcH`, this is
    ///
    private var seedH: CGFloat?
    private var seedW: CGFloat?

    /// Stable content key for the item this
    var contentKey: String?

    #if DEBUG
    /// Stable content-hash identity (set by
    var metricsTag: String?
    #endif

    func seedMeasuredHeight(_ height: CGFloat,width: CGFloat) {
        guard height >= 4,width>1 else { return }
        seedH = height
        seedW = width
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
    }

    private static let sizingLogger = AppLogger(category: "ChatList.CellMetrics")

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        // Short-window dedup BEFORE super: when UIKit fires repeated
        // self-sizing calls within `measureDedupWindow`, return the cached
        if let cached = lastCalcH,
           let cachedW = lastCalcW,
           let lastT = lastMeasureMedia,
           abs(layoutAttributes.size.width-cachedW)<1,
           CACurrentMediaTime()-lastT<Self.measureDedupWindow {
            let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
            copy.size.width = cachedW
            copy.size.height = cached
            return copy
        }

        //
        //
        // neither write lastCalcH nor mutate the height (which previously
        guard superview is UICollectionView,window != nil,contentConfiguration != nil else {
            return layoutAttributes
        }

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
                // MarkdownRenderView 的测量本身便宜（usedRect），实测不再昂贵。
                let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
                copy.size.width = cachedW
                copy.size.height = cached
                return copy
            }
            if isStreamingItem,
               // 只短路在 precalc 来源上（种子循环每个 chunk 重播种的
               // TextKit 校准值）。合并字典后 precalcHeight 对任意来源返回值，
               // 不加来源判定会把首帧陈旧估高当 precalc 返回并跳过实测——
               // 流式 cell 冻结在首帧高度，正文与下方内容重叠（2026-09-05 回归）。
               // 无 precalc（工具胶囊/思考块/footer）保持实测，与旧
               // precalcHeights 字典语义一致。
               layout.hasPrecalcHeight(at: item),
               let precalc = layout.precalcHeight(at: item) {
                let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
                copy.size.height = precalc
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
            lastCalcH = sh
            lastCalcW = layoutAttributes.size.width
            lastMeasureMedia = CACurrentMediaTime()
            let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
            copy.size.height = sh
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
                copy.size.height = cached
                return copy
            }
            return layoutAttributes
        }
        let attrs = superAttrs

        if let cached = lastCalcH,
           abs(layoutAttributes.size.width-attrs.size.width)<1 {
            // [2026-09-11 崩溃修复] super.PLAF 的 hosting 实测与 NegMeasure 家族
            // 同源——可能返回损坏值（2026-09-09 真机实录 -40，EXC_BAD_ACCESS 同在
            // ViewGraphGeometryObservers.needsUpdate）。损坏值原被 cached 短路掩盖；
            // 放行分支必须同样拦截：非有限/负值一律弃用实测、维持 cached。
            let measured = attrs.size.height
            guard measured.isFinite,measured >= 0,cached.isFinite,cached >= 0 else {
                attrs.size.height = max(cached.isFinite ? cached : 0,0)
                return attrs
            }
            // [回看裁剪修复 2026-09-10] lastCalcH 只做 ≤2pt 微差平滑；实测与缓存差
            // >2pt（典型=块内容离屏期间原地增长）放行真实高度，并推进 lastCalcH
            // 让短窗 dedup(:401) 与后续 pass 读到新值，避免振荡。
            if abs(measured-cached) > 2 {
                lastCalcH = measured
                lastMeasureMedia = CACurrentMediaTime()
            } else {
                attrs.size.height = cached
            }
            return attrs
        }

        let gen = cfgGen
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
        guard cfgGen == gen else { return attrs }
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
        attrs.size.height = clampedFit
        if fittingSize.height >= 4 {
            lastCalcH = fittingSize.height
            lastCalcW = layoutAttributes.size.width
            lastMeasureMedia = CACurrentMediaTime()
            // Memoize the real height under the
            if let key = contentKey,
               let cv = superview as? UICollectionView,
               let layout = cv.collectionViewLayout as? MessageListLayout {
                layout.recordMeasuredHeight(forKey: key,height: fittingSize.height,boundsWidth: cv.bounds.width)
            }
        }
        #if DEBUG
        // Capture message-list snapshot right after
        let cellPtr = String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        MessageListSnapshotCollector.captureIfEnabled(from: self, trigger: "cell.PLAF", triggerDetail: cellPtr)
        #endif
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
    }
}
