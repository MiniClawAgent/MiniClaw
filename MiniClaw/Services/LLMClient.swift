import Foundation

// MARK: - LLM Message Models

struct LLMMessage: Codable {
    let role: String
    var content: ContentType

    enum ContentType: Codable {
        case text(String)
        case multimodal([MultimodalPart])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else if let parts = try? container.decode([MultimodalPart].self) {
                self = .multimodal(parts)
            } else {
                self = .text("")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text):
                try container.encode(text)
            case .multimodal(let parts):
                try container.encode(parts)
            }
        }
    }

    struct MultimodalPart: Codable {
        let type: String
        var text: String?
        var imageURL: ImageURL?
        var inputAudio: InputAudio?

        struct ImageURL: Codable {
            let url: String
            var detail: String = "auto"
        }

        struct InputAudio: Codable {
            let data: String
            let format: String
        }
    }
}

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
            let nested = try container.nestedContainer(keyedBy: FileCodingKeys.self, forKey: .file)
            self = .file(
                fileData: try? nested.decode(String.self, forKey: .fileData),
                fileId: try? nested.decode(String.self, forKey: .fileId),
                filename: try? nested.decode(String.self, forKey: .filename)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "未知 ContentPart 类型: \(type)")
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
            try container.encode("file", forKey: .type)
            var nested = container.nestedContainer(keyedBy: FileCodingKeys.self, forKey: .file)
            try nested.encodeIfPresent(fileData, forKey: .fileData)
            try nested.encodeIfPresent(fileId, forKey: .fileId)
            try nested.encodeIfPresent(filename, forKey: .filename)
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

// MARK: - Responses API Request

/// OpenAI Responses API（/v1/responses）请求结构，遵循官方标准
struct ResponsesRequest: Encodable {
    let model: String
    var instructions: String?
    let input: [ResponsesInputItem]
    var stream: Bool = true
    var tools: [ResponsesTool]?
    var maxOutputTokens: Int?
    var reasoning: Reasoning?

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, stream, tools, reasoning
        case maxOutputTokens = "max_output_tokens"
    }

    struct Reasoning: Encodable {
        let effort: String
    }
}

/// Responses API input 内容部件（多模态）。字段名对齐官方 input_text / input_image /
/// input_audio / input_file。image_url 与 file_data 接收 data URI（data:<mime>;base64,...）。
enum ResponsesContentPart: Encodable {
    case inputText(String)
    case inputImage(url: String, detail: String?)
    case inputAudio(data: String, format: String)
    case inputFile(fileData: String?, fileId: String?, filename: String?)

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
        case inputAudio = "input_audio"
        case inputFile = "input_file"
        case url, detail, data, format
        case fileData = "file_data"
        case fileId = "file_id"
        case filename
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let t):
            try c.encode("input_text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .inputImage(let url, let detail):
            try c.encode("input_image", forKey: .type)
            var img: [String: String] = ["url": url]
            if let d = detail { img["detail"] = d }
            try c.encode(img, forKey: .imageURL)
        case .inputAudio(let data, let format):
            try c.encode("input_audio", forKey: .type)
            try c.encode(["data": data, "format": format], forKey: .inputAudio)
        case .inputFile(let fd, let fid, let fn):
            try c.encode("input_file", forKey: .type)
            var f: [String: String?] = [:]
            f["file_data"] = fd
            f["file_id"] = fid
            f["filename"] = fn
            try c.encode(f.compactMapValues { $0 }, forKey: .inputFile)
        }
    }
}

/// Responses API input 项，支持 message / function_call / function_call_output 三种官方类型。
/// message 的 content 可为字符串（纯文本）或部件数组（多模态）。
struct ResponsesInputItem: Encodable {
    let type: String
    var role: String?
    var content: String?
    var contentParts: [ResponsesContentPart]?
    var callId: String?
    var name: String?
    var arguments: String?
    var output: String?

    enum CodingKeys: String, CodingKey {
        case type, role, content, name, arguments, output
        case callId = "call_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch type {
        case "message":
            try c.encodeIfPresent(role, forKey: .role)
            if let parts = contentParts, !parts.isEmpty {
                try c.encode(parts, forKey: .content)
            } else {
                try c.encodeIfPresent(content, forKey: .content)
            }
        case "function_call":
            try c.encodeIfPresent(callId, forKey: .callId)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(arguments, forKey: .arguments)
        case "function_call_output":
            try c.encodeIfPresent(callId, forKey: .callId)
            try c.encodeIfPresent(output, forKey: .output)
        default:
            break
        }
    }

    static func message(role: String, content: String) -> ResponsesInputItem {
        ResponsesInputItem(type: "message", role: role, content: content)
    }
    static func message(role: String, parts: [ResponsesContentPart]) -> ResponsesInputItem {
        ResponsesInputItem(type: "message", role: role, contentParts: parts)
    }
    static func functionCall(callId: String, name: String, arguments: String) -> ResponsesInputItem {
        ResponsesInputItem(type: "function_call", callId: callId, name: name, arguments: arguments)
    }
    static func functionCallOutput(callId: String, output: String) -> ResponsesInputItem {
        ResponsesInputItem(type: "function_call_output", callId: callId, output: output)
    }
}

/// Responses API 工具声明（扁平结构，区别于 Chat Completions 的嵌套 function）
struct ResponsesTool: Encodable {
    let type: String
    let name: String
    let description: String
    let parameters: JSONSchema
}

/// 将 Chat Completions 风格的 ToolSchema 映射为 Responses API 工具声明
/// (internal:供 OpenAIProviderAdapter 复用,保持单一实现)。
func makeResponsesTools(_ schemas: [ToolSchema]?) -> [ResponsesTool]? {    guard let schemas, !schemas.isEmpty else { return nil }
    return schemas.map {
        ResponsesTool(
            type: "function",
            name: $0.function.name,
            description: $0.function.description,
            parameters: $0.function.parameters
        )
    }
}

/// 适配器回调转发盒:把引擎回调安全地跨 Task 边界传递给适配器事件消费循环。
/// @unchecked Sendable 的语义与适配器 delegate 在 URLSession 私有队列调用回调一致。
final class AdapterCallbackBox: @unchecked Sendable {
    let onToken: (String) -> Void
    let onToolCall: (ToolCall) -> Void
    let onReasoning: (String) -> Void
    let onUsage: (Int, Int, Int, Int) -> Void
    let onFinishReason: (String?) -> Void
    let onComplete: (Result<Void, Error>) -> Void

    init(
        onToken: @escaping (String) -> Void,
        onToolCall: @escaping (ToolCall) -> Void,
        onReasoning: @escaping (String) -> Void,
        onUsage: @escaping (Int, Int, Int, Int) -> Void,
        onFinishReason: @escaping (String?) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        self.onToken = onToken
        self.onToolCall = onToolCall
        self.onReasoning = onReasoning
        self.onUsage = onUsage
        self.onFinishReason = onFinishReason
        self.onComplete = onComplete
    }
}

// MARK: - Stream Response

struct ChatCompletionChunk: Codable {
    let id: String?
    let choices: [StreamChoice]?
    /// 流式响应最后一个 chunk 携带的用量（需 stream_options.include_usage = true）。
    let usage: UsageInfo?

    /// 用量明细（prompt = 输入，completion = 输出）
    struct UsageInfo: Codable {
        var promptTokens: Int = 0
        var completionTokens: Int = 0
        var totalTokens: Int = 0
        var promptTokensDetails: PromptTokensDetails?
        var completionTokensDetails: CompletionTokensDetails?
        /// DeepSeek 式 KV 缓存命中（顶层字段，不在 prompt_tokens_details 内）。
        /// 例：{"usage":{"prompt_tokens":32,"prompt_cache_hit_tokens":32,"prompt_cache_miss_tokens":0}}
        var promptCacheHitTokens: Int = 0
        var promptCacheMissTokens: Int = 0

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
            case completionTokensDetails = "completion_tokens_details"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case promptCacheMissTokens = "prompt_cache_miss_tokens"
        }

        /// 提示词 token 明细
        struct PromptTokensDetails: Codable {
            var cachedTokens: Int = 0
            var audioTokens: Int = 0
            var cacheCreationTokens: Int = 0

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
                case audioTokens = "audio_tokens"
                case cacheCreationTokens = "cache_creation_tokens"
            }
        }

        /// 补全 token 明细
        struct CompletionTokensDetails: Codable {
            var reasoningTokens: Int = 0
            var audioTokens: Int = 0
            var acceptedPredictionTokens: Int = 0
            var rejectedPredictionTokens: Int = 0

            enum CodingKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
                case audioTokens = "audio_tokens"
                case acceptedPredictionTokens = "accepted_prediction_tokens"
                case rejectedPredictionTokens = "rejected_prediction_tokens"
            }
        }
    }

    struct StreamChoice: Codable {
        let index: Int?
        let delta: StreamDelta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct StreamDelta: Codable {
        var content: String?
        var toolCalls: [ToolCallDelta]?
        /// 推理 / 思考过程（DeepSeek Reasoner、OpenAI o 系列、QwQ 等以
        /// `reasoning_content` 流式返回）。命中时经 `onReasoning` 上抛给上层展示。
        var reasoningContent: String?
        /// OpenAI 新协议 / xAI Grok 的思考字段(`reasoning`,与 reasoning_content 并存)。
        var reasoning: String?
        /// 旧版 OpenAI function_call 流格式（部分兼容服务仍在使用）。
        var functionCall: ToolCallFunctionDelta?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
            case reasoningContent = "reasoning_content"
            case reasoning
            case functionCall = "function_call"
        }
    }

    struct ToolCallDelta: Codable {
        let index: Int?
        var id: String?
        /// 标准格式：tool_calls[].function.name。
        var function: ToolCallFunctionDelta?
        /// 非标准兼容格式：部分服务把 name 直接放在 tool_calls[] 顶层。
        var name: String?
        /// 非标准兼容格式：部分服务把 arguments 直接放在 tool_calls[] 顶层。
        var arguments: String?
    }

    struct ToolCallFunctionDelta: Codable {
        var name: String?
        var arguments: String?
    }
}

// MARK: - LLM Client

// MARK: Anthropic Messages API 请求体

struct AnthropicThinking: Encodable {
    let type: String
    var budgetTokens: Int?
    var display: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
        case display
    }

    /// 手写 encode：可选字段用 encodeIfPresent，避免把 nil 编码成 `"budget_tokens": null` 之类
    /// Anthropic 会拒绝的脏字段。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(budgetTokens, forKey: .budgetTokens)
        try c.encodeIfPresent(display, forKey: .display)
    }

    /// 4.x 老式手动扩展思考（enabled + budget_tokens）。Claude 4.7+ 一律拒绝此写法（返回 400）。
    static func enabled(budget: Int) -> AnthropicThinking {
        AnthropicThinking(type: "enabled", budgetTokens: budget, display: nil)
    }
    /// 4.7+ / 5 代：自适应思考（默认开启），配合 output_config.effort 控深度。
    static var adaptive: AnthropicThinking {
        AnthropicThinking(type: "adaptive", budgetTokens: nil, display: nil)
    }
    /// 自适应思考 + 显式展示思考文本。Claude 5 / Opus 4.7+ 默认 display="omitted"（思考文本为空），
    /// 必须显式 "summarized" 才能拿到思考内容（display 只接受 summarized / omitted，无 "full"）。
    static var adaptiveWithDisplay: AnthropicThinking {
        AnthropicThinking(type: "adaptive", budgetTokens: nil, display: "summarized")
    }
    /// 5 代：显式关闭思考（Sonnet 5 / Opus 5 仅在 effort≤high 时允许；Fable/Mythos 5 拒绝 disabled）。
    static var disabled: AnthropicThinking {
        AnthropicThinking(type: "disabled", budgetTokens: nil, display: nil)
    }
}

/// Claude 5 代控制推理深度的字段（output_config.effort）。取值：low / medium / high / xhigh / max。
struct AnthropicOutputConfig: Encodable {
    var effort: String
}

/// Anthropic 提示词缓存断点标记。需在某个 content block / tool 上声明，
/// 告诉 Anthropic 「把到这里为止的前缀写入缓存（ephemeral，TTL 约 5 分钟）」。
/// 只读 `type`，固定为 ephemeral。
struct AnthropicCacheControl: Encodable {
    var type: String = "ephemeral"
}

struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    var messages: [AnthropicMessage]
    /// system 改为 content block 数组，以便在「稳定段」与「易变段（时间戳等）」之间放置 cache_control 断点，
    /// 让不随请求变化的前缀（人格/规则/工具说明等）命中提示词缓存。nil 表示不发送 system。
    var system: [AnthropicContentBlock]?
    var stream: Bool = true
    var temperature: Double?
    var topP: Double?
    var tools: [AnthropicToolDef]?
    var thinking: AnthropicThinking?
    var outputConfig: AnthropicOutputConfig?

    private enum CodingKeys: String, CodingKey {
        case model, messages, system, stream, temperature, tools, thinking, outputConfig
        case maxTokens = "max_tokens"
        case topP = "top_p"
    }

    /// 手写 encode：可选字段用 encodeIfPresent，避免把 thinking / outputConfig 的 nil 编码成
    /// `"thinking": null` 这种 Anthropic 会拒绝的字段。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(system, forKey: .system)
        try c.encode(stream, forKey: .stream)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encodeIfPresent(outputConfig, forKey: .outputConfig)
    }
}

struct AnthropicMessage: Encodable {
    let role: String
    let content: AnthropicContent
}

enum AnthropicContent: Encodable {
    case text(String)
    case blocks([AnthropicContentBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .blocks(let b): try container.encode(b)
        }
    }
}

struct AnthropicContentBlock: Encodable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var input: JSONSchemaValue?
    var toolUseId: String?
    var content: String?
    var source: AnthropicImageSource?
    /// 提示词缓存断点（可选）。仅在需要缓存到该 block 时才赋值，缺省不编码（避免发送 null 被 Anthropic 拒绝）。
    var cacheControl: AnthropicCacheControl? = nil

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content, source
        case toolUseId = "tool_use_id"
        case cacheControl = "cache_control"
    }

    static func text(_ t: String) -> AnthropicContentBlock {
        AnthropicContentBlock(type: "text", text: t)
    }
    static func toolResult(id: String, result: String) -> AnthropicContentBlock {
        AnthropicContentBlock(type: "tool_result", toolUseId: id, content: result)
    }
    /// assistant 发起的工具调用块（对应 OpenAI tool_calls[].function）。
    /// Anthropic 要求：assistant 消息里的 tool_use 必须与随后 user 消息里的 tool_result 一一对应。
    static func toolUse(id: String, name: String, input: JSONSchemaValue) -> AnthropicContentBlock {
        AnthropicContentBlock(type: "tool_use", id: id, name: name, input: input)
    }

    struct AnthropicImageSource: Encodable {
        var type: String = "base64"
        var mediaType: String
        var data: String

        enum CodingKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }
    }
}

struct AnthropicToolDef: Encodable {
    let name: String
    var description: String?
    var inputSchema: JSONSchema
    /// 提示词缓存断点（可选）。在最后一个 tool 上声明，让 tools 也进入缓存前缀。
    var cacheControl: AnthropicCacheControl? = nil

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }
}

// MARK: Anthropic SSE 事件

struct AnthropicSSEEvent: Decodable {
    var type: String
    var index: Int?
    var delta: AnthropicDelta?
    var contentBlock: AnthropicContentBlockStart?
    var message: AnthropicMessageMeta?
    var usage: AnthropicUsage?
    var error: AnthropicSSEError?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, usage, error
        case contentBlock = "content_block"
        case message
    }

    struct AnthropicDelta: Decodable {
        var type: String?
        var text: String?
        var partialJson: String?
        /// Anthropic 扩展思考（extended thinking）的思考 词元 流（thinking_delta 事件携带）。
        var thinking: String?
        /// Anthropic `message_delta` 事件携带的停止原因（end_turn / max_tokens / tool_use / stop_sequence）。
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case partialJson = "partial_json"
            case thinking
            case stopReason = "stop_reason"
        }
    }

    struct AnthropicContentBlockStart: Decodable {
        var type: String
        var id: String?
        var name: String?
        var text: String?
        var input: JSONSchemaValue?
    }

    struct AnthropicMessageMeta: Decodable {
        var id: String?
        var role: String?
        var stopReason: String?
        var stopSequence: String?
        var usage: AnthropicUsage?

        enum CodingKeys: String, CodingKey {
            case id, role, usage
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
        }
    }

    struct AnthropicUsage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        /// 命中提示词缓存的输入 词元 数（来自 message_start / message_delta 的 cache_read_input_tokens）。
        var cacheReadInputTokens: Int?
        /// 新建缓存写入的输入 词元 数（来自 message_start / message_delta 的 cache_creation_input_tokens）。
        var cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }

    struct AnthropicSSEError: Decodable {
        var type: String?
        var message: String?
    }
}

// MARK: - Google Gemini Generate Content API 类型

/// Gemini tool 函数声明（functionDeclarations），参数使用 Gemini Schema（OpenAPI 风格，type 需大写）。
struct GeminiFunctionDeclaration: Encodable {
    let name: String
    let description: String
    let parameters: GeminiSchema
}

/// Gemini Schema（参数结构）。type 采用大写枚举（STRING/NUMBER/INTEGER/BOOLEAN/ARRAY/OBJECT）。
/// 使用 final class 以支持递归 items（值类型无法递归自包含）。
final class GeminiSchema: Encodable {
    let type: String
    var properties: [String: GeminiSchema]?
    var required: [String]?
    var `enum`: [String]?
    var items: GeminiSchema?
    var description: String?

    init(type: String, properties: [String: GeminiSchema]? = nil, required: [String]? = nil, enum: [String]? = nil, items: GeminiSchema? = nil, description: String? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
        self.`enum` = `enum`
        self.items = items
        self.description = description
    }
}

/// Gemini 内容块（contents 数组元素）。role 取值 user / model / function。
struct GeminiContent: Encodable {
    let role: String
    let parts: [GeminiPart]
}

/// Gemini 单个 part：文本 / 函数调用 / 函数响应（三选一）。
struct GeminiPart: Encodable {
    var text: String?
    var functionCall: GeminiFunctionCallPayload?
    var functionResponse: GeminiFunctionResponsePayload?
    var inlineData: GeminiInlineData?

    struct GeminiFunctionCallPayload: Encodable {
        let name: String
        let args: JSONSchemaValue
    }

    struct GeminiFunctionResponsePayload: Encodable {
        let name: String
        let response: JSONSchemaValue
    }

    static func text(_ t: String) -> GeminiPart { GeminiPart(text: t) }
    static func inlineData(mimeType: String, data: String) -> GeminiPart {
        GeminiPart(inlineData: GeminiInlineData(mimeType: mimeType, data: data))
    }
    static func functionCall(name: String, args: JSONSchemaValue) -> GeminiPart {
        GeminiPart(functionCall: GeminiFunctionCallPayload(name: name, args: args))
    }
    static func functionResponse(name: String, response: JSONSchemaValue) -> GeminiPart {
        GeminiPart(functionResponse: GeminiFunctionResponsePayload(name: name, response: response))
    }
}

/// Gemini 内联二进制部件（图片 / 音频 / 文件），base64 编码。
struct GeminiInlineData: Encodable {
    var mimeType: String
    var data: String

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

/// Gemini 工具声明容器。
struct GeminiTool: Encodable {
    let functionDeclarations: [GeminiFunctionDeclaration]
}

/// Gemini 安全设置（全部设为 BLOCK_NONE，避免默认拦截工具输出 / 激进内容导致 Agent 循环中断）。
struct GeminiSafetySetting: Encodable {
    let category: String
    let threshold: String
}

/// Gemini 思考配置（2.5+ 支持）。includeThoughts 让思考过程以 thought 部件返回，
/// 由流式解析层按需上抛；thinkingBudget < 0 表示动态预算。
struct GeminiThinkingConfig: Encodable {
    var thinkingBudget: Int?
    var includeThoughts: Bool?

    enum CodingKeys: String, CodingKey {
        case thinkingBudget = "thinkingBudget"
        case includeThoughts = "includeThoughts"
    }
}

/// Gemini 生成配置。
struct GeminiGenerationConfig: Encodable {
    var temperature: Double?
    var topP: Double?
    var maxOutputTokens: Int?
    var stopSequences: [String]?
    var thinkingConfig: GeminiThinkingConfig?
}

/// Gemini 生成请求体。流式由 URL 的 `?alt=sse` 控制，无需 stream 字段。
struct GeminiGenerateContentRequest: Encodable {
    var contents: [GeminiContent]
    var systemInstruction: GeminiContent?
    var tools: [GeminiTool]?
    var safetySettings: [GeminiSafetySetting]
    var generationConfig: GeminiGenerationConfig
}

// MARK: Gemini 流式响应解析类型

struct GeminiGenerateContentResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?

    struct GeminiCandidate: Decodable {
        let content: GeminiContentResponse?
        let finishReason: String?
        let index: Int?
    }

    struct GeminiContentResponse: Decodable {
        let parts: [GeminiPartResponse]?
        let role: String?
    }

    struct GeminiPartResponse: Decodable {
        let text: String?
        let functionCall: GeminiFunctionCallResponse?
    }

    struct GeminiFunctionCallResponse: Decodable {
        let name: String?
        let args: JSONSchemaValue?
    }

    struct GeminiUsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
        /// 命中上下文缓存的 词元 数（Gemini 2.5+ 隐式缓存自动上报 cached_content_token_count）。
        let cachedContentTokenCount: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokenCount = "promptTokenCount"
            case candidatesTokenCount = "candidatesTokenCount"
            case totalTokenCount = "totalTokenCount"
            case cachedContentTokenCount = "cachedContentTokenCount"
        }
    }
}

struct LLMStreamResult {
    let text: String
    let toolCalls: [ToolCall]
}

final class LLMClient: @unchecked Sendable {
    private let sessionConfiguration: URLSessionConfiguration
    private var endpointURL: String
    private var apiKey: String
    private var format: APIFormat
    private var usesAzureAPIKey: Bool
    private var organizationId: String?
    private var projectId: String?
    private var clientRequestId: UUID?
    /// 服务商类型（驱动鉴头 / 端点 / 请求体 / SSE 解析分支）
    private var providerType: ProviderType
    /// 用户自定义请求头（provider 配置附带），在默认头之后合并、用户优先
    private var customHeaders: [String: String]?

    init(
        endpointURL: String,
        apiKey: String = "",
        format: APIFormat = .chatCompletions,
        usesAzureAPIKey: Bool = false,
        organizationId: String? = nil,
        projectId: String? = nil,
        clientRequestId: UUID? = nil,
        customHeaders: [String: String]? = nil,
        providerType: ProviderType = .openai
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        // 刻意不启用 waitsForConnectivity：它会禁用请求超时，断网时任务无限等待，
        // 导致 onComplete 永不回调、Agent 循环永久挂死（唯一逃生通道是用户手动停止）。
        // 断网让请求立即失败（NotConnectedToInternet），由引擎既有的重试/fallback 链路接管。
        self.sessionConfiguration = config
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.format = format
        self.usesAzureAPIKey = usesAzureAPIKey
        self.organizationId = organizationId
        self.projectId = projectId
        self.clientRequestId = clientRequestId
        self.customHeaders = customHeaders
        self.providerType = providerType
    }

    func streamChat(
        model: String,
        messages: [ChatCompletionMessage],
        tools: [ToolSchema]? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: String? = nil,
        thinkingLevel: String? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        seed: Int? = nil,
        responseFormat: ResponseFormat? = nil,
        parallelToolCalls: Bool? = nil,
        onToken: @escaping (String) -> Void,
        onToolCall: @escaping (ToolCall) -> Void,
        onReasoning: @escaping (String) -> Void = { _ in },
        onUsage: @escaping (Int, Int, Int, Int) -> Void,
        onFinishReason: @escaping (String?) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) -> URLSessionDataTask? {
        // 全部供应商经工厂分发到各自适配器(OpenAI 兼容族/Anthropic/Gemini)。
        if let adapter = LLMProviderFactory.adapter(
            providerType: providerType,
            endpointURL: endpointURL,
            apiKey: apiKey,
            usesAzureAPIKey: usesAzureAPIKey,
            format: format,
            customHeaders: customHeaders,
            organizationId: organizationId,
            projectId: projectId,
            clientRequestId: clientRequestId
        ) {
            return runWithAdapter(
                adapter,
                model: model,
                messages: messages,
                tools: tools,
                temperature: temperature,
                topP: topP,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                thinkingLevel: thinkingLevel,
                frequencyPenalty: frequencyPenalty,
                presencePenalty: presencePenalty,
                seed: seed,
                responseFormat: responseFormat,
                parallelToolCalls: parallelToolCalls,
                onToken: onToken,
                onToolCall: onToolCall,
                onReasoning: onReasoning,
                onUsage: onUsage,
                onFinishReason: onFinishReason,
                onComplete: onComplete
            )
        }
        // 工厂当前覆盖全部供应商;防御:未来新增未注册 case 时兜底报错而非静默。
        onComplete(.failure(LLMError.providerRejected("未找到供应商适配器: \(providerType.rawValue)")))
        return nil
    }

    // MARK: - 多模态部件转换

    /// 从 data URI（data:<mime>;base64,<data>）解析出 (mimeType, base64)。
    /// 非 data URI（http(s) 链接）返回 (nil, 原串)，由调用方决定如何处理。
    static func parseDataURI(_ uri: String) -> (mime: String?, base64: String, isDataURI: Bool) {
        guard uri.hasPrefix("data:"),
              let comma = uri.firstIndex(of: ",") else {
            return (nil, uri, false)
        }
        let meta = String(uri[uri.index(after: uri.startIndex)..<comma])
        let payload = String(uri[uri.index(after: comma)...])
        // meta 形如 "image/png;base64" 或 "image/png"
        let mime = meta.components(separatedBy: ";").first
        return (mime, payload, true)
    }

    /// 将统一 ContentPart 翻译为 Anthropic 内容块；不支持的类型返回 nil。
    static func anthropicBlock(from part: ContentPart) -> AnthropicContentBlock? {
        switch part {
        case .text(let t): return .text(t)
        case .imageURL(let url, _):
            let (mime, base64, isURI) = parseDataURI(url)
            // 仅 data URI 可作为 base64 发送；http(s) 链接直接丢弃（与 Gemini 分支一致），
            // 否则会把整个 URL 字符串当 base64 发给 Anthropic，导致 400。
            guard isURI else { return nil }
            return AnthropicContentBlock(type: "image", text: nil, id: nil, name: nil, input: nil,
                                         toolUseId: nil, content: nil,
                                         source: AnthropicContentBlock.AnthropicImageSource(mediaType: mime ?? "image/png", data: base64))
        case .inputAudio(let data, let format):
            let mediaType = Self.audioMimeType(format)
            return AnthropicContentBlock(type: "audio", text: nil, id: nil, name: nil, input: nil,
                                         toolUseId: nil, content: nil,
                                         source: AnthropicContentBlock.AnthropicImageSource(mediaType: mediaType, data: data))
        case .file(let fd, _, _):
            guard let fd else { return nil }
            let (mime, base64, isURI) = parseDataURI(fd)
            // Anthropic 仅原生支持 PDF 文档块；其余文档类型回退忽略。
            guard isURI, let mime, mime == "application/pdf" else { return nil }
            return AnthropicContentBlock(type: "document", text: nil, id: nil, name: nil, input: nil,
                                         toolUseId: nil, content: nil,
                                         source: AnthropicContentBlock.AnthropicImageSource(mediaType: mime, data: base64))
        }
    }

    /// 将统一 ContentPart 翻译为 Gemini 部件；不支持的类型返回 nil。
    static func geminiPart(from part: ContentPart) -> GeminiPart? {
        switch part {
        case .text(let t): return .text(t)
        case .imageURL(let url, _):
            let (mime, base64, isURI) = parseDataURI(url)
            guard isURI else { return nil }
            return .inlineData(mimeType: mime ?? "image/png", data: base64)
        case .inputAudio(let data, let format):
            let mime = Self.audioMimeType(format)
            return .inlineData(mimeType: mime, data: data)
        case .file(let fd, _, _):
            guard let fd else { return nil }
            let (mime, base64, isURI) = parseDataURI(fd)
            guard isURI else { return nil }
            return .inlineData(mimeType: mime ?? "application/octet-stream", data: base64)
        }
    }

    /// 音频格式后缀 → MIME（Anthropic / Gemini 要求带 subtype 的 audio/*）。
    static func audioMimeType(_ format: String) -> String {
        switch format.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mp3"
        case "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "webm": return "audio/webm"
        default: return "audio/\(format)"
        }
    }

    /// 由文件扩展名推断 MIME（用于把本地附件包成 data URI）。
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "bmp": return "image/bmp"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "webm": return "audio/webm"
        case "mp4", "mov", "m4v": return "video/mp4"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "txt", "text", "md", "json", "csv", "xml", "yaml", "yml", "css", "html", "htm",
             "py", "swift", "js", "ts", "java", "c", "cpp", "h", "sh", "go", "rs", "rb":
            return "text/plain"
        default: return "application/octet-stream"
        }
    }

    /// 由文本 + 本地附件路径构建发送给模型的内容。附件已假定按模型输入模态过滤过
    /// （不支持的类型不应传入）。图片→image_url data URI；音频→input_audio；其余→file。
    static func buildUserContent(text: String, attachments: [String]) -> MessageContent {
        guard !attachments.isEmpty else { return .text(text) }
        var parts: [ContentPart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        for path in attachments {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            let mime = Self.mimeType(forExtension: ext)
            let base64 = data.base64EncodedString()
            switch ext {
            case "jpg","jpeg","png","gif","webp","heic","heif","bmp":
                parts.append(.imageURL(url: "data:\(mime);base64,\(base64)", detail: "auto"))
            case "mp3","m4a","wav","aac","ogg","flac","webm":
                parts.append(.inputAudio(data: base64, format: ext == "m4a" ? "m4a" : ext))
            default:
                parts.append(.file(fileData: "data:\(mime);base64,\(base64)", fileId: nil, filename: url.lastPathComponent))
            }
        }
        return parts.isEmpty ? .text(text) : .parts(parts)
    }

    /// 提取消息的多模态部件（不含纯文本消息）。返回 nil 表示消息为纯文本，可走旧逻辑。
    static func multimodalParts(of content: MessageContent?) -> [ContentPart]? {
        guard case .parts(let parts) = content else { return nil }
        return parts
    }

    /// 把 system/developer 消息上的 `volatileSuffix` 拼回 content 末尾（仅用于 OpenAI / Responses / Gemini 路径）。
    /// 设计意图：易变段（时间戳、挂载列表）始终位于 system 末尾，同一 run 内冻结不变，可命中各家前缀缓存；
    /// 不进入 Anthropic 路径（Anthropic 走独立的 system block 拆分 + cache_control 断点）。
    // MARK: - 适配器桥接(阶段 1)

    /// 通过供应商适配器发起流式请求,并把事件流桥接回原有回调 API。
    /// 调用方(引擎/标题生成/压缩)感知不到实现切换;返回的 task 供 cancel() 取消。
    private func runWithAdapter(
        _ adapter: any LLMProviderAdapter,
        model: String,
        messages: [ChatCompletionMessage],
        tools: [ToolSchema]?,
        temperature: Double?,
        topP: Double?,
        maxTokens: Int?,
        reasoningEffort: String?,
        thinkingLevel: String?,
        frequencyPenalty: Double?,
        presencePenalty: Double?,
        seed: Int?,
        responseFormat: ResponseFormat?,
        parallelToolCalls: Bool?,
        onToken: @escaping (String) -> Void,
        onToolCall: @escaping (ToolCall) -> Void,
        onReasoning: @escaping (String) -> Void,
        onUsage: @escaping (Int, Int, Int, Int) -> Void,
        onFinishReason: @escaping (String?) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) -> URLSessionDataTask? {
        let request = LLMStreamRequest(
            model: model,
            messages: messages,
            tools: tools,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            thinkingLevel: thinkingLevel,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            seed: seed,
            responseFormat: responseFormat,
            parallelToolCalls: parallelToolCalls,
            stream: true
        )
        let handle = adapter.streamChat(request: request)
        // 回调经 @unchecked Sendable 盒子跨 Task 传递——与适配器 delegate 在
        // URLSession 私有队列回调这些闭包的行为一致(闭包本身由引擎持有非 Sendable 状态)。
        let box = AdapterCallbackBox(
            onToken: onToken,
            onToolCall: onToolCall,
            onReasoning: onReasoning,
            onUsage: onUsage,
            onFinishReason: onFinishReason,
            onComplete: onComplete
        )
        Task {
            do {
                for try await event in handle.events {
                    switch event {
                    case .token(let t): box.onToken(t)
                    case .reasoning(let r): box.onReasoning(r)
                    case .toolCall(let tc): box.onToolCall(tc)
                    case .usage(let p, let c, let cr, let cw): box.onUsage(p, c, cr, cw)
                    case .finishReason(let fr): box.onFinishReason(fr)
                    }
                }
                box.onComplete(.success(()))
            } catch {
                box.onComplete(.failure(error))
            }
        }
        return handle.task
    }

    /// 将 Chat Completions 风格的 messages 翻译为官方 input 结构：
    /// 把易变后缀拼到一条消息内容的末尾（user-turn 后缀做法）：
    /// 纯文本直接拼接；多模态块则在末尾追加一个 text 块。
    static func appendingVolatile(_ volatile: String, to content: AnthropicContent) -> AnthropicContent {
        switch content {
        case .text(let t):
            return .text(t + "\n\n" + volatile)
        case .blocks(var blocks):
            blocks.append(AnthropicContentBlock(type: "text", text: volatile))
            return .blocks(blocks)
        }
    }

    /// 在一条消息内容上打缓存断点：纯文本整体转成带 cache_control 的 block；
    /// 多模态块则在最后一个 block 上声明 cache_control，使该消息之前的全部前缀进入缓存。
    static func markCacheBreakpoint(_ content: AnthropicContent) -> AnthropicContent {
        switch content {
        case .text(let t):
            var block = AnthropicContentBlock(type: "text", text: t)
            block.cacheControl = AnthropicCacheControl(type: "ephemeral")
            return .blocks([block])
        case .blocks(var blocks):
            if let lastIdx = blocks.indices.last {
                blocks[lastIdx].cacheControl = AnthropicCacheControl(type: "ephemeral")
            }
            return .blocks(blocks)
        }
    }

    /// 将 OpenAI 工具调用的 arguments（JSON 字符串）解析为 Anthropic tool_use.input 需要的结构化对象。
    /// Anthropic 要求 input 必须是 JSON 对象；解析失败或为空时回退为空对象 {}。
    static func parseToolArguments(_ arguments: String) -> JSONSchemaValue {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONSchemaValue.self, from: data) else {
            return .object([:])
        }
        // 仅接受对象；若模型给了非对象（数组/标量），包一层避免 Anthropic 拒绝。
        if case .object = value { return value }
        return .object([:])
    }

    /// Claude 4.7+ / 5 代自适应思考模型判断(供 AnthropicProviderAdapter 复用,单一实现)。
    static func isClaudeAdaptiveGen(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("claude-opus-5") || m.contains("claude-sonnet-5")
            || m.contains("claude-fable-5") || m.contains("claude-mythos-5")
            || m.contains("claude-opus-4-7") || m.contains("claude-opus-4-8")
            || m.contains("claude-sonnet-4-7") || m.contains("claude-sonnet-4-8")
    }

    /// Claude Fable 5 / Mythos 5 拒绝 thinking:{type:"disabled"}(思考无法关闭)。
    static func isClaudeNonDisableable(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("claude-fable-5") || m.contains("claude-mythos-5")
    }

    /// 将 OpenAI 风格 JSONSchema（小写 type）转换为 Gemini Schema（大写 type，递归 properties/items）。
    /// 注：顶层 JSONSchema 仅有 type/properties/required；items/enum 仅存在于嵌套 JSONProperty。
    static func geminiSchema(from schema: JSONSchema) -> GeminiSchema {
        var props: [String: GeminiSchema]?
        if let p = schema.properties, !p.isEmpty {
            var built: [String: GeminiSchema] = [:]
            for (k, v) in p { built[k] = geminiSchema(fromProp: v) }
            props = built
        }
        return GeminiSchema(
            type: schema.type.uppercased(),
            properties: props,
            required: schema.required,
            enum: nil,
            items: nil,
            description: nil
        )
    }

    static func geminiSchema(fromProp prop: JSONSchema.JSONProperty) -> GeminiSchema {
        var items: GeminiSchema?
        if let itemSchema = prop.items { items = geminiSchema(from: itemSchema) }
        let properties = prop.properties.map { values in
            // 2026-08-12 修复:重复 key 用 uniquingKeysWith 避免崩溃(全维度审计)。
            Dictionary(values.map { key, value in
                (key, geminiSchema(fromProp: value))
            }, uniquingKeysWith: { _, new in new })
        }
        return GeminiSchema(
            type: prop.type.uppercased(),
            properties: properties,
            required: prop.required,
            enum: prop.`enum`,
            items: items,
            description: prop.description
        )
    }
}

enum LLMError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case noData
    case invalidResponse(Int)
    case rateLimited
    case providerRejected(String)
    case streamTruncated

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return L10n.l("llm_encoding_failed")
        case .decodingFailed: return L10n.l("llm_decoding_failed")
        case .noData: return L10n.l("llm_no_data")
        case .invalidResponse(let statusCode): return String(format: L10n.l("llm_invalid_response"), statusCode)
        case .rateLimited: return L10n.l("llm_rate_limited")
        case .providerRejected(let message): return message
        case .streamTruncated: return L10n.l("llm_stream_truncated")
        }
    }
}

