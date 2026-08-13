import Foundation

/// 分页读取子代理的完整最终回答。
/// `dispatch_subagent` 只回有界预览（保证父上下文不被撑爆）；当需要子代理结果的
/// 完整内容（长文/报告全文）时，用本工具按 subagent_id + 字符偏移分页读取。
/// 数据来自 SubagentStore（子代理对话已落盘持久化）。
final class ReadSubagentResultTool: AgentTool {
    private let sessionID: UUID?

    init(currentSessionID: UUID?) {
        self.sessionID = currentSessionID
    }

    var name: String { "read_subagent_result" }

    var schema: ToolSchema {
        ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: name,
                description: L10n.l("read_subagent_result_tool_desc"),
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "subagent_id": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_close_subagent_id")),
                        "offset": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_read_offset")),
                        "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_read_length"))
                    ],
                    required: ["subagent_id"]
                )
            )
        )
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let sidStr = parameters["subagent_id"] as? String,
              let subagentID = UUID(uuidString: sidStr) else {
            return ToolResult(success: false, text: L10n.l("err_read_result_need_id"))
        }
        let offset = (parameters["offset"] as? Int) ?? 0
        let limit = min((parameters["limit"] as? Int) ?? 4000, 20000)
        guard offset >= 0, limit > 0 else {
            return ToolResult(success: false, text: L10n.l("err_offset_limit_invalid"))
        }

        let sessionID = self.sessionID
        let (found, full, total) = await MainActor.run {
            guard let sessionID,
                  let conv = SubagentStore.shared.conversation(for: sessionID, subagentID: subagentID) else {
                return (false, "", 0)
            }
            let text = conv.messages.filter { $0.role == .response }.map(\.text).joined(separator: "\n\n")
            return (true, text, text.count)
        }

        guard found else {
            return ToolResult(success: false,
                              text: String(format: L10n.l("read_result_not_found"), sidStr))
        }
        guard offset < total else {
            return ToolResult(success: true, text: String(format: L10n.l("read_result_offset_exceeded"), total, offset))
        }
        let start = full.index(full.startIndex, offsetBy: offset, limitedBy: full.endIndex) ?? full.endIndex
        let end = full.index(start, offsetBy: limit, limitedBy: full.endIndex) ?? full.endIndex
        let chunk = String(full[start..<end])
        return ToolResult(success: true,
                          text: String(format: L10n.l("read_result_page"), offset, offset + chunk.count, total, chunk))
    }
}
