import Foundation
import SwiftData

@Model
final class ChatSession {
    @Attribute(.unique) var id: UUID
    var title: String
    /// 标题是否仍为「AI 未改名」占位（首条用户消息前 40 字）。AI 生成正式标题 / 用户手动改名后置 false。
    /// 会话页标题区据此在「占位（显示首条消息前 8 字…）」与「真实标题」间切换。
    var titleIsPlaceholder: Bool = false
    var createdAt: Date
    var updatedAt: Date
    var modelName: String
    var agentName: String
    /// 来源：app（App 内创建）/ cli（MiniClaw-sessions-cli 创建）。默认 app。
    var source: String = "app"
    var statusRaw: String
    var isPinned: Bool = false
    /// 上次记忆复盘处理到的消息条数（持久化，重启后不重复复盘）。
    /// 默认 0 = 从未复盘；SwiftData 轻量迁移对已有数据自动补默认值。
    var reviewedMessageCount: Int = 0
    /// 会话图标（SF Symbol 名称）。为空时回退到默认图标。可被 App 内 智能体通过
    /// sessions_cli（command=update, field=icon, value=<sf_symbol>）修改。
    /// 用可选类型以保证 SwiftData 轻量迁移兼容（对已有数据仅新增一列）。
    var icon: String?

    /// 会话图标前景色（十六进制，如 #FF6B6B）。由 智能体在生成标题/图标时一并挑选，
    /// 需与会话主题相匹配；持久化存储，故重新进入会话颜色稳定、不会重排。
    /// 为空时首页按默认蓝渲染（不使用系统随机取色）。
    var iconColor: String?

    /// 仅保留以维持 SwiftData 轻量迁移稳定，不再单独写入；图标背景统一由
    /// iconColor 的 0.12 透明度派生（见 SessionRowView）。
    var iconBackgroundColor: String?

    /// 深度思考等级的会话级覆盖：
    /// - nil = 未设置（跟随模型能力 + 模型组默认思考等级；模型支持思考则默认开启）；
    /// - "low" / "medium" / "high" / "xhigh" / "max" = 强制开启对应强度；
    /// 由聊天页「/」菜单的 /thinking 命令切换，按会话持久化，重新进入会话仍生效。
    var thinkingLevel: String?

    /// 会话摘要（由复盘分身在离开会话/App 后台时沉淀），供 buildSystemPrompt 的
    /// 「其它会话最近要点」小节注入。可选类型以保证 SwiftData 轻量迁移兼容。
    var summary: String?

    /// 本会话被「关闭」的 MCP server ID 集合（会话级开关）。可选类型以保证 SwiftData 轻量迁移兼容。
    /// 全局 `isEnabled` 控制总开关；此处做逐会话例外：即使全局启用，列在此处的 server 也不在本会话加载工具。
    var disabledMCPServerIDs: [UUID]?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []

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
        title: String = "新会话",
        modelName: String = "未配置",
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
}

enum SessionStatus: String, Codable {
    case idle
    case running
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
        lines.append("模型：\(modelName)")
        lines.append("智能体：\(agentName)")
        lines.append("创建时间：\(sessionExportDateFormatter.string(from: createdAt))")
        lines.append("更新时间：\(sessionExportDateFormatter.string(from: updatedAt))")
        lines.append("")

        for msg in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            let roleLabel: String = {
                switch msg.role {
                case .user: return "用户"
                case .assistant: return "助手"
                case .tool: return "工具"
                case .system: return "系统"
                }
            }()
            lines.append("--- \(roleLabel) · \(sessionExportDateFormatter.string(from: msg.createdAt)) ---")
            if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(msg.content)
            }
            if !msg.toolCalls.isEmpty {
                for tc in msg.toolCalls {
                    lines.append("  [工具: \(tc.name)]")
                    if !tc.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append("  参数: \(tc.arguments)")
                    }
                    if !tc.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append("  结果: \(tc.resultText)")
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
