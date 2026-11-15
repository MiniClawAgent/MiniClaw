import Foundation

struct ChatSettings: Codable, Equatable {
    // 2026-08-09 字体适配：移除 fontSize 设置，统一跟随系统动态字体（body 17pt 基准）。
    // 2026-09-05 移除 codeBlockTheme：代码块配色固定跟随系统外观。
    var showThinking: Bool = true
    var enterToSend: Bool = false
}

/// 语音设置（speech）
struct SpeechSettings: Codable, Equatable {
    var sttEnabled: Bool = false
    var ttsEnabled: Bool = false
    var voiceIdentifier: String = ""
    var speechRate: Double = 1.0
    var preferredLanguage: String = "auto"
}

/// 记忆设置（memory）
struct MemorySettings: Codable {
    var isEnabled: Bool = true
    var autoSaveDaily: Bool = true
    var retentionDays: Int = 30
    /// 是否启用向量召回（FTS + 向量混合检索）。首次安装默认关闭，由用户自行开启。
    var embeddingEnabled: Bool = false
    /// Embedding 模型名（OpenAI 兼容）。默认 text-embedding-3-small。
    var embeddingModel: String = "text-embedding-3-small"
    /// Embedding 供应商类型；用于复用该类型下已配置密钥的供应商（默认 OpenAI）。
    var embeddingProviderType: ProviderType = .openai
    /// 自定义压缩规则（注入历史压缩摘要提示词）；为空则用默认规则。
    var compressionRules: String = ""
    /// 是否允许后台自动整理长期记忆（去重 / 归并 / 主题重写，见 MemoryConsolidator）。
    var consolidationEnabled: Bool = true
    /// 语义归并阈值：条目向量余弦相似度 ≥ 该值判为同一事实。
    var consolidationSimilarity: Double = 0.90
    /// 自动整理的体量门槛：MEMORY.md 字符数低于此值时不自动跑（手动触发不受限）。
    var consolidationMinChars: Int = 3000
}

/// 浏览器设置（browser）
struct BrowserSettings: Codable, Equatable {
    var maxTabs: Int = 3
    /// User-Agent 形态：mobile / desktop / custom（custom 时取 userAgent 字段）
    var uaMode: String = "mobile"
    var userAgent: String = ""
    var blockPopups: Bool = true
    var defaultHomeURL: String = "https://www.apple.com"
    /// 地址栏搜索词使用的搜索引擎（仅切换搜索，不影响默认首页）：
    /// auto / bing / sogou / so360 / baidu / google / duckduckgo，默认 auto
    var searchEngine: String = "auto"
    /// 是否允许 AI 浏览器访问**局域网 / 本机**地址（默认关）。
    ///
    /// 关：拒绝 127.x、10.x、172.16-31.x、192.168.x、169.254.x、localhost、*.local
    ///     —— 防"网页内容注入诱导模型去打内网"的 SSRF。
    /// 开：允许，用于"让 AI 帮我管路由器 / 访问 NAS / 本地服务"。
    var allowPrivateNetwork: Bool = false

    enum CodingKeys: String, CodingKey {
        case maxTabs, uaMode, userAgent, blockPopups, defaultHomeURL, searchEngine, allowPrivateNetwork
    }

    /// 全字段 decodeIfPresent + 默认值兜底：新增字段缺键（旧数据）不整体失败丢其它设置。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxTabs = try c.decodeIfPresent(Int.self, forKey: .maxTabs) ?? 3
        uaMode = try c.decodeIfPresent(String.self, forKey: .uaMode) ?? "mobile"
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
        blockPopups = try c.decodeIfPresent(Bool.self, forKey: .blockPopups) ?? true
        defaultHomeURL = try c.decodeIfPresent(String.self, forKey: .defaultHomeURL) ?? "https://www.apple.com"
        searchEngine = try c.decodeIfPresent(String.self, forKey: .searchEngine) ?? "auto"
        allowPrivateNetwork = try c.decodeIfPresent(Bool.self, forKey: .allowPrivateNetwork) ?? false
    }

    init() {}
}

/// 外观设置（appearance）
