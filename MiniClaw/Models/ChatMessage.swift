import Foundation
import SwiftData

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var createdAt: Date
    var isStreaming: Bool
    /// 用户是否主动中断了本条 智能体回复。可选类型保证旧 SwiftData 数据轻量迁移兼容。
    var wasStopped: Bool?
    /// 智能体回复因异常/警告（网络失败、工具熔断、无效工具、无有效内容等）被迫中断，并未正常完成。
    /// 非可选 Bool 带默认值 false，配合 SwiftData 轻量迁移兼容旧数据。
    var wasInterrupted: Bool = false
    /// 任务总耗时（秒，2026-08-08 用户定）：从用户发送消息到 AI 跑完全部轮次输出完毕；
    /// 暂停/重试期间不计。可选类型：旧数据/断点恢复（冷启动）不显示。落盘持久化。
    var taskElapsedSeconds: Double? = nil
    var toolCallName: String?
    var toolCallResult: String?
    var toolCallsData: Data?
    var attachmentsData: Data?
    /// 思考过程（reasoning）展示字段：持久化到 SwiftData，重进会话后仍能看到可折叠「思考过程」块；
    /// **不回灌上下文**——`buildHistory` 只取 `content`，所以下一轮上下文只看正文、思考 词元 永不回灌。
    /// 由 ChatView 在流式期间实时写入（与 `content` 同机制），流式结束后随消息一起落盘。
    var reasoning: String?
    /// 最终轮回复正文：agent 工具循环结束后「最后一轮模型答复」的文本（区别于 `content`——
    /// content 是整轮所有循环文本的拼接，开头可能是过程叙述）。首页会话列表摘要优先用此字段，
    /// 避免显示成「第一轮循环的中间回复」；nil = 旧数据/未正常完成，回退 content。
    var previewText: String?
    /// 分段思考过程：按「agent loop 轮次（iterations）」切片，每段独立可折叠、穿插在正文/工具调用之间，
    /// 而非全部堆在回复顶部。由 ChatView 在流式期间按迭代序号累积写入并落盘。
    /// 旧消息只有单字符串 `reasoning` 时，`MessageBubbleView` 会把它包成一个 `position: 0` 的单段兼容。
    var reasoningSegmentsData: Data?

    var session: ChatSession?

    /// 解码缓存（2026-08-07 效率优化）：toolCalls/attachments/reasoningSegments 是计算属性,
    /// 每次访问都全量 JSON 解码——请求构造对每条历史消息访问多次,长会话每轮重复解码。
    /// @Transient 不落盘;set 时清缓存保证一致性。
    @Transient private var toolCallsCache: [ToolCallEvent]?
    @Transient private var attachmentsCache: [String]?
    @Transient private var reasoningSegmentsCache: [ReasoningSegment]?

    /// 本次回复过程中穿插的工具调用事件（含参数与结果），用于在 UI 中展示 智能体的工具使用过程。
    var toolCalls: [ToolCallEvent] {
        get {
            if let c = toolCallsCache { return c }
            guard let data = toolCallsData else { return [] }
            let v = (try? JSONDecoder().decode([ToolCallEvent].self, from: data)) ?? []
            toolCallsCache = v
            return v
        }
        set {
            toolCallsCache = newValue
            toolCallsData = try? JSONEncoder().encode(newValue)
        }
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var attachments: [String] {
        get {
            if let c = attachmentsCache { return c }
            guard let data = attachmentsData else { return [] }
            let v = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            attachmentsCache = v
            return v
        }
        set {
            attachmentsCache = newValue
            attachmentsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// 分段思考过程（按迭代轮次切片）。向后兼容：旧数据无此字段时为空数组，
    /// `MessageBubbleView` 会用单字符串 `reasoning` 兜底成一个单段。
    var reasoningSegments: [ReasoningSegment] {
        get {
            if let c = reasoningSegmentsCache { return c }
            guard let data = reasoningSegmentsData else { return [] }
            let v = (try? JSONDecoder().decode([ReasoningSegment].self, from: data)) ?? []
            reasoningSegmentsCache = v
            return v
        }
        set {
            reasoningSegmentsCache = newValue
            reasoningSegmentsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(
        id: UUID = UUID(),
        role: MessageRole = .user,
        content: String = "",
        attachments: [String] = [],
        isStreaming: Bool = false,
        wasStopped: Bool? = nil,
        toolCallName: String? = nil,
        toolCallResult: String? = nil
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = Date()
        self.isStreaming = isStreaming
        self.wasStopped = wasStopped
        self.toolCallName = toolCallName
        self.toolCallResult = toolCallResult
        self.attachmentsData = try? JSONEncoder().encode(attachments)
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case tool
    case system
}

// MARK: - 工具调用事件（展示在 智能体回复中）

struct ToolCallEvent: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// 模型工具调用 id（tool_call.id）：并发同名工具（如多个 browser）时用它在结果回填时精确配对。
    var callID: String?
    /// 模型传入的参数，已格式化为易读 JSON 字符串
    var arguments: String
    /// 工具执行结果文本
    var resultText: String
    var success: Bool
    /// 用户停止整条回复时，该工具是否仍处于执行中并被中断。
    var wasInterrupted: Bool
    var timestamp: Date
    /// 该工具调用在 智能体回复正文中的字符位置，用于把卡片内联穿插到「它发生的那句话」处
    var position: Int
    /// 工具调用总耗时（秒），在 resultText 落盘时由 ChatView.onToolResult 计算
    var duration: TimeInterval?
    /// 全局时间线序号：在流式过程中按「思考段/工具调用」的实际发生顺序递增。
    /// 用于渲染时正确交错排列。旧数据默认 0。
    var timelineOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        callID: String? = nil,
        arguments: String = "",
        resultText: String = "",
        success: Bool = false,
        wasInterrupted: Bool = false,
        timestamp: Date = Date(),
        position: Int = 0,
        duration: TimeInterval? = nil,
        timelineOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.callID = callID
        self.arguments = arguments
        self.resultText = resultText
        self.success = success
        self.wasInterrupted = wasInterrupted
        self.timestamp = timestamp
        self.position = position
        self.duration = duration
        self.timelineOrder = timelineOrder
    }

    // 兼容旧数据：旧消息的 toolCalls JSON 没有 position / duration / wasInterrupted / timelineOrder 时使用默认值
    private enum CodingKeys: String, CodingKey {
        case id, name, callID, arguments, resultText, success, wasInterrupted, timestamp, position, duration, timelineOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        callID = try c.decodeIfPresent(String.self, forKey: .callID)
        arguments = try c.decode(String.self, forKey: .arguments)
        resultText = try c.decode(String.self, forKey: .resultText)
        success = try c.decode(Bool.self, forKey: .success)
        wasInterrupted = try c.decodeIfPresent(Bool.self, forKey: .wasInterrupted) ?? false
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        timelineOrder = try c.decodeIfPresent(Int.self, forKey: .timelineOrder) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(callID, forKey: .callID)
        try c.encode(arguments, forKey: .arguments)
        try c.encode(resultText, forKey: .resultText)
        try c.encode(success, forKey: .success)
        try c.encode(wasInterrupted, forKey: .wasInterrupted)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(position, forKey: .position)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(timelineOrder, forKey: .timelineOrder)
    }
}

// MARK: - 分段思考过程（按 agent loop 轮次切片，穿插展示）

/// 一段「深度思考」内容：对应一次模型调用轮次（引擎 `iterations`）。
/// - `index`：1-based 迭代序号（第几轮思考）。
/// - `text`：该段思考文本（流式期间持续追加）。
/// - `position`：该段思考在助手**正文**中的字符偏移，用于把它穿插到正文/工具调用之间
///   （第 1 段通常为 0 → 顶部；后续段位于对应工具结果之后）。
struct ReasoningSegment: Codable, Identifiable, Equatable {
    var id: UUID
    var index: Int
    var text: String
    /// 该思考段在 智能体回复正文中的字符位置（用于文本锚入）
    var position: Int
    /// 全局时间线序号：在流式过程中按「思考段/工具调用」的实际发生顺序递增。
    /// 用于渲染时正确交错排列（解决"全部思考堆顶部"问题）。
    /// 旧数据默认 0，会排到最前面（可接受降级）。
    var timelineOrder: Int

    init(index: Int, text: String, position: Int, timelineOrder: Int = 0) {
        self.id = UUID()
        self.index = index
        self.text = text
        self.position = position
        self.timelineOrder = timelineOrder
    }

    // 兼容旧数据：旧 ReasoningSegment JSON 无 id/timelineOrder 字段时使用默认值
    private enum CodingKeys: String, CodingKey {
        case id, index, text, position, timelineOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        index = try c.decode(Int.self, forKey: .index)
        text = try c.decode(String.self, forKey: .text)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        timelineOrder = try c.decodeIfPresent(Int.self, forKey: .timelineOrder) ?? 0
    }
}

