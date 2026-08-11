import Foundation
import MiniClawKit

// MARK: - 适配层:消息转换(2026-08-09)
// 把 MiniClaw 的 SwiftData 消息模型转换为 移植消息列表组件所需的
// ChatMessage/AssistantBlock 形态。纯转换,不持有状态。

enum MiniClawChatAdapter {

    // MARK: - 消息级转换

    /// 把 MiniClaw 消息转换为 OM 形态(含 blocks 拆分)
    static func convert(_ message: ChatMessage) -> MiniClawKit.ChatMessage {
        let om = MiniClawKit.ChatMessage(role: omRole(message), content: message.content)
        om.blocks = buildBlocks(message)
        om.isAwaitingModelResponse = message.isStreaming
        return om
    }

    private static func omRole(_ message: ChatMessage) -> MiniClawKit.ChatMessageRole {
        switch message.role {
        case .user: return .user
        case .assistant, .tool: return .assistant
        case .system: return .systemInfo
        }
    }

    // MARK: - 块级转换

    /// 按 timelineOrder 交错生成 blocks:思考段/正文片段/工具调用。
    /// 正文按思考段/工具调用的 position 切分成多个片段,每段 order = 前一事件
    /// order + 0.5,实现「思考1→工具1→回复1→思考2→工具2→回复2」的真实穿插
    /// (与子代理会话 assistantSegments 的顺序规则一致)。
    private static func buildBlocks(_ message: ChatMessage) -> [MiniClawKit.AssistantBlock] {
        var items: [(order: Double, block: MiniClawKit.AssistantBlock)] = []

        // 收集事件(思考段 + 工具调用),按 timelineOrder 排序,含 position。
        var events: [(order: Int, position: Int, block: MiniClawKit.AssistantBlock)] = []

        for seg in message.reasoningSegments {
            let block = MiniClawKit.AssistantBlock(kind: .thinking, content: seg.text)
            // 2026-08-10 用户要求:思考块默认折叠,哪怕用户上次展开过,
            // 每次重建(新消息/流式刷新)一律强制折叠,不保留任何展开状态。
            block.isThinkingExpanded = false
            block.thinkingUserToggled = false
            events.append((seg.timelineOrder, seg.position, block))
        }

        for event in message.toolCalls {
            let block = MiniClawKit.AssistantBlock(kind: toolKind(event.name, arguments: event.arguments), content: event.resultText)
            block.toolUseId = event.callID ?? event.id.uuidString
            block.toolInputArgs = event.arguments
            block.toolDuration = event.duration
            block.toolStatus = toolStatus(for: event, message: message)
            events.append((event.timelineOrder, event.position, block))
        }

        let hasTimeline = events.contains { $0.order > 0 }
        let sortedEvents: [(order: Double, position: Int, block: MiniClawKit.AssistantBlock)]
        if hasTimeline {
            sortedEvents = events.sorted {
                $0.order < $1.order || ($0.order == $1.order && $0.position < $1.position)
            }.map { (Double($0.order), $0.position, $0.block) }
        } else {
            sortedEvents = events.sorted {
                $0.position < $1.position
            }.map { (Double($0.position + 1), $0.position, $0.block) }
        }

        // 正文按 position 切分:每个事件前的正文片段 order = 事件 order - 0.5,
        // 事件后的剩余正文排最后(Int.max-1)。
        // 注意:每个 block(事件块与正文片段)都必须在创建时把 order 写回
        // block.timelineOrder——渲染层按 block.timelineOrder 兜底排序(2026-08-10),
        // 若只按元组排序不写回,渲染层读默认值 Int.max-1 会全部相等→按 id 乱序。
        let content = message.content
        var textCursor = 0
        for (order, position, block) in sortedEvents {
            block.timelineOrder = order
            let pos = min(max(position, 0), content.count)
            if pos > textCursor {
                let startIdx = content.index(content.startIndex, offsetBy: textCursor)
                let endIdx = content.index(content.startIndex, offsetBy: pos)
                let textBlock = MiniClawKit.AssistantBlock(kind: .text, content: String(content[startIdx..<endIdx]))
                textBlock.timelineOrder = order - 0.5
                items.append((order - 0.5, textBlock))
            }
            items.append((order, block))
            textCursor = max(textCursor, pos)
        }
        if textCursor < content.count {
            let startIdx = content.index(content.startIndex, offsetBy: textCursor)
            let textBlock = MiniClawKit.AssistantBlock(kind: .text, content: String(content[startIdx..<content.endIndex]))
            textBlock.timelineOrder = Double(Int.max - 1)
            items.append((Double(Int.max - 1), textBlock))
        }

        return items.sorted { $0.order < $1.order }.map(\.block)
    }

    /// 工具名 + 参数 → OM 块类型(10 种 kind 映射),关联值填入真实操作名/路径/命令,
    /// 让工具卡显示真实操作名称(而非笼统的 "Browser action"/"Shell command")。
    static func toolKind(_ name: String, arguments: String = "") -> MiniClawKit.AssistantBlockKind {
        // 从参数 JSON 提取关键字段(command/path/action/url 等),用于关联值展示。
        var argDict: [String: Any] = [:]
        if let data = arguments.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            argDict = dict
        }
        func pick(_ keys: String...) -> String {
            for k in keys {
                if let v = argDict[k] as? String, !v.isEmpty { return v }
            }
            return ""
        }
        switch name {
        case "shell_execute":
            return .shellTool(command: pick("command", "cmd", "code", "script", "expression"))
        case "file_read":
            return .fileReadTool(path: pick("path", "file", "file_path", "filename"))
        case "file_write":
            return .fileWriteTool(path: pick("path", "file", "file_path", "filename"))
        case "file_edit":
            return .fileEditTool(path: pick("path", "file", "file_path", "filename"))
        case "browser", "miniclaw-browser-use":
            let action = pick("action", "query", "search", "url", "link", "href")
            return .browserTool(action: action)
        case "read_image":
            return .readImageTool(path: pick("path", "file", "file_path", "filename"))
        case "memory_write", "memory_get":
            return .memoryTool(action: pick("action", "key", "topic", "subject"))
        default:
            return .shellTool(command: pick("command", "cmd"))
        }
    }

    /// 工具状态:执行中(无结果)→ running;完成 → success/failed/cancelled
    static func toolStatus(for event: ToolCallEvent, message: ChatMessage) -> MiniClawKit.ToolBlockStatus? {
        if event.wasInterrupted { return .cancelled }
        if event.resultText.isEmpty && message.isStreaming {
            return .running
        }
        return event.success ? .success : .failed(message: "")
    }
}
