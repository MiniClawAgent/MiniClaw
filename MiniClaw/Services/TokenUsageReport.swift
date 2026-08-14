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
    /// 输出流式阶段耗时（毫秒），用于计算平均输出速度。
    let outputDurationMs: Double
    /// Agent 循环总次数（本轮 run 内的模型调用轮次）。
    let agentLoops: Int
}

