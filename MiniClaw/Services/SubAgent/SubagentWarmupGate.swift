import Foundation

/// 子代理并行冷启动门（2026-09-06 缓存命中治理第二步）。
///
/// 问题：前缀缓存的写入有秒级延迟。一批子代理同时发起首个请求时，第一个的
/// 缓存还没写完，其余的就已经到了 → 每个都各自冷写一遍共享前缀。
/// 真机实测：3 个并行子代理 `prompt=12099 命中=0(0.0%) 写入=12099` ×3。
///
/// 对策：首批错峰——第一个子代理立即发起（它负责把共享前缀写进缓存），
/// 其余等待「预热者产生首个 token」或超时后放行，从而复用已写入的前缀。
/// 命中建立后（warm 窗口内）后续派发不再等待，无额外延迟。
actor SubagentWarmupGate {
    static let shared = SubagentWarmupGate()

    /// 命中建立后的有效期：期间新派发的子代理直接放行。过期后重新预热
    /// （应对规则/工具/设置变更导致前缀变化、缓存自然淘汰）。
    private static let warmTTL: TimeInterval = 600
    /// 等待预热者的上限：超时即放行，避免预热者异常时整批卡死。
    private static let maxWaitNanos: UInt64 = 2_500_000_000

    private var warmUntil: Date = .distantPast
    private var leaderRunning = false
    private var waiters: [CheckedContinuation<Void,Never>] = []

    /// 子代理发起首个请求前调用：预热者立即返回，其余等待预热完成或超时。
    func enter() async {
        if Date() < warmUntil { return }
        let isLeader = !leaderRunning
        if isLeader {
            leaderRunning = true
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (c: CheckedContinuation<Void,Never>) in
                    Task { await self?.addWaiter(c) }
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: Self.maxWaitNanos) }
            await group.next()
            group.cancelAll()
        }
    }

    /// 预热者收到首个 token：共享前缀已写入，放行其余子代理。
    func markWarm() {
        warmUntil = Date().addingTimeInterval(Self.warmTTL)
        leaderRunning = false
        let pending = waiters
        waiters.removeAll()
        for c in pending { c.resume() }
    }

    /// 预热者异常结束（失败/取消/无内容）：释放领导权，让下一个补位，
    /// 已等待者按超时放行，不会死锁。
    func relinquishLead() {
        leaderRunning = false
    }

    private func addWaiter(_ c: CheckedContinuation<Void,Never>) {
        if Date() < warmUntil {
            c.resume()
        } else {
            waiters.append(c)
        }
    }
}
