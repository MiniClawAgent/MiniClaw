import Foundation

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
    /// 工具参数流式增量上抛的节流（key → 上次上抛时间）。
    private var streamingEmitTimes: [String: Date] = [:]
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
            // [2026-09-11 诊断增强] 把服务端错误体写入日志。此前只记 `status=xxx`
            //（见 didReceive response），排查「子代理报 400」时拿不到任何原因，只能靠猜。
            // 400/422 的 body 通常直接点明请求哪里不合法（如 tool_calls 未配对、
            // assistant content 为空串、字段非法），是定位的唯一线索。
            AppLogger.shared.warn(
                "适配器错误详情 status=\(statusCode) body=\(bodyText)",
                category: "LLMClient", subsystem: "Adapter")
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
                        // 参数流式增量上抛（0.15s 节流）：卡片实时显示 AI 正在生成的内容。
                        let acc = accumulatedToolCalls[key]!
                        let now = Date()
                        let last = streamingEmitTimes[key] ?? .distantPast
                        if now.timeIntervalSince(last) >= 0.15, !acc.name.isEmpty {
                            streamingEmitTimes[key] = now
                            onEvent?(.toolCallStreaming(id: acc.id.isEmpty ? key : acc.id,
                                                        name: acc.name,
                                                        partialArgs: acc.arguments,
                                                        bytes: acc.arguments.utf8.count))
                        }
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
                    let acc = accumulatedToolCalls[key]!
                    let now = Date()
                    let last = streamingEmitTimes[key] ?? .distantPast
                    if now.timeIntervalSince(last) >= 0.15, !acc.name.isEmpty {
                        streamingEmitTimes[key] = now
                        onEvent?(.toolCallStreaming(id: acc.id.isEmpty ? key : acc.id,
                                                    name: acc.name,
                                                    partialArgs: acc.arguments,
                                                    bytes: acc.arguments.utf8.count))
                    }
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
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? String(localized: "err_generation_failed")
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
                // id 兜底与 streaming emit 一致（兼容端点 delta 常不回传 id）：
                // 否则 streaming 占位（callID=key）与定稿（callID=""）配对失败，
                // 占位永远 running + 定稿重复 append（2026-09-03 实锤：browser 工具
                // 「执行中不刷新 + 重进后多出三个完成态」的根因）。
                onEvent?(.toolCall(ToolCall(
                    id: tc.id.isEmpty ? key : tc.id,
                    type: "function",
                    function: ToolCall.ToolCallFunction(name: tc.name, arguments: tc.arguments)
                )))
            }
        }
        onFinish?(.success(()))
    }
}

