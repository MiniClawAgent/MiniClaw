import Foundation
import ActivityKit
import CoreLocation
import UserNotifications

/// 跨视图共享的 Agent 运行态：后台设置页据此显示「活跃 / 空闲」。
@MainActor
final class AgentRuntimeStatus: ObservableObject {
    static let shared = AgentRuntimeStatus()
    @Published var isAgentActive: Bool = false
    @Published var lastTitle: String = ""

    func setActive(title: String) {
        isAgentActive = true
        lastTitle = title
    }

    func setInactive() {
        isAgentActive = false
    }
}

/// 同一会话只维护一个 Live Activity 的句柄表（sessionID -> Activity）。
/// 避免同一会话连续多轮对话拉起多个 LA；新一轮对话直接更新既有 LA 而非新建。
/// 作为实例属性（与旧版 currentActivity 同处），规避「模块级全局可变状态」的并发安全检查。

// MARK: - 通知管理

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func authorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// 通知点击 → 跳转对应会话（开始/完成通知都带 sessionID）。
    /// 冷启动（App 被杀后点通知）：进程拉起后等 SessionManager/UI 就绪再切会话。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sid = userInfo["sessionID"] as? String, let uuid = UUID(uuidString: sid) {
            Task { @MainActor in
                // 等待导航就绪（冷启动时视图树尚未构建，立即切 selectedSession 可能被覆盖）。
                try? await Task.sleep(for: .milliseconds(400))
                if let session = SessionManager.shared.session(id: uuid) {
                    AppState.shared?.selectedSession = session
                    AppLogger.shared.info(String(format: L10n.l("bg_notification_tap"), session.title), category: "BG")
                }
            }
        }
        completionHandler()
    }

    /// 快捷指令派发任务后立即提示「已开始」（对齐参考实现的 Task Started 通知）。
    /// 受后台通知开关控制；正文带任务提示词预览，便于用户在通知中心区分多条任务。
    func notifyTaskStarted(title: String, promptPreview: String, sessionID: UUID? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: L10n.l("started_processing"), promptPreview)
        content.sound = .default
        content.threadIdentifier = "miniclaw-agent"
        if let sessionID { content.userInfo["sessionID"] = sessionID.uuidString }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            AppLogger.shared.error(String(format: L10n.l("bg_start_notification_failed"), String(describing: error)), category: "BG")
        }
    }

    func notifyTaskComplete(title: String, success: Bool, lastReply: String? = nil, sessionID: UUID? = nil) async {
        let content = UNMutableNotificationContent()
        // 标题 = 会话名称；正文 = 最后回复内容（不限字数，折叠空白）。
        content.title = title
        content.body = Self.completionBody(reply: lastReply, success: success)
        content.sound = .default
        content.threadIdentifier = "miniclaw-agent"
        if let sessionID { content.userInfo["sessionID"] = sessionID.uuidString }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            AppLogger.shared.error(String(format: L10n.l("bg_complete_notification_failed"), String(describing: error)), category: "BG")
        }
    }

    /// 通知正文：最后回复内容不限字数（不做手动截断，超长由系统通知展示上限省略），
    /// 换行/空格/Tab 全部折叠为单个空格——正文紧凑连续，不会因模型排版换行显得稀碎。
    /// 无回复时回退完成/结束文案。
    private static func completionBody(reply: String?, success: Bool) -> String {
        let fallback = success ? L10n.l("the_agent_has_completed_this_task") : L10n.l("the_agent_has_ended_this_task")
        guard let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return reply
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

// MARK: - 模糊定位保活

/// 用「显著位置变化」监测 + 降低精度（模糊定位）在后台保持 App 可被唤醒。
/// 仅当「后台运行」开启且已授权定位时启动；不开启时完全不采集。
final class BackgroundLocationKeeper: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?

    func startIfAuthorized() {
        // iOS14+:authorizationStatus() 类方法已弃用,用实例查询(语义等价)。
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyReduced   // 模糊定位
        m.pausesLocationUpdatesAutomatically = false
        manager = m
        m.startMonitoringSignificantLocationChanges()
    }

    func stop() {
        manager?.stopMonitoringSignificantLocationChanges()
        manager = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLogger.shared.warn(String(format: L10n.l("bg_location_keepalive_failed"), error.localizedDescription), category: "BG")
    }
}

// MARK: - 后台任务协调器

/// 引擎在 Agent 开始 / 完成时调用，统一编排：
/// - Live Activity（灵动岛 / 锁屏）任务进度展示
/// - 模糊定位后台保活
/// - 完成时系统通知
///
/// 注意：本类**刻意不**声明 `@MainActor`。
/// ActivityKit 的 `Activity.update` / `end` 是 nonisolated async，而 `Activity` 句柄本身并非 `Sendable`。
/// 若本类处于 `@MainActor` 隔离，调用这些方法会把 main-actor 隔离的 `Activity` 跨域发送给非隔离方法，
/// 触发 Swift 6「sending risks data races」而编译失败。故本类运行于非隔离上下文，
/// 仅把需要触达主线程的 `AgentRuntimeStatus` / `NotificationManager` 调用显式包进 `Task { @MainActor in }` / `MainActor.run`。
