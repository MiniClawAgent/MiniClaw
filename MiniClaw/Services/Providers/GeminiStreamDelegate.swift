import Foundation

// MARK: - Gemini SSE 流解析器

/// Gemini 流解析(每请求一个实例)。传输层质量与 OpenAI 适配器一致;
/// **完整性判定豁免:官方协议无终帧哨兵,连接正常关闭即完成**。
final class GeminiStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let config: GeminiCompatConfig
    weak var session: URLSession?

    var onEvent: ((LLMStreamEvent) -> Void)?
    var onFinish: ((Result<Void, Error>) -> Void)?

    private var dataBuffer = Data()
    private var didFinish = false
    private var capturedFinishReason: String?
    private var capturedUsage: (input: Int, output: Int, cachedRead: Int, cachedWrite: Int)?
    private var parsedEventCount = 0
    private var meaningfulOutput = false
    private var responseStatusCode: Int?
    private var responseBody = Data()
    private var receivedBytes = 0
    /// 工具调用累积(index → 片段),finish 时统一发出。
    private var geminiToolCalls: [String: (name: String, arguments: String)] = [:]
    private var geminiToolCallIndex = 0
    private let errorClassifier: (Int, String) -> LLMError?

    init(config: GeminiCompatConfig, errorClassifier: @escaping (Int, String) -> LLMError?) {
        self.config = config
        self.errorClassifier = errorClassifier
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !didFinish, let http = response as? HTTPURLResponse else { return }
        responseStatusCode = http.statusCode
        AppLogger.shared.info("适配器响应 provider=Gemini status=\(http.statusCode)", category: "LLMClient", subsystem: "Adapter")
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
        // 收尾:处理残留行。
        if !dataBuffer.isEmpty {
            if let line = String(data: dataBuffer, encoding: .utf8) {
                processSSELine(line)
            }
            dataBuffer.removeAll()
        }
        // 完整性判定豁免:Gemini 官方协议无 [DONE]/message_stop 哨兵,
        // 连接正常关闭即完成——不检查 receivedDoneEvent。
        finish(failure: nil)
    }

    // MARK: SSE 行处理

    private func processSSELine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data: ") else { return }
        let jsonStr = String(trimmed.dropFirst(6))
        guard let jsonData = jsonStr.data(using: .utf8) else { return }
        processGeminiLine(jsonData)
    }

    private func processGeminiLine(_ jsonData: Data) {
        guard let obj = try? JSONDecoder().decode(GeminiGenerateContentResponse.self, from: jsonData) else { return }
        parsedEventCount += 1
        // 捕获真实用量(promptTokenCount / candidatesTokenCount / 隐式缓存命中)。
        if let usage = obj.usageMetadata {
            let input = usage.promptTokenCount ?? 0
            let output = usage.candidatesTokenCount ?? usage.totalTokenCount ?? 0
            let cached = usage.cachedContentTokenCount ?? 0
            capturedUsage = (input: input, output: output, cachedRead: cached, cachedWrite: 0)
        }
        for candidate in obj.candidates ?? [] {
            // MAX_TOKENS 表示被截断,归一化为 max_tokens 以便引擎统一判断。
            if let fr = candidate.finishReason, !fr.isEmpty {
                capturedFinishReason = (fr == "MAX_TOKENS") ? "max_tokens" : fr.lowercased()
            }
            guard let parts = candidate.content?.parts else { continue }
            for part in parts {
                if let text = part.text, !text.isEmpty {
                    meaningfulOutput = true
                    onEvent?(.token(text))
                }
                if let fc = part.functionCall, let name = fc.name, !name.isEmpty {
                    meaningfulOutput = true
                    let argsString: String
                    if let args = fc.args {
                        argsString = (try? JSONEncoder().encode(args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    } else {
                        argsString = "{}"
                    }
                    let key = "\(geminiToolCallIndex)"
                    geminiToolCallIndex += 1
                    geminiToolCalls[key] = (name: name, arguments: argsString)
                }
            }
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
        // 成功:按出现顺序统一发出累积的 functionCall 工具调用(与旧实现一致)。
        for key in geminiToolCalls.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            guard let tc = geminiToolCalls[key] else { continue }
            let trimmedName = tc.name.trimmingCharacters(in: .whitespacesAndNewlines)
            onEvent?(.toolCall(ToolCall(
                id: "gemini_\(key)",
                type: "function",
                function: ToolCall.ToolCallFunction(name: trimmedName, arguments: tc.arguments)
            )))
        }
        onFinish?(.success(()))
    }
}

