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
                description: "会话数据库 CRUD。当前会话操作优先使用 target=current，不要先 list 再猜 UUID。子命令: list/get/create/delete/update/append/messages/search。update/get/messages/append 默认操作当前会话；只有用户明确要求操作其他会话时，才使用 target=explicit 并提供 id。delete 必须使用 target=explicit 和 id。",
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "command": JSONSchema.JSONProperty(type: "string", description: "子命令", enum: ["list", "get", "create", "delete", "update", "append", "messages", "search"]),
                        "target": JSONSchema.JSONProperty(type: "string", description: "目标会话。current=当前打开的会话（默认）；explicit=其他指定会话，必须同时提供 id", enum: ["current", "explicit"]),
                        "id": JSONSchema.JSONProperty(type: "string", description: "仅 target=explicit 时使用的其他会话 UUID；不要为当前会话猜测或从 list 选择 UUID"),
                        "title": JSONSchema.JSONProperty(type: "string", description: "会话标题（create 或 update field=title 时提供）"),
                        "model": JSONSchema.JSONProperty(type: "string", description: "模型名（create 或 update field=model 时提供）"),
                        "agentName": JSONSchema.JSONProperty(type: "string", description: "Agent 显示名（create 或 update field=agentName 时提供）"),
                        "field": JSONSchema.JSONProperty(type: "string", description: "update 的字段名，可选: title/model/agentName/status/icon/iconColor。icon 为 SF Symbol 名称（如 'bookmark.fill'、'brain.head.profile'），传空字符串可清除自定义图标回退默认；iconColor 为十六进制颜色（如 '#FF6B6B'），与会话主题匹配，背景自动取该色 0.12 透明，传空字符串清除。注意：禁止使用纯黑(#000000)、纯白(#FFFFFF)或接近的黑/白色，它们在深色/浅色背景下会不可见，请选用明确的彩色，否则将被忽略回退默认蓝"),
                        "value": JSONSchema.JSONProperty(type: "string", description: "update 的字段新值"),
                        "role": JSONSchema.JSONProperty(type: "string", description: "append 的消息角色，可选: user/assistant/tool/system（默认 user）"),
                        "content": JSONSchema.JSONProperty(type: "string", description: "append 的消息正文 / search 的关键词"),
                        "keyword": JSONSchema.JSONProperty(type: "string", description: "search 的关键词（与 content 等价，任一即可）"),
                        "limit": JSONSchema.JSONProperty(type: "integer", description: "list 返回数量上限（0 = 全部）")
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
            "未知命令", "未找到", "缺少", "创建会话失败",
            "update 需要", "append 需要", "search 需要"
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
            return "未知命令: \(command)。可用: list / get / create / delete / update / append / messages / search"
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
            return "未找到会话 id=\(id ?? "nil")"
        }
        var d = sessionToDict(s)
        d["messages"] = s.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { messageToDict($0) }
        return prettyJSON(d)
    }

    static func create(title: String?, model: String?, agentName: String?) -> String {
        guard let s = SessionManager.shared.createSession(
            title: title ?? "新会话",
            model: model ?? "未配置",
            agentName: agentName ?? "MiniClaw"
        ) else {
            return "创建会话失败（SwiftData ModelContext 未配置）"
        }
        return "已创建会话:\n" + prettyJSON(sessionToDict(s))
    }

    static func delete(id: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id) else {
            return "缺少或无效的 id"
        }
        return SessionManager.shared.deleteSession(id: uuid)
            ? "已删除会话 \(id)"
            : "未找到会话 \(id)"
    }

    static func update(id: String?, field: String?, value: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id) else {
            return "缺少或无效的 id"
        }
        guard let field, let value else {
            return "update 需要 field 与 value 参数"
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
                ? (value.isEmpty ? "已清除会话 \(id) 的自定义图标，回退默认" : "已更新 \(id).icon = \(value)")
                : "未找到会话 \(id)"
        }
        if field == "iconColor" {
            return ok
                ? (value.isEmpty ? "已清除会话 \(id) 的自定义图标配色，回退多样兜底色" : "已更新 \(id).iconColor = \(value)")
                : "未找到会话 \(id)"
        }
        return ok ? "已更新 \(id).\(field)" : "未找到会话 \(id) 或字段无效（可选: title/model/agentName/status/icon/iconColor）"
    }

    static func append(id: String?, role: String?, content: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id) else {
            return "缺少或无效的 id"
        }
        guard let content, !content.isEmpty else {
            return "append 需要 content 参数"
        }
        let ok = SessionManager.shared.appendMessage(sessionId: uuid, role: role ?? "user", content: content)
        return ok ? "已追加消息到会话 \(id)" : "未找到会话 \(id)"
    }

    static func messages(id: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id),
              let s = SessionManager.shared.session(id: uuid) else {
            return "未找到会话 \(id ?? "nil")"
        }
        let arr = s.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { messageToDict($0) }
        return prettyJSON(arr)
    }

    static func search(keyword: String?) -> String {
        guard let keyword, !keyword.isEmpty else {
            return "search 需要 keyword 参数"
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
