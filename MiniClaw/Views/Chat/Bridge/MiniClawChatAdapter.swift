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
    /// 把正文切分点吸附到最近的**轮边界**（轮间分隔符 `"\n\n"` 的起点），仅在 `tolerance`
    /// 字符内吸附。
    ///
    /// [2026-09-15 治本] 切分点来自流式事件的 `position`，而它在**流式期间本质上拿不到权威值**
    /// —— 工具事件的位置要等「下一轮开始 / 终态」才定稿（实测当场取值少 2、偶见 4 = 在途尾
    /// token 数）⇒ 流式中按它切正文会把该轮句尾劈到工具卡之后，下一轮定稿后又自愈
    /// （真机日志实证：`[SplitProbe] pos=29/31` → 终态 `textLens` 恢复整齐）。
    ///
    /// 轮边界是**结构性事实**（每轮正文之间必有分隔符，与取值时机无关）⇒ 以它为准，切分便
    /// 不再依赖 `position` 的精度。偏差超过 `tolerance` 的不吸附：那说明是模型自己在正文里
    /// 换的行，动它反而错。
    /// 返回的 offset 是分隔符**起点**（= 上一轮正文终点；分隔符本身归属下一轮的文本片段）。
    static func snapToRoundBoundary(_ pos: Int, in content: String, tolerance: Int = 6) -> Int {
        guard pos > 0, pos < content.count else { return pos }
        var best = pos
        var bestDist = tolerance + 1
        // 候选 ① **正文末尾**：流式进行中「当前轮」之后**还没有分隔符**，末位就是本轮正文终点。
        //（真机 18:24 实证：`pos=18/20`，此刻唯一的 `\n\n` 在 9、距离 9 > 容差 ⇒ 只认分隔符
        // 会漏吸附，工具卡照旧插进本轮句尾 —— 这正是"吸附了却依然劈句"的原因。）
        if content.count - pos <= tolerance {
            best = content.count
            bestDist = content.count - pos
        }
        // 候选 ② 每个 `\n\n` 的**起点**（= 上一轮正文终点；分隔符本身归属下一轮文本片段）。
        let lo = max(2, pos - tolerance)
        let hi = min(content.count - 2, pos + tolerance)
        if lo <= hi {
            for offset in lo...hi {
                let a = content.index(content.startIndex, offsetBy: offset)
                let b = content.index(a, offsetBy: 1)
                guard b < content.endIndex else { continue }
                if content[a] == "\n", content[b] == "\n" {
                    let d = abs(offset - pos)
                    if d < bestDist { bestDist = d; best = offset }
                }
            }
        }
        return best
    }

    // MARK: - 时间线规划（流式与终态的唯一入口）

    /// 时间线规划的一步：正文片段 或 第 `index` 个事件。
    struct TimelineStep {
        enum Content {
            /// 正文片段。`startOffset` = 它在 content 中的起点（文本块 id 由它派生）。
            case text(startOffset: Int, text: String)
            /// 事件块（思考 / 工具）。`index` = 调用方传入事件的**原始下标**。
            case event(index: Int)
        }
        let content: Content
        /// 排序键：事件前正文片段 = 事件 order − 0.5；事件 = 自身 order；尾部片段 = 最大事件 order + 0.5。
        let order: Double
    }

    /// 把「正文 + 事件」规划为交错的 `TimelineStep` 序列 —— **流式与终态共用的唯一实现**。
    ///
    /// [2026-09-15 收敛] 此前流式（`MiniClawChatBridge`）与终态（本文件 `buildBlocks`）各写一份
    /// 同构拷贝，规则靠注释人工同步 ⇒ 改一处漏一处：治本修复只改了终态那份，流式期仍在劈句
    /// （真机 `[SplitProbe] pos=29/31` 实证）。现在只有这一份，两条路径不可能再漂移。
    ///
    /// 规则：
    /// 1. **事件排序**：order 优先、position 次之；整批无 order（旧数据）时退化按 position，并赋 order = position + 1。
    /// 2. **切分点吸附到轮边界**（`snapToRoundBoundary`）：流式期间事件 position 拿不到权威值
    ///    （要等下一轮/终态定稿），轮边界才是结构性事实 ⇒ 两条路径得到**同一套切分点**。
    /// 3. **游标只前进**：同轮多个事件、或吸附造成的回退，都不会让正文被重复输出。
    /// 4. **order 数值**：片段必须落在 Double 精确区间内 —— 曾用 `Int.max - 1` 作尾部基准，
    ///    该量级精度间隔 2048，`splitFileBlocks` 的 `+0.05*k` 子序被吞 ⇒ 文件块与正文块同 order
    ///    ⇒ 真机「文件指示器总在最终回复上面」。
    static func planTimeline(content: String,
                             events: [(order: Double, position: Int)],
                             identifier: String) -> [TimelineStep] {
        let hasTimeline = events.contains { $0.order > 0 }
        let sorted: [(index: Int, order: Double, position: Int)]
        if hasTimeline {
            sorted = events.enumerated()
                .map { (index: $0.offset, order: $0.element.order, position: $0.element.position) }
                .sorted { $0.order < $1.order || ($0.order == $1.order && $0.position < $1.position) }
        } else {
            sorted = events.enumerated()
                .map { (index: $0.offset, order: Double($0.element.position + 1), position: $0.element.position) }
                .sorted { $0.position < $1.position }
        }

        var steps: [TimelineStep] = []
        var cursor = 0
        for e in sorted {
            let pos = snapToRoundBoundary(min(max(e.position, 0), content.count), in: content)
            // [诊断哨兵] 吸附后仍落在句子中间 = position 偏离轮边界超出容差（正常应为零命中）。
            if pos > 0, pos < content.count {
                let before = content[content.index(content.startIndex, offsetBy: pos - 1)]
                let after = content[content.index(content.startIndex, offsetBy: pos)]
                if before != "\n", after != "\n" {
                    let cut = content.index(content.startIndex, offsetBy: pos)
                    let head = content[content.index(content.startIndex, offsetBy: max(0, pos - 8))..<cut]
                    let tail = content[cut..<content.index(content.startIndex, offsetBy: min(content.count, pos + 8))]
                    AppLogger.shared.warn(
                        "[SplitProbe] 正文被劈开（吸附后仍在句内）pos=\(pos)/\(content.count) order=\(e.order) id=\(identifier) ctx=「\(head)|\(tail)」",
                        category: "Timeline", subsystem: "Bridge")
                }
            }
            if pos > cursor {
                steps.append(TimelineStep(
                    content: .text(startOffset: cursor, text: substring(content, cursor, pos)),
                    order: e.order - 0.5))
            }
            steps.append(TimelineStep(content: .event(index: e.index), order: e.order))
            cursor = max(cursor, pos)
        }
        if cursor < content.count {
            steps.append(TimelineStep(
                content: .text(startOffset: cursor, text: substring(content, cursor, content.count)),
                order: (sorted.map(\.order).max() ?? 0) + 0.5))
        }
        return steps
    }

    /// content 的 `[from, to)` 子串。
    private static func substring(_ content: String, _ from: Int, _ to: Int) -> String {
        let a = content.index(content.startIndex, offsetBy: from)
        let b = content.index(content.startIndex, offsetBy: to)
        return String(content[a..<b])
    }

    private static func buildBlocks(_ message: ChatMessage) -> [AssistantBlock] {
        // 收集事件(思考段 + 工具调用)。排序与正文切分由 `planTimeline` 统一处理。
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

        // [2026-09-15 收敛] 事件排序 + 正文切分全部交给 `planTimeline`（与流式路径**同一实现**），
        // 本函数只负责把规划结果转成块：事件 → 原事件块（回写 order），正文片段 → `splitFileBlocks`。
        let content = message.content
        // [2026-09-09 诊断] position 超界 = 事件 position 与落盘 content 不同源
        //（典型：流式中退出会话，segments/toolCalls 已落盘而 content 滞后）。
        // clamp 会让中间正文段被 cursor 跳过 → 重进会话正文"消失"。
        // 打 warn（低频异常路径）供真机日志一锤定音。
        let overCount = events.filter { $0.position > content.count || $0.position < 0 }.count
        if overCount > 0 {
            AppLogger.shared.warn(
                "[Timeline] position out of range: contentCount=\(content.count) events=\(events.count) over=\(overCount) msgId=\(message.id.uuidString.prefix(8))",
                category: "Timeline", subsystem: "Bridge")
        }
        let items: [(order: Double, block: AssistantBlock)] = planTimeline(
            content: content,
            events: events.map { (order: Double($0.order), position: $0.position) },
            identifier: String(message.id.uuidString.prefix(8))
        ).flatMap { step -> [(order: Double, block: AssistantBlock)] in
            switch step.content {
            case .event(let index):
                let block = events[index].block
                block.timelineOrder = step.order
                return [(step.order, block)]
            case .text(let startOffset, let text):
                return splitFileBlocks(markdown: text, messageID: message.id,
                                       baseOrder: step.order, startOffset: startOffset)
            }
        }
        // [2026-09-13 P4] 末尾排序补 **id 次键**：原为 `$0.order < $1.order`，而 Swift 的
        // `sorted` **不保证稳定** ⇒ order 相等时结果跟实现细节/输入顺序有关（非确定性）。
        // 渲染层（`+Snapshot` 构建 `newRows` 时对 `message.blocks` 的兜底排序）早已是
        // 「order 优先、`id.uuidString` 次之」，两侧必须**同规则** —— 否则同一份 blocks
        // 在两个排序点可以得到不同的显示顺序，且这类不一致极难复现定位。
        return items.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.block.id.uuidString < $1.block.id.uuidString
        }.map(\.block)
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
    /// 同一片段内文件/文本子块的 order 步长。
    ///
    /// [2026-09-13 P4] 原为字面量 `0.05`。它有个**无上界**的缺陷：事件前正文段的基准是
    /// `eventOrder - 0.5`，故当该片段含 **≥5 个文件引用**时 `sub` 会到 10 ⇒
    /// `baseOrder + 10*0.05 == eventOrder` ⇒ 文件块与**紧随其后的思考/工具块 order 相等**。
    /// 此前靠"排序不保证稳定"随机决定先后（本身就是 bug）；本轮给排序补了 `id` 次键后，
    /// 这个相等会被**固定**成一个确定但可能错误的方向 —— 等于把既有建模缺陷固化。
    /// 故把步长缩小到 `0.005`：单片段需 **100 个**子块才会撞到 `eventOrder`（现实中不可能），
    /// 同时仍远大于 Double 在该量级的精度间隔（基准是 `maxEventOrder+0.5` 这种小数量级）。
    private static let splitFileSubStep = 0.005

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
                    let o = baseOrder + Double(sub) * splitFileSubStep
                    out.append((o, makeTextBlock(messageID: messageID, startOffset: startOffset + cursor, content: text, order: o)))
                    sub += 1
                }
            }
            let canonical = canonicalFileURL(url)
            let rawName = (canonical as NSString).lastPathComponent
            let fileName = rawName.removingPercentEncoding ?? rawName
            let fb = AssistantBlock(id: deterministicTextBlockID(messageID: messageID, startOffset: startOffset + m.range.location), kind: .file(url: canonical), content: fileName)
            let o = baseOrder + Double(sub) * splitFileSubStep
            fb.timelineOrder = o
            out.append((o, fb))
            sub += 1
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let text = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let o = baseOrder + Double(sub) * splitFileSubStep
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
        case "browser", "miniclaw_browser_use":
            let action = pick("action", "query", "search", "url", "link", "href")
            return .browserTool(action: action)
        case "apple_image":
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
