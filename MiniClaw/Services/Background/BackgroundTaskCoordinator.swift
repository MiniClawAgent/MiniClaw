import Foundation
import UIKit
import os

// MARK: - 后台任务协调器（对齐 哲学，自研实现）

/// 对齐 的后台任务生命周期管理（自研实现，非代码复刻）。
///
/// ## 要解决的问题
/// Agent 主循环在后台运行时（网络请求 / 工具执行），iOS 会在「后台宽限期」结束后挂起整个进程。
/// 若不加保护，循环会在一个未完成的网络/工具调用中途被冻结，回前台时表现为「卡死 / 闪退」，
/// 这是 Apple 审核红线。 用 `beginBackgroundTask` 申请宽限期，过期前优雅挂起循环、
/// 停掉正在跑的工具，回前台用 continuation 自动续跑。
///
/// ## 设计要点（按用户要求：标准 UIBackgroundTask，无 Info.plist 后台模式，零审核风险）
/// - `begin()`：申请一个系统后台任务（带 name「AgentLoop」），并挂过期处理器。幂等（已持有则忽略）。
/// - 过期处理器：宽限期耗尽时把 `suspended` 置真、结束已过期任务、广播 `.didExpire` 让引擎取消当前工具
///   （让循环在安全点干净停下）。不主动再延长——我们没有音频/定位等后台模式，无 Info.plist 模式即无法
///   真正常驻，拖延无意义。
/// - `waitIfSuspended() async`：循环在安全点调用；若已 suspended 则挂起在 continuation 上，
///   直到 `willEnterForegroundNotification` 复位并续跑。
/// - 前后台通知：进后台启动「剩余时间监测定时器」（<15s 告警，留日志便于定位）；回前台复位、续跑、重新申请。
///
/// ## 隔离说明
/// 类本身非隔离；仅触碰 UIKit 的方法标 `@MainActor`（UIApplication 为主线程隔离）。`waitIfSuspended`
/// 不碰 UIKit，保持非隔离 async，避免主循环在挂起点无谓切主线程。
///
/// ## 范围
/// 仅主引擎（非子代理）持有系统后台任务，避免单例 token 冲突；子代理运行在主循环的保护范围内。
final class BackgroundTaskCoordinator {

    /// 宽限期耗尽时广播：引擎据此取消正在跑的工具，循环在下一安全点干净停住。
    static let didExpireNotification = Notification.Name("BackgroundTaskCoordinator.didExpire")

    nonisolated(unsafe) static let shared = BackgroundTaskCoordinator()

    private struct State: Sendable {
        var taskID: UIBackgroundTaskIdentifier = .invalid
        var suspended = false
        var resumeContinuation: CheckedContinuation<Void, Never>?
        var lowTimeWarned = false
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private var statusTimer: Timer?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackgroundTaskCoordinator.shared.handleDidEnterBackground() }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackgroundTaskCoordinator.shared.handleWillEnterForeground() }
        }
    }

    // MARK: 公开 API

    /// 在 Agent 主循环启动时调用：申请后台宽限期。幂等（已持有则忽略）。
    /// 内部 UIKit 调用经 `MainActor.run` 派到主线程；方法本身 async 以便从后台循环以 `await` 调用。
    func begin() async {
        let shouldRequest = lock.withLock { $0.taskID == .invalid }
        guard shouldRequest else { return }
        let id = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "AgentLoop") {
                MainActor.assumeIsolated { BackgroundTaskCoordinator.shared.handleExpiry() }
            }
        }
        lock.withLock { $0.taskID = id }
        AppLogger.shared.info("BGTASK begin (id=\(id.rawValue))", category: "BG", subsystem: "AgentLoop")
    }

    /// 在 Agent 主循环退出（正常结束 / 暂停 / 中断 / 取消）时调用：结束后台任务。幂等、同步。
    /// UIKit 的 `endBackgroundTask` 必须主线程，这里 fire-and-forget 派到主线程（释放 token 不要求同步完成），
    /// 以便可从 `defer` 等同步上下文调用。
    func end() {
        let expiredID: UIBackgroundTaskIdentifier = lock.withLock {
            let id = $0.taskID
            $0.taskID = .invalid
            $0.suspended = false
            $0.lowTimeWarned = false
            return id
        }
        if expiredID != .invalid {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(expiredID)
                BackgroundTaskCoordinator.shared.stopStatusTimer()
            }
            AppLogger.shared.info("BGTASK end (id=\(expiredID.rawValue))", category: "BG", subsystem: "AgentLoop")
        }
    }

    /// 循环安全点调用：若已在后台被挂起，则在此 await 直到回前台。
    /// 与  的 `waitIfBackgroundSuspended()` 语义一致。必须在可挂起的安全点调用。
    func waitIfSuspended() async {
        await withCheckedContinuation { [weak self] (cont: CheckedContinuation<Void, Never>) in
            guard let self else { cont.resume(); return }
            let resumeImmediately = lock.withLock {
                if $0.suspended {
                    // 已在挂起态：存下 continuation，等回前台再 resume（恰好一次）。
                    $0.resumeContinuation = cont
                    return false
                }
                return true
            }
            if resumeImmediately { cont.resume() }
        }
    }

    // MARK: 前后台通知（均运行于主线程）

    @MainActor
    private func handleDidEnterBackground() {
        AppLogger.shared.info("BGTASK didEnterBackground", category: "BG", subsystem: "AgentLoop")
        startStatusTimer()
    }

    @MainActor
    private func handleWillEnterForeground() {
        AppLogger.shared.info("BGTASK willEnterForeground", category: "BG", subsystem: "AgentLoop")
        stopStatusTimer()
        let cont = lock.withLock {
            $0.suspended = false
            let c = $0.resumeContinuation
            $0.resumeContinuation = nil
            return c
        }
        cont?.resume()
        // 重新申请一个后台任务，以防再次进后台。begin() 为 async，这里以 Task 派发（已在主线程）。
        Task { await BackgroundTaskCoordinator.shared.begin() }
    }

    @MainActor
    private func handleExpiry() {
        let expiredID: UIBackgroundTaskIdentifier = lock.withLock {
            let id = $0.taskID
            $0.taskID = .invalid
            $0.suspended = true
            $0.lowTimeWarned = false
            return id
        }
        AppLogger.shared.error(
            "BGTASK 宽限期耗尽（id=\(expiredID.rawValue)），Agent 循环将在下一安全点挂起",
            category: "BG", subsystem: "AgentLoop"
        )
        // 必须结束已过期的任务，否则系统会强杀进程。
        if expiredID != .invalid {
            UIApplication.shared.endBackgroundTask(expiredID)
        }
        // 通知引擎取消正在跑的工具，让循环在下一安全点干净停住。
        NotificationCenter.default.post(name: Self.didExpireNotification, object: nil)
        stopStatusTimer()
    }

    // MARK: 剩余时间监测

    @MainActor
    private func startStatusTimer() {
        stopStatusTimer()
        let timer = Timer(timeInterval: 5.0, repeats: true) { _ in
            // 定时器 block 为 @Sendable，不能捕获非 Sendable 的 self；改走元类型访问单例。
            MainActor.assumeIsolated { BackgroundTaskCoordinator.shared.checkBackgroundTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    @MainActor
    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    @MainActor
    private func checkBackgroundTime() {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        guard remaining != .infinity else { return }
        let shouldWarn = lock.withLock {
            if remaining < 15 && !$0.lowTimeWarned {
                $0.lowTimeWarned = true
                return true
            }
            return false
        }
        if shouldWarn {
            AppLogger.shared.warn(
                "BGTASK 剩余后台时间不足 15s（≈\(Int(remaining))s），Agent 循环即将被系统挂起",
                category: "BG", subsystem: "AgentLoop"
            )
        }
    }
}
