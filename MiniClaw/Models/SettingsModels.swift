import Foundation

/// Agent 人格配置（对齐 SOUL.md frontmatter：name / style / lang + body）
struct SoulConfig: Codable {
    ///     /// 并与 SOUL.md 种子文件、appState.agentName 对齐（见 SettingsStore 迁移兜底）。
    var name: String = "MiniClaw"
    var style: String = ""
    /// 响应语言：auto / zh / en — 对齐 spec 9.2.3
    var lang: String = "auto"
    var body: String = ""
}

/// LLM 服务商配置
struct LLMProvider: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var label: String = ""
    var providerType: ProviderType = .openai
    /// 运行时密钥（仅内存，不落盘）。落盘由 APIKeyStore(Keychain) 负责。
    /// 仍保留在 CodingKeys 以兼容旧版明文文件迁移，但 encode 不写出。
    var apiKey: String = ""
    var customBaseURL: String = ""
    var apiFormat: APIFormat = .chatCompletions
    var azureEnabled: Bool = false
    var isEnabled: Bool = true
    /// OpenAI Organization ID（用于多组织计费/权限）
    var organizationId: String = ""
    /// OpenAI Project ID
    var projectId: String = ""
    /// 凭证类型（只读语义：apiKey / oauth）— 对齐 spec 9.2.1
    var credentialType: String = "apiKey"
    /// 自定义 User-Agent 头 — 对齐 spec 9.2.1
    var customUserAgent: String = ""
    /// 是否自动追加 /v1 到 base URL — 对齐 spec 9.2.1
    var appendV1Suffix: Bool = false
    /// 图片生成端点模式：auto / images_generations / chat_completions — 对齐 spec 9.2.1
    var imageEndpointMode: String = "auto"
    /// 运行时模型列表（不落盘——由 ProvidersContainer.modelEntries 在加载时填充）。
    /// 同步层用 ModelEntry(compositeKey + baseModel + overrides) 作为同步格式。
    var models: [ModelConfig] = []
    /// 是否已配置密钥（落盘标记，对应 Keychain 中的存在性）— 对齐 spec 9.2 / 12.2
    var hasApiKey: Bool = false
    /// 用户自定义请求头（键值对），运行时合并进 LLM 请求，对接不同中转网关时附加任意头。
    var customHeaders: [String: String] = [:]
    /// 模型列表拉取失败信息（可持久化）。非空时，在「模型」位置提示用户检查密钥 / API 地址。
    var modelFetchError: String? = nil
    /// 模型列表拉取的非阻断提示（可持久化）。如实时列表不可用已回退内置目录等。
    var modelFetchNotice: String? = nil

    /// API Key 是否已配置（基于落盘标记；运行时密钥由内存 apiKey 提供）
    var keyAdded: Bool {
        hasApiKey
    }
}

extension LLMProvider {
    private enum CodingKeys: String, CodingKey {
        case id, label, providerType, apiKey, customBaseURL, apiFormat
        case azureEnabled, isEnabled, credentialType, customUserAgent
        case appendV1Suffix, imageEndpointMode, hasApiKey
        case organizationId, projectId, customHeaders, modelFetchError, modelFetchNotice
        // models 不在 CodingKeys 中——它是运行时属性，不落盘。
        // 加载时由 ProviderFileStore 从 ProvidersContainer.modelEntries 填充。
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        providerType = try container.decodeIfPresent(ProviderType.self, forKey: .providerType) ?? .openai
        // 兼容旧版明文 apiKey：解码后由 ProviderFileStore 迁移至 Keychain（此处仅暂存内存态）
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        customBaseURL = try container.decodeIfPresent(String.self, forKey: .customBaseURL) ?? ""
        apiFormat = try container.decodeIfPresent(APIFormat.self, forKey: .apiFormat) ?? .chatCompletions
        azureEnabled = try container.decodeIfPresent(Bool.self, forKey: .azureEnabled) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        credentialType = try container.decodeIfPresent(String.self, forKey: .credentialType) ?? "apiKey"
        customUserAgent = try container.decodeIfPresent(String.self, forKey: .customUserAgent) ?? ""
        appendV1Suffix = try container.decodeIfPresent(Bool.self, forKey: .appendV1Suffix) ?? false
        imageEndpointMode = try container.decodeIfPresent(String.self, forKey: .imageEndpointMode) ?? "auto"
        // models 是运行时属性，不从 JSON 解码。由 ProviderFileStore 在加载后填充。
        hasApiKey = try container.decodeIfPresent(Bool.self, forKey: .hasApiKey) ?? !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        organizationId = try container.decodeIfPresent(String.self, forKey: .organizationId) ?? ""
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId) ?? ""
        customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        modelFetchError = try container.decodeIfPresent(String.self, forKey: .modelFetchError) ?? nil
        modelFetchNotice = try container.decodeIfPresent(String.self, forKey: .modelFetchNotice) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(providerType, forKey: .providerType)
        // 注意：apiKey 明文不写出，密钥已存入 Keychain。
        try container.encode(customBaseURL, forKey: .customBaseURL)
        try container.encode(apiFormat, forKey: .apiFormat)
        try container.encode(azureEnabled, forKey: .azureEnabled)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(credentialType, forKey: .credentialType)
        try container.encode(customUserAgent, forKey: .customUserAgent)
        try container.encode(appendV1Suffix, forKey: .appendV1Suffix)
        try container.encode(imageEndpointMode, forKey: .imageEndpointMode)
        // models 不编码——它是运行时属性，落盘由 ProvidersContainer.modelEntries 负责。
        try container.encode(hasApiKey, forKey: .hasApiKey)
        try container.encode(organizationId, forKey: .organizationId)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(customHeaders, forKey: .customHeaders)
        try container.encode(modelFetchError, forKey: .modelFetchError)
        try container.encode(modelFetchNotice, forKey: .modelFetchNotice)
    }
}

/// API 调用格式
enum APIFormat: String, Codable, CaseIterable, Identifiable {
    case chatCompletions = "Chat Completions"
    case responsesAPI = "Responses API"
    var id: String { rawValue }
}

enum ProviderType: String, Codable, CaseIterable {
    case openai = "OpenAI"
    case anthropic = "Anthropic"
    case google = "Google Gemini"
    case openRouter = "OpenRouter"
    case custom = "OpenAI Compatible"
    case grok = "xAI Grok"
    case deepSeek = "DeepSeek"
    case qwen = "Qwen 千问"
    case xiaomi = "Xiaomi MiMo"
    case zhipu = "Zhipu 智谱"

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .google: return "https://generativelanguage.googleapis.com"
        case .openRouter: return "https://openrouter.ai/api"
        case .custom: return ""
        case .grok: return "https://api.x.ai"
        case .deepSeek: return "https://api.deepseek.com"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode"
        case .xiaomi: return "https://api.xiaomimimo.com"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        }
    }

    /// 按兼容格式分类（用于设置列表分组与匹配，英文语义 key；显示走 L10n.l）
    var compatFormat: String {
        switch self {
        case .openai, .openRouter, .custom, .grok, .deepSeek, .qwen, .xiaomi, .zhipu: return "openai_compatible"
        case .anthropic: return "anthropic_compatible"
        case .google: return "google_gemini"
        }
    }

    /// 默认显示标签
    var defaultLabel: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .custom: return "OpenAI 兼容"
        case .grok: return "xAI Grok"
        case .deepSeek: return "DeepSeek"
        case .qwen: return "Qwen 千问"
        case .xiaomi: return "Xiaomi MiMo"
        case .zhipu: return "Zhipu 智谱"
        }
    }

    /// 是否支持 OAuth 认证（添加服务商时展示「认证方式选择」）。
    /// 已适配 OAuth 登录的服务商：Anthropic / OpenAI（见 AppState.oauthManager）。
    var supportsOAuth: Bool {
        switch self {
        case .anthropic, .openai: return true
        default: return false
        }
    }

    // MARK: - Responses API 厂商能力表（单一事实来源，禁止散落 if 判断）

    /// Responses API 端点路径（相对 base URL 根；nil = 该供应商不支持 Responses API）。
    /// 依据各厂商官方文档 2026-08 核对：
    /// - DeepSeek 官方端点无 /v1 前缀（api-docs.deepseek.com/zh-cn/guides/responses_api）；
    /// - 智谱官方 OpenAPI spec 无任何 responses 路径（仅 chat/completions）；
    /// - Anthropic / Gemini 为独立协议，不适用 Responses。
    /// 标记为 nil（不支持）的供应商在请求时自动回落 Chat Completions。
    var responsesPath: String? {
        switch self {
        case .deepSeek: return "responses"
        case .zhipu, .anthropic, .google: return nil
        case .openai, .openRouter, .custom, .grok, .qwen, .xiaomi: return "v1/responses"
        }
    }

    /// Responses API 的 reasoning.effort 是否接受 "none"（官方枚举未列出的供应商省略该字段，
    /// 避免 400）：OpenAI / 小米官方接受；**DeepSeek 官方 thinking_mode 页明确 Responses 格式
    /// effort 接受 none/low/high/max**（none=关闭思考，2026-08 核对）；OpenRouter 官方枚举未列。
    var supportsReasoningNone: Bool {
        switch self {
        case .openai, .xiaomi, .deepSeek: return true
        default: return false
        }
    }

    /// 厂商 embedding 支持登记（单一事实来源，2026-08 官网核对）。
    /// 适配新厂商 / 厂商能力变化时**必须**更新本表（「模型适配资料完整」纪律的组成部分）：
    /// 记忆嵌入设置的端点解析（AppState.resolveEmbeddingEndpoint）与运行时探测均以此为准，
    /// 未登记的厂商一律按「不支持」处理，自动回退全文注入。
    var embeddingSupport: EmbeddingSupport? {
        switch self {
        case .openai:
            return EmbeddingSupport(openAICompatPath: "v1/embeddings",
                                    models: ["text-embedding-3-small", "text-embedding-3-large"])
        case .openRouter:
            return EmbeddingSupport(openAICompatPath: "v1/embeddings",
                                    models: [],
                                    note: "代理任意 OpenAI 兼容 embedding 模型（默认端点 openrouter.ai/api/v1/embeddings）")
        case .qwen:
            return EmbeddingSupport(openAICompatPath: "embeddings",
                                    models: ["text-embedding-v4", "text-embedding-v3"],
                                    note: "百炼 compatible-mode 下默认端点 dashscope.aliyuncs.com/compatible-mode/embeddings")
        case .zhipu:
            return EmbeddingSupport(openAICompatPath: "embeddings",
                                    models: ["embedding-3"],
                                    note: "默认端点 open.bigmodel.cn/api/paas/v4/embeddings")
        case .google:
            return EmbeddingSupport(openAICompatPath: nil,
                                    models: ["embedding-001"],
                                    note: "原生 embedContent 格式，非 OpenAI 兼容，未接入 EmbeddingClient")
        case .grok:
            return EmbeddingSupport(openAICompatPath: nil,
                                    models: [],
                                    note: "官方未公布 embedding 模型（2026-08 未验证）")
        case .anthropic, .deepSeek, .xiaomi, .custom:
            // 官方无 embedding（Anthropic 明示不提供；DeepSeek API 参考无；小米模型矩阵无）；
            // custom 端点由用户自填，不预登记。
            return nil
        }
    }
}

/// 厂商 embedding 支持登记（模型适配资料之一；nil 表示不支持 / 未登记）。
struct EmbeddingSupport: Equatable {
    /// OpenAI 兼容 `/embeddings` 端点相对路径（相对厂商默认 baseURL；nil=无 OpenAI 兼容端点）。
    var openAICompatPath: String?
    /// 官方 embedding 模型 ID（OpenAI 兼容格式；空=不限定）。
    var models: [String]
    /// 补充说明（原生格式 / 未验证等）。
    var note: String?
}

struct ModelConfig: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    /// 模型 ID（必需）
    var modelId: String = ""
    /// 显示名称（可选，留空则使用模型 ID）
    var displayName: String = ""
    /// 用户是否已手动修改显示名；为 true 时重新拉取模型不再覆盖 displayName。
    /// Optional 用于兼容旧数据（缺失时等价于 false）。
    var userRenamed: Bool?
    /// 上下文窗口（0 表示使用默认值）
    var contextLimit: Int = 0
    /// 深度思考支持状态
    var deepThinking: Bool = false
    /// 服务商返回的最大输出 词元；nil 表示服务商未提供。
    var maxOutputTokens: Int?
    /// 隐藏后不在模型组模型选项和添加列表中出现。Optional 用于兼容旧 providers.json。
    var isHidden: Bool?
    /// 输入模态
    /// 文本输入：LLM 的通用基线能力，默认开启（以 `text` 作为文本输入的标准模态，
    /// 厂商 API 一般不单独暴露 `document` 作为输入模态类型）。
    var inputText: Bool = true
    var inputImage: Bool = false
    var inputAudio: Bool = false
    var inputVideo: Bool = false
    /// 输出模态
    /// 文本输出：LLM 的通用基线能力，默认开启（以 `text` 作为文本输出的标准模态）。
    var outputText: Bool = true
    var outputImage: Bool = false
    var outputAudio: Bool = false

    /// 解析后的显示名：留空则用模型 ID
    var resolvedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? modelId : displayName
    }

    var hidden: Bool {
        isHidden ?? false
    }

    /// 将模型 ID 规整为「每个单词首字母大写」的显示名。
    /// 例如 deepseek-v4-flash → Deepseek V4 Flash，gpt-4o-mini → Gpt 4o Mini。
    /// 注意：小数点（版本号分隔符，如 4.5）保留，不转成空格，避免 `Gpt-4.5` 变成 `Gpt 4 5`。
    static func titleCasedModelId(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "/", with: " ")
        let collapsed = normalized
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.capitalized
    }
}

/// 技能包配置
struct SkillPackage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var description: String
    var version: String
    var isEnabled: Bool = true
    /// 技能在 skills/ 下的目录名（用于删除/查看正文，不在 UI 展示）
    var directoryName: String = ""
    /// 来源：`builtin`（App 内置）/ `imported`（本地导入）
    var source: String = "imported"
    /// 安装/首次记录时间
    var installDate: Date = Date()
}

/// 远端 MCP 服务配置。Bearer 令牌 只存入 Keychain，永不编码进此模型。
struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var endpointURL: String
    var transport: MCPTransport
    var isEnabled: Bool
    var hasBearerToken: Bool
    /// 自定义请求头（如 X-API-Key）。随每次请求发送；协议保留头由系统托管，此处设置会被忽略。
    /// 值支持 `${VAR}` / `$VAR` 展开（见 envVars / 全局环境变量）。
    var customHeaders: [String: String]
    /// 环境变量密钥（如 API_KEY）。仅在本地配置；发送请求时展开进 URL 与自定义请求头。
    /// 建议机密写在全局「环境变量」里，本字段只放 `${VAR}` 引用，避免明文落盘。
    var envVars: [String: String]
    /// STDIO 传输启动命令（仅 transport == .stdio 时生效）。
    var command: String
    /// STDIO 传输启动参数（空格分隔；展开 ${VAR} 后按空白切分）。
    var args: String
    var lastStatus: MCPServerStatus
    var lastError: String?
    var lastToolCount: Int
    var lastCheckedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        endpointURL: String,
        transport: MCPTransport = .auto,
        isEnabled: Bool = true,
        hasBearerToken: Bool = false,
        customHeaders: [String: String] = [:],
        envVars: [String: String] = [:],
        command: String = "",
        args: String = "",
        lastStatus: MCPServerStatus = .unknown,
        lastError: String? = nil,
        lastToolCount: Int = 0,
        lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.endpointURL = endpointURL
        self.transport = transport
        self.isEnabled = isEnabled
        self.hasBearerToken = hasBearerToken
        self.customHeaders = customHeaders
        self.envVars = envVars
        self.command = command
        self.args = args
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.lastToolCount = lastToolCount
        self.lastCheckedAt = lastCheckedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpointURL, transport, isEnabled, hasBearerToken, customHeaders
        case envVars, command, args
        case lastStatus, lastError, lastToolCount, lastCheckedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "MCP Server"
        endpointURL = try values.decodeIfPresent(String.self, forKey: .endpointURL) ?? ""
        transport = try values.decodeIfPresent(MCPTransport.self, forKey: .transport) ?? .auto
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        hasBearerToken = try values.decodeIfPresent(Bool.self, forKey: .hasBearerToken) ?? false
        customHeaders = try values.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        envVars = try values.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try values.decodeIfPresent(String.self, forKey: .args) ?? ""
        lastStatus = try values.decodeIfPresent(MCPServerStatus.self, forKey: .lastStatus) ?? .unknown
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        lastToolCount = try values.decodeIfPresent(Int.self, forKey: .lastToolCount) ?? 0
        lastCheckedAt = try values.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }
}

enum MCPTransport: String, Codable, CaseIterable, Sendable {
    case auto
    case http
    case legacySSE
    case stdio
}

enum MCPServerStatus: String, Codable, Sendable {
    case unknown
    case connecting
    case connected
    case failed
}

/// 环境变量
struct EnvVariable: Identifiable, Codable {
    var id: UUID = UUID()
    var key: String
    var value: String
    var isSecret: Bool = false
}

/// 环境变量引用展开（spec 12.2 安全设计：机密仅通过环境变量引用 `$VAR`，
/// 避免把 API Key / Token 明文粘贴进命令或配置）。
/// - 支持 `$VAR` 与 `${VAR}` 两种写法；
/// - `$VAR` 的变量名由「字母/下划线开头 + 字母/数字/下划线」组成；
/// - 未定义的变量保持原样（不吞掉、不报错），便于命令里含普通 `$`。
enum EnvVarStore {
    /// 用给定（或当前）环境变量表展开字符串中的 `$VAR` / `${VAR}` 引用。
    static func expand(_ input: String, using vars: [EnvVariable]? = nil) -> String {
        guard input.contains("$") else { return input }
        let table = vars ?? SettingsStore.shared.settings.envvars
        guard !table.isEmpty else { return input }

        var lookup: [String: String] = [:]
        for v in table where !v.key.isEmpty { lookup[v.key] = v.value }
        guard !lookup.isEmpty else { return input }

        let chars = Array(input)
        var result = ""
        result.reserveCapacity(input.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "$", i + 1 < chars.count {
                // ${VAR}
                if chars[i + 1] == "{",
                   let closeOffset = chars[(i + 2)...].firstIndex(of: "}") {
                    let name = String(chars[(i + 2)..<closeOffset])
                    if let val = lookup[name] {
                        result += val
                        i = closeOffset + 1
                        continue
                    }
                }
                // $VAR
                let next = chars[i + 1]
                if next.isLetter || next == "_" {
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                        j += 1
                    }
                    let name = String(chars[(i + 1)..<j])
                    if let val = lookup[name] {
                        result += val
                        i = j
                        continue
                    }
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    /// 是否包含至少一个「可展开」的已定义变量引用（用于 UI 提示 / 契约说明）。
    static func containsReference(_ input: String, using vars: [EnvVariable]? = nil) -> Bool {
        expand(input, using: vars) != input
    }

    /// 当前已配置的环境变量表（key -> value），用于**真实注入进程环境**
    /// （而非字符串替换）。iSH 子进程（/bin/sh 及其后续 fork 的整条进程树）将
    /// 通过 getenv / os.environ / process.env 等读取到这些值。
    /// 参数版从传入快照构造（后台线程用，2026-08-13 竞争修复）。
    static func environmentDictionary(using vars: [EnvVariable]) -> [String: String] {
        var dict: [String: String] = [:]
        for v in vars where !v.key.isEmpty {
            dict[v.key] = v.value
        }
        return dict
    }

    /// 主线程便捷入口：直接读 SettingsStore（仅主线程调用）。
    static var environmentDictionary: [String: String] {
        environmentDictionary(using: SettingsStore.shared.settings.envvars)
    }
}

/// 同步配置
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
struct MountPoint: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    /// 虚拟路径，形如 `/var/MiniClaw/mounts/<name>`
    var path: String
    /// 外部文件夹真实路径（仅用于 UI 展示；bookmark 解析失败时的兜底显示）
    var externalPath: String? = nil
    /// security-scoped bookmark，持久化对外部文件夹的访问授权（跨重启有效）
    var bookmark: Data? = nil
    /// 是否允许 Agent 写入该挂载（默认 false = 只读，安全；需在设置中显式开启）。
    /// 旧字段名为 isReadOnly，改名是为了语义清晰且新默认值 false 对老数据同样安全（不写）。
    var isWritable: Bool = false
    var isMounted: Bool = false
}

/// 权限配置
struct PermissionConfig: Codable {
    /// 是否允许 miniclaw-config（Agent Tool / CLI）写入配置 — 对齐 spec 9.2.9 / 9.5
    var miniclawConfigWrite: Bool = false
    var location: PermissionState = .notDetermined
    var bluetooth: PermissionState = .notDetermined
    var microphone: PermissionState = .notDetermined
    var speechRecognition: PermissionState = .notDetermined
    var camera: PermissionState = .notDetermined
    var photoLibrary: PermissionState = .notDetermined
    var notifications: PermissionState = .notDetermined
    var calendar: PermissionState = .notDetermined
    var reminders: PermissionState = .notDetermined
    var healthKit: PermissionState = .notDetermined
    var homeKit: PermissionState = .notDetermined
    var nfc: PermissionState = .notDetermined
    var localNetwork: PermissionState = .notDetermined
    /// 蜂窝数据访问状态（读取自 CTCellularData；iOS 无公网联网授权弹窗，
    /// 此项反映用户在「设置 → 蜂窝网络」中对本 app 的开关）
    var cellularData: PermissionState = .notDetermined
}

enum PermissionState: String, Codable {
    case notDetermined = "未授权"
    case authorized = "已授权"
    case denied = "已拒绝"
    case restricted = "受限"

    /// 显示标签(英文 key,经 L10n.l 查表);rawValue 保持中文以兼容 Codable 持久化。
    var label: String {
        switch self {
        case .notDetermined: "permission_not_determined"
        case .authorized: "permission_authorized"
        case .denied: "permission_denied"
        case .restricted: "permission_restricted"
        }
    }
}

// MARK: - 统一配置域（对齐 spec 9.1：Swift 原生配置存储）

/// 模型组中的精确模型条目。
/// [ModelEntry 重构] 使用 compositeKey("{providerId}/{modelId}") 替代 providerId+modelConfigId(UUID)。
/// compositeKey 跨设备稳定，为 iCloud 同步奠定基础。对齐 ModelGroup.memberEntryIds。
struct ModelGroupEntry: Codable, Equatable, Hashable, Identifiable {
    /// compositeKey = "{providerInstanceId}/{modelId}"，与 ModelEntry.compositeKey 一致。
    var compositeKey: String

    /// 用于 ForEach($entries) 绑定重排。
    var id: String { compositeKey }
}

/// 模型组（groups）
struct ModelGroup: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var modelIds: [String] = []   // 旧版兼容字段；新数据使用 entries
    var entries: [ModelGroupEntry] = []
    /// 路由策略：fallback（按序尝试）/ loadBalance（分发）— 对齐 spec 9.2.2
    var strategy: String = "fallback"
    /// 降级策略：limited（仅 provider 拒绝时）/ always（短暂错误也降级）— 对齐 spec 9.2.2
    var fallbackStrategy: String = "limited"
    /// 上下文上限（词元），0 = 使用模型原生窗口 — 对齐 spec 9.2.2
    var contextLimitTokens: Int = 0
    /// 默认思考等级：off/low/medium/high/xhigh/max/ultra — 对齐 spec 9.2.2
    var defaultThinkingLevel: String = "off"

    private enum CodingKeys: String, CodingKey {
        case id, name, modelIds, entries, strategy, fallbackStrategy, contextLimitTokens, defaultThinkingLevel
    }

    init(
        id: UUID = UUID(),
        name: String,
        modelIds: [String] = [],
        entries: [ModelGroupEntry] = [],
        strategy: String = "fallback",
        fallbackStrategy: String = "limited",
        contextLimitTokens: Int = 0,
        defaultThinkingLevel: String = "off"
    ) {
        self.id = id
        self.name = name
        self.modelIds = modelIds
        self.entries = entries
        self.strategy = strategy
        self.fallbackStrategy = fallbackStrategy
        self.contextLimitTokens = contextLimitTokens
        self.defaultThinkingLevel = defaultThinkingLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        modelIds = try container.decodeIfPresent([String].self, forKey: .modelIds) ?? []
        entries = try container.decodeIfPresent([ModelGroupEntry].self, forKey: .entries) ?? []
        strategy = try container.decodeIfPresent(String.self, forKey: .strategy) ?? "fallback"
        fallbackStrategy = try container.decodeIfPresent(String.self, forKey: .fallbackStrategy) ?? "limited"
        contextLimitTokens = try container.decodeIfPresent(Int.self, forKey: .contextLimitTokens) ?? 0
        defaultThinkingLevel = try container.decodeIfPresent(String.self, forKey: .defaultThinkingLevel) ?? "off"
    }
}

/// 模型槽位选择：主/副/语音输入/语音输出可指向"模型组"或"单个模型"，也可不指定。
/// [ModelEntry 重构] 单模型用 compositeKey("{providerId}/{modelId}") 定位，跨设备稳定。
/// 对齐 SessionModelSource（directEntry + group）。
enum ModelSelection: Codable, Equatable, Hashable {
    case none
    case group(id: UUID)
    case model(compositeKey: String)

    private enum CodingKeys: String, CodingKey {
        case kind, groupId, compositeKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "none"
        switch kind {
        case "group":
            if let id = try container.decodeIfPresent(UUID.self, forKey: .groupId) {
                self = .group(id: id)
            } else {
                self = .none
            }
        case "model":
            if let key = try container.decodeIfPresent(String.self, forKey: .compositeKey) {
                self = .model(compositeKey: key)
            } else {
                self = .none
            }
        default:
            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .kind)
        case .group(let id):
            try container.encode("group", forKey: .kind)
            try container.encode(id, forKey: .groupId)
        case .model(let compositeKey):
            try container.encode("model", forKey: .kind)
            try container.encode(compositeKey, forKey: .compositeKey)
        }
    }

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    /// 指向的模型组 ID（仅 .group 时非 nil）。
    var groupId: UUID? {
        if case .group(let id) = self { return id }
        return nil
    }
}

/// 会话默认设置（session）
struct SessionSettings: Codable, Equatable {
    var autoGenerateTitle: Bool = true
    var defaultModelId: String = ""
    var maxContextMessages: Int = 50
    var streamResponses: Bool = true
    /// 模型槽位分配：可选模型组或单个模型；.none 表示"无"。
    /// 解码兼容旧版 settings.json 的 mainModelGroupId 等 UUID 字段（自动迁移为 .group）。
    var mainModel: ModelSelection = .none
    var secondaryModel: ModelSelection = .none
    var speechInputModel: ModelSelection = .none
    var speechOutputModel: ModelSelection = .none

    // MARK: 模型采样参数（nil = 不设置，使用 API 默认值）

    /// 核采样（0…2），nil = 不发送
    var topP: Double?
    /// 重复惩罚（-2…2），nil = 不发送
    var frequencyPenalty: Double?
    /// 话题多样性惩罚（-2…2），nil = 不发送
    var presencePenalty: Double?
    /// 确定性种子（可复现输出），nil = 不发送
    var seed: Int?
    /// 是否允许并行工具调用，nil = 不发送（API 默认 true）
    var parallelToolCalls: Bool?
    /// 输出模式："text" / "json_object" / "json_schema"
    var responseFormat: String = "text"

    private enum CodingKeys: String, CodingKey {
        case autoGenerateTitle, defaultModelId, maxContextMessages, streamResponses
        case mainModel, secondaryModel, speechInputModel, speechOutputModel
        // 旧版字段（仅解码迁移用）
        case mainModelGroupId, secondaryModelGroupId, speechInputGroupId, speechOutputGroupId
        case topP, frequencyPenalty, presencePenalty, seed, parallelToolCalls, responseFormat
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoGenerateTitle = try c.decodeIfPresent(Bool.self, forKey: .autoGenerateTitle) ?? true
        defaultModelId = try c.decodeIfPresent(String.self, forKey: .defaultModelId) ?? ""
        maxContextMessages = try c.decodeIfPresent(Int.self, forKey: .maxContextMessages) ?? 50
        streamResponses = try c.decodeIfPresent(Bool.self, forKey: .streamResponses) ?? true

        /// 新字段优先；缺失时回读旧版 UUID 字段并迁移为 .group。
        func migrate(_ newKey: CodingKeys, _ legacyKey: CodingKeys) -> ModelSelection {
            if let sel = try? c.decodeIfPresent(ModelSelection.self, forKey: newKey) {
                return sel
            }
            if let legacyId = try? c.decodeIfPresent(UUID.self, forKey: legacyKey) {
                return .group(id: legacyId)
            }
            return .none
        }
        mainModel = migrate(.mainModel, .mainModelGroupId)
        secondaryModel = migrate(.secondaryModel, .secondaryModelGroupId)
        speechInputModel = migrate(.speechInputModel, .speechInputGroupId)
        speechOutputModel = migrate(.speechOutputModel, .speechOutputGroupId)
        // 无旧数据兼容：缺 key 直接解码失败（需删 App + 清 Derived Data 重装）。

        topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        frequencyPenalty = try c.decodeIfPresent(Double.self, forKey: .frequencyPenalty)
        presencePenalty = try c.decodeIfPresent(Double.self, forKey: .presencePenalty)
        seed = try c.decodeIfPresent(Int.self, forKey: .seed)
        parallelToolCalls = try c.decodeIfPresent(Bool.self, forKey: .parallelToolCalls)
        responseFormat = try c.decodeIfPresent(String.self, forKey: .responseFormat) ?? "text"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(autoGenerateTitle, forKey: .autoGenerateTitle)
        try c.encode(defaultModelId, forKey: .defaultModelId)
        try c.encode(maxContextMessages, forKey: .maxContextMessages)
        try c.encode(streamResponses, forKey: .streamResponses)
        try c.encode(mainModel, forKey: .mainModel)
        try c.encode(secondaryModel, forKey: .secondaryModel)
        try c.encode(speechInputModel, forKey: .speechInputModel)
        try c.encode(speechOutputModel, forKey: .speechOutputModel)
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encodeIfPresent(frequencyPenalty, forKey: .frequencyPenalty)
        try c.encodeIfPresent(presencePenalty, forKey: .presencePenalty)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encodeIfPresent(parallelToolCalls, forKey: .parallelToolCalls)
        try c.encode(responseFormat, forKey: .responseFormat)
    }
}

/// 聊天 UI 设置（chat）
struct ChatSettings: Codable, Equatable {
    // 2026-08-09 字体适配：移除 fontSize 设置，统一跟随系统动态字体（body 17pt 基准）。
    var showThinking: Bool = true
    var codeBlockTheme: String = "auto"
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
    /// bing / sogou / so360 / baidu / google / duckduckgo，默认 bing。
    var searchEngine: String = "bing"

    enum CodingKeys: String, CodingKey {
        case maxTabs, uaMode, userAgent, blockPopups, defaultHomeURL, searchEngine
    }

    /// 全字段 decodeIfPresent + 默认值兜底：新增字段缺键（旧数据）不整体失败丢其它设置。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxTabs = try c.decodeIfPresent(Int.self, forKey: .maxTabs) ?? 3
        uaMode = try c.decodeIfPresent(String.self, forKey: .uaMode) ?? "mobile"
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
        blockPopups = try c.decodeIfPresent(Bool.self, forKey: .blockPopups) ?? true
        defaultHomeURL = try c.decodeIfPresent(String.self, forKey: .defaultHomeURL) ?? "https://www.apple.com"
        searchEngine = try c.decodeIfPresent(String.self, forKey: .searchEngine) ?? "bing"
    }

    init() {}
}

/// 外观设置（appearance）
struct AppearanceSettings: Codable {
    var colorSchemeRaw: String = "system"   // system / dark / light
    var useLargeText: Bool = false
    var accentColorRaw: String = "blue"
    var appLanguageRaw: String = "auto"     // auto / zh-Hans / en / ja / ko
}

/// 后台设置（background）
struct BackgroundSettings: Codable, Equatable {
    /// 后台运行：开启后运用灵动岛 / Live Activity 显示任务进度，并用模糊定位保持 App 在后台运行。
    var backgroundRun: Bool = true
    /// 实时活动：开启后对接 Live Activity（灵动岛 / 锁屏）渲染。
    var liveActivity: Bool = true
    /// 画中画：开启后退出会话页即以画中画常驻显示运行中的任务（图标 / 会话标题 / 执行进度）。
    var pictureInPicture: Bool = false
    /// 通知：仅当系统已授权通知时作为开关生效；未授权时 UI 显示「未授权」并引导授权。
    var notifications: Bool = false
}

/// 文件设置（files）
struct FileSettings: Codable, Equatable {
    var defaultWorkspace: String = "workspace"
    var autoOffloadThresholdKB: Int = 8
    var cleanupAttachmentsDays: Int = 30
}

/// 默认值设置（defaults）
struct DefaultSettings: Codable, Equatable {
    var defaultAgentName: String = "MiniClaw"
    var defaultLanguage: String = "auto"
    var confirmBeforeToolCall: Bool = false
}

/// 统一配置聚合：除 providers 外的 13 个配置域。
/// providers 由 ProviderFileStore 独立持久化（同属「Swift 原生配置存储」框），暂不并入以避免回归。
struct AppSettings: Codable {
    /// 全默认构造（自定义 init(from:) 会挤掉自动生成的无参 init，此处显式补回）。
    init() {}

    var groups: [ModelGroup] = []
    var envvars: [EnvVariable] = []
    /// 环境变量隐私模式：开启后 shell/记忆输出中的变量值自动掩码 — 对齐 spec 9.2.4
    var envvarsPrivacyMode: Bool = false
    var soul: SoulConfig = SoulConfig()
    var session: SessionSettings = SessionSettings()
    var chat: ChatSettings = ChatSettings()
    var speech: SpeechSettings = SpeechSettings()
    var memory: MemorySettings = MemorySettings()
    var browser: BrowserSettings = BrowserSettings()
    var appearance: AppearanceSettings = AppearanceSettings()
    var background: BackgroundSettings = BackgroundSettings()
    var files: FileSettings = FileSettings()
    var permissions: PermissionConfig = PermissionConfig()
    var defaults: DefaultSettings = DefaultSettings()
    var sync: SyncConfig = SyncConfig()
    /// 子代理用户控制（设置 → 智能体 → 子代理）。
    var subagent: SubAgentSettings = SubAgentSettings()
    /// 技能启用状态：`true`=启用（注入 system prompt），`false`=禁用。
    /// 键为技能 frontmatter 的 name；缺失视为启用（技能格式无启用概念，默认全启用）。
    var skillEnabledStates: [String: Bool] = [:]
    /// 技能安装时间（首次被记录的时间戳），键为技能 name。内置技能在首次加载时记录。
    var skillInstallDates: [String: Date] = [:]
    /// 技能调用次数（键为技能 frontmatter 的 name），用于斜杠命令菜单按调用热度排序。
    var skillUseCounts: [String: Int] = [:]
    /// 词元 用量统计（跨会话全局累计，可选以兼容旧 settings.json）。
    var tokenUsage: TokenUsageStats?
    /// 按会话累计的 词元 用量（键为 sessionID 的 uuidString），可选以兼容旧 settings.json。
    var sessionTokenUsage: [String: SessionTokenUsageData]? = nil

    /// 容错解码（源头修复，2026-08-05）：合成解码对**缺键的非 Optional 字段**直接抛
    /// keyNotFound → 旧版 settings.json（无 subagent 等后加字段）整体解码失败 →
    /// SettingsStore 静默回退全默认 → 用户全部已有设置被重置且被默认值覆盖落盘。
    /// 全部字段 decodeIfPresent + 默认值兜底；未来新增字段必须同步进此 init
    /// （编译器会因未覆盖的存储属性而报错，天然防漏）。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([ModelGroup].self, forKey: .groups) ?? []
        envvars = try c.decodeIfPresent([EnvVariable].self, forKey: .envvars) ?? []
        envvarsPrivacyMode = try c.decodeIfPresent(Bool.self, forKey: .envvarsPrivacyMode) ?? false
        soul = try c.decodeIfPresent(SoulConfig.self, forKey: .soul) ?? SoulConfig()
        session = try c.decodeIfPresent(SessionSettings.self, forKey: .session) ?? SessionSettings()
        chat = try c.decodeIfPresent(ChatSettings.self, forKey: .chat) ?? ChatSettings()
        speech = try c.decodeIfPresent(SpeechSettings.self, forKey: .speech) ?? SpeechSettings()
        memory = try c.decodeIfPresent(MemorySettings.self, forKey: .memory) ?? MemorySettings()
        browser = try c.decodeIfPresent(BrowserSettings.self, forKey: .browser) ?? BrowserSettings()
        appearance = try c.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? AppearanceSettings()
        background = try c.decodeIfPresent(BackgroundSettings.self, forKey: .background) ?? BackgroundSettings()
        files = try c.decodeIfPresent(FileSettings.self, forKey: .files) ?? FileSettings()
        permissions = try c.decodeIfPresent(PermissionConfig.self, forKey: .permissions) ?? PermissionConfig()
        defaults = try c.decodeIfPresent(DefaultSettings.self, forKey: .defaults) ?? DefaultSettings()
        sync = try c.decodeIfPresent(SyncConfig.self, forKey: .sync) ?? SyncConfig()
        subagent = try c.decodeIfPresent(SubAgentSettings.self, forKey: .subagent) ?? SubAgentSettings()
        skillEnabledStates = try c.decodeIfPresent([String: Bool].self, forKey: .skillEnabledStates) ?? [:]
        skillInstallDates = try c.decodeIfPresent([String: Date].self, forKey: .skillInstallDates) ?? [:]
        skillUseCounts = try c.decodeIfPresent([String: Int].self, forKey: .skillUseCounts) ?? [:]
        tokenUsage = try c.decodeIfPresent(TokenUsageStats.self, forKey: .tokenUsage)
        sessionTokenUsage = try c.decodeIfPresent([String: SessionTokenUsageData].self, forKey: .sessionTokenUsage)
    }
}

/// 子代理（subagent）用户控制配置。
struct SubAgentSettings: Codable {
    /// 总开关：false=禁用（引擎不注入 dispatch_subagent 工具，
    /// 引导段明确告知模型「子代理已被用户关闭」）。
    var enabled: Bool = true
    /// 最大并发子代理（1-4，默认 4；与引擎全局上限一致）。
    var maxConcurrent: Int = 4
    /// 子代理思考档位（参考 reasonix subagent_effort 思路）：
    /// `follow`=跟随模型默认（不强制） / `off`=关闭思考 / `low`=低 / `high`=高。
    var thinking: String = "follow"
}

/// 配置域标识，用于审计日志定位与回滚
enum SettingsDomain: String, CaseIterable, Codable {
    case groups, envvars, soul, session, chat, speech, memory, browser, appearance, background, files, permissions, defaults, sync, subagent
}
