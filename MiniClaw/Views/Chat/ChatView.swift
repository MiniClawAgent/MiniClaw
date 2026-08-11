import Foundation
import SwiftUI
import MiniClawKit
import SwiftData
import UIKit

/// 全屏图片查看的标识项：用 `.fullScreenCover(item:)` 的规范写法承载，
/// 避免「计算 Binding + 内容内再读同一可选值」导致的偶尔不弹出的 SwiftUI 隐患。
struct FullscreenImageItem: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 上下文占用圆环：随实时占用比例变色，中心显示占用百分比数字（无 % 符号）。
/// 变色档位与「真正的压缩触发点」严格同源——红色起点 = 引擎分档策略的 compactThreshold，
/// 所以圆环变红那一刻就是引擎会压缩历史的那一刻（大窗口模型阈值可能是 88% 而非 80%）。
/// 点击进入 词元 用量详情。放置于会话页右上角菜单左侧。
struct ContextRingIndicator: View {
    let ratio: Double
    /// 当前模型/端点未配置上下文窗口时为 true，显示「∞ 无限制」而非误导性的假 0。
    var unlimited: Bool = false
    /// 压缩触发点在环上的位置（0...1）。红色从此处开始，黄色为其前 20% 区间。
    var thresholdRatio: Double = 0.8
    /// 占用是否来自服务商真实 prompt_tokens（false = 本地估算，数字用次级色）。
    var measured: Bool = true

    private var color: Color {
        let r = min(1, max(0, ratio))
        let danger = min(0.99, max(0.1, thresholdRatio))
        let warn = danger * 0.8
        if r < warn { return .green }
        if r < danger { return .yellow }
        return .red
    }

    var body: some View {
        ZStack {
            // 圆底与右上角选项按钮同色（secondarySystemBackground），视觉上成为一组按钮。
            Circle()
                .fill(Color(.secondarySystemBackground))
            Circle()
                .stroke(Color(.tertiarySystemBackground), lineWidth: 2.5)
            if unlimited {
                // 无限制：画一段灰色弧线表示「未设上限」，而不是 0%。
                Circle()
                    .trim(from: 0, to: 0.85)
                    .stroke(Color(.tertiaryLabel), lineWidth: 2.5)
                    .rotationEffect(.degrees(-90))
            } else {
                // 压缩触发点刻度：一小段灰线标出「到这里就会压缩」。
                Circle()
                    .trim(from: CGFloat(min(0.99, max(0.1, thresholdRatio))),
                          to: CGFloat(min(1.0, max(0.1, thresholdRatio) + 0.012)))
                    .stroke(Color(.tertiaryLabel), lineWidth: 4)
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, ratio))))
                    .stroke(color, lineWidth: 2.5)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: ratio)
            }
            // 只显示占用百分比数字（居中、粗体），不再叠加缓存闪电等附加信息。
            Text(unlimited ? "∞" : "\(Int(min(1, max(0, ratio)) * 100))")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(measured ? .primary : .secondary)
        }
        .frame(width: 27, height: 27)
        .contentShape(Circle())
        .accessibilityLabel(unlimited ? "上下文窗口无限制" : "上下文占用 \(Int(ratio * 100))%")
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Bindable var session: ChatSession

    @State private var inputText: String = ""
    /// 外部向输入框注入文本的通道（斜杠命令插入/清空/草稿恢复）：
    /// 输入框文本已本地化到 ChatInputBar，外部写入必须经此通道 + injectionID 触发应用。
    @State private var inputInjectionID = 0
    @State private var injectedInputText = ""
    @State private var pendingAttachments: [InputAttachment] = []
    /// 附件被模型输入模态过滤后的提示文案（短暂展示于输入栏上方，几秒后自动消失）。
    @State private var attachmentNotice: String?
    @State private var browserURL: URL? = nil
    @State private var fullscreenImageItem: FullscreenImageItem? = nil
    @State private var showFileManager: Bool = false
    @State private var showSessionTerminal: Bool = false
    @State private var showSessionBrowser: Bool = false
    @State private var showTokenUsage: Bool = false
    @State private var showSoulSettings: Bool = false
    @State private var showModelManagement: Bool = false
    /// 上下文占用快照的本地镜像（数据源是 `ContextUsageStore`，引擎写、UI 读）。
    /// 进入会话时先做一次本地估算兜底，随后由引擎的真值/校准估算持续刷新。
    @State private var contextSnapshot: ContextUsageSnapshot = .empty
    @State private var activeSubagentConversation: SubagentConversation? = nil
    @State private var lastMessageID: UUID?
    /// 是否允许自动跟随最新内容。默认开启；用户只要手动拖动会话列表就立即关闭，
    /// 后续 词元 / 工具事件不再抢回滚动控制，直到用户主动发送消息或重新进入会话。
    @State private var shouldAutoFollow: Bool = true
    @FocusState private var isInputFocused: Bool
    /// 悬浮层总高度(2026-08-11 重写):onGeometryChange 测整个 chatOverlay 真实内容高度
    /// (排队消息 + 子代理头像 + 附件提示 + 输入栏),不含键盘。键盘展开/收起不改该值,
    /// 故消息距输入栏距离在无键盘态与有键盘态恒定(= 列表 contentInset.bottom - 8)。
    @State private var inputBarHeight: CGFloat = 0
    @State private var inputBarHeightDebounce: Task<Void, Never>?
    /// 悬浮内容条(排队/子代理/附件)高度,照 OpenMinis floatingBarHeight 语义:
    /// 列表 bottomInset = inputBarHeight + floatingBarHeight + 8。
    @State private var floatingBarHeight: CGFloat = 0
    /// 输入栏最近一次 on-screen 高度(onGeometryChange 上报,debounce 提交时读最新值)。
    /// [KbdDiag 2026-08-11] 上次打日志的高度(去重,避免刷屏)。
    /// 必须 @State:onGeometryChange 的 action 是 @escaping 非 mutating 闭包,
    /// 普通存储属性无法在其中赋值(Cannot assign to property: 'self' is immutable)。
    @State private var lastLoggedInputBarH: CGFloat = -1
    @State private var latestInputBarFrameH: CGFloat = 0
    @State private var didSeedInputBarHeight = false

    /// 本会话的进行中运行时（含引擎与流式缓冲区），存活于 AppState、跨视图重建可认领。
    /// nil 表示当前没有活跃回复。
    private var runtime: ChatSessionRuntime? { appState.chatRuntimes[session.id] }

    /// 输入栏「发送/停止」切换用的响应态绑定：读运行时的 isResponding；
    /// 写入无意义（状态由引擎回调驱动），因此 set 为空。
    private var isRespondingBinding: Binding<Bool> {
        Binding(
            get: { appState.chatRuntimes[session.id]?.isResponding ?? false },
            set: { _ in }
        )
    }

    /// 当前是否正在响应（用于监听「回复完成」以触发排队消息处理）
    private var isResponding: Bool { appState.chatRuntimes[session.id]?.isResponding ?? false }

    /// 输入栏「暂停/继续」切换用的暂停态绑定：读运行时的 isPaused。
    private var isPausedBinding: Binding<Bool> {
        Binding(
            get: { appState.chatRuntimes[session.id]?.isPaused ?? false },
            set: { _ in }
        )
    }

    /// 当前主模型是否支持深度思考（决定「/thinking」菜单项是档位选择还是禁用）。
    private var modelSupportsThinking: Bool {
        appState.resolveModelRoutingPlan(for: .main)?.endpoints.first?.supportsDeepThinking ?? false
    }

    /// 「/thinking」菜单项展示的当前状态。session.thinkingLevel 三态：
    ///   nil  = 跟随模型默认（思考模型默认开启）；
    ///   "off"= 用户显式关闭；
    ///   具体档位 = 开启到该档位。
    private var currentThinkingLevel: String? {
        guard modelSupportsThinking else { return nil }
        return session.thinkingLevel
    }

    /// 可用的思考强度档位（固定列表，与 normalizedThinkingLevel 对齐）。
    private static let thinkingLevels: [(id: String, label: String)] = [
        ("low", L10n.tr("低")), ("medium", L10n.tr("中")), ("high", L10n.tr("高")), ("xhigh", L10n.tr("极高")), ("max", L10n.tr("极强"))
    ]

    /// 档位 id → 中文标签。
    private static let thinkingLevelLabels: [String: String] = [
        "low": L10n.tr("低"), "medium": L10n.tr("中"), "high": L10n.tr("高"), "xhigh": L10n.tr("极高"), "max": L10n.tr("极强")
    ]

    /// 当前主模型的 id（用于查询模型目录里的思考档位配置）。
    private var activeModelId: String? {
        appState.resolveModelRoutingPlan(for: .main)?.endpoints.first?.modelId
    }

    /// 当前模型实际可用的思考档位：
    /// - 模型不支持思考 → 返回空（不展示档位）。
    /// - 支持思考但厂商适配器目录未配置 thinkingLevels（或为空）→ 默认 [low, medium, high]。
    /// - 配置了 thinkingLevels → 按配置的子集展示。
    /// 保证「模型读取的配置信息」真正驱动态。
    private var availableThinkingLevels: [(id: String, label: String)] {
        guard modelSupportsThinking else { return [] }
        let ids: [String]
        if let endpoint = appState.resolveModelRoutingPlan(for: .main)?.endpoints.first,
           let provider = appState.providers.first(where: { $0.id == endpoint.providerId }),
           let configured = LLMProviderFactory.modelCapabilities(providerType: provider.providerType, modelID: endpoint.modelId)?.thinkingLevels,
           !configured.isEmpty {
            ids = configured
        } else {
            ids = ["low", "medium", "high"]
        }
        return ids.compactMap { id in
            guard let label = Self.thinkingLevelLabels[id] else { return nil }
            return (id, label)
        }
    }

    /// 渲染单条消息气泡。抽成独立方法是为了隔离类型推断：
    /// `MessageBubbleView` 参数较多且含闭包，直接在 `ForEach` 尾随闭包里构造会拖垮
    /// Swift 类型检查器（误判 `message` 为 `Binding`，进而 `ForEach` 重载选择失败）。
    ///
    /// 注意：这里**不再读取** `runtime.streamingContent` 等流式字段——流式值的订阅下沉到
    /// `MessageBubbleView` 内部：只有「正在流式的那条消息」会在 body 里读取 runtime，从而每个
    /// 词元只重绘那一个气泡，历史消息不再随词元重绘（防上滑卡顿）。
    /// 气泡流式「行数增长」上报入口：节流 0.3s 后驱动 ScrollViewReader 滚动。
    @MainActor
    /// 本会话排队中的用户消息
    private var pendingMessages: [PendingUserMessage] { appState.pendingUserMessages[session.id] ?? [] }

    // MARK: - 持久化（草稿 / 排队队列跨会话与杀后台）

    /// 把当前内存队列落盘为磁盘真源（空则清文件）。每次队列增删后调用。
    private func persistQueue() {
        PendingMessageStore.shared.save(appState.pendingUserMessages[session.id] ?? [], for: session.id)
    }

    /// 把输入栏未发送内容落盘（空白即清文件）。每次输入变化 / 退出会话 / 消息发出时调用。
    private func persistDraft() {
        PendingMessageStore.shared.saveDraft(inputText, for: session.id)
    }

    /// 进入会话时从磁盘恢复：把未发送草稿回填输入框、把排队消息恢复到内存字典。
    /// 保证杀后台 / 退出会话 / App 重启后，用户重新进入仍可继续编辑或推给 智能体。
    private func restorePersistedState() {
        // 1. 草稿回填（无则保持空）
        if let draft = PendingMessageStore.shared.loadDraft(for: session.id) {
            inputText = draft
            injectInput(draft)
        }
        // 2. 排队消息恢复：仅在内存字典为空时从磁盘补入，避免与已有运行时队列重复。
        if (appState.pendingUserMessages[session.id] ?? []).isEmpty {
            if let stored = PendingMessageStore.shared.load(for: session.id) {
                appState.pendingUserMessages[session.id] = stored
            }
        }
    }

    /// 斜杠命令执行（/clear、/compact、/memory、/thinking 等；技能与 insertText 类由调用方处理）。
    /// 2026-08-07 批次2 迁移事故后自 8-04 备份恢复函数头（结构对齐当前 SlashCommandKind 枚举）。
    private func handleSlashCommand(_ cmd: SlashCommandItem) {
        switch cmd.kind {
        case .skill(let name):
            // 用户技能命令：点击后在输入框填入 "/技能名 "，让用户可以补充任务后发送，
            // 真正「使用技能」发生在发送时（sendMessage 解析并一次性注入技能正文）。
            injectInput("/\(name) ")
            return
        case .action:
            switch cmd.id {
            case "clear":
                // 清空当前会话所有消息（保留会话本身）
                let messages = session.messages
                for msg in messages {
                    modelContext.delete(msg)
                }
                try? modelContext.save()
                AgentTaskStore.shared.clear(sessionID: session.id)
                appState.chatRuntimes[session.id] = nil

            case "compact":
                // 手动触发对话压缩（标记需要压缩，下次 run 时执行）
                if let runtime = appState.chatRuntimes[session.id] {
                    runtime.requestCompression = true
                }

            default:
                break
            }
        case .toggle(let current):
            // 记忆开关切换（/memory）
            var memorySettings = SettingsStore.shared.settings.memory
            memorySettings.isEnabled = !current
            SettingsStore.shared.set(memorySettings, domain: .memory, summary: L10n.tr("斜杠命令切换"))

        case .thinkingPicker(selectedLevel: _, levels: _):
            // 「/thinking」：左侧标签 = 开/关切换；右侧档位 pill = 直接切到该档。
            // session.thinkingLevel 三态语义：
            //   nil  = 跟随模型默认（思考模型默认开启），显示为蓝/开启；
            //   "off"= 用户显式关闭，显示为灰/关闭；
            //   具体档位 = 开启到该档位。
            guard modelSupportsThinking else { return }
            if cmd.thinkingLevel == "off" {
                session.thinkingLevel = "off"            // 左侧开关「关」
            } else if let level = cmd.thinkingLevel {
                session.thinkingLevel = level           // 档位 pill 或左侧开关「开」→ 设到该档
            } else {
                // 输入式 /thinking 直发（无档位信息）：翻转当前状态（开→关，关→开到 low）
                session.thinkingLevel = (session.thinkingLevel == "off") ? "low" : "off"
            }
            try? modelContext.save()

        default:
            // 插入文本类命令（/search、/image 等）→ 回填到输入框
            if case .insertText(let prefix) = cmd.kind {
                injectInput(prefix)
            }
        }
    }

    /// 解析「/技能名」指令：若输入以 `/` 开头且首个分词匹配某个已加载技能，
    /// 返回 (技能名, 后续任务文本)；否则返回 nil（视为普通消息或内置命令）。
    @MainActor
    private static func parseSkillCommand(_ raw: String) -> (skill: String, task: String)? {
        guard raw.hasPrefix("/") else { return nil }
        let body = String(raw.dropFirst())
        let comps = body.split(separator: " ", maxSplits: 1)
        guard let first = comps.first, !first.isEmpty else { return nil }
        let name = String(first)
        guard SkillManager.shared.skillNames().contains(name) else { return nil }
        let task = comps.count > 1 ? String(comps[1]).trimmingCharacters(in: .whitespaces) : ""
        return (name, task)
    }

    /// 从输入文本匹配内置（非技能）斜杠命令。命中返回对应命令项，否则返回 nil。
    /// 仅匹配 `SlashCommandOverlay.defaultCommands`，技能命令由 parseSkillCommand 处理。
    private static func builtinCommand(matching raw: String) -> SlashCommandItem? {
        guard raw.hasPrefix("/") else { return nil }
        let body = String(raw.dropFirst())
        return SlashCommandOverlay.defaultCommands.first { cmd in
            body == cmd.id || body.hasPrefix(cmd.id + " ")
        }
    }

    /// 向输入框注入文本（输入文本已本地化，外部写入统一走此通道）。
    private func injectInput(_ text: String) {
        injectedInputText = text
        inputInjectionID += 1
        inputText = text // 镜像同步（草稿落盘/其他读取仍用 inputText）
    }

    private func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 内置斜杠命令（clear/compact/memory/thinking 等，非技能）：直接执行对应动作，
        // 不发给模型，避免把命令本身当成用户消息导致 智能体乱回。
        if let cmd = Self.builtinCommand(matching: trimmed) {
            switch cmd.kind {
            case .action, .toggle, .thinkingPicker:
                handleSlashCommand(cmd)
                injectInput("")
                persistDraft()
                return
            case .disabled:
                // 不支持的命令：仅清空输入，不发送。
                injectInput("")
                persistDraft()
                return
            case .insertText, .skill:
                // 插入文本类 / 技能类命令：继续走下方的解析与发送逻辑。
                break
            }
        }

        // 解析是否为「/技能名」指令：是则剥离前缀，仅把后续文本作为用户任务，
        // 并在本轮把该技能正文一次性注入 system prompt，让 智能体直接按该技能执行。
        let parsedSkill = Self.parseSkillCommand(trimmed)
        let skillName = parsedSkill?.skill
        let taskText = parsedSkill?.task
        let injectedSkill: String? = skillName
        let workingText: String
        if let skillName {
            SkillManager.shared.incrementUseCount(skillName)
            workingText = (taskText?.isEmpty == false) ? taskText! : "请直接使用 \(skillName) 技能完成任务。"
        } else {
            // 非技能（普通文本或 /search 等插入文本命令）：原样发送。
            workingText = trimmed
        }
        let raw = workingText
        // 用户主动发送 → 视为想回到最新位置，重新钉住底部（后续的 onChange 才会滚动到底）。
        shouldAutoFollow = true
        AppLogger.shared.info("[Chat] sendMessage follow=true", category: "Chat")

        // 回复进行中 / 已暂停 → 新消息进入排队队列（以虚线气泡展示，不立即落盘为真实消息），
        // 等当前回复完成后按 FIFO 逐条处理；暂停态会在恢复后续跑时一并处理。
        if let runtime = appState.chatRuntimes[session.id], runtime.isResponding || runtime.isPaused {
            // 统一并入运行时队列（单一来源，由 processNextPendingMessage 做 FIFO 处理），
            // 不再调用引擎 actor 队列，避免与磁盘检查点 / 冷恢复双重并入。
            appState.pendingUserMessages[session.id, default: []].append(
                PendingUserMessage(text: raw, attachments: persistAttachmentsToSession(pendingAttachments), skillName: injectedSkill)
            )
            // 队列落盘为磁盘真源：无论回复中还是已暂停，都立即持久化，
            // 保证 App 被杀 / 退出会话后重新进入仍能恢复并继续处理。
            persistQueue()
            // 输入框内容已转入队列，清空并落盘草稿（空白即删除草稿文件）。
            inputText = ""
            pendingAttachments = []
            persistDraft()
            isInputFocused = false
            return
        }

        // 若 session 尚未持久化（来自首页"新会话"按钮），在此首次发送时插入 SwiftData，
        // 这样列表不会在导航动画期间就闪现空白行，不发言直接返回也不会留下空会话。
        if session.modelContext == nil {
            modelContext.insert(session)
            try? modelContext.save()
        }

        let userMessage = ChatMessage(role: .user, content: raw)
        userMessage.session = session
        // 用户附件复制进当前会话的 attachments/ 目录（会话独享、随会话删除），
        // 仅存会话相对路径「attachments/<name>」，显示时按活动 Documents 路径解析，避免绝对路径失效。
        userMessage.attachments = persistAttachmentsToSession(pendingAttachments)
        session.messages.append(userMessage)
        session.updatedAt = Date()

        // 首条消息：先写本地占位标题（即时、列表不空），再后台用 智能体精炼（服务层统一判定与生成）。
        AgentRunService.shared.generateAITitleIfNeeded(session: session, firstUserText: raw)

        let sentText = raw
        inputText = ""
        persistDraft()   // 消息已真正发出，清空草稿落盘
        pendingAttachments = []
        isInputFocused = false

        // 未接入模型：不生成任何 智能体回复，顶部提示横幅已引导用户去配置
        guard appState.hasConfiguredModel else { return }

        // 空闲 → 常规启动。（回复进行中的分支已在函数开头拦截并入队）
        startAgentResponse(to: sentText, userMessageID: userMessage.id, injectedSkill: injectedSkill, attachments: userMessage.attachments, thinkingLevel: session.thinkingLevel)
    }

    // MARK: - 深链派任务消费（P1-4）

    /// 消费 AppState 中等待本会话的深链派发任务（若存在且未被消费）。
    /// 复用既有发送管线（startAgentResponse），不触碰 AgentLoopEngine 与 system prompt 缓存前缀。
    @MainActor
    private func consumePendingDeepLinkTask() {
        guard let task = appState.pendingDeepLinkTask,
              task.targetSessionID == session.id,
              !appState.consumedDeepLinkIDs.contains(task.id) else { return }

        // 防重复：onAppear 与 onChange 可能各触发一次，以任务 id 去重。
        appState.consumedDeepLinkIDs.insert(task.id)

        let prompt = task.prompt

        // 回复进行中 / 已暂停 → 并入排队队列（与人工发送一致，FIFO 续跑）。
        // 回调随消息出队时绑定的那一轮引擎触发，故此处不立即回跳。
        if let runtime = appState.chatRuntimes[session.id], runtime.isResponding || runtime.isPaused {
            appState.pendingUserMessages[session.id, default: []].append(
                PendingUserMessage(text: prompt, dlXSuccess: task.xSuccess, dlXError: task.xError)
            )
            appState.pendingDeepLinkTask = nil
            return
        }

        // 未配置模型：不派发，回跳 x-error（若有）。这是确定性失败，不走「等跑完再回跳」。
        guard appState.hasConfiguredModel else {
            appState.pendingDeepLinkTask = nil
            appState.fireDeepLinkError(task.xError)
            return
        }

        // 会话尚未持久化（理论上 createSession 已 insert，这里仅兜底）。
        if session.modelContext == nil {
            modelContext.insert(session)
            try? modelContext.save()
        }

        let userMessage = ChatMessage(role: .user, content: prompt)
        userMessage.session = session
        session.messages.append(userMessage)
        session.updatedAt = Date()

        // 快捷指令「继续会话」携带的附件：直接落会话 attachments/ 目录（命名约定 <UUID前缀>_<原名>，
        // 与 persistAttachmentsToSession 全链路同名，工具按 hint 才能解析到），返回相对路径数组。
        var attachmentPaths: [String] = []
        if !task.attachments.isEmpty {
            let sessionAttachDir = SessionFileRouter.shared.sessionHostDirectory(for: session.id)
                .appendingPathComponent("attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: sessionAttachDir, withIntermediateDirectories: true)
            for att in task.attachments {
                let safeName = att.fileName.replacingOccurrences(of: "/", with: "_")
                let name = "\(UUID().uuidString.prefix(8))_\(safeName)"
                let dest = sessionAttachDir.appendingPathComponent(name)
                do {
                    try att.data.write(to: dest)
                    attachmentPaths.append("attachments/\(name)")
                } catch {
                    NSLog("[ChatView] 深链附件落盘失败: \(error.localizedDescription)")
                }
            }
        }

        // 首条消息占位标题与 智能体标题生成（与 sendMessage 一致，服务层统一判定）。
        AgentRunService.shared.generateAITitleIfNeeded(session: session, firstUserText: prompt)

        shouldAutoFollow = true
        AppLogger.shared.info("[Chat] deepLink dispatch follow=true", category: "Chat")
        // 回调绑定到「真正处理这条深链消息的这轮运行」：onComplete→x-success，onError/onInterrupted→x-error。
        startAgentResponse(to: prompt, userMessageID: userMessage.id, injectedSkill: nil, attachments: attachmentPaths, thinkingLevel: session.thinkingLevel, deepLinkCallback: (task.xSuccess, task.xError))
        // 启动成功（startAgentResponse 内部已创建运行时并清除 pendingDeepLinkTask）则到此为止；
        // 若任务仍存在说明路由解析失败未启动——确定性失败，回跳 x-error，避免调用方永久挂起。
        if appState.pendingDeepLinkTask?.id == task.id {
            appState.pendingDeepLinkTask = nil
            appState.fireDeepLinkError(task.xError)
        }
    }

    /// 把用户选中的附件迁入当前会话的 `attachments/` 目录，返回会话相对路径（"attachments/<name>"）。
    /// - 直接沿用选图/选文件时**已生成的文件名**（自带 UUID 前缀、保证不重名），把共享
    ///   `attachments/` 里的副本**移动**进会话目录，**不再二次重命名**。
    ///   这样 hint 注入的名字、磁盘落盘的名字、工具（vision_analyze / read_image / read_document）
    ///   解析的名字三方完全一致，避免「路径对、文件名对不上」导致工具调用失败。
    /// - 会话目录由 SessionFileRouter 管理，删除会话时整个目录树（含 attachments）一并清理；
    /// - 移动失败回退为「复制 + 沿用原名」，仍失败则回退为该附件的原始绝对路径（向后兼容旧数据展示）。
    /// - 该逻辑对所有附件类型（图片 / 音频 / 视频 / 文档）统一生效，无需按类型分支。
    private func persistAttachmentsToSession(_ items: [InputAttachment]) -> [String] {
        guard !items.isEmpty else { return [] }
        let sessionAttachDir = SessionFileRouter.shared.sessionHostDirectory(for: session.id)
            .appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionAttachDir, withIntermediateDirectories: true)
        return items.map { att in
            // 选图/选文件时 InputAttachment.url 已是共享 attachments/ 下「<UUID>_<原名>」的副本；
            // 沿用同一名字移入会话目录，确保全链路只有一个文件名，工具才能按 hint 找到文件。
            let name = att.url.lastPathComponent
            let dest = sessionAttachDir.appendingPathComponent(name)
            let moveIntoSession: () throws -> Void = {
                if att.url.path != dest.path {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: att.url, to: dest)
                }
            }
            do {
                try moveIntoSession()
                return "attachments/\(name)"
            } catch {
                // 移动失败（跨卷 / 权限等）：兜底复制并沿用原名，再删共享副本。
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: att.url, to: dest)
                    try? FileManager.default.removeItem(at: att.url)
                    return "attachments/\(name)"
                } catch {
                    NSLog("[ChatView] 附件迁入会话目录失败，回退原路径: \(error.localizedDescription)")
                    return att.url.path
                }
            }
        }
    }

    // MARK: - 引擎 + 运行时装配（启动 / 恢复共用）

    /// 发现已启用远端 MCP Server 的工具，并在本轮引擎开始前动态注册。
    /// 单个 Server 失败只更新其健康状态，不阻断本地工具和其他 MCP Server。

    /// 装配一个全新的 `AgentLoopEngine` + `ChatSessionRuntime`，并接好全部回调。
    /// 启动（全新回复）与恢复（冷启动重放开检查点）共用，避免两套重复逻辑。
    /// MCP 工具发现由调用方在引擎 run/resume 前完成，确保 schema 和 system prompt 使用同一份工具快照。
    /// - Parameters:
    ///   - assistantMessage: 续写的助手气泡（全新的空气泡，或恢复时已有的那个）。
    ///   - routingPlan: 已解析的主模型路由计划。

    /// 从会话历史构建发送给模型的 `history`（排除当前轮 user / 本轮 assistant 气泡，
    /// 且过滤掉 tool 角色消息——工具配对存在于引擎的检查点，不在此重建）。
    // MARK: - 上下文占用快照

    /// 同步右上角圆环的数据源：优先取引擎写入的最新快照；
    /// 若本会话尚无快照（冷启动 / 刚进入会话），本地估算一次基线，
    /// 让用户一进会话就能看到「system + 工具定义 + 历史」已占掉多少窗口，
    /// 而不是误导性的 0%（工具定义常年占数千 词元，绝非 0）。
    /// - Parameter force: true 时忽略已有快照强制重算（切换模型后窗口/阈值会变，必须重算）。
    private func syncContextSnapshot(force: Bool = false) {
        if !force, let existing = ContextUsageStore.shared.snapshot(for: session.id) {
            contextSnapshot = existing
            return
        }
        Task { @MainActor in
            guard let endpoint = appState.resolveModelRoutingPlan()?.endpoints.first else { return }
            let router = AgentRunService.shared.buildToolRouter(sessionID: session.id)
            let (stable, volatile) = await AgentRunService.shared.buildSystemPrompt(with: router, sessionID: session.id)
            var messages: [ChatCompletionMessage] = []
            var systemMessage = ChatCompletionMessage(role: "system", content: stable)
            systemMessage.volatileSuffix = volatile
            messages.append(systemMessage)
            messages.append(contentsOf: AgentRunService.shared.buildHistory(session: session, userMessageID: UUID(), responseMessageID: UUID()))
            let schemas = router.allSchemas()
            let breakdown = ContextUsageEstimator.breakdown(
                messages: messages,
                tools: schemas.isEmpty ? nil : schemas
            )
            let policy = ContextPolicy(
                window: endpoint.contextLimitTokens,
                reservedOutputTokens: endpoint.maxOutputTokens ?? 0
            )
            let snapshot = ContextUsageSnapshot(
                tokens: breakdown.total,
                window: endpoint.contextLimitTokens,
                compactThreshold: policy.compactThreshold,
                measured: false,
                breakdown: breakdown,
                updatedAt: Date()
            )
            contextSnapshot = snapshot
            ContextUsageStore.shared.update(snapshot, for: session.id)
        }
    }

    /// 按端点输入模态能力过滤附件路径：不支持的模态直接剔除，返回被剔除的文件名。
    /// 纯文本模型（四个输入模态全关）会剔除全部附件——附件仍随消息气泡展示，
    /// 但不会编码进请求体，避免服务端 4xx 或静默截断。
    /// 返回三元组：(允许的路径列表, 被剔除的文件名列表, 被剔除的完整路径列表)

    /// 导航栏工具项（principal 标题 + 圆环 + 选项菜单）。抽为独立 ToolbarContent，
    /// 避免 body 巨型链式表达式触发编译器类型检查超时。
    @ToolbarContentBuilder
    private var chatToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            sessionHeaderToolbar
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showTokenUsage = true
            } label: {
                ContextRingIndicator(
                    ratio: contextSnapshot.ratio,
                    unlimited: contextSnapshot.isUnlimited,
                    thresholdRatio: contextSnapshot.thresholdRatio,
                    measured: contextSnapshot.measured
                )
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showFileManager = true
                } label: {
                    Label(L10n.tr("当前会话的文件管理"), systemImage: "folder")
                }
                Button {
                    showSessionTerminal = true
                } label: {
                    Label(L10n.tr("命令行（绑定本会话）"), systemImage: "terminal")
                }
                Button {
                    showSessionBrowser = true
                } label: {
                    Label(L10n.tr("浏览器（绑定本会话）"), systemImage: "safari")
                }

                // 后续选项在此追加
            } label: {
                sessionMenuLabel
            }
        }
    }

    /// 会话页标题区：会话标题（点按进灵魂设置）+ 模型名（点按进模型管理），居中显示。
    private var sessionHeaderToolbar: some View {
        VStack(spacing: 1) {
            Text(headerTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .onTapGesture { showSoulSettings = true }
            Text(headerModelName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .onTapGesture { showModelManagement = true }
        }
    }

    /// 标题区展示的标题：AI 尚未改名前（titleIsPlaceholder，即占位标题）显示首条用户消息
    /// 前 10 个字（超出部分用 "..." 截断）；AI 自动改标题 / 用户手动改名后显示会话标题（自动同步）。
    private var headerTitle: String {
        if session.titleIsPlaceholder {
            guard let first = session.messages.first(where: { $0.role == .user })?.content else {
                return session.title
            }
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = String(trimmed.prefix(10))
            return trimmed.count > 10 ? prefix + "..." : prefix
        }
        return session.title
    }

    /// 标题区当前应展示的模型名：正在流式回复时显示本消息实际所用模型，否则显示实时配置。
    private var headerModelName: String {
        if session.status == .running && !session.modelName.isEmpty {
            return session.modelName
        }
        return appState.currentModelDisplayName
    }

    /// 右上角选项菜单按钮的圆形标签。
    private var sessionMenuLabel: some View {
        ZStack {
            Circle()
                .fill(Color(.secondarySystemBackground))
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }

    /// 输入栏悬浮层(2026-08-11 拆分 body 避免类型推断超时)。
    /// 悬浮内容条(排队消息 + 子代理头像 + 附件提示):照 OpenMinis floatingToolPreview
    /// 语义,独立于输入栏测高(列表 bottomInset = inputBarHeight + floatingBarHeight + 8)。
    @ViewBuilder
    private var floatingContent: some View {
        // 「回到底部」按钮已按用户要求从源码剔除(2026-08-10)。

        // 排队消息:显示在输入框上方悬浮层(2026-08-10 用户要求,
        // 不再注入消息列表内容里)。每条含删除叉 + 立即发送按钮。
        let queue = pendingMessages
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(queue) { item in
                    queuedMessageRow(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }

        // 子代理：在输入框上方悬浮显示圆形头像（常驻，任务完成后也不消失）。
        // 点按头像从底部弹出「智能体 ↔ 子代理」对话详情页（下滑返回）；
        // 长按头像可移除该子代理卡片。
        let subs = SubagentStore.shared.avatars(for: session.id)
        if !subs.isEmpty {
            subagentFloatingAvatars(subs)
        }

        // 附件交由 智能体通过工具读取时的中性提示：
        // - 与输入栏左右对齐（同样的 16pt 外边距 + 12pt 内边距、左对齐）
        // - 用户可点按整条提示立即关闭（同时保留 5 秒后自动消失）
        if let notice = attachmentNotice {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { attachmentNotice = nil } }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var chatOverlay: some View {
        VStack(spacing: 0) {
            // 悬浮内容条(排队/子代理/附件):照 OpenMinis floatingToolPreview 独立测高。
            floatingContent
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newH in
                    floatingBarHeight = newH
                }
                .onDisappear {
                    floatingBarHeight = 0
                }
            ChatInputBar(
                isAgentResponding: isRespondingBinding,
                isPaused: isPausedBinding,
                attachments: $pendingAttachments,
                injectedText: injectedInputText,
                injectionID: inputInjectionID,
                onDraftChanged: { text in
                    // 防抖镜像同步 + 草稿落盘（击键不再触发本视图重算）
                    inputText = text
                    persistDraft()
                },
                onSend: { text in
                    sendMessage(text)
                },
                onPause: pauseGeneration,
                onResume: resumeGeneration,
                onSlashCommand: handleSlashCommand,
                thinkingSupported: modelSupportsThinking,
                thinkingSelectedLevel: currentThinkingLevel,
                thinkingLevels: availableThinkingLevels,
                focused: $isInputFocused
            )
            // 照 OpenMinis inputBar 测高:seed 首帧同步 + 380ms debounce + 320ms settle-confirm。
            // .global frame 的 height 不受键盘影响(键盘只改 Y),配合 onscreen 守卫。
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                let newH = frame.size.height
                guard newH > 0 else { return }
                let hostWindow = inputBarWindowBounds()
                let paneW = frame.width > 1 ? frame.width : hostWindow.width
                let tolerance = paneW * 0.25
                let onscreen = frame.minX >= hostWindow.minX - tolerance
                    && frame.maxX <= hostWindow.maxX + tolerance
                if onscreen { latestInputBarFrameH = newH }
                // [KbdDiag 2026-08-11] 输入栏测高全链路日志(照 OpenMinis InputBarLayout):
                // 每次上报打 frame.height + onscreen,seed/commit 时打结果。
                if newH != lastLoggedInputBarH {
                    lastLoggedInputBarH = newH
                    AppLogger.shared.info("[InputBarLayout] h=\(String(format: "%.1f", newH)) onscreen=\(onscreen) y=\(String(format: "%.1f", frame.minY)) win.h=\(String(format: "%.1f", hostWindow.height))", category: "InputBarLayout")
                }
                if !didSeedInputBarHeight, onscreen {
                    didSeedInputBarHeight = true
                    AppLogger.shared.info("[InputBarLayout] SEED inputBarHeight=\(String(format: "%.1f", newH))", category: "InputBarLayout")
                    inputBarHeightDebounce?.cancel()
                    inputBarHeight = newH
                    inputBarHeightDebounce = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(380))
                        guard !Task.isCancelled else { return }
                        let settled = latestInputBarFrameH
                        if settled > 0, abs(settled - newH) > 0.5 {
                            inputBarHeight = settled
                        }
                    }
                    return
                }
                guard onscreen else { return }
                inputBarHeightDebounce?.cancel()
                inputBarHeightDebounce = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(380))
                    guard !Task.isCancelled else { return }
                    let committed = latestInputBarFrameH > 0 ? latestInputBarFrameH : newH
                    if abs(committed - inputBarHeight) > 0.5 {
                        AppLogger.shared.info("[InputBarLayout] COMMIT inputBarHeight=\(String(format: "%.1f", committed))", category: "InputBarLayout")
                    }
                    inputBarHeight = committed
                    try? await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    let settled = latestInputBarFrameH
                    if settled > 0, abs(settled - committed) > 0.5 {
                        inputBarHeight = settled
                    }
                }
            }
        }
        .onAppear { didSeedInputBarHeight = false }
    }

    var body: some View {
        ZStack {
            messageListView
        }
        // 照 OpenMinis:输入栏以 .overlay(alignment:.bottom) 悬浮,受 safe area 约束,
        // 键盘展开/收起由系统自动键盘规避统一抬升——消息距输入栏距离恒定。
        .overlay(alignment: .bottom) {
            chatOverlay
        }
        // 键盘高度监听已移至列表 Coordinator(keyboardHeight),此处不再手动桥接。
        .onChange(of: appState.pendingBrowserURL) { _, url in
            if let url { browserURL = url; appState.pendingBrowserURL = nil }
        }
        .sheet(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 { browserURL = nil } }
        )) {
            if let url = browserURL {
                BrowserView(startURL: url)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showFileManager) {
            SessionFileManagerView(sessionID: session.id)
        }
        .sheet(isPresented: $showTokenUsage) {
            SessionTokenUsageView(session: session)
        }
        .sheet(item: $activeSubagentConversation) { conv in
            SubagentChatView(conversation: conv, sessionID: session.id)
                .presentationDragIndicator(.visible)
                // sheet 默认带抬升材质（深色下偏灰、不透黑），与主会话纯黑背景不一致；
                // 显式指定 presentationBackground = 系统背景（深色模式即纯黑）。
                .presentationBackground(Color(.systemBackground))
        }
        .fullScreenCover(isPresented: $showSoulSettings) {
            NavigationStack {
                SoulSettingsView(dismissAction: { showSoulSettings = false })
            }
        }
        .fullScreenCover(isPresented: $showModelManagement) {
            NavigationStack {
                GroupsSettingsView(dismissAction: { showModelManagement = false })
            }
        }
        .fullScreenCover(isPresented: $showSessionTerminal) {
            #if ISH_ENABLED
            TerminalView(initialSessionID: session.id, initialSessionTitle: session.title)
            #else
            UnavailablePlaceholder(title: L10n.tr("终端不可用"), message: L10n.tr("当前构建未集成 iSH 运行环境"))
            #endif
        }
        // 会话内浏览器（菜单「浏览器」入口）：初始 URL = 当前会话打开的链接；
        // 无则不加载任何页面（空白页，保留上一次的标签与浏览状态，绝不自动导航到默认站点）。
        // sheet + large detent：可下拉收起（浏览器状态保留在后台，标签/页面不丢），
        // 与首页浏览器的关闭方式一致；「完成」按钮与下拉等效。
        .sheet(isPresented: $showSessionBrowser) {
            BrowserView(startURL: browserURL)
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $fullscreenImageItem) { item in
            FullscreenImageView(
                imageURL: item.url,
                isPresented: Binding(
                    get: { fullscreenImageItem != nil },
                    set: { if !$0 { fullscreenImageItem = nil } }
                )
            )
        }
        // 标题区：系统导航栏 principal 居中显示（会话标题 + 模型名）。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar {
            chatToolbarItems
        }
        .onAppear {
            lastMessageID = session.messages.last?.id
            BrowserController.shared.setSession(session.id)
            restorePersistedState()
            // 调试日志（2026-08-08）：重进会话后的回复状态全链路追踪。
            let lastAssistant = session.messages.last(where: { $0.role == .assistant })
            AppLogger.shared.info("[Resume] onAppear: runtimeExists=\(appState.chatRuntimes[session.id] != nil), messages=\(session.messages.count), 最后AI消息 content=\(lastAssistant?.content.count ?? -1)字 toolCalls=\(lastAssistant?.toolCalls.count ?? -1) isStreaming=\(lastAssistant?.isStreaming ?? false) wasStopped=\(lastAssistant?.wasStopped ?? false) wasInterrupted=\(lastAssistant?.wasInterrupted ?? false) sessionStatus=\(session.status.rawValue)", category: "Agent", subsystem: "Resume")
            recoverIfNeeded()
            syncContextSnapshot()
            consumePendingDeepLinkTask()
        }
        .onChange(of: appState.pendingDeepLinkTask?.id) { _, _ in
            consumePendingDeepLinkTask()
        }
        .onChange(of: session.messages.count) { _, _ in
            lastMessageID = session.messages.last?.id
        }
        .onChange(of: session.modelName) { _, _ in
            // 切换模型 = 换了上下文窗口与压缩阈值，圆环必须按新窗口重算。
            syncContextSnapshot(force: true)
        }
        .onChange(of: isResponding) { wasResponding, nowResponding in
            // 当前回复刚结束（true → false）→ 立即处理队列中最早排队的消息
            if wasResponding && !nowResponding {
                processNextPendingMessage()
                // P24:回复完成显式贴底——完成瞬间无任何路径触发 scrollToBottom
                // (消息数不变、streamGrown 停报),KVO 兜底又被锚点窗口拦截,
                // 最后消息停在输入框后面。0.15s 等块级拆分/落盘布局稳定。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard shouldAutoFollow else { return }
                    chatBridge.vm.scrollToBottomSignal.send()
                }
            }
        }
        .onChange(of: inputText) { _, _ in
            // 输入变化即落盘草稿，使其跨退出会话 / 杀后台可恢复。
            persistDraft()
        }
        .onDisappear {
            // 退出会话时兜底保存最新草稿（键盘收起等边界下 .onChange 已覆盖，这里再保一次）。
            persistDraft()
            // fullScreenCover（会话内命令行）会把本视图移出层级并触发 onDisappear——
            // 此时用户并没有离开会话，绝不能执行空会话清理，否则会把会话从 SwiftData
            // 删掉并 unregister（删除刚建好的 Sessions/<uuid>/ 目录），导致终端里
            // 显示「已删除的会话」且 echo 写 /var/MiniClaw/workspace 报 ENOENT。
            if showSessionTerminal || showSessionBrowser { return }
            // 离开会话时触发「复盘分身」：沉淀用户画像/偏好/近况，并生成会话摘要。
            // （App 进后台由 MiniClawApp 的 scenePhase 统一触发；重复触发由
            //  SessionReviewService 内部的去重与「无新消息跳过」保证。）
            // 记忆总开关关闭时直接跳过触发：用户主动关闭记忆即不希望任何后台记录。
            if SettingsStore.shared.settings.memory.isEnabled {
                SessionReviewService.shared.schedule(sessionID: session.id)
            }
            // 仅对已持久化的空会话执行清理；全新未发言的会话未 insert，无需删除
            if session.messages.isEmpty, session.modelContext != nil {
                let sid = session.id
                modelContext.delete(session)
                try? modelContext.save()
                // 空会话同样清理隔离资源（注销 fsContext + 删除 Sessions/<uuid>/）
                SessionFileRouter.shared.unregister(sessionID: sid)
                // 顺手清掉该会话的子代理运行期注册表（复用状态不再需要）。
                SubagentRuntimeRegistry.shared.clear(sessionID: sid)
                ContextUsageStore.shared.clear(sessionID: sid)
            }
        }
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: fullscreenImageItem)
    }

    // MARK: - Message List

    /// 适配列表数据桥(2026-08-09 会话页 1:1 重构):移植列表组件的数据适配层
    @StateObject private var chatBridge = MiniClawChatBridge()

    /// 受控展开状态（2026-08-09）：思考块/工具卡/错误详情的展开集合。

    /// 贴底状态（开源参考实现对齐：控制浮动「回到底部」按钮显隐）
    @State private var isNearBottom = false

    private var messageListView: some View {
        adaptedListContent
        // 2026-08-11 恢复:仅列表延伸到小横条(消息可滚到小横条后面,底部无白条);
        // 输入栏 overlay 不受影响,仍尊重底部安全区停留在原位置。
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            shouldAutoFollow = true
            AppLogger.shared.info("[Chat] onAppear follow=true messages=" + String(session.messages.count)
                + " scrollToMessageID=" + (appState.scrollToMessageID != nil ? "set" : "nil"), category: "Chat")
            // 初始贴底：延迟到布局完成后滚动一次（用户已上滑则放弃）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                AppLogger.shared.info("[Chat] delayedScroll follow=" + (shouldAutoFollow ? "1" : "0"), category: "Chat")
                guard shouldAutoFollow else { return }
                chatBridge.vm.scrollToBottomSignal.send()
            }
            // 无有效目标也清空，避免泄漏到后续进入
            appState.scrollToMessageID = nil
        }
        // 贴底状态同步（浮动「回到底部」按钮显隐,2026-08-10 OM 路径）
        .onChange(of: chatBridge.vm.isNearBottom) { _, near in
            isNearBottom = near
        }
    }

    /// 适配列表(OpenMinis 移植组件,默认路径),miniclaw.debug.chatList 开启时使用)

    private var adaptedListContent: some View {
        CollectionViewMessageListV3(
            vm: chatBridge.vm,
            inputFocused: isInputFocused,
            onRetryMessage: nil,
            onResume: { chatBridge.onResume?() },
            onStop: { chatBridge.onStop?() },
            maxContentWidth: 0,
            floatingBarHeight: floatingBarHeight,
            inputBarHeight: inputBarHeight
        )
        .onAppear {
            chatBridge.attach(session: session, appState: appState)
            // 值类型捕获:ChatView 为 struct,闭包捕获的是值副本,无保留环风险
            chatBridge.onResume = { resumeGeneration() }
            chatBridge.onStop = { stopGeneration() }
        }
        .onChange(of: session.messages.count) { _, _ in chatBridge.refresh() }
        .onChange(of: session.messages.last?.content.count ?? 0) { _, _ in chatBridge.refresh() }
        .onChange(of: session.messages.last?.isStreaming ?? false) { _, _ in chatBridge.refresh(force: true) }
    }
    // MARK: - 子代理悬浮头像（输入框上方）

    /// 排队消息行(输入框上方悬浮层):虚线气泡 + 删除叉 + 立即发送按钮 + 长按菜单。
    /// 2026-08-10 用户要求排队消息显示在输入框上方而非消息列表内容里。
    private func queuedMessageRow(_ item: PendingUserMessage) -> some View {
        HStack(spacing: 6) {
            // 立即发送:中断当前回复并立即发送该条。
            Button {
                appState.pendingUserMessages[session.id, default: []].removeAll { $0.id == item.id }
                sendQueuedMessage(item.id)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
            }
            Text(item.text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // 删除叉:取消该条排队消息。
            Button {
                appState.pendingUserMessages[session.id, default: []].removeAll { $0.id == item.id }
                persistQueue()
                chatBridge.refresh()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(Color.gray.opacity(0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button {
                UIPasteboard.general.string = item.text
            } label: {
                Label(L10n.tr("复制"), systemImage: "doc.on.doc")
            }
            Button {
                injectInput(item.text)
                appState.pendingUserMessages[session.id, default: []].removeAll { $0.id == item.id }
                persistQueue()
                chatBridge.refresh()
            } label: {
                Label(L10n.tr("编辑"), systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                appState.pendingUserMessages[session.id, default: []].removeAll { $0.id == item.id }
                persistQueue()
                chatBridge.refresh()
            } label: {
                Label(L10n.tr("删除"), systemImage: "trash")
            }
        }
    }

    /// 输入栏测高用的宿主窗口 bounds。
    private func inputBarWindowBounds() -> CGRect {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let window else { return UIScreen.main.bounds }
        return window.bounds
    }

    /// 输入框上方悬浮的子代理圆形头像：SF 图标占位，点按打开「智能体 ↔ 子代理」对话详情页。
    /// 横向排布、最多铺满宽度；状态用颜色区分（运行中=强调色，出错=红色）。
    /// 仅显示圆形头像本身（无额外背景条），长按头像可移除该子代理卡片。
    private func subagentFloatingAvatars(_ subs: [SubagentCard]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(subs) { sub in
                    Button {
                        if let conv = SubagentStore.shared.conversation(for: session.id, subagentID: sub.id) {
                            activeSubagentConversation = conv
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(sub.status == .error ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                                .frame(width: 38, height: 38)
                            Image(systemName: sub.status == .error ? "exclamationmark.triangle" : "cpu")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(sub.status == .error ? .red : .accentColor)
                        }
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onLongPressGesture {
                        // 长按删除：与 智能体侧 close_subagent 同一条统一路径
                        // （取消运行中引擎 → 移除复用记录 → 移除卡片与对话 → 释放浏览器上下文）。
                        _ = SubagentLifecycle.close(
                            sessionID: session.id,
                            subagentID: sub.id,
                            cancel: { [weak appState] id in
                                appState?.chatRuntimes[session.id]?.cancelSubagent(subagentID: id)
                            }
                        )
                        if activeSubagentConversation?.id == sub.id {
                            activeSubagentConversation = nil
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }


    // MARK: - Actions

    /// 展示「附件将交由 智能体通过工具读取」的短暂提示，几秒后自动消失。
    @MainActor
    private func showAttachmentNotice(droppedNames: [String]) {
        guard !droppedNames.isEmpty else { return }
        let list = droppedNames.prefix(3).joined(separator: "、")
        let suffix = droppedNames.count > 3 ? String(format: L10n.tr(" 等 %@ 个文件"), String(droppedNames.count)) : ""
        withAnimation { attachmentNotice = String(format: L10n.tr("已发送给智能体（将交由智能体通过工具读取）：%@%@"), list, suffix) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation { attachmentNotice = nil }
        }
    }

    @MainActor
    /// 启动一轮 智能体回复（人工发送/排队/深链共用入口）。
    /// 职责：OAuth 刷新、路由解析、附件模态过滤与提示、hints 注入，
    /// 其余（检查点/引擎装配/运行时注册/系统提示/run）全部委托 AgentRunService.startRun。
    private func startAgentResponse(to userInput: String, userMessageID: UUID, injectedSkill: String? = nil, attachments: [String] = [], thinkingLevel: String? = nil, deepLinkCallback: (xSuccess: URL?, xError: URL?)? = nil) {
        // OAuth 服务商：发送前刷新 令牌（过期自动续期）。同步入口无法 await，
        // 由后台 Task 先行刷新；即使刷新未完成，端点解析还有 Keychain 同步兜底（见 AppState.makeRouteEndpoint）。
        if appState.hasOAuthProviders {
            Task { await appState.refreshOAuthTokensIfNeeded() }
        }

        // 解析模型组候选端点；未设置主模型组时自动兼容全局默认模型。
        guard let routingPlan = appState.resolveModelRoutingPlan(for: .main),
              let firstEndpoint = routingPlan.endpoints.first else { return }

        // 按首选端点的输入模态能力过滤附件：不支持的模态不进请求体，并提示用户。
        // 被模型原生模态拒收的附件（含图片——图片改由 vision_analyze 工具兜底读取）
        // 统一在输入栏上方弹一条提示，用户可点按关闭。
        let (allowedAttachments, droppedNames, droppedPaths) = AgentRunService.filterAttachments(attachments, endpoint: firstEndpoint)
        showAttachmentNotice(droppedNames: droppedNames)

        // 对于因模型不支持而被丢弃的附件，在用户消息中注入路径提示，
        // 让 智能体自行通过工具读取（模仿端侧「让 智能体自己找工具读文件」的模式）：
        // - 图片 → vision_analyze 工具（Apple Vision 端侧分析）
        // - 其它文件 → read_document 工具（txt/md/json/pdf 等）
        // 路径统一用 /var/MiniClaw/... 形式，与文件工具的 resolveAgentPath 约定一致，
        // 否则工具会因路径前缀不对而读取失败。
        var enrichedInput = userInput
        if !droppedPaths.isEmpty {
            let guestBase = "/var/MiniClaw/"
            let imagePaths = droppedPaths.filter { AttachmentKind.from(ext: ($0 as NSString).pathExtension) == .image }
                .map { guestBase + $0 }
            let filePaths = droppedPaths.filter { AttachmentKind.from(ext: ($0 as NSString).pathExtension) != .image }
                .map { guestBase + $0 }

            var hints: [String] = []
            if !imagePaths.isEmpty {
                let fileList = imagePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                let pathList = imagePaths.joined(separator: "\", \"")
                hints.append("[图片] 用户附件了 \(imagePaths.count) 张图片 (\(fileList))，但当前模型不支持原生视觉输入。请使用 vision_analyze 工具分析这些图片来理解用户意图。图片路径：\"\(pathList)\"")
            }
            if !filePaths.isEmpty {
                let fileList = filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                let pathList = filePaths.joined(separator: "\", \"")
                hints.append("[文件] 用户附件了 \(filePaths.count) 个文件 (\(fileList))，但当前模型不支持直接读取。请使用 read_document 工具读取这些文件的内容来理解用户意图。文件路径：\"\(pathList)\"")
            }
            if !hints.isEmpty {
                enrichedInput.append("\n\n[系统提示] " + hints.joined(separator: "\n"))
            }
        }

        AgentRunService.shared.startRun(
            session: session,
            enrichedInput: enrichedInput,
            userMessageID: userMessageID,
            routingPlan: routingPlan,
            allowedAttachments: allowedAttachments,
            injectedSkill: injectedSkill,
            thinkingLevel: thinkingLevel,
            deepLinkCallback: deepLinkCallback,
            uiHooks: AgentRunService.UIHooks(onContextUsage: { [self] snapshot in
                contextSnapshot = snapshot
            })
        )
    }


    // MARK: - 停止

    /// 从会话设置构造采样配置：startAgentResponse 与恢复路径（recoverIfNeeded）共用，
    /// 保证「新建回复」与「暂停→继续/冷启动续跑」的采样参数同源（恢复路径曾丢失 sampling）。

    /// 硬终止（用于回复中停止 / 工具执行中点按中断）：彻底中止循环，
    /// 已收内容落盘，并把回复终态明确标记为「已停止」而非「已完成」。
    private func stopGeneration() {
        guard let runtime = appState.chatRuntimes[session.id] else { return }
        runtime.mcpPreparationTask?.cancel()
        runtime.mcpPreparationTask = nil
        runtime.engine.cancel()
        // 收尾前先提交流式节流缓冲：pendingText/pendingReasoning 中的尾包
        // 尚未刷入 streamingContent，直接落盘会丢回复最后一段。
        runtime.commitStreamBuffer()
        runtime.commitReasoningBuffer()

        let stoppedAt = Date()
        // 只标记当前仍未返回结果的工具；此前已完成/失败的工具保留原状态。
        for index in runtime.streamingToolCalls.indices where runtime.streamingToolCalls[index].resultText.isEmpty {
            runtime.streamingToolCalls[index].wasInterrupted = true
            runtime.streamingToolCalls[index].resultText = L10n.tr("用户已停止")
            runtime.streamingToolCalls[index].success = false
            runtime.streamingToolCalls[index].duration = stoppedAt.timeIntervalSince(runtime.streamingToolCalls[index].timestamp)
        }

        if let sid = runtime.streamingMessageID,
           let msg = session.messages.first(where: { $0.id == sid }) {
            msg.content = runtime.streamingContent
            msg.isStreaming = false
            msg.wasStopped = true
            // 任务总耗时：用户停止即终态，结算耗时（暂停态停止同样覆盖；断点恢复任务不显示）。
            if !runtime.taskTimingInvalid, msg.taskElapsedSeconds == nil { msg.taskElapsedSeconds = runtime.taskSettle() }
            if !runtime.streamingToolCalls.isEmpty {
                msg.toolCalls = runtime.streamingToolCalls
            }
        }
        runtime.isResponding = false
        session.status = .completed
        session.updatedAt = stoppedAt
        appState.chatRuntimes[session.id] = nil
        // 关键：置空本运行时的 streamingMessageID。强行发送排队消息时旧引擎的
        // 在途网络请求可能在「新运行时已安装」之后才回调 onComplete/onError/onInterrupted，
        // 那些回调的 guard 依赖 `runtime.streamingMessageID == responseMessageID`；此处把旧值清空，
        // 延迟回调会因拿到 nil 而直接 no-op，从而不会误杀消息2的新运行时、也不会回写旧气泡。
        runtime.streamingMessageID = nil
    }

    // MARK: - 暂停 / 恢复

    /// 软暂停：只让引擎进入「暂停请求」，引擎会在最近的安全点
    /// （本轮流式结束 / 某个工具执行完）把上下文快照为检查点并落地为 `.paused`。
    /// 不立即改 UI——`AgentLoopEngine.onPaused` 回调会切换到「已暂停」状态，
    /// 输入栏随之从「暂停」切到「继续」，气泡保留以便续写。
    private func pauseGeneration() {
        guard let runtime = appState.chatRuntimes[session.id], runtime.isResponding else { return }
        runtime.engine.pause()
    }

    /// 恢复：从检查点重放上下文，开一个全新 Loop 续写同一气泡。
    /// 若检查点丢失（极端情况），退化为硬停止。
    private func resumeGeneration() {
        guard let runtime = appState.chatRuntimes[session.id], runtime.isPaused else { return }
        guard var task = AgentTaskStore.shared.load(sessionID: session.id) else {
            stopGeneration()
            return
        }
        // 把磁盘排队消息交给运行时队列统一 FIFO 接管：队列的磁盘真源是
        // PendingMessageStore（而非检查点 pendingUserInputs），仅在其尚未载入内存时
        // 从磁盘补一次，避免与内存字典重复并入。检查点携带的 pendingUserInputs
        // 在此清空，防止 resume() 在引擎内循环又处理一遍导致重复。
        task.pendingUserInputs = []
        task.updatedAt = Date()
        AgentTaskStore.shared.save(task)
        if appState.pendingUserMessages[session.id] == nil
            || appState.pendingUserMessages[session.id]!.isEmpty {
            if let stored = PendingMessageStore.shared.load(for: session.id) {
                appState.pendingUserMessages[session.id] = stored
            }
        }

        Task { @MainActor in
            if let preparationTask = runtime.mcpPreparationTask {
                await preparationTask.value
                runtime.mcpPreparationTask = nil
            }

            // 等待期间用户可能已停止此回复，或运行时已被另一轮替换。
            guard appState.chatRuntimes[session.id] === runtime, runtime.isPaused else { return }
            runtime.isPaused = false
            runtime.isResponding = true
            // 任务总耗时：继续任务在暂停前的基础上继续计时。
            runtime.taskStartOrResume()
            // 恢复流式缓冲区，使新 词元 续写到同一气泡（而非另起一段）。
            if let mid = runtime.streamingMessageID,
               let msg = session.messages.first(where: { $0.id == mid }) {
                runtime.streamingContent = msg.content
            }
            await runtime.engine.resume(task)
        }
    }

    /// 进入会话时恢复未完成的回复：
    /// - 已有运行时（活跃回复中 / 已暂停）→ 直接认领，不重建；
    /// - 检查点为 `.running` / `.interrupted`（App 被杀 / 后台返回）→ 重建引擎与运行时并自动续跑；
    /// - 检查点为 `.paused` → 重建为暂停态，等用户点「继续」；
    /// - 其他（不应残留的终态）→ 清掉检查点。
    @MainActor
    private func recoverIfNeeded() {
        // 已有运行时：活跃回复或已暂停，直接复用，无需重建。
        if appState.chatRuntimes[session.id] != nil {
            AppLogger.shared.info("[Recover] 已有运行时，跳过重建（任务仍在本进程内活跃/已暂停）", category: "Agent", subsystem: "Resume")
            return
        }
        guard var task = AgentTaskStore.shared.load(sessionID: session.id) else {
            AppLogger.shared.info("[Recover] 无检查点，无需恢复", category: "Agent", subsystem: "Resume")
            return
        }
        AppLogger.shared.info("[Recover] 发现检查点 status=\(task.status.rawValue) loopIteration=\(task.loopIteration) bubbleID=\(task.assistantMessageID?.uuidString.prefix(8) ?? "nil") sessionStatus=\(session.status.rawValue)", category: "Agent", subsystem: "Resume")
        // 终态兜底（2026-08-08 修复）：若会话已是终态（任务在进程外结束/被杀时清理代码没跑），
        // 检查点必然过期——丢弃并退出，避免误判「中断续跑」重建空 runtime 遮蔽落盘数据。
        if session.status == .completed || session.status == .error {
            AppLogger.shared.info("丢弃终态会话的过期检查点：\(session.id.uuidString.prefix(8))", category: "Agent", subsystem: "Checkpoint")
            AgentTaskStore.shared.clear(sessionID: session.id)
            return
        }
        // 防御：若检查点的「续写气泡 ID」不属于本会话（后台/子代理引擎如复盘分身曾误写入本会话槽位），
        // 直接丢弃，避免把后台对话作为「用户会话草稿」重建重放成对话框气泡。
        if !taskBelongsToSession(task) {
            AppLogger.shared.warn("丢弃非本会话的检查点（疑似后台/子代理误写入）：\(session.id.uuidString.prefix(8))", category: "Agent", subsystem: "Checkpoint")
            AgentTaskStore.shared.clear(sessionID: session.id)
            return
        }
        guard let routingPlan = appState.resolveModelRoutingPlan(for: .main),
              routingPlan.endpoints.first != nil else { return }

        // 找续写的气泡：优先用检查点里记录的 ID，找不到则兜底新建。
        let bubble: ChatMessage
        if let mid = task.assistantMessageID,
           let existing = session.messages.first(where: { $0.id == mid }) {
            bubble = existing
        } else {
            bubble = ChatMessage(role: .assistant, content: "", isStreaming: true)
            bubble.session = session
            session.messages.append(bubble)
        }

        let (engine, runtime, toolRouter) = AgentRunService.shared.buildEngine(
            session: session,
            assistantMessage: bubble,
            routingPlan: routingPlan,
            deepLinkCallback: nil,
            uiHooks: AgentRunService.UIHooks(onContextUsage: { [self] snapshot in
                contextSnapshot = snapshot
            })
        )
        // 断点恢复（冷启动续跑）：计时起点不可靠，按用户规则不显示耗时。
        runtime.taskTimingInvalid = true
        // 重建完整性（2026-08-08 修复）：把已落盘的工具卡/思考段/时间线序号回填进新 runtime，
        // 否则渲染时 effectiveToolCalls 优先取 runtime 空数组 → 已完成的工具卡/思考块被遮蔽消失。
        runtime.streamingToolCalls = bubble.toolCalls
        runtime.streamingReasoningSegments = bubble.reasoningSegments
        let lastOrder = (bubble.toolCalls.map(\.timelineOrder) + bubble.reasoningSegments.map(\.timelineOrder)).max() ?? 0
        runtime.nextTimelineOrder = lastOrder + 1
        AppLogger.shared.info("[Recover] 重建 runtime: bubble.content=\(bubble.content.count)字 toolCalls=\(bubble.toolCalls.count) reasoningSegments=\(bubble.reasoningSegments.count) status=\(task.status.rawValue)", category: "Agent", subsystem: "Resume")
        // 重建时把已落盘的部分文本装回流式缓冲，恢复后续写同一气泡。
        runtime.streamingContent = bubble.content
        runtime.isResponding = (task.status != .paused)
        runtime.isPaused = (task.status == .paused)
        appState.chatRuntimes[session.id] = runtime

        switch task.status {
        case .paused:
            // 暂停态也预先恢复 MCP 工具快照；任务保存到 runtime，用户点「继续」时会等待它完成。
            let preparationTask = Task { @MainActor in
                await AgentRunService.shared.registerRemoteMCPTools(in: toolRouter, sessionID: session.id)
                let (stable, volatile) = await AgentRunService.shared.buildSystemPromptCached(with: toolRouter, sessionID: session.id)
                engine.setSystemPrompt(stable: stable, volatile: volatile)
                // 恢复采样配置：重建引擎后 sampling 是 nil（暂停→继续后 topP/seed 等丢失是缺陷）
                engine.configure(sampling: AgentRunService.shared.samplingConfig())
            }
            runtime.mcpPreparationTask = preparationTask
        case .running, .interrupted:
            // App 被杀 / 后台返回：发现并注册当前可用 MCP tools 后再自动续跑。
            task.pendingUserInputs = []
            let preparationTask = Task { @MainActor in
                await AgentRunService.shared.registerRemoteMCPTools(in: toolRouter, sessionID: session.id)
                guard !Task.isCancelled,
                      appState.chatRuntimes[session.id] === runtime else { return }
                let (stable, volatile) = await AgentRunService.shared.buildSystemPromptCached(with: toolRouter, sessionID: session.id)
                engine.setSystemPrompt(stable: stable, volatile: volatile)
                engine.configure(sampling: AgentRunService.shared.samplingConfig())
                runtime.mcpPreparationTask = nil
                await engine.resume(task)
            }
            runtime.mcpPreparationTask = preparationTask
        default:
            // completed / failed / cancelled 等终态不应残留检查点，清掉。
            AgentTaskStore.shared.clear(sessionID: session.id)
        }
    }

    /// 判断 `AgentTaskStore` 取出的检查点是否真的属于本会话（而非后台/子代理引擎误写入）。
    /// 依据：合法的用户聊天检查点在写入时，`assistantMessageID` 指向的续写气泡一定已落盘到 `session.messages`；
    /// 而后台引擎（如复盘分身）配置的是全新 UUID（或 nil），其气泡不在本会话，据此判定为外来并丢弃。
    private func taskBelongsToSession(_ task: AgentTask) -> Bool {
        guard let mid = task.assistantMessageID else {
            // 无续写气泡 ID：仅当本会话本就空（不可能有已落盘气泡）时才视为可疑——空会话不误伤，放行交由后续逻辑。
            return true
        }
        return session.messages.contains { $0.id == mid }
    }

    // MARK: - 排队消息处理

    /// 当前回复完成后调用：取队首（最早排队）的消息，落盘为真实用户消息并启动新一轮回复。
    /// 其余排队消息保留为虚线气泡，待本轮完成后继续处理，形成 FIFO 链式处理。
    private func processNextPendingMessage() {
        // 必须确保当前空闲（无活跃运行时），避免与仍在收尾的回复冲突
        guard appState.chatRuntimes[session.id] == nil else { return }
        guard appState.hasConfiguredModel else { return }
        guard var queue = appState.pendingUserMessages[session.id], !queue.isEmpty else { return }

        let next = queue.removeFirst()
        appState.pendingUserMessages[session.id] = queue.isEmpty ? nil : queue
        persistQueue()

        let userMessage = ChatMessage(role: .user, content: next.text)
        userMessage.session = session
        userMessage.attachments = next.attachments
        session.messages.append(userMessage)
        session.updatedAt = Date()

        startAgentResponse(to: next.text, userMessageID: userMessage.id, injectedSkill: next.skillName, attachments: next.attachments, thinkingLevel: session.thinkingLevel, deepLinkCallback: next.deepLinkCallback)
    }

    /// 删除某条排队中的消息（点击虚线气泡右侧删除按钮）
    private func deletePendingMessage(_ id: UUID) {
        guard var queue = appState.pendingUserMessages[session.id] else { return }
        queue.removeAll { $0.id == id }
        appState.pendingUserMessages[session.id] = queue.isEmpty ? nil : queue
        persistQueue()
    }

    /// 点击某条排队消息左侧的发送按钮：硬停止当前生成（清检查点），
    /// 再把这条排队消息提升为真实用户消息并启动新一轮回复（即「停止并处理这条消息」）。
    /// 其余排队消息保留在运行时队列，待本轮完成后由 processNextPendingMessage 继续 FIFO 处理。
    private func sendQueuedMessage(_ id: UUID) {
        // 1. 停止当前生成（回复中或已暂停都先硬停止）
        let hadRuntime = appState.chatRuntimes[session.id] != nil
        if hadRuntime {
            stopGeneration()
        }
        // 2. 从运行时队列取出这条消息
        guard var queue = appState.pendingUserMessages[session.id],
              let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: idx)
        appState.pendingUserMessages[session.id] = queue.isEmpty ? nil : queue
        persistQueue()

        // 3. 若此前这条消息已落入磁盘 pendingUserInputs（暂停态写入），
        //    硬停止 cancel() 已清掉整个检查点，无需额外清理，避免 resume 重复并入。

        // 4. 落盘为真实用户消息并启动新回复（附件一并保留，此前遗漏导致排队插队发送丢附件）
        let userMessage = ChatMessage(role: .user, content: item.text)
        userMessage.session = session
        userMessage.attachments = item.attachments
        session.messages.append(userMessage)
        session.updatedAt = Date()
        startAgentResponse(to: item.text, userMessageID: userMessage.id, injectedSkill: item.skillName, attachments: item.attachments, thinkingLevel: session.thinkingLevel, deepLinkCallback: item.deepLinkCallback)
    }
}

// MARK: - 排队消息虚线气泡

/// 排队中的用户消息气泡：右对齐、虚线边框，右侧带删除按钮，持续展示直到被处理或删除。
struct PendingMessageBubble: View {
    let text: String
    var onSend: () -> Void
    var onDelete: () -> Void

    private let accent = Color(red: 0.098, green: 0.549, blue: 0.996)

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            // 左：发送按钮（停止当前生成并立即处理这条）；中：虚线气泡；右：删除按钮。
            // 三者同层、垂直居中对齐；删除按钮只相对气泡居中，不随下方「排队中」文字下移。
            HStack(alignment: .center, spacing: 8) {
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Text(text)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                accent.opacity(0.75),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                            )
                    )

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9))
                Text(L10n.tr("排队中 · 点左侧按钮可停止并立即发送"))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - 块级段缓存（2026-08-09 崩溃修复）

/// 穿插段纯性能缓存：引用类型，@State 持有它时内部写入不会触发 SwiftUI 更新，
/// 也不会被视为「视图更新期间修改 State」（iOS 18 该行为是断言崩溃，非警告）。

// MARK: - 未接入模型提示横幅（2026-08-09 抽为独立视图，供消息列表 banner cell 使用）

struct ModelWarningBannerView: View {
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text(L10n.tr("尚未接入模型"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            Text(L10n.tr("需要先接入模型才能完成对话。请前往「智能体服务商」添加服务商并填写 API Key。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onConfigure) {
                HStack(spacing: 6) {
                    Text(L10n.tr("前往配置模型"))
                        .fontWeight(.medium)
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
