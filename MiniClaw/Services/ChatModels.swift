import Foundation

// [2026-09-13 重构·删除零引用死簇] 此处原有 `LLMMessage` / `ContentType` / `MultimodalPart`
//（含 `ImageURL` / `InputAudio`）整套多模态消息体；全库引用数 = 1（仅定义处），属历史残留。
// 线上正在使用的是**更完整、更贴协议**的一份：`ChatCompletionMessage` + `MessageContent` +
// `ContentPart`（含 `.file` 的扁平 file_id/file_data 编码、空 payload 守卫、旧嵌套形状兼容，
// 以及 toolCalls / tool_call_id / reasoning_content / volatileSuffix）。
// 旧版是它的**严格子集**（缺 file / tools / reasoning）⇒ 按「同一功能只留更好的一份」删除。

// MARK: - API Request/Response

// MARK: - 请求体辅助类型

/// 停止词（string | [string]）
enum StopValue: Codable {
    case single(String)
    case multiple([String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let s): try container.encode(s)
        case .multiple(let a): try container.encode(a)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .single(s) }
        else { self = .multiple(try container.decode([String].self)) }
    }
}

/// 结构化输出 / JSON 模式
struct ResponseFormat: Codable {
    var type: String
    var jsonSchema: JSONSchemaDef?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    static let text = ResponseFormat(type: "text")
    static let jsonObject = ResponseFormat(type: "json_object")
    static func jsonSchema(name: String, description: String? = nil, schema: JSONSchemaValue, strict: Bool? = nil) -> ResponseFormat {
        ResponseFormat(type: "json_schema", jsonSchema: JSONSchemaDef(name: name, description: description, schema: schema, strict: strict))
    }

    struct JSONSchemaDef: Codable {
        var name: String
        var description: String?
        var schema: JSONSchemaValue
        var strict: Bool?
    }
}

/// 预测输出（降低首 词元 延迟）
struct PredictionConfig: Codable {
    var type: String
    var content: PredictionContent?

    enum CodingKeys: String, CodingKey {
        case type, content
    }

    struct PredictionContent: Codable {
        var text: String?
        var parts: [PredictionPart]?

        struct PredictionPart: Codable {
            var type: String
            var text: String
        }
    }
}

/// 音频输出配置
struct AudioOutputConfig: Codable {
    var voice: String
    var format: String
}

// MARK: - ChatCompletionRequest

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatCompletionMessage]
    var stream: Bool = true
    var tools: [ToolSchema]?
    var toolChoice: String?
    var temperature: Double?
    var maxTokens: Int?
    var reasoningEffort: String?
    var streamOptions: StreamOptions? = StreamOptions()

    // ——— 新增 OpenAI 完整参数（全可选，按需填入）———

    /// 核采样（0…2），与 temperature 二选一
    var topP: Double?
    /// 重复惩罚（-2…2），正值抑制重复、负值鼓励重复
    var frequencyPenalty: Double?
    /// 话题多样性惩罚（-2…2），正值鼓励切换话题
    var presencePenalty: Double?
    /// 确定性种子（可复现输出）
    var seed: Int?
    /// 停止词（字符串或数组）
    var stop: StopValue?
    /// 候选数（流式通常 =1）
    var n: Int?
    /// 终端用户标识（OpenAI 用于滥用监控）
    var user: String?
    /// 结构化输出格式
    var responseFormat: ResponseFormat?
    /// 是否允许并行工具调用
    var parallelToolCalls: Bool?
    /// o 系列推荐替代 max_tokens；优先于 maxTokens 发出
    var maxCompletionTokens: Int?
    /// 处理优先级层：auto / default / flex / scale / priority
    var serviceTier: String?
    /// 是否服务端存储补全记录
    var store: Bool?
    /// 存储补全时的附加元数据（最多 16 对）
    var metadata: [String: String]?
    /// 预测输出配置（降低延迟）
    var prediction: PredictionConfig?
    /// 返回 词元 对数概率
    var logprobs: Bool?
    /// 返回最可能的 top_logprobs 个 token
    var topLogprobs: Int?
    /// 输出模态 list
    var modalities: [String]?
    /// 语音输出配置
    var audio: AudioOutputConfig?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools, temperature
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
        case streamOptions = "stream_options"
        case topP = "top_p"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case seed, stop, n, user
        case responseFormat = "response_format"
        case parallelToolCalls = "parallel_tool_calls"
        case maxCompletionTokens = "max_completion_tokens"
        case serviceTier = "service_tier"
        case store, metadata, prediction, logprobs
        case topLogprobs = "top_logprobs"
        case modalities, audio
    }

    /// 流式用量上报开关
    struct StreamOptions: Codable {
        var includeUsage: Bool = true
        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }
}

// MARK: - 消息内容类型

/// 消息内容：文本字符串 或 多模态部件数组
enum MessageContent: Codable {
    case text(String)
    case parts([ContentPart])

    /// 提取纯文本（多模态时拼接 text 部件）
    var asText: String? {
        switch self {
        case .text(let s): return s
        case .parts(let parts): return parts.compactMap { p in
            if case .text(let t) = p { return t }
            return nil
        }.joined()
        }
    }

    var isEmpty: Bool { (asText ?? "").isEmpty }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .text(s) }
        else { self = .parts(try container.decode([ContentPart].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .parts(let p): try container.encode(p)
        }
    }
}

/// 消息内容部件（图片 / 音频 / 文件 / 文本）
enum ContentPart: Codable {
    case text(String)
    case imageURL(url: String, detail: String)
    case inputAudio(data: String, format: String)
    case file(fileData: String?, fileId: String?, filename: String?)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case inputAudio = "input_audio"
        case file
        // DeepSeek Files API 的引用是**扁平**形状（官方规范，亦见本项目
        // DeepSeekFilesClient 头注释）：`{"type":"file","file_id":"file-api-…"}`。
        // 旧的「嵌在 file 下」写法会被服务商判为「没有 file_id/file_data」→ HTTP 400。
        case fileData = "file_data"
        case fileId = "file_id"
        case filename
    }

    enum ImageCodingKeys: String, CodingKey {
        case url, detail
    }

    enum AudioCodingKeys: String, CodingKey {
        case data, format
    }

    enum FileCodingKeys: String, CodingKey {
        case fileData = "file_data"
        case fileId = "file_id"
        case filename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image_url":
            let nested = try container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .imageURL)
            self = .imageURL(
                url: try nested.decode(String.self, forKey: .url),
                detail: (try? nested.decode(String.self, forKey: .detail)) ?? "auto"
            )
        case "input_audio":
            let nested = try container.nestedContainer(keyedBy: AudioCodingKeys.self, forKey: .inputAudio)
            self = .inputAudio(
                data: try nested.decode(String.self, forKey: .data),
                format: try nested.decode(String.self, forKey: .format)
            )
        case "file":
            // 优先按**扁平**形状解（现行编码 + DeepSeek 官方形状）。
            let flatData = try? container.decode(String.self, forKey: .fileData)
            let flatId = try? container.decode(String.self, forKey: .fileId)
            let flatName = try? container.decode(String.self, forKey: .filename)
            if flatData != nil || flatId != nil {
                self = .file(fileData: flatData, fileId: flatId, filename: flatName)
            } else if let nested = try? container.nestedContainer(keyedBy: FileCodingKeys.self, forKey: .file) {
                // 兼容旧检查点里可能残留的嵌套形状 `{"type":"file","file":{…}}`。
                self = .file(
                    fileData: try? nested.decode(String.self, forKey: .fileData),
                    fileId: try? nested.decode(String.self, forKey: .fileId),
                    filename: try? nested.decode(String.self, forKey: .filename)
                )
            } else {
                self = .file(fileData: nil, fileId: nil, filename: flatName)
            }
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: String(format: String(localized: "err_unknown_content_part"), String(describing: type)))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try container.encode("text", forKey: .type)
            try container.encode(t, forKey: .text)
        case .imageURL(let url, let detail):
            try container.encode("image_url", forKey: .type)
            var nested = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .imageURL)
            try nested.encode(url, forKey: .url)
            try nested.encode(detail, forKey: .detail)
        case .inputAudio(let data, let format):
            try container.encode("input_audio", forKey: .type)
            var nested = container.nestedContainer(keyedBy: AudioCodingKeys.self, forKey: .inputAudio)
            try nested.encode(data, forKey: .data)
            try nested.encode(format, forKey: .format)
        case .file(let fileData, let fileId, let filename):
            // 守卫：两个 payload 都没有时**绝不产出 file 块** —— 服务商对空 file 块直接
            // 400「file must have a file_id or file_data」（2026-09-12 真机实证：
            // 工具图片注入产出空 file 块 → `.messages[6]: file must have a file_id or file_data`）。
            // 退化为文本占位，宁可少一张图也不让整轮请求失败。
            guard fileData?.isEmpty == false || fileId?.isEmpty == false else {
                try container.encode("text", forKey: .type)
                try container.encode(filename ?? "", forKey: .text)
                return
            }
            try container.encode("file", forKey: .type)
            // **扁平**编码（DeepSeek 官方规范）：file_id / file_data 置于顶层。
            // 两条服务商明文规则（2026-09-12 真机各撞过一次）：
            //   ① 没有 file_id 也没有 file_data → 400「file must have a file_id or file_data」；
            //   ② **带 file_id 时不得再带 filename** → 400「file cannot have filename when
            //      file_id is present」。
            // 故：file_id 优先且**只发 file_id**；否则只发 file_data。filename 一律不发 ——
            // 它对本服务商纯属多余字段（我们注入的图名恒为 miniclaw-screenshot.jpg），
            // 而多余字段正是上面两条 400 的来源。
            if let fileId, !fileId.isEmpty {
                try container.encode(fileId, forKey: .fileId)
            } else if let fileData, !fileData.isEmpty {
                try container.encode(fileData, forKey: .fileData)
            }
        }
    }
}

// MARK: - 消息结构

struct ChatCompletionMessage: Codable {
    let role: String
    var content: MessageContent?
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    var name: String?
    /// 思考过程文本。仅 DeepSeek 需要回传(官方硬性要求:带 tools 的后续请求必须回传
    /// reasoning_content,否则 400);其他厂商由适配器基类在构造请求体时剥离。
    var reasoningContent: String?
    /// 易变段（时间戳 / 动态挂载列表等），独立于稳定 system 内容之外携带，
    /// 由 LLMClient 在构造各家请求体时拼到 system 末尾（或不进入缓存前缀的位置）。
    /// 故意不进 CodingKeys —— 它是单次 run 的瞬态数据，绝不序列化进持久化历史。
    var volatileSuffix: String? = nil

    /// 便捷构造：纯文本内容（向后兼容旧调用方）
    init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil, name: String? = nil, reasoningContent: String? = nil) {
        self.role = role
        self.content = content.map { .text($0) }
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.reasoningContent = reasoningContent
    }

    /// 直接以统一 MessageContent 构造（纯文本或多模态部件均可）。
    init(role: String, messageContent: MessageContent?, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil, name: String? = nil, reasoningContent: String? = nil) {
        self.role = role
        self.content = messageContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.reasoningContent = reasoningContent
    }

    /// 多模态内容部件
    init(role: String, contentParts: [ContentPart]?, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil, name: String? = nil) {
        self.role = role
        self.content = contentParts.map { .parts($0) }
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }
}

struct ToolCall: Codable {
    let id: String
    let type: String
    let function: ToolCallFunction

    struct ToolCallFunction: Codable {
        let name: String
        let arguments: String
    }
}

