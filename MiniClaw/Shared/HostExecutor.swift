import Foundation

// MARK: - 宿主执行器（MiniClaw 无头执行 · 第一层）
//
// 职责（对齐无头执行架构 spec）：
// - 每次调用创建**独立执行任务**（无跨调用 session 持久化）；
// - 接收 command / timeout / workingDirectory；
// - **分别捕获 stdout 与 stderr**；
// - 等待任务结束，返回 exitCode + stdout + stderr；
// - 超时后**终止任务**；
// - 不要求交互式终端（无 PTY）；
// - 任务相互隔离，但**共享持久文件系统**（默认 /var/MiniClaw/）。
//
// macOS / 模拟器 / iSH 提供真实进程能力；iOS 真机在 iSH 接入前不可用（占位）。

/// 一次执行的结果。
public struct ExecutionResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// 是否成功（退出码 0 且未超时）。
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

#if os(macOS)

extension ExecutionResult {
    /// 合并 stdout+stderr 的文本（用于简单展示）。
    public var combined: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }
}

public enum HostExecutorError: Error {
    case cannotRun(String)
}

public struct HostExecutor {
    /// 默认共享持久文件系统根。任务隔离但共享此目录（与 12.2.3 文件系统边界一致）。
    public static let defaultWorkingDirectory = "/var/MiniClaw"

    /// 执行一条命令。
    /// - Parameters:
    ///   - command: 要执行的整条命令（经 /bin/sh -c 解释，支持管道、重定向）。
    ///   - timeout: 超时秒数，超时后终止任务。默认 900。
    ///   - workingDirectory: 工作目录，默认 `/var/MiniClaw`。不存在时回退到进程当前目录。
    ///   - environment: 额外注入的环境变量（如 $VAR 展开后的机密），合并到进程环境。
    ///   - inheritEnvironment: 是否继承当前进程环境，默认 true。
    public static func run(
        command: String,
        timeout: TimeInterval = 900,
        workingDirectory: String? = defaultWorkingDirectory,
        environment: [String: String]? = nil,
        inheritEnvironment: Bool = true
    ) -> ExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        // 工作目录：存在才设置，否则继承。
        if let wd = workingDirectory, !wd.isEmpty, FileManager.default.fileExists(atPath: wd) {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        // 环境变量：可选继承 + 注入。
        if inheritEnvironment || environment != nil {
            var env = inheritEnvironment
                ? (ProcessInfo.processInfo.environment as [String: String])
                : [String: String]()
            if let extra = environment { env.merge(extra) { $1 } }
            process.environment = env
        }

        // 分别捕获 stdout / stderr（无 PTY）。
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outLock = NSLock()
        var outData = Data()
        var errData = Data()

        let outQueue = DispatchQueue(label: "miniclaw.hostexec.stdout")
        let errQueue = DispatchQueue(label: "miniclaw.hostexec.stderr")
        let outGroup = DispatchGroup()
        let errGroup = DispatchGroup()
        outGroup.enter()
        errGroup.enter()
        outQueue.async {
            defer { outGroup.leave() }
            while let chunk = try? outPipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                outLock.lock(); outData.append(chunk); outLock.unlock()
            }
        }
        errQueue.async {
            defer { errGroup.leave() }
            while let chunk = try? errPipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                outLock.lock(); errData.append(chunk); outLock.unlock()
            }
        }

        let runGroup = DispatchGroup()
        runGroup.enter()
        process.terminationHandler = { _ in runGroup.leave() }

        do {
            try process.run()
        } catch {
            return ExecutionResult(exitCode: -1, stdout: "", stderr: "无法启动进程: \(error.localizedDescription)", timedOut: false)
        }

        // 超时控制：到点终止任务。
        var didTimeout = false
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            didTimeout = true
            process.terminate()
        }
        timer.resume()

        _ = runGroup.wait(timeout: .now() + timeout + 2)
        timer.cancel()

        // 等待输出读取完成。
        _ = outGroup.wait(timeout: .now() + 2)
        _ = errGroup.wait(timeout: .now() + 2)

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus
        return ExecutionResult(exitCode: exitCode, stdout: stdout, stderr: stderr, timedOut: didTimeout)
    }
}

#else

// iOS 真机：无独立进程能力，执行经由 iSH（尚未接入）。提供占位以保证 App 编译通过，
// 真实 shell 隔离契约由 iSH 接入后实现。
public struct HostExecutor {
    public static let defaultWorkingDirectory = "/var/MiniClaw"

    public static func run(
        command: String,
        timeout: TimeInterval = 900,
        workingDirectory: String? = defaultWorkingDirectory,
        environment: [String: String]? = nil,
        inheritEnvironment: Bool = true
    ) -> ExecutionResult {
        return ExecutionResult(
            exitCode: -1,
            stdout: "",
            stderr: "HostExecutor 在 iOS 真机需经 iSH (Alpine Linux) 接入；当前不可用。",
            timedOut: false
        )
    }
}

#endif
