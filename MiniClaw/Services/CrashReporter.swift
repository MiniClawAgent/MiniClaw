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
        logReference: String,
        contextLine: String = ""
    ) -> String {
        // 带默认值：信号处理器那条调用点（AppLogger，async-signal-safe 上下文）无需改动。
        let contextSection = contextLine.isEmpty ? "" : "\nRuntime context: \(contextLine)"
        return """
        === MiniClaw Crash Report ===
        Date:    \(date)
        Type:    \(type)
        Build:   \(build)
        OS:      \(os)
        Device:  \(device)
        Log file: \(logReference)

        Last Phase: \(lastPhase)
        Memory:  \(memoryMB) MB\(contextSection)

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

/// 崩溃现场落盘快照：由**当前进程**在相位变化与周期心跳时写入，供**下次启动**的异常退出
/// 检测读取。
///
/// 为什么必须落盘（2026-09-11 真机复盘）：`phaseLock` 与内存读数都是进程内状态，新进程启动时
/// 读到的只能是它自己的初值 —— 表现为每份报告都写 "Last Phase: Unknown (since <本次启动时刻>)"
/// 与启动瞬间的 ~15MB，**死前真实状态全部丢失**；实测「被外部 SIGKILL」与「真实崩溃」产出的
/// 报告完全同形，无法区分。落盘后即可报出死前相位（Active/Background）与内存，从而区分
/// 「后台被系统回收」与「前台真崩」。
private struct CrashStateSnapshot: Codable {
    var phase: String
    var sinceEpoch: Double
    var writtenAtEpoch: Double
    var memoryMB: Double?
    /// 后台剩余时间（秒）；nil = 采集时不在后台任务中。是「后台回收」判定的关键信号。
    var bgTimeRemaining: Double?
}

final class CrashReporter: @unchecked Sendable {
    static let shared = CrashReporter()

    private let queue = DispatchQueue(label: "com.neartop.miniclaw.crashreporter")
    private let fileManager = FileManager.default
    private let aliveMarkerName = ".crashalive"
    /// 现场落盘文件名（跨进程可读，见 CrashStateSnapshot 注释）。
    private let stateMarkerName = ".crashstate"
    private var terminateObserver: NSObjectProtocol?
    /// 心跳定时器：周期刷新落盘快照里的内存读数，使死前内存最多滞后一个周期。
    private var heartbeatTimer: DispatchSourceTimer?

    /// 心跳周期（秒）。取 30s：足够贴近死前内存真值，又不至于频繁写盘。
    private static let heartbeatInterval: TimeInterval = 30
    /// 最近一次落盘快照（内存态副本，供心跳沿用相位与后台剩余时间）。
    private let stateLock = OSAllocatedUnfairLock<CrashStateSnapshot?>(initialState: nil)

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

    /// 由 MiniClawApp 的场景相位桥调用，记录当前相位与进入时间，并**立即落盘**——
    /// 相位是判断「后台被回收 / 前台真崩」的关键证据，绝不能只留在内存里（进程一被 SIGKILL
    /// 就全丢了，下次启动只能读到 Unknown）。
    /// - Parameter bgTimeRemaining: 后台剩余秒数，由**主线程调用点**采集传入（见
    ///   `currentBackgroundTimeRemaining()`）。本类刻意保持 nonisolated —— 崩溃报告器一旦
    ///   绑定 @MainActor，主线程卡死时就再也写不出报告，那正是最需要它的时刻。
    func notePhase(_ desc: String, bgTimeRemaining: Double? = nil) {
        let since = Date()
        phaseLock.withLock { $0 = (phase: desc, since: since) }
        writeState(phase: desc, since: since, bgTimeRemaining: bgTimeRemaining)
    }

    /// 读取后台剩余时间（秒）。`UIApplication.shared` 是 main-actor 隔离属性，
    /// 故本方法标注 @MainActor，由主线程调用点（场景相位桥）调用；不在后台任务中时
    /// UIApplication 返回极大值，归一为 nil。读取失败一律返回 nil，绝不因此影响落盘。
    @MainActor
    static func currentBackgroundTimeRemaining() -> Double? {
        let remain = UIApplication.shared.backgroundTimeRemaining
        return remain.isFinite && remain < 1_000_000 ? remain : nil
    }

    // MARK: - 现场落盘（跨进程可读）

    private var stateFileURL: URL { logsDir.appendingPathComponent(stateMarkerName) }

    /// 写一份现场快照（更新内存态副本 + 异步落盘），不阻塞调用线程。
    private func writeState(phase: String, since: Date, bgTimeRemaining: Double?) {
        let snapshot = CrashStateSnapshot(
            phase: phase,
            sinceEpoch: since.timeIntervalSince1970,
            writtenAtEpoch: Date().timeIntervalSince1970,
            memoryMB: appMemoryMB(),
            bgTimeRemaining: bgTimeRemaining
        )
        stateLock.withLock { $0 = snapshot }
        queue.async { [snapshot] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: self.stateFileURL, options: .atomic)
        }
    }

    /// 读取上一轮进程遗留的快照（启动检测调用，此时本次进程尚未写过任何相位）。
    private func loadPersistedState() -> CrashStateSnapshot? {
        guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
        return try? JSONDecoder().decode(CrashStateSnapshot.self, from: data)
    }

    /// 周期刷新落盘快照的内存读数；相位与后台剩余时间沿用最近一次落盘值
    /// （心跳跑在 reporter 队列，不读 UIApplication）。
    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let (phase, since) = self.phaseLock.withLock { $0 }
            let bg = self.stateLock.withLock { $0?.bgTimeRemaining }
            self.writeState(phase: phase, since: since, bgTimeRemaining: bg)
        }
        timer.resume()
        heartbeatTimer = timer
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
            // 优先采用**上一轮进程落盘**的现场：相位/内存/后台剩余时间才反映死前真实状态。
            // 内存态 phaseLock 在本次启动时必然是初值 Unknown（见 CrashStateSnapshot 注释）。
            let persisted = loadPersistedState()
            let (memPhase, memSince) = phaseLock.withLock { $0 }
            let phase = persisted?.phase ?? memPhase
            let since = persisted.map { Date(timeIntervalSince1970: $0.sinceEpoch) } ?? memSince
            let reason: String
            if phase == "Background" {
                reason = "Background Termination (system reclaimed memory — normal)"
            } else {
                reason = "Abnormal termination detected at launch (last phase: \(phase))"
            }
            // 回填信号处理器抓到的真实调用栈（若有），使启动检测报告也带回溯。
            let stack = lastSignalCrashStack()
            writeReport(
                type: reason,
                stack: stack,
                lastPhase: phase,
                lastPhaseSince: since,
                memoryMBOverride: persisted?.memoryMB,
                contextLine: Self.describePersistedState(persisted)
            )
            try? fileManager.removeItem(at: marker)
        }
        // 写新标记。
        try? "alive".write(to: marker, atomically: true, encoding: .utf8)
        // 本次进程立刻覆盖一份自己的现场（否则上一轮的快照会残留、下次被误读成「本次死前状态」），
        // 并启动心跳周期刷新内存读数。
        let launchAt = Date()
        phaseLock.withLock { $0 = (phase: "Launching", since: launchAt) }
        stateLock.withLock { $0 = nil }
        writeState(phase: "Launching", since: launchAt, bgTimeRemaining: nil)
        startHeartbeat()
        // 优雅退出时清除标记（系统后台回收时不会触发，从而下次启动可检测）。
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            try? FileManager.default.removeItem(at: marker)
            self?.notePhase("Terminated")
        }
    }

    /// 把落盘现场转成报告里的一行上下文：人读友好 + 直接给出判定倾向。
    private static func describePersistedState(_ s: CrashStateSnapshot?) -> String {
        guard let s else {
            return "无现场落盘（进程从未进入任何场景相位，或该版本尚未带落盘机制）"
        }
        var parts: [String] = []
        parts.append("死前内存 " + (s.memoryMB.map { String(format: "%.0f", $0) + "MB" } ?? "n/a"))
        parts.append("后台剩余 " + (s.bgTimeRemaining.map { String(format: "%.0f", $0) + "s" } ?? "n/a"))
        parts.append("现场落盘于 " + Self.timeFormatter.string(from: Date(timeIntervalSince1970: s.writtenAtEpoch)))
        parts.append("判定提示：" + (s.phase == "Background"
            ? "死前在后台 → 疑似被系统回收（非崩溃）"
            : "死前在前台 → 更像真实崩溃，需结合调用栈"))
        return parts.joined(separator: " · ")
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
    func writeReport(
        type: String,
        stack: String?,
        lastPhase: String? = nil,
        lastPhaseSince: Date? = nil,
        memoryMBOverride: Double? = nil,
        contextLine: String? = nil
    ) -> URL {
        let now = Date()
        let (phase, since) = phaseLock.withLock { $0 }
        let curPhase = lastPhase ?? phase
        let curSince = lastPhaseSince ?? since

        let dateStr = Self.dateFormatter.string(from: now)
        let sinceStr = Self.timeFormatter.string(from: curSince)
        // 启动检测报告传入上一轮落盘的内存值——现场内存只能由死前那个进程测得，
        // 本进程此刻刚启动（~15MB），直接采会严重失真（2026-09-11 复盘结论）。
        let footprint = memoryMBOverride ?? appMemoryMB()
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
            logReference: AppLogger.shared.crashLogPath(),
            contextLine: contextLine ?? ""
        )

        let name = crashFileName(for: now)
        let url = logsDir.appendingPathComponent(name)
        try? report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 写入 MetricKit 系统级崩溃报告:`mxcrash-*.log`。
    /// [MetricKit 2026-08-11] 来源是系统 `.ips` 摘要(下次启动经 MXMetricManager
    /// 交付),与 App 内信号/启动检测报告(crash-*)区分——Type 带 "MetricKit" 前缀,
    /// 文件名用 mxcrash- 前缀。App 内信号处理器抓不到的崩溃(LLDB 接管/堆损坏/
    /// SIGKILL)由它兜底,栈完整可靠。
    @discardableResult
    func writeMetricKitReport(
        type: String,
        stack: String?,
        date: Date = Date(),
        lastLogLines: String? = nil
    ) -> URL {
        let dateStr = Self.dateFormatter.string(from: date)
        let footprint = appMemoryMB()
        let footprintStr = footprint.map { String(format: "%.0f", $0) } ?? "N/A"
        let totalMemMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
        let lines = lastLogLines ?? AppLogger.shared.lastLogLines(count: 20)

        let report = CrashReportComposer.compose(
            date: dateStr,
            type: type,
            build: appLoggerBuildString(),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            device: appLoggerDeviceModel(),
            lastPhase: "MetricKit (system crash diagnostics)",
            memoryMB: footprintStr,
            systemTotalMB: String(format: "%.0f", totalMemMB),
            lastLogLines: lines,
            stack: stack ?? "(none)",
            logReference: AppLogger.shared.crashLogPath()
        )

        let url = logsDir.appendingPathComponent(mxcrashFileName(for: date))
        try? report.write(to: url, atomically: true, encoding: .utf8)
        AppLogger.shared.info("[MetricKit] 崩溃报告已落盘 \(url.lastPathComponent)", category: "Crash")
        return url
    }

    // MARK: - 文件名

    func crashFileName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "crash-\(f.string(from: date)).log"
    }

    /// MetricKit 崩溃报告文件名：`mxcrash-YYYYMMDD-HHMMSS.log`。
    /// [MetricKit 2026-08-11] 前缀与 App 内信号/启动检测报告(`crash-`)区分,
    /// 崩溃日志页与用户据此识别来源(系统级 .ips 摘要 vs App 内抓取)。
    func mxcrashFileName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "mxcrash-\(f.string(from: date)).log"
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
