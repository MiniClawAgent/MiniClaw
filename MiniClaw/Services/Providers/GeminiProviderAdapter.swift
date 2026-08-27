import Foundation

// MARK: - Google Gemini 适配器
// 官方:https://ai.google.dev/api/generate-content(streamGenerateContent)
//
// 协议要点(官方文档,2026 现状):
// - 流式端点 `POST .../v1beta/{model}:streamGenerateContent`;认证 `?key=` 查询参数
//   (官方新示例推 x-goog-api-key 头,二者等价;沿用 ?key= 与旧实现一致);
// - **协议无 [DONE]/message_stop 哨兵:连接正常关闭即完成**——完整性判定豁免,
//   不能对 Gemini 报 streamTruncated(官方协议差异,非缺陷);
// - 每个 chunk 是完整 GenerateContentResponse:增量文本在 candidates[].content.parts[].text;
//   finishReason 只在最后一个 chunk 出现;functionCall part 的 args 是完整 JSON 对象(非增量);
// - usageMetadata 随 chunk 出现(累积):promptTokenCount / candidatesTokenCount /
//   cachedContentTokenCount(2.5+ 隐式缓存) / thoughtsTokenCount;
// - 思考:Gemini 2.5+ 默认思考,thinkingConfig.thinkingLevel 控制深度。

/// Gemini 适配器配置。
struct GeminiCompatConfig: Sendable {
    var endpointURL: String
    var apiKey: String
    var customHeaders: [String: String]?
}

final class GeminiProviderAdapter: LLMProviderAdapter, @unchecked Sendable {
    let name = "Gemini"
    let config: GeminiCompatConfig

    init(config: GeminiCompatConfig) {
        self.config = config
    }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportsResponseFormat: true,
            supportsParallelToolCalls: true,
            supportsSeed: true,
            supportsPromptCaching: true,
            supportsReasoning: true,
            supportedInputModalities: ["text", "image", "audio"]
        )
    }

    // MARK: 内置模型目录(Google Gemini 官方模型)

    class var builtinModels: [String: BuiltinModelInfo] {
        [

            "gemini-2.5-flash": BuiltinModelInfo(displayName: "Gemini 2.5 Flash", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image", "audio"], output: ["text"]),
            "gemini-2.5-flash-lite": BuiltinModelInfo(displayName: "Gemini 2.5 Flash-Lite", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image", "audio"], output: ["text"]),
            "gemini-2.5-pro": BuiltinModelInfo(displayName: "Gemini 2.5 Pro", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image", "audio"], output: ["text"]),
            "gemini-3-flash": BuiltinModelInfo(displayName: "Gemini 3 Flash", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image", "audio", "video"], output: ["text"]),
            "gemini-3.1-flash-lite": BuiltinModelInfo(displayName: "Gemini 3.1 Flash-Lite", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: false, input: ["text", "image", "audio", "video"], output: ["text"]),
            "gemini-3.1-pro": BuiltinModelInfo(displayName: "Gemini 3.1 Pro", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image", "audio", "video"], output: ["text"]),
            "gemini-3.5-flash": BuiltinModelInfo(displayName: "Gemini 3.5 Flash", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image", "audio", "video"], output: ["text"]),
        ]
    }

    class func modelCapabilities(for modelID: String) -> BuiltinModelInfo? {
        builtinModels[modelID] ?? heuristicCapabilities(for: modelID)
    }

    // MARK: - 请求

    func streamChat(request: LLMStreamRequest) -> LLMStreamHandle {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Gemini 鉴权:官方 `?key=` 查询参数 + `alt=sse`(让流以 SSE data: 帧返回,解析器按行解析;
        // alt=sse 是格式开关,独立于 key 是否存在)。
        var effectiveURLString = config.endpointURL
        effectiveURLString += (effectiveURLString.contains("?") ? "&" : "?") + "alt=sse"
        if !key.isEmpty {
            effectiveURLString += "&key=\(key)"
        }
        guard let url = URL(string: effectiveURLString) else {
            let stream = AsyncThrowingStream<LLMStreamEvent, Error> { cont in
                cont.finish(throwing: LLMError.invalidResponse(-1))
            }
            return LLMStreamHandle(task: Self.cancelledTask(), events: stream)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in config.customHeaders ?? [:] {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let body = buildGeminiBody(request: request)
        guard !body.isEmpty else {
            let stream = AsyncThrowingStream<LLMStreamEvent, Error> { cont in
                cont.finish(throwing: LLMError.encodingFailed)
            }
            return LLMStreamHandle(task: Self.cancelledTask(), events: stream)
        }
        req.httpBody = body

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 120
        let delegate = GeminiStreamDelegate(config: config) { [weak self] statusCode, body in
            self?.classifyHTTPError(statusCode: statusCode, body: body)
        }
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        let task = session.dataTask(with: req)
        AppLogger.shared.info("适配器请求发起 provider=Gemini url=\(config.endpointURL)", category: "LLMClient", subsystem: "Adapter")

        let events = AsyncThrowingStream<LLMStreamEvent, Error> { continuation in
            delegate.onEvent = { continuation.yield($0) }
            delegate.onFinish = { result in
                switch result {
                case .success: continuation.finish()
                case .failure(let e): continuation.finish(throwing: e)
                }
            }
            task.resume()
            continuation.onTermination = { _ in task.cancel() }
        }
        return LLMStreamHandle(task: task, events: events)
    }

    private static func cancelledTask() -> URLSessionDataTask {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://invalid.local")!)
        task.cancel()
        session.finishTasksAndInvalidate()
        return task
    }

    // MARK: - Body 构造(迁移自 LLMClient.buildGeminiBody,行为一致)

    /// 构建 Gemini GenerateContent 请求体。
    /// system/developer → systemInstruction;user → role "user";assistant → role "model";
    /// assistant 工具调用 → functionCall 块;tool 结果 → role "function" + functionResponse 块;
    /// tools → functionDeclarations;全部 BLOCK_NONE 安全设置避免默认拦截工具输出。
    private func buildGeminiBody(request: LLMStreamRequest) -> Data {
        let messages = request.messages.map { m -> ChatCompletionMessage in
            if (m.role == "system" || m.role == "developer"),
               let vol = m.volatileSuffix, !vol.isEmpty {
                let base = m.content?.asText ?? ""
                let merged = base.isEmpty ? vol : base + "\n\n" + vol
                var copy = m
                copy.content = .text(merged)
                copy.volatileSuffix = nil
                return copy
            }
            return m
        }
        var systemText: String?
        var contents: [GeminiContent] = []
        // Gemini 要求:model(functionCall) 之后必须紧跟 role="function" 的 functionResponse,
        // 且 function 消息之间不能插入 user。
        var pendingFunctionResponses: [GeminiContent] = []

        func flushFunctionResponses() {
            guard !pendingFunctionResponses.isEmpty else { return }
            contents.append(contentsOf: pendingFunctionResponses)
            pendingFunctionResponses.removeAll()
        }

        for m in messages {
            switch m.role {
            case "system", "developer":
                flushFunctionResponses()
                let text = m.content?.asText ?? ""
                if systemText == nil { systemText = text }
                else { systemText = (systemText ?? "") + "\n" + text }
            case "tool":
                let name = m.name ?? "tool_result"
                let resultText = m.content?.asText ?? ""
                let response: JSONSchemaValue = .object(["result": .string(resultText)])
                pendingFunctionResponses.append(GeminiContent(role: "function", parts: [.functionResponse(name: name, response: response)]))
            case "user":
                flushFunctionResponses()
                if let parts = LLMClient.multimodalParts(of: m.content), !parts.isEmpty {
                    let gp = parts.compactMap { LLMClient.geminiPart(from: $0) }
                    if !gp.isEmpty { contents.append(GeminiContent(role: "user", parts: gp)) }
                } else if let text = m.content?.asText, !text.isEmpty {
                    contents.append(GeminiContent(role: "user", parts: [.text(text)]))
                }
            case "assistant":
                flushFunctionResponses()
                var parts: [GeminiPart] = []
                if let multimodal = LLMClient.multimodalParts(of: m.content), !multimodal.isEmpty {
                    parts.append(contentsOf: multimodal.compactMap { LLMClient.geminiPart(from: $0) })
                } else if let text = m.content?.asText, !text.isEmpty {
                    parts.append(.text(text))
                }
                if let calls = m.toolCalls, !calls.isEmpty {
                    for c in calls {
                        parts.append(.functionCall(name: c.function.name, args: LLMClient.parseToolArguments(c.function.arguments)))
                    }
                }
                if !parts.isEmpty {
                    contents.append(GeminiContent(role: "model", parts: parts))
                }
            default:
                break
            }
        }
        flushFunctionResponses()

        var geminiTools: [GeminiTool]?
        if let tools = request.tools, !tools.isEmpty {
            let decls = tools.map { t in
                GeminiFunctionDeclaration(
                    name: t.function.name,
                    description: t.function.description,
                    parameters: LLMClient.geminiSchema(from: t.function.parameters)
                )
            }
            geminiTools = [GeminiTool(functionDeclarations: decls)]
        }

        // 安全设置:全部 BLOCK_NONE,避免 Gemini 默认拦截工具输出 / 激进内容导致 Agent 循环中断。
        let safety: [GeminiSafetySetting] = [
            "HARM_CATEGORY_DANGEROUS_CONTENT",
            "HARM_CATEGORY_HARASSMENT",
            "HARM_CATEGORY_HATE_SPEECH",
            "HARM_CATEGORY_SEXUALLY_EXPLICIT",
            "HARM_CATEGORY_CIVIC_INTEGRITY"
        ].map { GeminiSafetySetting(category: $0, threshold: "BLOCK_NONE") }

        // 深度思考:Gemini 2.5+ 默认思考。开启条件与旧内联实现一致
        // (reasoningEffort 或 thinkingLevel 档位触发;off 不注入——Gemini 无显式关闭开关,
        // 官方 thinkingConfig 只能调深度/是否返回思考文本)。
        let thinkingConfig: GeminiThinkingConfig? =
            (request.reasoningEffort != nil
             || (request.thinkingLevel != nil && request.thinkingLevel != "off"))
            ? GeminiThinkingConfig(thinkingBudget: nil, includeThoughts: true)
            : nil
        let genConfig = GeminiGenerationConfig(
            temperature: request.temperature,
            topP: request.topP,
            maxOutputTokens: request.maxTokens,
            thinkingConfig: thinkingConfig
        )

        let req = GeminiGenerateContentRequest(
            contents: contents,
            systemInstruction: systemText.map { GeminiContent(role: "user", parts: [.text($0)]) },
            tools: geminiTools,
            safetySettings: safety,
            generationConfig: genConfig
        )
        return (try? JSONEncoder().encode(req)) ?? Data()
    }

    // MARK: - 错误分类

    func classifyHTTPError(statusCode: Int, body: String) -> LLMError? {
        switch statusCode {
        case 400:
            return .providerRejected(body.isEmpty ? L10n.l("err_request_rejected") : body)
        case 401, 403:
            return .providerRejected(body.isEmpty ? L10n.l("err_auth_failed") : body)
        case 429:
            return .rateLimited
        default:
            if statusCode >= 500 {
                return .providerRejected(String(format: L10n.l("err_server_error"), statusCode, String(body.prefix(300))))
            }
            return nil
        }
    }
}

