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
    /// 厂商行为声明（来自 model 插件包 providers.json 的 behavior 块）；
    /// 缺省 = OpenAI 兼容基类默认行为。
    var behavior: ProviderBehaviorDecl? = nil
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
        // 2026-09-01：由 model 插件包的 behavior.capabilities 声明驱动（nil = 基类默认）。
        let c = config.behavior?.capabilities
        return ProviderCapabilities(
            supportsResponseFormat: c?.responseFormat ?? true,
            supportsParallelToolCalls: c?.parallelToolCalls ?? true,
            supportsSeed: c?.seed ?? true,
            supportsPromptCaching: c?.promptCaching ?? false,
            supportsReasoning: c?.reasoning ?? true,
            supportedInputModalities: Set(c?.supportedInputModalities ?? ["text", "image", "audio"])
        )
    }

    // MARK: - 内置模型目录(模型维护并入厂商文件)

    // MARK: - 子类覆写点

    /// 是否在请求体中保留 assistant 消息的 reasoning_content。
    /// 默认 false(OpenAI/Groq/智谱等对未知消息字段容忍度不一,统一剥离保行为不变);
    /// DeepSeek 必须保留(官方硬性要求:带 tools 的后续请求必须回传 reasoning_content,否则 400)。
    var preserveReasoningContent: Bool { config.behavior?.capabilities?.preserveReasoningContent ?? false }

    /// 请求体附加字段:子类注入本厂商的非 OpenAI 标准参数
    /// (如智谱 `thinking`、千问 `enable_thinking`)。返回 nil 表示无附加。
    func extraBodyFields(request: LLMStreamRequest) -> [String: Any]? {
        // 声明驱动：无条件附加字段 + 思考开关参数映射（behavior.thinkingParam）。
        var body: [String: Any] = [:]
        for (k, v) in config.behavior?.extraBody ?? [:] { body[k] = v.foundationValue }
        if let tp = config.behavior?.thinkingParam, !tp.body.isEmpty, let level = request.thinkingLevel {
            if level == "off" {
                if let off = tp.off { body[tp.body] = off.foundationValue }
            } else if let on = tp.on {
                body[tp.body] = on.foundationValue
            }
        }
        return body.isEmpty ? nil : body
    }

    /// 采样参数钳制:子类按官方约束调整参数
    /// (如智谱 temperature ∈ [0,1])。默认不调整。
    func clampSampling(request: inout LLMStreamRequest) {
        // 声明驱动：采样参数约束（behavior.samplingRules）。
        guard let rules = config.behavior?.samplingRules else { return }
        let thinkingOn = request.thinkingLevel != nil && request.thinkingLevel != "off"
        if thinkingOn {
            for name in rules.disableWhenThinking ?? [] {
                switch name {
                case "temperature": request.temperature = nil
                case "top_p": request.topP = nil
                case "frequency_penalty": request.frequencyPenalty = nil
                case "presence_penalty": request.presencePenalty = nil
                default: break
                }
            }
        }
        if let range = rules.temperatureRange, let t = request.temperature {
            request.temperature = min(max(t, range.first ?? t), range.last ?? t)
        }
        if let range = rules.topPRange, let t = request.topP {
            request.topP = min(max(t, range.first ?? t), range.last ?? t)
        }
    }

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
        // [2026-09-15 诊断·临时] 请求体落盘（环转保留最近 3 份）。
        // 目的：把**实际发出去的 body** 存下来，相邻两次请求一 diff ⇒ 第一处不同字节的位置
        // 就是「前缀在哪一段发生变动」的答案。定位完成后删除本块。
        // 落点 = 日志目录（与 AppLogger 同处，便于直接拉取）。
        do {
            if let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let dir = base.appendingPathComponent("MiniClaw/logs", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let stamp = String(format: "%d", Int(Date().timeIntervalSince1970))
                try? body.write(to: dir.appendingPathComponent("reqdump_\(stamp).json"), options: .atomic)
                if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    let dumps = files
                        .filter { $0.lastPathComponent.hasPrefix("reqdump_") }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for old in dumps.dropLast(2) { try? FileManager.default.removeItem(at: old) }
                }
            }
        }
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
        if config.format == .responsesAPI {
            // 回落 1：providerType 协议不支持 Responses（anthropic/gemini 族）。
            if config.providerType.responsesPath == nil { return .chatCompletions }
            // 回落 2：请求模型的插件声明 responsesSupported == false
            //（模型能力数据的唯一事实来源是插件声明，如 DeepSeek v4-pro 暂不支持）。
            if let info = PluginModelCatalog.modelCapabilities(providerType: config.providerType, modelID: request.model),
               info.responsesSupported == false {
                return .chatCompletions
            }
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
        // 2026-08-31 .sortedKeys:Swift JSONEncoder/JSONSerialization 默认不排字典键,
        // 同一 schema 多次编码键序会漂移 → 服务端按原始字节做前缀匹配,tools 段每轮
        // miss(真机日志实锤:8176tok 工具目录命中率为零)。键序确定化是缓存命中的前提。
        guard let jsonData = try? Self.cacheStableEncoder.encode(cc),
              var dict = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return Data()
        }
        // 子类注入非标准参数(智谱 thinking / 千问 enable_thinking 等)。
        if let extra = extraBodyFields(request: adjusted) {
            for (k, v) in extra { dict[k] = v }
        }
        // [2026-09-15 OpenAI 官方合规] 路由粘性键（官方 Cookbook《Prompt Caching 201》§4.4：
        // 「Requests are routed to inference engines based on a hash of the first ~256 tokens…
        // providing a prompt_cache_key … increases routing stickiness」；官方实测 60% → 87%）。
        // 只对官方收录该字段的供应商发送（OpenAI），其余保持不发，避免未知字段 400。
        if let key = adjusted.promptCacheKey, !key.isEmpty, config.providerType.supportsPromptCacheKey {
            dict["prompt_cache_key"] = key
        }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    /// 键序确定的编码器:请求体字节逐轮可复现是提示词前缀缓存的硬前提。
    static let cacheStableEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

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
            } ?? nil,
            // [2026-09-15 OpenAI 官方合规] 路由粘性键：Responses API 同样收录该字段（同上 §4.4）。
            promptCacheKey: (config.providerType.supportsPromptCacheKey && !(request.promptCacheKey ?? "").isEmpty)
                ? request.promptCacheKey : nil
        )
        return (try? Self.cacheStableEncoder.encode(req)) ?? Data()
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
        let annotated = String(format: String(localized: "env_snapshot_note"), merged)
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
            return .providerRejected(fallback.isEmpty ? String(localized: "err_auth_failed") : fallback)
        case 429:
            return .rateLimited
        case 400:
            return .providerRejected(fallback.isEmpty ? String(localized: "err_request_rejected") : fallback)
        default:
            if statusCode >= 500 {
                return .providerRejected(String(format: String(localized: "err_server_error"), statusCode, String(fallback.prefix(300))))
            }
            return nil
        }
    }
}

