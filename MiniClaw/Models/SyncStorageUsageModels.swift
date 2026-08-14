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
    /// 输出流式阶段累计耗时（毫秒），用于计算平均输出速度。
    var outputDurationMs: Double = 0
}

/// 挂载点
