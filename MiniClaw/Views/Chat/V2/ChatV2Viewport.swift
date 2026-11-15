import Foundation
import CoreGraphics

// ChatV2Viewport —— 会话页 V2 的视口所有者（本工程唯一写 offset / inset 的地方）。
// 唯一写入者：只有本类写 contentOffset / contentInset。Screen / Composer 只上报事件、
//   只读 isPinnedToBottom；写回 UIKit 的出口只有 applyOffset / applyBottomInset 两个闭包。
// 为什么同一帧只写一次：一次 runloop 里事件会连发（流式增长 + 键盘 inset + 用户松手），
//   逐个写 offset 会让列表在同一帧被反复推拉（每次 setContentOffset 又会回调
//   scrollViewDidScroll，反过来喂回事件）。所以这里只记「本帧最终想去哪」（pendingOffset），
//   帧末合并成一次写入，并对 1e-3 内的重复值去重。
//
// 语义（严格按契约，不做额外启发式）：
// - isPinnedToBottom 只由「用户松手」与「显式 pinToBottom」改写；
// - 贴底目标 offset 恒为 contentHeight - viewportHeight + bottomInset，下界按 0 夹
//   （V2 没有 topInset；上界与行级锚点都留给调用方，本类不做）；
// - 纯逻辑：不 import UIKit，不持有 scroll view，只读三个闭包、只调两个闭包；
// - 线程：主线程使用，整个类 @MainActor。
//
// 关于 `@preconcurrency ChatV2ViewportOwning`：契约里的协议是**非隔离**的，
// 而 Swift 6 语言模式下 @MainActor 类型直接遵循非隔离协议会报 ConformanceIsolation
// 错误。本类只在主线程被使用（Screen/Composer 均在主线程），故用 @preconcurrency
// 显式声明「按旧语义遵循该协议」，不修改契约文件。

@MainActor
final class ChatV2Viewport: @preconcurrency ChatV2ViewportOwning {

    // MARK: - 状态（只有这两个真相）

    /// 是否贴底。只有 `.userScrollEnded` 与 `.pinToBottom` 能改它。
    private(set) var isPinnedToBottom: Bool = true

    /// 底部遮挡高度：Composer + 安全区 + 浮动栏（**不含键盘**，键盘由系统压缩列表）。
    /// 只由 `.obscuredBottomChanged` 累加；本类不夹下界（inset 是高度语义，负值即上游算错）。
    private(set) var bottomInset: CGFloat = 0

    // MARK: - 输出（写回 UIKit 的唯一出口）

    /// 一帧内最多回调一次；`animated` 表示这一次是否应带动画。
    var applyOffset: ((CGFloat, Bool) -> Void)?

    /// inset 真正变化时回调一次（值没变则不回调）。
    var applyBottomInset: ((CGFloat) -> Void)?

    // MARK: - 输入（attach 注入）

    private var contentHeightProvider: (() -> CGFloat)?
    private var viewportHeightProvider: (() -> CGFloat)?
    private var currentOffsetProvider: (() -> CGFloat)?

    // MARK: - 同帧合并

    private static let epsilon: CGFloat = 1e-3
    private var pendingOffset: CGFloat?
    private var pendingAnimated = false
    private var flushScheduled = false
    private var lastAppliedOffset: CGFloat?

    init() {}

    // MARK: - ChatV2ViewportOwning

    func attach(contentHeight: @escaping () -> CGFloat,
                viewportHeight: @escaping () -> CGFloat,
                currentOffset: @escaping () -> CGFloat) {
        self.contentHeightProvider = contentHeight
        self.viewportHeightProvider = viewportHeight
        self.currentOffsetProvider = currentOffset
    }

    func handle(_ event: ChatV2ViewportEvent) {
        switch event {
        case .userScrollEnded(let atBottom):
            // 用户的手动位置优先：只改判定，绝不改 offset。
            isPinnedToBottom = atBottom

        case .contentGrewAtBottom(let delta):
            guard requireFinite(delta, "contentGrewAtBottom.delta") else { return }
            // 不贴底就不追底；delta 为 0 表示底边没变，没必要写。
            guard isPinnedToBottom, delta != 0 else { return }
            guard let geometry = currentGeometry() else { return }
            scheduleBottomOffset(geometry, animated: false)

        case .contentResized:
            // 内容在上方变化：V2 先不做行级锚点，offset 一律不动（补偿与否由调用方决定）。
            break

        case .obscuredBottomChanged(let delta):
            guard requireFinite(delta, "obscuredBottomChanged.delta") else { return }
            let newInset = bottomInset + delta
            guard requireFinite(newInset, "bottomInset") else { return }
            guard newInset != bottomInset else { return }
            bottomInset = newInset
            // inset 真的变了 → 回调一次（值没变时上面的 guard 已经返回）。
            applyBottomInset?(newInset)
            // 贴底：底边跟着 inset 走，重算 offset；没贴底：用户停在哪就停在哪。
            guard isPinnedToBottom, let geometry = currentGeometry() else { return }
            scheduleBottomOffset(geometry, animated: false)

        case .pinToBottom:
            isPinnedToBottom = true
            guard let geometry = currentGeometry() else { return }
            // 显式贴底是用户动作（发送消息 / 点「回到底部」），带动画。
            scheduleBottomOffset(geometry, animated: true)
        }
    }

    // MARK: - 几何

    /// 贴底目标所需的两个只读量。
    private struct Geometry {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
    }

    /// 读取并校验当前几何。任一值非有限或为负 → 丢弃该次事件（DEBUG 断言）。
    private func currentGeometry() -> Geometry? {
        guard let contentHeightProvider, let viewportHeightProvider else {
            // attach 之前收到需要几何的事件：静默丢弃（此时没有任何可写出口，也无可校验的值）。
            return nil
        }
        let contentHeight = contentHeightProvider()
        let viewportHeight = viewportHeightProvider()
        guard contentHeight.isFinite, contentHeight >= 0,
              viewportHeight.isFinite, viewportHeight >= 0 else {
            #if DEBUG
            assertionFailure("ChatV2Viewport: 几何非法 contentHeight=\(contentHeight) "
                + "viewportHeight=\(viewportHeight)，已丢弃该次事件")
            #endif
            return nil
        }
        return Geometry(contentHeight: contentHeight, viewportHeight: viewportHeight)
    }

    /// 贴底时的目标 offset：`contentHeight - viewportHeight + bottomInset`，下界按 0 夹。
    private func bottomOffset(for geometry: Geometry) -> CGFloat {
        max(0, geometry.contentHeight - geometry.viewportHeight + bottomInset)
    }

    // MARK: - 同帧合并与写回

    private func scheduleBottomOffset(_ geometry: Geometry, animated: Bool) {
        schedule(bottomOffset(for: geometry), animated: animated)
    }

    /// 记录本帧的目标 offset。同一帧内多次调用只保留最后一个值，
    /// 帧末（下一次主线程调度）由 `flushPendingOffset()` 统一写一次。
    private func schedule(_ offset: CGFloat, animated: Bool) {
        // 几何与 delta 已在入口校验过有限性，这里是最后一道防线。
        guard offset.isFinite else { return }
        pendingOffset = offset
        // 本帧只要有一次要求动画（pinToBottom），就按动画执行，
        // 免得 pin 的动画被同帧的流式增长打断成瞬移。
        pendingAnimated = pendingAnimated || animated
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            self?.flushPendingOffset()
        }
    }

    private func flushPendingOffset() {
        flushScheduled = false
        guard let target = pendingOffset else { return }
        let animated = pendingAnimated
        pendingOffset = nil
        pendingAnimated = false

        // 合并窗口内用户松手改成了「不贴底」：用户位置优先，丢掉这次排队中的写入。
        guard isPinnedToBottom else { return }

        // 1e-3 内视为同一个位置：不重复写，避免无意义的 layout 与事件回灌。
        if let current = currentOffsetProvider?(), current.isFinite,
           abs(current - target) <= Self.epsilon {
            lastAppliedOffset = target
            return
        }
        if let lastAppliedOffset, abs(lastAppliedOffset - target) <= Self.epsilon {
            return
        }

        lastAppliedOffset = target
        applyOffset?(target, animated)
    }

    // MARK: - 数值防御

    /// 非有限值视为上游算错：丢弃该次事件，DEBUG 直接断言出来。
    private func requireFinite(_ value: CGFloat, _ label: String) -> Bool {
        guard value.isFinite else {
            #if DEBUG
            assertionFailure("ChatV2Viewport: \(label) 非有限值 \(value)，已丢弃该次事件")
            #endif
            return false
        }
        return true
    }
}
