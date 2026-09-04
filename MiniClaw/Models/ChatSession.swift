import Foundation

/// 会话。iOS16 适配(2026-08-12):由 SwiftData @Model 改为 ObservableObject + Codable class,
/// 持久化经 SessionManager 的 JSON 文件存储(Documents/MiniClaw-Sessions/<uuid>/session.json)。
/// @Published 驱动会话页/首页 UI 刷新;Codable 手动实现(排除 @Published 包装)。
final class ChatSession: ObservableObject, Identifiable, Codable {
    var id: UUID
    @Published var title: String
    /// 标题是否仍为「AI 未改名」占位（首条用户消息前 40 字）。AI 生成正式标题 / 用户手动改名后置 false。
    @Published var titleIsPlaceholder: Bool = false
    @Published var createdAt: Date
    @Published var updatedAt: Date
    @Published var modelName: String
    @Published var agentName: String
    /// 来源：app（App 内创建）/ cli（MiniClaw-sessions-cli 创建）。默认 app。
    @Published var source: String = "app"
    @Published var statusRaw: String
    @Published var isPinned: Bool = false
    /// 上次记忆复盘处理到的消息条数（持久化，重启后不重复复盘）。
    @Published var reviewedMessageCount: Int = 0
    /// 会话图标（SF Symbol 名称）。为空时回退到默认图标。
    @Published var icon: String?

    /// 会话图标前景色（十六进制，如 #FF6B6B）。
    @Published var iconColor: String?

    /// 仅保留以维持旧数据兼容，不再单独写入；图标背景统一由 iconColor 的 0.12 透明度派生。
    @Published var iconBackgroundColor: String?

    /// 深度思考等级的会话级覆盖：nil = 未设置；"low"/"medium"/"high"/"xhigh"/"max" = 强制开启对应强度。
    @Published var thinkingLevel: String?

    /// 会话摘要（由复盘分身在离开会话/App 后台时沉淀），供 buildSystemPrompt 注入。
    @Published var summary: String?
    /// 上下文压缩锚点(手动「折叠上方」与引擎自动压缩共用同一机制):
    /// 此消息 id 之上的历史已压缩为摘要,buildHistory 消费时丢弃锚点之上、摘要置 history 首位。
    /// 2026-08-13 起引擎自动压缩也写回本字段,SQLite 持久化(重启后仍生效)。
    @Published var compactAnchorID: UUID? = nil
    /// 压缩摘要文本(仅当 compactAnchorID 非 nil 时有效)。
    @Published var compactSummary: String? = nil

    /// 本会话被「关闭」的 MCP server ID 集合（会话级开关）。
    @Published var disabledMCPServerIDs: [UUID]?

    @Published var messages: [ChatMessage] = []

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .idle }
        set { statusRaw = newValue.rawValue }
    }

    /// 列表展示用的 SF Symbol 名称；未自定义时回退默认图标。
    var iconName: String { icon ?? ChatSession.defaultIcon }

    /// 默认会话图标（SF Symbol）。
    static let defaultIcon = "bubble.left.and.bubble.right.fill"

    init(
        id: UUID = UUID(),
        title: String = "NewChat",
        modelName: String = "NotConfigured",
        agentName: String = "MiniClaw",
        source: String = "app",
        status: SessionStatus = .idle,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.modelName = modelName
        self.agentName = agentName
        self.source = source
        self.statusRaw = status.rawValue
        self.isPinned = isPinned
    }

    /// 加载后装配消息反向引用（SessionManager 调用）。
    func attachMessages(_ msgs: [ChatMessage]) {
        messages = msgs
        for m in msgs { m.session = self }
    }

    // MARK: - Codable（手动：@Published 包装无法自动合成）

    private enum CodingKeys: String, CodingKey {
        case id, title, titleIsPlaceholder, createdAt, updatedAt, modelName, agentName,
             source, statusRaw, isPinned, reviewedMessageCount, icon, iconColor,
             iconBackgroundColor, thinkingLevel, summary, disabledMCPServerIDs, messages,
             compactAnchorID, compactSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        titleIsPlaceholder = try c.decodeIfPresent(Bool.self, forKey: .titleIsPlaceholder) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        modelName = try c.decode(String.self, forKey: .modelName)
        agentName = try c.decode(String.self, forKey: .agentName)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "app"
        statusRaw = try c.decode(String.self, forKey: .statusRaw)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        reviewedMessageCount = try c.decodeIfPresent(Int.self, forKey: .reviewedMessageCount) ?? 0
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        iconColor = try c.decodeIfPresent(String.self, forKey: .iconColor)
        iconBackgroundColor = try c.decodeIfPresent(String.self, forKey: .iconBackgroundColor)
        thinkingLevel = try c.decodeIfPresent(String.self, forKey: .thinkingLevel)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        disabledMCPServerIDs = try c.decodeIfPresent([UUID].self, forKey: .disabledMCPServerIDs)
        let msgs = try c.decode([ChatMessage].self, forKey: .messages)
        compactAnchorID = try c.decodeIfPresent(UUID.self, forKey: .compactAnchorID)
        compactSummary = try c.decodeIfPresent(String.self, forKey: .compactSummary)
        attachMessages(msgs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(titleIsPlaceholder, forKey: .titleIsPlaceholder)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(agentName, forKey: .agentName)
        try c.encode(source, forKey: .source)
        try c.encode(statusRaw, forKey: .statusRaw)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(reviewedMessageCount, forKey: .reviewedMessageCount)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(iconColor, forKey: .iconColor)
        try c.encodeIfPresent(iconBackgroundColor, forKey: .iconBackgroundColor)
        try c.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(disabledMCPServerIDs, forKey: .disabledMCPServerIDs)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(compactAnchorID, forKey: .compactAnchorID)
        try c.encodeIfPresent(compactSummary, forKey: .compactSummary)
    }
}

enum SessionStatus: String, Codable {
    case idle
    case running
    /// 2026-08-12 治本:暂停态(用户暂停/可恢复)。此前暂停不写 status 卡 .running,
    /// 首页行据此显示"回复中"转圈。
    case paused
    case completed
    case error
    case retrying
}

// MARK: - 导出（JSON / 纯文本）

/// 会话导出格式。
enum SessionExportFormat {
    case json
    case text
}

/// 导出时使用的本地化时间格式（模块内私有，仅本文件导出方法使用）。
private let sessionExportDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = .current
    return f
}()

extension ChatSession {
    /// 导出为字典结构（供 JSON 序列化）。消息按创建时间升序，包含可选的 toolCalls。
    func exportDictionary() -> [String: Any] {
        let messages = self.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { msg -> [String: Any] in
                var dict: [String: Any] = [
                    "role": msg.role.rawValue,
                    "content": msg.content,
                    "createdAt": sessionExportDateFormatter.string(from: msg.createdAt)
                ]
                if !msg.toolCalls.isEmpty {
                    dict["toolCalls"] = msg.toolCalls.map { tc -> [String: Any] in
                        [
                            "name": tc.name,
                            "arguments": tc.arguments,
                            "resultText": tc.resultText,
                            "success": tc.success,
                            "timestamp": sessionExportDateFormatter.string(from: tc.timestamp)
                        ]
                    }
                }
                return dict
            }
        return [
            "title": title,
            "modelName": modelName,
            "agentName": agentName,
            "createdAt": sessionExportDateFormatter.string(from: createdAt),
            "updatedAt": sessionExportDateFormatter.string(from: updatedAt),
            "messages": messages
        ]
    }

    /// 导出为易读的纯文本对话记录。
    func exportText() -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append(String(format: String(localized: "export_model_label"), modelName))
        lines.append(String(format: String(localized: "export_agent_label"), agentName))
        lines.append(String(format: String(localized: "export_created_label"), sessionExportDateFormatter.string(from: createdAt)))
        lines.append(String(format: String(localized: "export_updated_label"), sessionExportDateFormatter.string(from: updatedAt)))
        lines.append("")

        for msg in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            let roleLabel: String = {
                switch msg.role {
                case .user: return String(localized: "export_role_user")
                case .assistant: return String(localized: "export_role_assistant")
                case .tool: return String(localized: "export_role_tool")
                case .system: return String(localized: "export_role_system")
                }
            }()
            lines.append("--- \(roleLabel) · \(sessionExportDateFormatter.string(from: msg.createdAt)) ---")
            if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(msg.content)
            }
            if !msg.toolCalls.isEmpty {
                for tc in msg.toolCalls {
                    lines.append(String(format: String(localized: "export_tool_call"), tc.name))
                    if !tc.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append(String(format: String(localized: "export_tool_args"), tc.arguments))
                    }
                    if !tc.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append(String(format: String(localized: "export_tool_result"), tc.resultText))
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Equatable(按 id;iOS16 onChange(of:) 要求 Equatable)

extension ChatSession: Equatable {
    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        // 2026-08-13:纳入 isPinned——否则置顶(Pin)是成员级变更,数组判等只比 id 不变,
        // SwiftUI @State 不重渲染,首页分组不立即重排(置顶"要等刷新才生效")。
        lhs.id == rhs.id && lhs.isPinned == rhs.isPinned
    }
}
