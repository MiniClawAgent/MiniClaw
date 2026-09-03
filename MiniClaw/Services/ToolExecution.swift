import Foundation
import MiniClawKit

/// 工具执行上下文（直接引用架构）：内持 AssistantBlock 引用，
/// 参数流式/执行中输出/结果落定全部由执行逻辑直接写到 block 上，
/// 经 @Published 驱动指示器与浮层实时刷新——不存在事件转换层与 id 配对。
/// （方法借鉴 OpenMinis「执行中直接写 block」的思路，实现为 MiniClaw 自有代码。）
final class ToolExecution: @unchecked Sendable {
    let block: MiniClawKit.AssistantBlock
    let name: String
    let callID: String
    let startedAt: Date
    private(set) var argsJSON: String
    private(set) var result: ToolResult?
    private(set) var duration: TimeInterval = 0
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
        block.content = argsJSON
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

    func finish(_ result: ToolResult, duration: TimeInterval) {
        self.result = result
        self.duration = duration
        Task { @MainActor [block] in
            block.content = result.text
            block.toolDuration = duration
            block.toolStatus = result.success ? .success : .failed(message: "")
            block.streamingFileContent = nil
        }
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
            wasInterrupted: false,
            timestamp: startedAt,
            position: position,
            duration: duration,
            timelineOrder: timelineOrder
        )
    }
}
