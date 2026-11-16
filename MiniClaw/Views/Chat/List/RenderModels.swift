import MiniClawKit
import Combine
import Foundation
import SwiftUI
import UIKit

public enum AssistantBlockKind: Equatable {
    case text
    case thinking
    case shellTool(command: String)
    case fileReadTool(path: String)
    case fileWriteTool(path: String)
    case fileEditTool(path: String)
    case browserTool(action: String)
    case readImageTool(path: String)
    case memoryTool(action: String)
    /// 子代理调用（dispatch_subagent / close_subagent）：action = 展示用摘要
    /// （派发取 focus/task 摘要，关闭取 subagent_id）。
    case subagentTool(action: String)
    /// AI 向用户提问的卡片（`ask_user`）。callId 用于和等待中的请求配对。
    case question(callId: String)
    case info
    /// 文件引用(块级):url = 已规范化的 miniclaw:// 源,content = 展示文件名
    case file(url: String)
}

// MARK: - [Stage 1 · R7] 块类型 → 播种兜底高度 的**唯一来源**
//
// 收口动机：此前这张表在**两处**各自维护、值相同但各自演化——
//   ① `MessageCollectionCoordinator+Heights.swift` 的 `estimateItemHeight`（.assistantBlock 分支）
//   ② `MessageCollectionCoordinator+Snapshot.swift` 的播种 switch（`.readImageTool`/`.file`/`.info`/`default`）
// 任何一处改了另一处漏改，就会出现"同一块在两个路径下算出不同兜底高"的两套口径。
//
// ⚠️ 本函数**只覆盖"播种兜底"这一语义**，不是"块的真实高度"：
//   · `.text` / `.thinking` 有各自更精确的估算路径（见 estimateItemHeight），**不经过本表**；
//   · `.info` 的行数由 `content` 决定，故 `content` 必须传入；其余类型忽略该参数。
extension AssistantBlockKind {
    /// ⚠️ 必须是**实例**方法（`switch self` 切的是枚举值）；写成 `static` 会让 `self` 变成
    /// `AssistantBlockKind.Type` 元类型，`case .readImageTool` 等模式将无法匹配（编译错）。
    /// [治本 2026-09-17] **`.info` 到底会渲染几行 —— 唯一来源。**
    ///
    /// 病根（M21 两轮机）：`.info` 的播种按**原始内容的行数**外推（`20 + n*16`），
    /// 而视图渲染时**只显示 `⚠️` 开头的行**（超过 9 行则折叠为 4+1+4）⇒
    /// 8 行内容可能只渲染 1 行 ⇒ 播种 148 而真值 20.3。**与胶囊同一种病：
    /// 按"原始内容的形状"猜"渲染后的高度"。**
    /// 提取为一处定义后：**视图与播种读同一个函数** ⇒ 不可能漂移；
    /// 且返回值只依赖"过滤规则 + 上限"，不依赖内容长度。
    static func infoDisplayedLines(_ content: String) -> [String] {
        let allLines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let reasonLines = allLines.filter { $0.hasPrefix("⚠️") }
        if reasonLines.count <= 9 { return reasonLines }
        return Array(reasonLines.prefix(4))
            + [String(localized: "⋯ \(reasonLines.count - 8) more")]
            + Array(reasonLines.suffix(4))
    }

    /// `.info` 渲染时**不显示**的那一行（开关/切换说明）—— 同样是一处定义。
    static func infoSwitchedLine(_ content: String) -> String? {
        content.components(separatedBy: "\n")
            .first { !$0.isEmpty && !$0.hasPrefix("⚠️") }
    }

    /// [治本 2026-09-17] **渲染高度由视图作者写死的那些类型，在此声明它的高度（唯一来源）。**
    ///
    /// 为什么必须有这个声明：真机 M21 两轮机证据显示，这类"固定高度"的块被**文本测量**的生产者
    /// 喂过高度 —— 而文本测量量的是**内容文字**，不是胶囊的固定高度。后果两个方向都出：
    ///   · 量成 `2764`（真值 20.3）⇒ **屏上大片空白**（用户截图的形状；同族还有 205/181/120/109/86）；
    ///   · 量成 `20.3`（声明值 36）⇒ 胶囊被**裁切** 16pt。
    /// ⇒ 类型自己声明高度后：**播种值 = 声明值 = 渲染值**（同一个常量），既不可能偏高（无空白），
    /// 也不该被文本测量压低（测量只能"加"不能"减"）。
    ///
    /// 取值依据：`ToolCapsuleView` 的 body 里写着 `.frame(height: 36)`（`AssistantBlockView.swift:147`）
    /// —— 也就是**视图自己的定义**，不是估计值。`nil` = 该类型的高度随内容变化（正文/思考/info 等），
    /// 必须走测量。
    var authoredHeight: CGFloat? {
        switch self {
        case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool,
             .browserTool, .readImageTool, .memoryTool, .subagentTool:
            return 36   // = ToolCapsuleView 的 .frame(height: 36)
        default:
            return nil
        }
    }

    func seedFallbackHeight(content: String) -> CGFloat {
        // [治本] 声明了固定高度的类型：**播种直接取声明值**，不再猜（这样播种不可能偏高）。
        if let authored = authoredHeight { return authored }
        switch self {
        case .readImageTool: return 36
        case .file: return 40
        case .info:
            // [治本 2026-09-17] 由**渲染后的行数**推出：`infoDisplayedLines` 与视图同源。
            // 度量取自视图自身的定义：`.padding(.vertical,7)`（上下各 7）+ 行文本
            // `font(.system(size: 10/11))` 的行高（取 11 → 约 13.5）+ VStack `spacing: 3`。
            // 只算**会被渲染**的行 ⇒ 与内容长度脱钩（旧式 `20 + n*16` 的病根就是按原始行数外推）。
            let lines = max(1, Self.infoDisplayedLines(content).count)
            let lineH = UIFont.systemFont(ofSize: 11).lineHeight   // 与视图 `font(size: 11)` 同源
            return CGFloat(14) + CGFloat(lines) * lineH + CGFloat(max(0, lines - 1)) * 3
        default: return 36 // 其余工具胶囊（execute/browser 等）：无外层 padding
        }
    }
}

public struct AttachmentMeta: Identifiable,Equatable {
    public let id = UUID()
    /// Linux path, e.g. `/var/MiniClaw/attachments/uploads/photo.jpg`
    public let path: String
    public let size: Int
    public let modified: Date

    /// 2026-08-12:显式 public init——自动成员初始化器是 internal,
    /// 宿主(MiniClaw 主工程)无法构造,附件桥接(convert)编译失败。
    public init(path: String, size: Int, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    /// Derive a `miniclaw://` URL from the Linux path.
    public var miniClawURL: String {
        guard path.hasPrefix("/var/miniclaw/") else { return path }
        let rel = String(path.dropFirst("/var/miniclaw/".count))
        return "miniclaw://\(rel)"
    }

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public var isImage: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext)
    }

    public var isVideo: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    public var isAudio: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp3", "m4a", "wav", "aac", "ogg", "flac"].contains(ext)
    }
}

public struct TokenUsage {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var latestContextTokens: Int = 0

    mutating func add(_ u: LLMUsage) {
        // • Provider sends usage only on the last chunk → same as +=, one update
        // • Provider sends incremental cumulative usage each chunk → last (max) value wins
        // • Agent multi-turn (multiple API calls) → each call's input grows, max is correct
        inputTokens = max(inputTokens,u.inputTokens)
        outputTokens = max(outputTokens,u.outputTokens)
        cacheCreationTokens = (u.cacheCreationInputTokens ?? 0)
        cacheReadTokens = (u.cacheReadInputTokens ?? 0)
        latestContextTokens = u.inputTokens
            + (u.cacheReadInputTokens ?? 0)
            + (u.cacheCreationInputTokens ?? 0)
    }
}

public enum ToolBlockStatus: Equatable {
    case streaming(bytes: Int)
    case running
    case success
    case failed(message: String)
    case cancelled
}

public struct RenderAttachment: Identifiable {
    public let id: UUID
    public var fileName: String
    public var cacheURL: URL
    public var kind: Kind
    public var loadState: LoadState

    public enum Kind {
        case image // JPEG/PNG/GIF/WebP
        case video // MP4/MOV/etc.
        case document // PDF or other file
    }

    public enum LoadState: Equatable {
        case ready
        case loading
        case failed
    }

    public init(id: UUID = UUID(),fileName: String,cacheURL: URL,kind: Kind,loadState: LoadState = .ready) {
        self.id = id
        self.fileName = fileName
        self.cacheURL = cacheURL
        self.kind = kind
        self.loadState = loadState
    }

    public static func loadingPlaceholder(id: UUID,kind: Kind) -> RenderAttachment {
        RenderAttachment(
            id: id,
            fileName: "",
            cacheURL: URL(fileURLWithPath: "/dev/null"),
            kind: kind,
            loadState: .loading
        )
    }
}

// [2026-09-13 重构·删除零引用类型] 此处原有 `public struct QueuedPrompt`（id/text/attachments/timestamp），
// 全库引用数 = 1（仅定义处）且**非 Codable**（无法持久化）。线上正在使用的是 `PendingUserMessage`
// （ChatSessionRuntime:9-53：id/text/attachments:[String]/skillName/深链回跳 + Codable +
// decodeIfPresent 向后兼容，存于 `AppState.pendingUserMessages`）—— 更完整且可落盘 ⇒ 删除本类型。

public enum ChatMessageRole {
    case user
    case assistant
    case compactDivider
    case systemInfo
}

public struct ToolSnapshotItem: Identifiable {
    public let id: String // toolUseId
    public let toolName: String
    public let snapshot: ToolSnapshot
    public let mediaResolver: (MediaRef) -> URL
}

public final class AssistantBlock: Identifiable,ObservableObject {
    /// 2026-08-11 [Fix 重进会话跳屏·方案B]:id 可由外部指定并跨重建复用——
    /// SwiftData 的 ReasoningSegment/ToolCallEvent 有持久化 id,桥接层重建 block 时
    /// 传入该 id,使 contentKey 稳定 → measuredHeightByContentKey memo 跨会话命中。
    public let id: UUID
    @Published public var kind: AssistantBlockKind
    @Published public var content: String

    /// 该块是否有**可见**正文（纯空白不算）。
    ///
    /// 2026-11-14 修「流式期凭空空白」：模型在工具调用之间／思考结束时常连发空行，
    /// 形成 content 只含 `\n` 的文本块。旧判据 `!content.isEmpty` 把这类块当成正文渲染，
    /// Markdown 折成 1–2 个空段落 ⇒ 屏上出现 20–42pt 的「莫名其妙空白」
    /// （真机实测空白带 21/42pt，与 M21「播种 40/42/53 → 真值 20.3」吻合）。
    /// 渲染判据、估高判据、可达性判据统一走这里，避免三处各写一份而漂移。
    var hasVisibleText: Bool {
        !displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 清洗结果的进程内缓存（按原文相等性失效）：渲染每帧都会读，不能每帧跑正则。
    private var sanitizedCache: (source: String, result: String)?

    /// **显示用正文**：剔除模型泄漏进正文的协议标记。
    ///
    /// 2026-11-14 真机实证：NeoHorse-1-9B 会把 XML 风格的工具调用语法直接写进 content，
    /// 会话库原文形如 `…」>\n\n</tool_call>\n\n…`，屏上就出现 `</tool_call>`、`/>` 这类
    /// "莫名其妙的字符"。模型侧不可控 ⇒ 在**显示边界**统一清洗；原始 `content` 保持不动
    /// （历史回放 / 复制仍可取到原文）。
    var displayContent: String {
        if let c = sanitizedCache, c.source == content { return c.result }
        let result = ProtocolMarkupSanitizer.sanitize(content)
        sanitizedCache = (content, result)
        return result
    }

    // [Stage 1 · §6.3 A2/A3 链式删除] 此处原有两个成员：
    //   · `public var contentUpdateSeq: Int = 0` —— 全库**零读者**（唯一的写点原本就在下方被删的函数里）；
    //   · `public func appendThinkingDelta(_:)` —— 全库**零调用者**（`git grep -n appendThinkingDelta -- '*.swift' .`
    //     仅命中定义处）。
    // ⚠️ **顺带查出的既存事实（不是本次删除造成的，删除前就已成立）**：`appendThinkingDelta` 是
    // `thinkingContentBuffer` 的**唯一写者**。它零调用 ⇒ `thinkingContentBuffer` **恒为空**
    // ⇒ `flushThinkingBuffer()` 的守卫 `thinkingContentBuffer.count > content.count` 恒假
    // ⇒ 该函数目前是**保证 no-op**（`AssistantBlockView.swift:286-287` 里那次读取同样恒为 0）。
    // 也就是说"思考增量缓冲→节流 flush"这条机制在当前代码里**已经是死的**（正文实际由 Bridge 直写
    // `content`）。此处只删"已证零引用"的两项；`thinkingContentBuffer` / `flushThinkingBuffer`
    // 仍有读取点，属**功能形态**的删除 ⇒ 留待裁决，不擅自扩大范围。

    // [Stage 1 · §6.3 A2/A3 收口 2026-09-17] 此处原有 `thinkingContentBuffer: String` 与
    // `flushThinkingBuffer()`，**本次已删除（用户裁决）**。删除依据（两层证明）：
    //   ① 缓冲的**唯一写者**是 `appendThinkingDelta`，而它全仓零调用（`git grep` 仅命中定义处）
    //      ⇒ 缓冲恒为空 ⇒ `flushThinkingBuffer()` 的守卫 `count > content.count` 恒假 ⇒ **保证 no-op**；
    //   ② 不可能有仓外调用者：`AssistantBlock` **只在 app target 定义**（本文件），
    //      `MiniClawKit` 内无同名类型、也无同名成员。
    // 决策不静默丢弃：这条"思考增量缓冲 → 节流 flush"机制在当前代码里**已被 Bridge 直写 `content` 取代**
    //（见 `MiniClawChatBridge` 的 `existing.content = content`）。若将来要恢复节流写入，
    // 应作为**独立重构**连同度量一起做，而不是把 no-op 的旧壳留在树里冒充"机制在工作"。

    // [Stage 1 · §6.3 A3 链式删除] 此处原有 `thinkingFlushTiers`（4 档阈值表，10 行）与
    // `thinkingFlushInterval(forLength:)`。二者**互相成链且全库零调用**：
    // `git grep -n thinkingFlushInterval -- '*.swift' .` 只命中定义处，而 `thinkingFlushTiers`
    // 的唯一读者就是该函数 ⇒ 一并删除（表中记录的"档位决策"已由 `flushThinkingBuffer` 的
    // 恒 no-op 事实取代，见上）。

    @Published public var toolStatus: ToolBlockStatus?
    /// 工具开始执行的时刻（运行中状态行的实时计时用；恢复路径取事件时间戳）。
    @Published public var commandStartedAt: Date?
    @Published public var imageFilePath: String?
    @Published public var browserURL: String?
    @Published public var toolSummary: String?
    @Published public var toolDuration: TimeInterval?
    public var toolStartTime: Date?
    /// True when this tool block was force-finalized
    @Published public var wasBackgroundSuspended: Bool = false
    /// [Stage 2 · A1] **不再 @Published**：这两个属性是**纯缓存**（渲染结果回写/预渲染），
    /// 写入不应触发 `objectWillChange` → `body` 重算。作为 `@Published` 时，
    /// `onRendered` 回调（`MarkdownView.sizeThatFits` 内）每次写入都会引发 4 处
    /// `@ObservedObject` 的 `body` 重算 → 4 个新的 `MarkdownView` → 4 次 `updateUIView`
    /// → 构成"布局↔渲染"反馈环（实测 `Publishing changes from within view updates` fault）。
    /// 消费方全部通过**直接属性读**获取值（`AssistantBlockView:686-687`、`Snapshot:519/:753`、
    /// `Heights:366` 等），不依赖 `@Published` 触发。
    /// 同类先例：`contentUpdateSeq`（`:161`）与 `cachedAttrFingerprint`（`:211`）同为非 `@Published`。
    public var cachedMarkdown: MarkdownContent?
    public var cachedAttributedString: NSAttributedString?
    /// [2026-09-09 截短锁死修复] 上面缓存对应的内容指纹（写入时
    /// `ContentFingerprint.of(content)`，非 @Published——纯内部簿记，不驱动 UI）。
    /// 采用方（MarkdownView prebuilt
    /// 路径）与回写方（AssistantBlockView.onRendered 覆盖式回写）据它判断
    /// 「缓存是否对应当前内容」。无此校验时，流式中工具挂载让块提前被当终态
    /// 回写的**缺尾包中间态**会被 prebuilt 路径永久锁死（正文显示截短且
    /// 滑动/复用均不恢复，真机 IMG_4605）。
    public var cachedAttrFingerprint: Int?
    public var toolUseId: String?
    public var toolInputArgs: String?
    /// 全局时间线序号:流式插入/终态排序用它保持「思考→工具→正文」的真实发生顺序。
    /// 思考段/工具调用为运行时递增序号(Int 转 Double);正文片段为「前一事件 order + 0.5」,
    /// 使正文能穿插在对应思考/工具之后(思考1→工具1→回复1→思考2→工具2→回复2)。
    /// 默认 Int.max-1 表示无时间线信息的正文排最后。
    public var timelineOrder: Double = Double(Int.max - 1)
    @Published public var streamingFileContent: String?
    @Published public var isThinkingExpanded: Bool = false
    @Published public var thinkingUserToggled: Bool = false

    public init(id: UUID = UUID(),kind: AssistantBlockKind,content: String,toolStatus: ToolBlockStatus? = nil,toolUseId: String? = nil) {
        self.id = id
        self.kind = kind
        self.content = content
        self.toolStatus = toolStatus
        self.toolUseId = toolUseId
    }

    public var toolDescription: String {
        // 2026-08-10 用户要求:所有工具指示器显示具体操作名称。
        // 工具调用参数 JSON 里有 activity 字段(引擎专用于 UI 展示,熔断签名忽略它),
        // 优先取它作为操作名——例如 browser 工具显示「打开 xxx」、shell 显示具体命令描述。
        if let args = toolInputArgs,
           let data = args.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let act = obj["activity"] as? String, !act.isEmpty {
            return act
        }
        switch kind {
        case .text,.thinking:
            return ""
        case .question:
            // [2026-11-16 23:14] 之前这里固定返回空串 ⇒ 工具没带 activity、或
            // 引擎摘出的 summary 为空时，指示器只剩一个图标没有标题（真机第二次提问复现）。
            // 现在从提问载荷里自取标题：header → 首题文本 → 兜底文案，保证永不为空。
            if let req = UserQuestionRequest.decode(from: content) {
                if let h = req.questions.first?.header, !h.isEmpty { return h }
                if let q = req.questions.first?.question, !q.isEmpty {
                    return String(q.prefix(24))
                }
            }
            return String(localized: "ask_user_title")
        case .file(let url):
            return (url as NSString).lastPathComponent
        case .shellTool(let command):
            if !command.isEmpty { return command }
            if content.hasPrefix("$ ") {
                let firstLine = content.prefix(while: { $0 != "\n" })
                return String(firstLine.dropFirst(2))
            }
            return "Shell command"
        case .browserTool(let action):
            if !action.isEmpty { return action }
            if content.hasPrefix("Browser: ") {
                let firstLine = content.prefix(while: { $0 != "\n" })
                return String(firstLine.dropFirst(9))
            }
            return "Browser action"
        case .fileReadTool(let path):
            let name = (path as NSString).lastPathComponent
            return (!path.isEmpty && name != "/" && name.contains(".")) ? name : "Read file"
        case .fileWriteTool(let path):
            let name = (path as NSString).lastPathComponent
            return (!path.isEmpty && name != "/" && name.contains(".")) ? name : "Write file"
        case .fileEditTool(let path):
            let name = (path as NSString).lastPathComponent
            return (!path.isEmpty && name != "/" && name.contains(".")) ? name : "Edit file"
        case .readImageTool(let path):
            let name = (path as NSString).lastPathComponent
            return (!path.isEmpty && name != "/" && name.contains(".")) ? name : "Read image"
        case .memoryTool(let action):
            return action.isEmpty ? "Memory" : action
        case .subagentTool(let action):
            return action.isEmpty ? "Subagent" : action
        case .info:
            return ""
        }
    }
}

public final class RenderMessage: Identifiable,ObservableObject {
    public let id: UUID
    public let role: ChatMessageRole
    @Published public var content: String
    @Published public var blocks: [AssistantBlock] = []
    @Published public var error: String?
    @Published public var streamInterruptCount: Int = 0
    @Published public var usage: TokenUsage?
    @Published public var attachments: [AttachmentMeta] = []
    @Published public var inputAttachments: [RenderAttachment] = []
    @Published public var isAwaitingModelResponse = false
    /// 终态状态行（footer）桥接字段：已停止/已中断/任务耗时（宿主消息同步，2026-09-05）。
    @Published public var wasStopped: Bool = false
    @Published public var wasInterrupted: Bool = false
    @Published public var taskElapsedSeconds: Double?
    @Published public var isQueued = false
    @Published public var isCompactedHistory = false
    @Published public var isCompactLoading = false
    public var systemIcon: String?
    public var compactSummary: String?
    public var sourceSortOrder: Int?
    public var lastSourceSortOrder: Int?
    public var queuedPromptId: UUID?
    public let timestamp = Date()

    public init(role: ChatMessageRole,content: String,blocks: [AssistantBlock] = [],isQueued: Bool = false,id: UUID = UUID()) {
        self.id = id
        self.role = role
        self.content = content
        self.blocks = blocks
        self.isQueued = isQueued
    }

    /// True when this UI message is the internal
    public var isInternalBridge: Bool {
        guard role == .assistant else { return false }
        if RawMessage.isInternalBridgeText(content) { return true }
        if content.isEmpty,blocks.count == 1,
           case .text = blocks[0].kind,
           RawMessage.isInternalBridgeText(blocks[0].content) {
            return true
        }
        return false
    }
}

// [2026-09-13 重构·删除零引用类型] 此处原有 `public enum KernelStatus`（notBooted/booting/booted/failed(String)），
// 全库引用数 = 1（仅定义处）。线上正在使用的是 `BootPhase` + `RuntimeStatusSnapshot`
//（RuntimeStatus.swift:45-114：idle/prewarming/booted/failed + 颜色/符号 + runtimeDetail +
// errorMessage，与 C 侧 `MiniClawiSHBootState` 对齐）—— 语义更全、更贴底层 ⇒ 删除本类型。

// MARK: - 高度预渲染缓存（Fix 重进会话跳屏·根因）

extension AssistantBlock {
    /// [Fix 重进会话跳屏·根因] 为完成的 text block 预渲染 NSAttributedString,
    /// 移植自 MessageListModel.cacheAttributedString(for:) 的等价逻辑:
    /// cachedMarkdown 持久化解析结果(复用避免重解析),cachedAttributedString 用
    /// 真实渲染引擎 MarkdownNSRenderer 生成最终字符串。
    ///
    /// applySnapshot 的 TextKit 精确 precalc 分支(`if let attrStr = block.cachedAttributedString`)
    /// 依赖它——否则 text block 首帧只能走字符数启发式 estimateTextBlockHeight
    /// (误差 ±13-52pt,CJK 内容达 -50%),真实 self-size 后大修正 → 滚动/重进跳屏。
    /// 赋值后:重进会话首帧即精确高度,零跳屏(与原版行为一致)。
    ///
    /// 必须在 MainActor 上下文调用(渲染引擎依赖字体设置)。
    /// [T-perf 2026-09-08] 接入进程级统一缓存（MarkdownRenderCache，LRU 1024）：
    /// ① 命中（第二次进入同会话）→ 零渲染直接复用——修复"所有会话进入白屏一秒"
    ///（后台渲染方案对大会话快、但对多数小会话引入白屏闪烁，已回退为同步）；
    /// ② 渲染后回写统一缓存 → 下次进入同会话零成本。**附件块不入统一缓存**
    ///（attachment 与 renderer 身份耦合，prebuilt 路径有 prebuiltHasTable 同款守卫）。
    /// 是否含会产生 NSTextAttachment 的语法（2026-09-08 收口为**唯一实现**）。
    /// 覆盖：``` 代码块 / | 表格 / ![ 图片 / $$ 公式 / [audio][video][file] /
    /// --- 分隔线（ThematicBreakAttachment，此前三份清单**全部漏掉**）。
    /// 用途：判断该块的渲染结果能否安全进「进程级统一缓存」——附件实例与
    /// renderer/视图上下文身份耦合，共享会串味。
    public static func hasRichSyntax(_ content: String) -> Bool {
        content.contains("```")
            || content.contains("|")
            || content.contains("![")
            || content.contains("$$")
            || content.contains("[audio]") || content.contains("[video]") || content.contains("[file]")
            || content.contains("\n---") || content.hasPrefix("---")
    }

    /// **「含富文本附件」的统一判据**（2026-09-13 收口）＝ 源文启发式 **OR** 产物判据。
    ///
    /// 为什么必须两者取或：
    ///   - 只信源文启发式 `hasRichSyntax`：它是**已知语法清单**，parser 一旦新增附件类型
    ///     （例如行内 `$...$` 数学，见 `hasRenderableContent` 处的注释）就会**漏判** ⇒ 放行
    ///     到「CT 快路径 / 进程级共享缓存」而 CTFramesetter **不调用 `attachmentBounds`** ⇒
    ///     高度失真、且含附件的渲染产物进共享缓存会串味（附件实例与 renderer 身份耦合）。
    ///   - 只信产物判据 `hasAnyAttachment`：**必须先有渲染产物**才能问，无法在"还没渲染、
    ///     正决定要不要付出渲染代价"的分派点上使用。
    ///   ⇒ 取或 = 有产物时用产物兜住新类型，无产物时退回保守的源文启发式。
    ///
    /// 全库原来有 **3 处**各自拼这个判据（`+Snapshot` 缓存串味、`Snapshot` 种子分派、
    /// `+Heights` 用户气泡分派），其中一处还是**残缺版**（只查 ``` 与 `|`）。现收敛到此处。
    /// - Parameter rendered: 已有的渲染产物；`nil` 表示"尚无产物，只能靠源文启发式"。
    public static func hasRichSyntaxOrAttachment(_ content: String,
                                                 rendered: NSAttributedString? = nil) -> Bool {
        hasRichSyntax(content) || (rendered?.hasAnyAttachment ?? false)
    }

    /// 已渲染结果是否**对应当前内容**（内容指纹一致），可直接用于高度计算。
    ///
    /// [2026-09-11 尾部行裁切修复] 陈旧 attr = 旧内容的渲染产物，其高度系统性偏小；
    /// 用于播种/精确 precalc 会裁掉尾部行，还会以「当前内容」为 key 毒化进程级统一
    /// 高度缓存（重进会话继续命中）。渲染侧 prebuilt 采用点早已用同一指纹校验
    /// （cachedAttrFingerprint），此处收口为单一事实源，供高度侧共用同一判据。
    public var hasFreshRenderedContent: Bool {
        guard let attr = cachedAttributedString, attr.length > 0 else { return false }
        return cachedAttrFingerprint == ContentFingerprint.of(content)
    }

    @MainActor
    public func cacheRenderedContent() {
        guard !content.isEmpty else { return }
        // [2026-09-11 尾部行裁切修复] 「追赶内容」——旧实现只在 cachedAttributedString
        // == nil 时渲染，于是**流式期写入的中间态渲染结果永久滞留**：内容继续增长到
        // 终值后块缓存仍指向旧内容，高度侧（applySnapshot 精确 precalc /
        // estimateItemHeight）按旧内容算高 → 系统性矮值 → 播种矮高度 → 尾部行被裁；
        // 矮值还会以「当前内容」为 key 写进统一高度缓存，重进会话继续命中
        //（会话结束后 + 重进会话两个场景都复现，真机 IMG_4660/4661）。
        // 判据与渲染侧 prebuilt 采用点同源（cachedAttrFingerprint）。
        guard !hasFreshRenderedContent else { return }
        let fontSize = FontSettings.shared.scaledMessage(16.5)
        let hasAttachmentSyntax = Self.hasRichSyntax(content)
        let cacheKey = hasAttachmentSyntax ? nil : MarkdownRenderCache.key(for: content, fontSize: fontSize)
        // 内容已变化 → 解析结果一并失效，必须重解析（旧实现只在 nil 时建，同样滞留）。
        cachedMarkdown = MarkdownContent(prepareMarkdownForRender(content))
        if let cacheKey,
           let cached = MarkdownRenderCache.shared.cachedAttributed(for: cacheKey),
           cached.length > 0 {
            // 统一缓存命中：跳过 cmark 解析 + 全量渲染（第二次进入零成本）。
            // [2026-09-09] 空 att 不采用（历史污染/defer 空产物），落走正常渲染。
            cachedAttributedString = cached
            cachedAttrFingerprint = ContentFingerprint.of(content)
            return
        }
        cachedAttributedString = autoreleasepool {
            renderMarkdownBlocks(cachedMarkdown!.blocks)
        }
        cachedAttrFingerprint = ContentFingerprint.of(content)
        // [2026-09-13 缓存串味修复] 结构判据兜底：源文启发式 `hasRichSyntax` 只查 `$$`，
        // **漏判行内 `$...$`**（MiniClawMarkdownParser 会为它产出 MathAttachment）⇒ 会把
        // 带附件的渲染产物放行进进程级共享缓存（附件实例与 renderer/视图上下文身份耦合，
        // 共享即串味；且 store 首写胜出，进会话时的本函数通常先写 = 投毒）。故对**渲染
        // 产物本身**再判一次 `hasAnyAttachment`，与 MarkdownView 的写入口径统一。
        if let cacheKey, let attr = cachedAttributedString, !attr.hasAnyAttachment {
            MarkdownRenderCache.shared.store(attributed: attr, key: cacheKey)
        }
    }

}

extension RenderMessage {
    /// footer 是否将渲染任何块内容（与 BridgedAssistantFooter.hasVisibleContent
    /// 同口径：text 块需非空，其余任意块即算可见）。
    var footerHasVisibleContent: Bool {
        blocks.contains { block in
            if case .text = block.kind { return !block.content.isEmpty }
            return true
        }
    }

    /// footer 是否会渲染终态 quiet 状态行（已完成/已停止/已中断 + 耗时）。
    /// 与 BridgedAssistantFooter.body 的分支一一对应（error==nil 且非恢复态时，
    /// 按 wasStopped/wasInterrupted/有可见内容三选一渲染 caption 状态行，~18pt）。
    /// 种子循环用它把 footer 估高对齐渲染现实——4pt 种子 vs 18pt 实高是
    /// 重进会话上滑抖动的主误差源（2026-09-06 修复方案 A）。
    var footerShowsQuietStatusRow: Bool {
        error == nil && (wasStopped || wasInterrupted || footerHasVisibleContent)
    }
}

// MARK: - 协议标记清洗（显示边界）

/// 剔除模型泄漏进正文的工具调用协议残留。
///
/// 背景：部分模型（真机实证 NeoHorse-1-9B）用 XML 风格表达工具调用
/// （`<tool_call>{"name":…}</tool_call>`），偶发把这些标签写进 `content` 而不是
/// 结构化 `tool_calls`。这些标签对用户没有意义，必须从**显示**里去掉。
///
/// 设计边界：
/// - 只清「协议标记」与它们留下的**纯标点残行**，不碰正文；
/// - 原文不改（见 `AssistantBlock.displayContent`），历史/复制仍可追溯；
/// - 纯标点残行只在本次确实命中过协议标记时才清，避免误删正常代码块里的符号行。
enum ProtocolMarkupSanitizer {

    /// 成对块：`<tool_call …> … </tool_call>`（含换行）
    private static let blockPattern = try! NSRegularExpression(
        pattern: #"<\s*tool_calls?\b[^>]*>[\s\S]*?<\s*/\s*tool_calls?\s*>"#,
        options: [.caseInsensitive]
    )
    /// 孤立开/闭标签：tool_call(s) / function_call(s) / tool_use / tool_result
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<\s*/?\s*(?:tool_calls?|function_calls?|tool_use|tool_result)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    /// 特殊 token：`<|im_start|>`、`<|im_end|>`、`<|endoftext|>`、`<|tool_call|>` 等
    private static let specialTokenPattern = try! NSRegularExpression(
        pattern: #"<\|[A-Za-z0-9_./\-]+\|>"#
    )
    /// 纯标点残行（长度 ≤4 且只由这些字符组成）
    private static let punctuationSet = Set("{}[]()<>\"'`”’「」『』:;,、~-_=+*/\\")

    static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        if !text.contains("<") && !text.contains("|") { return text }

        var result = text
        var matched = false
        for regex in [blockPattern, tagPattern, specialTokenPattern] {
            let range = NSRange(result.startIndex..., in: result)
            if regex.firstMatch(in: result, options: [], range: range) != nil {
                matched = true
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }
        guard matched else { return text }

        // 残留的纯标点行（如 `」>`、`}>`）随协议块一起清掉
        var lines = result.components(separatedBy: "\n")
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t.count <= 4 && t.allSatisfy { punctuationSet.contains($0) }
        }
        result = lines.joined(separator: "\n")

        // 折叠被协议块撕开的大段空行
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
