import UIKit
import AVKit

/// 画中画(PiP)任务进度悬浮窗 —— VideoCall contentSource 路线
///
/// 实现依据(2026-08-08 调研 GlobalRefresh-PiP 项目结论):
/// 系统对「自定义内容 PiP」有两条官方 API:
///   ❌ AVSampleBufferDisplayLayer(视频帧流)—— 对静态 UI / BGRA 帧支持差,
///      前台 possible 恒 false,启动不稳定。
///   ✅ AVPictureInPictureVideoCallViewController + ContentSource(视频通话式)
///      —— 直接把 UIView 塞进 PiP 窗口,会议类 App 均走此路线,启动稳定,
///      无需视频文件 / AVPlayer / 音频会话。
///
/// 本控制器采用后者:进度面板 = 普通 UIView(图标 + 标题 + 进度文本),
/// 复用 BackgroundTaskController 的任务状态流驱动。
///
/// 启动前置条件(照搬调研结论):
///   1. 源 View(pipSourceView)必须挂在窗口上且 bounds 非空
///   2. pipController.isPictureInPicturePossible
/// 启动失败走「延迟递增重试链」(最多 maximumStartAttempts 次),耗尽才报失败。
@MainActor
final class TaskPipController: NSObject {

    static let shared = TaskPipController()

    // MARK: - 常量

    /// PiP 窗口内容尺寸：长条形——宽度 = 屏幕最大宽度，高度 = 两行文字高度（标题 + 进度）。
    /// 系统会按比例 clamp 悬浮窗实际宽度，高度随比例等比缩放，始终是细长条。
    private static func pipContentSize() -> CGSize {
        // [2026-11-20] 原来是「屏宽 × 60」≈ 6.7:1 的细长条，系统按视频比例显示时会被压扁、
        // 标题被切（真机截图）。改成标准 16:9 横向，PiP 窗口按原比例呈现，不再变形。
        let w = UIScreen.main.bounds.width
        return CGSize(width: w, height: (w * 9.0 / 16.0).rounded())
    }
    /// 启动重试上限(与调研项目同量级)
    private static let maximumStartAttempts = 8

    // MARK: - 运行状态

    /// 当前 PiP 窗口正在展示的任务(sessionID 字符串);nil = 未展示
    private(set) var activeTaskSessionID: String?
    /// 运行中的任务表(sessionID -> 展示信息),由 agentDidStart / Finish / Stop 维护
    private var runningTasks: [String: (title: String, icon: String)] = [:]
    /// 已被关闭(系统回前台自动关 / 用户手动关)的任务:当前任务期间不再自动重启,
    /// 直到新任务(noteTaskStarted)或用户显式开启(force)才重新弹出。
    private var dismissedTaskSessionIDs: Set<String> = []
    /// ensure 节流:onToken 每 token 高频调用下,0.5s 内只处理一次(防重复启动/日志刷屏)
    private var lastEnsureAt: Date = .distantPast
    private static let ensureThrottleInterval: TimeInterval = 0.5
    /// 「已完成待销毁」标记:taskEnded 清空 runningTasks 后,onAppForeground 无法再靠
    /// runningTasks 判断任务已完成——用独立标记记住,回前台时销毁基础设施(系统无法自动复活)。
    private var completedTaskPendingTeardown = false
    /// 延迟释放调度(点 PiP 进入时给系统展开动画时间,避免动画中断黑屏)
    private var pendingTeardownWorkItem: DispatchWorkItem?
    /// 用户是否想显示 PiP(手动关闭后不再自动拉起)
    private var wantsActive = false
    private var startAttempt = 0
    private var pendingStartWorkItem: DispatchWorkItem?
    /// 当前面板图标 SF Symbol 名(进度刷新时复用)
    private var currentIcon = "bubble.left.and.bubble.right.fill"
    /// 进度节流:同一文本不重复刷新;不同文本 0.4s 内最多刷一次(流式 token 高频回调下防抖)
    private var lastProgressText = ""
    private var lastProgressUpdateAt: Date = .distantPast
    private static let progressThrottleInterval: TimeInterval = 0.4

    // MARK: - 基础设施

    private var pipController: AVPictureInPictureController?
    private var pipSourceView: UIView?
    private var contentController: AVPictureInPictureVideoCallViewController?

    // MARK: - 面板控件

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let progressLabel = UILabel()

    private override init() {
        super.init()
    }

    // MARK: - 日志

    private func log(_ message: String) {
        AppLogger.shared.info("[TaskPiP] \(message)", category: "PiP", subsystem: "PiP")
    }

    // MARK: - 任务生命周期(BackgroundTaskController 调用)

    /// agentDidStart:登记运行中的任务。PiP 不在此刻启动(等退出会话页才弹)。
    func noteTaskStarted(sessionID: String?, title: String, icon: String) {
        guard let sid = sessionID else {
            log("noteTaskStarted 跳过:无 sessionID")
            return
        }
        runningTasks[sid] = (title, icon)
        // 新任务(含同一会话新一轮对话):允许重新弹出 PiP——清除上一轮的「已关闭」标记
        dismissedTaskSessionIDs.remove(sid)
        completedTaskPendingTeardown = false
        log("任务登记: sid=\(sid.prefix(8)) title=\(title) running=\(runningTasks.count) active=\(activeTaskSessionID.map { String($0.prefix(8)) } ?? "nil") dismissed=\(dismissedTaskSessionIDs.map { String($0.prefix(8)) })")
        // 若 PiP 恰好在显示该任务(多任务切换场景)→ 立即刷新面板
        if activeTaskSessionID == sid {
            updatePanel(title: title, icon: icon, progress: progressLabel.text ?? String(localized: "thinking"))
        }
    }

    /// 检查开关与活跃任务 → 启动 PiP。
    /// 用户定(2026-08-08 最终语义):
    /// - **App 前台:绝不显示 PiP**(不挡会话页/首页)——只「预热」:创建好基础设施 + 保持面板内容
    ///   最新,退后台瞬间立即弹出,无需等待创建/重试;
    /// - **App 后台:弹出 PiP**;被系统收起过(dismissed)的未完成任务,退后台重新弹起;
    /// - `force`(用户菜单显式开启):仅影响 dismissed 判定,前台同样不显示。
    func ensurePipIfRunning(force: Bool = false) {
        // 节流:非 force 高频触发(onToken 每 token 调)下 0.5s 内只处理一次,防重复启动/日志刷屏
        let now = Date()
        if !force, now.timeIntervalSince(lastEnsureAt) < Self.ensureThrottleInterval {
            return
        }
        lastEnsureAt = now

        // 自清理:登记表中「不在推进且未暂停」的任务(已完成/引擎已销毁,agentDidFinish 可能因
        // App 挂起延迟执行未清表)→ 立即移除,确保「已完成」的任务绝不会再弹 PiP。
        for sid in runningTasks.keys where !isTaskProgressing(sid) && !isTaskPaused(sid) {
            runningTasks.removeValue(forKey: sid)
            dismissedTaskSessionIDs.remove(sid)
            log("自清理已完成任务: sid=\(sid.prefix(8)) 剩余=\(runningTasks.count)")
        }
        // 治本(2026-08-13 崩溃 0x8BADF00D 根因):自清理后登记表为空 = 无任何推进中/暂停任务,
        // PiP 已无用 → 补设「已完成待销毁」标记,让 onAppForeground 的既有分支(:184,自带
        // pipShowing 黑屏保护)正确销毁基础设施,退后台不再被系统自动复活。
        // 此前只清表不补标记,造成 runningTasks 空 + completedTaskPendingTeardown=false 死角:
        // onAppForeground 走 else「保持 PiP」→ 基础设施残留 → 退后台系统自动复活 PiP →
        // 后台烧 CPU + 过热 → watchdog 5s 挂起超时强杀(signal 9)。
        if runningTasks.isEmpty {
            completedTaskPendingTeardown = true
        }

        let bg = SettingsStore.shared.settings.background
        let appState = UIApplication.shared.applicationState
        guard bg.backgroundRun, bg.pictureInPicture else { return }
        if pipController?.isPictureInPictureActive == true { return }
        guard let (sid, info) = runningTasks.first(where: { isTaskProgressing($0.key) }) else {
            log("ensure 跳过: 无推进中的任务 running=\(runningTasks.keys.map { String($0.prefix(8)) })")
            return
        }

        // ★ 前台:不显示 PiP,但立即【预热】创建基础设施(用户定 2026-08-08:发送消息后预热,
        //   用户可能立马切 App)。实证:前台创建后系统只在 App 退后台时自动启动(15:47:47 日志),
        //   前台不会显示;若系统异常前台启动,onAppForeground 已主动收起兜底。
        //   退后台瞬间基础设施已就绪 → 系统自动启动 + startPictureInPicture 兜底 = 零延迟弹出。
        if appState != .background {
            if pipController == nil {
                if prepareInfrastructure() {
                    updatePanel(title: info.title, icon: info.icon, progress: String(localized: "thinking"))
                    log("前台预热: PiP 基础设施就绪,不显示(退后台系统立即自动启动) sid=\(sid.prefix(8))")
                }
            }
            return
        }

        // 后台:创建(若未建)+ 弹出
        if pipController == nil {
            guard prepareInfrastructure() else {
                log("ensure 失败: 后台创建基础设施失败 sid=\(sid.prefix(8))")
                return
            }
            updatePanel(title: info.title, icon: info.icon, progress: String(localized: "thinking"))
            log("ensure: 后台创建基础设施就绪(系统将自动启动) sid=\(sid.prefix(8))")
        }
        if !force, dismissedTaskSessionIDs.contains(sid) {
            // 回前台被系统收起后,任务未结束 → 退后台重新弹起
            dismissedTaskSessionIDs.remove(sid)
            log("ensure: 退后台清除「已关闭」标记,重新弹出 sid=\(sid.prefix(8))")
        }
        log("ensure 触发: 显示 sid=\(sid.prefix(8)) title=\(info.title)")
        start(sessionID: sid, title: info.title, icon: info.icon)
    }

    /// 回前台（用户点击 PiP 进入 App / 点击图标进入）：判断任务完成状态（用户定 2026-08-08）。
    /// - **前台绝不显示 PiP**:若系统未自动收起(点图标进入等场景系统不收)——主动收起兜底;
    /// - 任务已完成 → **彻底关闭**:清登记表 + 销毁基础设施——退后台不再弹;
    /// - 任务未完成 → 保持(退后台 ensure 再弹,即「未完成不关闭」)。
    func onAppForeground() {
        // ★ 前台绝不显示 PiP。关键时序:点 PiP 进入时系统正在播放「PiP 展开回源 View」动画,
        // 此刻直接释放(移除源 View)会中断动画 → 黑屏 1 秒(用户实测)。
        // 方案:PiP 显示中 → 延迟释放(0.6s);若期间系统 DidStop(展开动画完成)→ 立即释放(无黑屏);
        // 点图标进入等系统不播动画场景 → 延迟到期直接释放(原地消失,已验证有效)。
        let pipShowing = pipController?.isPictureInPictureActive == true
        if pipShowing {
            log("回前台: PiP 显示中 → 延迟释放(0.6s 观察系统展开动画,避免黑屏)")
            scheduleTeardown(delay: 0.6)
        }
        // ★ 优先处理「已完成待销毁」:taskEnded 已清空 runningTasks(完成信息不在登记表里),
        // 必须靠独立标记识别——否则回前台误判「未完成」不销毁,退后台被系统自动复活。
        if completedTaskPendingTeardown {
            completedTaskPendingTeardown = false
            log("回前台: 检测到已完成待销毁的 PiP → 关闭")
            if !pipShowing {
                teardownInfrastructure()
            }
            return
        }
        var completed: [String] = []
        for sid in runningTasks.keys where !isTaskProgressing(sid) && !isTaskPaused(sid) {
            completed.append(sid)
            runningTasks.removeValue(forKey: sid)
            dismissedTaskSessionIDs.remove(sid)
        }
        if !completed.isEmpty {
            log("回前台: 任务已完成,彻底关闭 \(completed.map { String($0.prefix(8)) })")
            if !pipShowing {
                if let sid = activeTaskSessionID, completed.contains(sid) {
                    dismissIfShowing()
                }
                // ★ 销毁基础设施:VideoCall 型 PiP 的「通话」语义——只要 pipController 存在,
                // App 退后台时系统会自动启动 PiP(无需我们调用 start)。不销毁则「已完成」的
                // PiP 会在退后台时被系统复活(用户实测:自清理清了登记表仍弹)。
                teardownInfrastructure()
            }
        } else {
            log("回前台: 任务未完成,保持 PiP(退后台再弹) running=\(runningTasks.keys.map { String($0.prefix(8)) })")
        }
    }

    /// 延迟释放:给系统「PiP 展开回源 View」动画时间(点 PiP 进入场景),避免动画中断黑屏。
    /// 若期间系统 DidStop(动画完成)→ onDidStop 取消此调度并立即释放;否则到期释放。
    private func scheduleTeardown(delay: TimeInterval) {
        pendingTeardownWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingTeardownWorkItem = nil
                self.log("延迟释放到期: 释放基础设施(系统未在时限内 DidStop)")
                self.teardownInfrastructure()
            }
        }
        pendingTeardownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 销毁 PiP 基础设施:移除源 View、释放 pipController/contentController。
    /// 任务已完成且不再需要 PiP 时调用——系统无法再自动启动,新任务由 ensure 重建。
    private func teardownInfrastructure() {
        pendingStartWorkItem?.cancel()
        pendingTeardownWorkItem?.cancel()
        pendingTeardownWorkItem = nil
        completedTaskPendingTeardown = false
        // 方案 A(用户拍板 2026-08-08):不调 stopPictureInPicture,直接释放——
        // 官方 Important 认可「释放 controller 结束 PiP」;验证是否无关闭动画(原地消失)。
        pipSourceView?.removeFromSuperview()
        pipSourceView = nil
        contentController = nil
        pipController = nil
        activeTaskSessionID = nil
        wantsActive = false
        log("基础设施已销毁(直接释放,未调 stopPictureInPicture)")
    }

    /// 任务是否在推进(引擎活跃响应且未暂停)。
    /// 判定依据(用户定 2026-08-08):暂停/完成的任务是「无法推进」状态,不弹 PiP;
    /// 只有正在推进的任务才继续显示悬浮窗。
    private func isTaskProgressing(_ sid: String) -> Bool {
        guard let uuid = UUID(uuidString: sid), let runtime = AppState.shared?.chatRuntimes[uuid] else {
            return false
        }
        return !runtime.isPaused && runtime.isResponding
    }

    /// 任务是否暂停(暂停保留登记,恢复后可重新弹出)。
    private func isTaskPaused(_ sid: String) -> Bool {
        guard let uuid = UUID(uuidString: sid), let runtime = AppState.shared?.chatRuntimes[uuid] else {
            return false
        }
        return runtime.isPaused
    }

    /// agentDidProgress / 流式回调:刷新进度文本(仅当 PiP 正显示该任务)。
    /// 节流:内容未变直接跳过;内容变化但距上次刷新 < 0.4s 也跳过(流式 token 高频回调防抖),
    /// 状态跳变(如 工具→生成)因文本不同仍会尽快上屏。
    /// 日志:未命中(状态脱节)才打,命中后由节流后的「进度刷新」日志记录,避免每 token 刷屏。
    func updateProgress(sessionID: String?, text: String) {
        guard let sid = sessionID else { return }
        guard activeTaskSessionID == sid else { return }
        guard text != lastProgressText else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdateAt) >= Self.progressThrottleInterval else { return }
        lastProgressUpdateAt = now
        lastProgressText = text
        updatePanel(title: titleLabel.text ?? "", icon: currentIcon, progress: text)
        log("进度刷新: sid=\(sid.prefix(8)) text=\(text.prefix(20))")
    }

    /// agentDidFinish / agentDidStop:移除任务;若正显示该任务 → 切换下一个或关闭。
    func taskEnded(sessionID: String?) {
        guard let sid = sessionID else { return }
        runningTasks.removeValue(forKey: sid)
        dismissedTaskSessionIDs.remove(sid)
        log("任务结束: sid=\(sid.prefix(8)) 剩余=\(runningTasks.count) active=\(activeTaskSessionID.map { String($0.prefix(8)) } ?? "-")")
        guard activeTaskSessionID == sid else {
            log("taskEnded 跳过停止: active(=\(activeTaskSessionID.map { String($0.prefix(8)) } ?? "nil")) != sid(\(sid.prefix(8)))")
            return
        }
        if let (nextSid, next) = runningTasks.first {
            log("切换展示: sid=\(nextSid.prefix(8))")
            start(sessionID: nextSid, title: next.title, icon: next.icon)
        } else {
            // 任务完成【不关闭】:PiP 常驻显示「已完成」,等用户回到会话查看结果才关闭。
            updatePanel(title: titleLabel.text ?? "", icon: currentIcon, progress: String(localized: "completed"))
            log("任务完成: PiP 保持显示「已完成」(active=\(sid.prefix(8)))")
            // 记住「已完成待销毁」:runningTasks 已被清空,onAppForeground 靠此标记销毁基础设施
            completedTaskPendingTeardown = true
            // 若用户【当前正在前台查看】该会话 → 悬浮窗多余,立即关闭 + 销毁基础设施。
            // 注意:selectedSession 在 App 退后台后仍保留旧值,必须叠加「前台」判断——
            // 否则后台任务完成时(用户根本没进 App)会被误判为"正在查看"而杀掉 PiP。
            if let uuid = UUID(uuidString: sid),
               AppState.shared?.selectedSession?.id == uuid,
               UIApplication.shared.applicationState != .background {
                log("用户正在查看该会话 → 直接关闭")
                dismissIfShowing()
                teardownInfrastructure()
            }
        }
    }

    /// 手动关闭(设置/菜单开关关闭时调用):记录「已关闭」,当前任务不再自动重启。
    func dismissIfShowing() {
        if let sid = activeTaskSessionID {
            dismissedTaskSessionIDs.insert(sid)
            log("手动关闭: 记录已关闭 sid=\(sid.prefix(8))")
        }
        wantsActive = false
        pendingStartWorkItem?.cancel()
        // 方案 A(用户拍板 2026-08-08):直接释放代替 stopPictureInPicture(原地消失,已验证)。
        // PiP 激活中 → 延迟释放(系统停止流程中释放会崩,16:35 实证);未激活 → 立即释放。
        if pipController?.isPictureInPictureActive == true {
            scheduleTeardown(delay: 0.3)
        } else {
            teardownInfrastructure()
        }
    }

    // MARK: - 启动 / 停止

    private func start(sessionID: String, title: String, icon: String) {
        // 幂等:同一任务已显示/正在启动(含系统延迟启动中)→ 只刷新面板,不重置重试链
        // (此前每 token 的 ensure 都重新 start,日志刷屏 + 多次 startPictureInPicture 竞争)
        if activeTaskSessionID == sessionID, wantsActive {
            updatePanel(title: title, icon: icon, progress: progressLabel.text ?? String(localized: "thinking"))
            return
        }
        wantsActive = true
        activeTaskSessionID = sessionID
        startAttempt = 0
        guard prepareInfrastructure() else {
            log("启动失败: 基础设施创建失败")
            activeTaskSessionID = nil
            return
        }
        updatePanel(title: title, icon: icon, progress: String(localized: "thinking"))
        requestStart(attempt: 0)
    }

    // MARK: - 基础设施

    /// 一次性创建:源 View(挂窗口) + contentSource + pipController。
    /// 复用已创建的实例(第二次启动不需要重建)。
    private func prepareInfrastructure() -> Bool {
        if pipController != nil { return true }

        // 1. 源 View:透明圆角小窗,挂 keyWindow(启动前置条件: window != nil)
        let source = UIView()
        source.backgroundColor = .clear
        source.isOpaque = false
        source.isUserInteractionEnabled = false
        source.layer.cornerRadius = 18
        source.layer.cornerCurve = .continuous
        source.clipsToBounds = true
        let contentSize = Self.pipContentSize()
        source.frame = CGRect(origin: .zero, size: contentSize)
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else {
            log("基础设施失败: 无 keyWindow")
            return false
        }
        window.addSubview(source)
        source.center = window.center
        pipSourceView = source
        log("源 View 挂载: window=\(window.bounds.size) source=\(source.frame.size)")

        // 2. 内容控制器:PiP 窗口内承载进度面板
        let content = AVPictureInPictureVideoCallViewController()
        content.preferredContentSize = contentSize
        content.view.backgroundColor = .clear
        content.view.isOpaque = false
        content.view.clipsToBounds = true
        let panel = makePanel()
        panel.frame = content.view.bounds
        panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.view.addSubview(panel)
        contentController = content
        log("内容控制器就绪: preferredContentSize=\(contentSize)")

        // 3. contentSource + pipController(官方 VideoCall 路线)
        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: source,
            contentViewController: content
        )
        let pip = AVPictureInPictureController(contentSource: contentSource)
        pip.delegate = self
        pipController = pip
        log("pipController 就绪: possible=\(pip.isPictureInPicturePossible)")
        return true
    }

    /// 进度面板：长条形——圆角深色容器 + 左侧图标(32pt) + 右侧两行文字(标题 / 进度)。
    /// 纯 UIKit，避免 SwiftUI 在 PiP 容器内的布局问题。
    private func makePanel() -> UIView {
        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0.08, alpha: 0.94)
        panel.layer.cornerRadius = 18
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .white
        iconView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.35)
        iconView.layer.cornerRadius = 12
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = .systemFont(ofSize: 14)
        progressLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        progressLabel.numberOfLines = 1
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(iconView)
        panel.addSubview(titleLabel)
        panel.addSubview(progressLabel)

        NSLayoutConstraint.activate([
        iconView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -20),
            titleLabel.centerYAnchor.constraint(equalTo: panel.centerYAnchor, constant: -10),

            progressLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -20),
            progressLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
        ])
        return panel
    }

    private func updatePanel(title: String, icon: String, progress: String) {
        titleLabel.text = title
        progressLabel.text = progress
        currentIcon = icon
        // [2026-11-20] 优先用 App 图标（与系统 PiP 的观感一致），拿不到再退回工具符号。
        iconView.image = Self.appIconImage() ?? UIImage(systemName: icon)
        iconView.contentMode = .scaleAspectFit
        // App 图标自带底色，不再叠蓝色背景；符号才需要底色。
        iconView.backgroundColor = Self.appIconImage() == nil
            ? UIColor.systemBlue.withAlphaComponent(0.35) : .clear
    }

    /// 从 Info.plist 的 CFBundleIcons 里取应用图标（PiP 面板左侧展示品牌标识）。
    private static func appIconImage() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }

    // MARK: - 启动重试链(照搬调研结论)

    /// 前置条件满足才调 startPictureInPicture;否则延迟递增重试,耗尽报失败。
    private func requestStart(attempt: Int) {
        pendingStartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.wantsActive else { return }
            guard let pip = self.pipController, let source = self.pipSourceView else { return }
            if pip.isPictureInPictureActive { return }
            let sourceReady = !source.bounds.isEmpty && source.window != nil
            if sourceReady && pip.isPictureInPicturePossible {
                self.startAttempt = attempt
                self.log("启动调用: attempt=\(attempt) possible=true sourceReady=true")
                pip.startPictureInPicture()
                return
            }
            if attempt < Self.maximumStartAttempts {
                let delay = 0.3 * Double(attempt + 1)
                self.log("重试: attempt=\(attempt) possible=\(pip.isPictureInPicturePossible) sourceReady=\(sourceReady) delay=\(delay)")
                self.requestStart(attempt: attempt + 1)
            } else {
                self.log("启动失败: 重试耗尽 possible=\(pip.isPictureInPicturePossible) sourceReady=\(sourceReady)")
                self.activeTaskSessionID = nil
                self.wantsActive = false
            }
        }
        pendingStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.3 * Double(attempt)), execute: workItem)
    }
    /// DidStop 回调:PiP 窗口已关闭(系统回前台自动关 / stopPictureInPicture / 用户手动)。
    /// 记录「已关闭」标记:当前任务期间 ensure 不再自动重启(用户回 App 后 PiP 被系统收起,
    /// 退后台不应再弹;新任务或用户显式开启才重新弹出)。
    private func onDidStop() {
        pendingStartWorkItem?.cancel()
        pendingTeardownWorkItem?.cancel()
        pendingTeardownWorkItem = nil
        if let sid = activeTaskSessionID {
            dismissedTaskSessionIDs.insert(sid)
            log("DidStop: 记录已关闭 sid=\(sid.prefix(8)) dismissed=\(dismissedTaskSessionIDs.map { String($0.prefix(8)) })")
        }
        wantsActive = false
        activeTaskSessionID = nil
        // ★ 不在 delegate 回调内直接释放 pipController:系统停止流程仍在执行、内部持有
        //   controller,回调内释放 → 崩溃(16:35 闪退实证)。延迟 0.3s 等系统回调完全结束再释放,
        //   同时防止退后台被系统自动复活。
        scheduleTeardown(delay: 0.3)
        log("DidStop: 清理完成(延迟 0.3s 释放基础设施)")
    }

    /// DidStart 回调:PiP 窗口真实启动。**自愈**:若内部状态丢失(历史 failedToStart 清空、
    /// 系统延迟启动等竞态导致 activeTaskSessionID == nil 但窗口已显示),
    /// 从 runningTasks 恢复任务绑定,否则进度更新/完成关闭全部失效。
    private func onDidStart() {
        log("DidStart: active=\(activeTaskSessionID.map { String($0.prefix(8)) } ?? "nil") running=\(runningTasks.keys.map { String($0.prefix(8)) })")
        if activeTaskSessionID == nil, let (sid, info) = runningTasks.first {
            log("DidStart 自愈: 恢复 active=\(sid.prefix(8)) title=\(info.title)")
            activeTaskSessionID = sid
            wantsActive = true
            updatePanel(title: info.title, icon: info.icon, progress: progressLabel.text ?? String(localized: "thinking"))
        }
    }

    /// 启动失败(系统瞬时拒绝,常见于退后台过渡期):**保留状态 + 有限重试**,
    /// 不放弃——否则系统稍后真正启动 PiP(DidStart)时状态已清空,
    /// 导致「窗口显示着但 activeTaskSessionID=nil」:进度更新全被拦截、任务完成不关闭。
    /// 重试耗尽才清状态放弃。
    private func handleStartFailure(_ error: Error) {
        log("failedToStart: \(error.localizedDescription) attempt=\(startAttempt)")
        guard wantsActive, activeTaskSessionID != nil else {
            log("failedToStart 放弃: wantsActive=\(wantsActive) active=\(activeTaskSessionID.map { String($0.prefix(8)) } ?? "nil")")
            return
        }
        if startAttempt < Self.maximumStartAttempts {
            log("failedToStart 后重试: attempt=\(startAttempt + 1)")
            requestStart(attempt: startAttempt + 1)
        } else {
            log("failedToStart 重试耗尽,放弃")
            activeTaskSessionID = nil
            wantsActive = false
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
// 协议方法系统在任意线程回调:nonisolated + Task { @MainActor } 跳回主线程,
// 避免跨入 main-actor 隔离的类( Swift 6 并发检查 )。

extension TaskPipController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            TaskPipController.shared.onDidStart()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            TaskPipController.shared.onDidStop()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            TaskPipController.shared.handleStartFailure(error)
        }
    }
}
