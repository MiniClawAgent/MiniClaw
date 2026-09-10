import Foundation
import UIKit
import Darwin.Mach

private let logger = AppLogger(category: "MiniClawResourceMonitor")

///
///
/// Deliberately NOT reusing `SystemResourceMonitor` (ChatView.swift): that is
///
///
///
/// footprint is **not** counted in our `task_info`, and our app will not even
/// reliably get a memory warning when WebContent is under pressure.
/// sandbox) or `proc_pid_rusage()` (won't cross to WebContent). And we can't
/// get its pid anyway: the public WebKit headers expose no process identifier.
/// `_webProcessIdentifier` is SPI — an App Store review risk, so not an option.
/// debuggers outside our sandbox. That capability does not exist at runtime.
///
///
@MainActor
public final class MiniClawResourceMonitor {
    public static let shared = MiniClawResourceMonitor()

    private static let sampleInterval: TimeInterval = 8.0

    private static let stuckThreshold: TimeInterval = 30.0

    ///
    public struct WebContentLiveness {
        let hasURL: Bool
        let hasTitle: Bool
        var looksBlank: Bool { !hasURL && !hasTitle }
    }

    /// Injected by `MiniClawTabPool` so this stays out of the browser layer:
    public var livenessProbe: ((Int) -> WebContentLiveness?)?

    private struct Inflight {
        let action: String
        let url: String?
        let tabId: Int?
        let startedAt: Date
        let startedInBackground: Bool
        var stuckTask: Task<Void,Never>?
        var stuckReported = false
    }

    private var inflight: [UUID: Inflight] = [:]
    private var samplingTask: Task<Void,Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        observeLifecycle()
    }

    public struct Snapshot {
        let appState: String
        let appMemoryMB: Int
        ///
        let appAvailableMemoryMB: Int
        let appCPUPercent: Double
        let thermalState: String
        let lowPowerMode: Bool
        let backgroundTimeRemaining: TimeInterval?

        var logLine: String {
            var parts: [String] = [
                "app_state=\(appState)",
                "app_mem=\(appMemoryMB)MB",
                "app_avail_mem=\(appAvailableMemoryMB)MB",
                "app_cpu=\(String(format: "%.1f", appCPUPercent))%",
                "thermal=\(thermalState)",
                "low_power=\(lowPowerMode)",
            ]
            if let remaining = backgroundTimeRemaining {
                parts.append("bg_time_left=\(String(format: "%.0f", remaining))s")
            }
            return parts.joined(separator: " ")
        }
    }

    public func snapshot() -> Snapshot {
        let state = UIApplication.shared.applicationState
        let stateName: String
        switch state {
        case .active: stateName = "active"
        case .inactive: stateName = "inactive"
        case .background: stateName = "background"
        @unknown default: stateName = "unknown"
        }

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }

        let rawRemaining = UIApplication.shared.backgroundTimeRemaining
        let remaining: TimeInterval? =
            (state == .background && rawRemaining<24*60*60) ? rawRemaining : nil

        return Snapshot(
            appState: stateName,
            appMemoryMB: Self.appMemoryMB(),
            appAvailableMemoryMB: Self.appAvailableMemoryMB(),
            appCPUPercent: Self.appCPUPercent(),
            thermalState: thermal,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            backgroundTimeRemaining: remaining
        )
    }

    @discardableResult
    public func actionWillStart(action: String,url: String?,tabId: Int?) -> UUID {
        let id = UUID()
        let snap = snapshot()
        let isBackground = snap.appState == "background"

        var entry = Inflight(
            action: action,
            url: url,
            tabId: tabId,
            startedAt: Date(),
            startedInBackground: isBackground,
            stuckTask: nil,
            stuckReported: false
        )

        let target = url.map { " url=\($0)" } ?? ""
        let tab = tabId.map { " tab=\($0)" } ?? ""
        logger.info("[BrowserToolDiag] start action=\(action)\(tab)\(target) \(snap.logLine)")

        if isBackground {
            logger.warning(
                "[BrowserToolDiag] backgrounded-dispatch action=\(action)\(tab) — "
                + "browser action issued while app is in background; WebContent may be "
                + "suspended by the system and this action may never return. \(snap.logLine)"
            )
        }

        entry.stuckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stuckThreshold*1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.reportStuck(id: id)
        }

        inflight[id] = entry
        startSamplingIfNeeded()
        return id
    }

    public func actionDidFinish(_ id: UUID,success: Bool,error: String? = nil) {
        guard let entry = inflight.removeValue(forKey: id) else { return }
        entry.stuckTask?.cancel()

        let elapsedMs = Int(Date().timeIntervalSince(entry.startedAt)*1000)
        let snap = snapshot()
        let tab = entry.tabId.map { " tab=\($0)" } ?? ""
        let outcome = success ? "ok" : "fail"
        let errPart = error.map { " error=\($0)" } ?? ""
        let bgPart = entry.startedInBackground ? " started_in_background=true" : ""

        logger.info(
            "[BrowserToolDiag] end action=\(entry.action)\(tab) result=\(outcome) "
            + "elapsed=\(elapsedMs)ms\(bgPart)\(errPart) \(snap.logLine)"
        )

        if entry.stuckReported {
            logger.warning(
                "[BrowserToolDiag] stuck-recovered action=\(entry.action)\(tab) "
                + "elapsed=\(elapsedMs)ms result=\(outcome) — action returned after being "
                + "flagged stuck. \(snap.logLine)"
            )
        }

        stopSamplingIfIdle()
    }

    private func reportStuck(id: UUID) {
        guard var entry = inflight[id],!entry.stuckReported else { return }
        entry.stuckReported = true
        inflight[id] = entry

        let elapsed = Int(Date().timeIntervalSince(entry.startedAt))
        let snap = snapshot()
        let tab = entry.tabId.map { " tab=\($0)" } ?? ""
        let target = entry.url.map { " url=\($0)" } ?? ""

        logger.warning(
            "[BrowserToolDiag] STUCK action=\(entry.action)\(tab)\(target) "
            + "elapsed=\(elapsed)s started_in_background=\(entry.startedInBackground) "
            + "still_running — \(snap.logLine)"
        )

        guard let tabId = entry.tabId,let live = livenessProbe?(tabId) else { return }
        if live.looksBlank {
            logger.error(
                "[BrowserToolDiag] webcontent-presumed-dead tab=\(tabId) "
                + "action=\(entry.action) elapsed=\(elapsed)s — WKWebView is blank "
                + "(url=nil title=empty) while the action is still pending, and no "
                + "termination callback fired. WebContent was very likely killed by "
                + "the system; this action will never return on its own. \(snap.logLine)"
            )
        } else {
            logger.warning(
                "[BrowserToolDiag] webcontent-alive tab=\(tabId) action=\(entry.action) "
                + "elapsed=\(elapsed)s has_url=\(live.hasURL) has_title=\(live.hasTitle) "
                + "— WKWebView still holds its page, so this is NOT a WebContent kill; "
                + "suspect suspension or a stranded continuation."
            )
        }
    }

    private func startSamplingIfNeeded() {
        guard samplingTask == nil,!inflight.isEmpty else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.sampleInterval*1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard await self.emitPeriodicSample() else { return }
            }
        }
    }

    private func emitPeriodicSample() -> Bool {
        guard !inflight.isEmpty else {
            samplingTask = nil
            return false
        }
        let snap = snapshot()
        let now = Date()
        let running = inflight.values
            .map { entry -> String in
                let secs = Int(now.timeIntervalSince(entry.startedAt))
                let tab = entry.tabId.map { "#\($0)" } ?? "#-"
                return "\(entry.action)\(tab)@\(secs)s"
            }
            .sorted()
            .joined(separator: ",")

        logger.info(
            "[MiniClawResourceMonitor] sample inflight=\(inflight.count) "
            + "actions=[\(running)] \(snap.logLine)"
        )
        return true
    }

    private func stopSamplingIfIdle() {
        guard inflight.isEmpty else { return }
        samplingTask?.cancel()
        samplingTask = nil
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let transitions: [(Notification.Name,String)] = [
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.willResignActiveNotification, "willResignActive"),
        ]
        for (name,label) in transitions {
            let token = center.addObserver(forName: name,object: nil,queue: .main) { _ in
                MainActor.assumeIsolated {
                    MiniClawResourceMonitor.shared.logLifecycle(label)
                }
            }
            lifecycleObservers.append(token)
        }

        memoryWarningObserver = center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                MiniClawResourceMonitor.shared.logMemoryWarning()
            }
        }
    }

    private func logLifecycle(_ transition: String) {
        let snap = snapshot()
        let count = inflight.count
        let line = "[BrowserToolDiag] lifecycle=\(transition) inflight_browser_actions=\(count) \(snap.logLine)"
        if count > 0, transition == "didEnterBackground" {
            logger.warning(line + " — browser actions in flight while backgrounding")
        } else {
            logger.info(line)
        }
    }

    private func logMemoryWarning() {
        let snap = snapshot()
        logger.warning(
            "[BrowserToolDiag] memory-warning inflight_browser_actions=\(inflight.count) \(snap.logLine)"
        )
    }

    public func webContentProcessDidTerminate(tabId: Int?,url: String?) {
        let snap = snapshot()
        let tab = tabId.map { " tab=\($0)" } ?? ""
        let target = url.map { " url=\($0)" } ?? ""
        logger.error(
            "[BrowserToolDiag] webcontent-terminated\(tab)\(target) "
            + "inflight_browser_actions=\(inflight.count) — WKWebView WebContent process was "
            + "killed by the system (OOM/jetsam). Any in-flight action on this tab will not "
            + "return. \(snap.logLine)"
        )
    }

    private static func appMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self,capacity: Int(count)) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint)/(1024*1024)
    }

    private static func appAvailableMemoryMB() -> Int {
        Int(os_proc_available_memory())/(1024*1024)
    }

    private static func appCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_,&threadList,&threadCount) == KERN_SUCCESS,
              let threads = threadList else { return -1 }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount)*MemoryLayout<thread_t>.stride)
            )
        }

        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self,capacity: Int(count)) {
                    thread_info(threads[i],thread_flavor_t(THREAD_BASIC_INFO),$0,&count)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            if info.flags&TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage)/Double(TH_USAGE_SCALE)*100.0
            }
        }
        return total
    }
}
