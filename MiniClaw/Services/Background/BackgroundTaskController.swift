import Foundation
import ActivityKit
import CoreLocation
import UserNotifications

// MARK: - 运行时状态（供后台页「Agent状态」展示）

/// 跨视图共享的 Agent 运行态：后台设置页据此显示「活跃 / 空闲」。
final class BackgroundTaskController {
    // 全部访问均源自主线程（引擎经 Task { @MainActor in } 调用），外部已同步，故以 nonisolated(unsafe) 豁免并发安全检查。
    nonisolated(unsafe) static let shared = BackgroundTaskController()

    /// 同一会话只维护一个 Live Activity 的句柄表（sessionID -> Activity）。

    // MARK: 生命周期

    /// 取出某会话当前仍存活的 Live Activity。
    /// 去重以【系统活动列表】为权威来源：按 attributes.sessionID 匹配，
    /// 内存缓存（liveActivities）仅作加速。这样即使缓存因并发/重入命中失败，
    /// 也能通过系统列表发现「该会话已有一个活动」从而避免重复创建。
    @available(iOS 16.1, *)
    private func liveActivities(forSessionID sid: String) -> [Activity<MiniClawLiveActivityAttributes>] {
        var result: [Activity<MiniClawLiveActivityAttributes>] = []
        var seen = Set<String>()
        if let cached = LiveActivityState.shared.liveActivities[sid] {
            result.append(cached); seen.insert(cached.id)
        }
        for act in Activity<MiniClawLiveActivityAttributes>.activities where act.attributes.sessionID == sid {
            if seen.insert(act.id).inserted { result.append(act) }
        }
        return result
    }

    func agentDidStart(sessionID: String?, title: String, icon: String = "bubble.left.and.bubble.right.fill") {
        Task { @MainActor in AgentRuntimeStatus.shared.setActive(title: title) }

        let bg = SettingsStore.shared.settings.background
        Task { @MainActor in
            TaskPipController.shared.noteTaskStarted(sessionID: sessionID, title: title, icon: icon)
            // ★ 发送消息(任务启动)立即预热 PiP 基础设施——不等 AI 第一步行动。
            // 用户发消息后可能立马切 App,退后台时基础设施已就绪 → 系统立即自动启动,零延迟。
            TaskPipController.shared.ensurePipIfRunning()
        }
        if #available(iOS 16.1, *) {
            guard bg.backgroundRun, bg.liveActivity else { return }

            // ★ 会话级去重（以系统活动列表为权威）：
            //   只要该系统会话已有一个【仍活跃】的 Live Activity，就【更新】它而非新建，
            //   并顺手清理同会话下因历史竞态多出来的重复活动。
            //   注意：上一轮结束后活动已被 end(.after)（系统待移除，activityState != .active）
            //   或 App 重启后系统里残留已结束活动——这些都不能再 update，必须新建。
            if let sid = sessionID {
            let existing = liveActivities(forSessionID: sid)
            // 找第一个【仍活跃】的活动复用，而不是 existing.first——
            // Activity.activities 顺序不保证，first 可能是已结束的旧活动，
            // 导致误入 create 分支、遗漏清理仍活跃的重复活动。
            if let keep = existing.first(where: { $0.activityState == .active }) {
            LiveActivityState.shared.liveActivities[sid] = keep
            // 兜底：清理同会话下所有其他活动（含活跃重复 + 已结束残留），
            // 确保屏幕上不会叠出多个。仅捕获 dup.id（String），在 Task 内按 id 定位并结束。
            for dup in existing where dup.id != keep.id {
            let dupID = dup.id
            Task { @MainActor in
            for activity in Activity<MiniClawLiveActivityAttributes>.activities where activity.id == dupID {
            await activity.end(
            using: MiniClawLiveActivityAttributes.ContentState(
            sessionTitle: "", progressText: String(localized: "ended"), phase: "completed"
            ),
            dismissalPolicy: .immediate
            )
            }
            }
            }
            Task { @MainActor in
            await BackgroundTaskController.shared.updateActivity(sessionID: sid) { s in
            var c = s
            c.progressText = String(localized: "thinking")
            c.timeText = Self.nowString()
            c.phase = "running"
            c.status = "running"
            return c
            }
            }
            return
            }
            // 没有活跃活动：先把同会话所有旧活动（含 dismissal 窗口内残留）立即结束，
            // 再新建——否则旧的会继续显示在锁屏，新的叠上去，产生多个通知。
            LiveActivityState.shared.liveActivities[sid] = nil
            for old in existing {
            let oldID = old.id
            Task { @MainActor in
            for activity in Activity<MiniClawLiveActivityAttributes>.activities where activity.id == oldID {
            await activity.end(
            using: MiniClawLiveActivityAttributes.ContentState(
            sessionTitle: "", progressText: String(localized: "ended"), phase: "completed"
            ),
            dismissalPolicy: .immediate
            )
            }
            }
            }
            }
            startLiveActivity(sessionID: sessionID, title: title, icon: icon)
        }
    }

    func agentDidProgress(_ text: String, sessionID: String?) async {
        guard let sid = sessionID else { return }
        await TaskPipController.shared.updateProgress(sessionID: sid, text: text)
        if #available(iOS 16.1, *) {
            await updateActivity(sessionID: sid) { s in
            var c = s
            c.progressText = text
            c.timeText = Self.nowString()
            c.phase = "running"
            c.status = "running"
            return c
            }
        }
    }

    /// 刷新时间戳（每次进度/速度更新时顺带刷新标题行右侧时间）。
    func agentDidUpdateTime(sessionID: String?) async {
        guard let sid = sessionID else { return }
        if #available(iOS 16.1, *) {
            await updateActivity(sessionID: sid) { s in
            var c = s
            c.timeText = Self.nowString()
            return c
            }
        }
    }

    /// 智能体 / 用户更新会话标题或图标后回传：重新读取会话元信息并刷新（保留进度/状态）。
    func agentDidUpdateSession(sessionID: String?) {
        guard let sid = sessionID, let uuid = UUID(uuidString: sid) else { return }
        Task { @MainActor in
            let session = SessionManager.shared.session(id: uuid)
            let title = session?.title ?? "MiniClaw"
            let icon = session?.iconName ?? ChatSession.defaultIcon
        if #available(iOS 16.1, *) {
            await BackgroundTaskController.shared.updateActivity(sessionID: sid) { s in
            var c = s
            c.sessionTitle = title
            c.sessionIcon = icon
            return c
            }
        }
        }
    }

    func agentDidFinish(sessionID: String?, success: Bool, lastReply: String? = nil) async {
        Task { @MainActor in AgentRuntimeStatus.shared.setInactive() }
        await TaskPipController.shared.taskEnded(sessionID: sessionID)

        // ★ 官方机制结束 Live Activity（源头修复 2026-08-05）：
        //   旧实现 = 进程内 Task.sleep 5 分钟后调 end —— App 挂起/被杀后进程冻结，
        //   定时器永不触发，活动残留在锁屏/灵动岛（用户实测 5 分钟不消失）。
        //   官方（ActivityUIDismissalPolicy.after(_:), iOS 16.1+）：任务完成时直接
        //   end(content, dismissalPolicy: .after(5min))，由【系统】在「指定时间」或
        //   「结束后 4 小时」先到者移除 UI —— 不依赖 App 进程存活，前后台/被杀均生效。
        //   终态内容（最后回复/已完成）随 end 一并展示，无需先 update 再 end。
        if #available(iOS 16.1, *) {
            if let sid = sessionID, let act = liveActivities(forSessionID: sid).first {
            var c = act.contentState
            // 完成态中间内容：展示 智能体最后回复（而非「已完成」），最右侧状态图标已显示完成状态。
            let finishedText: String
            if success, let reply = lastReply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishedText = String(reply.prefix(300))
            } else {
            finishedText = success ? String(localized: "completed") : String(localized: "ended")
            }
            c.progressText = finishedText
            c.phase = success ? "completed" : "failed"
            c.status = success ? "completed" : "failed"
            c.timeText = Self.nowString()
            await endLiveActivity(sessionID: sid, state: c,
            dismissalPolicy: .after(Date().addingTimeInterval(Self.completionAutoEndDelay)))
        }
        }
        sendCompletionNotificationIfEnabled(success: success, lastReply: lastReply, sessionID: sessionID.flatMap(UUID.init(uuidString:)))
    }

    // MARK: Live Activity

    /// 启动会话 Live Activity。默认前台调用；快捷指令意图遵循 LiveActivityIntent 时，
    /// 在 perform() 内调用可获系统后台启动授权（官方唯一无 UI 后台启动路径）。
    @available(iOS 16.1, *)
    func startLiveActivity(sessionID: String?, title: String, icon: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // 第一排 智能体名字：读取用户在「灵魂（人格）」设置里配置的名字，而非写死。
        let rawSoulName = SettingsStore.shared.settings.soul.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawSoulName.isEmpty ? "MiniClaw" : rawSoulName
        let attrs = MiniClawLiveActivityAttributes(
            aiName: displayName,
            sessionID: sessionID ?? ""
        )
        let state = MiniClawLiveActivityAttributes.ContentState(
            sessionIcon: icon,
            sessionTitle: title,
            progressText: String(localized: "thinking"),
            timeText: Self.nowString(),
            phase: "running",
            status: "running"
        )
        do {
            let activity = try Activity.request(
                attributes: attrs,
                contentState: state,
                pushType: nil
            )
            if let sid = sessionID { LiveActivityState.shared.liveActivities[sid] = activity }
        } catch {
            AppLogger.shared.error(String(format: String(localized: "bg_liveactivity_failed"), String(describing: error)), category: "BG")
        }
    }

    /// 任务完成 / 手动停止后的自动移除延迟（官方 dismissalPolicy.after 的保留窗口）。
    /// 系统在「该时间点」或「活动结束后 4 小时」先到者移除，不依赖 App 进程存活。
    private static let completionAutoEndDelay: TimeInterval = 5 * 60

    /// 结束该系统会话下【所有】活动并清理缓存（state 为终态展示内容）。
    @available(iOS 16.1, *)
    private func endLiveActivity(sessionID: String, state: MiniClawLiveActivityAttributes.ContentState, dismissalPolicy: ActivityUIDismissalPolicy) async {
        for act in liveActivities(forSessionID: sessionID) {
            await act.end(using: state, dismissalPolicy: dismissalPolicy)
            // 先收集再删除：遍历字典的同时 removeValue 是 Swift 未定义行为。
            let staleKeys = LiveActivityState.shared.liveActivities.keys.filter { LiveActivityState.shared.liveActivities[$0]?.id == act.id }
            for k in staleKeys {
                LiveActivityState.shared.liveActivities.removeValue(forKey: k)
            }
        }
    }

    /// 会话被删除时显式关闭其 Live Activity（会话级生命周期的收尾点）。
    /// 删除即终局：立即移除，不保留。
    func endSessionActivity(sessionID: String) {
        Task { @MainActor in
        if #available(iOS 16.1, *) {
            let state = MiniClawLiveActivityAttributes.ContentState(
            sessionTitle: "",
            progressText: String(localized: "ended"),
            phase: "completed"
            )
            await BackgroundTaskController.shared.endLiveActivity(sessionID: sessionID, state: state, dismissalPolicy: .immediate)
        }
        }
    }

    /// 关闭全部 Live Activity：用于 App 启动时清理上一运行残留的旧活动
    ///（单例内存表在重启后为空，但系统里可能仍挂着旧会话的活动）。
    func endAllLiveActivities() {
        Task { @MainActor in
        if #available(iOS 16.1, *) {
            for activity in Activity<MiniClawLiveActivityAttributes>.activities {
            await activity.end(
            using: MiniClawLiveActivityAttributes.ContentState(sessionTitle: "", progressText: String(localized: "ended"), phase: "completed"),
            dismissalPolicy: .immediate
            )
            }
            LiveActivityState.shared.liveActivities.removeAll()
        }
        }
    }

    /// 字段级更新：读取活动当前 ContentState，套用 mutate 后整体更新。
    /// 避免「每次更新都重建整段状态」导致其它动态字段（标题/速度）被清掉。
    @available(iOS 16.1, *)
    private func updateActivity(sessionID sid: String, mutate: @Sendable (MiniClawLiveActivityAttributes.ContentState) -> MiniClawLiveActivityAttributes.ContentState) async {
        guard let activity = liveActivities(forSessionID: sid).first else { return }
        let newState = mutate(activity.contentState)
        await activity.update(using: newState)
    }

    /// 当前时刻字符串（HH:mm），用于第三排时间列。
    private static func nowString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    // MARK: 会话状态变更（暂停 / 停止 / 中断）

    /// 用户软暂停（安全点落地）：右上角状态图标切到「已暂停」，中间内容保持不变。
    func agentDidPause(sessionID: String?) {
        guard let sid = sessionID else { return }
        Task { @MainActor in
        if #available(iOS 16.1, *) {
            await BackgroundTaskController.shared.updateActivity(sessionID: sid) { s in
            var c = s
            c.progressText = String(localized: "paused")
            c.timeText = Self.nowString()
            c.phase = "running"
            c.status = "paused"
            return c
            }
        }
        }
    }

    /// 用户手动停止（engine.cancel）：终态「已停止」+ 官方 after 策略 5 分钟后移除
    /// （同 agentDidFinish：系统级移除，不依赖 App 进程存活）。
    func agentDidStop(sessionID: String?) {
        guard let sid = sessionID else { return }
        Task { @MainActor in
            TaskPipController.shared.taskEnded(sessionID: sessionID)
        }
        Task { @MainActor in
        if #available(iOS 16.1, *) {
            guard let act = BackgroundTaskController.shared.liveActivities(forSessionID: sid).first else { return }
            var c = act.contentState
            c.progressText = String(localized: "stopped")
            c.timeText = BackgroundTaskController.nowString()
            c.phase = "running"
            c.status = "stopped"
            await BackgroundTaskController.shared.endLiveActivity(
            sessionID: sid,
            state: c,
            dismissalPolicy: .after(Date().addingTimeInterval(BackgroundTaskController.completionAutoEndDelay))
            )
        }
        }
    }

    /// 熔断 / 异常中断（无效工具、重复失败工具等）：右上角状态图标切到「已中断」。
    func agentDidInterrupt(sessionID: String?) {
        guard let sid = sessionID else { return }
        Task { @MainActor in
            if #available(iOS 16.1, *) {
                await BackgroundTaskController.shared.updateActivity(sessionID: sid) { s in
                    var c = s
                    c.progressText = String(localized: "interrupted")
                    c.timeText = Self.nowString()
                    c.phase = "failed"
                    c.status = "interrupted"
                    return c
                }
            }
        }
    }

    // MARK: 快捷指令派发

    /// 快捷指令 headless 派发时的立即保活（eager arm，对齐参考实现）：
    /// 在 intent 执行窗口内直接点亮 Live Activity，消除「引擎尚未启动 → 进程已被挂起」
    /// 的窗口期。引擎启动后 agentDidStart 会再次调用（幂等）。受「后台运行」开关控制。
    ///
    /// （原「定位保活」环节已于 2026-09-07 移除——见 BackgroundTaskComponents 注释。）
    func armForIntent(sessionID: String?) {
        let bg = SettingsStore.shared.settings.background
        guard bg.backgroundRun else {
            AppLogger.shared.info(String(localized: "intent_keepalive_skipped"), category: "Intent")
            return
        }
        if let sid = sessionID, let uuid = UUID(uuidString: sid) {
            Task { @MainActor in
                let title = SessionManager.shared.session(id: uuid)?.title ?? "MiniClaw"
                AgentRuntimeStatus.shared.setActive(title: title)
            }
        }
        AppLogger.shared.info(String(localized: "intent_keepalive_armed"), category: "Intent")
    }

    // MARK: 通知

    private func sendCompletionNotificationIfEnabled(success: Bool, lastReply: String?, sessionID: UUID?) {
        let bg = SettingsStore.shared.settings.background
        guard bg.notifications else { return }
        Task {
            let title = await MainActor.run { AgentRuntimeStatus.shared.lastTitle }
            guard await NotificationManager.shared.authorized() else { return }
            await NotificationManager.shared.notifyTaskComplete(title: title, success: success, lastReply: lastReply, sessionID: sessionID)
        }
    }
}


/// Live Activity 句柄表的可用性容器(iOS16 兼容 2026-08-12):
/// ActivityKit 是 iOS16.1+ 框架,存储属性不能标 @available,
/// 故把句柄表收进本 @available 单例;16.0 设备上 LiveActivityState.shared 不可访问,
/// 所有访问点都在 if #available(iOS 16.1, *) 守卫内,不会触达。
@available(iOS 16.1, *)
private final class LiveActivityState: @unchecked Sendable {
    static let shared = LiveActivityState()
    var liveActivities: [String: Activity<MiniClawLiveActivityAttributes>] = [:]
}
