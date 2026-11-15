import Foundation

/// `ask_user`：AI 遇到只有用户能决定的事（选项、确认、缺失信息）时向用户提问。
///
/// 行为（P0，按唐唐 2026-11-16 决策）：
/// - **阻塞等待**：工具挂起，直到用户提交 / 跳过 / 超时（10 分钟） / 被取消；
/// - 一次最多 4 个问题、每题最多 6 个选项；同会话同时只允许 1 个待答；
/// - 子代理**禁止**调用（它的问题必须写进最终结果，由父级来问）。
struct AskUserTool: AgentTool {
    let name = "ask_user"
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "ask_user",
            description: String(localized: "ask_user_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    // 嵌套数组用 description 说明结构（JSONSchema 的 items 支持有限，
                    // 这里不对模型做严格 schema 校验，限制由工具内部硬校验兜住）。
                    "questions": JSONSchema.JSONProperty(
                        type: "array",
                        description: String(localized: "ask_user_param_questions")
                    ),
                    "timeout": JSONSchema.JSONProperty(type: "number", description: String(localized: "ask_user_param_timeout")),
                ],
                required: ["questions"]
            )
        )
    )

    /// 把各种"看起来像问题列表"的入参归一化成 `[[String: Any]]`。
    static func normalizeQuestions(_ parameters: [String: Any]) -> [[String: Any]]? {
        func asArray(_ value: Any?) -> [[String: Any]]? {
            if let arr = value as? [[String: Any]] { return arr }
            if let arr = value as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
            if let str = value as? String,
               let data = str.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                return asArray(obj)
            }
            if let dict = value as? [String: Any] { return [dict] }
            return nil
        }
        if let q = asArray(parameters["questions"]), !q.isEmpty { return q }
        // 单数形式 `question`（字符串）：包成一个默认问题
        if let text = (parameters["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return [["id": "q1", "question": text]]
        }
        return nil
    }

    /// 错误里回显原文时做最小转义（只用于诊断，不参与业务）。
    static func escapeForJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let engine = ToolEngineScope.engine, let callID = ToolEngineScope.callID else {
            return ToolResult(success: false, text: #"{"error":"no_engine_context"}"#)
        }
        // 子代理不能直接问用户：它没有可见的会话界面。
        if engine.isSubagentEngine {
            return ToolResult(success: false, text: #"{"error":"delegated_caller"}"#)
        }
        guard let sessionID = currentSessionID else {
            return ToolResult(success: false, text: #"{"error":"no_session"}"#)
        }

        // ── 解析与硬校验（不指望模型自觉）──
        //
        // 小模型（NeoHorse 1 9B）实测会把 `questions` 写成**字符串化的 JSON**、
        // 或者只给一个对象、或者用单数 `question`。真机 01:41 的 `no_questions`
        // 就是严格 `as? [[String: Any]]` 解析不出来导致的（工具 1ms 即失败）。
        // 这里做宽松归一化，任何"能看出意图"的写法都接住。
        guard let rawQuestions = Self.normalizeQuestions(parameters), !rawQuestions.isEmpty else {
            let preview = String(String(describing: parameters).prefix(400))
            AppLogger.shared.warn("[AskUser] unparsable args: \(preview)", category: "Agent", subsystem: "AgentLoop")
            return ToolResult(
                success: false,
                text: #"{"error":"no_questions","hint":"questions 必须是数组，例如 {\"questions\":[{\"id\":\"q1\",\"question\":\"...\",\"options\":[{\"label\":\"...\"}]}]}","received":"\#(Self.escapeForJSON(preview))"}"#
            )
        }
        guard rawQuestions.count <= 4 else {
            return ToolResult(success: false, text: #"{"error":"too_many_questions","max":4}"#)
        }

        var questions: [UserQuestion] = []
        var seen = Set<String>()
        for (index, raw) in rawQuestions.enumerated() {
            // 字段名容错：小模型常写 text/title/prompt，或干脆不写 id。
            func firstString(_ keys: [String]) -> String? {
                for k in keys {
                    if let v = raw[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return v.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return nil
            }
            let id = firstString(["id", "key", "name"]) ?? "q\(index + 1)"
            guard let text = firstString(["question", "text", "title", "prompt", "q"]) else {
                return ToolResult(success: false, text: #"{"error":"invalid_question","hint":"each item needs a non-empty question string"}"#)
            }
            guard !seen.contains(id) else {
                return ToolResult(success: false, text: #"{"error":"duplicate_question_id"}"#)
            }
            seen.insert(id)

            var options: [UserQuestionOption]?
            if let rawOptions = raw["options"] as? [[String: Any]], !rawOptions.isEmpty {
                guard rawOptions.count <= 6 else {
                    return ToolResult(success: false, text: #"{"error":"too_many_options","max":6}"#)
                }
                options = rawOptions.compactMap { o in
                    let label = (o["label"] as? String) ?? (o["text"] as? String) ?? (o["title"] as? String) ?? (o["value"] as? String)
                    guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                    return UserQuestionOption(label: String(label.prefix(60)), description: o["description"] as? String)
                }
                if options?.isEmpty ?? true {
                    return ToolResult(success: false, text: #"{"error":"invalid_options"}"#)
                }
            } else if let stringOptions = raw["options"] as? [String], !stringOptions.isEmpty {
                // 纯字符串数组：["A 版", "B 版"]
                options = stringOptions.prefix(6).compactMap { label in
                    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    return UserQuestionOption(label: String(trimmed.prefix(60)), description: nil)
                }
            }

            questions.append(UserQuestion(
                id: id,
                question: String(text.prefix(200)),
                detail: raw["detail"] as? String,
                header: raw["header"] as? String,
                options: options,
                multiSelect: raw["multiSelect"] as? Bool,
                allowCustom: options == nil ? true : (raw["allowCustom"] as? Bool ?? true)
            ))
        }

        let request = UserQuestionRequest(
            callId: callID,
            questions: questions,
            answers: nil,
            state: .pending,
            createdAt: Date()
        )

        // 把这次工具调用的块换成"问题卡"，并写入请求载荷。
        await MainActor.run {
            guard let block = engine.blockForToolCall(callID) else { return }
            block.kind = .question(callId: callID)
            block.content = request.encoded()
        }

        let outcome = await AskUserBroker.shared.request(request, sessionID: sessionID)

        var final = request
        switch outcome {
        case .answered(let answers):
            final.answers = answers
            final.state = .answered
        case .skipped:
            final.answers = []
            final.state = .skipped
        case .timedOut:
            final.answers = []
            final.state = .expired
        case .cancelled:
            final.answers = []
            final.state = .cancelled
        }

        await MainActor.run {
            engine.blockForToolCall(callID)?.content = final.encoded()
        }

        return ToolResult(success: final.state == .answered || final.state == .skipped,
                          text: final.modelFacingJSON)
    }
}
