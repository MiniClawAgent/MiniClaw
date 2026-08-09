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
/// 无法走 L10n.tr 运行时查表；如需多语言需接入 String Catalog（Localizable.xcstrings）体系。
///
/// 派发链路目前在 UI 层（ChatView 消费 pendingDeepLinkTask 后启动引擎），
/// 因此两个意图都置 openAppWhenRun = true 保证界面出现、任务必达；
/// 服务层派发器落地（无 UI 也能消费）后改回 false 实现真后台执行。
struct RunAgentTaskIntent: LiveActivityIntent, ProgressReportingIntent {

    static let title: LocalizedStringResource = "新建任务"
    static let description = IntentDescription("让 MiniClaw 智能体执行一条新任务（可附文件），完成后发通知")
    // headless：不打开 App 界面，任务由服务层消费者后台执行（用户已验证此模式可用）。
    static let openAppWhenRun = false

    @Parameter(title: "任务提示词", description: "要交给 MiniClaw 执行的指令", requestValueDialog: "要执行什么任务？")
    var prompt: String

    @Parameter(title: "附件", description: "要随任务发送的文件（可选），可接收前面动作的输出（如图片/文档）",
               supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var attachments: [IntentFile]?

    static var parameterSummary: some ParameterSummary {
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
        BackgroundTaskController.shared.startLiveActivity(sessionID: nil, title: "新建任务", icon: ChatSession.defaultIcon)

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentError.emptyPrompt }

        // 附件转为内存数据（由服务层消费者落盘到会话目录）；未配置附件时为 nil/空。
        var deepLinkAttachments: [AppState.DeepLinkAttachment] = []
        for file in attachments ?? [] {
            let data: Data
            do {
                data = try await file.data
            } catch {
                throw IntentError.attachmentReadFailed(file.filename)
            }
            deepLinkAttachments.append(AppState.DeepLinkAttachment(fileName: resolvedIntentFileName(for: file), data: data))
        }

        // 新建会话（与深链语义一致：source=deeplink），标题占位「新会话」由 智能体标题生成接管。
        guard let session = SessionManager.shared.createSession(title: "新会话", source: "deeplink") else {
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
        IntentNotification.postStarted(title: "新建任务", promptPreview: String(trimmed.prefix(50)), sessionID: session.id)

#if compiler(>=6.4)
        // ===== iOS 27+ 官方长任务路径（LongRunningIntent）=====
        // 任务放进 performBackgroundTask：系统扩展后台执行时间（突破 30s 限制）；
        // 期间必须定期更新 progress（官方硬性要求，否则系统取消扩展提前终止）；
        // 整轮完成才返回——perform 未返回期间快捷指令持续显示执行中，
        // 完成时经返回值（回复全文）+ 完成通知双路上报。
        let reply = try await performBackgroundTask { () -> String? in
            // 定期上报进度（系统要求）：totalUnitCount=0 为不确定进度，
            // completedUnitCount 递增表示持续活跃（进度数据源：引擎 词元/阶段，后续可细化）。
            progress.totalUnitCount = 100
            progress.localizedDescription = "MiniClaw 任务处理中…"
            let deadline = Date().addingTimeInterval(Self.finishTimeoutSeconds)
            while Date() < deadline {
                try Task.checkCancellation()
                // 引擎整轮完成（onComplete/onError/onInterrupted 写入信号）→ 上报结果。
                if let replyText = try AppState.shared?.consumeIntentEngineFinished(sessionID: session.id) {
                    return replyText
                }
                progress.completedUnitCount += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
            throw IntentError.timeout
        } onCancel: { _ in
            // 用户取消（Siri「取消」等）：通知引擎停止，避免后台继续空跑。
            Task { @MainActor in
                if let engine = AppState.shared?.chatRuntimes[session.id] { engine.cancel() }
                AppState.shared?.markIntentEngineFinished(sessionID: session.id, result: .failure(IntentError.timeout))
            }
        }
        return .result(value: reply ?? "", dialog: "任务完成")
#else
        // ===== iOS 26 及以下：现有 headless 路径 =====
        // 系统无官方后台延长 API，保持「等引擎启动即返回 + eager 保活 + LiveActivity + 完成通知」；
        // progress 定期更新仅作 Siri 进度显示（无延长能力）。
        // 等引擎真正开始 run 后再返回（消除「返回了但引擎没启动」窗口）。
        await waitForEngineStart(sessionID: session.id, progress: progress)
        return .result(value: "已开始", dialog: "任务已开始，完成后会通知你。")
#endif
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
            case .emptyPrompt: return "任务提示词为空，请输入要执行的任务"
            case .attachmentReadFailed(let name): return "附件「\(name)」读取失败，请重试"
            case .createSessionFailed: return "创建会话失败，请重试"
            case .timeout: return "等待任务完成超时（30 分钟），请到 App 内查看进度"
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
@MainActor
private func waitForEngineStart(sessionID: UUID, progress: Progress? = nil) async {
    for _ in 0..<50 {
        if AppState.shared?.intentEngineStartedSessions.contains(sessionID) == true {
            AppLogger.shared.info("[Intent] 引擎已启动，perform 返回", category: "Intent")
            return
        }
        if let progress {
            progress.totalUnitCount = 100
            progress.localizedDescription = "MiniClaw 任务处理中…"
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
struct MiniClawShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAgentTaskIntent(),
            phrases: [
                "用 ${applicationName} 执行任务",
                "让 ${applicationName} 运行任务",
                "新建 ${applicationName} 任务"
            ],
            shortTitle: "新建任务",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: ContinueSessionIntent(),
            phrases: [
                "继续 ${applicationName} 会话",
                "向 ${applicationName} 会话发送消息"
            ],
            shortTitle: "继续会话",
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

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "会话" }
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
        identifiers.compactMap { id in
            SessionManager.shared.session(id: id).map {
                ChatSessionEntity(id: $0.id, title: $0.title, iconName: $0.iconName)
            }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [ChatSessionEntity] {
        SessionManager.shared.allSessions().prefix(50).map {
            ChatSessionEntity(id: $0.id, title: $0.title, iconName: $0.iconName)
        }
    }
}

/// 继续会话：向选中的已有会话发送消息（可携带多个附件）。
/// - waitForResult = false（默认）：立即返回「已开始」，智能体完成后由引擎管线发本地通知；
/// - waitForResult = true：等待整轮完成，返回 智能体回复全文（可链式传给后续快捷指令动作）。
struct ContinueSessionIntent: LiveActivityIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "继续会话"
    static let description = IntentDescription("向选中的 MiniClaw 会话发送消息（可附文件）。可等待智能体完成并返回回复内容，或立即返回稍后通知。")
    // headless：与「运行任务」完全同机制（openAppWhenRun=false + 短语注册）。
    // 此前失败根因 = 未注册 AppShortcut 短语，用户从「App 动作」手动添加的意图
    // 路由不可靠（perform 不执行、App 不拉起）；短语注册后路由与运行任务一致。
    static let openAppWhenRun = false

    @Parameter(title: "会话", description: "选择要发送消息的会话")
    var session: ChatSessionEntity

    @Parameter(title: "消息", description: "要发送给智能体的内容", requestValueDialog: "要发送什么内容？")
    var message: String

    @Parameter(title: "附件", description: "要随消息发送的文件（可选），可接收前面动作的输出（如图片/文档）",
               supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var attachments: [IntentFile]?

    @Parameter(title: "等待结果", description: "开启后等待智能体完成并返回回复内容；关闭则立即返回，完成时发通知", default: false)
    var waitForResult: Bool

    /// 等待模式下防永久挂起的超时（秒）：任何链路故障（派发失败/引擎未启动）都不会让快捷指令无限转圈。
    static let waitTimeoutSeconds: UInt64 = 120
    /// 官方长任务路径（iOS 27+ LongRunningIntent）的完成兜底超时（秒）。
    static let finishTimeoutSeconds: TimeInterval = 1800

    static var parameterSummary: some ParameterSummary {
        // 显式列出全部参数（含可选参数）：否则「附件/等待结果」会折叠进快捷指令的
        // 隐藏区，用户看不到添加入口。
        Summary("向 \(\.$session) 发送 \(\.$message)") {
            \.$attachments
            \.$waitForResult
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
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
            let data: Data
            do {
                data = try await file.data
            } catch {
                throw IntentError.attachmentReadFailed(file.filename)
            }
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
        // 官方路径必须等到整轮完成才返回（保持 performBackgroundTask 扩展窗口，突破 30s 限制）；
        // waitForResult 仅影响 dialog 措辞，返回值恒为整轮回复文本（快捷指令总能拿到结果）。
        let reply = try await performBackgroundTask { () -> String? in
            progress.totalUnitCount = 100
            progress.localizedDescription = "MiniClaw 任务处理中…"
            let deadline = Date().addingTimeInterval(Self.finishTimeoutSeconds)
            while Date() < deadline {
                try Task.checkCancellation()
                if let replyText = try AppState.shared?.consumeIntentEngineFinished(sessionID: session.id) {
                    return replyText
                }
                progress.completedUnitCount += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
            throw IntentError.timeout
        } onCancel: { _ in
            Task { @MainActor in
                if let engine = AppState.shared?.chatRuntimes[session.id] { engine.cancel() }
                AppState.shared?.markIntentEngineFinished(sessionID: session.id, result: .failure(IntentError.timeout))
            }
        }
        return .result(value: reply ?? "", dialog: waitForResult ? "任务完成" : "已开始处理，完成后会通知你。")
#else
        // ===== iOS 26 及以下：现有 headless 路径 =====
        // 等引擎真正开始 run 后再返回（headless 无 UI，用户感知 = 通知；保证引擎已启动）。
        await waitForEngineStart(sessionID: session.id, progress: progress)

        guard waitForResult else {
            return .result(value: "已开始", dialog: "已开始处理，完成后会通知你。")
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
        return .result(value: reply, dialog: "任务完成")
#endif
    }

    enum IntentError: LocalizedError {
        case sessionNotFound
        case emptyMessage
        case attachmentReadFailed(String)
        case timeout
        var errorDescription: String? {
            switch self {
            case .sessionNotFound: return "找不到所选会话"
            case .emptyMessage: return "消息内容为空，请输入要发送给智能体的内容"
            case .attachmentReadFailed(let name): return "附件「\(name)」读取失败，请重试"
            case .timeout: return "等待智能体回复超时（120 秒），任务可能仍在运行，请到 App 内查看"
            }
        }
    }
}

#if compiler(>=6.4)
// iOS 27+ 官方长任务协议遵循（LongRunningIntent : ProgressReportingIntent）。
// 采用条件编译：iOS 26.5 SDK 无此符号，旧编译器整块跳过（不解析、不报错）；
// Xcode 27 / iOS 27 SDK 下自动启用 performBackgroundTask 官方长任务路径（突破 30s 后台限制）。
extension RunAgentTaskIntent: LongRunningIntent {}
extension ContinueSessionIntent: LongRunningIntent {}
#endif
