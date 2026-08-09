import Foundation
import OpenMinisPort

// MARK: - OM 适配层:消息转换(2026-08-09)
// 把 MiniClaw 的 SwiftData 消息模型转换为 OpenMinis 消息列表组件所需的
// ChatMessage/AssistantBlock 形态。纯转换,不持有状态。

enum OMChatAdapter {

    // MARK: - 消息级转换

    /// 把 MiniClaw 消息转换为 OM 形态(含 blocks 拆分)
    static func convert(_ message: ChatMessage) -> OpenMinisPort.ChatMessage {
        let om = OpenMinisPort.ChatMessage(role: omRole(message), content: message.content)
        om.blocks = buildBlocks(message)
        om.isAwaitingModelResponse = message.isStreaming
        return om
    }

    private static func omRole(_ message: ChatMessage) -> OpenMinisPort.ChatMessageRole {
        switch message.role {
        case .user: return .user
        case .assistant, .tool: return .assistant
        case .system: return .systemInfo
        }
    }

    // MARK: - 块级转换

    /// 按 timelineOrder 交错生成 blocks:思考段/正文/工具调用
    private static func buildBlocks(_ message: ChatMessage) -> [OpenMinisPort.AssistantBlock] {
        var items: [(order: Int, block: OpenMinisPort.AssistantBlock)] = []

        for seg in message.reasoningSegments {
            let block = OpenMinisPort.AssistantBlock(kind: .thinking, content: seg.text)
            items.append((seg.timelineOrder, block))
        }

        if !message.content.isEmpty {
            let textBlock = OpenMinisPort.AssistantBlock(kind: .text, content: message.content)
            // 正文排在所有思考/工具之后(与历史渲染一致)
            items.append((Int.max - 1, textBlock))
        }

        for event in message.toolCalls {
            let block = OpenMinisPort.AssistantBlock(kind: toolKind(event.name), content: event.resultText)
            block.toolUseId = event.callID ?? event.id.uuidString
            block.toolInputArgs = event.arguments
            block.toolDuration = event.duration
            block.toolStatus = toolStatus(for: event, message: message)
            items.append((event.timelineOrder, block))
        }

        return items.sorted { $0.order < $1.order }.map(\.block)
    }

    /// 工具名 → OM 块类型(10 种 kind 映射)
    private static func toolKind(_ name: String) -> OpenMinisPort.AssistantBlockKind {
        switch name {
        case "shell_execute": return .shellTool(command: "")
        case "file_read": return .fileReadTool(path: "")
        case "file_write": return .fileWriteTool(path: "")
        case "file_edit": return .fileEditTool(path: "")
        case "browser", "miniclaw-browser-use": return .browserTool(action: "")
        case "read_image": return .readImageTool(path: "")
        case "memory_write", "memory_get": return .memoryTool(action: "")
        default: return .shellTool(command: "")
        }
    }

    /// 工具状态:执行中(无结果)→ running;完成 → success/failed/cancelled
    private static func toolStatus(for event: ToolCallEvent, message: ChatMessage) -> OpenMinisPort.ToolBlockStatus? {
        if event.wasInterrupted { return .cancelled }
        if event.resultText.isEmpty && message.isStreaming {
            return .running
        }
        return event.success ? .success : .failed(message: "")
    }
}
