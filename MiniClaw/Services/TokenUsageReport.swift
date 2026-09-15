import Foundation

// MARK: - Token Usage Report

/// 一次 run 结束时上报的单次调用用量聚合（含缓存、耗时、循环次数），
/// 供上层同时写入「全局统计」与「会话级统计」。
struct TokenUsageReport {
    let modelId: String
    let input: Int
    let output: Int
    let cachedRead: Int
    let cachedWrite: Int
    /// [2026-09-15 DSH 对齐] 本步首 token 延迟（请求发出 → 首个生成 token，毫秒）；无样本为 nil。
    let ttftMs: Double?
    /// [2026-09-15 DSH 对齐] 本步解码窗口（首个生成 token → 该步完成，毫秒）；无样本为 nil。
    let decodeMs: Double?
    /// Agent 循环总次数（本轮 run 内的模型调用轮次）。
    let agentLoops: Int
}

