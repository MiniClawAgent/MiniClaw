import Foundation
import SwiftUI

/// AI 提问的等待/取消中枢。
///
/// 骨架照抄 `ToolConfirmationBridge`（同一套"必达终态"纪律）：
/// - 每个会话只允许 **1 个** 待答问题，避免用户在两个卡片之间来回切；
/// - 有超时兜底（默认 10 分钟）⇒ 到点按"跳过"让模型继续，不会永久挂住引擎；
/// - 停止 / 删除会话 / 引擎销毁时统一 `cancel`，保证 continuation 只恢复一次。
@MainActor
final class AskUserBroker: ObservableObject {
    static let shared = AskUserBroker()

    enum Outcome {
        case answered([UserQuestionAnswer])
        case skipped
        case cancelled
        case timedOut
    }

    private struct Slot {
        let request: UserQuestionRequest
        let continuation: CheckedContinuation<Outcome, Never>
        /// 用户是否已经提交过（防重复恢复）
        var settled: Bool = false
    }

    /// 当前待答（按 callId）。UI 只知道 callId，据此决定卡片是否可交互。
    @Published private(set) var pending: [String: UserQuestionRequest] = [:]

    /// 当前**需要弹出授权窗**的提问（每个会话最多一条）。
    /// 2026-11-16 唐唐定的形态：提问不再内嵌在消息流里（会挤压高度），
    /// 改成类似授权弹窗的居中对话框；会话里只保留一条工具指示器。
    @Published private(set) var active: ActiveQuestion?

    struct ActiveQuestion: Identifiable, Equatable {
        let callId: String
        let sessionID: UUID
        var request: UserQuestionRequest
        var id: String { callId }
    }
    private var slots: [String: Slot] = [:]
    private var sessionByCall: [String: UUID] = [:]

    /// 默认等待时长：用户离开太久就别把引擎挂死了。
    static let timeoutSeconds: TimeInterval = 5 * 60

    func request(_ request: UserQuestionRequest, sessionID: UUID) async -> Outcome {
        let callId = request.callId
        // 同会话已有待答：直接拒绝，避免两张卡片抢同一个槽位。
        guard !sessionByCall.values.contains(sessionID) else { return .skipped }

        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
            self.settle(callId: callId, outcome: .timedOut)
        }
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            slots[callId] = Slot(request: request, continuation: cont)
            sessionByCall[callId] = sessionID
            pending[callId] = request
            active = ActiveQuestion(callId: callId, sessionID: sessionID, request: request)
        }
        timeout.cancel()
        return outcome
    }

    /// 用户提交答案。
    func submit(callId: String, answers: [UserQuestionAnswer]) {
        settle(callId: callId, outcome: answers.isEmpty ? .skipped : .answered(answers))
    }

    /// 取消某会话的全部待答（停止 / 删除会话 / 引擎退出）。
    func cancel(sessionID: UUID) {
        for (callId, sid) in sessionByCall where sid == sessionID {
            settle(callId: callId, outcome: .cancelled)
        }
    }

    /// 查询某次调用的待答请求（UI 判断卡片是否可点）。
    func pendingRequest(callId: String) -> UserQuestionRequest? { pending[callId] }

    private func settle(callId: String, outcome: Outcome) {
        guard var slot = slots[callId], !slot.settled else { return }
        slot.settled = true
        slots[callId] = nil
        sessionByCall[callId] = nil
        pending[callId] = nil
        if active?.callId == callId { active = nil }
        slot.continuation.resume(returning: outcome)
    }
}
