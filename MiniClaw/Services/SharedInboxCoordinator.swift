import Foundation
import UIKit

/// 系统分享收件箱的主 App 侧消费者。
///
/// Share Extension 无法唤起主 App（平台限制），所以分享内容先落 App Group
/// 共享容器，由这里在**深链到达 / 冷启动 / 回前台**时取出并派发成任务：
/// 建会话 → 走既有深链派发（P1-4，附件落会话目录）→ 引擎执行。
///
/// 幂等与兜底：
/// - 取走即清（记录 + 共享文件），不会重复派发；
/// - 超过 `SharedInbox.ttl` 视为弃用内容：清理并**发通知明确告知**，不静默丢弃。
@MainActor
final class SharedInboxCoordinator {
    static let shared = SharedInboxCoordinator()

    /// 取出的分享内容。
    struct Payload {
        let text: String
        let attachments: [AppState.DeepLinkAttachment]
    }

    private init() {}

    /// 取出并清理一条待处理分享；无内容或已过期返回 nil（过期会先提示用户）。
    @discardableResult
    func take() -> Payload? {
        guard let pending = SharedInbox.load() else { return nil }

        let age = Date().timeIntervalSince(pending.timestamp)
        guard age <= SharedInbox.ttl else {
            AppLogger.shared.info(String(format: String(localized: "share_expired_log"),Int(age)),
                                  category: "Share")
            SharedInbox.clear()
            notifyExpired()
            return nil
        }

        // 先读文件数据，再清容器（清理会删除文件）。
        var attachments: [AppState.DeepLinkAttachment] = []
        if let dir = SharedInbox.fileDirectory {
            for name in pending.attachmentNames {
                let url = dir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { continue }
                attachments.append(AppState.DeepLinkAttachment(fileName: name,data: data))
            }
        }
        SharedInbox.clear()
        AppLogger.shared.info("[Share] 收件箱消费：\(pending.items.count) 项（附件 \(attachments.count)，age=\(Int(age))s）",
                              category: "Share")
        return Payload(text: pending.combinedText,attachments: attachments)
    }

    /// 冷启动 / 回前台兜底扫描：有内容就建会话派发（无内容零成本返回）。
    func drainIfNeeded(reason: String) {
        guard let payload = take() else { return }
        dispatch(payload,reason: reason)
    }

    /// 把分享内容派发成一个新会话任务（复用既有深链派发链路）。
    func dispatch(_ payload: Payload,reason: String) {
        guard let appState = AppState.shared else { return }
        guard let session = SessionManager.shared.createSession(
            title: String(localized: "share_session_title"),source: "share") else {
            AppLogger.shared.error("[Share] 建会话失败，放弃本次分享（reason=\(reason)）",category: "Share")
            return
        }
        let prompt = payload.text.isEmpty
            ? String(localized: "share_default_prompt")
            : payload.text
        appState.selectedSession = session
        appState.pendingDeepLinkTask = AppState.PendingDeepLinkTask(
            prompt: prompt,
            targetSessionID: session.id,
            xSuccess: nil,
            xError: nil,
            attachments: payload.attachments
        )
        appState.consumeIntentTaskIfNeeded()
    }

    // MARK: - 过期提示

    /// 过期内容必须让用户知道（用户是显式分享进来的，静默丢弃最糟）。
    private func notifyExpired() {
        Task {
            guard await NotificationManager.shared.authorized() else { return }
            await NotificationManager.shared.notifyNotice(
                title: String(localized: "share_expired_title"),
                body: String(localized: "share_expired_body"))
        }
    }
}
