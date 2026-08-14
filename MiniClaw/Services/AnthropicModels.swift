import Foundation

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
