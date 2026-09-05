import Foundation
import MiniClawKit

/// 工具执行上下文（直接引用架构）：内持 AssistantBlock 引用，
/// 参数流式/执行中输出/结果落定全部由执行逻辑直接写到 block 上，
/// 经 @Published 驱动指示器与浮层实时刷新——不存在事件转换层与 id 配对。
/// 相比「事件广播 + id 配对」，直接持有 block 引用天然免疫索引失效与重复事件。
final class ToolExecution: @unchecked Sendable {
    let block: MiniClawKit.AssistantBlock
    let name: String
    let callID: String
    let startedAt: Date
    private(set) var argsJSON: String
    private(set) var result: ToolResult?
    private(set) var duration: TimeInterval = 0
    /// 用户停止整条回复时该执行仍 in-flight 被中断（落盘语义，对应 ToolCallEvent.wasInterrupted）。
    private(set) var wasInterrupted = false
    /// 挂载时由宿主填写（正文中的字符位置，用于卡片内联穿插）。
    var position: Int = 0

    /// 输出行缓冲与节流（流式输出高频，合并后回主线程写 block）。
    private var outputLineBuffer: [String] = []
    private var lastOutputFlush = Date.distantPast

    init(name: String, callID: String, startedAt: Date = Date()) {
        self.name = name
        self.callID = callID
        self.startedAt = startedAt
        self.argsJSON = ""
        self.block = MiniClawKit.AssistantBlock(
            id: UUID(),
            kind: MiniClawChatAdapter.toolKind(name),
            content: "",
            toolStatus: .streaming(bytes: 0),
            toolUseId: callID
        )
        block.commandStartedAt = startedAt
    }

    // MARK: - 参数流式（AI 正在生成参数）

    /// SSE 参数增量（LLMClient 层已按 0.15s 节流）：卡片实时显示主参数的已生成部分。
    func appendArgsDelta(_ delta: String) {
        argsJSON += delta
        block.toolInputArgs = argsJSON
        block.toolStatus = .streaming(bytes: argsJSON.utf8.count)
        if let primary = ToolStreamingParser.primaryPartialValue(name: name, partialJSON: argsJSON) {
            block.content = primary
            if isFileStreamingKind { block.streamingFileContent = primary }
        }
    }

    // MARK: - 执行

    /// 参数定稿、开始执行：kind 按完整参数刷新（file 类补 path 关联值）。
    func beginExecution(argsJSON: String) {
        self.argsJSON = argsJSON
        block.toolInputArgs = argsJSON
        block.kind = MiniClawChatAdapter.toolKind(name, arguments: argsJSON)
        // 2026-09-05 修复：终端视图以 content 作为「输出」渲染（含 ToolLiveSheet 黑框）。
        // 此前把参数 JSON 写进 content，导致执行期间终端显示的是参数回显而非真实输出。
        // 参数已在 toolInputArgs 单独呈现，content 清空等待真实输出流入。
        block.content = ""
        block.toolStatus = .running
        block.streamingFileContent = nil
    }

    /// 执行中过程输出（逐行，内部节流合并后回主线程写 block）。
    func appendOutputLine(_ line: String) {
        outputLineBuffer.append(line)
        let now = Date()
        let interval: TimeInterval = block.content.utf8.count < 1_000 ? 0.3 : 0.6
        guard now.timeIntervalSince(lastOutputFlush) >= interval else { return }
        lastOutputFlush = now
        let text = outputLineBuffer.joined(separator: "\n")
        outputLineBuffer.removeAll()
        Task { @MainActor [block] in
            if block.content.hasSuffix("Executing...") || block.content.isEmpty {
                block.content = text
            } else {
                block.content += "\n" + text
            }
            if block.content.count > 30_000 {
                block.content = "…[output truncated]…\n" + String(block.content.suffix(30_000))
            }
        }
    }

    // MARK: - 结果落定

    /// 结果落定回调（直接引用架构：宿主按需挂载，如子代理事件转发）。
    /// 在 finish() 调用点同步触发（引擎隔离域），与旧事件回调的投递时机一致。
    var onFinish: ((ToolResult, TimeInterval) -> Void)?

    /// 用户停止整条回复时标记中断（仅对尚未返回结果的执行生效，与旧 stopGeneration 语义一致）。
    func markInterrupted(text: String, at stoppedAt: Date) {
        guard result == nil else { return }
        wasInterrupted = true
        finish(ToolResult(success: false, text: text), duration: stoppedAt.timeIntervalSince(startedAt))
    }

    /// 断点恢复：从落盘事件重建执行上下文（round-trip 对应 toEvent）。
    /// 恢复场景必须经 `registerStreamingToolExecution` 挂载以回填 order 字典。
    convenience init(restoring event: ToolCallEvent) {
        // 注册表按 callID 幂等去重；ToolCallEvent.callID 为 Optional（默认 nil），
        // 旧落盘数据可能整批缺失。缺失时生成唯一值，避免多条工具卡被判定为同一条
        // 而只挂载第一条、其余全部丢失。
        let resolvedCallID: String
        if let existing = event.callID, !existing.isEmpty {
            resolvedCallID = existing
        } else {
            resolvedCallID = UUID().uuidString
        }
        self.init(name: event.name, callID: resolvedCallID, startedAt: event.timestamp)
        argsJSON = event.arguments
        result = ToolResult(success: event.success, text: event.resultText)
        duration = event.duration ?? 0
        wasInterrupted = event.wasInterrupted
        position = event.position
        block.toolInputArgs = event.arguments
        block.kind = MiniClawChatAdapter.toolKind(event.name, arguments: event.arguments)
        block.content = event.resultText
        block.toolDuration = event.duration ?? 0
        block.commandStartedAt = event.timestamp
        // 还原中断态：wasInterrupted → .cancelled（黄色），与 .failed（红色）区分。
        block.toolStatus = event.wasInterrupted ? .cancelled : (event.success ? .success : .failed(message: ""))
    }

    func finish(_ result: ToolResult, duration: TimeInterval) {
        self.result = result
        self.duration = duration
        // 被用户停止的执行走 .cancelled（黄色「已取消」），与 .failed（红色「失败」）区分。
        let isCancelled = wasInterrupted
        Task { @MainActor [block, isCancelled] in
            block.content = result.text
            block.toolDuration = duration
            block.toolStatus = isCancelled ? .cancelled : (result.success ? .success : .failed(message: ""))
            block.streamingFileContent = nil
        }
        onFinish?(result, duration)
    }

    private var isFileStreamingKind: Bool {
        switch block.kind {
        case .fileWriteTool, .fileEditTool: return true
        default: return false
        }
    }

    // MARK: - 落盘

    /// 转持久化事件（position/timelineOrder 由宿主在挂载时分配）。
    func toEvent(position: Int, timelineOrder: Int) -> ToolCallEvent {
        ToolCallEvent(
            name: name,
            callID: callID,
            arguments: argsJSON,
            resultText: result?.text ?? "",
            success: result?.success ?? false,
            wasInterrupted: wasInterrupted,
            timestamp: startedAt,
            position: position,
            duration: duration,
            timelineOrder: timelineOrder
        )
    }
}
