import Foundation

enum RootfsMaintenance {
    private static let pendingKey = "ish.pendingRootfsReinstall"

    /// 沙盒内 rootfs 部署目标路径（与 LinuxShellRuntime.deployedRootfsURL 保持一致，
    /// 但此处非 gated，供未集成 iSH 的构建也能计算路径）。
    static func deployedRootfsURL() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: true) else { return nil }
        return support.appendingPathComponent("MiniClaw/ish-rootfs", isDirectory: true)
    }

    /// 是否已请求"重启后恢复出厂"。
    static var isReinstallPending: Bool {
        UserDefaults.standard.bool(forKey: pendingKey)
    }

    /// 标记"下次启动时恢复出厂 rootfs"。真正的删除延后到下次启动 deploy 之前执行，
    /// 以避免删除正在被已 boot 内核占用的文件。
    static func requestReinstall() {
        UserDefaults.standard.set(true, forKey: pendingKey)
        AppLogger.shared.info("已请求 rootfs 恢复出厂（将于下次启动 App 时生效）",
                              category: "iSH", subsystem: "Runtime")
    }

    /// 取消尚未生效的重装请求。
    static func cancelReinstall() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
        AppLogger.shared.info("已取消 rootfs 恢复出厂请求", category: "iSH", subsystem: "Runtime")
    }

    /// 若存在待处理的重装请求，则删除已部署的沙盒 rootfs 并清除标记。
    /// **必须在任何 iSH boot / mount 之前调用**（App 启动 deploy 路径最前端）。
    /// 删除失败时保留标记并抛错，绝不能继续 boot 旧的损坏 rootfs。
    static func performPendingReinstallIfNeeded() throws {
        guard isReinstallPending else { return }
        guard let deployed = deployedRootfsURL() else {
            throw ShellError.runtimeNotReady
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: deployed.path) {
            do {
                try fm.removeItem(at: deployed)
                AppLogger.shared.info("rootfs 恢复出厂：已删除旧沙盒实例 \(deployed.path)",
                                      category: "iSH", subsystem: "Runtime")
            } catch {
                AppLogger.shared.error("rootfs 恢复出厂删除失败: \(error.localizedDescription)",
                                       category: "iSH", subsystem: "Runtime")
                throw error
            }
        }
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }
}

// MARK: - 统一入口

enum ShellRuntimeFactory {
    static let runtime: ShellRuntime = {
        #if ISH_ENABLED
        return LinuxShellRuntime.shared
        #else
        return PlaceholderShellRuntime()
        #endif
    }()
}

// MARK: - 错误

enum ShellError: LocalizedError {
    case runtimeNotReady
    case invalidRootfs(String)
    case launchFailed(Int32)
    case timeout

    var errorDescription: String? {
        switch self {
        case .runtimeNotReady: return String(localized: "shell_runtime_not_ready")
        case .invalidRootfs(let reason): return String(format: String(localized: "shell_invalid_rootfs"), reason)
        case .launchFailed(let code): return String(format: String(localized: "shell_launch_failed"), code)
        case .timeout: return String(localized: "shell_timeout")
        }
    }
}
