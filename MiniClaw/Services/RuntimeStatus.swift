import Foundation
import SwiftUI

// MARK: - 状态等级

enum StatusState {
    case ok
    case warning
    case error
    case unknown

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .unknown: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .ok: return L10n.l("status_ok")
        case .warning: return L10n.l("status_warning")
        case .error: return L10n.l("status_error")
        case .unknown: return L10n.l("status_unknown")
        }
    }
}

// MARK: - 状态快照

/// iSH 内核启动阶段。对应 MiniClawiSHBootState（C 侧）。
/// 新模型:rootfs 在 App 首次打开即后台部署,内核也在打开后后台预热,
/// 不再等到第一条 Shell 命令才启动。
enum BootPhase {
    case idle       // 尚未开始（App 打开即预热,仅极短暂窗口）
    case prewarming // 后台预热中
    case booted     // 已启动
    case failed     // 启动失败（运行 Shell 时自动重试）

    var statusState: StatusState {
        switch self {
        case .booted:     return .ok
        case .prewarming: return .warning
        case .failed:     return .error
        case .idle:       return .unknown
        }
    }

    /// “iSH 运行时”那一行的详细说明
    var runtimeDetail: String {
        switch self {
        case .booted:     return L10n.l("status_booted")
        case .prewarming: return L10n.l("status_prewarming")
        case .failed:     return L10n.l("status_failed")
        case .idle:       return L10n.l("status_idle")
        }
    }
}

struct RuntimeStatusSnapshot {
    let ishCompiledIn: Bool
    let booted: Bool
    let bootedState: StatusState
    let bootPhase: BootPhase
    let rootfsDeployed: Bool
    let rootfsPath: String?
    let rootfsSizeBytes: UInt64?
    let alpineDetected: Bool
    let alpineRelease: String?
    let alpineArch: String?
    let liveKernel: String?
    let liveArch: String?
    let liveRelease: String?
    let errorMessage: String?
    let gatheredAt: Date

    /// 综合判断
    var overall: StatusState {
        if !ishCompiledIn { return .unknown }
        if bootPhase == .booted && rootfsDeployed && alpineDetected { return .ok }
        if bootPhase == .failed { return .error }
        if bootPhase == .prewarming { return .warning }
        if rootfsDeployed { return .warning }
        return .error
    }

    /// 顶部列表行的快速摘要
    var summary: String {
        if !ishCompiledIn { return L10n.l("status_ish_not_integrated") }
        switch bootPhase {
        case .booted:
            let version = alpineRelease ?? "（未识别版本）"
            let arch = liveArch ?? alpineArch ?? "（未识别架构）"
            return String(format: L10n.l("status_ish_running"), version, arch)
        case .prewarming:
            return L10n.l("status_kernel_prewarming")
        case .failed:
            return L10n.l("status_kernel_failed")
        case .idle:
            return rootfsDeployed ? "已就绪 · 等待内核启动" : "rootfs 未部署"
        }
    }
}

// MARK: - 路径与大小工具

private func expectedRootfsURL() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("MiniClaw/ish-rootfs", isDirectory: true)
}

private func directorySize(_ url: URL) -> UInt64? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return nil }
    var total: UInt64 = 0
    guard let enumerator = fm.enumerator(at: url,
                                         includingPropertiesForKeys: [.fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
    for case let fileURL as URL in enumerator {
        if let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
           let size = vals.fileSize {
            total += UInt64(size)
        }
    }
    return total
}

// MARK: - 状态采集

/// 采集 iSH / rootfs / Alpine 的运行状态。
/// - Parameter performLiveProbe: true 时会真正启动 iSH 运行时并执行 `uname` 等命令（用于确认 runtime 实际可用）。
#if ISH_ENABLED

func gatherRuntimeStatus(performLiveProbe: Bool) async -> RuntimeStatusSnapshot {
    let booted = MiniClawiSHIsBooted()
    let bootPhase: BootPhase
    switch MiniClawiSHGetBootState() {
    case .prewarming: bootPhase = .prewarming
    case .booted:     bootPhase = .booted
    case .failed:     bootPhase = .failed
    case .idle:       bootPhase = .idle
    @unknown default: bootPhase = .idle
    }
    let rootURL = expectedRootfsURL()
    let fm = FileManager.default
    let deployed = fm.fileExists(atPath: rootURL.path)
    let size = deployed ? directorySize(rootURL) : nil

    // 不启动 runtime 的前提下，从 rootfs 文件树识别 Alpine 标记
    var detectedRelease: String? = nil        // Alpine 版本（如 3.20.0），来自 etc/alpine-release
    var detectedArch: String? = "aarch64"     // 编译目标架构（GUEST_ARM64）
    if deployed {
        let rel = rootURL.appendingPathComponent("etc/alpine-release")
        if let s = (try? String(contentsOf: rel, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            detectedRelease = s
        }
        // 通过 musl 动态链接器确认确实是 aarch64 根文件系统
        let musl = rootURL.appendingPathComponent("lib/ld-musl-aarch64.so.1")
        if !fm.fileExists(atPath: musl.path) {
            detectedArch = nil
        }
    }

    var liveKernel: String? = nil
    var liveArch: String? = nil
    var liveRel: String? = nil
    var errorMsg: String? = nil

    if performLiveProbe {
        do {
            let result = try await ShellRuntimeFactory.runtime.execute(
                command: "uname -a; echo '===ARCH==='; uname -m; echo '===REL==='; cat /etc/alpine-release 2>/dev/null || echo n/a",
                environment: [:],
                workingDirectory: nil,
                timeout: 15,
                onLine: nil,
                sessionID: nil
            )
            let out = result.stdout
            let parts = out.components(separatedBy: "===ARCH===")
            let kernelPart = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            liveKernel = kernelPart.isEmpty ? nil : kernelPart
            if parts.count > 1 {
                let rest = parts[1].components(separatedBy: "===REL===")
                let archPart = rest[0].trimmingCharacters(in: .whitespacesAndNewlines)
                liveArch = archPart.isEmpty ? nil : archPart
                if rest.count > 1 {
                    let relPart = rest[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    liveRel = (relPart == "n/a" || relPart.isEmpty) ? nil : relPart
                }
            }
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    let bootedState: StatusState = bootPhase.statusState
    let alpineDetected = detectedRelease != nil

    return RuntimeStatusSnapshot(
        ishCompiledIn: true,
        booted: booted,
        bootedState: bootedState,
        bootPhase: bootPhase,
        rootfsDeployed: deployed,
        rootfsPath: deployed ? rootURL.path : nil,
        rootfsSizeBytes: size,
        alpineDetected: alpineDetected,
        alpineRelease: detectedRelease,
        alpineArch: detectedArch,
        liveKernel: liveKernel,
        liveArch: liveArch,
        liveRelease: liveRel,
        errorMessage: errorMsg,
        gatheredAt: Date()
    )
}

#else

func gatherRuntimeStatus(performLiveProbe: Bool) async -> RuntimeStatusSnapshot {
    return RuntimeStatusSnapshot(
        ishCompiledIn: false,
        booted: false,
        bootedState: .unknown,
        bootPhase: .idle,
        rootfsDeployed: false,
        rootfsPath: nil,
        rootfsSizeBytes: nil,
        alpineDetected: false,
        alpineRelease: nil,
        alpineArch: nil,
        liveKernel: nil,
        liveArch: nil,
        liveRelease: nil,
        errorMessage: nil,
        gatheredAt: Date()
    )
}

#endif
