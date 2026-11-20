import Foundation

// MARK: - Bash 可用性管理（自研，按需安装 + 退避）
//
// 背景：执行器是 busybox ash（iSH Alpine）；智能体命令常含 bash 语法。
// 本组件在 Swift 层探测/安装 bash，供 shell-execute 在 BashismDetector 命中时
// 用 `bash -lc` 包装执行（命令执行前决策，无重复副作用）。
// 约束：安装独立预算 60s；失败 30 分钟冷却；累计 3 次失败后放弃（不反复骚扰网络）。

enum BashSupport {
    /// 线程安全状态（Swift 6：async 上下文禁止直接持有 NSLock，封装到 Sendable 类的同步方法内）。
    private static let state = BashSupportState()

    /// 确保 bash 可用（探测 → 按需安装 → 缓存）。安装失败自动冷却。
    static func ensureInstalled() async -> Bool {
        if state.isKnown { return state.availableValue }
        let probe = await checkBash()
        if probe {
            state.markAvailable()
            return true
        }
        guard state.allowInstallAttempt() else { return false }
        let ok = await installBash()
        if ok { state.markAvailable() }
        return ok
    }

    /// 重置缓存（会话清理/调试用；一般不需要调用）。
    static func reset() {
        state.reset()
    }

    private static func checkBash() async -> Bool {
        guard let r = try? await ShellRuntimeFactory.runtime.execute(
            command: "command -v bash >/dev/null 2>&1 && echo yes || echo no",
            environment: [:],
            workingDirectory: nil,
            timeout: 15,
            onLine: { line, _ in ToolProgressScope.reporter?(line) },
            sessionID: nil
        ) else { return false }
        return r.stdout.contains("yes")
    }

    private static func installBash() async -> Bool {
        guard let r = try? await ShellRuntimeFactory.runtime.execute(
            command: "apk add --no-cache bash >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 && echo OK",
            environment: [:],
            workingDirectory: nil,
            timeout: 180,
            onLine: { line, _ in ToolProgressScope.reporter?(line) },
            sessionID: nil
        ) else { return false }
        return r.stdout.contains("OK")
    }
}

/// Bash 安装状态（@unchecked Sendable：全部访问经内部 NSLock 同步方法）。
private final class BashSupportState: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false
    private var known = false
    private var lastInstallAttempt: Date?
    private var installFailures = 0

    private let retryCooldown: TimeInterval = 1800
    private let maxInstallFailures = 3

    var isKnown: Bool {
        lock.lock(); defer { lock.unlock() }
        return known
    }

    var availableValue: Bool {
        lock.lock(); defer { lock.unlock() }
        return available
    }

    func markAvailable() {
        lock.lock(); defer { lock.unlock() }
        available = true
        known = true
    }

    /// 是否允许发起一次安装尝试（冷却 + 失败次数限制）。
    func allowInstallAttempt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if known { return false }
        if let last = lastInstallAttempt, Date().timeIntervalSince(last) < retryCooldown { return false }
        if installFailures >= maxInstallFailures { return false }
        lastInstallAttempt = Date()
        installFailures += 1
        return true
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        available = false
        known = false
        lastInstallAttempt = nil
        installFailures = 0
    }
}
