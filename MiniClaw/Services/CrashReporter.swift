import Foundation
import Darwin
import os
import UIKit

// MARK: - Crash Reporter
//
// 按 `crash-YYYYMMDD-HHMMSS.log` 生成结构化崩溃报告，格式借鉴用户提供的
// `crash-20260718-174112.log` 样本（=== MiniClaw Crash Report === ... === End ===）。
//
// 触发时机：
// 1) 启动检测异常退出（上一轮被系统回收/闪退，靠 `.crashalive` 标记判断）；
// 2) 捕获到未捕获异常（NSException）；
// 3) 捕获到致命信号（SIGSEGV 等，由 AppLogger 的信号处理器低层写入最小报告）。
//
// 注：MiniClaw 当前未做 Shell / WebView / 后台保活等细粒度遥测，相关段标 (none)/(unavailable)。

// MARK: - 共享崩溃报告构造器
//
// AppLogger 的信号处理器（崩溃上下文，限 async-signal-safe 操作）与 CrashReporter
// 的富报告（主线程/队列，可用 DateFormatter 等）都通过本构造器生成文本，
// 保证「日志侧」与「bug 检测侧」的崩溃报告结构完全一致，且只有一份模板来源。
// 构造器仅做纯字符串拼接，不触碰日期格式化/文件 IO/锁，故信号上下文亦可安全调用。
struct CrashReportComposer {

    /// 所有崩溃报告统一的、因上下文不可用而缺失字段的占位文案。
    static let unavailable = "(unavailable in crash-handler context)"

    /// 生成标准崩溃报告文本。所有入参均为已序列化的 String，调用方负责在各自
    /// 上下文中取数（富报告从主线程/队列取，信号报告在信号上下文取可用字段）。
    static func compose(
        date: String,
        type: String,
        build: String,
        os: String,
        device: String,
        lastPhase: String,
        memoryMB: String,
        systemTotalMB: String,
        lastLogLines: String,
        stack: String,
        logReference: String
    ) -> String {
        """
        === MiniClaw Crash Report ===
        Date:    \(date)
        Type:    \(type)
        Build:   \(build)
        OS:      \(os)
        Device:  \(device)
        Log file: \(logReference)

        Last Phase: \(lastPhase)
        Memory:  \(memoryMB) MB

        --- Memory State (at last phase change) ---
        App footprint:    \(memoryMB) MB
        System total:     \(systemTotalMB) MB
        memory pressure:  normal
        Active sessions:  (unavailable)
        Shell running:    no
        BG task active:   false
        BG time remaining: unlimited
        Silent audio playing: no
        Audio session active: no
        Stop debounce pending: no
        Last lifecycle:   \(lastPhase)
        Last API:         (unavailable)

        --- Active WebViews (at last phase change) ---
        (none — MiniClaw browser state unavailable)

        --- Last Shell Commands (before exit) ---
        (none)

        --- Last 20 Log Lines (before exit) ---
        \(lastLogLines)

        --- MetricKit Call Stack ---
        \(stack)

        === End ===
        """
    }
}

final class CrashReporter: @unchecked Sendable {
    static let shared = CrashReporter()

    private let queue = DispatchQueue(label: "com.neartop.miniclaw.crashreporter")
    private let fileManager = FileManager.default
    private let aliveMarkerName = ".crashalive"
    private var terminateObserver: NSObjectProtocol?

    private var logsDir: URL {
        FileSystemManager.shared.miniClawRoot.appendingPathComponent("logs", isDirectory: true)
    }

    // 场景相位追踪（由 ScenePhaseBridge 调用），用锁保护跨线程读写。
    private let phaseLock = OSAllocatedUnfairLock(initialState: (phase: "Unknown", since: Date()))

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private init() {
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    // MARK: - 相位追踪

    /// 由 MiniClawApp 的场景相位桥调用，记录当前相位与进入时间。
    func notePhase(_ desc: String) {
        phaseLock.withLock { $0 = (phase: desc, since: Date()) }
    }

    // MARK: - 异常退出检测（启动）

    /// 在 App 启动时调用一次：
    /// - 若 `.crashalive` 标记存在 → 上一轮异常退出（被系统回收/闪退），生成崩溃报告；
    /// - 写入新的 `.crashalive` 标记，并监听 `willTerminate` 在优雅退出时清除标记。
    /// 注意：**不区分阶段、不过滤任何情况**——宁可多报（含 prewarm 回收的噪音），
    /// 绝不漏报一次真实异常退出（启动期卡死被系统杀等 phase=Unknown 场景同样要留痕）。
    func checkAbnormalExit() {
        let marker = logsDir.appendingPathComponent(aliveMarkerName)
        if fileManager.fileExists(atPath: marker.path) {
            let (phase, since) = phaseLock.withLock { $0 }
            let reason: String
            if phase == "Background" {
                reason = "Background Termination (system reclaimed memory — normal)"
            } else {
                reason = "Abnormal termination detected at launch (last phase: \(phase))"
            }
            // 回填信号处理器抓到的真实调用栈（若有），使启动检测报告也带回溯。
            let stack = lastSignalCrashStack()
            writeReport(type: reason, stack: stack, lastPhase: phase, lastPhaseSince: since)
            try? fileManager.removeItem(at: marker)
        }
        // 写新标记。
        try? "alive".write(to: marker, atomically: true, encoding: .utf8)
        // 优雅退出时清除标记（系统后台回收时不会触发，从而下次启动可检测）。
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            try? FileManager.default.removeItem(at: marker)
            self?.notePhase("Terminated")
        }
    }

    // MARK: - 信号崩溃栈回填

    /// 在启动检测时，扫描最近的信号型崩溃报告（`Type: Signal ...`），
    /// 取出其 `--- MetricKit Call Stack ---` 段回填到启动检测报告，使崩溃栈可见。
    private func lastSignalCrashStack() -> String? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let crashFiles = urls
            .filter { $0.lastPathComponent.lowercased().hasPrefix("crash-") && $0.pathExtension.lowercased() == "log" }
            .sorted {
                let da = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
        for url in crashFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard text.contains("Type:    Signal") || text.contains("FATAL SIGNAL") else { continue }
            guard let start = text.range(of: "--- MetricKit Call Stack ---"),
                  let end = text.range(of: "=== End ===") else { continue }
            let block = text[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty, !block.hasPrefix("(none") {
                return block
            }
        }
        return nil
    }

    // MARK: - 未捕获异常

    /// 由 AppLogger 的未捕获异常处理器调用。返回写出的崩溃报告 URL，供日志行引用。
    @discardableResult
    func recordException(_ exception: NSException) -> URL? {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        let (phase, since) = phaseLock.withLock { $0 }
        return writeReport(
            type: "Uncaught Exception: \(exception.name.rawValue)",
            stack: "\(exception.reason ?? "no reason")\n\(stack)",
            lastPhase: phase,
            lastPhaseSince: since
        )
    }

    // MARK: - 报告生成

    /// 生成并写入一份崩溃报告文件 `crash-YYYYMMDD-HHMMSS.log`。
    /// 同步写入（文件体积小、耗时低），以在进程终止前完成。
    /// 文本统一由 `CrashReportComposer` 构造，与信号路径共用同一模板。
    @discardableResult
    func writeReport(type: String, stack: String?, lastPhase: String? = nil, lastPhaseSince: Date? = nil) -> URL {
        let now = Date()
        let (phase, since) = phaseLock.withLock { $0 }
        let curPhase = lastPhase ?? phase
        let curSince = lastPhaseSince ?? since

        let dateStr = Self.dateFormatter.string(from: now)
        let sinceStr = Self.timeFormatter.string(from: curSince)
        let footprint = appMemoryMB()
        let footprintStr = footprint.map { String(format: "%.0f", $0) } ?? "N/A"
        let totalMemMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
        let lastLines = AppLogger.shared.lastLogLines(count: 20)
        let stackBlock = stack ?? "(none)"

        let report = CrashReportComposer.compose(
            date: dateStr,
            type: type,
            build: appLoggerBuildString(),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            device: appLoggerDeviceModel(),
            lastPhase: "\(curPhase) (since \(sinceStr))",
            memoryMB: footprintStr,
            systemTotalMB: String(format: "%.0f", totalMemMB),
            lastLogLines: lastLines,
            stack: stackBlock,
            logReference: AppLogger.shared.crashLogPath()
        )

        let name = crashFileName(for: now)
        let url = logsDir.appendingPathComponent(name)
        try? report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 文件名

    func crashFileName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "crash-\(f.string(from: date)).log"
    }

    // MARK: - 内存占用（best-effort）

    private func appMemoryMB() -> Double? {
        var info = task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / (1024 * 1024)
    }
}
