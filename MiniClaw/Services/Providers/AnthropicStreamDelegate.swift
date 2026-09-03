import Foundation

// MARK: - Anthropic SSE 流解析器

/// Anthropic SSE 流解析(每请求一个实例)。传输层质量与 OpenAI 适配器一致:
/// Data 级行缓冲 / 30s-120s 超时 / 终态单出口 + invalidate / 失败也回传 finishReason+usage。
final class AnthropicStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let config: AnthropicCompatConfig
    weak var session: URLSession?

    var onEvent: ((LLMStreamEvent) -> Void)?
    /// 工具参数流式增量上抛的节流（idx → 上次上抛时间）。
    private var streamingEmitTimes: [Int: Date] = [:]
    var onFinish: ((Result<Void, Error>) -> Void)?

    private var dataBuffer = Data()
    private var currentEvent = ""
    private var didFinish = false
    private var receivedDoneEvent = false
    private var capturedFinishReason: String?
    private var capturedUsage: (input: Int, output: Int, cachedRead: Int, cachedWrite: Int)?
    private var parsedEventCount = 0
    private var meaningfulOutput = false
    private var responseStatusCode: Int?
    private var responseBody = Data()
    private var receivedBytes = 0
    /// 工具调用累积(index → 片段)。
    private var accumulatedToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
    private let errorClassifier: (Int, String) -> LLMError?

    init(config: AnthropicCompatConfig, errorClassifier: @escaping (Int, String) -> LLMError?) {
        self.config = config
        self.errorClassifier = errorClassifier
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !didFinish, let http = response as? HTTPURLResponse else { return }
        responseStatusCode = http.statusCode
        AppLogger.shared.info("适配器响应 provider=Anthropic status=\(http.statusCode)", category: "LLMClient", subsystem: "Adapter")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !didFinish else { return }
        receivedBytes += data.count
        if responseBody.count < 65_536 {
            responseBody.append(data.prefix(65_536 - responseBody.count))
        }
        if dataBuffer.count + data.count > 1_048_576 { return }
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
        if let error {
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
        // 收尾:处理残留行(最后一块数据常无尾随 \n)。
        if !dataBuffer.isEmpty {
            if let line = String(data: dataBuffer, encoding: .utf8) {
                processSSELine(line)
            }
            dataBuffer.removeAll()
        }
        // 完整性判定:必须收到 message_stop。
        if !receivedDoneEvent {
            finish(failure: LLMError.streamTruncated)
            return
        }
        finish(failure: nil)
    }

    // MARK: SSE 行处理

    private func processSSELine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("event: ") {
            currentEvent = String(trimmed.dropFirst(7))
            return
        }
        guard trimmed.hasPrefix("data: ") else { return }
        let jsonStr = String(trimmed.dropFirst(6))
        guard let jsonData = jsonStr.data(using: .utf8) else { return }
        processAnthropicEvent(currentEvent, jsonData: jsonData)
        currentEvent = ""
    }

    private func processAnthropicEvent(_ event: String, jsonData: Data) {
        guard let obj = try? JSONDecoder().decode(AnthropicSSEEvent.self, from: jsonData) else { return }
        parsedEventCount += 1

        switch event {
        case "message_start":
            if let usage = obj.message?.usage ?? obj.usage {
                let input = usage.inputTokens ?? capturedUsage?.input ?? 0
                let cachedRead = usage.cacheReadInputTokens ?? capturedUsage?.cachedRead ?? 0
                let cachedWrite = usage.cacheCreationInputTokens ?? capturedUsage?.cachedWrite ?? 0
                capturedUsage = (input: input, output: capturedUsage?.output ?? 0, cachedRead: cachedRead, cachedWrite: cachedWrite)
            }
        case "content_block_delta":
            guard let delta = obj.delta else { return }
            switch delta.type {
            case "thinking_delta":
                if let thinking = delta.thinking, !thinking.isEmpty {
                    meaningfulOutput = true
                    onEvent?(.reasoning(thinking))
                }
            case "text_delta":
                if let text = delta.text, !text.isEmpty {
                    meaningfulOutput = true
                    onEvent?(.token(text))
                }
            case "input_json_delta":
                if let json = delta.partialJson, !json.isEmpty {
                    meaningfulOutput = true
                    let idx = obj.index ?? 0
                    accumulatedToolCalls[idx, default: ("", "", "")].arguments += json
                    // 参数流式增量上抛（0.15s 节流）：卡片实时显示 AI 正在生成的内容。
                    let acc = accumulatedToolCalls[idx]!
                    let now = Date()
                    let last = streamingEmitTimes[idx] ?? .distantPast
                    if now.timeIntervalSince(last) >= 0.15, !acc.name.isEmpty {
                        streamingEmitTimes[idx] = now
                        onEvent?(.toolCallStreaming(id: acc.id.isEmpty ? String(idx) : acc.id,
                                                    name: acc.name,
                                                    partialArgs: acc.arguments,
                                                    bytes: acc.arguments.utf8.count))
                    }
                }
            default:
                break
            }
        case "content_block_start":
            guard let block = obj.contentBlock else { return }
            if block.type == "tool_use", let id = block.id, let name = block.name {
                let idx = obj.index ?? accumulatedToolCalls.count
                accumulatedToolCalls[idx] = (id: id, name: name, arguments: "")
            }
        case "content_block_stop":
            break
        case "message_delta":
            if let usage = obj.usage {
                // 绝不能把 cachedRead/cachedWrite 重置为 0,否则覆盖 message_start 已上报的缓存命中数。
                let input = capturedUsage?.input ?? 0
                let output = usage.outputTokens ?? capturedUsage?.output ?? 0
                let cachedRead = usage.cacheReadInputTokens ?? capturedUsage?.cachedRead ?? 0
                let cachedWrite = usage.cacheCreationInputTokens ?? capturedUsage?.cachedWrite ?? 0
                capturedUsage = (input: input, output: output, cachedRead: cachedRead, cachedWrite: cachedWrite)
            }
            if let sr = obj.delta?.stopReason, !sr.isEmpty {
                capturedFinishReason = sr
            }
        case "message_stop":
            receivedDoneEvent = true
            // flush accumulated tool calls(与旧实现一致:message_stop 时统一发出)。
            for key in accumulatedToolCalls.keys.sorted() {
                guard let tc = accumulatedToolCalls[key] else { continue }
                // id 兜底与 streaming emit 一致（String(key)）——防配对断裂（同 OpenAI 侧注释）。
                onEvent?(.toolCall(ToolCall(
                    id: tc.id.isEmpty ? String(key) : tc.id,
                    type: "function",
                    function: ToolCall.ToolCallFunction(name: tc.name, arguments: tc.arguments)
                )))
                meaningfulOutput = true
            }
            accumulatedToolCalls.removeAll()
        case "error":
            let msg = obj.error?.message ?? L10n.l("err_anthropic_server")
            finish(failure: LLMError.providerRejected(msg))
        default:
            break
        }
    }

    // MARK: 终态

    private func finish(failure: Error?) {
        guard !didFinish else { return }
        didFinish = true
        defer { session?.finishTasksAndInvalidate() }

        // 无论成败都先回传 finishReason 与用量(与旧实现一致,续写兜底依赖)。
        onEvent?(.finishReason(capturedFinishReason))
        if let usage = capturedUsage {
            onEvent?(.usage(prompt: usage.input, completion: usage.output, cachedRead: usage.cachedRead, cachedWrite: usage.cachedWrite))
        }
        if let failure {
            onFinish?(.failure(failure))
            return
        }
        onFinish?(.success(()))
    }
}

