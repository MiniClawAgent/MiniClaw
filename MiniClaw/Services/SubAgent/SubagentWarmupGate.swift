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
    private var waiters: [String: [CheckedContinuation<Void,Never>]] = [:]

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
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitUntilWarm(endpointKey) }
            group.addTask { try? await Task.sleep(nanoseconds: Self.maxWaitNanos) }
            await group.next()          // 先到者胜：预热完成 或 超时
            group.cancelAll()
        }
        let waited = CACurrentMediaTime()-t0
        log("released",endpointKey,waited: waited,
            note: isWarm(endpointKey) ? "预热完成" : "超时放行")
    }

    /// 预热者已产生 output（首个文本 token 或首个工具调用）：共享前缀大概率
    /// 已写入缓存 → 放行其余并行子代理。
    func markWarm(endpointKey: String) {
        let wasWarm = isWarm(endpointKey)
        warmUntil[endpointKey] = Date().addingTimeInterval(Self.warmTTL)
        leaders.remove(endpointKey)
        let pending = waiters.removeValue(forKey: endpointKey) ?? []
        for c in pending { c.resume() }
        if !wasWarm || !pending.isEmpty {
            log("warm",endpointKey,waited: 0,note: "放行 \(pending.count) 个等待者")
        }
    }

    /// 预热者结束（无论成功失败）：交还领导权，让下一个补位。已 warm 的
    /// 窗口不受影响；等待者最迟由超时放行，不会死锁。
    func relinquishLead(endpointKey: String) {
        leaders.remove(endpointKey)
    }

    // MARK: - 内部

    private func waitUntilWarm(_ key: String) async {
        if isWarm(key) { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void,Never>) in
            waiters[key,default: []].append(c)
        }
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
