import SwiftUI
import UIKit
import Combine
import Foundation

extension MessageCollectionView.Coordinator {

        func subscribeToLastMessage(_ message: RenderMessage?) {
            guard let message,message.id != lastMessageId else { return }
            lastMessageId = message.id
            lastMessageSub?.cancel()
            lastMessageBlockCountSub?.cancel()

            guard vm?.isProcessing == true else { return }

            lastMessageSub = message.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    guard self.vm?.isProcessing == true else {
                        AppLogger.shared.info("[StreamSub] END — isProcessing=false, cancelling subs, final flush. pendingLayout=\(self.pendingStreamingLayout != nil) tracking=\(self.viewController?.collectionView?.isTracking ?? false) decel=\(self.viewController?.collectionView?.isDecelerating ?? false)", category: "ChatList.Stream")
                        self.lastMessageSub?.cancel()
                        self.lastMessageSub = nil
                        self.lastMessageBlockCountSub?.cancel()
                        self.lastMessageBlockCountSub = nil
                        self.flushStreamingLayout()
                        // Terminal
                        // `pendingSnapshotFlag = true` without rebuilding the
                        // snapshot is actually pending. Gated on NOT-suspendedFlag:
                        // if we're still suspendedFlag we leave `pendingSnapshotFlag`
                        AppLogger.shared.info("[SnapQueue] STREAM-END terminal rescue check — pendingSnapshotFlag=\(self.pendingSnapshotFlag) suspendedFlag=\(self.vm?.streamingUIUpdatesSuspended == true)", category: "ChatList.SnapQueue")
                        if self.pendingSnapshotFlag,self.vm?.streamingUIUpdatesSuspended != true {
                            self.flushPendingSnapshotIfNeeded(caller: "stream-end")
                        } else if self.pendingSnapshotFlag {
                            // Still suspendedFlag at stream-end: cannot safely apply here.
                            // This is the key symptom line:
                            AppLogger.shared.warning("[SnapQueue] ⚠️ STREAM-END left pending (still suspendedFlag) — content in DB, UI frozen until suspend-resume (or next openSession clears it)", category: "ChatList.SnapQueue")
                        }
                        // [2026-11-20] 无论挂起与否，终态都要把最后一条的高度按**最终内容**重测一次，
                        // 否则末行永远停在流式早期的矮高度（真机：cellH=1143 / textNeed=1210）。
                        self.remeasureLastAssistantBlocks(reason: "stream-end")
                        return
                    }
                    self.flushStreamingLayout()
                }

            lastMessageBlockCountSub = message.$blocks
                .map(\.count)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .dropFirst()
                .sink { [weak self] count in
                    guard let self,let msgs = self.vm?.messages else { return }
                    if self.vm?.streamingUIUpdatesSuspended == true {
                        // [SnapQueue] Deferring snapshot rebuild while suspendedFlag;
                        AppLogger.shared.info("[SnapQueue] DEFER blockCount=\(count) — suspendedFlag, set pendingSnapshotFlag=true (was \(self.pendingSnapshotFlag))", category: "ChatList.SnapQueue")
                        self.pendingSnapshotFlag = true
                        return
                    }
                    self.applySnapshot(messages: msgs, caller: "bind4b-blockCount")
                }
        }

        /// Flush any snapshot that was deferred while streaming UI updates were suspendedFlag.
        // a backstop flush.
        func flushPendingSnapshotIfNeeded(caller: String = "?") {
            guard pendingSnapshotFlag else { return }
            pendingSnapshotFlag = false
            let blocks = vm?.messages.last(where: { $0.role == .assistant })?.blocks.count ?? -1
            // Include blockCount + isProcessing so a
            AppLogger.shared.info("[SnapQueue] FLUSH caller=\(caller) blockCount=\(blocks) isProcessing=\(vm?.isProcessing == true) — applying deferred snapshot", category: "ChatList.SnapQueue")
            if let msgs = vm?.messages { applySnapshot(messages: msgs, caller: "flushPending(\(caller))") }
        }

        func flushStreamingLayout() {
            flushPendingSnapshotIfNeeded(caller: "flushStreamingLayout")

            guard viewController?.collectionView != nil,
                  viewController?.messageListLayout != nil else { return }

            let interval: TimeInterval = scrollMode == .autoScrolling ? 0.1 : 3.0
            let now = Date()
            if now.timeIntervalSince(lastStreamingLayoutTime)<interval {
                if pendingStreamingLayout == nil {
                    let work = DispatchWorkItem { [weak self] in
                        self?.pendingStreamingLayout = nil
                        self?.doFlushStreamingLayout()
                    }
                    pendingStreamingLayout = work
                    DispatchQueue.main.asyncAfter(deadline: .now()+interval,execute: work)
                }
                return
            }
            pendingStreamingLayout?.cancel()
            pendingStreamingLayout = nil
            doFlushStreamingLayout()
        }

        /// 流结束后**强制重测**最后一条 AI 回复的所有块。
        ///
        /// [2026-11-20 文字被截断] 真机日志：流式期间 cell 一路欠高
        /// （`UNDER-HEIGHT cellH=1143 textNeed=1210`），流结束那刻 `STREAM-END` 因
        /// `suspendedFlag=true` 不 flush，随后 settle 只补了快照、**没有重测高度**，
        /// 于是最后几个字的行高永远停在流式早期的值 ⇒ 末行被裁，只能重进会话才恢复。
        func remeasureLastAssistantBlocks(reason: String) {
            guard let vm, let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView,
                  let lastAI = vm.messages.last(where: { $0.role == .assistant }) else { return }
            var idxs: [Int] = []
            for b in lastAI.blocks {
                if let i = itemToIndex[.assistantBlock(lastAI.id, b.id)] { idxs.append(i) }
            }
            guard !idxs.isEmpty else { return }
            for i in idxs { layout.invalidateHeight(at: i, memo: .withMemo) }
            seedHeights(.indices(idxs), rows: prevSnapshotIds, messages: vm.messages, width: cv.bounds.width)
            layout.invalidateLayout()
            AppLogger.shared.info("[Heights] stream-end remeasure rows=\(idxs.count) reason=\(reason)", category: "ChatList.Heights")
            applySnapshot(messages: vm.messages, caller: "remeasure(\(reason))")
        }

        func doFlushStreamingLayout() {
            lastStreamingLayoutTime = Date()
            guard let layout = viewController?.messageListLayout else { return }
            layout.invalidateLayout()

            if scrollMode == .autoScrolling {
                scheduleCoalescedScroll()
            }
        }

        func scheduleCoalescedScroll() {
            pendingScrollWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let isTracking = self.viewController?.collectionView?.isTracking ?? false
                if self.scrollMode != .autoScrolling || isTracking { return }
                self.scrollToBottomNow()
            }
            pendingScrollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now()+0.08,execute: work)
        }

}
