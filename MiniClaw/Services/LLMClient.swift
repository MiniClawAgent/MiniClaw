import Foundation
import os

// MARK: - LLM Message Models


final class AdapterCallbackBox: @unchecked Sendable {
    let onToken: (String) -> Void
    let onToolCall: (ToolCall) -> Void
    /// 工具参数流式增量（id/name/累计部分 JSON/字节数）。
    let onToolCallStreaming: (String, String, String, Int) -> Void
    let onReasoning: (String) -> Void
    let onUsage: (Int, Int, Int, Int) -> Void
    let onFinishReason: (String?) -> Void
    let onComplete: (Result<Void, Error>) -> Void

    init(
        onToken: @escaping (String) -> Void,
        onToolCall: @escaping (ToolCall) -> Void,
        onToolCallStreaming: @escaping (String, String, String, Int) -> Void = { _, _, _, _ in },
        onReasoning: @escaping (String) -> Void,
        onUsage: @escaping (Int, Int, Int, Int) -> Void,
        onFinishReason: @escaping (String?) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        self.onToken = onToken
        self.onToolCall = onToolCall
        self.onToolCallStreaming = onToolCallStreaming
        self.onReasoning = onReasoning
        self.onUsage = onUsage
        self.onFinishReason = onFinishReason
        self.onComplete = onComplete
    }
}


// MARK: - LLM Client

// MARK: Anthropic Messages API 请求体


// [2026-09-13 重构·删除零引用类型] 此处原有 `struct LLMStreamResult { text; toolCalls }`，
// 全库引用数 = 1（仅定义处），是流式能力最早期的残留形态。线上正在使用的是
// `LLMStreamEvent` / `LLMStreamHandle` / `LLMStreamRequest`（LLMProviderAdapter:31-65：
// token/reasoning/toolCall/toolCallStreaming/usage/finishReason + AsyncThrowingStream + 取消句柄）
// —— 覆盖增量、思考、用量、结束原因与取消 ⇒ 删除本类型。

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
    /// [2026-09-15 OpenAI 官方合规] 会话级路由粘性键（官方 Prompt Caching §4.4）。
    /// nil = 不发（供应商未收录该字段时适配器本来也会忽略）。
    private var promptCacheKey: String?

    /// [2026-09-15 速度口径修正] 最近一次调用的时间锚点（**到达端**，来自适配器 `.outputTiming`）：
    /// `requestStartedAt`（请求交给 URLSession 的时刻）+ `first`/`last`（首末生成 token 到达时刻）。
    /// 加锁：写入在消费 Task，读取在引擎的调用返回之后。为 nil 时引擎回退到自己的消费端锚点。
    /// 用 `OSAllocatedUnfairLock` 而非 `NSLock`：后者的 lock/unlock 在**异步上下文**里被 Swift 标记为
    /// 不可用（可能跨越挂起点持锁），`withLock` 才是异步安全的（AppLogger 同款用法）。
    struct OutputTimingWindow: Sendable {
        let requestStartedAt: Date
        let first: Date
        let last: Date
    }
    private let outputWindow = OSAllocatedUnfairLock<OutputTimingWindow?>(initialState: nil)
    var lastOutputWindow: OutputTimingWindow? {
        outputWindow.withLock { $0 }
    }

    init(
        endpointURL: String,
        apiKey: String = "",
        format: APIFormat = .chatCompletions,
        usesAzureAPIKey: Bool = false,
        organizationId: String? = nil,
        projectId: String? = nil,
        clientRequestId: UUID? = nil,
        customHeaders: [String: String]? = nil,
        providerType: ProviderType = .openai,
        promptCacheKey: String? = nil
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
        self.promptCacheKey = promptCacheKey
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
        onToolCallStreaming: ((String, String, String, Int) -> Void)? = nil,
        onReasoning: @escaping (String) -> Void = { _ in },
        onUsage: @escaping (Int, Int, Int, Int) -> Void,
        onFinishReason: @escaping (String?) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) -> URLSessionDataTask? {
        // 全部供应商经工厂分发到各自适配器(OpenAI 兼容族/Anthropic/Gemini)。
        // [2026-09-14 唐唐 · 思考档位观测] 此前线上**没有任何"本轮实际发送了什么档位"的记录**，
        // 思维控制是否生效只能靠代码推断（审查结论之一）。每轮请求一行，与 [Cache] 指纹同量级；
        // `effort=nil` 也要打（= 该轮未发推理参数，本身就是一个需要看见的状态）。
        AppLogger.shared.info(
            "[LLM] effort=\(reasoningEffort ?? "nil") thinkingLevel=\(thinkingLevel ?? "nil") provider=\(String(describing: providerType)) model=\(model)",
            category: "LLM")
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
                onToolCallStreaming: onToolCallStreaming ?? { _, _, _, _ in },
                onReasoning: onReasoning,
                onUsage: onUsage,
                onFinishReason: onFinishReason,
                onComplete: onComplete
            )
        }
        // 工厂当前覆盖全部供应商;防御:未来新增未注册 case 时兜底报错而非静默。
        onComplete(.failure(LLMError.providerRejected(String(format: String(localized: "err_provider_adapter_missing"), providerType.rawValue))))
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
        onToolCallStreaming: @escaping (String, String, String, Int) -> Void,
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
            promptCacheKey: promptCacheKey,
            stream: true
        )
        let handle = adapter.streamChat(request: request)
        // 回调经 @unchecked Sendable 盒子跨 Task 传递——与适配器 delegate 在
        // URLSession 私有队列回调这些闭包的行为一致(闭包本身由引擎持有非 Sendable 状态)。
        let streamingHandler = onToolCallStreaming ?? { _, _, _, _ in }
        let box = AdapterCallbackBox(
            onToken: onToken,
            onToolCall: onToolCall,
            onToolCallStreaming: streamingHandler,
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
                    case .toolCallStreaming(let id, let name, let args, let bytes): box.onToolCallStreaming(id, name, args, bytes)
                    case .usage(let p, let c, let cr, let cw): box.onUsage(p, c, cr, cw)
                    case .outputTiming(let startedAt, let f, let l):
                        // [2026-09-15 速度口径修正] 记下到达端锚点（端到端 + 解码两个窗口都用它）。
                        self.outputWindow.withLock {
                            $0 = OutputTimingWindow(requestStartedAt: startedAt, first: f, last: l)
                        }
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
        case .encodingFailed: return String(localized: "llm_encoding_failed")
        case .decodingFailed: return String(localized: "llm_decoding_failed")
        case .noData: return String(localized: "llm_no_data")
        case .invalidResponse(let statusCode): return String(format: String(localized: "llm_invalid_response"), statusCode)
        case .rateLimited: return String(localized: "llm_rate_limited")
        case .providerRejected(let message): return message
        case .streamTruncated: return String(localized: "llm_stream_truncated")
        }
    }
}

