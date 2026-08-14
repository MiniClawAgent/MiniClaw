import Foundation

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
