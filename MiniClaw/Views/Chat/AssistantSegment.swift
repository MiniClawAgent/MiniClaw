import SwiftUI

/// 消息穿插段（2026-08-09 块级拆分）：正文片段 / 工具调用卡 / 思考段。
enum AssistantSegment {
    case text(String)
    case tool(ToolCallEvent)
    case reasoning(ReasoningSegment)
}

extension AssistantSegment {
    /// 高度缓存签名（2026-08-09）：文本取长度、工具取事件 id、思考取文本长度。
    var contentSignature: String {
        // 长度 + 内容前缀共同签名（2026-08-09 修复 P2：同长度不同内容避免误命中高度缓存）
        switch self {
        case .text(let t): return "t\(t.count)-\(t.prefix(32))"
        case .tool(let ev): return "tool\(ev.id.uuidString.prefix(8))-r\(ev.resultText.count)"
        case .reasoning(let rs): return "r\(rs.text.count)-\(rs.text.prefix(32))"
        }
    }
}

