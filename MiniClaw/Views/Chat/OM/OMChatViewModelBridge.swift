import Foundation
import SwiftUI
import OpenMinisPort

// MARK: - OM 数据桥(2026-08-09)
// 把 MiniClaw 会话数据(SwiftData 消息 + runtime 流式状态)桥接进
// OpenMinis 消息列表组件所需的 AIChatViewModel。宿主(ChatView)在
// 数据变化点调用 refresh(),内部按内容指纹节流,避免流式高频重建。

@MainActor
final class OMChatViewModelBridge: ObservableObject {
    /// OM 列表直接消费的视图模型
    let vm = OpenMinisPort.AIChatViewModel()

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

        let messages = session.messages.map { OMChatAdapter.convert($0) }
        let fp = messages.reduce("") { $0 + "\($1.content.count)|\($1.blocks.count)|" }
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
