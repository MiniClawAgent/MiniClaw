//
//  ChatV2RowBuilder.swift — Chat V2 的唯一行生产者（纯函数）。
//  身份：ChatRowID = (messageID, kind, blockID)，只由结构决定，内容变化不改身份。
//  版本：version = 内容长度 + 内容指纹 + 该行真正渲染的状态；内容/状态变则必变，
//        纯 UI 无关变化（toolStatus.streaming 的字节数、计时 tick）不进版本。
//  顺序：user/divider/systemInfo → 单行；assistant → header + blocks（现有顺序，不排序）+ footer；
//        末尾固定一行 bottomSpacer，高度由布局填满剩余空间。
//

import Foundation
import CoreGraphics

struct ChatV2RowBuilder: ChatV2RowBuilding {

    // MARK: - 会话级状态（可选注入）

    /// `isProcessing` / `canResume` **不在** `RenderMessage` 上 —— 它们在宿主视图模型
    /// `MessageListModel` 上（MiniClawHostStubs.swift:320-321），且只对最后一条消息生效
    /// （MessageCollectionView.swift:535：`isActive = isLast && vm.isProcessing`）。
    ///
    /// 本 Builder 是纯函数（不收宿主、不读单例）⇒ 二者只能"可读就注入"：
    /// 注入 → 参与 footer 版本；保持 nil（默认）→ 版本**不含**该项，绝不为版本好看而假造状态。
    var isProcessing: Bool? = nil
    var canResume: Bool? = nil

    /// 空会话时 `bottomSpacer` 的身份来源。必须是**固定常量**：
    /// `UUID()` 每次构建都给新身份 ⇒ diffable 每帧都当成「删一行 + 插一行」。
    static let bottomSpacerMessageID = UUID(uuidString: "00000000-0000-0000-0000-00000000FEED")!

    // MARK: - ChatV2RowBuilding

    func buildRows(messages: [RenderMessage]) -> [ChatRow] {
        var rows: [ChatRow] = []
        rows.reserveCapacity(messages.count + 2)

        for message in messages {
            switch message.role {
            case .user:
                rows.append(wholeRow(message, kind: .userBubble))
            case .compactDivider:
                rows.append(wholeRow(message, kind: .divider))
            case .systemInfo:
                rows.append(wholeRow(message, kind: .systemInfo))

            case .assistant:
                // 顺序与旧页逐条对齐（MessageCollectionCoordinator+Snapshot.swift:239-267）：
                // header → 每个 block → footer。每条 assistant 消息都带 footer
                //（旧页 2026-09-05 的决定：终态状态行不再只显示最后一条）。
                rows.append(headerRow(message))
                // ⚠️ 不排序：blocks 的顺序由 Bridge 维护；这里按 `message.blocks` 的现有顺序逐块出行。
                for block in message.blocks {
                    rows.append(blockRow(message, block: block))
                }
                rows.append(footerRow(message))
            }
        }

        rows.append(bottomSpacerRow(after: messages.last))
        return rows
    }

    // MARK: - 行构造（身份在这里落地；版本见下方各 version 函数）

    private func wholeRow(_ message: RenderMessage, kind: ChatRowKind) -> ChatRow {
        ChatRow(id: ChatRowID(messageID: message.id, kind: kind, blockID: nil),
                version: wholeMessageVersion(message),
                message: message,
                block: nil)
    }

    private func headerRow(_ message: RenderMessage) -> ChatRow {
        ChatRow(id: ChatRowID(messageID: message.id, kind: .assistantHeader, blockID: nil),
                version: headerVersion(message),
                message: message,
                block: nil)
    }

    private func blockRow(_ message: RenderMessage, block: AssistantBlock) -> ChatRow {
        ChatRow(id: ChatRowID(messageID: message.id, kind: Self.rowKind(for: block.kind), blockID: block.id),
                version: blockVersion(block, in: message),
                message: message,
                block: block)   // 只有 block 行携带 block（契约：其它行的 block == nil）
    }

    private func footerRow(_ message: RenderMessage) -> ChatRow {
        ChatRow(id: ChatRowID(messageID: message.id, kind: .footer, blockID: nil),
                version: footerVersion(message),
                message: message,
                block: nil)
    }

    /// 末尾占位：挂在最后一条消息上；没有消息时用固定常量。
    /// 高度策略固定为 `.automatic(estimated: 0)`（见 `heightPolicy(for:)`），由布局填满剩余空间。
    private func bottomSpacerRow(after last: RenderMessage?) -> ChatRow {
        let owner = last ?? RenderMessage(role: .systemInfo, content: "", id: Self.bottomSpacerMessageID)
        return ChatRow(id: ChatRowID(messageID: owner.id, kind: .bottomSpacer, blockID: nil),
                       version: "spacer",   // 高度只取决于"剩余空间"，与内容无关 ⇒ 版本恒定
                       message: owner,
                       block: nil)
    }

    // MARK: - 类型映射

    /// 块类型 → 行类型。
    /// - `.info` 渲染成小号文字行（AssistantBlockView.swift:632-669）⇒ `.text`；
    /// - `.file` 渲染成文件卡（AssistantBlockView.swift:670-673），契约的 kind 集合里没有对应项
    ///   ⇒ 取 `.tool`：同为「非正文卡片」，且它的播种兜底高度 40 = `ChatV2Metrics.toolEstimate`
    ///   （RenderModels.swift:90）。将来契约若新增 `.file` 行类型，只改这一处。
    private static func rowKind(for kind: AssistantBlockKind) -> ChatRowKind {
        switch kind {
        case .text, .info: return .text
        case .thinking: return .thinking
        case .question: return .question
        case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool,
             .browserTool, .readImageTool, .memoryTool, .subagentTool, .file:
            return .tool
        }
    }

    // MARK: - 版本（内容/状态 → version；纯 UI 无关的变化一律不进）

    /// 整条消息行（user / compactDivider / systemInfo）：
    /// 覆盖 `ChatMessageRow` 这三个分支真正会读的字段（ChatMessageRow.swift:96-180、198-283）。
    private func wholeMessageVersion(_ message: RenderMessage) -> String {
        var parts = ["w"]
        parts += Self.contentToken(message.content)
        parts.append("att=\(message.attachments.count)")
        // 排队附件预览按 loadState 显示缩略图 / 进度 / 失败占位（QueuedAttachmentPreview）
        parts.append("ina=\(message.inputAttachments.count):\(message.inputAttachments.map(\.loadState.token).joined())")
        if message.isQueued { parts.append("queued") }           // 虚线气泡 + 立即发送/撤回按钮
        if message.isCompactedHistory { parts.append("faded") }   // .opacity(0.5)
        if message.isCompactLoading { parts.append("loading") }   // 图标换成 ProgressView
        if let icon = message.systemIcon { parts.append("icon=\(icon)") }
        if let summary = message.compactSummary { parts.append("sum=\(Self.fingerprint(summary))") }
        return parts.joined(separator: "|")
    }

    /// 头部只有 ✨ + 名字（MessageCollectionView.swift:8-25），会随消息变的只有整条半透明态。
    private func headerVersion(_ message: RenderMessage) -> String {
        message.isCompactedHistory ? "h|faded" : "h|solid"
    }

    /// 块行版本：内容（长度 + 指纹）+ 类型（含会影响显示文案的关联值）+ 该块真正渲染的状态。
    private func blockVersion(_ block: AssistantBlock, in message: RenderMessage) -> String {
        var parts = ["b", Self.kindToken(block.kind)]
        parts += Self.contentToken(block.content)
        // 「本消息是否还在生成」的唯一**可读**信号：`isActiveMessage` 在 CellStateBridge 上（不可读），
        // `isAwaitingModelResponse` 是 RenderMessage 上的对应状态 ⇒ 块行也带，避免等待/收尾时停在旧渲染。
        parts.append("await=\(message.isAwaitingModelResponse ? 1 : 0)")

        switch block.kind {
        case .thinking:
            // 收起 / 展开是两种高度与外观（`ThinkingBlockView`：收起=标题条，展开=可滚动面板）
            parts.append("exp=\(block.isThinkingExpanded ? 1 : 0)")

        case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool,
             .browserTool, .readImageTool, .memoryTool, .subagentTool:
            // 状态灯、shimmer、停止按钮、BouncingDots 都由 toolStatus 决定（AssistantBlockView.swift:99-165、:237-243）
            parts.append(Self.toolStatusToken(block.toolStatus))
            // 耗时是胶囊上的一段可见文字（AssistantBlockView.swift:246-256）⇒ 按显示精度进版本
            parts.append("dur=\(Self.durationToken(block.toolDuration))")
            // `displayStr` 优先取 toolSummary，其次 toolDescription(kind 关联值 / toolInputArgs)
            if let summary = block.toolSummary, !summary.isEmpty {
                parts.append("sum=\(Self.fingerprint(summary))")
            }
            if let args = block.toolInputArgs, !args.isEmpty {
                parts.append("args=\(Self.fingerprint(args))")
            }
            // 后台挂起时胶囊外侧会多一个黄色 ⓘ（AssistantBlockView.swift:20、:202-215）
            if block.wasBackgroundSuspended { parts.append("susp") }

        case .text, .question, .info, .file:
            // 这几类没有块级状态：问答卡的 pending / answered 编码在 content 里（指纹已覆盖），
            // 文件卡只读 url + content。
            // （问答卡"是否有待答请求"还依赖 `AskUserBroker` 这个单例，纯函数读不到 ⇒ 留给 cell 自行刷新。）
            break
        }

        return parts.joined(separator: "|")
    }

    /// footer 版本：终态静默行 / 错误 / 恢复横幅 / 中断徽标 / 用量胶囊，逐条对应
    /// `BridgedAssistantFooter.body`（BridgedCellViews.swift:238-285）。
    private func footerVersion(_ message: RenderMessage) -> String {
        var parts = ["f"]
        parts.append(message.error.map { "err=\(Self.fingerprint($0))" } ?? "err=none")
        parts.append("int=\(message.streamInterruptCount)")
        parts.append("await=\(message.isAwaitingModelResponse ? 1 : 0)")
        parts.append(message.wasStopped ? "stopped" : "notStopped")
        parts.append(message.wasInterrupted ? "interrupted" : "notInterrupted")
        // 耗时后缀只在终态行出现，且 <1s 不显示 ⇒ 版本也用同一精度
        parts.append("elapsed=\(Self.elapsedToken(message.taskElapsedSeconds))")
        parts.append("usage=\(Self.usageToken(message.usage))")
        if message.isCompactedHistory { parts.append("faded") }
        // 会话级状态：只有调用方注入时才可读（见属性注释），nil 时版本里不出现该项
        if let processing = isProcessing { parts.append("proc=\(processing ? 1 : 0)") }
        if let resume = canResume { parts.append("resume=\(resume ? 1 : 0)") }
        return parts.joined(separator: "|")
    }

    // MARK: - 可用状态 → 版本令牌

    /// 块类型标签。凡是**会显示**的关联值都拼进来（`toolDescription`、`FileBlockView`、问答卡配对）。
    private static func kindToken(_ kind: AssistantBlockKind) -> String {
        switch kind {
        case .text: return "k=text"
        case .thinking: return "k=thinking"
        case .info: return "k=info"
        case .question(let callId): return "k=question/\(fingerprint(callId))"
        case .file(let url): return "k=file/\(fingerprint(url))"
        case .shellTool(let command): return "k=shell/\(fingerprint(command))"
        case .fileReadTool(let path): return "k=read/\(fingerprint(path))"
        case .fileWriteTool(let path): return "k=write/\(fingerprint(path))"
        case .fileEditTool(let path): return "k=edit/\(fingerprint(path))"
        case .browserTool(let action): return "k=browser/\(fingerprint(action))"
        case .readImageTool(let path): return "k=img/\(fingerprint(path))"
        case .memoryTool(let action): return "k=memory/\(fingerprint(action))"
        case .subagentTool(let action): return "k=subagent/\(fingerprint(action))"
        }
    }

    /// 工具状态标签。⚠️ **故意丢掉 `.streaming(bytes:)` 的字节数**：
    /// 字节每 chunk 都变，而胶囊上并不显示它（AssistantBlockView.swift:99-102、:122 只用来显示 BouncingDots）
    /// —— 把它放进版本等于让每一帧都 reconfigure。
    /// `.failed(message:)` 同理只留状态：失败文案不进胶囊，只有详情页会读。
    private static func toolStatusToken(_ status: ToolBlockStatus?) -> String {
        guard let status else { return "st=none" }
        switch status {
        case .streaming: return "st=stream"
        case .running: return "st=run"
        case .success: return "st=ok"
        case .failed: return "st=fail"
        case .cancelled: return "st=cancel"
        }
    }

    /// 与 `ToolCapsuleView.durationLabel`（AssistantBlockView.swift:246-256）**同精度**：
    /// 屏上文字没变（2.34s 与 2.35s 都显示 "2s"）就不该重配。
    private static func durationToken(_ duration: TimeInterval?) -> String {
        guard let duration else { return "nil" }
        if duration < 1 { return String(format: "%.1fs", duration) }
        if duration < 60 { return String(format: "%.0fs", duration) }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return "\(mins)m\(secs)s"
    }

    /// 与 `BridgedAssistantFooter.elapsedText`（BridgedCellViews.swift:215-221）+ 展示阈值 `>= 1`
    /// （BridgedCellViews.swift:206）同口径：不足 1s 不显示，版本里也不区分。
    private static func elapsedToken(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 1 else { return "hidden" }
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return "\(h)h\(m)m\(s)s" }
        if m > 0 { return "\(m)m\(s)s" }
        return "\(s)s"
    }

    /// 用量胶囊显示的是这五个计数（BridgedCellViews.swift:430-438）。
    private static func usageToken(_ usage: TokenUsage?) -> String {
        guard let usage else { return "none" }
        return "\(usage.latestContextTokens).\(usage.inputTokens).\(usage.outputTokens)"
            + ".\(usage.cacheCreationTokens).\(usage.cacheReadTokens)"
    }

    // MARK: - 内容令牌

    /// 内容令牌：**长度 + 确定性指纹**。
    /// - 长度：契约要求 version 含内容长度，日志里也能一眼看出"是在长还是在改"；
    /// - 指纹：等长改写（长度不变、内容不同）也必须让版本变化 ⇒ 复用全库唯一的内容指纹
    ///   `ContentFingerprint`（MarkdownSupport.swift:1496，FNV-1a，跨进程稳定；**不用 Hasher**，
    ///   它的种子逐进程随机），不另造第二套哈希口径。
    /// - 用 UTF-8 字节数而非 `Character` 数：同样是"长度"，但省掉字形分割且与指纹内部口径一致。
    private static func contentToken(_ text: String) -> [String] {
        ["len=\(text.utf8.count)", "fp=\(fingerprint(text))"]
    }

    private static func fingerprint(_ text: String) -> String {
        String(UInt(bitPattern: ContentFingerprint.of(text)), radix: 16)
    }

    // MARK: - 高度策略（Builder 决定，布局只读）

    /// `ChatRow` 本身不带策略字段 ⇒ 布局侧经本方法读取；值的唯一来源仍是 `ChatV2Metrics`。
    func heightPolicy(for row: ChatRow) -> ChatRowHeightPolicy {
        Self.heightPolicy(for: row.kind)
    }

    /// 行高策略只由**行类型**决定，与内容无关（纯函数，可单测）。
    ///
    /// `bottomSpacer` 是唯一特殊项：`.automatic(estimated: 0)` —— 估算 0，真实高度 = 剩余空间，
    /// 由布局填满；短会话靠它把内容顶到底部，长会话它自然为 0。
    static func heightPolicy(for kind: ChatRowKind) -> ChatRowHeightPolicy {
        switch kind {
        case .assistantHeader: return .fixed(ChatV2Metrics.headerHeight)
        case .footer: return .fixed(ChatV2Metrics.footerHeight)
        case .userBubble: return .automatic(estimated: ChatV2Metrics.userBubbleEstimate)
        case .text: return .automatic(estimated: ChatV2Metrics.textEstimate)
        case .thinking:
            // 契约没有给 thinking 单列估高：收起态就是 40pt 标题条（V1 `estimateItemHeight` 的
            // headerH = 40），故借同为 40 的 toolEstimate 当种子，展开态交给 cell 自 sizing。
            // 不新增常量：ChatV2Metrics 是唯一来源。
            return .automatic(estimated: ChatV2Metrics.toolEstimate)
        case .tool: return .automatic(estimated: ChatV2Metrics.toolEstimate)
        case .question: return .automatic(estimated: ChatV2Metrics.questionEstimate)
        case .divider: return .automatic(estimated: ChatV2Metrics.dividerEstimate)
        case .systemInfo: return .automatic(estimated: ChatV2Metrics.systemInfoEstimate)
        case .bottomSpacer: return .automatic(estimated: 0)
        }
    }
}

// MARK: - 私有辅助

private extension RenderAttachment.LoadState {
    /// 版本令牌：附件加载态变化会改可见内容（缩略图 ↔ 进度 ↔ 失败占位）。
    var token: String {
        switch self {
        case .ready: return "r"
        case .loading: return "l"
        case .failed: return "f"
        }
    }
}
