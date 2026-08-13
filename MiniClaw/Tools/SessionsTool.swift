import Foundation
import SwiftData

/// sessions_cli（spec 9.4）
/// 对 SwiftData 会话数据库（Session → [Message]）进行 CRUD 操作。
/// 所有数据库访问都在 `MainActor.run` 闭包内经 `SessionManager.shared` 完成，
/// 避免 SwiftData 的 ModelContext 跨 actor 不安全；闭包内完成序列化后只返回 String。
struct SessionsTool: AgentTool {
    let name = "sessions_cli"
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema: ToolSchema = {
        ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: "sessions_cli",
                description: L10n.l("sessions_tool_desc"),
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "command": JSONSchema.JSONProperty(type: "string", description: L10n.l("subcommand_label"), enum: ["list", "get", "create", "delete", "update", "append", "messages", "search"]),
                        "target": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_target_session"), enum: ["current", "explicit"]),
                        "id": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_target_explicit_note")),
                        "title": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_session_title")),
                        "model": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_model_name")),
                        "agentName": JSONSchema.JSONProperty(type: "string", description: L10n.l("agent_display_name_param")),
                        "field": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_update_field_desc")),
                        "value": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_update_value")),
                        "role": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_append_role")),
                        "content": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_message_content_or_keyword")),
                        "keyword": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_search_keyword")),
                        "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_list_limit"))
                    ],
                    required: ["command"]
                )
            )
        )
    }()

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let command = (parameters["command"] as? String) ?? ""
        let target = (parameters["target"] as? String) ?? "current"
        let requestedID = parameters["id"] as? String
        let id: String?
        if target == "explicit" {
            id = requestedID
        } else if command == "delete" {
            id = nil
        } else {
            id = currentSessionID?.uuidString
        }
        let title = parameters["title"] as? String
        let model = parameters["model"] as? String
        let agentName = parameters["agentName"] as? String
        let field = parameters["field"] as? String
        let value = parameters["value"] as? String
        let content = parameters["content"] as? String ?? parameters["keyword"] as? String
        let role = parameters["role"] as? String
        let keyword = parameters["keyword"] as? String ?? content
        let limit = (parameters["limit"] as? Int)
            ?? (parameters["limit"] as? String).flatMap(Int.init)
            ?? 0

        let output = await MainActor.run {
            SessionsCLI.run(command: command,
                            id: id,
                            title: title,
                            model: model,
                            agentName: agentName,
                            field: field,
                            value: value,
                            content: content,
                            role: role,
                            keyword: keyword,
                            limit: limit)
        }

        let failedPrefixes = [
            L10n.l("unknown_command"), L10n.l("not_found"), L10n.l("missing_label"), L10n.l("err_create_session_failed"),
            L10n.l("update_requires"), L10n.l("append_requires"), L10n.l("search_requires")
        ]
        let success = !failedPrefixes.contains { output.hasPrefix($0) }

        return ToolResult(success: success, text: output)
    }
}

// MARK: - CLI 实现（全部 MainActor 隔离，访问 SessionManager.shared 并序列化为可读 JSON）

@MainActor
enum SessionsCLI {
    static func run(command: String,
                    id: String?, title: String?, model: String?, agentName: String?,
                    field: String?, value: String?, content: String?, role: String?,
                    keyword: String?, limit: Int) -> String {
        switch command {
        case "list":    return list(limit: limit)
        case "get":     return get(id: id)
        case "create":  return create(title: title, model: model, agentName: agentName)
        case "delete":  return delete(id: id)
        case "update":  return update(id: id, field: field, value: value)
        case "append":  return append(id: id, role: role, content: content)
        case "messages":return messages(id: id)
        case "search":  return search(keyword: keyword)
        default:
            return String(format: L10n.l("sessions_unknown_command"), command)
        }
    }

    static func list(limit: Int) -> String {
        let sessions = SessionManager.shared.allSessions()
        let limited = limit > 0 ? Array(sessions.prefix(limit)) : sessions
        return prettyJSON(limited.map { sessionToDict($0) })
    }

    static func get(id: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id),
              let s = SessionManager.shared.session(id: uuid) else {
            return L10n.l("session_not_found_id") + (id ?? L10n.l("none"))
        }
        var d = sessionToDict(s)
        d["messages"] = s.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { messageToDict($0) }
        return prettyJSON(d)
    }

    static func create(title: String?, model: String?, agentName: String?) -> String {
        guard let s = SessionManager.shared.createSession(
            title: title ?? L10n.l("new_chat_title"),
            model: model ?? L10n.l("not_configured"),
            agentName: agentName ?? "MiniClaw"
        ) else {
            return L10n.l("err_create_session_no_context")
        }
        return L10n.l("session_created_header") + prettyJSON(sessionToDict(s))
    }

    static func delete(id: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id) else {
            return L10n.l("err_missing_id")
        }
        return SessionManager.shared.deleteSession(id: uuid)
            ? String(format: L10n.l("sessions_deleted"), id)
            : String(format: L10n.l("sessions_not_found"), id)
    }

    static func update(id: String?, field: String?, value: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id) else {
            return L10n.l("err_missing_id")
        }
        guard let field, let value else {
            return L10n.l("err_update_need_field_value")
        }
        // icon / iconColor 字段：空字符串表示清除（回退默认），其余原样透传给 SessionManager。
        let iconValue: String? = (field == "icon" || field == "iconColor") ? value : nil
        let ok = SessionManager.shared.updateSession(
            id: uuid,
            title: field == "title" ? value : nil,
            model: field == "model" ? value : nil,
            agentName: field == "agentName" ? value : nil,
            status: field == "status" ? value : nil,
            icon: field == "icon" ? iconValue : nil,
            iconColor: field == "iconColor" ? iconValue : nil
        )
        if field == "icon" {
            return ok
                ? (value.isEmpty ? String(format: L10n.l("sessions_icon_cleared"), id) : String(format: L10n.l("sessions_updated_icon"), id, value))
                : String(format: L10n.l("sessions_not_found"), id)
        }
        if field == "iconColor" {
            return ok
                ? (value.isEmpty ? String(format: L10n.l("sessions_iconcolor_cleared"), id) : String(format: L10n.l("sessions_updated_iconcolor"), id, value))
                : String(format: L10n.l("sessions_not_found"), id)
        }
        return ok ? String(format: L10n.l("sessions_updated_field"), id, field) : String(format: L10n.l("sessions_not_found_or_field"), id)
    }

    static func append(id: String?, role: String?, content: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id) else {
            return L10n.l("err_missing_id")
        }
        guard let content, !content.isEmpty else {
            return L10n.l("err_append_need_content")
        }
        let ok = SessionManager.shared.appendMessage(sessionId: uuid, role: role ?? "user", content: content)
        return ok ? String(format: L10n.l("sessions_message_appended"), id) : String(format: L10n.l("sessions_not_found"), id)
    }

    static func messages(id: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id),
              let s = SessionManager.shared.session(id: uuid) else {
            return L10n.l("session_not_found_ws") + (id ?? L10n.l("none"))
        }
        let arr = s.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { messageToDict($0) }
        return prettyJSON(arr)
    }

    static func search(keyword: String?) -> String {
        guard let keyword, !keyword.isEmpty else {
            return L10n.l("err_search_need_keyword")
        }
        let results = SessionManager.shared.searchAllMessages(keyword: keyword)
        let arr = results.map { item -> [String: Any] in
            var m = messageToDict(item.message)
            m["sessionTitle"] = item.sessionTitle
            return m
        }
        return prettyJSON(arr)
    }

    // MARK: - 序列化

    static func sessionToDict(_ s: ChatSession) -> [String: Any] {
        [
            "id": s.id.uuidString,
            "title": s.title,
            "model": s.modelName,
            "agentName": s.agentName,
            "icon": s.icon as Any? ?? NSNull(),
            "iconColor": s.iconColor as Any? ?? NSNull(),
            "status": s.statusRaw,
            "createdAt": ISO8601DateFormatter().string(from: s.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: s.updatedAt),
            "messageCount": s.messages.count
        ]
    }

    static func messageToDict(_ m: ChatMessage) -> [String: Any] {
        [
            "id": m.id.uuidString,
            "role": m.roleRaw,
            "content": m.content,
            "createdAt": ISO8601DateFormatter().string(from: m.createdAt),
            "attachments": m.attachments,
            "toolCalls": m.toolCalls.map { ["name": $0.name, "success": $0.success] }
        ]
    }

    static func prettyJSON(_ obj: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: obj)
    }
}
