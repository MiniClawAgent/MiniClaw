import Foundation

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

