import AppIntents
import UserNotifications

/// 快捷指令派发任务后的「任务已开始」本地通知（对齐参考实现的 Task Started 通知）。
/// 受设置 → 后台 → 通知 开关控制；完成通知由引擎管线（agentDidFinish）统一发送。
enum IntentNotification {
    static func postStarted(title: String, promptPreview: String, sessionID: UUID) {
        let bg = SettingsStore.shared.settings.background
        guard bg.notifications else { return }
        Task {
            guard await NotificationManager.shared.authorized() else { return }
            await NotificationManager.shared.notifyTaskStarted(title: title, promptPreview: promptPreview, sessionID: sessionID)
        }
    }
}

/// P1-1 阶段1：Siri / 快捷指令入口。
/// 让用户在快捷指令里直接派发一条任务给 MiniClaw，复用 P1-4 的深链派发逻辑。
/// 该意图在 App 进程内执行，通过 AppState.shared 直接登记深链任务（App 启动即置位 shared）。
///
/// 注意：本文件在 project.yml 中被单独设为 Swift 5 语言模式编译。原因：iOS 26 SDK 把
/// LocalizedStringResource / Summary / AppShortcut 的构造标为 @MainActor 且未声明 Sendable，
/// 而 AppIntent / AppShortcutsProvider 要求 Sendable、协议本身非隔离，Swift 6 严格并发下
/// 无论 @MainActor 还是 nonisolated+assumeIsolated 都过不了。该冲突是 SDK 侧的已知问题，
/// 仅对本文件降级到 Swift 5 模式即可干净编译，且不影响 App 其余 Swift 6 严格性。
///
/// 本地化边界：`IntentDescription` / `LocalizedStringResource` 必须为编译期字面量——
/// appintentsmetadataprocessor 禁止运行时动态值（实测验证），故快捷指令的标题与描述
/// 无法运行时查表（Localizable.xcstrings）；多语言由 String Catalog 各语言条目覆盖。
///
/// 派发链路目前在 UI 层（ChatView 消费 pendingDeepLinkTask 后启动引擎），
/// 因此两个意图都置 openAppWhenRun = true 保证界面出现、任务必达；
/// 服务层派发器落地（无 UI 也能消费）后改回 false 实现真后台执行。
@available(iOS 17.0, *)
struct RunAgentTaskIntent: LiveActivityIntent, ProgressReportingIntent {

    static let title: LocalizedStringResource = "new_task"
    static let description = IntentDescription("new_task_desc")
    // headless：不打开 App 界面，任务由服务层消费者后台执行（用户已验证此模式可用）。
    static let openAppWhenRun = false

    @Parameter(title: "task_prompt_title", description: "task_prompt_desc", requestValueDialog: "task_prompt_dialog")
    var prompt: String

    @Parameter(title: "attachment_title", description: "attachment_desc",
               supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var attachments: [IntentFile]?

    static var parameterSummary: some ParameterSummary {
        // 摘要必须用**源码插值**写法：占位符与参数的绑定关系由源码提取（元数据处理器
        // 无法从裸 key 得知参数个数，运行时不会替换、直接显示裸 %@——2026-09-05 实测）。
        // 摘要里内插的参数不必重复进构建器；构建器只列其余参数（不在摘要里的参数
        // 编辑器不渲染输入行）。
        Summary("新建任务：\(\.$prompt)") {
            \.$attachments
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        AppLogger.shared.info("[Intent] 新建任务 开始执行", category: "Intent")
        // eager 保活：不等引擎启动，立即进入保活（受「后台运行」开关控制）。
        BackgroundTaskController.shared.armForIntent(sessionID: nil)
        // LiveActivityIntent 授权窗口内启动实时活动（官方唯一后台启动路径）；
        // 引擎 agentDidStart 会再次调用（幂等复用），双路径安全。
        BackgroundTaskController.shared.startLiveActivity(sessionID: nil, title: String(localized: "new_task"), icon: ChatSession.defaultIcon)

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentError.emptyPrompt }

        // 附件转为内存数据（由服务层消费者落盘到会话目录）；未配置附件时为 nil/空。
        var deepLinkAttachments: [AppState.DeepLinkAttachment] = []
        for file in attachments ?? [] {
            let data = file.data
            deepLinkAttachments.append(AppState.DeepLinkAttachment(fileName: resolvedIntentFileName(for: file), data: data))
        }

        // 新建会话（与深链语义一致：source=deeplink），标题占位「新会话」由 智能体标题生成接管。
        guard let session = SessionManager.shared.createSession(title: String(localized: "new_chat_title"), source: "deeplink") else {
            throw IntentError.createSessionFailed
        }
        let task = AppState.PendingDeepLinkTask(
            prompt: trimmed,
            targetSessionID: session.id,
            xSuccess: nil,
            xError: nil,
            attachments: deepLinkAttachments
        )
        AppState.shared?.pendingDeepLinkTask = task
        AppState.shared?.consumeIntentTaskIfNeeded()

        // 开始通知标题固定「新建任务」（仅本意图；「继续会话」的开始通知仍用会话名，完成通知不变）。
        IntentNotification.postStarted(title: String(localized: "new_task"), promptPreview: String(trimmed.prefix(50)), sessionID: session.id)

#if compiler(>=6.4)
        // ===== iOS 27+ 官方长任务路径（LongRunningIntent）=====
        // 编译器 ≥6.4（iOS 27 SDK）才有 onCancel 重载与 CancellableIntent；
        // API 运行时要求 iOS 27.0+，26.x 及以下设备走下方 headless 兜底。
        // 任务放进 performBackgroundTask：系统扩展后台执行时间（突破 30s 限制）；
        // 期间必须定期更新 progress（官方硬性要求，否则系统取消扩展提前终止）；
        // 整轮完成才返回——perform 未返回期间快捷指令持续显示执行中，
        // 完成时经返回值（回复全文）+ 完成通知双路上报。
        // onCancel 是 @Sendable 闭包：只捕获 Sendable 的 sid（ChatSession 非 Sendable）。
        let sid = session.id
        if #available(iOS 27.0, *) {
            let reply = try await performLongTask(sessionID: sid)
            return .result(value: reply, dialog: IntentDialog("task_complete"))
        }
#endif
        // ===== headless 路径（运行时 iOS 27 以下，或旧编译器）=====
        // 系统无官方后台延长 API，保持「等引擎启动即返回 + eager 保活 + LiveActivity + 完成通知」；
        // progress 定期更新仅作 Siri 进度显示（无延长能力）。
        // 等引擎真正开始 run 后再返回（消除「返回了但引擎没启动」窗口）。
        await waitForEngineStart(sessionID: session.id, progress: progress)
        return .result(value: String(localized: "started"), dialog: IntentDialog("task_started_notice"))
    }

    /// 官方长任务路径的完成兜底超时（秒）：任何链路故障都不会让快捷指令无限转圈。
    static let finishTimeoutSeconds: TimeInterval = 1800

    enum IntentError: LocalizedError {
        case emptyPrompt
        case attachmentReadFailed(String)
        case createSessionFailed
        case timeout
        var errorDescription: String? {
            switch self {
            case .emptyPrompt: return String(localized: "intent_empty_prompt")
            case .attachmentReadFailed(let name): return String(format: String(localized: "intent_attachment_read_failed"), name)
            case .createSessionFailed: return String(localized: "intent_create_session_failed")
            case .timeout: return String(localized: "intent_wait_timeout")
            }
        }
    }
}

/// 确保 IntentFile 有可用文件名与正确扩展名。
/// 快捷指令常传无扩展名文件（如 "IMG_1234"、"Photo"）或空名；
/// 用文件自身的 UTType 补扩展名，保证 AttachmentKind 判定与工具读取正常。
/// 对齐参考实现（SendPromptIntent.resolvedFileName）。
func resolvedIntentFileName(for file: IntentFile) -> String {
    let name = file.filename
    let ext = (name as NSString).pathExtension.lowercased()
    if !ext.isEmpty { return name }
    if let type = file.type, let preferred = type.preferredFilenameExtension {
        return "\(name).\(preferred)"
    }
    return name.isEmpty ? "attachment" : name
}

/// 等待 headless 派发的引擎开始 run（AppState.intentEngineStartedSessions 信号）。
/// 注意：pendingDeepLinkTask 在 startRun 成功后即被消费清空，不能作为等待依据；
/// 只检查目标会话的引擎启动信号。文件级私有：两个 intent 共用。
/// 等待期间定期更新 progress（ProgressReportingIntent，iOS 17+）：Siri/快捷指令显示执行中。
@available(iOS 17.0, *)
@MainActor
private func waitForEngineStart(sessionID: UUID, progress: Progress? = nil) async {
    for _ in 0..<50 {
        if AppState.shared?.intentEngineStartedSessions.contains(sessionID) == true {
            AppLogger.shared.info("[Intent] 引擎已启动，perform 返回", category: "Intent")
            return
        }
        if let progress {
            progress.totalUnitCount = 100
            progress.localizedDescription = String(localized: "intent_processing")
            progress.completedUnitCount += 1
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    AppLogger.shared.info("[Intent] 等待引擎启动超时（5s）——任务可能未启动，请检查日志", category: "Intent")
}

/// 在「快捷指令」App 中暴露 MiniClaw 的短语入口，支持 Siri 语音触发。
/// 每个意图都注册 AppShortcut（对齐参考实现）——只有短语注册的意图，
/// 用户才能从「App 快捷指令」列表可靠添加并运行；未注册短语的意图
/// 即使从「App 动作」手动添加，运行时路由也不可靠（日志零 intent 执行）。
/// iOS16 兼容(2026-08-12):两个意图依赖 LiveActivityIntent(iOS17),
/// 快捷指令整体仅 iOS17+ 注册;16 下无 Siri 快捷指令(记录于改造报告)。
@available(iOS 17.0, *)
struct MiniClawShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAgentTaskIntent(),
            phrases: [
                "用 ${applicationName} 执行任务",
                "让 ${applicationName} 运行任务",
                "新建 ${applicationName} 任务",
                "Run a task with ${applicationName}",
                "Ask ${applicationName} to run a task"
            ],
            shortTitle: "new_task",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: ContinueSessionIntent(),
            phrases: [
                "继续 ${applicationName} 会话",
                "向 ${applicationName} 会话发送消息",
                "Continue ${applicationName} conversation",
                "Send a message to ${applicationName} conversation"
            ],
            shortTitle: "continue_session",
            systemImageName: "arrowshape.turn.up.left.fill"
        )
    }
}

// MARK: - 继续会话（快捷指令：选择已有会话 + 消息 + 多附件）

/// 快捷指令里的会话实体（实体选择器列出最近会话，按更新时间倒序）。
struct ChatSessionEntity: AppEntity {
    let id: UUID
    let title: String
    let iconName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "session_entity" }
    static var defaultQuery: ChatSessionEntityQuery { ChatSessionEntityQuery() }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            image: DisplayRepresentation.Image(systemName: iconName)
        )
    }
}

/// 会话实体查询：按标识符取指定会话、给出建议列表（最近 50 个会话）。
struct ChatSessionEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ChatSessionEntity] {
        await SessionManager.shared.waitForLoaded()
        return identifiers.compactMap { id in
            SessionManager.shared.session(id: id).map {
                ChatSessionEntity(id: $0.id, title: $0.title, iconName: $0.iconName)
            }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [ChatSessionEntity] {
        await SessionManager.shared.waitForLoaded()
        return SessionManager.shared.allSessions().prefix(50).map {
            ChatSessionEntity(id: $0.id, title: $0.title, iconName: $0.iconName)
        }
    }
}

/// 继续会话：向选中的已有会话发送消息（可携带多个附件）。
/// - waitForResult = false（默认）：立即返回「已开始」，智能体完成后由引擎管线发本地通知；
/// - waitForResult = true：等待整轮完成，返回 智能体回复全文（可链式传给后续快捷指令动作）。
@available(iOS 17.0, *)
struct ContinueSessionIntent: LiveActivityIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "continue_session"
    static let description = IntentDescription("continue_session_desc")
    // headless：与「运行任务」完全同机制（openAppWhenRun=false + 短语注册）。
    // 此前失败根因 = 未注册 AppShortcut 短语，用户从「App 动作」手动添加的意图
    // 路由不可靠（perform 不执行、App 不拉起）；短语注册后路由与运行任务一致。
    static let openAppWhenRun = false

    @Parameter(title: "session_title", description: "task_prompt_desc")
    var session: ChatSessionEntity

    @Parameter(title: "message_title", description: "message_desc", requestValueDialog: "message_dialog")
    var message: String

    @Parameter(title: "attachment_title", description: "attachment_desc",
               supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var attachments: [IntentFile]?

    @Parameter(title: "wait_for_result_title", description: "attachment_desc", default: false)
    var waitForResult: Bool

    /// 等待模式下防永久挂起的超时（秒）：任何链路故障（派发失败/引擎未启动）都不会让快捷指令无限转圈。
    static let waitTimeoutSeconds: UInt64 = 120
    /// 官方长任务路径（iOS 27+ LongRunningIntent）的完成兜底超时（秒）。
    static let finishTimeoutSeconds: TimeInterval = 1800

    static var parameterSummary: some ParameterSummary {
        // 源码插值写法（同上）：session/message 内插进摘要句，attachments/waitForResult
        // 进构建器（各自渲染为输入行）。全部参数均可达。
        Summary("向 \(\.$session) 会话发送 \(\.$message)") {
            \.$attachments
            \.$waitForResult
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // 冷启动经快捷指令拉起时 load 已异步化：读会话前等加载完成（超时兜底）。
        await SessionManager.shared.waitForLoaded()
        guard let target = SessionManager.shared.session(id: session.id) else {
            throw IntentError.sessionNotFound
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw IntentError.emptyMessage
        }
        // 附件转为内存数据（由服务层消费者落盘到会话目录）；未配置附件时为 nil/空。
        var deepLinkAttachments: [AppState.DeepLinkAttachment] = []
        for file in attachments ?? [] {
            let data = file.data
            deepLinkAttachments.append(AppState.DeepLinkAttachment(fileName: resolvedIntentFileName(for: file), data: data))
        }
        let task = AppState.PendingDeepLinkTask(
            prompt: message,
            targetSessionID: session.id,
            xSuccess: nil,
            xError: nil,
            attachments: deepLinkAttachments
        )
        AppLogger.shared.info("[Intent] ContinueSession 开始执行，会话 \(target.title)", category: "Intent")
        // eager 保活：不等引擎启动，立即进入保活（受「后台运行」开关控制）。
        BackgroundTaskController.shared.armForIntent(sessionID: session.id.uuidString)
        // LiveActivityIntent 授权窗口内启动实时活动（官方唯一后台启动路径）。
        BackgroundTaskController.shared.startLiveActivity(sessionID: session.id.uuidString, title: target.title, icon: target.iconName)
        AppState.shared?.pendingDeepLinkTask = task
        // headless：登记后立即由服务层消费者启动引擎（无 UI 依赖）。
        AppState.shared?.consumeIntentTaskIfNeeded()

        let promptPreview = String(message.prefix(50))
        IntentNotification.postStarted(title: target.title, promptPreview: promptPreview, sessionID: session.id)

#if compiler(>=6.4)
        // ===== iOS 27+ 官方长任务路径（LongRunningIntent）=====
        // 编译器 ≥6.4（iOS 27 SDK）才有 onCancel 重载与 CancellableIntent；
        // API 运行时要求 iOS 27.0+，26.x 及以下设备走下方 headless 兜底。
        // 官方路径必须等到整轮完成才返回（保持 performBackgroundTask 扩展窗口，突破 30s 限制）；
        // waitForResult 仅影响 dialog 措辞，返回值恒为整轮回复文本（快捷指令总能拿到结果）。
        // onCancel 是 @Sendable 闭包：只捕获 Sendable 的 sid（ChatSession 非 Sendable）。
        // onCancel 是 @Sendable 闭包：只捕获 Sendable 的 sid（ChatSessionEntity 引用非 Sendable）。
        let sid = session.id
        if #available(iOS 27.0, *) {
            let reply = try await performLongTask(sessionID: sid)
            return .result(value: reply, dialog: IntentDialog(waitForResult ? "task_complete" : "task_started_processing"))
        }
#endif
        // ===== headless 路径（运行时 iOS 27 以下，或旧编译器）=====
        // 等引擎真正开始 run 后再返回（headless 无 UI，用户感知 = 通知；保证引擎已启动）。
        await waitForEngineStart(sessionID: session.id, progress: progress)

        guard waitForResult else {
            return .result(value: String(localized: "started"), dialog: IntentDialog("task_started_processing"))
        }

        // 等待模式：整轮 Agent 跑完由 ChatView.onComplete 经 fireDeepLinkSuccess 回传回复文本；
        // 失败/中断由 fireDeepLinkError 抛出；超时兜底防永久挂起。
        let reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
            AppState.shared?.deepLinkResultContinuation = cont
            // 代际校验：只允许当前代际的续体被超时触发，陈旧超时（上一意图已完成/已超时后遗留）不得误杀新意图。
            let generation = AppState.shared?.deepLinkGeneration ?? 0
            Task {
                try? await Task.sleep(for: .seconds(Self.waitTimeoutSeconds))
                guard AppState.shared?.deepLinkGeneration == generation,
                      AppState.shared?.deepLinkResultContinuation != nil else { return }
                AppState.shared?.deepLinkResultContinuation?.resume(throwing: IntentError.timeout)
                AppState.shared?.deepLinkResultContinuation = nil
            }
        }
        return .result(value: reply, dialog: IntentDialog("task_complete"))
    }

    enum IntentError: LocalizedError {
        case sessionNotFound
        case emptyMessage
        case attachmentReadFailed(String)
        case timeout
        var errorDescription: String? {
            switch self {
            case .sessionNotFound: return String(localized: "intent_session_not_found")
            case .emptyMessage: return String(localized: "intent_empty_message")
            case .attachmentReadFailed(let name): return String(format: String(localized: "intent_attachment_read_failed"), name)
            case .timeout: return String(localized: "intent_reply_timeout")
            }
        }
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
extension RunAgentTaskIntent {
    /// 长任务轮询体。**必须非隔离**：performBackgroundTask 的 operation 按 sending
    /// 语义检查，@MainActor 闭包传不进去（Xcode 26.6 / iOS 27 SDK 实测报
    /// SendingRisksDataRace）。self 满足 AppIntent: Sendable 可跨隔离；AppState 消费
    /// 显式跳回主 actor。取消经 onCancel → engine.cancel()（与 App 内停止同口径）。
    fileprivate func performLongTask(sessionID sid: UUID) async throws -> String {
        try await performBackgroundTask { () -> String in
            // 定期上报进度（系统要求）：completedUnitCount 递增表示持续活跃。
            progress.totalUnitCount = 100
            progress.localizedDescription = String(localized: "intent_processing")
            let deadline = Date().addingTimeInterval(Self.finishTimeoutSeconds)
            while Date() < deadline {
                try Task.checkCancellation()
                // 引擎整轮完成（onComplete/onError/onInterrupted 写入信号）→ 上报结果。
                if let replyText = try await MainActor.run(body: { () -> String? in
                    try AppState.shared?.consumeIntentEngineFinished(sessionID: sid)
                }) {
                    return replyText
                }
                progress.completedUnitCount += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
            throw IntentError.timeout
        } onCancel: { _ in
            // 用户取消（Siri「取消」等）：通知引擎停止，避免后台继续空跑。
            Task { @MainActor in
                if let runtime = AppState.shared?.chatRuntimes[sid] { runtime.engine.cancel() }
                AppState.shared?.markIntentEngineFinished(sessionID: sid, result: .failure(IntentError.timeout))
                // 2026-08-12 修复：取消同样写终态，否则 status 卡 .running → 首页图标转圈
                // (runLoop 被 cancel 后静默返回，不触发 onComplete/onError 回调)。
                if let s = SessionManager.shared.session(id: sid),
                   s.status == .running || s.status == .retrying {
                    s.status = .completed
                    s.updatedAt = Date()
                    SessionManager.shared.persist(s)
                }
            }
        }
    }
}
#endif

#if compiler(>=6.4)
@available(iOS 27.0, *)
extension ContinueSessionIntent {
    /// 同 RunAgentTaskIntent.performLongTask：非隔离轮询体（sending 检查）。
    fileprivate func performLongTask(sessionID sid: UUID) async throws -> String {
        try await performBackgroundTask { () -> String in
            progress.totalUnitCount = 100
            progress.localizedDescription = String(localized: "intent_processing")
            let deadline = Date().addingTimeInterval(Self.finishTimeoutSeconds)
            while Date() < deadline {
                try Task.checkCancellation()
                if let replyText = try await MainActor.run(body: { () -> String? in
                    try AppState.shared?.consumeIntentEngineFinished(sessionID: sid)
                }) {
                    return replyText
                }
                progress.completedUnitCount += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
            throw IntentError.timeout
        } onCancel: { _ in
            Task { @MainActor in
                if let runtime = AppState.shared?.chatRuntimes[sid] { runtime.engine.cancel() }
                AppState.shared?.markIntentEngineFinished(sessionID: sid, result: .failure(IntentError.timeout))
            }
        }
    }
}
#endif

#if compiler(>=6.4)
// iOS 27+ 官方长任务协议遵循（LongRunningIntent : ProgressReportingIntent）。
// 采用条件编译：iOS 26.5 SDK 无此符号，旧编译器整块跳过（不解析、不报错）；
// Xcode 27 / iOS 27 SDK 下自动启用 performBackgroundTask 官方长任务路径（突破 30s 后台限制）。
// 2026-09-11（Xcode 26.6 / iOS 27 SDK）：带 onCancel: 的 performBackgroundTask 重载
// 额外要求 Self : CancellableIntent（anyAppleOS 26.4+ 空协议，无成员），此处一并补齐。
// 协议可用性（CancellableIntent=26.4 / LongRunningIntent=27.0）高于类型可用性（iOS 17），
// 遵循扩展必须显式标注类型自己的 @available，否则编译器在 iOS 16 上下文报「类型仅 iOS 17+ 可用」。
@available(iOS 17.0, *)
extension RunAgentTaskIntent: LongRunningIntent {}
@available(iOS 17.0, *)
extension ContinueSessionIntent: LongRunningIntent {}
@available(iOS 17.0, *)
extension RunAgentTaskIntent: CancellableIntent {}
@available(iOS 17.0, *)
extension ContinueSessionIntent: CancellableIntent {}
#endif
