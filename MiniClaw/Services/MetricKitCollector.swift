import Foundation
import MetricKit
import os

/// MetricKit 系统级崩溃诊断收集器。[MetricKit 2026-08-11]
///
/// 为什么需要它：App 内信号处理器(AppLogger)在部分场景抓不到崩溃——
/// ① Xcode/LLDB 调试下崩溃信号被调试器接管,App 处理器不触发;
/// ② 数据竞争/堆损坏(如 swift_release_dealloc)时 backtrace 本身可能失败;
/// ③ SIGKILL(系统回收/重装)无法被任何 App 内处理器捕获。
/// MetricKit 是系统级机制(基于 .ips),与 App 内存状态无关,上述场景全部兜底。
///
/// 工作方式：崩溃后**下次启动**(或当天稍晚)系统经 `MXMetricManager` 交付
/// `MXDiagnosticPayload`(含 MXCrashDiagnostic: crashReason + callStackTree)。
/// 收到后立即转成与现有 CrashReportComposer 同构的报告,以 `mxcrash-*.log`
/// 落盘——崩溃日志页零改动自动显示,文件名前缀 + Type 标记区分来源。
///
/// 注意：交付是**事后异步**的(系统调度,可能延迟数分钟~数小时),不是崩溃
/// 当场回调;系统只保留近期诊断,收到后须尽快落盘。
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = MetricKitCollector()

    /// 启动早期注册(与 installCrashHandlers 同阶段)。幂等。
    func start() {
        MXMetricManager.shared.add(self)
        AppLogger.shared.info("[MetricKit] 收集器已注册,等待系统交付诊断", category: "Crash")
    }

    // MARK: - MXMetricManagerSubscriber

    /// 系统交付诊断负载(崩溃/挂起/CPU 等)。主线程回调。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        AppLogger.shared.info("[MetricKit] 收到诊断负载 \(payloads.count) 个", category: "Crash")

        for payload in payloads {
            let timeStamp = payload.timeStampBegin
            // 崩溃诊断:本收集器唯一关心的负载类型。
            if let crash = payload.crashDiagnostics?.first {
                writeCrashDiagnostic(crash, at: timeStamp)
            }
        }
    }

    // MARK: - 落盘

    /// 把 MXCrashDiagnostic 转成现有报告格式并落盘为 mxcrash-*.log。
    private func writeCrashDiagnostic(_ crash: MXCrashDiagnostic, at date: Date) {
        // 崩溃原因:signal/exception/termination 摘要(系统侧,完整可靠)。
        // 注:MXCrashDiagnostic 无 crashReason 属性,用 signal/exceptionType/
        // terminationReason 组合描述(头文件 Headers/MXCrashDiagnostic.h 确认)。
        var reasonParts: [String] = []
        if let signal = crash.signal { reasonParts.append("signal=\(signal.intValue)") }
        if let exception = crash.exceptionType { reasonParts.append("exception=\(exception.intValue)") }
        if let term = crash.terminationReason { reasonParts.append("termination=\(term)") }
        if let memInfo = crash.virtualMemoryRegionInfo { reasonParts.append("vmRegion=\(memInfo)") }
        let reasonDetail = reasonParts.isEmpty ? "" : " (\(reasonParts.joined(separator: " ")))"
        let type = "MetricKit Crash\(reasonDetail)"

        // 调用栈:callStackTree 的 JSON 序列化(系统符号化,比 App 内 backtrace 完整)。
        // callStackTree.jsonRepresentation() 为非可选 Data(同步),无失败分支。
        let stack = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)

        // 崩溃发生时刻的日志尾部(尽力而为——崩溃可能发生在数小时前,
        // 当前日志尾部不一定对应崩溃时刻,但作为上下文仍有价值)。
        let lastLines = AppLogger.shared.lastLogLines(count: 20)

        CrashReporter.shared.writeMetricKitReport(
            type: type,
            stack: stack,
            date: date,
            lastLogLines: lastLines
        )
    }
}
