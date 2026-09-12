import Foundation
import MiniClawKit

// MARK: - 适配层:消息转换(2026-08-09)
// 把 MiniClaw 的 SwiftData 消息模型转换为 移植消息列表组件所需的
// ChatMessage/AssistantBlock 形态。纯转换,不持有状态。
// 2026-08-11 [Fix 重进会话跳屏·根因]:整体 @MainActor——buildBlocks 内为 text
// block 调用 cacheRenderedContent()(内部经 FontSettings.shared 渲染,其本身是
// @MainActor),且所有调用方(MiniClawChatBridge)都在 MainActor 上下文。

@MainActor
enum MiniClawChatAdapter {

    // MARK: - 消息级转换

    /// 把 MiniClaw 消息转换为移植组件形态(含 blocks 拆分)
    static func convert(_ message: ChatMessage) -> RenderMessage {
        // 2026-08-13 治本:id 注入——Kit ChatMessage.id 原为自动 UUID,与宿主 message.id
        // 不等,导致长按菜单 Edit/Retry 的 session.messages.first(where: id) 找不到 → no-op。
        let kitMessage = RenderMessage(role: kitRole(message), content: message.content, id: message.id)
        kitMessage.blocks = buildBlocks(message)
        kitMessage.isAwaitingModelResponse = message.isStreaming
        // 终态状态行桥接（2026-09-05）：footer 状态行需要已停止/已中断/耗时。
        kitMessage.wasStopped = message.wasStopped ?? false
        kitMessage.wasInterrupted = message.wasInterrupted ?? false
        kitMessage.taskElapsedSeconds = message.taskElapsedSeconds
        // 2026-08-12 治本:附件桥接——宿主消息 attachments 是会话相对路径
        // ("attachments/<name>"),映射为 Kit 的 AttachmentMeta(path: "/var/miniclaw/<rel>");
        // Kit 的 miniClawURL 据此派生 miniclaw:// URL,UserAttachmentList 才能渲染出
        // 图片缩略图/文件卡片(此前 convert 从不读 attachments,渲染恒空 → 附件全部不显示)。
        if message.role == .user {
            kitMessage.attachments = message.attachments.map { rel in
                AttachmentMeta(path: "/var/miniclaw/\(rel)", size: Self.attachmentSize(rel), modified: Date())
            }
        }
        return kitMessage
    }

    /// 附件实际字节数(读会话目录文件;失败回退 0)。
    private static func attachmentSize(_ rel: String) -> Int {
        let url = SessionFileRouter.sessionsHostBase.appendingPathComponent(rel)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }

    private static func kitRole(_ message: ChatMessage) -> ChatMessageRole {
        switch message.role {
        case .user: return .user
        case .assistant, .tool: return .assistant
        case .system: return .systemInfo
        }
    }

    // MARK: - 块级转换

    /// 按 timelineOrder 交错生成 blocks:思考段/正文片段/工具调用。
    /// 正文按思考段/工具调用的 position 切分成多个片段,每段 order = 前一事件
    /// order + 0.5,实现「思考1→工具1→回复1→思考2→工具2→回复2」的真实穿插
    /// (与子代理会话 assistantSegments 的顺序规则一致)。
    private static func buildBlocks(_ message: ChatMessage) -> [AssistantBlock] {
        var items: [(order: Double, block: AssistantBlock)] = []

        // 收集事件(思考段 + 工具调用),按 timelineOrder 排序,含 position。
        var events: [(order: Int, position: Int, block: AssistantBlock)] = []

        // 2026-08-12 兜底:reasoningSegments 为空但 message.reasoning(单串)非空时,
        // 渲染一个完整思考块(旧数据/异常路径的降级,避免思考内容被静默隐藏)。
        if message.reasoningSegments.isEmpty, let reasoning = message.reasoning, !reasoning.isEmpty {
            let block = AssistantBlock(id: UUID(), kind: .thinking, content: reasoning)
            block.isThinkingExpanded = false
            block.thinkingUserToggled = false
            events.append((0, 0, block))
        }

        for seg in message.reasoningSegments {
            // 2026-08-11 [Fix 重进会话跳屏·方案B]:传 seg.id(SwiftData 持久化),
            // 重建时复用 → contentKey 稳定 → memo 跨会话命中,首帧即精确高度。
            let block = AssistantBlock(id: seg.id, kind: .thinking, content: seg.text)
            // 2026-08-10 用户要求:思考块默认折叠,哪怕用户上次展开过,
            // 每次重建(新消息/流式刷新)一律强制折叠,不保留任何展开状态。
            block.isThinkingExpanded = false
            block.thinkingUserToggled = false
            events.append((seg.timelineOrder, seg.position, block))
        }

        for event in message.toolCalls {
            let block = AssistantBlock(id: event.id, kind: toolKind(event.name, arguments: event.arguments), content: event.resultText)
            block.toolUseId = event.callID ?? event.id.uuidString
            block.toolInputArgs = event.arguments
            block.toolDuration = event.duration
            block.toolStatus = toolStatus(for: event, message: message)
            events.append((event.timelineOrder, event.position, block))
        }

        let hasTimeline = events.contains { $0.order > 0 }
        let sortedEvents: [(order: Double, position: Int, block: AssistantBlock)]
        if hasTimeline {
            sortedEvents = events.sorted {
                $0.order < $1.order || ($0.order == $1.order && $0.position < $1.position)
            }.map { (Double($0.order), $0.position, $0.block) }
        } else {
            sortedEvents = events.sorted {
                $0.position < $1.position
            }.map { (Double($0.position + 1), $0.position, $0.block) }
        }

        // 正文按 position 切分:每个事件前的正文片段 order = 事件 order - 0.5,
        // 事件后的剩余正文排最后(Int.max-1)。
        // 注意:每个 block(事件块与正文片段)都必须在创建时把 order 写回
        // block.timelineOrder——渲染层按 block.timelineOrder 兜底排序(2026-08-10),
        // 若只按元组排序不写回,渲染层读默认值 Int.max-1 会全部相等→按 id 乱序。
        let content = message.content
        // [2026-09-09 诊断] position 超界 = 事件 position 与落盘 content 不同源
        //（典型：流式中退出会话，segments/toolCalls 已落盘而 content 滞后）。
        // clamp 会让中间正文段被 cursor 跳过 → 重进会话正文"消失"。
        // 打 warn（低频异常路径）供真机日志一锤定音。
        let overCount = sortedEvents.filter { $0.position > content.count || $0.position < 0 }.count
        if overCount > 0 {
            AppLogger.shared.warn(
                "[Timeline] position out of range: contentCount=\(content.count) events=\(sortedEvents.count) over=\(overCount) msgId=\(message.id.uuidString.prefix(8))",
                category: "Timeline", subsystem: "Bridge")
        }
        var textCursor = 0
        for (order, position, block) in sortedEvents {
            block.timelineOrder = order
            let pos = min(max(position, 0), content.count)
            if pos > textCursor {
                let startIdx = content.index(content.startIndex, offsetBy: textCursor)
                let endIdx = content.index(content.startIndex, offsetBy: pos)
                // [Fix 重进会话跳屏·方案B] 正文片段无持久化事件 id,用
                // (mid+起始字符位置) 生成确定性 UUID:同内容同切分 → 同 id →
                // contentKey 稳定 → memo 跨会话命中。
                let segment = String(content[startIdx..<endIdx])
                for (o, b) in splitFileBlocks(markdown: segment, messageID: message.id, baseOrder: order - 0.5, startOffset: textCursor) {
                    items.append((o, b))
                }
            }
            items.append((order, block))
            textCursor = max(textCursor, pos)
        }
        if textCursor < content.count {
            let startIdx = content.index(content.startIndex, offsetBy: textCursor)
            let segment = String(content[startIdx..<content.endIndex])
            // [2026-09-12 文件指示器错位修复] 尾部片段（= 最终回复）此前用
            // `baseOrder: Double(Int.max - 1)`。该量级下 **Double 的精度间隔是 2048**，
            // 于是 splitFileBlocks 内部的 `baseOrder + 0.05*k` **全部被吞掉** → 尾部里的
            // 文本块与文件块拿到**完全相同**的 order → `sorted`（不保证稳定）把文件块
            // 排到了正文之前 ⇒ 真机表现为「文件指示器总在最终回复上面」（截图实证）。
            // （同款坑在本文件 110-112 行的注释里已记录：默认值 Int.max-1 会让 order 全相等。）
            // 修法：基准取**实际最大事件 order + 0.5** —— 仍严格大于所有事件与事件前正文段
            // （后者是 eventOrder - 0.5），同时保持在 Double 精确表示范围内，子序 0.05*k 不丢。
            let tailBase = (sortedEvents.map(\.order).max() ?? 0) + 0.5
            for (o, b) in splitFileBlocks(markdown: segment, messageID: message.id, baseOrder: tailBase, startOffset: textCursor) {
                items.append((o, b))
            }
        }

        return items.sorted { $0.order < $1.order }.map(\.block)
    }

    // MARK: - 文件引用拆分(块级渲染,消除行内附件黑边)

    /// 媒体扩展名(图片/视频/音频),与 Kit MarkdownView 的
    /// nativeImageExts/nativeVideoExts/nativeAudioExts 保持一致。
    private static let mediaExts: Set<String> = [
        "png","jpg","jpeg","gif","webp","bmp","tiff","svg",
        "mp4","mov","m4v","avi","mkv","webm",
        "mp3","m4a","wav","aac","ogg","flac"
    ]

    /// 是否文件引用:非 http/https 且扩展名为非媒体。
    private static func isFileReference(_ url: String) -> Bool {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return false }
        var path = url
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let f = path.firstIndex(of: "#") { path = String(path[..<f]) }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return !mediaExts.contains(ext)
    }

    /// 语义 URL 归一(2026-08-13:协议统一为 miniclaw://,不再做 scheme 转换)。
    private static func canonicalFileURL(_ url: String) -> String {
        url
    }

    /// 建一个文本块（timelineOrder 写回）。
    /// [T-perf 2026-09-08] **不再在此调用 cacheRenderedContent()**——refresh() 每
    /// 100ms 对全部历史消息 convert，而 bridgedMessage 的签名比对会丢弃 fresh
    ///（签名相同复用 cached）→ 全量 cmark+渲染"算完就丢"，真机实测思考期间
    /// 主线程 190-950ms/次饱和（滑动卡死+发热）。渲染上移到 bridgedMessage：
    /// 仅"签名真变化"的消息（终态合并/新消息入缓存）才渲染一次。
    /// [2026-09-09 改 internal] 流式合并（Bridge upsertTextBlock）也用同款确定性 id
    /// 创建正文块：流式 → 终态块 id 不再换血，diffable 只 reconfigure 不全量重建，
    /// 消除「回复刚结束界面又重放一遍」+ 高度缓存连坐失效。
    static func makeTextBlock(messageID: UUID, startOffset: Int, content: String, order: Double) -> AssistantBlock {
        let b = AssistantBlock(id: deterministicTextBlockID(messageID: messageID, startOffset: startOffset), kind: .text, content: content)
        b.timelineOrder = order
        return b
    }

    /// 把一段 markdown 拆成「文本 + 文件块」交错序列。
    /// 文件引用 = 非媒体扩展名的 markdown 图片/链接(排除 http/https)。
    private static func splitFileBlocks(markdown: String, messageID: UUID, baseOrder: Double, startOffset: Int) -> [(order: Double, block: AssistantBlock)] {
        var out: [(order: Double, block: AssistantBlock)] = []
        let pattern = #"!\[[^\]]*\]\(([^)\s]+)\)|\[[^\]]*\]\(([^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            out.append((baseOrder, makeTextBlock(messageID: messageID, startOffset: startOffset, content: markdown, order: baseOrder)))
            return out
        }
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        var sub = 0
        for m in matches {
            let urlRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            guard urlRange.location != NSNotFound else { continue }
            let url = ns.substring(with: urlRange)
            guard isFileReference(url) else { continue }
            if m.range.location > cursor {
                let text = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let o = baseOrder + Double(sub) * 0.05
                    out.append((o, makeTextBlock(messageID: messageID, startOffset: startOffset + cursor, content: text, order: o)))
                    sub += 1
                }
            }
            let canonical = canonicalFileURL(url)
            let rawName = (canonical as NSString).lastPathComponent
            let fileName = rawName.removingPercentEncoding ?? rawName
            let fb = AssistantBlock(id: deterministicTextBlockID(messageID: messageID, startOffset: startOffset + m.range.location), kind: .file(url: canonical), content: fileName)
            let o = baseOrder + Double(sub) * 0.05
            fb.timelineOrder = o
            out.append((o, fb))
            sub += 1
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let text = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let o = baseOrder + Double(sub) * 0.05
                out.append((o, makeTextBlock(messageID: messageID, startOffset: startOffset + cursor, content: text, order: o)))
            }
        }
        return out
    }

    /// [Fix 重进会话跳屏·方案B] 由 (消息 id + 片段起始偏移) 生成确定性 UUID:
    /// 内容切分稳定时,重进会话重建得到同一 id。偏移 -1 表示尾部正文片段。
    /// [2026-09-09 崩溃修复] 提为 internal:流式 upsert 必须用同一个 id 做幂等
    /// 判定——此前按 timelineOrder 匹配,与确定性 id 不同口径,同一 startOffset
    /// 会生成两个 id 相同、order 不同的块 → diffable 重复 identifier 崩溃。
    static func textBlockID(messageID: UUID, startOffset: Int) -> UUID {
        deterministicTextBlockID(messageID: messageID, startOffset: startOffset)
    }

    private static func deterministicTextBlockID(messageID: UUID, startOffset: Int) -> UUID {
        var h: UInt64 = 1469598103934665603 // FNV-1a 64
        let seed = "\(messageID.uuidString)|\(startOffset)"
        for b in seed.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        // 用哈希值填充 UUID 的 16 字节(前 8 字节 = h,后 8 字节 = 对 h 做一次混淆)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8((h >> (i * 8)) & 0xFF)
        }
        let h2 = h &* 0x9E3779B97F4A7C15 &+ 0x94D049BB133111EB
        for i in 0..<8 {
            bytes[8 + i] = UInt8((h2 >> (i * 8)) & 0xFF)
        }
        // 置 UUID v4 版本位与变体位(保证格式合法)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple = (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                     bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])
        return UUID(uuid: tuple)
    }

    /// 工具名 + 参数 → Kit 块类型(10 种 kind 映射),关联值填入真实操作名/路径/命令,
    /// 让工具卡显示真实操作名称(而非笼统的 "Browser action"/"Shell command")。
    /// 纯函数（无状态依赖）→ nonisolated：服务层（ToolExecution）也可调用。
    nonisolated static func toolKind(_ name: String, arguments: String = "") -> AssistantBlockKind {
        // 从参数 JSON 提取关键字段(command/path/action/url 等),用于关联值展示。
        var argDict: [String: Any] = [:]
        if let data = arguments.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            argDict = dict
        }
        func pick(_ keys: String...) -> String {
            for k in keys {
                if let v = argDict[k] as? String, !v.isEmpty { return v }
            }
            return ""
        }
        switch name {
        case "dispatch_subagent":
            return .subagentTool(action: pick("focus", "task"))
        case "close_subagent":
            return .subagentTool(action: pick("subagent_id", "subagentID", "id"))
        case "shell_execute":
            return .shellTool(command: pick("command", "cmd", "code", "script", "expression"))
        case "file_read":
            return .fileReadTool(path: pick("path", "file", "file_path", "filename"))
        case "file_write":
            return .fileWriteTool(path: pick("path", "file", "file_path", "filename"))
        case "file_edit":
            return .fileEditTool(path: pick("path", "file", "file_path", "filename"))
        case "browser", "miniclaw-browser-use":
            let action = pick("action", "query", "search", "url", "link", "href")
            return .browserTool(action: action)
        case "apple-image":
            return .readImageTool(path: pick("path", "file", "file_path", "filename"))
        case "memory_write", "memory_get":
            return .memoryTool(action: pick("action", "key", "topic", "subject"))
        default:
            return .shellTool(command: pick("command", "cmd"))
        }
    }

    /// 工具状态:执行中(无结果)→ running;完成 → success/failed/cancelled
    static func toolStatus(for event: ToolCallEvent, message: ChatMessage) -> ToolBlockStatus? {
        if event.wasInterrupted { return .cancelled }
        if event.resultText.isEmpty && message.isStreaming {
            return .running
        }
        return event.success ? .success : .failed(message: "")
    }
}
