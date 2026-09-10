import SwiftUI
import UIKit

// MARK: - 工具卡片独立窗口呈现器
//
// 唐唐 2026-09-01 拍板：工具卡片浮层是**叠加在会话页之上的独立呈现层**，
// 严禁通过修改会话页的宿主视图（host frame/可见性/布局）来实现——
// 那会破坏消息列表原有的滑动与布局逻辑（已踩坑回滚）。
//
// 实现：独立 UIWindow（windowLevel 略低于状态栏、高于应用内容），
// rootViewController 为 UIHostingController(ToolCardOverlay)。窗口天然全屏
// 坐标系（GeometryReader 正确），出现/关闭动画由 ToolCardOverlay 内部状态驱动，
// 窗口只负责显示与隐藏。密钥/会话数据不经过本层。

@MainActor
final class ToolCardWindowPresenter {
    static let shared = ToolCardWindowPresenter()

    private var window: UIWindow?
    private var onDismiss: (() -> Void)?

    private init() {}

    /// 呈现工具卡片浮层。
    /// - Parameter onDismiss: 卡片关闭完成后的回调（宿主用于收尾，如快照落盘）。
    func present(
        toolBlocks: [AssistantBlock],
        initialBlockID: UUID,
        toolSnapshots: [ToolSnapshotItem] = [],
        snapshotBridge: CellStateBridge? = nil,
        browserPool: MiniClawTabPool? = nil,
        browserContentProvider: ((URL?) -> AnyView)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.onDismiss = onDismiss

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let overlay = ToolCardOverlay(
            toolBlocks: toolBlocks,
            initialBlockID: initialBlockID,
            toolSnapshots: toolSnapshots,
            snapshotBridge: snapshotBridge,
            browserPool: browserPool,
            browserContentProvider: browserContentProvider,
            onClose: { [weak self] in self?.closeAndHide() }
        )
        let host = UIHostingController(rootView: overlay)
        host.view.backgroundColor = .clear

        let win = window ?? UIWindow(windowScene: scene)
        win.windowLevel = .statusBar - 1
        win.rootViewController = host
        win.isHidden = false
        self.window = win
    }

    /// 卡片关闭动画播完后由 onClose 触发：隐藏窗口并回调宿主。
    private func closeAndHide() {
        window?.isHidden = true
        let cb = onDismiss
        onDismiss = nil
        cb?()
    }
}
