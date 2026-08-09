import Foundation
import BackgroundTasks

/// BGTaskScheduler 落地：让 Info.plist 已声明的 processing/fetch 后台模式真正生效。
///
/// - `BGProcessingTask`「记忆整理」：系统在空闲/充电时执行 `MemoryConsolidator.consolidate`，
///   替代当前「前台空闲时 Task.detached 裸跑」的无保障方案（App 挂起即中断）。
/// - `BGAppRefreshTask`「维护」：清理过期的 offloads/ 大输出转存与临时文件。
///
/// 注册时机：App 启动时 `registerAndSchedule()`。launch handler 由系统在合适时机唤醒执行，
/// 必须调用 `task.setTaskCompleted()`（处理任务预算约几十分钟，刷新任务约 30s）。
/// `@unchecked Sendable`：仅启动期主线程写 `registered`，随后只读，无并发访问。
final class BackgroundScheduler: @unchecked Sendable {
    static let shared = BackgroundScheduler()

    static let consolidateTaskID = "com.neartop.miniclaw.processing.consolidate"
    static let maintenanceTaskID = "com.neartop.miniclaw.refresh.maintenance"

    /// 后台维护清理的过期阈值（天）。
    private static let fileRetentionDays: TimeInterval = 7 * 24 * 3600

    private var registered = false

    /// BGTask 非 Sendable，不能直接跨进 Task 闭包；用 @unchecked Sendable 盒子包装传递
    /// （任务句柄在 launch handler 生命周期内由系统持有，盒子不会逃逸出本次处理）。
    private struct ProcessingTaskBox: @unchecked Sendable {
        let task: BGProcessingTask
    }
    private struct RefreshTaskBox: @unchecked Sendable {
        let task: BGAppRefreshTask
    }

    /// 一次性执行器：BGTask.setTaskCompleted 系统要求恰好调用一次，
    /// expirationHandler（预算耗尽）与正常完成路径存在竞态，用锁保证只执行其一。
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            lock.unlock()
            body()
        }
    }

    private init() {}

    /// App 启动时调用：注册两类后台任务并提交调度请求。
    func registerAndSchedule() {
        register()
        submit()
    }

    func register() {
        guard !registered else { return }
        registered = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.consolidateTaskID,
            using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else { return }
            let box = ProcessingTaskBox(task: task)
            let once = Once()
            // 系统在预算耗尽前调用：记录日志并显式结束任务（success: false），
            // 否则系统在 handler 返回后强杀进程。与正常完成路径用 Once 保证 setTaskCompleted 恰好一次。
            task.expirationHandler = {
                AppLogger.shared.warn("BGProcessingTask 记忆整理到期被系统终止", category: "BG", subsystem: "Scheduler")
                once.run { box.task.setTaskCompleted(success: false) }
            }
            Task {
                _ = await MemoryConsolidator.shared.consolidate(force: false)
                once.run { box.task.setTaskCompleted(success: true) }
                // 完成后为下一轮重新提交调度。
                BackgroundScheduler.shared.submit()
            }
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.maintenanceTaskID,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let box = RefreshTaskBox(task: task)
            let once = Once()
            task.expirationHandler = {
                AppLogger.shared.warn("BGAppRefreshTask 维护到期被系统终止", category: "BG", subsystem: "Scheduler")
                once.run { box.task.setTaskCompleted(success: false) }
            }
            Task {
                Self.cleanupExpiredFiles()
                once.run { box.task.setTaskCompleted(success: true) }
                BackgroundScheduler.shared.submit()
            }
        }
        AppLogger.shared.info("后台任务已注册（consolidate/maintenance）", category: "BG", subsystem: "Scheduler")
    }

    /// 提交调度请求。同类任务已在队列中时 submit 会失败（try? 忽略，无副作用）。
    func submit() {
        // 记忆整理：需要网络（embedding/模型），不要求充电，最早 1 小时后由系统调度。
        let processing = BGProcessingTaskRequest(identifier: Self.consolidateTaskID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(processing)

        // 维护：轻量刷新任务（30s 预算）。
        let refresh = BGAppRefreshTaskRequest(identifier: Self.maintenanceTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    // MARK: - 任务执行

    /// 清理 offloads/ 中超过保留期的文件（后台下载孤儿、大输出转存等）。
    /// 系统临时文件（downloadTask 完成回调的 location）由系统自行管理，无需也不应清理。
    private static func cleanupExpiredFiles() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.fileRetentionDays)

        let offloads = FileSystemManager.shared.offloadsDir
        guard let entries = try? fm.contentsOfDirectory(at: offloads, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            AppLogger.shared.info("后台维护完成：offloads 不可读或无文件", category: "BG", subsystem: "Scheduler")
            return
        }
        for entry in entries {
            guard let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
        AppLogger.shared.info("后台维护完成：过期文件清理", category: "BG", subsystem: "Scheduler")
    }
}
