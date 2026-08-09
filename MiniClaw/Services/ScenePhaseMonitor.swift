import Foundation
import os

/// 轻量场景相位监控：由 `ScenePhaseBridge`（SwiftUI 环境）写入，供后台任务（如 AgentLoopEngine）
/// 判定 App 当前是否处于前台，从而在「退后台期间网络请求失败」后等待回到前台再重试。
///
/// 不引入 SwiftUI 依赖：相位以字符串（"Active" / "Inactive" / "Background" / "Unknown"）传递，
/// 与 `ScenePhaseBridge` 现有的描述保持一致。
final class ScenePhaseMonitor: @unchecked Sendable {
    static let shared = ScenePhaseMonitor()

    private let lock = OSAllocatedUnfairLock(initialState: "Unknown")

    func set(_ desc: String) {
        lock.withLock { $0 = desc }
    }

    /// App 是否处于前台活跃状态。
    var isActive: Bool {
        lock.withLock { $0 == "Active" }
    }
}
