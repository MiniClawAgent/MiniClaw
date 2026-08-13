import Foundation

// MARK: - OpenAI 兼容供应商适配器
//
// 覆盖:OpenAI Chat Completions / OpenAI Responses API / OpenRouter / 任意 OpenAI 兼容网关(custom)。
// 设计参考 OpenAIProvider:
// - 认证集中判定(applyKeyAuth):Azure 用 `api-key` 头,其余一律 `Bearer`;
// - 端点/认证/构造/解析/能力声明全部内聚本文件;
// - OpenAI 兼容厂商(DeepSeek/Mistral/DashScope 等)继承本类只覆写差异。

/// OpenAI 兼容配置(工厂注入)。
struct OpenAICompatConfig: Sendable {
    var endpointURL: String
    var apiKey: String
    var usesAzureAPIKey: Bool
    var format: APIFormat
    var customHeaders: [String: String]?
    var organizationId: String?
    var projectId: String?
    var clientRequestId: UUID?
    /// 供应商类型：适配器据此查询厂商能力表(responsesPath / supportsReasoningNone)，
    /// 决定 Responses API 回落与 reasoning 字段兼容(单一事实来源,见 ProviderType 扩展)。
    var providerType: ProviderType = .openai
}

/// OpenAI 兼容供应商适配器(基类)。
///
/// 覆盖:OpenAI Chat Completions / OpenAI Responses API / OpenRouter / 任意 OpenAI 兼容网关(custom)。
/// 设计参考 OpenAIProvider:
/// - 认证集中判定(applyKeyAuth):Azure 用 `api-key` 头,其余一律 `Bearer`;
/// - 端点/认证/构造/解析/能力声明全部内聚本文件;
/// - OpenAI 兼容厂商(Grok/千问/小米/智谱等)继承本类,只覆写差异
///   (`extraBodyFields` 注入非标准参数、`clampSampling` 钳制采样范围、`capabilities` 声明能力)。
class OpenAIProviderAdapter: LLMProviderAdapter, @unchecked Sendable {
    let name: String
    let config: OpenAICompatConfig

    init(name: String, config: OpenAICompatConfig) {
        self.name = name
        self.config = config
    }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportsResponseFormat: true,
            supportsParallelToolCalls: true,
            supportsSeed: true,
            supportsPromptCaching: false,
            supportsReasoning: true,
            supportedInputModalities: ["text", "image", "audio"]
        )
    }

    // MARK: - 内置模型目录(模型维护并入厂商文件)

    class var builtinModels: [String: BuiltinModelInfo] {
        [

            "anthropic/claude-fable-5": BuiltinModelInfo(displayName: "Claude Fable 5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "anthropic/claude-mythos-5": BuiltinModelInfo(displayName: "Claude Mythos 5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "anthropic/claude-opus-4.5": BuiltinModelInfo(displayName: "Claude Opus 4.5", contextWindow: 200000, maxOutputTokens: 64000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "max"], input: ["text", "image"], output: ["text"]),
            "anthropic/claude-opus-5": BuiltinModelInfo(displayName: "Claude Opus 5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "anthropic/claude-sonnet-4.5": BuiltinModelInfo(displayName: "Claude Sonnet 4.5", contextWindow: 200000, maxOutputTokens: 64000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "max"], input: ["text", "image"], output: ["text"]),
            "anthropic/claude-sonnet-5": BuiltinModelInfo(displayName: "Claude Sonnet 5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "deepseek/deepseek-v4-flash": BuiltinModelInfo(displayName: "DeepSeek V4 Flash", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high"], input: ["text"], output: ["text"]),
            "deepseek/deepseek-v4-pro": BuiltinModelInfo(displayName: "DeepSeek V4 Pro", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high"], input: ["text"], output: ["text"]),
            "google/gemini-2.5-pro": BuiltinModelInfo(displayName: "Gemini 2.5 Pro", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image", "audio"], output: ["text"]),
            "gpt-4.1": BuiltinModelInfo(displayName: "GPT-4.1", contextWindow: 1000000, maxOutputTokens: 32768, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "gpt-4.1-mini": BuiltinModelInfo(displayName: "GPT-4.1 mini", contextWindow: 1000000, maxOutputTokens: 32768, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "gpt-4o": BuiltinModelInfo(displayName: "GPT-4o", contextWindow: 128000, maxOutputTokens: 16384, deepThinking: false, input: ["text", "image", "audio"], output: ["text"]),
            "gpt-4o-mini": BuiltinModelInfo(displayName: "GPT-4o mini", contextWindow: 128000, maxOutputTokens: 16384, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "gpt-5.1": BuiltinModelInfo(displayName: "GPT-5.1", contextWindow: 400000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high"], input: ["text", "image"], output: ["text"]),
            "gpt-5.2": BuiltinModelInfo(displayName: "GPT-5.2", contextWindow: 400000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh"], input: ["text", "image"], output: ["text"]),
            "gpt-5.5": BuiltinModelInfo(displayName: "GPT-5.5", contextWindow: 1050000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh"], input: ["text", "image"], output: ["text"]),
            "gpt-5.6": BuiltinModelInfo(displayName: "GPT-5.6", contextWindow: 1050000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "gpt-5.6-luna": BuiltinModelInfo(displayName: "GPT-5.6 Luna", contextWindow: 1050000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "gpt-5.6-sol": BuiltinModelInfo(displayName: "GPT-5.6 Sol", contextWindow: 1050000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "gpt-5.6-terra": BuiltinModelInfo(displayName: "GPT-5.6 Terra", contextWindow: 1050000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "llama-3.3-70b": BuiltinModelInfo(displayName: "Llama 3.3 70B", contextWindow: 128000, maxOutputTokens: 4096, deepThinking: false, input: ["text"], output: ["text"]),
            "llama-4-maverick": BuiltinModelInfo(displayName: "Llama 4 Maverick", contextWindow: 128000, maxOutputTokens: 4096, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "llama-4-scout": BuiltinModelInfo(displayName: "Llama 4 Scout", contextWindow: 128000, maxOutputTokens: 4096, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "meta-llama/llama-4-maverick": BuiltinModelInfo(displayName: "Llama 4 Maverick", contextWindow: 128000, maxOutputTokens: 4096, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "minimax-m2": BuiltinModelInfo(displayName: "MiniMax M2", contextWindow: 200000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "minimax/minimax-m2": BuiltinModelInfo(displayName: "MiniMax M2", contextWindow: 200000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "mistral-large-3": BuiltinModelInfo(displayName: "Mistral Large 3", deepThinking: false, input: ["text", "image"], output: ["text"]),
            "mistral-large-latest": BuiltinModelInfo(displayName: "Mistral Large", contextWindow: 128000, maxOutputTokens: 4096, deepThinking: false, input: ["text"], output: ["text"]),
            "mistral-small-latest": BuiltinModelInfo(displayName: "Mistral Small", contextWindow: 128000, maxOutputTokens: 4096, deepThinking: false, input: ["text"], output: ["text"]),
            "openai/gpt-4.1": BuiltinModelInfo(displayName: "GPT-4.1", contextWindow: 1000000, maxOutputTokens: 32768, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "openai/gpt-4o": BuiltinModelInfo(displayName: "GPT-4o", contextWindow: 128000, maxOutputTokens: 16384, deepThinking: false, input: ["text", "image", "audio"], output: ["text"]),
            "openai/gpt-5": BuiltinModelInfo(displayName: "GPT-5", contextWindow: 400000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high"], input: ["text", "image"], output: ["text"]),
            "openai/gpt-5.2": BuiltinModelInfo(displayName: "GPT-5.2", contextWindow: 400000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh"], input: ["text", "image"], output: ["text"]),
            "pixtral-12b": BuiltinModelInfo(displayName: "Pixtral 12B", contextWindow: 128000, maxOutputTokens: 4096, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "qwen/qwen3-235b-a22b": BuiltinModelInfo(displayName: "Qwen3-235B-A22B", contextWindow: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "z-ai/glm-4.6": BuiltinModelInfo(displayName: "GLM-4.6", contextWindow: 200000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "z-ai/glm-5": BuiltinModelInfo(displayName: "GLM-5", contextWindow: 198000, maxOutputTokens: 64000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "z-ai/glm-5.1": BuiltinModelInfo(displayName: "GLM-5.1", contextWindow: 198000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
        ]
    }

    class func modelCapabilities(for modelID: String) -> BuiltinModelInfo? {
        builtinModels[modelID] ?? heuristicCapabilities(for: modelID)
    }

    // MARK: - 子类覆写点

    /// 是否在请求体中保留 assistant 消息的 reasoning_content。
    /// 默认 false(OpenAI/Groq/智谱等对未知消息字段容忍度不一,统一剥离保行为不变);
    /// DeepSeek 必须保留(官方硬性要求:带 tools 的后续请求必须回传 reasoning_content,否则 400)。
    var preserveReasoningContent: Bool { false }

    /// 请求体附加字段:子类注入本厂商的非 OpenAI 标准参数
    /// (如智谱 `thinking`、千问 `enable_thinking`)。返回 nil 表示无附加。
    func extraBodyFields(request: LLMStreamRequest) -> [String: Any]? { nil }

    /// 采样参数钳制:子类按官方约束调整参数
    /// (如智谱 temperature ∈ [0,1])。默认不调整。
    func clampSampling(request: inout LLMStreamRequest) {}

    // MARK: - 请求构造

    func streamChat(request: LLMStreamRequest) -> LLMStreamHandle {
        // 统一去除首尾空白,避免复制密钥时带入的换行/空格导致静默失效(与旧 LLMClient 一致)。
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: config.endpointURL) else {
            let stream = AsyncThrowingStream<LLMStreamEvent, Error> { cont in
                cont.finish(throwing: LLMError.invalidResponse(-1))
            }
            return LLMStreamHandle(task: Self.cancelledTask(), events: stream)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 标准 SSE 流式请求头:部分严格网关要求显式 Accept,否则可能返回非 SSE 或 406。
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // 认证判定(参考 applyKeyAuth:Azure 分支永远不可能设错头):
        // Azure → `api-key`;其余 → `Bearer`。
        if !key.isEmpty {
            if config.usesAzureAPIKey {
                req.setValue(key, forHTTPHeaderField: "api-key")
            } else {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        if let org = config.organizationId, !org.isEmpty {
            req.setValue(org, forHTTPHeaderField: "OpenAI-Organization")
        }
        if let project = config.projectId, !project.isEmpty {
            req.setValue(project, forHTTPHeaderField: "OpenAI-Project")
        }
        // 请求追踪 ID:与旧内联路径一致,便于网关侧排查单次请求。
        if let rid = config.clientRequestId {
            req.setValue(rid.uuidString, forHTTPHeaderField: "X-Client-Request-Id")
        }
        for (k, v) in config.customHeaders ?? [:] {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let body: Data
        // 供应商/模型级 Responses 回落:不支持该协议的供应商(能力表 responsesPath == nil)
        // 或模型(如 DeepSeek 非 v4-flash)自动降级 Chat Completions,URL 侧同步判断(见 AppState)。
        if effectiveFormat(for: request) == .responsesAPI {
            body = buildResponsesBody(request: request)
        } else {
            body = buildChatCompletionsBody(request: request)
        }
        // 编码失败必须报错而不能静默发空 body(与旧路径 encodingFailed 语义一致)。
        guard !body.isEmpty else {
            let stream = AsyncThrowingStream<LLMStreamEvent, Error> { cont in
                cont.finish(throwing: LLMError.encodingFailed)
            }
            return LLMStreamHandle(task: Self.cancelledTask(), events: stream)
        }
        req.httpBody = body

        // 超时配置与旧内联路径一致(30s 无数据 / 120s 总时长):
        // 流中途挂起时不能放任 URLSession 默认的 7 天资源超时,否则引擎挂死窗口长达数天。
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 120
        let delegate = OpenAIStreamDelegate(
            config: config,
            effectiveFormat: effectiveFormat(for: request),
            errorClassifier: { [weak self] statusCode, body in
                self?.classifyHTTPError(statusCode: statusCode, body: body)
            }
        )
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        let task = session.dataTask(with: req)
        AppLogger.shared.info("适配器请求发起 format=\(config.format.rawValue) url=\(config.endpointURL)", category: "LLMClient", subsystem: "Adapter")

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

    /// 兜底空任务(URL 无效等场景,供调用方持有并取消)。
    private static func cancelledTask() -> URLSessionDataTask {
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: URL(string: "https://invalid.local")!)
        task.cancel()
        session.finishTasksAndInvalidate()
        return task
    }

    // MARK: - Body 构造(逻辑迁移自 LLMClient,保持行为一致)

    /// 本次请求实际生效的协议格式。基类:供应商不支持 Responses(能力表 responsesPath == nil)
    /// 时回落 Chat Completions;子类(DeepSeek)可追加模型级回落。URL 侧(AppState)同步判断。
    func effectiveFormat(for request: LLMStreamRequest) -> APIFormat {
        if config.format == .responsesAPI, config.providerType.responsesPath == nil {
            return .chatCompletions
        }
        return config.format
    }

    private func buildChatCompletionsBody(request: LLMStreamRequest) -> Data {
        var adjusted = request
        clampSampling(request: &adjusted)
        // reasoning_content 剥离:除明确需要回传的厂商(DeepSeek)外,统一剥离,
        // 避免未知消息字段触发严格网关 400。
        let reqMessages = preserveReasoningContent
            ? resolveVolatile(adjusted.messages)
            : resolveVolatile(adjusted.messages).map { m in
                guard m.reasoningContent != nil else { return m }
                var copy = m
                copy.reasoningContent = nil
                return copy
            }
        let cc = ChatCompletionRequest(
            model: adjusted.model,
            messages: reqMessages,
            stream: true,
            tools: adjusted.tools,
            temperature: adjusted.temperature,
            maxTokens: adjusted.maxTokens,
            reasoningEffort: adjusted.reasoningEffort,
            topP: adjusted.topP,
            frequencyPenalty: adjusted.frequencyPenalty,
            presencePenalty: adjusted.presencePenalty,
            seed: adjusted.seed,
            responseFormat: adjusted.responseFormat,
            parallelToolCalls: adjusted.parallelToolCalls
        )
        // 编码失败场景:调用方收到空 body 会直接失败;此处尽力而为。
        guard let jsonData = try? JSONEncoder().encode(cc),
              var dict = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return Data()
        }
        // 子类注入非标准参数(智谱 thinking / 千问 enable_thinking 等)。
        if let extra = extraBodyFields(request: adjusted) {
            for (k, v) in extra { dict[k] = v }
        }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private func buildResponsesBody(request: LLMStreamRequest) -> Data {
        let messages = resolveVolatile(request.messages)
        var instructions: String?
        var inputItems: [ResponsesInputItem] = []

        for m in messages {
            switch m.role {
            case "system":
                let text = m.content?.asText
                if instructions == nil {
                    instructions = text
                } else {
                    instructions = (instructions ?? "") + "\n" + (text ?? "")
                }
            case "user":
                if let parts = Self.multimodalParts(of: m.content), !parts.isEmpty {
                    let rp = parts.compactMap { Self.responsesPart(from: $0) }
                    if !rp.isEmpty { inputItems.append(.message(role: "user", parts: rp)) }
                } else if let text = m.content?.asText, !text.isEmpty {
                    inputItems.append(.message(role: "user", content: text))
                }
            case "assistant":
                if let parts = Self.multimodalParts(of: m.content), !parts.isEmpty {
                    let rp = parts.compactMap { Self.responsesPart(from: $0) }
                    if !rp.isEmpty { inputItems.append(.message(role: "assistant", parts: rp)) }
                } else if let text = m.content?.asText, !text.isEmpty {
                    inputItems.append(.message(role: "assistant", content: text))
                }
                if let calls = m.toolCalls, !calls.isEmpty {
                    for tc in calls {
                        inputItems.append(.functionCall(
                            callId: tc.id,
                            name: tc.function.name,
                            arguments: tc.function.arguments
                        ))
                    }
                }
            case "tool":
                if let callId = m.toolCallID, let output = m.content?.asText {
                    inputItems.append(.functionCallOutput(callId: callId, output: output))
                }
            default:
                if let text = m.content?.asText, !text.isEmpty {
                    inputItems.append(.message(role: m.role, content: text))
                }
            }
        }

        let req = ResponsesRequest(
            model: request.model,
            instructions: instructions,
            input: inputItems,
            tools: makeResponsesTools(request.tools),
            maxOutputTokens: request.maxTokens,
            // reasoning.effort "none":仅发给官方枚举承诺支持的供应商(OpenAI/小米),
            // 其余(DeepSeek/OpenRouter)省略该字段,避免 400(厂商能力表 supportsReasoningNone)。
            reasoning: request.reasoningEffort.map { effort in
                effort == "none" && !config.providerType.supportsReasoningNone ? nil : ResponsesRequest.Reasoning(effort: effort)
            } ?? nil
        )
        return (try? JSONEncoder().encode(req)) ?? Data()
    }

    /// 把 system/developer 消息上的 volatileSuffix 从 system 剥离,追加为消息流末尾的独立 user 消息。
    ///
    /// 为什么不能拼回 system 末尾:DeepSeek/OpenAI 的上下文缓存是「请求前缀自动匹配」,
    /// volatile(时间戳等)每轮必变,拼在 system 末尾 = 前缀第一个易变字节 → 工具定义与全部历史
    /// 每轮全 miss(输入 词元 费用翻倍)。追加到流末尾则前缀(system+历史)逐字节不变,
    /// 每轮只 miss 末尾这一条小消息(与 Anthropic 路径的 cache_control 断点体系同构的收益)。
    /// 连续 user 消息是 OpenAI/DeepSeek 协议允许的(服务端按序处理),无格式问题。
    private func resolveVolatile(_ messages: [ChatCompletionMessage]) -> [ChatCompletionMessage] {
        var result = messages
        var volatileParts: [String] = []
        for i in result.indices {
            if (result[i].role == "system" || result[i].role == "developer"),
               let vol = result[i].volatileSuffix, !vol.isEmpty {
                volatileParts.append(vol)
                result[i].volatileSuffix = nil
            }
        }
        guard !volatileParts.isEmpty else { return result }
        let merged = volatileParts.joined(separator: "\n\n")
        // 追加为消息流末尾的独立 user 消息:不触碰任何历史消息,前缀保持不变。
        // 加显式标注防止模型把它误读为「用户最新输入」(末尾 user 有强指令语义)。
        let annotated = "以下为系统环境信息快照,非用户消息,仅供你参考当前时间/挂载/记忆,请继续处理用户的实际请求:\n\n\(merged)"
        result.append(ChatCompletionMessage(role: "user", content: annotated))
        return result
    }

    private static func multimodalParts(of content: MessageContent?) -> [ContentPart]? {
        guard case .parts(let parts) = content else { return nil }
        return parts
    }

    private static func responsesPart(from part: ContentPart) -> ResponsesContentPart? {
        switch part {
        case .text(let t): return .inputText(t)
        case .imageURL(let url, let detail):
            return .inputImage(url: url, detail: detail == "auto" ? nil : detail)
        case .inputAudio(let data, let format):
            return .inputAudio(data: data, format: format)
        case .file(let fd, let fid, let fn):
            return .inputFile(fileData: fd, fileId: fid, filename: fn)
        }
    }

    // MARK: - 错误分类(参考 mapHTTPError)

    func classifyHTTPError(statusCode: Int, body: String) -> LLMError? {
        // 优先提取服务商 error.message(比整段 body 更可读)。
        let message: String? = {
            guard let data = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let nested = obj["error"] as? [String: Any]
            return nested?["message"] as? String ?? obj["message"] as? String
        }()
        let fallback = message ?? body
        switch statusCode {
        case 401, 403:
            return .providerRejected(fallback.isEmpty ? "认证失败(401/403):请检查 API Key" : fallback)
        case 429:
            return .rateLimited
        case 400:
            return .providerRejected(fallback.isEmpty ? "请求被拒绝(400)" : fallback)
        default:
            if statusCode >= 500 {
                return .providerRejected("服务端错误(\(statusCode)): \(String(fallback.prefix(300)))")
            }
            return nil
        }
    }
}

// MARK: - OpenAI SSE 流解析器

/// OpenAI 兼容 SSE 流解析(每请求一个实例,自含累积状态)。
/// 继承了 LLMClient 传输层修复的全部质量要求:
/// - Data 级行缓冲(UTF-8 多字节跨 chunk 不丢字);
/// - 收尾处理残留行(服务端最后一块数据常无尾随 \n);
/// - [DONE] 完整性判定(缺失 → streamTruncated,不静默当成功);
/// - 终态 invalidate session(防泄漏)。
final class OpenAIStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let config: OpenAICompatConfig
    /// 本次请求实际生效的协议格式(供应商/模型级回落后的结果,与 body/URL 一致)。
    /// 解析分支必须用它,而不是 config.format——否则 DeepSeek 模型级回落组合下
    /// body=chat 却按 responses 解析,全帧丢弃报 decodingFailed。
    let effectiveFormat: APIFormat
    weak var session: URLSession?

    var onEvent: ((LLMStreamEvent) -> Void)?
    var onFinish: ((Result<Void, Error>) -> Void)?

    /// 跨 chunk 累积的原始字节行缓冲。
    private var dataBuffer = Data()
    private var didFinish = false
    private var receivedDoneEvent = false
    private var capturedFinishReason: String?
    private var capturedUsage: (input: Int, output: Int, cachedRead: Int, cachedWrite: Int)?
    private var parsedEventCount = 0
    /// chatCompletions 工具调用累积(index → 片段)。
    private var accumulatedToolCalls: [String: (id: String, name: String, arguments: String)] = [:]
    /// responses 工具调用累积(item_id → 片段)。
    private var responsesToolCalls: [String: (callId: String, name: String, arguments: String)] = [:]
    /// HTTP 状态码与响应体(错误分类用)。
    private var responseStatusCode: Int?
    private var responseBody = Data()
    /// 已收到的字节数(空响应判定)。
    private var receivedBytes = 0
    /// 是否产出过有效内容(token/工具调用/完成原因)。
    private var meaningfulOutput = false
    /// chatCompletions 工具调用首次出现顺序(旧路径 toolCallKeyOrder 语义)。
    private var toolCallOrder: [String] = []
    /// 错误分类闭包(由适配器注入,单一实现)。
    private let errorClassifier: (Int, String) -> LLMError?

    init(config: OpenAICompatConfig, effectiveFormat: APIFormat, errorClassifier: @escaping (Int, String) -> LLMError?) {
        self.config = config
        self.effectiveFormat = effectiveFormat
        self.errorClassifier = errorClassifier
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !didFinish,
              let http = response as? HTTPURLResponse else { return }
        responseStatusCode = http.statusCode
        AppLogger.shared.info("适配器响应 status=\(http.statusCode)", category: "LLMClient", subsystem: "Adapter")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !didFinish else { return }
        receivedBytes += data.count
        // 响应体仅用于 HTTP 错误分类;上限保护防止异常网关无界累积。
        if responseBody.count < 65_536 {
            responseBody.append(data.prefix(65_536 - responseBody.count))
        }
        // Data 级行缓冲:先追加字节,再按 \n 切出完整行、逐行解码。
        // 多字节 UTF-8 字符(中文/emoji)跨 chunk 边界时,单块解码会失败丢字——Data 域切行杜绝此问题。
        // 上限保护:异常网关持续发送无换行大块数据时防止无界累积。
        if dataBuffer.count + data.count > 1_048_576 {
            return
        }
        dataBuffer.append(data)
        let newline = Data([0x0A])
        while let range = dataBuffer.range(of: newline) {
            let lineData = dataBuffer.subdata(in: dataBuffer.startIndex..<range.lowerBound)
            dataBuffer.removeSubrange(dataBuffer.startIndex...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                processSSELine(line)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !didFinish else { return }
        // 终态判定顺序与旧内联路径一致:
        // 连接错误 → HTTP 状态码分类 → 空响应(noData) → 零有效事件(decodingFailed) → [DONE] 完整性。
        if let error {
            // 失败/取消:直接结束(取消是瞬时错误,由引擎重试链路接管)
            finish(failure: error)
            return
        }
        if let statusCode = responseStatusCode, statusCode >= 400 {
            let bodyText = String(data: responseBody.prefix(240), encoding: .utf8) ?? ""
            let classified = errorClassifier(statusCode, bodyText)
                ?? LLMError.invalidResponse(statusCode)
            finish(failure: classified)
            return
        }
        if receivedBytes == 0 {
            finish(failure: LLMError.noData)
            return
        }
        if parsedEventCount == 0 {
            finish(failure: LLMError.decodingFailed)
            return
        }
        if !meaningfulOutput {
            finish(failure: LLMError.noData)
            return
        }
        // 收尾:处理缓冲区残留行——服务端最后一块数据常无尾随 \n,
        // 直接清空会丢失末行(末尾 token / usage / [DONE])。
        if !dataBuffer.isEmpty {
            if let line = String(data: dataBuffer, encoding: .utf8) {
                processSSELine(line)
            }
            dataBuffer.removeAll()
        }
        // 完整性判定:OpenAI 兼容流必须收到 [DONE],未收到即视为截断
        // (网关超时/服务端崩溃),不能静默当成功。
        if !receivedDoneEvent {
            finish(failure: LLMError.streamTruncated)
            return
        }
        finish(failure: nil)
    }

    // MARK: - SSE 行处理

    private func processSSELine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            receivedDoneEvent = true
            return
        }
        guard !payload.isEmpty,
              let jsonData = payload.data(using: .utf8) else { return }
        if effectiveFormat == .responsesAPI {
            processResponsesLine(jsonData)
        } else {
            processChatCompletionsLine(jsonData)
        }
    }

    private func processChatCompletionsLine(_ jsonData: Data) {
        // 优先从原始 JSON 直接解析 usage(绕过结构体解码,确保缓存字段不丢)。
        if let usage = Self.extractUsageFromRaw(jsonData) {
            capturedUsage = usage
        }
        guard let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: jsonData) else {
            return
        }
        parsedEventCount += 1
        meaningfulOutput = true
        for choice in chunk.choices ?? [] {
            if let fr = choice.finishReason, !fr.isEmpty {
                capturedFinishReason = fr
            }
            if let content = choice.delta?.content, !content.isEmpty {
                onEvent?(.token(content))
            }
            // 思考过程:兼容 reasoning_content(DeepSeek/智谱/千问)与 reasoning(xAI Grok/OpenAI 新协议)。
            let deltaReasoning = choice.delta?.reasoning ?? choice.delta?.reasoningContent
            if let reasoning = deltaReasoning, !reasoning.isEmpty {
                onEvent?(.reasoning(reasoning))
            }
            if let toolCalls = choice.delta?.toolCalls, !toolCalls.isEmpty {
                for tc in toolCalls {
                    let index = tc.index ?? 0
                    let key = "\(index)"
                    if accumulatedToolCalls[key] == nil {
                        accumulatedToolCalls[key] = (id: tc.id ?? "", name: "", arguments: "")
                        toolCallOrder.append(key)
                    }
                    if let id = tc.id, !id.isEmpty {
                        accumulatedToolCalls[key]?.id = id
                    }
                    if let name = tc.function?.name ?? tc.name, !name.isEmpty {
                        // 与旧路径一致:工具名去除首尾空白后再入参。
                        accumulatedToolCalls[key]?.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let args = tc.function?.arguments ?? tc.arguments {
                        accumulatedToolCalls[key]?.arguments += args
                    }
                }
            }
            // 兼容旧式 delta.function_call:没有 tool_calls 数组、也没有 call id/index。
            if let legacy = choice.delta?.functionCall {
                let key = "legacy-\(choice.index ?? 0)"
                if accumulatedToolCalls[key] == nil {
                    accumulatedToolCalls[key] = (id: "legacy_\(choice.index ?? 0)", name: "", arguments: "")
                    toolCallOrder.append(key)
                }
                if let name = legacy.name, !name.isEmpty {
                    accumulatedToolCalls[key]?.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let args = legacy.arguments {
                    accumulatedToolCalls[key]?.arguments += args
                }
            }
        }
    }

    private func processResponsesLine(_ jsonData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = obj["type"] as? String else { return }
        parsedEventCount += 1
        meaningfulOutput = true
        switch type {
        case "response.output_text.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                onEvent?(.token(delta))
            }
        case "response.reasoning_text.delta", "response.reasoning.delta":
            // 思考增量:OpenAI 官方/DeepSeek/小米 为 reasoning_text.delta;
            // OpenRouter 为 reasoning.delta(厂商事件名差异,见厂商适配纪律)。
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                onEvent?(.reasoning(delta))
            }
        case "response.output_item.added":
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let itemId = "\(obj["item_id"] ?? item["id"] ?? UUID().uuidString)"
                let callId = (item["call_id"] as? String) ?? itemId
                let name = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let arguments = (item["arguments"] as? String) ?? ""
                responsesToolCalls[itemId] = (callId: callId, name: name, arguments: arguments)
            }
        case "response.function_call_arguments.delta":
            if let itemId = obj["item_id"] as? String,
               let delta = obj["delta"] as? String {
                responsesToolCalls[itemId]?.arguments += delta
            }
        case "response.output_item.done":
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let itemId = "\(obj["item_id"] ?? item["id"] ?? "")"
                let accumulated = responsesToolCalls[itemId]
                let callId = (item["call_id"] as? String) ?? accumulated?.callId ?? itemId
                let name = (item["name"] as? String) ?? accumulated?.name ?? ""
                let arguments = (item["arguments"] as? String) ?? accumulated?.arguments ?? ""
                if !callId.isEmpty {
                    onEvent?(.toolCall(ToolCall(
                        id: callId,
                        type: "function",
                        function: ToolCall.ToolCallFunction(name: name, arguments: arguments)
                    )))
                }
                responsesToolCalls.removeValue(forKey: itemId)
            }
        case "response.completed":
            receivedDoneEvent = true
            if let resp = obj["response"] as? [String: Any],
               let usage = resp["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let cached = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                capturedUsage = (input: input, output: output, cachedRead: cached, cachedWrite: 0)
            }
        case "response.done":
            // OpenRouter 收尾事件(OpenAI 族为 response.completed,见厂商适配纪律);
            // 后面通常还有 data: [DONE],此处置位即可。
            receivedDoneEvent = true
        case "response.failed":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "响应生成失败"
            finish(failure: LLMError.providerRejected(msg))
        default:
            break
        }
    }

    private static func extractUsageFromRaw(_ jsonData: Data) -> (input: Int, output: Int, cachedRead: Int, cachedWrite: Int)? {
        guard let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let u = dict["usage"] as? [String: Any] else { return nil }
        let prompt = (u["prompt_tokens"] as? Int) ?? 0
        let completion = (u["completion_tokens"] as? Int) ?? 0
        let details = u["prompt_tokens_details"] as? [String: Any]
        let cachedTokens = (details?["cached_tokens"] as? Int) ?? 0
        let cacheCreation = (details?["cache_creation_tokens"] as? Int) ?? 0
        let hit = (u["prompt_cache_hit_tokens"] as? Int) ?? 0
        let miss = (u["prompt_cache_miss_tokens"] as? Int) ?? 0
        let cachedRead = max(cachedTokens, hit)
        let cachedWrite = max(cacheCreation, miss)
        // 仅当确有用量时才返回,避免普通内容帧(无 usage)误覆盖。
        if prompt == 0, completion == 0, cachedRead == 0, cachedWrite == 0 { return nil }
        return (prompt, completion, cachedRead, cachedWrite)
    }

    // MARK: - 终态

    /// 唯一终态出口:成功/失败/取消都必须经过这里,且只执行一次。
    private func finish(failure: Error?) {
        guard !didFinish else { return }
        didFinish = true
        // 终态释放 session + delegate + 闭包链(防泄漏)。
        defer { session?.finishTasksAndInvalidate() }

        // 无论成败都先回传已捕获的 finishReason 与用量(与旧路径一致):
        // max_tokens 截断 + 断连的组合下,引擎续写兜底依赖 finishReason 已收到。
        onEvent?(.finishReason(capturedFinishReason))
        if let usage = capturedUsage {
            onEvent?(.usage(prompt: usage.input, completion: usage.output, cachedRead: usage.cachedRead, cachedWrite: usage.cachedWrite))
        }
        if let failure {
            onFinish?(.failure(failure))
            return
        }
        // 成功:按首次出现顺序统一发出累积的工具调用(旧路径 toolCallKeyOrder 语义)。
        for key in toolCallOrder {
            if let tc = accumulatedToolCalls[key] {
                onEvent?(.toolCall(ToolCall(
                    id: tc.id,
                    type: "function",
                    function: ToolCall.ToolCallFunction(name: tc.name, arguments: tc.arguments)
                )))
            }
        }
        onFinish?(.success(()))
    }
}
