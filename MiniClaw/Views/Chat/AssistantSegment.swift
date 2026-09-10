import SwiftUI

/// 消息穿插段（2026-08-09 块级拆分）：正文片段 / 工具调用卡 / 思考段。
enum AssistantSegment {
    /// - ordinal：该文本段在本条消息中的序号，用作稳定渲染身份（正文片段可能有多个）。
    case text(String, ordinal: Int)
    case tool(ToolCallEvent)
    case reasoning(ReasoningSegment)
}

extension AssistantSegment: Identifiable {
    /// 渲染身份（2026-09-07）：此前 ForEach 用数组下标 `\.offset` 作 id，
    /// 中段插入工具/思考段时后续下标整体右移，SwiftUI 复用同一下标的 View
    /// 并喂入错位内容。改用语义身份后，段顺序变化不影响已有段的身份：
    /// 工具取事件 id、思考取段序号、文本取段序号（均为稳定值）。
    var id: String {
        switch self {
        case .text(_, let ordinal): return "t\(ordinal)"
        case .tool(let ev): return "o\(ev.id.uuidString)"
        case .reasoning(let rs): return "r\(rs.index)"
        }
    }

    /// 高度缓存签名（2026-08-09）：文本取长度、工具取事件 id、思考取文本长度。
    var contentSignature: String {
        // 长度 + 内容前缀共同签名（2026-08-09 修复 P2：同长度不同内容避免误命中高度缓存）
        switch self {
        case .text(let t, _): return "t\(t.count)-\(t.prefix(32))"
        case .tool(let ev): return "tool\(ev.id.uuidString.prefix(8))-r\(ev.resultText.count)"
        case .reasoning(let rs): return "r\(rs.text.count)-\(rs.text.prefix(32))"
        }
    }
}

