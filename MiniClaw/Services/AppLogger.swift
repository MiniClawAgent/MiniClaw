import Foundation
import Darwin
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Log Level

enum LogLevel: String, CustomStringConvertible {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case fault = "FAULT"
    var description: String { rawValue }
}

// MARK: - App Logger

/// 按天写入 `Documents/MiniClaw/logs/MiniClaw-YYYY-MM-DD.log`，格式对齐 Apple Unified Log：
/// `[HH:MM:SS] yyyy-MM-dd HH:mm:ss.sss MiniClaw[pid:tid] [Category] [LEVEL] [Subsystem] message`
///
/// 用于真机 debug：检测会话期间的报错 / 卡死 / 死循环 / 闪退，并可在
/// 设置 → 日志 → 运行日志 中按天查看、复制、导出。
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    /// 单条日志文件元数据（供设置页列表展示）。
    struct LogFileEntry: Identifiable {
        let url: URL
        let date: String      // yyyy-MM-dd
        let size: Int64
        var id: String { url.lastPathComponent }
    }

    private let queue = DispatchQueue(label: "com.neartop.miniclaw.applogger")
    private let fileManager = FileManager.default

    // MARK: - 批量落盘（2026-09-08 性能修复）
    //
    // 此前**每条日志**都 `queue.async` 一次：一次 block 分配 + 一次
    // open/seek/write/close。Instruments 实测 50+ 消息会话滑动时 54% CPU 烧在
    // libdispatch 的释放路径（`_dispatch_block_async_invoke2 → _Block_release →
    // dispatch_continuation_free_to_cache_limit`），正是这条路径。
    // 改为攒批：满 `flushThreshold` 条、或距上次 flush 超过 `flushInterval` 秒，
    // 才派发**一次**块，把整批行一次性写入（1 次 open/write/close）。
    private let pendingLock = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let lastFlushLock = OSAllocatedUnfairLock(initialState: Date())
    private let flushThreshold = 32
    private let flushInterval: TimeInterval = 1.0

    /// 独立计算（2026-09-05 修复）：路径与 FileSystemManager.miniClawRoot/logs 保持一致，
    /// 但**不依赖 FSM 单例**——AppLogger 被 FSM.init 的清理路径同步调用，而
    /// FSM.shared 的 dispatch_once 尚未完成时，logsDir 再回查 FSM.shared 会形成
    /// 静态初始化重入死循环（Mac "Designed for iPad" 启动 EXC_BREAKPOINT 实锤；
    /// dispatch_once_wait 死等栈已由帧走查抓到）。日志器必须零依赖自举。
    private var logsDir: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("MiniClaw/logs", isDirectory: true)
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private let fullFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    // 主线程心跳（卡死检测用），用锁保护跨线程读写。
    private let lastMainTickLock = OSAllocatedUnfairLock(initialState: Date())

    /// 「最后执行点」：由 `crisisMark` 持续更新，卡死/崩溃报告直接把它当作 lastPhase 输出。
    /// 这样报告首屏就能回答「卡死那一刻正在干什么」，而不用人工去日志里翻最后几行。
    /// 用无锁自旋锁保护：写入在业务线程、读取在看门狗线程。
    private let lastCrisisPhaseLock = OSAllocatedUnfairLock<(mark: String, at: Date)?>(initialState: nil)
    private var lastFreezeLog = Date(timeIntervalSince1970: 0)
    private var lastFreezeReport = Date(timeIntervalSince1970: 0)
    private var heartbeatTimer: Timer?
    private var watchdogSource: DispatchSourceTimer?
    private var runLoopObserver: CFRunLoopObserver?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// App 是否处于前台。**卡死判定的前置闸门**。
    ///
    /// 进入后台后 iOS 会挂起整个进程：主线程心跳计时器停摆，看门狗队列也一并冻结。
    /// 回到前台时若直接用 wall-clock 差值判定，会把「整段后台挂起时长」误报成
    /// 「主线程卡死 N 秒」——这正是此前 39.9s / 51.6s 两份报告「精确始于 Background、
    /// 终于 Active」的成因（假阳性，不是真死锁）。因此后台期间一律不判定，
    /// 且在前后台切换的两个时刻都把心跳基线归零。
    private let isForegroundLock = OSAllocatedUnfairLock(initialState: true)

    /// 主线程 runloop 的最近活动阶段。
    /// `beforeWaiting` 表示「主线程已把事件处理完、正在空转等下一个事件」= 健康空闲，
    /// 不能算卡死。只有停在处理事件的阶段（sources/timers）超时才是真卡死。
    private let runLoopActivityLock = OSAllocatedUnfairLock<CFRunLoopActivity>(initialState: .entry)

    /// 默认日志分类(移植适配:AppLogger(category:) 兼容构造)
    private let defaultCategory: String

    init(category: String = "App") {
        self.defaultCategory = category
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    // MARK: - Enable switch（设置页开关，关闭后停止记录）

    /// 是否启用日志记录。默认开启，持久化到 UserDefaults。
    /// 读写走 `appLoggerEnabledFlag` 全局标志，以便崩溃信号处理器可无锁读取。
    var isEnabled: Bool { appLoggerEnabledFlag }

    func setEnabled(_ on: Bool) {
        appLoggerEnabledFlag = on
        UserDefaults.standard.set(on, forKey: appLoggerEnabledKey)
        if on {
            info("Logging enabled (由设置页开关开启)", category: "Lifecycle", subsystem: "Lifecycle")
        }
    }

    /// 诊断类 category 白名单:这些 category 的 info 级日志也镜像到 Xcode 控制台,
    /// 便于真机调试时直接观察滚动/抖动链路(2026-08-11 用户要求)。
    /// 2026-08-13 降噪:移除 KbdDiag/InputBarLayout/SubViewport/InputFocus——键盘与布局
    /// inset 变化每次操作都打,刷屏价值低;文件日志仍完整保留。
    private static let consoleMirrorCategories: Set<String> = [
        "ScrollDiag", "ScrollStall", "Settle", "SettleJitter",
        "ChatInputInject",  // 2026-08-13:「添加到输入框」链路打点,排查期镜像控制台
        // 2026-09-02:MCP OAuth 排障期镜像——授权/回调/token 链路与 MCP 刷新链路
        // 需要在 Xcode 实时观察(ARDOT loopback 收码定位)
        "MCP-OAuth", "MCP"
    ]

    /// 诊断插桩静默类别（2026-09-11 降噪）：这些 category 的 info/debug
    /// **既不落盘也不打印**。它们都是阶段性排查插桩——缓存观测（RenderCache：
    /// 高度 memo / 渲染缓存的 STORE·MISS·HIT）、渲染统计（MarkdownRenderer）——
    /// 诊断使命完成后会常驻刷屏（实测占单日日志 91%：8216/9038 行）。
    /// 需要复现排查时把类别移出本集合即可恢复全量观测；WARN/ERROR/FAULT 不受影响
    /// （始终保留，见 log 中的级别判断）。
    private static let quietInfoCategories: Set<String> = [
        "RenderCache", "MarkdownRenderer",
    ]

    func log(category: String, subsystem: String? = nil, level: LogLevel, message: String) {
        guard appLoggerEnabledFlag else { return }
        // 插桩静默：在 formatLine 之前短路，省掉无谓的格式化与线程 id 查询开销。
        if level == .info || level == .debug, Self.quietInfoCategories.contains(category) { return }

        let line = formatLine(category: category, subsystem: subsystem ?? category, level: level, message: message)
        // 警告及以上镜像到控制台，便于真机/模拟器调试时直接看到。
        if level == .warn || level == .error || level == .fault
            || (level == .info && Self.consoleMirrorCategories.contains(category)) {
            print("[\(level.rawValue)] [\(category)] \(message)")
        }
        // 警告及以上：立即落盘（崩溃前必须留住），其余攒批。
        pendingLock.withLock { $0.append(line) }
        if level == .warn || level == .error || level == .fault {
            flushPending()
            return
        }
        let count = pendingLock.withLock { $0.count }
        let sinceFlush = Date().timeIntervalSince(lastFlushLock.withLock { $0 })
        if count >= flushThreshold || sinceFlush >= flushInterval {
            flushPending()
        }
    }

    /// 把缓冲行一次性交给日志队列批量写入（一次 open/write/close）。
    /// `sync = true` 时在**调用线程**直写（崩溃/信号处理器用，那里不能 async）。
    func flushPending(sync: Bool = false) {
        lastFlushLock.withLock { $0 = Date() }
        let batch = pendingLock.withLock { buf -> [String] in
            let out = buf
            buf.removeAll(keepingCapacity: true)
            return out
        }
        guard !batch.isEmpty else { return }
        if sync {
            append(batch)
        } else {
            queue.async { [weak self] in
                self?.append(batch)
            }
        }
    }

    func debug(_ message: String, category: String = "App", subsystem: String? = nil) {
        log(category: category, subsystem: subsystem, level: .debug, message: message)
    }
    func info(_ message: String, category: String? = nil, subsystem: String? = nil) {
        log(category: category ?? defaultCategory, subsystem: subsystem, level: .info, message: message)
    }
    func warn(_ message: String, category: String? = nil, subsystem: String? = nil) {
        log(category: category ?? defaultCategory, subsystem: subsystem, level: .warn, message: message)
    }
    /// 移植适配:warning 别名(warn)
    func warning(_ message: String, category: String? = nil, subsystem: String? = nil) {
        log(category: category ?? defaultCategory, subsystem: subsystem, level: .warn, message: message)
    }
    func error(_ message: String, category: String? = nil, subsystem: String? = nil) {
        log(category: category ?? defaultCategory, subsystem: subsystem, level: .error, message: message)
    }
    func fault(_ message: String, category: String = "App", subsystem: String? = nil) {
        guard appLoggerEnabledFlag else { return }
        let line = formatLine(category: category, subsystem: subsystem ?? category, level: .fault, message: message)
        print("[FAULT] [\(category)] \(message)")
        // 崩溃上下文：在调用线程直接落盘。
        // 不用 `queue.sync`——那会排在业务日志队列的所有积压 async 之后，
        // 让调用线程（可能是主线程）被日志系统反噬，本身变成新的卡死源。
        append(line)
    }

    /// 危机定位标记：在**调用线程**立即落盘，用于关键路径疑似卡死时保留「最后执行点」。
    /// 与 `fault` 不同，它不打印到控制台，仅静默落盘——配合 `captureAllThreadStacks` 抓栈，
    /// 闪退时即可从日志反推「卡在哪个函数/工具」。
    ///
    /// 刻意不走异步队列：卡死/被杀时队列里的 async 可能永远来不及执行，标记就丢了；
    /// 也刻意不用 `queue.sync`（理由同 `fault`）。直写 + fileLock 是唯一既可靠又不阻塞的路径。
    func crisisMark(_ message: String, category: String = "Hang") {
        guard appLoggerEnabledFlag else { return }
        // 先更新「最后执行点」，再落盘：即便随后立刻卡死，看门狗也能读到这一条。
        lastCrisisPhaseLock.withLock { $0 = (mark: message, at: Date()) }
        let line = formatLine(category: category, subsystem: category, level: .warn, message: message)
        append(line)
    }

    /// 供卡死/崩溃报告读取的「最后执行点」描述，形如
    /// `TOOL ENTER: read_file（12.4s 前）`。无标记时返回 nil。
    func lastCrisisPhase() -> String? {
        guard let snapshot = lastCrisisPhaseLock.withLock({ $0 }) else { return nil }
        let elapsed = Date().timeIntervalSince(snapshot.at)
        return "\(snapshot.mark)（\(String(format: "%.1f", elapsed))s 前）"
    }

    private func formatLine(category: String, subsystem: String, level: LogLevel, message: String) -> String {
        let now = Date()
        let time = timeFormatter.string(from: now)
        let full = fullFormatter.string(from: now)
        let pid = ProcessInfo.processInfo.processIdentifier
        let tid = Self.threadID()
        return "[\(time)] \(full) MiniClaw[\(pid):\(tid)] [\(category)] [\(level.rawValue)] [\(subsystem)] \(message)"
    }

    fileprivate static func threadID() -> String {
        #if canImport(Darwin)
        var tid: __uint64_t = 0
        pthread_threadid_np(nil, &tid)
        return String(tid)
        #else
        return "0"
        #endif
    }

    // MARK: - File append

    private func currentLogFileURL() -> URL {
        let name = "MiniClaw-\(dateFormatter.string(from: Date())).log"
        return logsDir.appendingPathComponent(name)
    }

    /// 保护日志文件写入。业务日志（异步队列）与危机标记（调用线程直写）两条路径都经过它，
    /// 避免交错写坏同一行。持锁时间 = 一次 open/seek/write/close，微秒级，不构成阻塞风险。
    private let fileLock = NSLock()

    private func append(_ line: String) {
        append([line])
    }

    /// 批量写：一次 open/seek/write/close 写多行（单条路径也走这里，行为一致）。
    private func append(_ lines: [String]) {
        let url = currentLogFileURL()
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        fileLock.lock()
        defer { fileLock.unlock() }
        do {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } catch {
            // 文件尚不存在时创建后写入。
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Crash / Signal handlers（闪退检测）

    /// 安装未捕获异常处理器与关键信号处理器，并启动主线程卡死看门狗。
    /// 应在 App 启动时（FileSystemManager 初始化之后）调用一次。
    func installCrashHandlers() {
        NSSetUncaughtExceptionHandler(appLoggerUncaughtExceptionHandler)

        signal(SIGABRT, appLoggerCrashSignalHandler)
        signal(SIGSEGV, appLoggerCrashSignalHandler)
        signal(SIGBUS, appLoggerCrashSignalHandler)
        signal(SIGILL, appLoggerCrashSignalHandler)
        signal(SIGTRAP, appLoggerCrashSignalHandler)
        signal(SIGFPE, appLoggerCrashSignalHandler)

        startWatchdog()
        // [2026-09-09 构建指纹] 启动日志打印**可执行文件编译时间**与版本号：
        // 可执行文件 mtime = 上次真实编译时间，自动准确、零维护，
        // 日志首屏即可确认修复是否在包里（多轮「测的哪个构建」排查成本过高）。
        var buildStamp = "?"
        if let exe = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
           let mtime = attrs[.modificationDate] as? Date {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm:ss"
            buildStamp = fmt.string(from: mtime)
        }
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        info("App launched — AppLogger ready (build=\(buildStamp) ver=\(ver) logs at \(logsDir.path))", category: "Lifecycle", subsystem: "Lifecycle")
    }

    /// 当天运行日志路径，供崩溃报告「Log file」字段引用（AppLogger 与 CrashReporter 共用）。
    func crashLogPath() -> String {
        logsDir.appendingPathComponent("MiniClaw-\(dateFormatter.string(from: Date())).log").path
    }

    /// 崩溃报告文件路径：`crash-YYYYMMDD-HHMMSS.log`（供信号处理器低层写入）。
    func crashLogFileURL(for date: Date = Date()) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return logsDir.appendingPathComponent("crash-\(f.string(from: date)).log")
    }

    // MARK: - Main-thread freeze watchdog（卡死检测）

    private func startWatchdog() {
        // 主线程心跳：每 0.5s 更新 lastMainTick。主线程卡死时该计时器不再触发。
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.lastMainTickLock.withLock { $0 = Date() }
        }
        // runloop 观察者：比计时器更贴近主线程真实状态。计时器只能证明「主线程还能跑任务」，
        // 观察者还能告诉我们主线程此刻停在 runloop 的哪个阶段，从而区分
        // 「空闲等事件（健康）」与「卡在事件处理里（真卡死）」。
        let activities: CFRunLoopActivity = [
            .entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit,
        ]
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities.rawValue, true, 0
        ) { [weak self] _, activity in
            guard let self else { return }
            self.lastMainTickLock.withLock { $0 = Date() }
            self.runLoopActivityLock.withLock { $0 = activity }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserver = observer
        }
        observeAppLifecycleForWatchdog()
        // 后台看门狗：每 1s 检查主线程是否被阻塞超过阈值。
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.neartop.miniclaw.watchdog"))
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        source.resume()
        watchdogSource = source
    }

    /// 订阅前后台切换，维护 `isForeground` 闸门并在切换瞬间重置心跳基线。
    ///
    /// 两个方向都必须重置：进入后台时重置，避免「后台前最后一次心跳」成为陈旧基线；
    /// 回到前台时重置，避免把整段挂起时长算进第一次 tick。
    private func observeAppLifecycleForWatchdog() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let toBackground = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isForegroundLock.withLock { $0 = false }
            self.lastMainTickLock.withLock { $0 = Date() }
        }
        let toForeground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 先刷新基线再开闸，顺序不能反：否则开闸后、基线刷新前的那一次 tick
            // 仍会读到后台前的旧时间戳，照样误报。
            self.lastMainTickLock.withLock { $0 = Date() }
            self.isForegroundLock.withLock { $0 = true }
        }
        lifecycleObservers = [toBackground, toForeground]
        #endif
    }

    private func watchdogTick() {
        // 闸门一：后台挂起期间不判定（详见 isForegroundLock 说明）。
        guard isForegroundLock.withLock({ $0 }) else { return }
        // 闸门二：主线程停在 beforeWaiting = 已处理完事件、正在等下一个，属健康空闲。
        guard runLoopActivityLock.withLock({ $0 }) != .beforeWaiting else { return }
        let gap = Date().timeIntervalSince(lastMainTickLock.withLock { $0 })
        guard gap > 3.0 else { return }
        let now = Date()
        // 节流：同一卡死事件最多每 5s 记一次，避免刷屏。
        guard now.timeIntervalSince(lastFreezeLog) > 5 else { return }
        lastFreezeLog = now
        let phase = lastCrisisPhase()
        self.error(
            "MAIN THREAD BLOCKED for \(String(format: "%.1f", gap))s — 主线程可能卡死(卡死检测)，"
                + "最后执行点：\(phase ?? "无标记（卡死不在工具执行期间）")",
            category: "Watchdog", subsystem: "Watchdog"
        )
        // 卡死也是「用户不知何时发生」的问题：单独生成一份崩溃式报告，复用 CrashReporter
        // 富模板（自动带入最近日志/内存/相位），让日志能直接把问题端出来，而非只留一行 ERROR。
        // 报告节流放宽到 30s，避免长卡死刷出大量报告文件。
        guard now.timeIntervalSince(lastFreezeReport) > 30 else { return }
        lastFreezeReport = now
        CrashReporter.shared.writeReport(
            type: "Main Thread Freeze (\(String(format: "%.1f", gap))s blocked)",
            stack: AppLogger.captureAllThreadStacks()
                ?? "Main thread call stack unavailable (capture failed or unsupported arch). See recent log lines above for the in-progress operation.",
            lastPhase: phase
        )
    }

    // MARK: - 卡死时主动抓栈（根治"只记卡了几秒却不知卡在哪一行"）

    /// 主线程被同步重活卡死（或发生死锁）时，由后台看门狗线程主动抓取**所有存活线程**的调用栈。
    /// 做法：task_threads 枚举 → 逐线程挂起 → 读取 arm64 寄存器(FP/LR/PC) → 沿帧链回溯返回地址 → 恢复 → dladdr 符号化。
    /// 这样即使不连调试器，崩溃报告里也能直接看到「主线程卡在哪个函数、哪一行」，
    /// 并顺带把后台线程栈一并dump（死锁时常是后台线程持锁、主线程等锁，全量才有价值）。
    /// 注意：该 SDK 不含 `pthread_main_thread_np`，故用 task_threads 枚举 + pthread 名来标识主线程。
    private static func captureAllThreadStacks(maxFrames: Int = 48) -> String? {
        #if arch(arm64)
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let list = threads, count > 0 else { return nil }
        let selfThread = mach_thread_self()
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count)) * vm_size_t(MemoryLayout<thread_act_t>.stride))
            mach_port_deallocate(mach_task_self_, selfThread)
        }

        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / 4)
        let infoPtr = UnsafeMutablePointer<Dl_info>.allocate(capacity: 1)
        defer { infoPtr.deallocate() }

        var blocks: [String] = []
        for i in 0..<Int(count) {
            let t = list[i]
            // 线程名（用于区分主线程与其他后台线程；主线程通常 unnamed 或叫 main）
            var nm = [CChar](repeating: 0, count: 128)
            var threadName = "unnamed (likely main/UI)"
            if let pt = pthread_from_mach_thread_np(t) {
                if pthread_getname_np(pt, &nm, nm.count) == 0 {
                    let s = nm.withUnsafeBufferPointer { buf in buf.baseAddress.map { String(cString: $0) } ?? "" }
                    if !s.isEmpty { threadName = s }
                }
            }
            guard t != selfThread else {
                blocks.append("thread #\(i) [watchdog/self] — skipped")
                continue
            }
            guard thread_suspend(t) == KERN_SUCCESS else {
                blocks.append("thread #\(i) [\(threadName)] — suspend failed")
                continue
            }
            defer { thread_resume(t) }

            var state = arm_thread_state64_t()
            let kr = withUnsafeMutableBytes(of: &state) { rawBuf in
                thread_get_state(
                    t,
                    ARM_THREAD_STATE64,
                    rawBuf.bindMemory(to: UInt32.self).baseAddress!,
                    &stateCount
                )
            }
            guard kr == KERN_SUCCESS else {
                blocks.append("thread #\(i) [\(threadName)] — get_state failed")
                continue
            }

            // 帧链回溯：仅依赖「16 字节对齐」+「帧链单调递增/非退化为坏指针」守卫，
            // 不再用 pthread_get_stackaddr_np 的栈边界做硬截断——
            // iOS 上主线程/系统线程的 pthread_get_stackaddr_np 返回值常与实际
            // 运行期帧指针范围不匹配，会导致 while 循环体一次都不执行 → 所有线程
            // 都报 "no frames"，正是上次崩溃日志定位不到根因的元凶。
            // 参照 HangDetector.captureFramesARM64：只做对齐 + 坏指针
            // 守卫即可抓到真实栈，且不会因越界解引用而让看门狗自身崩溃。
            var fp = state.__fp
            // 帧 0 直接放 PC（当前指令地址），即真正卡住的那个函数，便于一眼定位。
            var frames: [UInt64] = [UInt64(state.__pc)]
            var gc = 0
            while fp != 0, (fp & 0xF) == 0, gc < maxFrames {
                let raw = UnsafeRawPointer(bitPattern: UInt(fp))!
                let savedFp = raw.load(fromByteOffset: 0, as: UInt64.self)
                let retAddr = raw.load(fromByteOffset: 8, as: UInt64.self)
                frames.append(retAddr)
                fp = savedFp
                gc += 1
                if savedFp == 0 || (savedFp & 0xF) != 0 || savedFp <= fp {
                    break
                }
            }

            if frames.isEmpty {
                blocks.append("thread #\(i) [\(threadName)] (mach port \(t)) — no frames (pc=0x\(String(format: "%llx", Int64(bitPattern: state.__pc)))")
                continue
            }
            var lines: [String] = []
            for (j, addr) in frames.enumerated() {
                let line: String
                if dladdr(UnsafeRawPointer(bitPattern: UInt(addr)), infoPtr) != 0 {
                    let info = infoPtr.pointee
                    let fname = info.dli_fname.map { String(cString: $0) } ?? "?"
                    let sname = info.dli_sname.map { String(cString: $0) } ?? "??"
                    let offset: UInt64 = info.dli_saddr.map { addr - UInt64(UInt(bitPattern: $0)) } ?? 0
                    line = String(format: "    %2d  %@  0x%016llx  %@ + 0x%llx",
                                  j, (fname as NSString).lastPathComponent, Int64(bitPattern: addr), sname, Int64(bitPattern: offset))
                } else {
                    line = String(format: "    %2d  0x%016llx", j, Int64(bitPattern: addr))
                }
                lines.append(line)
            }
            blocks.append("thread #\(i) [\(threadName)] (mach port \(t)):\n" + lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return nil }
        return "Captured by watchdog via arm64 frame walk (all live threads):\n" + blocks.joined(separator: "\n\n")
        #else
        return nil
        #endif
    }

    // MARK: - Listing（供设置页）

    var logsDirectory: URL { logsDir }

    /// 返回所有 `MiniClaw-YYYY-MM-DD.log`，按日期倒序。
    func listLogFiles() -> [LogFileEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "log" }
            // 排除崩溃日志（crash-*.log / mxcrash-*.log），它们由专门的「崩溃日志」分区单独列出
            .filter {
                let name = $0.lastPathComponent.lowercased()
                return !name.hasPrefix("crash-") && !name.hasPrefix("mxcrash-")
            }
            .compactMap { url in
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey])
                let size = Int64(vals?.fileSize ?? 0)
                let date = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "MiniClaw-", with: "")
                return LogFileEntry(url: url, date: date, size: size)
            }
            .sorted { $0.date > $1.date }
    }

    /// 崩溃日志列表：过滤 `crash-YYYYMMDD-HHMMSS.log` 与 `mxcrash-YYYYMMDD-HHMMSS.log`
    /// （MetricKit 系统级报告），按名称倒序。[MetricKit 2026-08-11] mxcrash- 前缀
    /// 用于区分来源：App 内信号/启动检测(crash-) vs 系统 .ips 摘要(MetricKit)。
    func listCrashLogFiles() -> [LogFileEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }
        return urls
            .filter {
                let name = $0.lastPathComponent.lowercased()
                return $0.pathExtension.lowercased() == "log"
                    && (name.hasPrefix("crash-") || name.hasPrefix("mxcrash-"))
            }
            .compactMap { url in
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey])
                let size = Int64(vals?.fileSize ?? 0)
                let date = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "crash-", with: "")
                    .replacingOccurrences(of: "mxcrash-", with: "")
                return LogFileEntry(url: url, date: date, size: size)
            }
            .sorted { $0.date > $1.date }
    }

    /// 读取当天运行日志末尾 N 行，用于崩溃报告「Last N Log Lines」。
    func lastLogLines(count: Int = 20) -> String {
        let url = currentLogFileURL()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "(no log)" }
        defer { handle.closeFile() }
        let total = (try? handle.seekToEnd()) ?? 0
        guard total > 0 else { return "(no log)" }
        let maxBytes = 64_000
        let start = max(0, Int64(total) - Int64(maxBytes))
        handle.seek(toFileOffset: UInt64(start))
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return "(no log)" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(count)
        return tail.joined(separator: "\n")
    }

    /// 读取日志尾部（最多 maxBytes），用于详情页展示，避免超大文件卡顿。
    func readTail(of url: URL, maxBytes: Int = 512_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { handle.closeFile() }
        let total = (try? handle.seekToEnd()) ?? 0
        guard total > 0 else { return "" }
        let start = max(0, Int64(total) - Int64(maxBytes))
        handle.seek(toFileOffset: UInt64(start))
        let data = handle.readDataToEndOfFile()
        guard var text = String(data: data, encoding: .utf8) else { return "" }
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
            text = "…（前文已省略，仅显示最近 \(maxBytes / 1024)KB）\n" + text
        }
        return text
    }
}

// MARK: - 崩溃信号处理的文件级辅助（需顶层函数才能形成 C 函数指针）

/// 设备型号（hw.machine），供信号处理器与 CrashReporter 共用。
func appLoggerDeviceModel() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var machine = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.machine", &machine, &size, nil, 0)
    // iOS16 兼容:数组版 String(cString:) 已 deprecated,数组层截断 null 后 decoding 等价实现。
    let nulIdx = machine.firstIndex(of: 0) ?? machine.endIndex
    let bytes = machine[..<nulIdx].map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// 版本号 (build)，供信号处理器与 CrashReporter 共用。
func appLoggerBuildString() -> String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return "\(v) (\(b))"
}

/// 全局启用开关：普通日志与崩溃信号处理共享。
/// 用全局标志而非锁，是因为信号处理器中读锁并非 async-signal-safe，单 Bool 读取足够。
/// 首次访问时从 UserDefaults 惰性初始化（默认开启）。
let appLoggerEnabledKey = "AppLogger.isEnabled"
nonisolated(unsafe) var appLoggerEnabledFlag: Bool =
    (UserDefaults.standard.object(forKey: "AppLogger.isEnabled") as? Bool) ?? true

fileprivate let sTimeFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
}()
fileprivate let sFullFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
}()

fileprivate func appLoggerUncaughtExceptionHandler(_ exception: NSException) {
    guard appLoggerEnabledFlag else { return }
    AppLogger.shared.flushPending(sync: true)   // 攒批缓冲在崩溃时必须直写落盘
    let stack = exception.callStackSymbols.joined(separator: "\n")
    let crashURL = CrashReporter.shared.recordException(exception)
    let ref = crashURL?.lastPathComponent ?? "(unknown)"
    AppLogger.shared.fault(
        "UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "no reason")\n\(stack) | crash report: \(ref)",
        category: "Crash", subsystem: "Crash"
    )
}

fileprivate func appLoggerSignalName(_ sig: Int32) -> String {
    switch sig {
    case SIGABRT: return "SIGABRT"
    case SIGSEGV: return "SIGSEGV"
    case SIGBUS: return "SIGBUS"
    case SIGILL: return "SIGILL"
    case SIGTRAP: return "SIGTRAP"
    case SIGFPE: return "SIGFPE"
    default: return "SIG#\(sig)"
    }
}

/// 顶层自由函数：可被 `signal()` 直接引用为 C 函数指针。
/// 用低层 `open/write/close` 同步写入当天日志（异步队列在崩溃上下文不安全）。
///
/// 关键点：除写入一行 `FATAL SIGNAL` 外，这里用 `backtrace()`/`backtrace_symbols()`
/// 抓取崩溃线程调用栈并写入独立崩溃报告。虽 `backtrace_symbols`/`free` 严格说非
/// async-signal-safe，但崩溃处理器本就在进程将死之际运行，且随后会 re-raise 让系统
/// 另生成标准 `.ips`，风险可接受。这样下次崩溃在 App 内「崩溃日志」即可看到崩溃行，
/// 不必再等系统 `.ips` 同步到 Mac。
/// 信号上下文安全的日志尾部读取（best-effort）：仅用低层 open/fstat/pread 取最近
/// count 行文本，任意步骤失败即返回 nil。用于给崩溃报告补充「事发前日志上下文」，
/// 让用户在不知何时闪退时仍能从报告里看到崩溃前发生了什么，而不是一份空壳。
fileprivate func appLoggerTailLines(_ path: String, maxBytes: Int = 16_384, count: Int = 20) -> String? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0 else { return nil }
    let total = Int(st.st_size)
    guard total > 0 else { return nil }
    let clamped = min(maxBytes, total)
    var buf = [CChar](repeating: 0, count: clamped + 1)
    let n = pread(fd, &buf, clamped, off_t(total - clamped))
    guard n > 0 else { return nil }
    let nulIdx = buf.firstIndex(of: 0) ?? buf.endIndex
    let bytes = buf[..<nulIdx].map { UInt8(bitPattern: $0) }
    let text = String(decoding: bytes, as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.suffix(count).joined(separator: "\n")
}

fileprivate func appLoggerCrashSignalHandler(_ sig: Int32) {
    guard appLoggerEnabledFlag else {
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }
    let name = appLoggerSignalName(sig)
    AppLogger.shared.flushPending(sync: true)   // 攒批缓冲在崩溃时必须直写落盘
    let ts = sFullFormatter.string(from: Date())
    let time = sTimeFormatter.string(from: Date())

    // 抓取调用栈（崩溃线程）。
    var addresses: [UnsafeMutableRawPointer?] = Array(repeating: nil, count: 64)
    let frames = backtrace(&addresses, Int32(addresses.count))
    let symbols = backtrace_symbols(&addresses, frames)
    var stackLines = [String]()
    for i in 0..<Int(frames) {
        if let symPtr = symbols?[i] {
            stackLines.append(String(cString: UnsafePointer(symPtr)))
        }
    }
    if let syms = symbols { free(UnsafeMutableRawPointer(syms)) }
    let stackBlock = stackLines.isEmpty ? "(no symbols captured)" : stackLines.joined(separator: "\n")

    let crashName = AppLogger.shared.crashLogFileURL().lastPathComponent
    let line = "[\(time)] \(ts) MiniClaw[\(ProcessInfo.processInfo.processIdentifier):\(AppLogger.threadID())] [Crash] [FAULT] [Crash] FATAL SIGNAL \(name) (\(sig)) received — possible crash (闪退) | crash report: \(crashName)\n\(stackBlock)"
    // 写入当天运行日志（low-level，async-signal-safe）。
    let path = AppLogger.shared.crashLogPath()
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
        _ = (line + "\n").withCString { cstr in
            write(fd, cstr, strlen(cstr))
        }
        close(fd)
    }
    // 同时写入独立崩溃报告文件（含真实调用栈）。报告文本统一由 CrashReportComposer
    // 构造，与 CrashReporter 富报告共用同一模板，仅字段可用性不同（信号上下文取不到
    // 相位/内存/最近日志，统一标注 unavailable），从而保证「日志侧」与「bug 检测侧」
    // 崩溃报告结构一致、且只有一份模板来源。
    let logRef = AppLogger.shared.crashLogPath()
    let totalMemMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
    // 尽力抓取崩溃前的最近日志，使报告带真实上下文（失败则退回 unavailable 提示）。
    let recentLog = appLoggerTailLines(logRef) ?? "(unavailable — see daily log \(logRef))"
    let crashFileText = CrashReportComposer.compose(
        date: ts,
        type: "Signal \(name) (\(sig))",
        build: appLoggerBuildString(),
        os: ProcessInfo.processInfo.operatingSystemVersionString,
        device: appLoggerDeviceModel(),
        lastPhase: "Signal handler (crash context)",
        memoryMB: "N/A",
        systemTotalMB: String(format: "%.0f", totalMemMB),
        lastLogLines: recentLog,
        stack: stackBlock,
        logReference: logRef
    )
    let crashPath = AppLogger.shared.crashLogFileURL().path
    let cfd = open(crashPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if cfd >= 0 {
        _ = crashFileText.withCString { cstr in
            write(cfd, cstr, strlen(cstr))
        }
        close(cfd)
    }
    // 恢复原处理并 re-raise，让系统生成标准崩溃报告。
    signal(sig, SIG_DFL)
    raise(sig)
}
