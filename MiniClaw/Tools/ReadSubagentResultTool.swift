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
                description: "按 subagent_id 分页读取某个子代理的完整最终回答（dispatch_subagent 只返回有界预览）。当需要子代理结果的完整内容（长文、报告全文、详细清单）时使用；offset 翻页可读完整个回答。",
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "subagent_id": JSONSchema.JSONProperty(type: "string", description: "必填：dispatch_subagent 返回结果里的子代理 id。"),
                        "offset": JSONSchema.JSONProperty(type: "integer", description: "可选：读取起始位置（字符偏移），默认 0。"),
                        "limit": JSONSchema.JSONProperty(type: "integer", description: "可选：本次读取长度（字符数），默认 4000，最大 20000。")
                    ],
                    required: ["subagent_id"]
                )
            )
        )
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let sidStr = parameters["subagent_id"] as? String,
              let subagentID = UUID(uuidString: sidStr) else {
            return ToolResult(success: false, text: "Error: read_subagent_result 需要有效的 subagent_id（来自 dispatch_subagent 返回结果）。")
        }
        let offset = (parameters["offset"] as? Int) ?? 0
        let limit = min((parameters["limit"] as? Int) ?? 4000, 20000)
        guard offset >= 0, limit > 0 else {
            return ToolResult(success: false, text: "Error: offset 不能为负，limit 必须大于 0。")
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
                              text: "Error: 找不到 subagent_id=\(sidStr) 的子代理结果（可能已清理或不在当前会话）。")
        }
        guard offset < total else {
            return ToolResult(success: true, text: "（已读完：总长度 \(total) 字符，offset \(offset) 已超出范围）")
        }
        let start = full.index(full.startIndex, offsetBy: offset, limitedBy: full.endIndex) ?? full.endIndex
        let end = full.index(start, offsetBy: limit, limitedBy: full.endIndex) ?? full.endIndex
        let chunk = String(full[start..<end])
        return ToolResult(success: true,
                          text: "子代理结果（\(offset)-\(offset + chunk.count)/\(total) 字符）：\n\(chunk)")
    }
}
