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

    func attach(session: ChatSession, appState: AppState) {
        self.session = session
        self.appState = appState
        refresh(force: true)
    }

    /// 数据变化点调用(消息增删/流式增长/工具状态变化)
    func refresh(force: Bool = false) {
        guard let session else { return }

        let sorted = session.messages.sorted { $0.createdAt < $1.createdAt }
        let messages = sorted.map { MiniClawChatAdapter.convert($0) }
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

        // 运行状态镜像(停止/暂停按钮与 typing 指示器用)
        if let runtime = appState?.chatRuntimes[session.id] {
            vm.isProcessing = runtime.isResponding
            vm.canResume = runtime.isPaused
            vm.streamingUIUpdatesSuspended = false
        } else {
            vm.isProcessing = false
            vm.canResume = false
        }
        vm.isLoadingSession = false
    }

    /// 发送(复用宿主发送管线,由宿主闭包注入)
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onResume: (() -> Void)?
    var onPause: (() -> Void)?
}
