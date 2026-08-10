import Foundation
import SwiftUI
import MiniClawKit

// MARK: - 数据桥(2026-08-09)
// 把 MiniClaw 会话数据(SwiftData 消息 + runtime 流式状态)桥接进
// 移植消息列表组件所需的 AIChatViewModel。宿主(ChatView)在
// 数据变化点调用 refresh(),内部按内容指纹节流,避免流式高频重建。

@MainActor
final class MiniClawChatBridge: ObservableObject {
    /// 适配列表直接消费的视图模型
    let vm = MiniClawKit.AIChatViewModel()

    private weak var session: ChatSession?
    private weak var appState: AppState?
    private var lastFingerprint = ""
    /// 流式内容上报的最小间隔(秒):行增长高频触发时合并刷新
    private var lastRefreshAt: Date = .distantPast
    /// OM 对象缓存(按 MiniClaw 持久消息 id):内容签名不变则复用旧对象,
    /// 保持 message.id/block.id 稳定 → 列表高度缓存/contentKey memo 可命中,
    /// 消除每次刷新的全量缓存失效与估算↔实测落差(2026-08-10 滑动跳动/空白根因)。
    private var omCache: [String: MiniClawKit.ChatMessage] = [:]
    /// 当前观察的 runtime(流式实时:SwiftData 消息终态落盘,流式中 content 不变,
    /// 需订阅 runtime.streamingContent 驱动刷新;2026-08-10 切默认路径前接通)。
    private weak var observedRuntime: ChatSessionRuntime?

    func attach(session: ChatSession, appState: AppState) {
        self.session = session
        self.appState = appState
        refresh(force: true)
    }

    /// 数据变化点调用(消息增删/流式增长/工具状态变化)
    func refresh(force: Bool = false) {
        guard let session else { return }

        let sorted = session.messages.sorted { $0.createdAt < $1.createdAt }

        // 运行状态镜像(停止/暂停按钮与 typing 指示器用)——必须在节流判断之前:
        // 流式结束瞬间内容可能不变(指纹相同),但 isResponding 翻转必须同步,
        // 否则思考块 isStreaming 永远为 true,自动折叠永不触发。
        if let runtime = appState?.chatRuntimes[session.id] {
            vm.isProcessing = runtime.isResponding
            vm.canResume = runtime.isPaused
            vm.streamingUIUpdatesSuspended = false
        } else {
            vm.isProcessing = false
            vm.canResume = false
        }

        let messages = sorted.map { omMessage(for: $0) }
        // 指纹纳入思考段与工具状态(同 blocks 数内的状态流转不再被节流吞掉)
        var fp = ""
        for m in messages {
            fp += "\(m.content.count)|\(m.blocks.count)|"
            for b in m.blocks {
                if case .thinking = b.kind {
                    fp += "t:\(b.content.count)|"
                } else if b.toolStatus != nil {
                    fp += "u:\(String(describing: b.toolStatus))|\(b.content.count)|"
                } else {
                    fp += "x|"
                }
            }
        }
        let now = Date()
        let throttled = now.timeIntervalSince(lastRefreshAt) < 0.25 && !force
        if fp == lastFingerprint || (throttled && !force) { return }
        lastFingerprint = fp
        lastRefreshAt = now

        vm.messages = messages
        vm.isLoadingSession = false

        // 流式实时合并(SwiftData 终态落盘,流式中 content 不更新):
        // 把 runtime.streamingContent 合并进最后一条 assistant 消息的
        // content 与最后 text block;若正文尚未出现则追加 text block。
        if let runtime = appState?.chatRuntimes[session.id],
           runtime.isResponding, !runtime.streamingContent.isEmpty,
           let lastAI = messages.last(where: { $0.role == .assistant }) {
            lastAI.content = runtime.streamingContent
            if let tb = lastAI.blocks.last(where: { if case .text = $0.kind { return true }; return false }) {
                tb.content = runtime.streamingContent
            } else {
                let tb = MiniClawKit.AssistantBlock(kind: .text, content: runtime.streamingContent)
                lastAI.blocks.append(tb)
            }
        }

        // 流式观察接管:runtime 对象变化(新建/重建)时重新挂 withObservationTracking
        observeStreamingIfNeeded()
    }

    // MARK: - 流式实时观察(@Observable runtime)

    /// runtime 流式内容变化 → refresh(指纹节流 0.25s 合并)。
    /// SwiftData 消息终态落盘,流式中必须靠此订阅驱动 OM 列表实时刷新。
    private func observeStreamingIfNeeded() {
        guard let runtime = appState?.chatRuntimes[session?.id ?? UUID()] else { return }
        if observedRuntime === runtime { return }
        observedRuntime = runtime
        trackStreaming(runtime)
    }

    private func trackStreaming(_ runtime: ChatSessionRuntime) {
        withObservationTracking {
            _ = runtime.streamingContent
            _ = runtime.isResponding
            _ = runtime.isPaused
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refresh()
                // 重新注册(每次变化后需要重新观察)
                if let rt = self.observedRuntime, rt === runtime {
                    self.trackStreaming(runtime)
                }
            }
        }
    }

    // MARK: - 对象复用(稳定 id)

    /// 按 MiniClaw 持久消息 id 取 OM 对象:内容签名不变则复用缓存对象,
    /// 避免每次 refresh 全量重建 UUID 导致列表高度缓存连坐失效。
    private func omMessage(for model: ChatMessage) -> MiniClawKit.ChatMessage {
        let key = model.id.uuidString
        let fresh = MiniClawChatAdapter.convert(model)
        if let cached = omCache[key], blockSignature(cached) == blockSignature(fresh) {
            return cached
        }
        omCache[key] = fresh
        return fresh
    }

    /// 块级渲染签名(块类型+内容量+工具状态+流式标志):
    /// 签名相同 → 渲染等价 → 可安全复用旧对象(含 block.id/message.id)。
    private func blockSignature(_ om: MiniClawKit.ChatMessage) -> String {
        var s = "\(om.content.count)|\(om.isAwaitingModelResponse)|"
        for b in om.blocks {
            switch b.kind {
            case .thinking: s += "t:\(b.content.count)|"
            case .text: s += "x:\(b.content.count)|"
            default: s += "u:\(String(describing: b.toolStatus)):\(b.content.count)|"
            }
        }
        return s
    }

    /// 发送(复用宿主发送管线,由宿主闭包注入)
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onResume: (() -> Void)?
    var onPause: (() -> Void)?
}
