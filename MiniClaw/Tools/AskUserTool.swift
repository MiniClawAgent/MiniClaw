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
        guard let rawQuestions = parameters["questions"] as? [[String: Any]], !rawQuestions.isEmpty else {
            return ToolResult(success: false, text: #"{"error":"no_questions"}"#)
        }
        guard rawQuestions.count <= 4 else {
            return ToolResult(success: false, text: #"{"error":"too_many_questions","max":4}"#)
        }

        var questions: [UserQuestion] = []
        var seen = Set<String>()
        for raw in rawQuestions {
            guard let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let text = (raw["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return ToolResult(success: false, text: #"{"error":"invalid_question"}"#)
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
                    guard let label = (o["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                    return UserQuestionOption(label: String(label.prefix(60)), description: o["description"] as? String)
                }
                if options?.isEmpty ?? true {
                    return ToolResult(success: false, text: #"{"error":"invalid_options"}"#)
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
