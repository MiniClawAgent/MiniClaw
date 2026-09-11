import Foundation

// MARK: - 单次触发守卫（iOS 17 兼容）
//
// completion / timeout / 启动失败会在不同线程竞争 resume 同一个 continuation，
// 必须保证只有先到者成功 resume（否则触发
// "SWIFT TASK CONTINUATION MISUSE: resume more than once" 崩溃）。
// 用 final class + NSLock 封装成引用类型 + Sendable，@Sendable 闭包捕获的是引用而非可变 var，
// 从而通过 Swift 6 严格并发检查（Atomic/OSAllocatedUnfairLock 分别要求 iOS 18/scope 不满足）。
private final class FinishOnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    /// 返回 true 表示本次调用抢到了唯一的"完成"资格。
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

// MARK: - Shell 执行结果

struct ShellResult: Sendable {
    let pid: Int32
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    let errorCode: Int
}

// MARK: - Shell 运行时协议（解耦 iSH 依赖，当前工程可编译）

protocol ShellRuntime: AnyObject, Sendable {
    var isReady: Bool { get }
    func execute(
        command: String,
        environment: [String: String],
        workingDirectory: String?,
        timeout: TimeInterval,
        onLine: (@Sendable (_ line: String, _ isStderr: Bool) -> Void)?,
        sessionID: UUID?
    ) async throws -> ShellResult
    func executeExecutable(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        onLine: (@Sendable (_ line: String, _ isStderr: Bool) -> Void)?,
        sessionID: UUID?
    ) async throws -> ShellResult
    func cancel(pid: Int32)
}

// MARK: - 当前占位实现（发布前替换为 iSH 真执行）

final class PlaceholderShellRuntime: ShellRuntime, @unchecked Sendable {
    var isReady: Bool { false }

    func execute(
        command: String,
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        timeout: TimeInterval = 60,
        onLine: (@Sendable (_ line: String, _ isStderr: Bool) -> Void)? = nil,
        sessionID: UUID? = nil
    ) async throws -> ShellResult {
        throw ShellError.runtimeNotReady
    }

    func executeExecutable(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        onLine: (@Sendable (_ line: String, _ isStderr: Bool) -> Void)? = nil,
        sessionID: UUID? = nil
    ) async throws -> ShellResult {
        throw ShellError.runtimeNotReady
    }

    func cancel(pid: Int32) {}
}

// MARK: - iSH 真 Shell 运行时（仅在链接 iSH 静态库后启用）

#if ISH_ENABLED

final class LinuxShellRuntime: ShellRuntime, @unchecked Sendable {
    static let shared = LinuxShellRuntime()

    /// 串行队列保护 rootfs 部署与恢复出厂操作，防止并发 copyItem 文件冲突
    private static let deployQueue = DispatchQueue(label: "com.neartop.miniclaw.ish.deploy")

    private init() {}

    var isReady: Bool { MiniClawiSHIsBooted() }

    /// 沙盒内 rootfs 的部署目标路径（Application Support/MiniClaw/ish-rootfs）。
    /// [2026-09-11 审计收敛] 委托 ShellRuntimeSupport.deployedRootfsURL()——全库
    /// 唯一权威（gated 非抛出版），四处硬编码已收口。
    static func deployedRootfsURL() throws -> URL {
        guard let url = RootfsMaintenance.deployedRootfsURL() else {
            throw ShellError.launchFailed(-3)
        }
        return url
    }

    /// 能启动 `/bin/sh` 所必需的 fakefs 文件。仅检查目录存在会把中断拷贝留下的
    /// 半成品误判为已部署，最终在 guest 内表现为 `do_execve(...)=ENOENT`。
    private static let requiredRootfsFiles = [
        "meta.db",
        "data/bin/sh",
        "data/bin/busybox",
        "data/lib/ld-musl-aarch64.so.1"
    ]

    private static func validateRootfs(at rootfs: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: rootfs.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        for relativePath in requiredRootfsFiles {
            let file = rootfs.appendingPathComponent(relativePath)
            guard fm.fileExists(atPath: file.path),
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0 else { return false }
        }
        return true
    }

    /// rootfs 是否完整部署到沙盒，而不只是存在一个同名目录。
    static var isRootfsDeployed: Bool {
        guard let deployed = try? deployedRootfsURL() else { return false }
        return validateRootfs(at: deployed)
    }

    /// 首次启动把 rootfs 从 App bundle 部署到沙盒，之后直接加载。
    /// 先复制到同一父目录的临时目录，完整性校验通过后再发布到最终路径，避免 App
    /// 被中断时留下一个会被下次启动误认成正常 rootfs 的半成品。
    @discardableResult
    static func deployRootfsIfNeeded() throws -> String {
        try deployQueue.sync {
            try RootfsMaintenance.performPendingReinstallIfNeeded()

            let fm = FileManager.default
            let deployed = try deployedRootfsURL()
            guard let bundled = Bundle.main.url(forResource: "rootfs", withExtension: nil),
                  validateRootfs(at: bundled) else {
                throw ShellError.invalidRootfs(String(localized: "shell_rootfs_missing_bin_sh"))
            }

            if validateRootfs(at: deployed) {
                ensureResolvConf(at: deployed)
                return deployed.path
            }

            let parent = deployed.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent("ish-rootfs.installing-\(UUID().uuidString)", isDirectory: true)

            do {
                try fm.copyItem(at: bundled, to: staging)
                guard validateRootfs(at: staging) else {
                    throw ShellError.invalidRootfs(String(localized: "shell_rootfs_staging_invalid"))
                }
                ensureResolvConf(at: staging)

                // 旧目录若存在，说明它未通过校验，是历史中断拷贝留下的半成品。
                if fm.fileExists(atPath: deployed.path) {
                    try fm.removeItem(at: deployed)
                    AppLogger.shared.info("检测到不完整 rootfs，已移除并准备重新部署",
                                          category: "iSH", subsystem: "Runtime")
                }
                try fm.moveItem(at: staging, to: deployed)
                AppLogger.shared.info("rootfs 完整性校验通过并已发布到 \(deployed.path)",
                                      category: "iSH", subsystem: "Runtime")
                return deployed.path
            } catch {
                if fm.fileExists(atPath: staging.path) {
                    try? fm.removeItem(at: staging)
                }
                throw error
            }
        }
    }

    /// 确保容器内 /etc/resolv.conf 存在并含可用 DNS。
    /// iSH 走宿主 socket 直连、自身不做 DNS 翻译，DNS 全靠 guest musl 查 nameserver；
    /// 缺 resolv.conf 或文件空白会导致所有主机名解析失败（表面现象即"容器无法联网"）。
    /// 若文件存在但不含有效 nameserver，也会覆盖，避免空/损坏配置拖慢命令。
    private static func ensureResolvConf(at deployedRootfs: URL) {
        let resolv = deployedRootfs.appendingPathComponent("data/etc/resolv.conf")
        let fm = FileManager.default
        try? fm.createDirectory(at: resolv.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        let content = """
        # Generated by MiniClaw for iSH/Alpine networking (host-socket translation)
        nameserver 8.8.8.8
        nameserver 1.1.1.1
        """

        if fm.fileExists(atPath: resolv.path),
           let existing = try? String(contentsOf: resolv, encoding: .utf8),
           existing.range(of: "nameserver", options: .caseInsensitive) != nil {
            return
        }

        try? content.write(to: resolv, atomically: true, encoding: .utf8)
    }

    /// App 首次打开时在后台部署 rootfs（要求 3：首次打开即部署）。
    /// 只做纯文件拷贝，绝不触发有崩溃风险的 iSH boot。失败仅记日志，不影响 App 启动。
    static func deployRootfsInBackground() {
        DispatchQueue.global(qos: .utility).async {
            do {
                // 恢复出厂、完整性校验与部署全部在 deployQueue 内完成，避免竞态。
                let path = try deployRootfsIfNeeded()
                AppLogger.shared.info("rootfs 已在首次启动验证/部署到 \(path)", category: "iSH", subsystem: "Runtime")
            } catch {
                AppLogger.shared.error("rootfs 首次启动部署失败: \(error.localizedDescription)", category: "iSH", subsystem: "Runtime")
            }
        }
    }

    /// App 首次打开时在后台预热 iSH 内核（boot），严格在 rootfs 部署完成后。
    /// 异步、不阻塞 App 启动；boot 失败可重试（MiniClawiSH.m 可重置守卫）且不污染启动。
    static func prewarmBootInBackground() {
        // 用 userInitiated 而非 utility：boot 直接决定终端/检测是否可用。
        // 关键修正：改用与「检测」相同的 MiniClawiSHEnsureBooted（同步 do_boot）而非
        // 异步 MiniClawiSHPrewarmBoot —— 实测冷启动早期异步 do_boot 易失败（进程/文件系统
        // 未就绪，mount_root 返回错误），而 App 已激活后再跑（检测/轮询重试走的就是这条）
        // 稳定成功。此处整体仍 dispatch 到后台全局队列，不阻塞调用方。
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rootfs = try deployRootfsIfNeeded()   // 同步确保部署完成（已部署则秒回）
                let err = MiniClawiSHEnsureBooted((rootfs as NSString).fileSystemRepresentation)
                if err < 0 {
                    AppLogger.shared.error("iSH boot 失败（将在 App 激活/轮询中重试）: \(err)", category: "iSH", subsystem: "Runtime")
                }
            } catch {
                AppLogger.shared.error("iSH rootfs 部署失败，无法启动 boot: \(error.localizedDescription)", category: "iSH", subsystem: "Runtime")
            }
        }
    }

    /// 确保 iSH runtime 已启动（一次性；启动顺序见 MiniClawiSH.m）。
    /// 部署与 boot 中涉及 dispatch_sync / 文件拷贝等阻塞操作，
    /// 全程走后台线程避免卡死主线程或挂起 Swift 协作式线程池。
    private func ensureBooted() async throws {
        let rootfs = try await Task.detached(priority: .userInitiated) {
            return try Self.deployRootfsIfNeeded()
        }.value
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let err = MiniClawiSHEnsureBooted((rootfs as NSString).fileSystemRepresentation)
                if err < 0 {
                    cont.resume(throwing: ShellError.launchFailed(Int32(err)))
                } else {
                    cont.resume()
                }
            }
        }
    }

    /// 执行 Shell 命令（字符串模式）
    func execute(
        command: String,
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        timeout: TimeInterval = 60,
        onLine: (@Sendable (_ line: String, _ isStderr: Bool) -> Void)? = nil,
        sessionID: UUID? = nil
    ) async throws -> ShellResult {
        try await ensureBooted()

        let fsContext = sessionID.map { SessionFileRouter.shared.fsContext(for: $0) } ?? 0

        var finalCommand = command
        if let wd = workingDirectory { finalCommand = "cd \(wd) && \(command)" }

        // 系统代理跟随（P4）：调用方未显式配置代理变量时，注入系统代理环境，
        // 使容器内命令与 App 其余网络（NSURLSession 自动跟随系统代理）行为一致。
        let effectiveEnv = Self.mergeEnvironment(environment)

        // [2026-09-11 审计修复] 任务取消传播：引擎停止/暂停时，正在执行的 iSH 命令
        // 必须被终止且 continuation 恰好 resume 一次（原实现无取消桥——命令继续占用
        // CPU 到自然结束，timeout<=0 时任务永久挂死）。
        final class ShellContinuation: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<ShellResult, any Error>?
            func store(_ c: CheckedContinuation<ShellResult, any Error>) {
                lock.lock(); continuation = c; lock.unlock()
            }
            /// 取走续体（恰一次）；已取走/未存入返回 nil。
            func take() -> CheckedContinuation<ShellResult, any Error>? {
                lock.lock(); defer { lock.unlock() }
                let c = continuation
                continuation = nil
                return c
            }
        }
        final class CancelSync: @unchecked Sendable {
            private let lock = NSLock()
            private var pid: Int32 = -1
            private var cancelled = false
            /// 登记子进程 pid；取消先到时返回 true（调用方需立即终止该 pid）。
            func register(newPid: Int32) -> Bool {
                lock.lock(); defer { lock.unlock() }
                pid = newPid
                return cancelled
            }
            /// 取消到达：登记意图并返回当前 pid（尚未启动返回 -1）。
            func cancelRequested() -> Int32 {
                lock.lock(); defer { lock.unlock() }
                cancelled = true
                return pid
            }
        }

        let box = ShellContinuation()
        let cancelSync = CancelSync()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.store(continuation)
                let guard_ = FinishOnceGuard()
                var timeoutWork: DispatchWorkItem?

                @Sendable func claimFinish() -> Bool { guard_.claim() }

                let pid = ISHShellExecutor.executeCommand(
                    finalCommand,
                    environment: effectiveEnv.isEmpty ? nil : effectiveEnv,
                    lineCallback: { line, isStderr in
                        onLine?(line, isStderr)
                    },
                    completion: { result in
                        guard claimFinish(), let cont = box.take() else { return }
                        timeoutWork?.cancel()   // 已正常完成，取消待触发的超时定时器
                        cont.resume(returning: ShellResult(
                            pid: Int32(result.pid),
                            exitCode: Int32(result.exitCode),
                            stdout: result.output,
                            stderr: result.errorOutput,
                            duration: result.duration,
                            errorCode: result.error.rawValue
                        ))
                    },
                    sessionFsContext: fsContext
                )

                if pid < 0 {
                    if claimFinish(), let cont = box.take() {
                        cont.resume(throwing: ShellError.launchFailed(pid))
                    }
                    return
                }

                // 子进程已启动；若取消早于启动到达，立即终止并上报。
                if cancelSync.register(newPid: Int32(pid)) {
                    self.cancel(pid: Int32(pid))
                    if claimFinish(), let cont = box.take() {
                        cont.resume(throwing: CancellationError())
                    }
                    return
                }

                if timeout > 0 {
                    let work = DispatchWorkItem { [weak self] in
                        guard claimFinish(), let cont = box.take() else { return }
                        self?.cancel(pid: pid)
                        cont.resume(throwing: ShellError.timeout)
                    }
                    timeoutWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
                }
            }
        } onCancel: { [weak self] in
            let pid = cancelSync.cancelRequested()
            // pid<0 = 子进程尚未启动：register 时会补终止；take()=nil = 已正常结束。
            guard pid >= 0, let cont = box.take() else { return }
            self?.cancel(pid: pid)
            cont.resume(throwing: CancellationError())
        }
    }

    /// 生成 POSIX TZ 值（符号与 UTC 偏移相反）：北京(UTC+8) → "UTC-8"；
    /// 纽约夏令时(UTC-4) → "UTC+4"；支持非整小时（印度 UTC+5:30 → "UTC-5:30"）。
    /// busybox `date` 原生支持 TZ 环境变量，无需 tzdata。
    private static func currentTZValue() -> String {
        let total = TimeZone.current.secondsFromGMT()
        let hours = total / 3600
        let minutes = abs(total % 3600) / 60
        let sign = total >= 0 ? "-" : "+"   // POSIX 符号反转
        let absHours = abs(hours)
        if minutes == 0 {
            return String(format: "UTC%@%d", sign, absHours)
        }
        return String(format: "UTC%@%d:%02d", sign, absHours, minutes)
    }

    /// 合并执行环境：注入系统时区（TZ，容器默认 UTC 与本地时间差 8 小时；
    /// 跟随系统时区，每条命令执行时读取，出国/改时区自动生效），
    /// 再合并系统代理（调用方显式配置过代理变量时尊重调用方）。
    private static func mergeEnvironment(_ environment: [String: String]) -> [String: String] {
        var merged = environment
        // 调用方显式传了 TZ 则尊重调用方，否则注入系统时区。
        if merged["TZ"] == nil {
            merged["TZ"] = currentTZValue()
        }
        let keys: Set<String> = ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"]
        guard !merged.keys.contains(where: { keys.contains($0) }) else {
            return merged
        }
        for (key, value) in SystemProxyStore.proxyEnvironment {
            merged[key] = value
        }
        return merged
    }

    /// 执行可执行文件 + 参数（推荐，防命令注入）
    func executeExecutable(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        onLine: (@Sendable (_ line: String, _ isStderr: Bool) -> Void)? = nil,
        sessionID: UUID? = nil
    ) async throws -> ShellResult {
        try await ensureBooted()

        let fsContext = sessionID.map { SessionFileRouter.shared.fsContext(for: $0) } ?? 0

        // 系统代理跟随（P4）：与 execute(command:) 同一策略。
        let effectiveEnv = Self.mergeEnvironment(environment)

        return try await withCheckedThrowingContinuation { continuation in
            let guard_ = FinishOnceGuard()

            @Sendable func claimFinish() -> Bool { guard_.claim() }

            let pid = ISHShellExecutor.executeExecutable(
                executable,
                arguments: arguments.isEmpty ? nil : arguments,
                environment: effectiveEnv.isEmpty ? nil : effectiveEnv,
                lineCallback: { line, isStderr in
                    onLine?(line, isStderr)
                },
                completion: { result in
                    guard claimFinish() else { return }
                    continuation.resume(returning: ShellResult(
                        pid: Int32(result.pid),
                        exitCode: Int32(result.exitCode),
                        stdout: result.output,
                        stderr: result.errorOutput,
                        duration: result.duration,
                        errorCode: result.error.rawValue
                    ))
                },
                sessionFsContext: fsContext
            )

            if pid < 0 {
                if claimFinish() {
                    continuation.resume(throwing: ShellError.launchFailed(pid))
                }
            }
        }
    }

    /// 取消进程
    func cancel(pid: Int32) {
        ISHShellExecutor.killProcess(pid, withSignal: 9)
    }
}

#endif

// MARK: - Rootfs 维护（卸载重装 / 恢复出厂）
//
// 与 ISH_ENABLED 解耦：只操作 UserDefaults + 沙盒文件，不引用任何 iSH C 符号，
// 因此设置界面在任意构建下都能调用。
//
// 为什么"重装"必须重启 App 才生效：
//   iSH 内核一旦 boot 便通过 mount_root 打开了 rootfs 的 fakefs（meta.db + data/），
//   而 iSH **不支持在进程内卸载 / 重挂载根**。若当场删除正在被内核占用的文件，
//   会导致崩溃或 fakefs 元数据损坏。安全做法是：
//     1) 用户点"恢复出厂" → 仅打一个持久化标记（requestReinstall）；
//     2) 用户重启 App；
//     3) 下次启动的 deploy 路径最前端调用 performPendingReinstallIfNeeded()，
//        此时内核尚未 boot，可安全删除旧沙盒 rootfs → 随后从 bundle 全新拷贝并重新 boot。
//   重启后进程是全新的，g_booted 本就为 NO，无需额外重置 C 侧守卫。
