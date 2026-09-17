import Foundation
import SwiftUI
import MiniClawKit
import UIKit
import QuickLook
import AVKit

/// 全屏图片查看的标识项：用 `.fullScreenCover(item:)` 的规范写法承载，
/// 避免「计算 Binding + 内容内再读同一可选值」导致的偶尔不弹出的 SwiftUI 隐患。

struct ChatView: View {
    @EnvironmentObject private var appState: AppState

    @ObservedObject var session: ChatSession
    /// 子代理仓库的订阅：头像条读的是它的 `cards`，必须建立观察关系，
    /// 否则 `startSubagent` 发出的 objectWillChange 无人接收，头像要等下一次
    /// 无关状态变化触发重绘才出现（表现为「唤起子代理后没有第一时间显示」）。
    @ObservedObject private var subagentStore = SubagentStore.shared

    @State private var inputText: String = ""
    /// 外部向输入框注入文本的通道（斜杠命令插入/清空/草稿恢复）：
    /// 输入框文本已本地化到 ChatInputBar，外部写入必须经此通道 + injectionID 触发应用。
    @State private var inputInjectionID = 0
    @State private var injectedInputText = ""
    @State private var pendingAttachments: [InputAttachment] = []
    /// 附件被模型输入模态过滤后的提示文案（短暂展示于输入栏上方，几秒后自动消失）。
    @State private var attachmentNotice: String?
    @State private var browserURL: URL? = nil
    /// 2026-08-12:统一全屏预览(文件管理器同款 FilePreviewView)目标文件。
    @State private var previewFileURL: URL? = nil
    @State private var showFileManager: Bool = false
    @State private var showSessionTerminal: Bool = false
    @State private var showSessionBrowser: Bool = false
    @State private var showTokenUsage: Bool = false
    @State private var showSoulSettings: Bool = false
    @State private var showModelManagement: Bool = false
    /// 「添加密钥」指示器 → 智能体服务商页面(ProviderSettingsView,2026-08-11)。
    @State private var showProviderSettings: Bool = false
    /// 上下文占用快照的本地镜像（数据源是 `ContextUsageStore`，引擎写、UI 读）。
    /// 进入会话时先做一次本地估算兜底，随后由引擎的真值/校准估算持续刷新。
    // [2026-09-11 删除] 原 `@State private var contextSnapshot: ContextUsageSnapshot = .empty`：
    // 该状态在 ChatView 内**只被写、从不被读**（唯一读取点 `contextUsageCaption` 已随圆环入口
    // 移除），却在 `syncContextSnapshot()` 里于**进入后 ~1.2s** 才被赋值 → 每次赋值都让 body
    // 重算 → toolbar 整体重建 → 系统播放 bar button 更新动画 = 真机实测的「选项图标慢慢淡入」。
    // 用量数据仍由全局 `ContextUsageStore` 承载（syncContextSnapshot 继续写它），用量页照常读取。
    // 子代理（general-purpose-2）穷尽排查确认：菜单内容与标题依赖均非元凶，唯此延迟状态写入是。
    @State private var activeSubagentConversation: SubagentConversation? = nil
    /// 长按胶囊待确认关闭的子代理（弹二次确认框；确认才走 SubagentLifecycle.close）。
    @State private var pendingRemoveSubagent: SubagentCard? = nil
    @State private var lastMessageID: UUID?
    /// 上一个 isResponding 值(iOS16 onChange 单参版本的翻转检测缓存)。
    @State private var lastResponding: Bool = false
    /// 是否允许自动跟随最新内容。默认开启；用户只要手动拖动会话列表就立即关闭，
    /// 后续 词元 / 工具事件不再抢回滚动控制，直到用户主动发送消息或重新进入会话。
    @State private var shouldAutoFollow: Bool = true
    @FocusState private var isInputFocused: Bool
    /// 悬浮层总高度(2026-08-11 重写):onGeometryChange 测整个 chatOverlay 真实内容高度
    /// (排队消息 + 子代理头像 + 附件提示 + 输入栏),不含键盘。键盘展开/收起不改该值,
    /// 故消息距输入栏距离在无键盘态与有键盘态恒定(= 列表 contentInset.bottom - 8)。
    /// [F3(b) 2026-09-12] 初值**不取 0**：0 → 实测值 的跳变会让底部留白在进入会话时变一次
    /// （真机实证 `contentInset.bottom` 8 → 69），内容因此整体位移一次；即便顶部留白已锚定，
    /// 底部这一次跳变仍会造成「进入后第一次上滑整屏弹」。改为**持久化上一次实测值**作为初值，
    /// 使进入时即为稳定值（首装/清数据后第一次仍会学习一次，属可接受的一次性成本）。
    @State private var inputBarHeight: CGFloat = ChatView.persistedBarHeight(forKey: "chat.inputBarHeight")
    @State private var inputBarHeightDebounce: Task<Void, Never>?
    /// 悬浮内容条(排队/子代理/附件)高度,照 floatingBarHeight 语义:
    /// 列表 bottomInset = inputBarHeight + floatingBarHeight + 8。
    @State private var floatingBarHeight: CGFloat = ChatView.persistedBarHeight(forKey: "chat.floatingBarHeight")

    /// [F3(b) 2026-09-12] 读取上一次实测栏高作为初值（无记录/异常值返回 0）。
    static func persistedBarHeight(forKey key: String) -> CGFloat {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 1 ? CGFloat(v) : 0
    }

    /// 记录实测栏高（仅记非 0：0 是「该栏当前不显示」的合法状态，不应成为下次的初值）。
    static func persistBarHeight(_ h: CGFloat, forKey key: String) {
        guard h > 1 else { return }
        UserDefaults.standard.set(Double(h), forKey: key)
    }
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
            guard let label = ChatCommandParser.thinkingLevelLabels[id] else { return nil }
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
        // 1. 草稿回填：先清空再回填。会话切换若复用本视图实例，上一会话的残留文本
        //    会经 onChange → persistDraft 落盘，把 A 的草稿污染成 B 的草稿。
        injectInput("")
        if let draft = PendingMessageStore.shared.loadDraft(for: session.id) {
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
                // 2026-08-12 修复：清空前必须像 stopGeneration 一样终止在途引擎并写终态，
                // 否则旧引擎回调因 runtime 被丢弃而 guard 跳过，status 卡 .running → 首页图标转圈。
                if let runtime = appState.chatRuntimes[session.id] {
                    runtime.engine.cancel()
                    runtime.streamingMessageID = nil
                }
                appState.chatRuntimes[session.id] = nil
                // 清空会话时同步清除 /compact 预约：否则残留标志会让清空后的首轮对话
                // 误触发一次强制压缩尝试（2026-09-08）。
                appState.pendingManualCompact.remove(session.id)
                SessionManager.shared.removeAllMessages(from: session)
                AgentTaskStore.shared.clear(sessionID: session.id)
                session.status = .completed
                session.updatedAt = Date()
                SessionManager.shared.persist(session)

            case "compact":
                // 手动触发对话压缩（预约标志，下次 run 的前置压缩阶段强制执行）。
                // 2026-09-08 修复：标志原挂在 runtime 上，而 runtime 仅在回复进行期间
                // 存在——空闲会话 /compact 曾静默无效。改写会话级 AppState 预约，
                // 空闲也生效（下次对话开始前压缩），并插入指示器给出可见反馈。
                appState.pendingManualCompact.insert(session.id)
                let indicator = ChatMessage(role: .system, content: String(localized: "compact_scheduled_indicator"))
                indicator.session = session
                session.messages.append(indicator)
                session.updatedAt = Date()
                SessionManager.shared.persist(session)

            default:
                break
            }
        case .toggle:
            // 记忆开关切换（/memory）。2026-09-08 修复：命令携带的是占位 .toggle(false)
            //（菜单/直发两条路径都不携带真实状态），按它取反会恒置为开启——
            // 改为直接读当前真实设置取反，菜单点击与直发两条路径均正确。
            var memorySettings = SettingsStore.shared.settings.memory
            memorySettings.isEnabled = !memorySettings.isEnabled
            SettingsStore.shared.set(memorySettings, domain: .memory, summary: String(localized: "slash_command_toggled"))

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
            SessionManager.shared.persist(session)

        default:
            // 插入文本类命令（/search、/image 等）→ 回填到输入框
            if case .insertText(let prefix) = cmd.kind {
                injectInput(prefix)
            }
        }
    }

    /// 向输入框注入文本（输入文本已本地化，外部写入统一走此通道）。
    private func injectInput(_ text: String) {
        // 运行时打点(2026-08-13):注入通道入口。
        injectedInputText = text
        inputInjectionID += 1
        inputText = text // 镜像同步（草稿落盘/其他读取仍用 inputText）
    }

    private func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 内置斜杠命令（clear/compact/memory/thinking 等，非技能）：直接执行对应动作，
        // 不发给模型，避免把命令本身当成用户消息导致 智能体乱回。
        if let cmd = ChatCommandParser.builtinCommand(matching: trimmed) {
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
        let parsedSkill = ChatCommandParser.parseSkillCommand(trimmed)
        let skillName = parsedSkill?.skill
        let taskText = parsedSkill?.task
        let injectedSkill: String? = skillName
        let workingText: String
        if let skillName {
            SkillManager.shared.incrementUseCount(skillName)
            workingText = (taskText?.isEmpty == false) ? taskText! : String(format: String(localized: "please_complete_the_task_directly_using_the_skill"), skillName)
        } else {
            // 非技能（普通文本或 /search 等插入文本命令）：原样发送。
            workingText = trimmed
        }
        let raw = workingText
        // 用户主动发送 → 视为想回到最新位置，重新钉住底部（后续的 onChange 才会滚动到底）。
        shouldAutoFollow = true

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

        // 用户发送消息即落盘(2026-08-12 回归修复)：立即持久化会话行+用户消息。
        // createSession 只落盘了空会话,用户消息若不立即 persist,则 AI 运行中返回首页/
        // 杀进程时该会话在 SQLite 中仍是空壳甚至缺失——会话从列表消失的根因之一。
        let userMessage = ChatMessage(role: .user, content: raw)
        userMessage.session = session
        // 用户附件复制进当前会话的 attachments/ 目录（会话独享、随会话删除），
        // 仅存会话相对路径「attachments/<name>」，显示时按活动 Documents 路径解析，避免绝对路径失效。
        userMessage.attachments = persistAttachmentsToSession(pendingAttachments)
        session.messages.append(userMessage)
        session.updatedAt = Date()
        SessionManager.shared.persist(session)

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

    // MARK: - 长按菜单动作（2026-08-12 治本：Edit/Retry/Re-run 接线）

    /// 长按菜单「编辑」：回填输入框并聚焦。
    @MainActor
    private func editMessage(_ messageID: UUID) {
        guard let msg = session.messages.first(where: { $0.id == messageID }), msg.role == .user else { return }
        inputText = msg.content
        isInputFocused = true
    }

    /// 长按菜单「重试」：截断到该用户消息（删除其后 AI 回复），重新执行 Agent。
    @MainActor
    private func retryMessage(_ messageID: UUID) {
        guard let idx = session.messages.firstIndex(where: { $0.id == messageID }),
              session.messages[idx].role == .user else { return }
        // 该消息正在回复中则不重试（避免并发跑两轮）。
        guard appState.chatRuntimes[session.id] == nil else { return }
        let userMessage = session.messages[idx]
        session.messages = Array(session.messages.prefix(idx + 1))
        SessionManager.shared.persist(session)
        startAgentResponse(to: userMessage.content, userMessageID: userMessage.id,
                           attachments: userMessage.attachments, thinkingLevel: session.thinkingLevel)
    }

    /// 长按菜单「折叠上方」：压缩该消息之上的上下文。
    /// 会话可见结构不变（仅插入一条指示器 system 消息），API 上下文用摘要替代
    /// （buildHistory 应用 compactAnchorID/compactSummary）。
    @MainActor
    private func compactAbove(_ messageID: UUID) {
        guard let idx = session.messages.firstIndex(where: { $0.id == messageID }), idx > 0 else { return }
        guard appState.chatRuntimes[session.id] == nil else { return }
        let indicator = ChatMessage(role: .system, content: String(localized: "compact_above_indicator"))
        session.messages.insert(indicator, at: idx)
        session.updatedAt = Date()
        SessionManager.shared.persist(session)
        Task { @MainActor in
            if let summary = await AgentRunService.shared.generateCompactionSummary(session: session, anchorMessageID: messageID) {
                session.compactAnchorID = messageID
                session.compactSummary = summary
                SessionManager.shared.persist(session)
            } else {
                // 摘要失败：移除指示器并回滚锚点。
                session.messages.removeAll { $0.id == indicator.id }
                session.compactAnchorID = nil
                session.compactSummary = nil
                SessionManager.shared.persist(session)
            }
        }
    }

    /// 长按工具块「从这里重跑」：定位包含该工具调用的 AI 消息，截断后重跑其前的用户消息。
    @MainActor
    private func rerunFromToolBlock(_ blockId: UUID) {
        if let aiIdx = session.messages.firstIndex(where: { msg in
            msg.role == .assistant && msg.toolCalls.contains(where: { $0.id == blockId })
        }) {
            let userIdx = aiIdx - 1
            if userIdx >= 0, session.messages[userIdx].role == .user {
                retryMessage(session.messages[userIdx].id)
                return
            }
        }
        // 兜底：重发最后一条用户消息。
        if let lastUser = session.messages.last(where: { $0.role == .user }) {
            retryMessage(lastUser.id)
        }
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

        // 用户发送消息即落盘(2026-08-12 回归修复)：快捷指令「继续会话」路径与人工发送一致,
        // 立即持久化,避免运行中会话在存储中缺失。
        let userMessage = ChatMessage(role: .user, content: prompt)
        userMessage.session = session
        session.messages.append(userMessage)
        session.updatedAt = Date()
        SessionManager.shared.persist(session)

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
    ///   这样 hint 注入的名字、磁盘落盘的名字、工具（apple-vision / apple-image / read_document）
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
    /// [T-perf 2026-09-08] MCP 工具发现预热：进入会话即后台预热工具列表缓存，
    /// 避免首次发送时等待 1-2s 的网络发现（stale-while-revalidate 之外的补充）。
    /// 独立于 syncContextSnapshot（其有快照命中早退路径，会把预热一起跳过）。
    private func warmupMCPDiscovery() {
        let servers = MCPConfigStore.shared.servers.filter { $0.isEnabled }
        guard !servers.isEmpty else { return }
        var tokens: [UUID: String] = [:]
        for server in servers {
            if let token = MCPConfigStore.shared.effectiveBearerToken(for: server.id) {
                tokens[server.id] = token
            }
        }
        Task.detached(priority: .utility) {
            for server in servers {
                _ = try? await MCPToolDiscoveryCache.shared.definitions(
                    for: server,
                    bearerToken: tokens[server.id]
                )
            }
        }
    }

    private func syncContextSnapshot(force: Bool = false) {
        // [2026-09-11] 本函数只负责把用量**写入全局 `ContextUsageStore`**（用量页读取），
        // 不再写 ChatView 本地状态（见 contextSnapshot 删除说明）——进入后 1.2s 的估算落地
        // 时不再触发 body 重算，工具栏因此不会重建/淡入。
        if !force, ContextUsageStore.shared.snapshot(for: session.id) != nil {
            return
        }
        Task { @MainActor in
            // [T-perf-session-open 2026-09-08] 延迟到进入转场与首帧稳定之后再估算：
            // 圆环晚 ~1.2s 出现用户无感，但避免与转场/首屏渲染争抢主线程
            //（此前 PROMPT BUILD + buildHistory 在点击后立即执行，卡住进入 ~1s）。
            // 发消息路径不受影响（startRun 自行构建 prompt 与精确用量）。
            // MCP 预热已拆至 warmupMCPDiscovery()（随会话进入触发，不依赖本函数）。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            guard let endpoint = appState.resolveModelRoutingPlan()?.endpoints.first else { return }
            let router = AgentRunService.shared.buildToolRouter(sessionID: session.id)
            let (stable, volatile) = await AgentRunService.shared.buildSystemPrompt(with: router, sessionID: session.id)
            var messages: [ChatCompletionMessage] = []
            var systemMessage = ChatCompletionMessage(role: "system", content: stable)
            systemMessage.volatileSuffix = volatile
            messages.append(systemMessage)
            messages.append(contentsOf: AgentRunService.shared.buildHistory(session: session, userMessageID: UUID(), responseMessageID: UUID()).messages)
            let schemas = router.allSchemas()
            // [T-perf-session-open 2026-09-08] token 估算是对**全部历史消息**的逐字符
            // 扫描（CJK per-char 成本更高）——20 条回复的会话可达数百 ms，此前与
            // prompt 构建一起压在 @MainActor Task 里，卡住进入会话的转场（点击后
            // ~1s 才可见）。估算为纯函数：挪后台执行，主线程只收结果更新圆环。
            let detachedMessages = messages
            let detachedSchemas = schemas
            let breakdown = await Task.detached(priority: .userInitiated) {
                ContextUsageEstimator.breakdown(
                    messages: detachedMessages,
                    tools: detachedSchemas.isEmpty ? nil : detachedSchemas
                )
            }.value
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
        // [2026-09-11 实验记录] topBarLeading 走不通：UIKit 会把该位置的 item 当**按钮**
        // 渲染——iOS 27 液态玻璃给它加胶囊底，且按图标体量预期尺寸 → 标题溢出玻璃底外
        //（真机实测「背景没框住标题」）。导航栏两侧只接受图标体量内容，标题仍回 principal。
        ToolbarItem(placement: .principal) {
            sessionHeaderToolbar
                // [2026-09-11 双保险] 内容更新不播过渡动画：抑制 bar button 的
                // 「更新动画」（首次进入时的反复淡入即由此累积而成）。详见 onAppear 说明。
                .transaction { $0.animation = nil }
        }
        // [2026-09-11 唐唐拍板] 右上角**完全照首页同款做法**（HomeView.swift:205）：
        // 单个系统 ToolbarItem(.topBarTrailing) + Menu，label 仅放 `Image(systemName:)`，
        // 无自绘底 / 无 frame / 无 fixedSize / 无 sharedBackgroundVisibility——
        // 玻璃底、尺寸、位置全交系统原生渲染（首页一直如此且从未错位/变色）。
        // 原自绘「上下文用量环」不再常驻显示，入口并入菜单（首项显示当前用量）。
        ToolbarItem(placement: .topBarTrailing) {
            sessionOptionsMenu
                // [2026-09-11 双保险] 同 principal：更新静默生效，不播 bar button 更新动画。
                .transaction { $0.animation = nil }
        }
    }

    /// 会话页右上角选项菜单（外观与首页 optionsMenu 同款，内容为会话专属项）。
    ///
    /// [2026-09-11] 菜单内容**保持完全不依赖动态状态**（治本第二步）。
    /// 第一步曾把首项从「上下文占用 42%」（读 `contextSnapshot`）改成静态文案，但淡入依旧——
    /// 子代理穷尽排查后确认：真正的重建源是 `contextSnapshot` 这个**延迟 1.2s 写入的本地状态**
    /// 本身，它让 ChatView body 在进入后重算 → toolbar 重建 → 系统播放 bar button 更新动画。
    /// 该状态已整个删除（只写不读），故现在 body 不再被延迟重算，菜单也就不会重建。
    /// 首页 optionsMenu 因纯静态 + 无同类延迟写入，从无此现象——这是二者的真正差别。
    private var sessionOptionsMenu: some View {
        Menu {
            Button {
                showTokenUsage = true
            } label: {
                Label(String(localized: "context_usage"), systemImage: "gauge.with.needle")
            }
            Divider()
            Button {
                showFileManager = true
            } label: {
                Label(String(localized: "file_management_for_the_current_session"), systemImage: "folder")
            }
            Button {
                showSessionTerminal = true
            } label: {
                Label(String(localized: "terminal"), systemImage: "terminal")
            }
            Button {
                showSessionBrowser = true
            } label: {
                Label(String(localized: "browser"), systemImage: "safari")
            }

            // 后续选项在此追加
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    /// 会话页标题区：会话标题（点按进灵魂设置）+ 模型名（点按进模型管理），居中显示。
    private var sessionHeaderToolbar: some View {
        VStack(spacing: 1) {
            Text(headerTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .onTapGesture { showSoulSettings = true }
            Text(headerModelName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .onTapGesture { showModelManagement = true }
        }
        // [2026-09-12 唐唐拍板改回居中] 去掉 09-11 的「定宽 260pt + leading」——那套的
        // 目的是让标题靠左以避开超宽挪位，但视觉上标题就不在中间了。
        // 现恢复原样：**不加任何宽度约束**，交给系统把 principal 居中
        //（09-11 记录过：柔性 .frame(maxWidth:) 会被 UIKit titleView 撑满可用区导致左锚定，
        //  所以这里既不加定宽也不加柔性宽度）。标题字符数同步回到原样，见 headerTitle。
        // 已知代价（09-11 记录的原始现象）：正式标题超过约 9 个字时 UIKit 会把 principal 挪偏左。
    }

    /// 标题区展示的标题：AI 尚未改名前（titleIsPlaceholder，即占位标题）显示首条用户消息
    /// 前 8 个字（超出部分用单字符省略号截断）；AI 自动改标题 / 用户手动改名后**完整显示**会话标题。
    private var headerTitle: String {
        // 显示标题：默认占位标题（"新会话"）走 i18n（存量数据为中文默认值，显示层兜底本地化）。
        func localizedDefault(_ title: String) -> String {
            title == "NewChat" ? String(localized: "new_chat_title") : title
        }
        if session.titleIsPlaceholder {
            guard let first = session.messages.first(where: { $0.role == .user })?.content else {
                return localizedDefault(session.title)
            }
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            // [2026-09-12 唐唐拍板改回] 只对**占位标题**截断：正文取原样，超过 8 字才补省略号。
            // 09-11 曾把「占位标题」与「正式标题」两分支统一收口到 8 字，副作用是
            // AI 自动命名 / 用户手动改名的正式标题也被砍到 8 字——本条撤销该副作用，
            // 正式标题回到完整显示（与更早的实现一致）。
            let prefix = String(trimmed.prefix(8))
            return trimmed.count > 8 ? prefix + "…" : prefix
        }
        return localizedDefault(session.title)
    }

    /// 标题区当前应展示的模型名：正在流式回复时显示本消息实际所用模型，否则显示实时配置。
    private var headerModelName: String {
        if session.status == .running && !session.modelName.isEmpty {
            return session.modelName
        }
        return appState.currentModelDisplayName
    }

    // [2026-09-11 删除] 旧的 sessionMenuLabel（自绘 27pt 圆底 + 44 盒）已废弃：
    // 右上角改为完全照首页做法（sessionOptionsMenu，label 仅 `Image(systemName:)`，
    // 系统原生渲染），自绘底不再需要。

    /// 输入栏悬浮层(2026-08-11 拆分 body 避免类型推断超时)。
    /// 悬浮内容条(排队消息 + 子代理头像 + 附件提示):照 floatingToolPreview
    /// 语义,独立于输入栏测高(列表 bottomInset = inputBarHeight + floatingBarHeight + 8)。
    @ViewBuilder
    private var floatingContent: some View {
        // 显式 VStack 容器（2026-09-06 悬浮条遮挡修复）：
        // 修饰符挂在 @ViewBuilder 的 Group 上会**逐子视图**应用——
        // onGeometryChange 测到的是单个子视图（最后上报者）的高度，
        // 而非排队框 + 胶囊条的总高 → 列表底部预留缺了排队框那截，
        // 流式页脚（回复中）被排队框压在半透明材质后面。
        // 包一层 VStack 后测高量到总高，随任一子条出现/消失正确增减。
        // 注意：spacing 必须为 0——子条自带 bottom padding，保持既有间距。
        VStack(spacing: 0) {
            // 「回到底部」按钮已按用户要求从源码剔除(2026-08-10)。

            // 添加密钥引导:用户未配置任何服务商密钥时显示在输入框上方(2026-08-11 用户需求)。
            // 点击 → 打开服务商页面 + 申请网络/本地网络权限(照设置页先例,拒绝不闪退)。
            // 已配置任意服务商(apiKey/OAuth/Keychain)后自动消失。
            if !appState.hasAnyConfiguredProvider {
                addKeyBanner
            }

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
            let subs = subagentStore.avatars(for: session.id)
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
    }

    @ViewBuilder
    private var chatOverlay: some View {
        VStack(spacing: 0) {
            // 悬浮内容条(排队/子代理/附件):照 floatingToolPreview 独立测高。
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
                injection: ChatInputInjection(id: inputInjectionID, text: injectedInputText),
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
            // zIndex：斜杠菜单覆盖层从输入栏向上溢出（覆盖消息与浮动条），
            // 重叠区兄弟绘制顺序未定义 → 显式抬高输入栏层级，保证菜单压住头像条。
            .zIndex(1)
            // 照 inputBar 测高:seed 首帧同步 + 380ms debounce + 320ms settle-confirm。
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
                // [KbdDiag 2026-08-11] 输入栏测高全链路日志(照 InputBarLayout):
                // 每次上报打 frame.height + onscreen,seed/commit 时打结果。
                if newH != lastLoggedInputBarH {
                    lastLoggedInputBarH = newH
                }
                if !didSeedInputBarHeight, onscreen {
                    didSeedInputBarHeight = true
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
            // 背景主题挂载点：Kit 消息列表已透明（host.view.backgroundColor = .clear），
            // 主题图从这里透出；无主题时组件回退系统背景（视觉与现状一致）。
            ThemeBackground(slot: .chat)
            messageListView
        }
        // 输入栏以 .overlay(alignment:.bottom) 悬浮,受 safe area 约束,
        // 键盘展开/收起由系统自动键盘规避统一抬升——消息距输入栏距离恒定。
        .overlay(alignment: .bottom) {
            chatOverlay
        }
        // 键盘高度监听已移至列表 Coordinator(keyboardHeight),此处不再手动桥接。
        .onChange(of: appState.pendingBrowserURL) { url in
            if let url { browserURL = url; appState.pendingBrowserURL = nil }
        }
        // 内置浏览器打开策略:Kit 发来的 http/https 链接请求 → 复用同一个浏览器 sheet
        .onReceive(NotificationCenter.default.publisher(for: .miniClawOpenURLRequested)) { note in
            if let url = note.object as? URL,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                browserURL = url
            } else {
            }
        }
        .sheet(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 {
                browserURL = nil
            } }
        )) {
            if let url = browserURL {
                BrowserView(startURL: url)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showFileManager) {
            SessionFileManagerView(sessionID: session.id)
        }
        // 2026-08-12:统一全屏预览(文件管理器同款 FilePreviewView)——AI 图片/文件链接/
        // 用户附件点击统一全屏呈现,右上角分享/关闭按钮,图片/视频黑 80% 透明背景。
        .fullScreenCover(isPresented: Binding(
            get: { previewFileURL != nil },
            set: { if !$0 { previewFileURL = nil } }
        )) {
            if let url = previewFileURL {
                FilePreviewView(fileURL: url)
            }
        }
        .sheet(isPresented: $showTokenUsage) {
            SessionTokenUsageView(session: session)
        }
        .sheet(item: $activeSubagentConversation) { conv in
            SubagentChatView(conversation: conv, sessionID: session.id)
                .presentationDragIndicator(.visible)
                // sheet 默认带抬升材质（深色下偏灰、不透黑），与主会话纯黑背景不一致；
                // 显式指定背景 = 系统背景（深色模式即纯黑）。
                // iOS16 兼容(2026-08-12):presentationBackground 是 iOS16.4 API,
                // 用等价的 UIKit 背景(系统背景色铺满)替代,视觉一致。
                .background(Color(.systemBackground))
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
        .sheet(isPresented: $showProviderSettings) {
            // 2026-08-11:与设置页「智能体服务商」完全一致的界面(ProviderSettingsView),
            // 全屏高度呈现;系统下滑手势关闭(不画蛇添足加关闭按钮)。
            NavigationStack {
                ProviderSettingsView()
                    .navigationTitle(String(localized: "providers"))
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showSessionTerminal) {
            #if ISH_ENABLED
            TerminalView(initialSessionID: session.id, initialSessionTitle: session.title)
            #else
            UnavailablePlaceholder(title: String(localized: "terminal_unavailable"), message: String(localized: "the_current_build_does_not_include_the_ish_runtime"))
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
        // 标题区：系统导航栏 principal 居中显示（会话标题 + 模型名）。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar {
            chatToolbarItems
        }
        // [2026-09-14 顶部磨砂·失败记录] 这里曾用
        //   `.toolbarBackground(.bar, for: .navigationBar)` + `.toolbarBackground(.visible, …)`
        // 给栏硬贴一层材质。**错的**：那会变成一块**常显的灰**，与首页"直接映射背景色"的行为
        // 完全不同 —— 首页是 SwiftUI `List`，由**系统**在"内容滑到栏下"时才换上材质，
        // 静止时栏是透明、直接映射背景（所以是纯黑/纯白）。
        // ⇒ 正确做法见 `messageListView` 与 `MessageListViewController.registerCollectionViewForNavBarScrollEdge`：
        //   让列表穿过顶栏 + 把列表注册给导航栏，背景切换由系统完成，本页**不自绘任何东西**。
        .onAppear {
            // [2026-09-11 「重复淡入」修复] 下面这一串状态更新会让 ChatView body 连续重算
            //（真机探针实测：首次进入 body 重算 7 次、菜单构建 7 次）→ toolbar 随之重建
            // → 系统对 bar button 播放「更新动画」；因集中发生在进入转场前后，视觉上就是
            // 「选项图标反复淡入」。
            // 对照实验（同批探针）：首页菜单同样被重建 12 次却**毫无可见动画**——
            // 说明重建本身不是病因，"更新发生在转场语境下"才是。故此处用「禁动画事务」
            // 把这批更新包住：状态照常生效，但不产生任何过渡动画。
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                lastMessageID = session.messages.last?.id
                // 2026-08-12:浏览器 UI 标签池绑定到当前会话(与工具链同一池,指示器/工具/浏览器标签同步)
                // [2026-09-15 体系统一] 原先这里还调 BrowserController.setSession（旧上下文体系），
                // 与适配器是两套状态；旧体系已删，只保留适配器这一条。
                BrowserEngineAdapter.shared.setSession(session.id)
                // 2026-08-12 修复:播种 lastResponding——若进入时 agent 已在回复中,
                // 完成翻转 true→false 才不会被漏检(否则排队消息不自动续跑)。
                lastResponding = isResponding
                restorePersistedState()
                recoverIfNeeded()
                syncContextSnapshot()
                warmupMCPDiscovery()
                consumePendingDeepLinkTask()
            }
            // 调试日志（2026-08-08）：重进会话后的回复状态全链路追踪。
            let lastAssistant = session.messages.last(where: { $0.role == .assistant })
        }
        .onChange(of: appState.pendingDeepLinkTask?.id) { _ in
            consumePendingDeepLinkTask()
        }
        // 2026-08-12 治本:长按菜单「添加到输入框」与「从这里重跑」——
        // Kit 发通知但此前无监听(空桩)。独立 modifier 承载,避免主 body
        // type-check 超时(2026-08-12 编译错误)。
        .modifier(ChatMenuListeners(
            onAppend: { text in
                // 2026-08-13 治本:输入框文本已本地化到 ChatInputBar,必须走
                // injectInput 注入通道(推进 injectionID),否则只改本地 state,
                // ChatInputBar 收不到 → 点击无反应。
                injectInput(inputText + text)
                isInputFocused = true
            },
            onRerun: { blockId in
                rerunFromToolBlock(blockId)
            }
        ))
        // 2026-08-12 治本:附件卡片点击打开——Kit 的 UserAttachmentList 点击发
        // .miniClawOpenURLRequested 通知,此前宿主无监听 → 点击无反应。此处解析
        // miniclaw:// URL 到会话目录实际文件,用分享面板打开(图片/音视频/文档通用)。
        .onReceive(NotificationCenter.default.publisher(for: .miniClawOpenURLRequested)) { note in
            guard let url = note.object as? URL else { return }
            // 2026-08-12:兼容两种来源——miniclaw:// 语义链接(解析到会话目录)与
            // 本地文件 URL(视频/音频卡片点击直接传 fileURL)。
            let fileURL: URL?
            if url.isFileURL {
                fileURL = url
            } else if url.scheme?.lowercased() == "miniclaw",
                      // [2026-09-12 文件打不开·真因] 必须走**统一解析器**
                      // `FileSystemManager.resolveMiniClawResourceURL`：它的 host 表覆盖
                      // `shared/workspace/mounts/attachments/browser/offloads/memory/rules/skills`。
                      // 此前用的 `MiniClawHostStubs.resolveMiniClawURL(url)` 只覆盖
                      // 「会话目录 + skills/memory」两类，**`shared` 直接返回 nil**
                      // ⇒ 真机 `miniclaw://shared/今日科技新闻-20260912.md` 被吞掉、
                      // 统一预览的 `guard fileExists` 直接 return（点击毫无反应）。
                      let unified = FileSystemManager.shared.resolveMiniClawResourceURL(
                          url.absoluteString, sessionID: session.id) {
                fileURL = unified
            } else if let resolved = MessageListModel.resolveMiniClawURL(url) {
                fileURL = resolved
            } else {
                // 兜底：AI 偶尔输出**裸路径**（相对名/裸绝对路径，`canonicalFileURL` 是空实现），
                // 既非 file:// 也非 miniclaw:// —— 复用同一套解析器逐个 host 试探。
                fileURL = MessageListModel.resolveLooseFilePath(url.path, sessionID: session.id)
            }
            guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
                // [2026-09-12] 此前这里静默 return，导致「点了没反应」在日志里毫无痕迹。
                // 打一条 info（用户主动点击触发，低频）便于一次性定位。
                AppLogger.shared.info("[FileOpen] FAIL url=\"\(url.absoluteString)\" scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil") resolved=\(fileURL?.path ?? "nil") exists=false", category: "FileOpen")
                return
            }
            AppLogger.shared.info("[FileOpen] OK url=\"\(url.absoluteString)\" resolved=\(fileURL.path)", category: "FileOpen")
            // 2026-08-12:系统预览(Quick Look)——图片/PDF/音视频/文档统一用系统原生预览
            // 呈现(替代此前分享面板;分享仍可从 QL 底部动作获得)。
            previewFileURL = fileURL
        }
        .onChange(of: session.messages.count) { _ in
            lastMessageID = session.messages.last?.id
        }
        // [F3(b) 2026-09-12] 记住实测栏高，作为下次进入的初值（消除 0→实测 的一次性跳变）。
        .onChange(of: inputBarHeight) { h in
            ChatView.persistBarHeight(h, forKey: "chat.inputBarHeight")
        }
        .onChange(of: floatingBarHeight) { h in
            ChatView.persistBarHeight(h, forKey: "chat.floatingBarHeight")
        }
        .onChange(of: session.modelName) { _ in
            // 切换模型 = 换了上下文窗口与压缩阈值，圆环必须按新窗口重算。
            syncContextSnapshot(force: true)
        }
        // iOS16:onChange 单参数版本。用 @State 缓存上一个 isResponding 值,
        // 检测「回复刚结束」(true→false) 翻转。
        .onChange(of: isResponding) { nowResponding in
            let wasResponding = lastResponding
            lastResponding = nowResponding
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
        .onChange(of: inputText) { _ in
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
            // 仅对已持久化的空会话执行清理；全新未发言的会话未入内存，无需删除。
            // 存活守卫(2026-08-12 回归修复)：会话仍有存活运行时(AI 正在操作/排队)时绝不删——
            // 首条用户消息尚未落盘时 messages.isEmpty 误判,曾把运行中会话整体删除。
            // 2026-08-12 修复:队列里有排队消息的会话也不删(否则 teardownSession 清空排队 blob)。
            if session.messages.isEmpty && appState.chatRuntimes[session.id] == nil
                && (appState.pendingUserMessages[session.id]?.isEmpty ?? true) {
                let sid = session.id
                SessionManager.shared.deleteSession(id: sid)
                // 空会话同样清理隔离资源（注销 fsContext + 删除 Sessions/<uuid>/）
                SessionFileRouter.shared.unregister(sessionID: sid)
                // 顺手清掉该会话的子代理运行期注册表（复用状态不再需要）。
                SubagentRuntimeRegistry.shared.clear(sessionID: sid)
                ContextUsageStore.shared.clear(sessionID: sid)
            }
        }
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
        //
        // [2026-09-14 顶部磨砂·第三版] 顶部也放开 ⇒ 内容会**从顶栏下穿过**。这是"跟首页一样"的
        // **前提**：首页列表是 SwiftUI `List`，内容本来就从栏下穿过，系统才会在"有内容在栏下"时
        // 把栏背景换成材质、没有内容时保持**透明直接映射背景**（所以静止时是纯黑/纯白）。
        // 本页要补齐两件事，**都不自绘任何图层**：
        //   ① 列表穿过顶栏（本行）；
        //   ② 把列表**注册给导航栏**，让系统知道该盯哪个滚动视图 —— 见
        //      `MessageListViewController.registerCollectionViewForNavBarScrollEdge`。
        // 配套：顶部留白 = 顶栏真实高度（`TopBarInset` 常量），否则首条消息被顶栏盖住。
        // ⚠️ 第一版"割裂"的根因是**自绘了一整条渐变叠层 + 强制常显材质 + 隐藏栏背景**，
        // 三件事叠加成了"第二层"。这次一件都不做：颜色与材质**全部由系统栏自己给**。
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .onAppear {
            shouldAutoFollow = true
            // 初始贴底：延迟到布局完成后滚动一次（用户已上滑则放弃）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // [2026-09-13 补读路径] 搜索结果带定位目标时**定位优先于贴底**：
                // 此前这里只无条件清 nil（`appState.scrollToMessageID = nil`），
                // 而全库没有任何读取点 ⇒ 点搜索结果只进会话、不定位到那条消息。
                // 两者互斥，避免"先贴底再跳"的闪动。
                if let target = appState.scrollToMessageID {
                    appState.scrollToMessageID = nil
                    chatBridge.vm.scrollToMessageSignal.send(target)
                } else {
                    guard shouldAutoFollow else { return }
                    chatBridge.vm.scrollToBottomSignal.send()
                }
            }
        }
        // 会话已在前台时又被要求定位（首页再次点搜索结果等）→ 立即消费。
        // 消费后置 nil，与上面 onAppear 的读取合并成完整闭环（本变量此前只写不读）。
        .onChange(of: appState.scrollToMessageID) { target in
            guard let target else { return }
            appState.scrollToMessageID = nil
            chatBridge.vm.scrollToMessageSignal.send(target)
        }
        // 贴底状态同步（浮动「回到底部」按钮显隐,2026-08-10 Kit 路径）
        .onChange(of: chatBridge.vm.isNearBottom) { near in
            isNearBottom = near
        }
    }

    /// 适配列表(移植组件,默认路径),miniclaw.debug.chatList 开启时使用)

    private var adaptedListContent: some View {
        MessageCollectionView(
            vm: chatBridge.vm,
            inputFocused: isInputFocused,
            onRetryMessage: { messageID in retryMessage(messageID) },
            onEdit: { messageID in editMessage(messageID) },
            onResume: { chatBridge.onResume?() },
            onStop: { chatBridge.onStop?() },
            onCompact: { messageID in compactAbove(messageID) },
            onScreenshotImage: { image in
                // 2026-08-12 治本:菜单「复制截图」——截图真实生成后此前被丢弃,现写入剪贴板。
                UIPasteboard.general.image = image
            },
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
        // [Stage 2 · A1 收口 2026-09-17] **三处 `.onChange` 一律推到下一 runloop 再刷新。**
        //
        // 事实：`.onChange` 的闭包在 **SwiftUI view update 事务内**执行（本仓已有同源结论，
        // 见 `AssistantBlockView.onChange(of: isStreaming)` 的注释），而 `chatBridge.refresh()`
        // 会写 `vm.isProcessing` / `vm.canResume`（`@Published`）并在末尾发布
        // `vm.messages`（`@Published` 大数组）⇒ 运行期 fault：
        //   `[SwiftUI] Publishing changes from within view updates is not allowed,
        //    this will cause undefined behavior.`
        // 真机实证：单次会话窗口内 5 条 fault，时间点全部落在「新消息入列 / 流式起止」，
        // 与 `session.messages.count` / `…last?.isStreaming` 的翻转一一对应。
        // A1（`cachedMarkdown/cachedAttributedString` 去 `@Published`）只切断了渲染回写这一路，
        // 本条是同一 fault 的**第二条通路**，也是残留 fault 的来源。
        //
        // 为什么推一帧是安全的：列表数据本就经 `refresh()` 异步重建（通知路径早已写成
        // `DispatchQueue.main.async { self.refresh(force: true) }`），一个 runloop hop 仍在
        // 同一帧内完成；语义、顺序（count → content → isStreaming）均不变。
        .onChange(of: session.messages.count) { _ in
            DispatchQueue.main.async { chatBridge.refresh() }
        }
        .onChange(of: session.messages.last?.content.count ?? 0) { _ in
            DispatchQueue.main.async { chatBridge.refresh() }
        }
        .onChange(of: session.messages.last?.isStreaming ?? false) { _ in
            DispatchQueue.main.async { chatBridge.refresh(force: true) }
        }
    }
    // MARK: - 子代理悬浮头像（输入框上方）

    /// 添加密钥引导条(输入框上方悬浮层):照排队消息样式——虚线气泡 + 磨砂背景。
    /// 2026-08-11 用户需求:未配置任何服务商密钥时显示,点击进入服务商页面;
    /// 点击同时申请网络/本地网络权限(照设置页先例,拒绝不闪退)。
    private var addKeyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            Text(String(localized: "add_api_key"))
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(Color.orange.opacity(0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            // ① 打开智能体服务商页面(配置 LLM 提供商与 API,2026-08-11
            //    修正:此前误跳「模型管理」GroupsSettingsView,应为 ProviderSettingsView)。
            showProviderSettings = true
            // ② 申请网络/本地网络权限(照设置页先例):
            //    requestNetworkAccess 不弹窗仅登记联网;requestLocalNetwork 触发
            //    本地网络弹窗,用户拒绝走 .failed → denied 持久化,不会闪退。
            PermissionManager.shared.requestNetworkAccess()
            PermissionManager.shared.requestLocalNetwork()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// 排队消息行(输入框上方悬浮层):虚线气泡 + 删除叉 + 立即发送按钮 + 长按菜单。
    /// 2026-08-10 用户要求排队消息显示在输入框上方而非消息列表内容里。
    private func queuedMessageRow(_ item: PendingUserMessage) -> some View {
        HStack(spacing: 6) {
            // 立即发送:中断当前回复并立即发送该条。
            Button {
                // 2026-08-12 修复:只调 sendQueuedMessage,移除逻辑收敛在方法内部
                // (此前先 removeAll 再按 id 查找必然失败,排队消息静默丢失)。
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
                Label(String(localized: "copy_action"), systemImage: "doc.on.doc")
            }
            Button {
                injectInput(item.text)
                appState.pendingUserMessages[session.id, default: []].removeAll { $0.id == item.id }
                persistQueue()
                chatBridge.refresh()
            } label: {
                Label(String(localized: "edit_action"), systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                appState.pendingUserMessages[session.id, default: []].removeAll { $0.id == item.id }
                persistQueue()
                chatBridge.refresh()
            } label: {
                Label(String(localized: "delete_action"), systemImage: "trash")
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

    /// 输入框上方悬浮的子代理胶囊卡（唐唐 2026-09-05 定稿）：
    /// 每个子代理一张胶囊卡（紫色首字母圆头像 + 名称），背景与排队消息一致（ultraThinMaterial 实心圆角框），
    /// 高度对齐排队消息行；长度随子代理数量自然增长（超出宽度横向滚动）。
    /// 状态边框对齐工具指示器：已完成=绿色、出错=红色、已取消=灰色、运行中=无边框。
    /// 点按打开「智能体 ↔ 子代理」对话详情页；长按移除该子代理卡片。
    /// 注意：手势不用 Button（Button 内部手势会压制 onLongPressGesture，长按永不触发），
    /// 用 onTapGesture + onLongPressGesture 组合（长按优先识别，快速点按走 tap）。
    private func subagentFloatingAvatars(_ subs: [SubagentCard]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(subs) { sub in
                    subagentCapsule(sub)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        // 长按关闭二次确认（唐唐 2026-09-05 要求）：确认才走统一关闭路径。
        .confirmationDialog(
            String(localized: "subagent_close_confirm_title"),
            isPresented: Binding(
                get: { pendingRemoveSubagent != nil },
                set: { if !$0 { pendingRemoveSubagent = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "subagent_close_button"), role: .destructive) {
                if let sub = pendingRemoveSubagent { closeSubagent(sub) }
                pendingRemoveSubagent = nil
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingRemoveSubagent = nil
            }
        } message: {
            Text(String(localized: "subagent_close_confirm_message"))
        }
    }

    /// 统一关闭入口（确认弹窗确认后调用）：与 智能体侧 close_subagent 同一条
    /// SubagentLifecycle.close 路径（取消运行中引擎 → 移除复用记录 → 移除卡片与对话 →
    /// 释放浏览器上下文）。
    private func closeSubagent(_ sub: SubagentCard) {
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

    /// 单张子代理胶囊卡。
    /// 样式（唐唐 2026-09-12 定稿）：**背景恒为卡片常规实底**（去掉完成态的绿底，
    /// 底色与排队消息卡同系）；**状态一律用「思考指示器同款 0.5pt 描边圈」表达**——
    /// 已完成=绿、出错/已中断=红、已取消=灰、运行中=无圈。
    /// 高度对齐思考指示器（`ReasoningBlockView`：内容高 + 上下各 10 ≈ 36pt）：本卡
    /// 24pt 头像 + 上下各 6 = 36pt。
    /// 圈与底色用**同一个圆角矩形**（background → clipShape → overlay(strokeBorder)，
    /// 与 ReasoningBlockView 逐字同序），保证描边严格贴合卡片边缘、不出现半像素缝。
    private func subagentCapsule(_ sub: SubagentCard) -> some View {
        HStack(spacing: 8) {
            // 首字母圆头像（紫色实心，白字）
            ZStack {
                Circle()
                    .fill(Color(red: 0.38, green: 0.32, blue: 0.80))
                    .frame(width: 24, height: 24)
                Text(String(sub.name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(sub.name)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // 实底背景（唐唐 2026-09-05 定稿，pill 卡做法）：
        // 不用 ultraThinMaterial 实时模糊——悬浮条 3 层 blur 在列表滚动时每帧重采样，
        // 是「回到会话页翻历史整页抖动」的根因。底色恒为常规实底，不再随状态变绿。
        .background(Color(UIColor.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            // 状态圈：思考指示器同款 0.5pt 细描边（已完成=绿 / 出错=红 / 取消=灰）
            if let ring = subagentCapsuleRing(sub.status) {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(ring, lineWidth: 0.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if let conv = subagentStore.conversation(for: session.id, subagentID: sub.id) {
                activeSubagentConversation = conv
            }
        }
        .onLongPressGesture {
            // 长按：弹二次确认（确认才走 closeSubagent 统一路径）
            pendingRemoveSubagent = sub
        }
        .accessibilityLabel(Text(sub.name))
    }

    /// 胶囊卡状态圈颜色（nil = 运行中，不画圈）。
    /// 2026-09-12：完成态**不再用绿底**，改为思考指示器同款的一圈绿色（0.5pt 细描边）；
    /// 出错/已中断=红、已取消=灰，与工具/思考指示器的状态语言完全一致。
    private func subagentCapsuleRing(_ status: SubagentStatus) -> Color? {
        switch status {
        case .completed: return .green
        case .error: return .red
        case .cancelled: return .gray
        case .running: return nil
        }
    }

    /// 展示「附件将交由 智能体通过工具读取」的短暂提示，几秒后自动消失。
    @MainActor
    private func showAttachmentNotice(droppedNames: [String]) {
        guard !droppedNames.isEmpty else { return }
        let list = droppedNames.prefix(3).joined(separator: "、")
        let suffix = droppedNames.count > 3 ? String(format: String(localized: "and_other_files"), String(droppedNames.count)) : ""
        withAnimation { attachmentNotice = String(format: String(localized: "sent_to_the_agent_it_will_read_them_via_tools"), list, suffix) }
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
        // 被模型原生模态拒收的附件（含图片——图片改由 apple-vision 工具兜底读取）
        // 统一在输入栏上方弹一条提示，用户可点按关闭。
        let (allowedAttachments, droppedNames, droppedPaths) = AgentRunService.filterAttachments(attachments, endpoint: firstEndpoint)
        // [Attach 诊断 2026-09-12] 记下附件模态判定的**全部现场**：端点能力 + 每个附件的扩展名
        // + 最终放行/丢弃名单。用于一次定位「图片没走原生输入」到底是哪一种：
        //   ①端点 inputImage 为 false（模型能力判定）②扩展名被判成非图片 ③附件路径/迁移失败。
        AppLogger.shared.info(
            "[Attach] model=\(firstEndpoint.modelName) inputImage=\(firstEndpoint.supportsImageInput) inputAudio=\(firstEndpoint.supportsAudioInput) inputVideo=\(firstEndpoint.supportsVideoInput) total=\(attachments.count) allowed=\(allowedAttachments.count) exts=[\(attachments.map { ($0 as NSString).pathExtension.lowercased() }.joined(separator: ","))] dropped=[\(droppedNames.joined(separator: ","))]",
            category: "Attach")
        showAttachmentNotice(droppedNames: droppedNames)

        // 对于因模型不支持而被丢弃的附件，在用户消息中注入路径提示，
        // 让 智能体自行通过工具读取（模仿端侧「让 智能体自己找工具读文件」的模式）：
        // - 图片 → apple-vision 工具（Apple Vision 端侧分析）
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
                hints.append(String(format: String(localized: "vision_unsupported_hint"), imagePaths.count, fileList, pathList))
            }
            if !filePaths.isEmpty {
                let fileList = filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                let pathList = filePaths.joined(separator: "\", \"")
                hints.append(String(format: String(localized: "files_unsupported_hint"), filePaths.count, fileList, pathList))
            }
            if !hints.isEmpty {
                enrichedInput.append("\n\n" + String(localized: "sys_note_prefix") + hints.joined(separator: "\n"))
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
            // 用量回调不再写 ChatView 本地状态（见 contextSnapshot 删除说明）；
            // 用量由 AgentRunService / ContextUsageStore 侧统一承载。
            uiHooks: AgentRunService.UIHooks(onContextUsage: { _ in })
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
        for exec in runtime.streamingToolExecutions where exec.result == nil {
            exec.markInterrupted(text: String(localized: "user_stopped"), at: stoppedAt)
        }

        if let sid = runtime.streamingMessageID,
           let msg = session.messages.first(where: { $0.id == sid }) {
            msg.content = runtime.streamingContent
            msg.isStreaming = false
            msg.wasStopped = true
            // 终态清除消息级暂停标志：曾被暂停（isPaused 落盘）的回复被手动停止后，
            // 不再残留「已暂停」横幅（与 AgentRunService 三条终态路径同口径）。
            msg.isPaused = false
            // 2026-08-12 修复:停止也是终态,补落盘思考段(此前漏写,思考永久丢失
            // 且被打断会话重进后思考指示器消失)。对齐 onInterrupted 的落盘逻辑。
            msg.reasoningSegments = runtime.streamingReasoningSegments
            if !runtime.streamingReasoningSegments.isEmpty {
                msg.reasoning = runtime.streamingReasoningSegments.map { $0.text }.joined(separator: "\n\n")
            }
            // 任务总耗时：用户停止即终态，结算耗时（暂停态停止同样覆盖；断点恢复任务不显示）。
            if !runtime.taskTimingInvalid, msg.taskElapsedSeconds == nil { msg.taskElapsedSeconds = runtime.taskSettle() }
            if !runtime.streamingToolExecutions.isEmpty {
                msg.toolCalls = runtime.streamingToolEvents
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
            // 2026-08-12 治本:恢复即回 .running(与暂停写 .paused 对称)。
            session.status = .running
            session.updatedAt = Date()
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
        // 2026-08-12 治本:恢复时按检查点状态还原会话状态——暂停的检查点恢复为 .paused
        // (首页行显示暂停而非转圈),其余(中断/运行)恢复为 .running 待续跑。
        session.status = (task.status == .paused) ? .paused : .running

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
            // 同上：不再写本地状态。
            uiHooks: AgentRunService.UIHooks(onContextUsage: { _ in })
        )
        // 断点恢复（冷启动续跑）：计时起点不可靠，按用户规则不显示耗时。
        runtime.taskTimingInvalid = true
        // 重建完整性（2026-08-08 修复）：把已落盘的工具卡/思考段/时间线序号回填进新 runtime，
        // 否则渲染时 effectiveToolCalls 优先取 runtime 空数组 → 已完成的工具卡/思考块被遮蔽消失。
        // 直接引用架构：从落盘事件重建 ToolExecution，并经幂等注册表挂载（同时回填 order 字典，
        // 保证渲染排序 `runtime.order(for:)` 拿到原时间线序号而非兜底 0）。
        for event in bubble.toolCalls {
            runtime.registerStreamingToolExecution(ToolExecution(restoring: event), order: Double(event.timelineOrder))
        }
        // [2026-09-15 治本] 这些位置来自落盘事件（权威）⇒ 标记已定稿，禁止后续冻结改写。
        runtime.markRestoredToolsSettled()
        runtime.streamingReasoningSegments = bubble.reasoningSegments
        // 2026-08-12 修复:旧数据/停止时未落盘思考段的场景,bubble.reasoningSegments 为空时
        // 从检查点 task.messages 的最后一条 assistant 消息提取 reasoning_content 重建思考段,
        // 否则被打断会话重进后思考指示器消失。
        if bubble.reasoningSegments.isEmpty,
           let lastAssistant = task.messages.last(where: { $0.role == "assistant" }),
           let rc = lastAssistant.reasoningContent, !rc.isEmpty {
            let seg = ReasoningSegment(index: 0, text: rc, position: 0, timelineOrder: 0)
            bubble.reasoningSegments = [seg]
            runtime.streamingReasoningSegments = [seg]
        }
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
        // 排队消息转为真实用户消息即落盘(2026-08-12 回归修复)。
        SessionManager.shared.persist(session)

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
        // 排队消息转真实消息即落盘(2026-08-12 回归修复)。
        SessionManager.shared.persist(session)
        startAgentResponse(to: item.text, userMessageID: userMessage.id, injectedSkill: item.skillName, attachments: item.attachments, thinkingLevel: session.thinkingLevel, deepLinkCallback: item.deepLinkCallback)
    }
}

// MARK: - 块级段缓存（2026-08-09 崩溃修复）

/// 穿插段纯性能缓存：引用类型，@State 持有它时内部写入不会触发 SwiftUI 更新，
/// 也不会被视为「视图更新期间修改 State」（iOS 18 该行为是断言崩溃，非警告）。
