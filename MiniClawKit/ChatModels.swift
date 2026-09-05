import Combine
import Foundation
import SwiftUI
import UIKit

// MARK: - Models

/// Structured metadata for a user-attached file (image, document, etc.).
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
    /// Context size of the latest API call (input + cache_read + cache_creation).
    public var latestContextTokens: Int = 0

    mutating func add(_ u: LLMUsage) {
        // Use max() instead of += to handle providers that emit cumulative usage
        // on every SSE chunk (e.g. DeepSeek-V4-Flash). With += the final count
        // would be the sum of all intermediate values (0+1+2+...+N ≈ N²/2).
        // max() is correct for both cases:
        // • Provider sends usage only on the last chunk → same as +=, one update
        // • Provider sends incremental cumulative usage each chunk → last (max) value wins
        // • Agent multi-turn (multiple API calls) → each call's input grows, max is correct
        inputTokens = max(inputTokens,u.inputTokens)
        outputTokens = max(outputTokens,u.outputTokens)
        cacheCreationTokens = (u.cacheCreationInputTokens ?? 0)
        cacheReadTokens = (u.cacheReadInputTokens ?? 0)
        latestContextTokens = u.inputTokens
+(u.cacheReadInputTokens ?? 0)
+(u.cacheCreationInputTokens ?? 0)
    }
}

public enum ToolBlockStatus: Equatable {
    case streaming(bytes: Int)
    case running
    case success
    case failed(message: String)
    case cancelled
}

/// A single block within an assistant turn.
public struct InputAttachment: Identifiable {
    public let id: UUID
    public var fileName: String
    /// URL in the app's Caches directory. For a `.loading` placeholder this is a
    /// dummy URL with no file on disk yet; it's replaced when the load finishes.
    public var cacheURL: URL
    public var kind: Kind
    /// Load lifecycle. Photo-library picks insert `.loading` placeholders
    /// immediately, then flip to `.ready` (success) or `.failed` (error) as each
    /// concurrent `loadTransferable` completes. Non-picker attachments are
    /// `.ready` by default so all existing construction sites are unchanged.
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

    /// A loading placeholder shown the instant photos are picked, before bytes
    /// finish loading. `id` is supplied so the async load can find & replace it.
    public static func loadingPlaceholder(id: UUID,kind: Kind) -> InputAttachment {
        InputAttachment(
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
    public let attachments: [InputAttachment]
    public let timestamp = Date()
}

/// Token usage for the current assistant turn.
/// `inputTokens` and `outputTokens` track the **peak** values seen across all
/// SSE chunks and API calls in the turn — using max() rather than summation so
/// that providers emitting cumulative usage on every chunk don't inflate the count.
/// Cache metrics and context size reflect only the **latest** API call, since
/// cumulative cache numbers are misleading in multi-call agent turns.
public enum ChatMessageRole {
    case user
    case assistant
    /// A visual separator showing where context was compacted.
    case compactDivider
    /// Ephemeral UI-only info message (not sent to LLM, not persisted).
    case systemInfo
}

/// Execution status of a tool block.
public struct ToolSnapshotItem: Identifiable {
    public let id: String // toolUseId
    public let toolName: String
    public let snapshot: ToolSnapshot
    public let mediaResolver: (MediaRef) -> URL
}

/// An attachment queued for the next message (stored in Caches).
public final class AssistantBlock: Identifiable,ObservableObject {
    /// 2026-08-11 [Fix 重进会话跳屏·方案B]:id 可由外部指定并跨重建复用——
    /// SwiftData 的 ReasoningSegment/ToolCallEvent 有持久化 id,桥接层重建 block 时
    /// 传入该 id,使 contentKey 稳定 → measuredHeightByContentKey memo 跨会话命中。
    public let id: UUID
    @Published public var kind: AssistantBlockKind
    @Published public var content: String

    // MARK: Thinking block performance (T-thinking-render-perf-ios)

    /// O(1) change counter — incremented on every thinking delta. Deliberately
    /// NOT @Published: as a published property every
    /// token fired objectWillChange, so an EXPANDED thinking block re-ran its
    /// SwiftUI body + animated scrollTo per delta (~60-105/s measured on
    /// iPhone 11) even though `content` only flushes every 0.3s. The view now
    /// keys its scroll/redraw off `content` (flush-paced); this counter stays
    /// as a cheap diagnostic sequence.
    public var contentUpdateSeq: Int = 0

    /// Non-published buffer for thinking content. During streaming the SSE handler
    /// appends here; `@Published content` is only flushed periodically or when the
    /// user expands the block, so collapsed thinking blocks don't trigger per-token
    /// SwiftUI recomposition.
    public var thinkingContentBuffer: String = ""

    // Perf instrumentation: 1s-windowed delta-rate
    // summary + per-flush timing, category "ThinkPerf". Cheap (one Date +
    // counters per delta, one log line per second) so it can stay on in
    // debug builds while reproducing the long-thinking jank report.
    private static let perfLogger = AppLogger(category: "ChatList.Think")
    private var perfWindowStart = Date()
    private var perfDeltaCount = 0
    private var perfDeltaBytes = 0

    public func appendThinkingDelta(_ delta: String) {
        thinkingContentBuffer += delta
        contentUpdateSeq += 1
        perfDeltaCount += 1
        perfDeltaBytes += delta.utf8.count
        let now = Date()
        let dt = now.timeIntervalSince(perfWindowStart)
        if dt >= 1.0 {
            // [T-log-noise-privacy 2026-07-18] info → debug: fires once per
            // second per streaming thinking block for the whole stream.
            Self.perfLogger.debug("[ThinkPerf] deltas/s=\(self.perfDeltaCount) bytes/s=\(self.perfDeltaBytes) bufLen=\(self.thinkingContentBuffer.count) contentLen=\(self.content.count) window=\(String(format: "%.2f", dt))s block=\(self.id.uuidString.prefix(8))")
            perfWindowStart = now
            perfDeltaCount = 0
            perfDeltaBytes = 0
        }
    }

    // Adaptive flush throttle for streaming thinking
    // content. Each flush costs a body re-eval + windowed Text re-layout + a
    // nested animated scrollTo in the EXPANDED view, and that cost grows with
    // rendered content while the user's need for per-word tracking shrinks —
    // past a few K they only care that it's visibly moving. So the flush
    // interval widens with the buffered length. Tiers are a table so they're
    // easy to retune; lengths are characters of thinkingContentBuffer.
    // <1K → 0.3s (short content: responsiveness first, current behavior)
    // 1-3K → 0.6s
    // ≥3K → 1.0s (cap: long content is about overall motion, not word
    // tracking, but 1.0s keeps the tail visibly alive)
    // Collapsed blocks are unaffected either way: deltas only append to the
    // non-published buffer, and the flush this paces merely updates the pill's
    // char counter when collapsed.
    public static let thinkingFlushTiers: [(maxLength: Int,interval: TimeInterval)] = [
        (1_000,0.3),
        (3_000,0.6),
        (Int.max,1.0),
    ]

    /// Flush interval for a thinking buffer of `length` chars (see tier table).
    public static func thinkingFlushInterval(forLength length: Int) -> TimeInterval {
        for tier in thinkingFlushTiers where length<tier.maxLength {
            return tier.interval
        }
        return thinkingFlushTiers[thinkingFlushTiers.count-1].interval
    }

    public func flushThinkingBuffer() {
        guard kind == .thinking,thinkingContentBuffer.count>content.count else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        content = thinkingContentBuffer
        let ms = (CFAbsoluteTimeGetCurrent()-t0)*1000
        // The assign itself is a copy; the real cost lands in the SwiftUI
        // update it triggers. Log both the copy time and the length so slow
        // flushes can be correlated with hitches.
        if ms>4 {
            Self.perfLogger.info("[ThinkPerf] flush SLOW len=\(self.content.count) copy=\(String(format: "%.1f", ms))ms block=\(self.id.uuidString.prefix(8))")
        } else {
            Self.perfLogger.debug("[ThinkPerf] flush len=\(self.content.count) copy=\(String(format: "%.1f", ms))ms")
        }
    }
    /// Status for tool blocks (nil for text blocks).
    @Published public var toolStatus: ToolBlockStatus?
    /// Local file path for an image (e.g. browser screenshot).
    @Published public var imageFilePath: String?
    /// URL associated with browser tool calls (for display in preview).
    @Published public var browserURL: String?
    /// LLM-generated concise description of what this tool call does (5-10 words).
    @Published public var toolSummary: String?
    /// Wall-clock execution duration (display only, not sent to model).
    @Published public var toolDuration: TimeInterval?
    /// Timestamp when tool execution started (internal, for computing duration).
    public var toolStartTime: Date?
    /// True when this tool block was force-finalized
    /// because the app was suspended in the background (the same condition that
    /// drives BackgroundInterruptionTracker's banner: a finite background task
    /// expired with no enhanced-background keep-alive). Distinguishes a genuine
    /// OS-suspension from a normal failure / user cancel so the chat capsule can
    /// surface the yellow ⓘ "enable enhanced background" hint only when relevant.
    @Published public var wasBackgroundSuspended: Bool = false
    /// Cached parsed markdown for completed text blocks.
    @Published public var cachedMarkdown: MarkdownContent?
    /// Cached rendered NSAttributedString for completed text blocks.
    /// Set once when cachedMarkdown is finalized; avoids re-running MarkdownNSRenderer
    /// on every SwiftUI updateUIView triggered by unrelated state changes.
    @Published public var cachedAttributedString: NSAttributedString?
    /// The tool_use ID from the provider, used to match with snapshots.
    public var toolUseId: String?
    /// Serialized JSON of the tool input arguments (for introspection in SessionMemoryView, etc.).
    public var toolInputArgs: String?
    /// 全局时间线序号:流式插入/终态排序用它保持「思考→工具→正文」的真实发生顺序。
    /// 思考段/工具调用为运行时递增序号(Int 转 Double);正文片段为「前一事件 order + 0.5」,
    /// 使正文能穿插在对应思考/工具之后(思考1→工具1→回复1→思考2→工具2→回复2)。
    /// 默认 Int.max-1 表示无时间线信息的正文排最后。
    public var timelineOrder: Double = Double(Int.max - 1)
    /// Streaming file content for file_write tool (live content as it arrives).
    @Published public var streamingFileContent: String?
    /// Whether a thinking block is expanded (persisted across cell reuse).
    @Published public var isThinkingExpanded: Bool = false
    /// True once the user has manually tapped this thinking block's header.
    /// While this is false the view is allowed to auto-expand on stream start
    /// and auto-collapse on stream end; once the user takes control we leave
    /// `isThinkingExpanded` alone so a tap on an earlier (frozen) block can't
    /// be silently undone by a streaming sibling's recomposition.
    @Published public var thinkingUserToggled: Bool = false

    public init(id: UUID = UUID(),kind: AssistantBlockKind,content: String,toolStatus: ToolBlockStatus? = nil,toolUseId: String? = nil) {
        self.id = id
        self.kind = kind
        self.content = content
        self.toolStatus = toolStatus
        self.toolUseId = toolUseId
    }

    /// Concise one-line description for compact tool card display.
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
            // Parse from content: "$ <command>\n..."
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

public final class ChatMessage: Identifiable,ObservableObject {
    public let id: UUID
    public let role: ChatMessageRole
    @Published public var content: String
    /// For assistant turns: ordered list of content blocks (text + tool calls)
    @Published public var blocks: [AssistantBlock] = []
    /// Error that terminated this assistant turn (nil = no error).
    @Published public var error: String?
    /// Number of mid-stream auto-retries that completed successfully before this turn finished.
    /// Shown as a small badge in the UI. Reset to 0 when the user manually retries.
    @Published public var streamInterruptCount: Int = 0
    /// Accumulated token usage for this assistant turn.
    @Published public var usage: TokenUsage?
    /// Structured metadata for user-attached files (images & documents).
    @Published public var attachments: [AttachmentMeta] = []
    /// Raw input attachments for preview before queue drain (cache URLs still valid).
    @Published public var inputAttachments: [InputAttachment] = []
    /// True when all tool calls have completed and we're waiting for the model's next response.
    @Published public var isAwaitingModelResponse = false
    /// 终态状态行（footer）桥接字段：已停止/已中断/任务耗时（宿主消息同步，2026-09-05）。
    @Published public var wasStopped: Bool = false
    @Published public var wasInterrupted: Bool = false
    @Published public var taskElapsedSeconds: Double?
    /// True when this message is queued but not yet injected into the agent loop.
    @Published public var isQueued = false
    /// True if this message is from the compacted history zone (read-only, no actions).
    @Published public var isCompactedHistory = false
    /// True when this compact divider is still loading (LLM generating summary).
    @Published public var isCompactLoading = false
    /// SF Symbol name for systemInfo rows (e.g. "brain.head.profile", "arrow.down.right.and.arrow.up.left").
    public var systemIcon: String?
    /// LLM-generated compact summary (for display in info sheet on compact divider).
    public var compactSummary: String?
    /// sort_order of the FIRST raw message that contributed to this UI message.
    /// Used by Phase 2.5 to locate the compact divider position on reload.
    public var sourceSortOrder: Int?
    /// sort_order of the LAST raw message folded into this UI message. For an
    /// assistant turn that was streamed across multiple raw rows (continuation
    /// blocks appended via the `continuation` path in Phase 2), this differs
    /// from `sourceSortOrder`. compactMarker resolution uses the inclusive
    /// range [sourceSortOrder ... lastSourceSortOrder] when matching a raw
    /// row's sortOrder back to its UI message — without this, an anchor that
    /// landed on a continuation row would fail to resolve and the divider
    /// would slide to the top of the list.
    public var lastSourceSortOrder: Int?
    /// Links back to the QueuedPrompt so we can withdraw it.
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
    /// role-alternation bridge (#579) that must never render as a chat bubble.
    /// The bridge is filtered out of the DB-reload path (loadSession), but a
    /// leak through any OTHER path that pushes into `messages` (e.g. a rebuild
    /// that bypasses that loop) surfaced it in the chat. Filtering at the single
    /// UI collection sink (applySnapshot) using this property catches every
    /// path uniformly. Checks both `content` and a lone text block, since a
    /// leaked bridge may arrive in either shape. Uses the shared bridge-text
    /// set so old- and new-wording bridges are both caught.
    public var isInternalBridge: Bool {
        guard role == .assistant else { return false }
        if RawMessage.isInternalBridgeText(content) { return true }
        // A bridge carried as a single text block with no other content.
        if content.isEmpty,blocks.count == 1,
           case .text = blocks[0].kind,
           RawMessage.isInternalBridgeText(blocks[0].content) {
            return true
        }
        return false
    }
}

/// A user prompt queued while the agent is processing.
public enum KernelStatus: Equatable {
    case notBooted
    case booting
    case booted
    case failed(String)
}

/// A tool snapshot item for UI display in the snapshot bar.
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
    @MainActor
    public func cacheRenderedContent() {
        guard !content.isEmpty else { return }
        if cachedMarkdown == nil {
            cachedMarkdown = MarkdownContent(prepareMarkdownForRender(content))
        }
        if cachedAttributedString == nil {
            cachedAttributedString = autoreleasepool {
                renderMarkdownBlocks(cachedMarkdown!.blocks)
            }
        }
    }
}
