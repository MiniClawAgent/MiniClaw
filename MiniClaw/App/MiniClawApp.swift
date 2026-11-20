import SwiftUI
import UIKit

@main
struct MiniClawApp: App {
    /// 后台下载唤醒收尾（URLSession.background 必需）：系统在后台下载完成时唤醒 App，
    /// 经此回调转交 completionHandler，由 BackgroundDownloader 在事件处理完后调用。
    @UIApplicationDelegateAdaptor(MiniClawAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    init() {
        // 早期置位 AppState.shared，缩短 AppIntent（Siri/快捷指令）在冷启动后
        // 立刻派发任务时的竞态窗口（原先只在 WindowGroup 的 .task 里置位）。
        AppState.shared = appState
        // 提前加载会话持久层：快捷指令/深链冷启动拉起 App 进程时即可建会话/查会话，
        // 不再等 HomeView 出现（后台 intent 无 UI 时 HomeView 可能不出现，任务会静默丢失）。
        // HomeView 处仍保留 load 调用（幂等，仅重读磁盘）。
        SessionManager.shared.load()
        // App 启动即创建运行时目录，并同步随版本发布的项目托管规则。
        _ = FileSystemManager.shared
        // 安装崩溃/信号处理器与主线程卡死看门狗（依赖 FileSystemManager 已创建根目录）。
        AppLogger.shared.installCrashHandlers()
        // 注册 MetricKit 系统级崩溃诊断收集（下次启动接收系统 .ips 摘要，
        // 兜底 App 内信号处理器抓不到的崩溃：LLDB 接管/堆损坏/SIGKILL）。
        MetricKitCollector.shared.start()
        // 检测上一轮异常退出并生成崩溃报告（写入 .crashalive 标记）。
        CrashReporter.shared.checkAbnormalExit()
        // 模型能力目录已并入厂商适配器文件(编译期),无需种子拷贝。
        // 首次打开即部署 Linux rootfs 并预热 iSH 内核（要求 3 + 不再等待命令）。
        // 两者都在后台异步进行，不阻塞首屏；boot 失败可重试且不污染启动
        // （MiniClawiSH.m 用可重置串行队列守卫，预热/执行时若失败会自动重试）。
        #if ISH_ENABLED
        LinuxShellRuntime.prewarmBootInBackground()
        #endif
        // 恢复子代理头像 / 对话（落盘数据），使 App 被杀后重开仍保留。
        SubagentStore.shared.load()
        // 恢复子代理运行期记录（身份+角色+聚焦+上下文历史，B 方案）：
        // 复用分支据此跨 App 重启继续命中，子代理的「会话感」不因重启丢失。
        SubagentRuntimeRegistry.shared.rebuild()
        // 加载子代理角色（profile）：bundle 同步已移后台（线程治理 P0），
        // 先等同步完成再后台读盘加载，避免首启读到空目录。
        // 启用状态在主线程先快照（SettingsStore 后台裸读竞态防护，2026-08-14 崩溃修复同款约束）。
        let subagentEnabledStates = SettingsStore.shared.settings.skillEnabledStates
        let subagentBuiltinIds = FileSystemManager.shared.bundledPluginIds()
        // [2026-11-20] 构建标记：用于确认设备上跑的到底是哪一版（MCP 命名修复 v2）。
        AppLogger.shared.info("[Build] MCPNaming=v2", category: "App")
        FileSystemManager.shared.syncBundledResourcesInBackground()
        Task {
            await FileSystemManager.shared.waitForBundledSync()
            await Task.detached(priority: .userInitiated) {
                SubAgentProfileStore.shared.reload(enabledStates: subagentEnabledStates,
                                                   builtinIds: subagentBuiltinIds)
            }.value
        }
        // 数据预热：启动时同步加载会话持久层（SessionManager.load 已预热内存缓存），
        // 首页首帧即可显示数据，消除空列表闪烁。
        AppLogger.shared.info("启动预热：已加载 \(SessionManager.shared.sessions.count) 个会话", category: "Lifecycle", subsystem: "Startup")
        // 清理上一运行残留的 Live Activity（单例内存表重启后为空，但系统里可能仍挂着旧的）。
        BackgroundTaskController.shared.endAllLiveActivities()
        // 同步系统初始化：注册 hydrator + transport（不启动，需用户开启 iCloud 同步后才 start）。
        Task { @MainActor in SyncBootstrap.setup() }
        // 后台任务注册（BGTaskScheduler）：记忆整理 / 过期文件维护由系统在空闲时调度执行。
        // 与 BackgroundTaskCoordinator 的宽限期互补——宽限期管「当前正在跑的回复」，
        // BGTask 管「稍后该做的事」（App 挂起/被杀也能在系统合适时机执行）。
        BackgroundScheduler.shared.registerAndSchedule()
        // 注意：麦克风/语音识别权限【不在启动时预请求】。
        // 真机验证：在 App.init() 调 requestRecordPermission 时若用户点「拒绝」，
        // TCC 回调在 com.apple.ccserver 队列触发 AVAudioSession 主队列断言崩溃，
        // 而启动期崩溃 = App 直接打不开。改为运行时只查状态、引导去设置页授予
        // （详见 ChatInputBar.requestMicThenStart）。
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    AppState.shared = appState
                    // OAuth 服务商：启动时异步刷新 令牌（过期自动续期），回填内存 apiKey 供运行时使用。
                    // 主 actor 上下文创建，避免非 Sendable AppState 的 sending 检查报错。
                    Task { @MainActor in
                        await AppState.shared.refreshOAuthTokensIfNeeded()
                    }
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
            ScenePhaseBridge()
        }
    }

    /// 轻量视图：观察场景生命周期并记录到运行日志（前台/后台/活跃切换）。
    private struct ScenePhaseBridge: View {
        @Environment(\.scenePhase) private var phase
        var body: some View {
            EmptyView()
                .onChange(of: phase) { newPhase in
                    let desc: String
                    switch newPhase {
                    case .active:
                        desc = "Active"
                        // 分享收件箱兜底：Share Extension 无法唤起主 App（平台限制），
                        // 内容落在 App Group，这里在回前台 / 冷启动时取出派发。
                        Task { @MainActor in
                            SharedInboxCoordinator.shared.drainIfNeeded(reason: "scene-active")
                        }
                        // 回前台：OAuth 服务商 令牌 过期自动续期（内存回填，不落盘）。
                        Task { await AppState.shared.refreshOAuthTokensIfNeeded() }
                        // 回前台（用户点 PiP 进入 / 从桌面进入）：判断任务完成状态——
                        // 已完成 → 彻底关闭 PiP（清登记表，退后台不再弹）；未完成 → 保持。
                        Task { @MainActor in
                            TaskPipController.shared.onAppForeground()
                        }
                    case .inactive: desc = "Inactive"
                    case .background:
                        desc = "Background"
                        // 退后台：任务仍在运行（回前台被系统收起后）→ 重新弹出 PiP。
                        // 任务已结束(runningTasks 空)时 ensure 自动跳过。
                        Task { @MainActor in
                            TaskPipController.shared.ensurePipIfRunning()
                        }
                        // App 进后台：对仍在运行期注册表中的会话触发「复盘分身」，
                        // 沉淀记忆并生成会话摘要。记忆总开关关闭时整体跳过：用户主动
                        // 关闭记忆即不希望任何后台记录。去重与「无新消息跳过」由服务内部保证。
                        if SettingsStore.shared.settings.memory.isEnabled {
                            for (sid, runtime) in AppState.shared.chatRuntimes {
                                // 暂停态会话不触发复盘：半截回复沉淀进长期记忆会污染数据质量
                                // （SessionReviewService 只拦 isResponding，这里补上 isPaused）。
                                if runtime.isPaused { continue }
                                SessionReviewService.shared.schedule(sessionID: sid)
                            }
                        }
                    @unknown default: desc = "Unknown"
                    }
                    AppLogger.shared.info("Scene phase → \(desc)", category: "Lifecycle", subsystem: "Lifecycle")
                    CrashReporter.shared.notePhase(
                        desc,
                        // 主线程上下文，可取 UIApplication 的后台剩余时间（判别「后台回收」的关键）。
                        bgTimeRemaining: CrashReporter.currentBackgroundTimeRemaining()
                    )
                    ScenePhaseMonitor.shared.set(desc)
                    #if DEBUG
                    // [2026-09-12 滚动度量出口] 退后台/失活时把整个事件环落盘为 scroll-metrics.json。
                    // 录制开关**不在这里**检查：相位回调对初始值不触发（启动时已是 active），
                    // 挂这里会导致录制从未开启 —— 改为在 `ScrollMetricsRecorder.record` 里做
                    // 一次性检查（首次记录尝试时执行，不依赖任何生命周期钩子）。
                    if newPhase == .inactive || newPhase == .background {
                        ScrollMetricsRecorder.shared.dumpToFile()
                    }
                    #endif
                    // App 进入 active 后主动触发一次 iSH/Alpine 启动（用已修正的稳定路径）。
                    // 冷启动早期异步 do_boot 易失败，此刻进程/文件系统/场景均已就绪，
                    // 与「检测」同一时机，成功率最高；再由首页轮询兜底重试。
                    #if ISH_ENABLED
                    if newPhase == .active {
                        LinuxShellRuntime.prewarmBootInBackground()
                    }
                    #endif
                }
        }
    }

    // MARK: - Deep Link 处理
    /// 支持的 miniclaw:// 协议：
    ///   资源类：attachments / workspace / shared / browser / memory / rules → 在浏览器打开本地文件
    ///   导航类：settings/<path> → 打开设置；views/alarm → 闹钟页；open_terminal → 终端
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "miniclaw" else { return }

        let absolute = url.absoluteString
        let _ = absolute.lowercased()
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()

        // P1-4：深链派任务 / x-callback-url。命中则交给 AppState 异步登记（需主线程访问 SessionManager），
        // 由目标会话的 ChatView 复用既有发送管线派发，不再走下方导航分支。
        if host == "task" || host == "run" || host == "x-callback-url" {
            let appState = self.appState
            Task { @MainActor in
                _ = appState.handleDeepLinkTask(url: url)
            }
            return
        }

        // 新建会话（桌面小组件「新建对话」快捷入口）：建一个空会话并直接进入。
        if host == "new" {
            Task { @MainActor in
                if let s = SessionManager.shared.createSession(title: String(localized: "new_chat"), source: "widget") {
                    appState.selectedSession = s
                }
            }
            return
        }

        // 资源类：统一解析 attachments/workspace/shared/offloads/browser/memory/rules/skills/mounts。
        // URLComponents 会负责百分号解码；FileSystemManager 会阻止目录穿越。
        // 会话独享资源（attachments/workspace/browser/offloads）必须带会话 id 才能解析到
        // 会话目录下的产物。外部 deep link 本身不携带会话 id，只能取当前选中会话近似；
        // 冷启动时 selectedSession 可能为 nil → 传 nil，仅回落扁平目录（旧文件兼容）。
        if let localPath = BrowserActionHelpers.resolveMiniClawURL(absolute,
                                                                   sessionID: appState.selectedSession?.id) {
            if FileManager.default.fileExists(atPath: localPath) {
                appState.pendingBrowserResourceURL = URL(fileURLWithPath: localPath)
            }
            return
        }

        // 设置页深链（单一事实来源：AppState.routeSettingsDeepLink，会话内链接点击共用）
        if appState.routeSettingsDeepLink(url) {
            return
        }

        // 闹钟页
        if host == "views" && path.contains("alarm") {
            appState.showAlarmView = true
            return
        }

        // 终端
        if host == "open_terminal" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let item = components.queryItems?.first(where: { $0.name == "init_command" }),
               let cmd = item.value {
                appState.pendingTerminalCommand = cmd
            } else {
                appState.pendingTerminalCommand = nil
            }
            return
        }

        // 会话深链：miniclaw://session/<id> → 打开对应会话（供 MiniClaw-sessions-cli open 使用）
        if host == "session" {
            let idString = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let uuid = UUID(uuidString: idString),
               let target = SessionManager.shared.session(id: uuid) {
                appState.selectedSession = target
            }
            return
        }
    }
}

/// 后台下载唤醒收尾（与 BackgroundDownloader 配套）。
/// 系统在 background session 的下载完成/继续时唤醒 App，必须在此创建/引用对应会话
/// （冷启动场景下会话尚未存在）并保存 completionHandler，
/// 否则系统无法把完成事件交给 App，后台下载会丢失。
final class MiniClawAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundDownloader.shared.ensureSession()
        BackgroundDownloader.shared.setBackgroundCompletionHandler(completionHandler)
    }
}
