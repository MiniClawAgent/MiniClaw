import Foundation

// MARK: - ModelOverrides

/// 用户对模型的编辑覆盖。跨 API 刷新保留（baseModel 被覆盖，overrides 不被覆盖）。
/// 对齐 ModelOverrides 设计。
struct ModelOverrides: Codable, Equatable, Hashable {
    /// 用户自定义显示名（nil = 使用 baseModel.displayName）
    var displayName: String?
    /// 用户自定义上下文窗口（nil = 使用 baseModel.contextLimit）
    var contextLimit: Int?
    /// 用户自定义深度思考开关（nil = 使用 baseModel.deepThinking）
    var deepThinking: Bool?
    /// 用户自定义最大输出 词元（nil = 使用 baseModel.maxOutputTokens）
    var maxOutputTokens: Int?
    /// 用户自定义输入模态覆盖
    var inputText: Bool?
    var inputImage: Bool?
    var inputAudio: Bool?
    var inputVideo: Bool?
    /// 用户自定义输出模态覆盖
    var outputText: Bool?
    var outputImage: Bool?
    var outputAudio: Bool?

    var isEmpty: Bool {
        displayName == nil && contextLimit == nil && deepThinking == nil &&
        maxOutputTokens == nil && inputText == nil && inputImage == nil &&
        inputAudio == nil && inputVideo == nil && outputText == nil &&
        outputImage == nil && outputAudio == nil
    }
}

// MARK: - ModelEntry

/// 把一个模型绑定到一个供应商实例。对齐 ModelEntry。
///
/// - `baseModel`：API 报告的元数据，刷新时覆盖。
/// - `overrides`：用户编辑，跨刷新保留。
/// - `compositeKey`：跨设备稳定身份 = "{providerId}/{modelId}"。
/// - `model`：计算属性，合并 baseModel + overrides，UI 代码读这个。
///
/// MiniClaw 未上线，无需旧数据兼容。
struct ModelEntry: Identifiable, Codable, Equatable, Hashable {
    /// compositeKey = "{providerInstanceId}/{baseModel.modelId}"
    var id: String { compositeKey }
    var compositeKey: String { "\(providerInstanceId)/\(baseModel.modelId)" }
    let providerInstanceId: UUID
    /// API 报告的模型元数据。刷新时覆盖。UI 代码请读 `model` 而非直接读 `baseModel`。
    var baseModel: ModelConfig
    /// 用户编辑覆盖。跨刷新保留。
    var overrides: ModelOverrides
    var isCustom: Bool
    var isHidden: Bool
    /// 用户最近修改时间（用于 iCloud 同步的 last-write-wins 冲突解决）。
    var userModifiedAt: Date?

    /// 有效模型视图：baseModel + overrides 合并。
    var model: ModelConfig {
        guard !overrides.isEmpty else { return baseModel }
        var m = baseModel
        if let v = overrides.displayName { m.displayName = v }
        if let v = overrides.contextLimit { m.contextLimit = v }
        if let v = overrides.deepThinking { m.deepThinking = v }
        if let v = overrides.maxOutputTokens { m.maxOutputTokens = v }
        if let v = overrides.inputText { m.inputText = v }
        if let v = overrides.inputImage { m.inputImage = v }
        if let v = overrides.inputAudio { m.inputAudio = v }
        if let v = overrides.inputVideo { m.inputVideo = v }
        if let v = overrides.outputText { m.outputText = v }
        if let v = overrides.outputImage { m.outputImage = v }
        if let v = overrides.outputAudio { m.outputAudio = v }
        return m
    }

    /// 是否携带用户修改（用于判断是否需要同步）。
    var isUserModified: Bool {
        isCustom || isHidden || !overrides.isEmpty
    }

    init(
        providerInstanceId: UUID,
        model: ModelConfig,
        overrides: ModelOverrides = ModelOverrides(),
        isCustom: Bool = false,
        isHidden: Bool = false,
        userModifiedAt: Date? = nil
    ) {
        self.providerInstanceId = providerInstanceId
        self.baseModel = model
        self.overrides = overrides
        self.isCustom = isCustom
        self.isHidden = isHidden
        self.userModifiedAt = userModifiedAt
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case providerInstanceId, baseModel, overrides, isCustom, isHidden, userModifiedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerInstanceId = try c.decode(UUID.self, forKey: .providerInstanceId)
        baseModel = try c.decode(ModelConfig.self, forKey: .baseModel)
        overrides = try c.decodeIfPresent(ModelOverrides.self, forKey: .overrides) ?? ModelOverrides()
        isCustom = try c.decode(Bool.self, forKey: .isCustom)
        isHidden = try c.decode(Bool.self, forKey: .isHidden)
        userModifiedAt = try c.decodeIfPresent(Date.self, forKey: .userModifiedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(providerInstanceId, forKey: .providerInstanceId)
        try c.encode(baseModel, forKey: .baseModel)
        if !overrides.isEmpty {
            try c.encode(overrides, forKey: .overrides)
        }
        try c.encode(isCustom, forKey: .isCustom)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encodeIfPresent(userModifiedAt, forKey: .userModifiedAt)
    }
}
