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
    case info
    /// 文件引用(块级):url = 已规范化的 miniclaw:// 源,content = 展示文件名
    case file(url: String)
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

public struct QueuedPrompt: Identifiable {
    public let id = UUID()
    public let text: String
    public let attachments: [RenderAttachment]
    public let timestamp = Date()
}

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

    /// NOT @Published: as a published property every
    public var contentUpdateSeq: Int = 0

    public var thinkingContentBuffer: String = ""

    public func appendThinkingDelta(_ delta: String) {
        thinkingContentBuffer += delta
        contentUpdateSeq += 1
    }

    // Adaptive flush throttle for streaming thinking
    // <1K → 0.3s (short content: responsiveness first, current behavior)
    // 1-3K → 0.6s
    // ≥3K → 1.0s (cap: long content is about overall motion, not word
    // tracking, but 1.0s keeps the tail visibly alive)
    public static let thinkingFlushTiers: [(maxLength: Int,interval: TimeInterval)] = [
        (1_000,0.3),
        (3_000,0.6),
        (Int.max,1.0),
    ]

    public static func thinkingFlushInterval(forLength length: Int) -> TimeInterval {
        for tier in thinkingFlushTiers where length<tier.maxLength {
            return tier.interval
        }
        return thinkingFlushTiers[thinkingFlushTiers.count-1].interval
    }

    public func flushThinkingBuffer() {
        guard kind == .thinking,thinkingContentBuffer.count>content.count else { return }
        content = thinkingContentBuffer
    }
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
    @Published public var cachedMarkdown: MarkdownContent?
    @Published public var cachedAttributedString: NSAttributedString?
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

public enum KernelStatus: Equatable {
    case notBooted
    case booting
    case booted
    case failed(String)
}

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
