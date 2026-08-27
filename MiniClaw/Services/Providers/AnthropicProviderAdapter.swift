import Foundation

// MARK: - Anthropic 适配器
// 官方:https://docs.anthropic.com/en/api/messages 与 https://docs.anthropic.com/en/api/streaming
//
// 协议要点(官方文档,2026 现状):
// - 端点 `POST https://api.anthropic.com/v1/messages`;认证 `x-api-key` + `anthropic-version: 2023-06-01`;
// - **prompt caching 已 GA,不再需要 prompt-caching-2024-07-31 beta 头**(官方 FAQ 明文,旧实现已移除);
// - SSE 事件序列:message_start → [content_block_start → content_block_delta* → content_block_stop]* →
//   message_delta*(usage 为累计值) → message_stop(终帧);
// - 工具调用:input_json_delta 累积 partial JSON,content_block_stop 时定稿;
// - 思考:4.6 及更早 budget_tokens;4.7+/5 代 adaptive + output_config.effort,
//   5 代/4.6+ 拒绝非默认 temperature/top_p/top_k(400)。

/// Anthropic 适配器配置。
struct AnthropicCompatConfig: Sendable {
    var endpointURL: String
    var apiKey: String
    var customHeaders: [String: String]?
}

final class AnthropicProviderAdapter: LLMProviderAdapter, @unchecked Sendable {
    let name = "Anthropic"
    let config: AnthropicCompatConfig

    init(config: AnthropicCompatConfig) {
        self.config = config
    }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportsResponseFormat: false,
            supportsParallelToolCalls: true,
            supportsSeed: false,
            supportsPromptCaching: true,
            supportsReasoning: true,
            supportedInputModalities: ["text", "image"]
        )
    }

    // MARK: 内置模型目录(Anthropic 官方模型)

    class var builtinModels: [String: BuiltinModelInfo] {
        [

            "claude-fable-5": BuiltinModelInfo(displayName: "Claude Fable 5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "claude-haiku-4-5": BuiltinModelInfo(displayName: "Claude Haiku 4.5", contextWindow: 200000, maxOutputTokens: 64000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "max"], input: ["text", "image"], output: ["text"]),
            "claude-mythos-5": BuiltinModelInfo(displayName: "Claude Mythos 5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "claude-opus-4-5": BuiltinModelInfo(displayName: "Claude Opus 4.5", contextWindow: 200000, maxOutputTokens: 64000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "max"], input: ["text", "image"], output: ["text"]),
            "claude-opus-4-6": BuiltinModelInfo(displayName: "Claude Opus 4.6", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "max"], input: ["text", "image"], output: ["text"]),
            "claude-opus-5": BuiltinModelInfo(displayName: "Claude Opus 5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
            "claude-sonnet-4-5": BuiltinModelInfo(displayName: "Claude Sonnet 4.5", contextWindow: 200000, maxOutputTokens: 64000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "max"], input: ["text", "image"], output: ["text"]),
            "claude-sonnet-4-6": BuiltinModelInfo(displayName: "Claude Sonnet 4.6", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high"], input: ["text", "image"], output: ["text"]),
            "claude-sonnet-5": BuiltinModelInfo(displayName: "Claude Sonnet 5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image"], output: ["text"]),
        ]
    }

    class func modelCapabilities(for modelID: String) -> BuiltinModelInfo? {
        builtinModels[modelID] ?? heuristicCapabilities(for: modelID)
    }

    // MARK: - 请求

    func streamChat(request: LLMStreamRequest) -> LLMStreamHandle {
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
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (k, v) in config.customHeaders ?? [:] {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let body = buildAnthropicBody(request: request)
        guard !body.isEmpty else {
            let stream = AsyncThrowingStream<LLMStreamEvent, Error> { cont in
                cont.finish(throwing: LLMError.encodingFailed)
            }
            return LLMStreamHandle(task: Self.cancelledTask(), events: stream)
        }
        req.httpBody = body

        // 超时与旧内联路径一致(30s 无数据 / 120s 总时长),防流中途挂死。
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 120
        let delegate = AnthropicStreamDelegate(config: config) { [weak self] statusCode, body in
            self?.classifyHTTPError(statusCode: statusCode, body: body)
        }
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        let task = session.dataTask(with: req)
        AppLogger.shared.info("适配器请求发起 provider=Anthropic url=\(config.endpointURL)", category: "LLMClient", subsystem: "Adapter")

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

    // MARK: - Body 构造(迁移自 LLMClient.buildAnthropicBody,行为一致)

    /// 构建 Anthropic Messages API 请求体。
    /// 缓存断点系统(迁移自旧实现,字节稳定前缀设计):
    /// - system 稳定段带 cache_control(易变段绝不夹在 system 与 tools 之间);
    /// - 最后一个 tool 声明 cache_control;
    /// - 「当前 user 之前那条历史消息」打历史断点(独立于 volatile);
    /// - 易变段(时间戳/挂载/记忆)拼到「最后一条 user 消息」末尾,不进缓存前缀。
    /// 采样限制:5 代/4.7+ 模型拒绝非默认 temperature/top_p/top_k(400),构造时置 nil。
    func buildAnthropicBody(request: LLMStreamRequest) -> Data {
        var systemStableText: String = ""
        var systemVolatileText: String = ""
        var anthroMessages: [AnthropicMessage] = []
        // 连续的 tool 结果必须合并进「紧跟 assistant」的同一条 user 消息,
        // 否则并行工具调用时后续 tool_result 会因找不到前序 tool_use 而被 Anthropic 拒(HTTP 400)。
        var pendingToolResults: [AnthropicContentBlock] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            anthroMessages.append(AnthropicMessage(role: "user", content: .blocks(pendingToolResults)))
            pendingToolResults.removeAll()
        }

        func contentBlocks(_ content: MessageContent?) -> AnthropicContent {
            if let parts = LLMClient.multimodalParts(of: content), !parts.isEmpty {
                let blocks = parts.compactMap { LLMClient.anthropicBlock(from: $0) }
                if !blocks.isEmpty { return .blocks(blocks) }
            }
            return .text(content?.asText ?? "")
        }

        for m in request.messages {
            switch m.role {
            case "system", "developer":
                flushToolResults()
                let stable = m.content?.asText ?? ""
                let volatile = m.volatileSuffix ?? ""
                systemStableText = systemStableText.isEmpty ? stable : systemStableText + "\n" + stable
                if !volatile.isEmpty {
                    systemVolatileText = systemVolatileText.isEmpty ? volatile : systemVolatileText + "\n" + volatile
                }
            case "tool":
                if let callId = m.toolCallID {
                    let result = m.content?.asText ?? ""
                    pendingToolResults.append(.toolResult(id: callId, result: result))
                }
            case "user":
                flushToolResults()
                anthroMessages.append(AnthropicMessage(role: "user", content: contentBlocks(m.content)))
            case "assistant":
                flushToolResults()
                if let calls = m.toolCalls, !calls.isEmpty {
                    var blocks: [AnthropicContentBlock] = []
                    if let parts = LLMClient.multimodalParts(of: m.content), !parts.isEmpty {
                        blocks.append(contentsOf: parts.compactMap { LLMClient.anthropicBlock(from: $0) })
                    } else if let text = m.content?.asText, !text.isEmpty {
                        blocks.append(.text(text))
                    }
                    for c in calls {
                        blocks.append(.toolUse(id: c.id, name: c.function.name, input: LLMClient.parseToolArguments(c.function.arguments)))
                    }
                    if !blocks.isEmpty {
                        anthroMessages.append(AnthropicMessage(role: "assistant", content: .blocks(blocks)))
                    }
                } else {
                    anthroMessages.append(AnthropicMessage(role: "assistant", content: contentBlocks(m.content)))
                }
            default:
                break
            }
        }
        flushToolResults()

        var anthroTools: [AnthropicToolDef]?
        if let tools = request.tools, !tools.isEmpty {
            anthroTools = tools.map { t in
                AnthropicToolDef(name: t.function.name, description: t.function.description, inputSchema: t.function.parameters)
            }
            // 在最后一个 tool 上声明 cache_control 断点,让 tools 也进入缓存前缀。
            if let lastIdx = anthroTools?.indices.last {
                anthroTools?[lastIdx].cacheControl = AnthropicCacheControl(type: "ephemeral")
            }
        }

        // 历史消息 cache_control 断点:与「易变段后缀」解耦,独立于 volatile 是否存在。
        if let lastUserIdx = anthroMessages.lastIndex(where: { $0.role == "user" }),
           lastUserIdx > 0 {
            let historyBreakIdx = lastUserIdx - 1
            let marked: AnthropicContent = LLMClient.markCacheBreakpoint(anthroMessages[historyBreakIdx].content)
            anthroMessages[historyBreakIdx] = AnthropicMessage(role: anthroMessages[historyBreakIdx].role, content: marked)
        }

        // 易变段注入:仅当 volatile 非空时,拼到「最后一条 user 消息」末尾。
        if !systemVolatileText.isEmpty,
           let lastUserIdx = anthroMessages.lastIndex(where: { $0.role == "user" }) {
            let merged: AnthropicContent = LLMClient.appendingVolatile(systemVolatileText, to: anthroMessages[lastUserIdx].content)
            anthroMessages[lastUserIdx] = AnthropicMessage(role: anthroMessages[lastUserIdx].role, content: merged)
        }

        var systemBlocks: [AnthropicContentBlock] = []
        if !systemStableText.isEmpty {
            var stableBlock = AnthropicContentBlock(type: "text", text: systemStableText)
            stableBlock.cacheControl = AnthropicCacheControl(type: "ephemeral")
            systemBlocks.append(stableBlock)
        }

        // 深度思考:4.6 及更早用 budget_tokens;4.7+/5 代用 adaptive + output_config.effort。
        let adaptiveGen = LLMClient.isClaudeAdaptiveGen(request.model)
        var effectiveMax = request.maxTokens ?? 4096
        var effectiveTemp = request.temperature
        var effectiveTopP = request.topP
        var thinking: AnthropicThinking?
        var outputConfig: AnthropicOutputConfig?
        let thinkingLevel = request.thinkingLevel

        if adaptiveGen {
            effectiveTemp = nil
            effectiveTopP = nil
            if LLMClient.isClaudeNonDisableable(request.model) {
                // Fable 5 / Mythos 5:思考不可关,且官方明确「不要传 thinking 字段」。
                let eff: String = (thinkingLevel == "off") ? "low" : (thinkingLevel ?? "high")
                if eff == "xhigh" || eff == "max" {
                    effectiveMax = max(effectiveMax, 32000)
                } else if eff == "high" {
                    effectiveMax = max(effectiveMax, 16000)
                }
                outputConfig = AnthropicOutputConfig(effort: eff)
            } else {
                // Sonnet 5 / Opus 5:可 disabled;开启用 adaptive + display:summarized。
                if thinkingLevel == "off" {
                    thinking = .disabled
                } else if let lvl = thinkingLevel, lvl != "off" {
                    thinking = .adaptiveWithDisplay
                    outputConfig = AnthropicOutputConfig(effort: lvl)
                    if lvl == "xhigh" || lvl == "max" {
                        effectiveMax = max(effectiveMax, 32000)
                    } else if lvl == "high" {
                        effectiveMax = max(effectiveMax, 16000)
                    }
                }
            }
        } else {
            if request.reasoningEffort != nil {
                let budget = max(1024, min(effectiveMax / 4, 8000))
                effectiveMax = max(effectiveMax, budget + 2048)
                thinking = .enabled(budget: budget)
                effectiveTemp = nil
            }
        }

        let req = AnthropicRequest(
            model: request.model,
            maxTokens: effectiveMax,
            messages: anthroMessages,
            system: systemBlocks.isEmpty ? nil : systemBlocks,
            stream: true,
            temperature: effectiveTemp,
            topP: effectiveTopP,
            tools: anthroTools,
            thinking: thinking,
            outputConfig: outputConfig
        )
        return (try? JSONEncoder().encode(req)) ?? Data()
    }

    // MARK: - 错误分类

    func classifyHTTPError(statusCode: Int, body: String) -> LLMError? {
        switch statusCode {
        case 401, 403:
            return .providerRejected(body.isEmpty ? L10n.l("err_auth_failed") : body)
        case 429, 529:
            // 429 = 限流;529 = overloaded_error(官方错误码,服务过载,可重试)。
            return .rateLimited
        case 400:
            return .providerRejected(body.isEmpty ? L10n.l("err_request_rejected") : body)
        default:
            if statusCode >= 500 {
                return .providerRejected(String(format: L10n.l("err_server_error"), statusCode, String(body.prefix(300))))
            }
            return nil
        }
    }
}

