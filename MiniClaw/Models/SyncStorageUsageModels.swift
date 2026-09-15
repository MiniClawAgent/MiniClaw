import Foundation

struct SyncConfig: Codable {
    var iCloudEnabled: Bool = false
    var autoSync: Bool = true
    var lastSyncDate: Date?
}

/// 存储配置
struct StorageConfig: Codable {
    var totalUsage: Int64 = 0
    var workspaceSize: Int64 = 0
    var attachmentsSize: Int64 = 0
    var cacheSize: Int64 = 0
}

/// 词元 用量统计（对齐 spec：设置 → 词元 用量）
/// - `daily`：按天累计，key 为 "yyyy-MM-dd"，供「今日 / 本月」聚合。
/// - `byModel`：按模型累计，key 为模型 ID（如 "deepseek-chat"），含调用次数。
/// 数值来自服务商在流式响应中上报的用量；未上报时由本地估算兜底（见 AgentLoopEngine）。
struct TokenUsageStats: Codable {
    var daily: [String: DayStat] = [:]
    var byModel: [String: ModelStat] = [:]

    struct DayStat: Codable {
        var input: Int = 0
        var output: Int = 0
        /// 缓存读取 词元（prompt_tokens_details.cached_tokens）。可选以兼容旧数据。
        var cachedRead: Int? = nil
        /// 缓存写入 词元（prompt_tokens_details.cache_creation_tokens）。
        var cachedWrite: Int? = nil
    }

    struct ModelStat: Codable {
        var input: Int = 0
        var output: Int = 0
        var calls: Int = 0
        var cachedRead: Int? = nil
        var cachedWrite: Int? = nil
    }
}

/// 单次会话的 词元 用量累计（存入 AppSettings.sessionTokenUsage，按 sessionID 索引）。
/// 可选字段以兼容旧 settings.json。
struct SessionTokenUsageData: Codable {
    var input: Int = 0
    var output: Int = 0
    var cachedRead: Int? = nil
    var cachedWrite: Int? = nil
    /// Agent 循环总次数（模型被调用的轮次累计）。
    var agentLoops: Int = 0
    /// [2026-09-15 DSH 对齐] 输出吞吐 = **ΣdecodeTokens ÷ ΣdecodeMs**（求和后相除的 token 加权聚合，
    /// **不是**逐次平均、也不是中位数）——口径与 DSH `dsh-session-stats` 投影逐字一致。
    /// 只累计「同时带解码窗口与 output token 数」的步（DSH 原注："counting only steps that carry both"）。
    var decodeTokens: Int = 0
    /// Σ 解码窗口（首个生成 token → 该步完成，毫秒）。
    var decodeMs: Double = 0
    /// Σ 首 token 延迟（请求发出 → 首个生成 token，毫秒）。
    var ttftMs: Double = 0
    /// 带 TTFT 样本的步数（展示用 ΣttftMs ÷ ttftSteps 的平均值）。
    var ttftSteps: Int = 0
}

/// 挂载点
