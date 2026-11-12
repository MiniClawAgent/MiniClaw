import Foundation
import QuartzCore

/// 子代理并行冷启动门（2026-09-06 缓存命中治理第二步）。
///
/// 问题：前缀缓存的写入有秒级延迟。一批子代理同时发起首个请求时，第一个的
/// 缓存还没写完，其余的就已经到了 → 每个都各自冷写一遍共享前缀。
/// 真机实测：3 个并行子代理 `prompt=12099 命中=0(0.0%) 写入=12099` ×3。
///
/// 对策：首批错峰——同端点下第一个子代理立即发起（负责把共享前缀写进缓存），
/// 其余等待「预热者产生首个 token / 首个工具调用」或超时后放行，从而复用
/// 已写入的前缀。命中建立后（warm 窗口内）后续派发直接放行，无额外延迟。
///
/// **按端点（modelId）分别记录 warm**：缓存是服务商账号维度的，A 厂商预热
/// 不等于 B 厂商已预热，混用会错误放行、白白丢掉一次错峰机会。
///
/// **2026-11-12 治本（ISSUES I-01）**：原实现用 `withTaskGroup` 让
/// 「等待预热」与 `Task.sleep(2.5s)` 竞速。`withTaskGroup` 退出前会隐式 await
/// 所有子任务，而等待者挂在**不可取消**的 `withCheckedContinuation` 上；
/// 一旦预热者在 2.5s 内失败/被停（`relinquishLead` 又不放行等待者），
/// 超时分支虽然先返回，group 仍要等那个永不 resume 的等待者 ⇒ `enter()` 永不返回
/// ⇒ `dispatch_subagent` 挂死整个会话主循环（只能杀 App）。
/// 现改为：等待者登记进 `WaiterRegistry`，由**超时任务直接 resume**（而不是与它竞速），
/// `relinquishLead` / `markWarm` 都会显式放行；不再使用 `withTaskGroup`。
actor SubagentWarmupGate {
    static let shared = SubagentWarmupGate()

    /// 命中建立后的有效期：期间新派发的子代理直接放行。过期后重新预热
    /// （应对规则/工具/设置变更导致前缀变化、缓存自然淘汰）。
    private static let warmTTL: TimeInterval = 600
    /// 等待预热者的上限：超时即放行，避免预热者异常（失败/取消/首轮只出工具
    /// 调用不出文本）时整批卡死。
    private static let maxWaitNanos: UInt64 = 2_500_000_000

    private var warmUntil: [String: Date] = [:]
    private var leaders: Set<String> = []
    private let waiters = WaiterRegistry()

    // MARK: - 入口

    /// 子代理发起首个请求前调用：预热者立即返回，其余等待预热完成或超时。
    func enter(endpointKey: String) async {
        if isWarm(endpointKey) {
            log("pass-warm",endpointKey,waited: 0,note: "窗口内直接放行")
            return
        }
        if !leaders.contains(endpointKey) {
            leaders.insert(endpointKey)
            log("leader",endpointKey,waited: 0,note: "本批预热者，立即发起")
            return
        }

        let t0 = CACurrentMediaTime()
        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 超时任务先建后登记：两者之间没有 await，不存在「已超时但未登记」窗口。
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.maxWaitNanos)
                } catch {
                    return // 已被 markWarm / relinquishLead 放行并取消：正常路径
                }
                await self?.timeoutWait(endpointKey, waiterID: waiterID)
            }
            waiters.add(
                waiterID,
                key: endpointKey,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
        }
        let waited = CACurrentMediaTime()-t0
        log("released",endpointKey,waited: waited,
            note: isWarm(endpointKey) ? "预热完成" : "放行")
    }

    /// 预热者已产生 output（首个文本 token 或首个工具调用）：共享前缀大概率
    /// 已写入缓存 → 放行其余并行子代理。
    func markWarm(endpointKey: String) {
        let wasWarm = isWarm(endpointKey)
        warmUntil[endpointKey] = Date().addingTimeInterval(Self.warmTTL)
        leaders.remove(endpointKey)
        let released = releaseWaiters(endpointKey)
        if !wasWarm || released > 0 {
            log("warm",endpointKey,waited: 0,note: "放行 \(released) 个等待者")
        }
    }

    /// 预热者结束（无论成功失败）：交还领导权，让下一个补位；**同时放行全部等待者**
    /// （预热者已失败，继续等同一个不会到来的 warm 没有意义）。
    /// 等待者最迟由 2.5s 超时放行，本函数保证失败路径不依赖超时也不死锁。
    func relinquishLead(endpointKey: String) {
        leaders.remove(endpointKey)
        let released = releaseWaiters(endpointKey)
        if released > 0 {
            log("leader-failed",endpointKey,waited: 0,note: "预热者结束，放行 \(released) 个等待者")
        }
    }

    // MARK: - 内部

    private func timeoutWait(_ key: String, waiterID: UUID) {
        guard let continuation = waiters.take(waiterID, key: key) else { return }
        continuation.resume()
        log("timeout",key,waited: Double(Self.maxWaitNanos)/1_000_000_000,
            note: "等待上限放行")
    }

    @discardableResult
    private func releaseWaiters(_ key: String) -> Int {
        let pending = waiters.takeAll(key)
        for continuation in pending { continuation.resume() }
        return pending.count
    }

    private func isWarm(_ key: String) -> Bool {
        Date() < (warmUntil[key] ?? .distantPast)
    }

    private func log(_ event: String,_ key: String,waited: Double,note: String) {
        AppLogger.shared.info(
            "[SubGate] \(event) key=\(key) waited=\(String(format: "%.2f", waited))s — \(note)",
            category: "SubGate",subsystem: "Cache"
        )
    }
}

// MARK: - 等待者登记表

/// 等待者 + 超时任务的线程安全登记表（隔离在 actor 外，避免在
/// `withCheckedContinuation` 的同步闭包里触碰 actor 状态）。
/// 语义：同一 waiterID 的 continuation **只会被取走一次**；取走时顺带取消其超时任务。
private final class WaiterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    func add(
        _ id: UUID,
        key: String,
        continuation: CheckedContinuation<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        lock.lock()
        continuations[key,default: [:]][id] = continuation
        timeoutTasks[id] = timeoutTask
        lock.unlock()
    }

    /// 超时路径：取走单个等待者（不存在说明已被其它路径放行/已超时）。
    func take(_ id: UUID, key: String) -> CheckedContinuation<Void, Never>? {
        lock.lock()
        timeoutTasks.removeValue(forKey: id)
        let continuation = continuations[key]?.removeValue(forKey: id)
        if continuations[key]?.isEmpty == true { continuations[key] = nil }
        lock.unlock()
        return continuation
    }

    /// 放行路径：取走该端点下全部等待者，并取消它们的超时任务。
    func takeAll(_ key: String) -> [CheckedContinuation<Void, Never>] {
        lock.lock()
        let pending = continuations.removeValue(forKey: key) ?? [:]
        for id in pending.keys {
            timeoutTasks.removeValue(forKey: id)?.cancel()
        }
        lock.unlock()
        return Array(pending.values)
    }
}
