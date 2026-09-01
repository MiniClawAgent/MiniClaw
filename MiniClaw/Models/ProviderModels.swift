import Foundation

struct SoulConfig: Codable {
    ///     /// 并与 SOUL.md 种子文件、appState.agentName 对齐（见 SettingsStore 迁移兜底）。
    var name: String = "MiniClaw"
    var style: String = ""
    /// 响应语言：auto / zh / en — 对齐 spec 9.2.3
    var lang: String = "auto"
    var body: String = ""
    /// 当前生效的 soul 插件（manifest.name）：nil = 内置灵魂生效；
    /// 非 nil = 该第三方 soul 插件生效（memory/SOUL.md 由其提供，内置草稿 SOUL.builtin.md 暂存用户修改）。
    var activePlugin: String? = nil
}

/// model 插件包 providers.json 的宽松声明结构（外部 JSON 铁律：全字段 decodeIfPresent）。
/// 供 AppState 幂等合并与 AddProviderView 模板列表共用。
struct ModelPluginProviderDecl: Codable {
    var label: String = ""
    var providerType: String? = nil
    var customBaseURL: String? = nil
    var apiFormat: String? = nil
    var appendV1Suffix: Bool? = nil
    var organizationId: String? = nil
    var projectId: String? = nil
    var customUserAgent: String? = nil
    var customHeaders: [String: String]? = nil
    var models: [ModelPluginModelDecl]? = nil
}

struct ModelPluginModelDecl: Codable {
    var modelId: String = ""
    var displayName: String? = nil
    var contextLimit: Int? = nil
    var deepThinking: Bool? = nil
    var maxOutputTokens: Int? = nil
    var inputText: Bool? = nil
    var inputImage: Bool? = nil
    var inputAudio: Bool? = nil
    var inputVideo: Bool? = nil
    var outputText: Bool? = nil
    var outputImage: Bool? = nil
    var outputAudio: Bool? = nil
    /// 以下资料字段自 2026-09-01 起由 model 插件包承载（原嵌在厂商适配器
    /// builtinModels 中；适配器已瘦身仅保留请求行为）。
    /// 支持的 API 格式（如 ["chat/completions", "responses", "anthropic"]）。
    var apiFormats: [String]? = nil
    /// 模型级是否支持 Responses API。
    var responsesSupported: Bool? = nil
    /// 特殊参数约束（思考模式禁用参数、回传要求等，文本说明）。
    var specialConstraints: String? = nil
    /// 定价说明（每百万 token，官网公布时填写）。
    var pricing: String? = nil
}

extension ProviderType {
    /// model 插件包内 providerType 字段的宽容映射（小写 id 优先，兼容清单 rawValue）。
    init?(flexibleID raw: String?) {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "openai": self = .openai
        case "anthropic": self = .anthropic
        case "google", "gemini": self = .google
        case "openrouter": self = .openRouter
        case "custom", "openai-compatible", "openai兼容": self = .custom
        case "grok": self = .grok
        case "deepseek": self = .deepSeek
        case "qwen": self = .qwen
        case "xiaomi": self = .xiaomi
        case "zhipu": self = .zhipu
        default:
            guard let v = ProviderType(rawValue: raw) else { return nil }
            self = v
        }
    }
}

extension APIFormat {
    /// model 插件包内 apiFormat 字段的宽容映射。
    init?(flexibleID raw: String?) {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "chatcompletions", "chat/completions": self = .chatCompletions
        case "responsesapi", "responses": self = .responsesAPI
        default:
            guard let v = APIFormat(rawValue: raw) else { return nil }
            self = v
        }
    }
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
    /// 来源插件（manifest.id）：由 model 配置包导入的供应商记录来源，
    /// 删除该插件时连带删除其导入的供应商；手动添加的为 nil。
    var sourcePlugin: String? = nil

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
        case sourcePlugin
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
        sourcePlugin = try container.decodeIfPresent(String.self, forKey: .sourcePlugin)
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
        try container.encodeIfPresent(sourcePlugin, forKey: .sourcePlugin)
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
        case .custom: return L10n.l("provider_kind_custom")
        case .grok: return "xAI Grok"
        case .deepSeek: return "DeepSeek"
        case .qwen: return L10n.l("provider_qwen")
        case .xiaomi: return "Xiaomi MiMo"
        case .zhipu: return L10n.l("provider_zhipu")
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
                                    note: L10n.l("embed_note_openrouter"))
        case .qwen:
            return EmbeddingSupport(openAICompatPath: "embeddings",
                                    models: ["text-embedding-v4", "text-embedding-v3"],
                                    note: L10n.l("embed_note_bailian"))
        case .zhipu:
            return EmbeddingSupport(openAICompatPath: "embeddings",
                                    models: ["embedding-3"],
                                    note: L10n.l("embed_note_zhipu"))
        case .google:
            return EmbeddingSupport(openAICompatPath: nil,
                                    models: ["embedding-001"],
                                    note: L10n.l("embed_note_gemini"))
        case .grok:
            return EmbeddingSupport(openAICompatPath: nil,
                                    models: [],
                                    note: L10n.l("embed_note_unknown"))
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
    /// 技能在 skills/ 下的目录名（即插件 id，用于删除/查看正文，不在 UI 展示）
    var directoryName: String = ""
    /// 来源：`builtin`（App 内置）/ `imported`（本地导入）
    var source: String = "imported"
    /// 安装/首次记录时间
    var installDate: Date = Date()
    /// 插件图标（SF Symbols 名）；空字符串时由 category 取默认图标
    var icon: String = ""
    /// 插件分类（用于默认图标与分组展示）
    var category: String = "skill"
    /// 插件类型（对应 plugin.json 的 type）
    var type: String = "skill"
}

/// 远端 MCP 服务配置。Bearer 令牌 只存入 Keychain，永不编码进此模型。
