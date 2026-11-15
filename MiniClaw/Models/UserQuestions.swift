import Foundation

/// AI 向用户提问（选择题 / 征求意见）的载荷。
///
/// 一份 `UserQuestionRequest` 对应一次 `ask_user` 工具调用：
/// 问题列表 + 用户答案 + 状态。它既用于运行期（卡片交互），
/// 也用于历史回放（由 `ToolCallEvent.arguments/resultText` 还原）。
struct UserQuestionOption: Codable, Hashable, Identifiable {
    var label: String
    var description: String?
    var id: String { label }
}

struct UserQuestion: Codable, Hashable, Identifiable {
    var id: String
    var question: String
    var detail: String?
    var header: String?
    var options: [UserQuestionOption]?
    var multiSelect: Bool?
    /// 是否允许自由输入（缺省 true；没有选项时强制 true）。
    var allowCustom: Bool?
}

struct UserQuestionAnswer: Codable, Hashable {
    var id: String
    var selected: [String]
    var custom: String?
}

enum UserQuestionState: String, Codable {
    case pending
    case answered
    case skipped
    case cancelled
    case expired
}

/// 卡片渲染与工具返回共用的载体。
struct UserQuestionRequest: Codable, Hashable {
    var callId: String
    var questions: [UserQuestion]
    /// nil = 还没答；空数组 = 全部跳过。
    var answers: [UserQuestionAnswer]?
    var state: UserQuestionState
    var createdAt: Date

    /// 给模型看的紧凑结果。
    var modelFacingJSON: String {
        switch state {
        case .pending:
            return #"{"pending":true}"#
        case .cancelled:
            return #"{"error":"cancelled"}"#
        case .expired:
            return #"{"error":"no_answer"}"#
        case .answered, .skipped:
            var items: [String] = []
            for q in questions {
                let a = answers?.first { $0.id == q.id }
                let selected = a?.selected ?? []
                var obj = #"{"id":"\#(Self.escape(q.id))""#
                obj += #","selected":["# + selected.map { #""\#(Self.escape($0))""# }.joined(separator: ",") + "]"
                if let custom = a?.custom, !custom.isEmpty {
                    obj += #","custom":"\#(Self.escape(custom))""#
                }
                obj += "}"
                items.append(obj)
            }
            let skipped = questions.filter { q in
                let a = answers?.first { $0.id == q.id }
                return (a?.selected.isEmpty ?? true) && (a?.custom?.isEmpty ?? true)
            }.count
            return #"{"answers":["# + items.joined(separator: ",") + #"],"skipped":\#(skipped)}"#
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

extension UserQuestionRequest {
    static func decode(from content: String) -> UserQuestionRequest? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UserQuestionRequest.self, from: data)
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
