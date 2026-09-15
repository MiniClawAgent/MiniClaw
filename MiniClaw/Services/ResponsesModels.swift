import Foundation

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
    /// [2026-09-15 OpenAI 官方合规] 路由粘性键（官方 Cookbook《Prompt Caching 201》§4.4）。
    /// Responses API 同样收录该字段；只在 `ProviderType.supportsPromptCacheKey` 为真时填入。
    var promptCacheKey: String?

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, stream, tools, reasoning
        case maxOutputTokens = "max_output_tokens"
        case promptCacheKey = "prompt_cache_key"
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


