import Foundation

/// 会话消息。iOS16 适配(2026-08-12):由 SwiftData @Model 改为普通 Codable class,
/// 持久化经 SessionManager 的 JSON 文件存储(Documents/MiniClaw-Sessions/<uuid>/session.json)。
/// `session` 为内存反向引用(不参与编码),缓存属性不落盘。
final class ChatMessage: Identifiable, Codable {
    var id: UUID
    var roleRaw: String
    var content: String
    var createdAt: Date
    var isStreaming: Bool
    /// 2026-08-12 治本:消息级暂停标志。暂停即置 true 并同步落盘,
    /// 重启后据此恢复暂停指示器(不依赖进程内 runtime)。
    var isPaused: Bool = false
    /// 用户是否主动中断了本条 智能体回复。可选类型兼容旧数据。
    var wasStopped: Bool?
    /// 智能体回复因异常/警告（网络失败、工具熔断、无效工具、无有效内容等）被迫中断，并未正常完成。
    var wasInterrupted: Bool = false
    /// 任务总耗时（秒，2026-08-08 用户定）：从用户发送消息到 AI 跑完全部轮次输出完毕；
    /// 暂停/重试期间不计。可选类型：旧数据/断点恢复（冷启动）不显示。落盘持久化。
    var taskElapsedSeconds: Double? = nil
    var toolCallName: String?
    var toolCallResult: String?
    var toolCallsData: Data?
    var attachmentsData: Data?
    /// 思考过程（reasoning）展示字段：持久化，重进会话后仍能看到可折叠「思考过程」块；
    /// **不回灌上下文**——`buildHistory` 只取 `content`，所以下一轮上下文只看正文、思考 词元 永不回灌。
    var reasoning: String?
    /// 最终轮回复正文：agent 工具循环结束后「最后一轮模型答复」的文本（区别于 `content`——
    /// content 是整轮所有循环文本的拼接，开头可能是过程叙述）。首页会话列表摘要优先用此字段。
    var previewText: String?
    /// 分段思考过程：按「agent loop 轮次（iterations）」切片，每段独立可折叠、穿插在正文/工具调用之间。
    var reasoningSegmentsData: Data?

    /// [2026-09-15 缓存治本] 本条消息在**实际请求体**里 `content` 之后必须逐字重放的字节
    /// （= 附件提示段 + 本轮「易变段快照」）。只进 API 请求，不进 UI；可选类型，旧数据为 nil。
    ///
    /// 为什么必须落盘并逐字回放：服务端提示词缓存按「缓存前缀单元 / 最长公共前缀」命中，前提是
    /// **请求 N+1 逐字节以请求 N 开头**。易变段（时间 / 工具清单 / 环境变量 / 挂载 / 记忆 / 子代理清单）
    /// 若每轮临时拼在请求末尾，上一轮请求的结尾在下一轮里不存在 ⇒ 缓存只能命中静态前块
    /// （真机实证：`[Cache命中]` 恒等于 sys+tools，历史逐轮 0 命中、未命中与 prompt 增量 1:1）。
    /// 把易变段落进本条消息并逐字回放后，请求序列恢复为纯追加 ⇒ 缓存可覆盖全部历史。
    /// 根因与实测见 `docs/archive/MiniClaw_缓存命中率-根因报告-20260915.md`。
    var apiContextSuffix: String?

    /// 本条消息实际发给模型的正文 = `content` + `apiContextSuffix`。
    /// **发送侧与历史回放侧必须都走这里**（`AgentRunService+Run.startRun` / `buildHistory`），
    /// 否则两侧字节不一致会重新打断前缀缓存。
    var apiContent: String {
        guard let suffix = apiContextSuffix, !suffix.isEmpty else { return content }
        return content + suffix
    }

    /// 内存反向引用（不参与编码）：由 SessionManager 加载时装配。
    weak var session: ChatSession?

    /// 解码缓存（2026-08-07 效率优化）：toolCalls/attachments/reasoningSegments 是计算属性,
    /// 每次访问都全量 JSON 解码——请求构造对每条历史消息访问多次,长会话每轮重复解码。
    /// 不落盘;set 时清缓存保证一致性。
    private var toolCallsCache: [ToolCallEvent]?
    private var attachmentsCache: [String]?
    private var reasoningSegmentsCache: [ReasoningSegment]?

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

    // MARK: - Codable（手动：排除内存引用 session 与解码缓存）

    private enum CodingKeys: String, CodingKey {
        case id, roleRaw, content, createdAt, isStreaming, wasStopped, wasInterrupted,
             taskElapsedSeconds, toolCallName, toolCallResult, toolCallsData, attachmentsData,
             reasoning, previewText, reasoningSegmentsData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roleRaw = try c.decode(String.self, forKey: .roleRaw)
        content = try c.decode(String.self, forKey: .content)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        wasStopped = try c.decodeIfPresent(Bool.self, forKey: .wasStopped)
        wasInterrupted = try c.decodeIfPresent(Bool.self, forKey: .wasInterrupted) ?? false
        taskElapsedSeconds = try c.decodeIfPresent(Double.self, forKey: .taskElapsedSeconds)
        toolCallName = try c.decodeIfPresent(String.self, forKey: .toolCallName)
        toolCallResult = try c.decodeIfPresent(String.self, forKey: .toolCallResult)
        toolCallsData = try c.decodeIfPresent(Data.self, forKey: .toolCallsData)
        attachmentsData = try c.decodeIfPresent(Data.self, forKey: .attachmentsData)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        previewText = try c.decodeIfPresent(String.self, forKey: .previewText)
        reasoningSegmentsData = try c.decodeIfPresent(Data.self, forKey: .reasoningSegmentsData)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(roleRaw, forKey: .roleRaw)
        try c.encode(content, forKey: .content)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encodeIfPresent(wasStopped, forKey: .wasStopped)
        try c.encode(wasInterrupted, forKey: .wasInterrupted)
        try c.encodeIfPresent(taskElapsedSeconds, forKey: .taskElapsedSeconds)
        try c.encodeIfPresent(toolCallName, forKey: .toolCallName)
        try c.encodeIfPresent(toolCallResult, forKey: .toolCallResult)
        try c.encodeIfPresent(toolCallsData, forKey: .toolCallsData)
        try c.encodeIfPresent(attachmentsData, forKey: .attachmentsData)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encodeIfPresent(previewText, forKey: .previewText)
        try c.encodeIfPresent(reasoningSegmentsData, forKey: .reasoningSegmentsData)
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

// MARK: - 易变段 → 请求体后缀（唯一构造点）

/// [2026-09-15 缓存治本] 「易变段快照」拼进请求体的**唯一构造点**。
///
/// 发送侧（`AgentRunService+Run.startRun` 落盘快照）与轮内增量（`AgentLoopEngine` 在
/// `skill-load` 后追加）都从这里取文本，保证同一段快照在任何位置逐字节一致——
/// 前缀缓存只认字节，任何"两处各拼一遍"的分叉都会重新打断嵌套。
enum APIContextSuffix {
    /// 把易变段包成可直接追加到消息末尾的后缀（含"这不是用户指令"的显式标注）。
    /// 易变段为空时返回空串（此时请求保持纯追加，不产生任何尾巴）。
    static func volatile(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\n\n" + String(format: String(localized: "env_snapshot_note"), trimmed)
    }
}

