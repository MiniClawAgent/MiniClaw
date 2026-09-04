import Foundation
import Combine
import SwiftUI
import MiniClawKit

// MARK: - 数据桥(2026-08-09)
// 把 MiniClaw 会话数据(SwiftData 消息 + runtime 流式状态)桥接进
// 移植消息列表组件所需的 MessageListModel。宿主(ChatView)在
// 数据变化点调用 refresh(),内部按内容指纹节流,避免流式高频重建。

@MainActor
final class MiniClawChatBridge: ObservableObject {
    /// 适配列表直接消费的视图模型
    /// 适配列表直接消费的视图模型。注入 BrowserEngineAdapter 的共享标签池,
    /// 让浏览器工具指示器能打开真实引擎 WebView(BrowserSheetView),不再落入
    /// 空桩 ISHTerminalView(2026-08-10 修复:浏览器工具白屏)。
    let vm = MiniClawKit.MessageListModel(browserTabPool: BrowserEngineAdapter.shared.pool(for: nil))

    private weak var session: ChatSession?
    private weak var appState: AppState?
    private var lastFingerprint = ""
    /// 流式内容上报的最小间隔(秒):行增长高频触发时合并刷新
    private var lastRefreshAt: Date = .distantPast
    /// 上次 refresh 时的 isProcessing 值,用于检测「流式结束翻转」
    /// (isResponding true→false):终态刷新若撞上 0.25s 节流窗口会被吞掉,
    /// UI 停在差几个字的旧内容,重进会话才完整(2026-08-11 方案一修复)。
    private var lastIsProcessing: Bool = false
    /// Kit 对象缓存(按 MiniClaw 持久消息 id):内容签名不变则复用旧对象,
    /// 保持 message.id/block.id 稳定 → 列表高度缓存/contentKey memo 可命中,
    /// 消除每次刷新的全量缓存失效与估算↔实测落差(2026-08-10 滑动跳动/空白根因)。
    private var bridgeCache: [String: MiniClawKit.ChatMessage] = [:]
    /// 当前观察的 runtime(流式实时:SwiftData 消息终态落盘,流式中 content 不变,
    /// 需订阅 runtime.streamingContent 驱动刷新;2026-08-10 切默认路径前接通)。
    private weak var observedRuntime: ChatSessionRuntime?
    /// 流式 Combine 订阅(iOS16 适配:替代 withObservationTracking)。
    private var streamingSub: AnyCancellable?
    private var streamingSubscriptions: [AnyPublisher<Void, Never>] = []
    /// [2026-08-14 抖动修复·方案1补充] 拖动挂起期间是否跳过过流式更新。
    /// 挂起窗口内不替换 vm.messages；恢复(true→false)时据此强制终态刷新——
    /// 否则流式恰在挂起中结束会吞掉最后几个字(终态 endTransition 刷新也被挂起拦下)。
    private var suspendedSkipHappened = false
    private var suspendedSub: AnyCancellable?

    func attach(session: ChatSession, appState: AppState) {
        self.session = session
        self.appState = appState
        // 2026-08-12 治本:附件缩略图/媒体缓存按会话目录解析,必须设置 activeSessionId
        // (Kit 的 TileImage/miniClawMediaCacheKey 据此定位 Documents/MiniClaw-Sessions/<sid>/;
        // 此前宿主从不设置 → 缩略图 guard 直接 return,图片附件显示空白)。
        MessageListModel.activeSessionId = session.id.uuidString
        // 浏览器工具指示器用的标签池必须是会话级池(与引擎工具执行同一对象):
        // 注入 sharedPool 会让工具导航的 tab 落在会话级池、指示器打开的是空池
        // → "No Page"(2026-08-10 修复)。attach 时按 session.id 取会话级池。
        vm.browserTabPool = BrowserEngineAdapter.shared.pool(for: session.id)
        // 2026-08-12:浏览器接管内容注入主工程 BrowserView(照原版机制,
        // 由 ToolLiveSheet 二级 sheet 呈现,稳定弹出;池与会话级池同一对象,标签同步)。
        vm.browserContentProvider = { url in
            // 2026-09-01：工具卡片改为独立 UIWindow 呈现——窗口视图树中没有
            // environmentObject 继承链，BrowserView 依赖 AppState（@EnvironmentObject），
            // 必须在此显式注入（原 sheet 链路同样缺失，只是从未被点到）。
            AnyView(BrowserView(startURL: url)
                .presentationDetents([.large])
                .environmentObject(AppState.shared))
        }
        // 重进会话:清空对象缓存 + 重置指纹,强制从磁盘重建 blocks
        // (buildBlocks 按 timelineOrder 正确排序)。否则 bridgeCache 复用流式期间
        // 的中途乱序 blocks,重进会话仍错序(2026-08-10 修复)。
        bridgeCache.removeAll(keepingCapacity: true)
        lastFingerprint = ""
        refresh(force: true)

        // [2026-08-14 抖动修复·方案1补充] 拖动挂起恢复(true→false)边沿：
        // 挂起窗口内被跳过的流式更新(尤其流式恰在拖动中结束的终态几个字)在此强制补齐。
        // 不能依赖组件侧 suspend-resume flush——它 apply 的是组件缓存的旧 vm.messages。
        suspendedSub?.cancel()
        suspendedSub = vm.$streamingUIUpdatesSuspended
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suspended in
                guard let self, !suspended, self.suspendedSkipHappened else { return }
                self.suspendedSkipHappened = false
                self.refresh(force: true)
            }
    }

    /// 数据变化点调用(消息增删/流式增长/工具状态变化)
    func refresh(force: Bool = false) {
        guard let session else { return }

        let sorted = session.messages.sorted { $0.createdAt < $1.createdAt }
        // 排队消息不再注入 vm.messages——2026-08-10 用户要求显示在输入框上方
        // 悬浮层(ChatView.queuedMessageRow 直接读 appState.pendingUserMessages),
        // 此处移除列表注入避免重复显示。
        // 运行状态镜像(停止/暂停按钮与 typing 指示器用)——必须在节流判断之前:
        // 流式结束瞬间内容可能不变(指纹相同),但 isResponding 翻转必须同步,
        // 否则思考块 isStreaming 永远为 true,自动折叠永不触发。
        // 注意:不再无条件清 streamingUIUpdatesSuspended——该标志由消息列表
        // 组件在用户拖动(挂起流式重建)/settle(恢复)时自行管理,此处强制复位
        // 会让拖动中的挂起窗失效(0.25s 内被踢回 false),是上拉回弹抖动的一环。
        if let runtime = appState?.chatRuntimes[session.id] {
            vm.isProcessing = runtime.isResponding
            vm.canResume = runtime.isPaused
        } else {
            vm.isProcessing = false
            // 2026-08-12 治本:重启后无 runtime,暂停指示器从持久化的消息级 isPaused 恢复
            // (暂停已同步落盘),不再依赖进程内运行时——否则退出重进后"已暂停"横幅消失,
            // 重进会话又出现(用户报告的指示器不一致)。
            let lastAssistant = session.messages.last(where: { $0.role == .assistant })
            vm.canResume = lastAssistant?.isPaused ?? false
        }
        // 流式结束翻转检测(2026-08-11 方案一):isResponding true→false 瞬间,
        // 终态刷新可能撞上 0.25s 节流窗口被吞(UI 停在差几个字的旧内容,
        // 重进会话才完整)。翻转时本次刷新绕过节流强制重建 vm.messages,
        // 内容来自已同步落盘的 SwiftData,不新增内容源。
        let endTransition = lastIsProcessing && !vm.isProcessing
        lastIsProcessing = vm.isProcessing

        let messages = sorted.map { bridgedMessage(for: $0) }
        // 流式实时合并(SwiftData 终态落盘,流式中 content 不更新):
        // 把 runtime 的实时缓冲(正文 streamingContent、思考段
        // streamingReasoningSegments、工具调用 streamingToolExecutions)合并进
        // 最后一条 assistant 消息,按 timelineOrder 交错插入 blocks——
        // 实现「思考指示器 → 工具指示器 → 正文」流式中依次实时出现,
        // 不再等终态落盘一次性吐出(2026-08-10 修复)。
        // 注意:合并必须在指纹/节流 return 之前执行——流式中指纹可能因
        // 纯文本增长而恒等,若合并放 return 之后则永不执行 → 无流式输出。
        // 合并只改最后一条消息的 content/blocks,成本可控,不应被节流吞掉。
        if let runtime = appState?.chatRuntimes[session.id],
           runtime.isResponding,
           let lastAI = messages.last(where: { $0.role == .assistant }) {
            // ① 正文:按思考段/工具调用的 position 把 streamingContent 切分成
            // 多段 text block,按「事件 order - 0.5」穿插插入——与终态 buildBlocks
            // 规则一致,实现「思考1→工具1→回复1→思考2→工具2→回复2」流式中即
            // 正确穿插(2026-08-10 修复:流式正文混在一起、完成后才跳回正确)。
            // 幂等:0.25s 节流高频调用,按 timelineOrder 定位既有 text block 就地
            // 更新(保 block.id/高度缓存),不存在才 insertBlock。
            if !runtime.streamingContent.isEmpty {
                lastAI.content = runtime.streamingContent
                // 事件列表:思考段 + 工具调用,按 order(次按 position)排序。
                var events: [(order: Double, position: Int)] = []
                for seg in runtime.streamingReasoningSegments {
                    events.append((Double(seg.timelineOrder), seg.position))
                }
                for exec in runtime.streamingToolExecutions {
                    events.append((runtime.order(for: exec.callID), exec.position))
                }
                events.sort {
                    $0.order < $1.order || ($0.order == $1.order && $0.position < $1.position)
                }
                // 切分:每个事件前的正文片段 order = 事件order - 0.5;剩余排最后。
                let content = runtime.streamingContent
                var cursor = 0
                for (order, position) in events {
                    let p = min(max(position, 0), content.count)
                    if p > cursor {
                        let startIdx = content.index(content.startIndex, offsetBy: cursor)
                        let endIdx = content.index(content.startIndex, offsetBy: p)
                        upsertTextBlock(content: String(content[startIdx..<endIdx]),
                                        order: order - 0.5,
                                        into: &lastAI.blocks)
                    }
                    cursor = max(cursor, p)
                }
                if cursor < content.count {
                    let startIdx = content.index(content.startIndex, offsetBy: cursor)
                    upsertTextBlock(content: String(content[startIdx..<content.endIndex]),
                                    order: Double(Int.max - 1),
                                    into: &lastAI.blocks)
                }
            }
            // ② 思考段:按 timelineOrder 交错插入 .thinking block。
            // 段文本流式增长(新全文以旧全文为前缀),用「新文本以旧内容开头」
            // 匹配已存在的段并就地更新;新段追加并强制折叠。
            for seg in runtime.streamingReasoningSegments {
                let prefixMatch = lastAI.blocks.first { b in
                    b.kind == .thinking && !b.content.isEmpty && seg.text.hasPrefix(b.content)
                }
                if let existing = prefixMatch {
                    existing.content = seg.text
                } else {
                    // [Fix 重进会话跳屏·方案B] 传 seg.id 保持与终态 Adapter 重建一致。
                    let tb = MiniClawKit.AssistantBlock(id: seg.id, kind: .thinking, content: seg.text)
                    tb.isThinkingExpanded = false
                    tb.thinkingUserToggled = false
                    insertBlock(tb, order: Double(seg.timelineOrder), into: &lastAI.blocks)
                }
            }
            // ③ 工具调用（直接引用架构）：ToolExecution 内持 AssistantBlock 引用，
            // 执行逻辑直接写 block（@Published 自驱动 cell 刷新）——bridge 只负责
            // 把新块挂进消息流（幂等：已挂载的引用跳过，不再做任何内容转换）。
            for exec in runtime.streamingToolExecutions {
                let key = exec.callID
                if lastAI.blocks.first(where: { $0.toolUseId == key || $0.id == exec.block.id }) != nil {
                    continue
                }
                insertBlock(exec.block, order: runtime.order(for: exec.callID), into: &lastAI.blocks)
            }
        }

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
                    // text 块指纹含内容量:流式增长必须反映到指纹,
                    // 否则 vm.messages 重建被节流吞掉,列表无刷新驱动。
                    fp += "x:\(b.content.count)|"
                }
            }
        }
        let now = Date()
        let throttled = now.timeIntervalSince(lastRefreshAt) < 0.25 && !force && !endTransition
        if fp == lastFingerprint || (throttled && !force) { return }

        // [2026-08-14 流式滑动抖动修复·方案1] 用户拖动列表期间组件置
        // `streamingUIUpdatesSuspended`（scrollViewWillBeginDragging → deferSelfSizing）。
        // 此时若继续替换 `vm.messages`，diffable 应用 + 高度 re-measure 会在拖动中
        // 重排内容 → 视口内容相对移动 → 抖动。这里在挂起窗口内**不替换 messages、
        // 也不推进指纹/节流锚点**：settle 恢复后由 suspendedSub（true→false 边沿）
        // 强制终态刷新补齐（含流式恰在挂起中结束的终态内容），拖动中零重绘。
        // 其他状态（isProcessing 等）在方法开头已同步，不受影响。
        if vm.streamingUIUpdatesSuspended {
            suspendedSkipHappened = true
            return
        }

        lastFingerprint = fp
        lastRefreshAt = now

        vm.messages = messages
        vm.isLoadingSession = false

        // 流式观察接管:runtime 对象变化(新建/重建)时重新挂 withObservationTracking
        observeStreamingIfNeeded()
    }

    // MARK: - 流式实时观察(@Observable runtime)

    /// runtime 流式内容变化 → refresh(指纹节流 0.25s 合并)。
    /// SwiftData 消息终态落盘,流式中必须靠此订阅驱动 Kit 列表实时刷新。
    private func observeStreamingIfNeeded() {
        guard let runtime = appState?.chatRuntimes[session?.id ?? UUID()] else { return }
        if observedRuntime === runtime { return }
        observedRuntime = runtime
        // 换观察对象时取消旧订阅(runtime 重建场景)。
        streamingSub?.cancel()
        trackStreaming(runtime)
    }

    private func trackStreaming(_ runtime: ChatSessionRuntime) {
        // iOS16 适配(2026-08-12):@Observable 宏的 withObservationTracking 是 iOS17 API,
        // 改为 Combine 订阅(runtime 已改 ObservableObject + @Published)——语义等价:
        // 任一被观察属性变化即触发 refresh(流式正文/思考段/工具调用/响应状态)。
        streamingSubscriptions = [
            runtime.$streamingContent.map { _ in () }.eraseToAnyPublisher(),
            runtime.$streamingReasoningSegments.map { _ in () }.eraseToAnyPublisher(),
            runtime.$streamingToolExecutions.map { _ in () }.eraseToAnyPublisher(),
            runtime.$isResponding.map { _ in () }.eraseToAnyPublisher(),
            runtime.$isPaused.map { _ in () }.eraseToAnyPublisher(),
        ]
        streamingSub = Publishers.MergeMany(streamingSubscriptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.refresh()
            }
    }

    // MARK: - 对象复用(稳定 id)

    /// 按 MiniClaw 持久消息 id 取 Kit 对象:内容签名不变则复用缓存对象,
    /// 避免每次 refresh 全量重建 UUID 导致列表高度缓存连坐失效。
    /// 流式增长特例:同一消息 content 变长但 blocks 结构相同(仅文本块增量)
    /// 时,复用旧对象并就地更新文本块 content——保持 block.id 恒定,
    /// diffable 列表只 reconfigure 不重建,消除流式/切回 app 抖动。
    private func bridgedMessage(for model: ChatMessage) -> MiniClawKit.ChatMessage {
        let key = model.id.uuidString
        let fresh = MiniClawChatAdapter.convert(model)
        if let cached = bridgeCache[key] {
            // 内容签名完全一致:复用缓存对象(block.id 稳定,高度缓存可命中)。
            if blockSignature(cached) == blockSignature(fresh) {
                return cached
            }
            // 流式中的消息(终态前 SwiftData 未落盘):始终保留 cached 并就地同步
            // 已落盘部分(blocks 结构变化时也复用旧对象)。流式状态(正文/思考/工具)
            // 由 refresh() 的实时合并补充,若此处替换新对象会导致 block.id 全变、
            // 高度缓存连坐失效、bind4a 订阅断链——加剧「一次性吐出」(2026-08-10)。
            if model.isStreaming {
                mergeTextContent(cached, from: fresh)
                cached.isAwaitingModelResponse = fresh.isAwaitingModelResponse
                cached.content = fresh.content
                return cached
            }
            // 终态消息(isStreaming == false):直接返回 fresh,走 buildBlocks 的
            // timelineOrder 正确排序。不复用 cached——cached 可能是流式期间
            // 「正文堆末尾/思考逆序」的中途状态,复用会让重进会话仍错序
            // (2026-08-10 修复:重进会话排序混乱)。
            bridgeCache[key] = fresh
            return fresh
        }
        bridgeCache[key] = fresh
        return fresh
    }

    /// 块级结构签名(仅块数+类型,不含内容量):判断"能否就地复用"。
    private func blockStructure(_ msg: MiniClawKit.ChatMessage) -> String {
        var s = "\(msg.blocks.count)|"
        for b in msg.blocks {
            switch b.kind {
            case .text: s += "x|"
            case .thinking: s += "t|"
            default: s += "u|"
            }
        }
        return s
    }

    /// 把 fresh 的文本块内容就地写进 cached 对应块(保持对象/block.id 不变)。
    /// 思考块/工具块内容也可能增长(流式中),一并更新以保渲染正确。
    private func mergeTextContent(_ cached: MiniClawKit.ChatMessage, from fresh: MiniClawKit.ChatMessage) {
        let count = min(cached.blocks.count, fresh.blocks.count)
        for i in 0..<count {
            switch (cached.blocks[i].kind, fresh.blocks[i].kind) {
            case (.text, .text), (.thinking, .thinking):
                cached.blocks[i].content = fresh.blocks[i].content
            case (_, _) where kindTag(cached.blocks[i].kind) == kindTag(fresh.blocks[i].kind):
                // 工具类块(带关联值,kind 本身不等)且结构标签一致时同步内容/状态
                cached.blocks[i].content = fresh.blocks[i].content
                if let ts = fresh.blocks[i].toolStatus { cached.blocks[i].toolStatus = ts }
            default:
                break
            }
        }
    }

    /// 工具/信息类块的粗粒度结构标签(不带关联值),用于就地复用的匹配判断。
    private func kindTag(_ kind: AssistantBlockKind) -> String {
        switch kind {
        case .text: return "x"
        case .thinking: return "t"
        case .shellTool: return "u"
        case .fileReadTool: return "u"
        case .fileWriteTool: return "u"
        case .fileEditTool: return "u"
        case .browserTool: return "u"
        case .readImageTool: return "u"
        case .memoryTool: return "u"
        case .info: return "i"
        case .file: return "f"
        }
    }

    /// 块级渲染签名(块类型+内容量+工具状态+流式标志):
    /// 签名相同 → 渲染等价 → 可安全复用旧对象(含 block.id/message.id)。
    private func blockSignature(_ msg: MiniClawKit.ChatMessage) -> String {
        var s = "\(msg.content.count)|\(msg.isAwaitingModelResponse)|"
        for b in msg.blocks {
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

    /// 按 timelineOrder 把新块插入 blocks,保持「思考→工具→正文」的真实发生顺序。
    /// 每个块都携带 timelineOrder(Double,正文片段用事件 order+0.5 穿插),插入时
    /// 按真实序号定位,不再用常数推断(旧实现 thinking=5/tool=10 导致多段思考逆序)。
    private func insertBlock(_ block: MiniClawKit.AssistantBlock, order: Double, into blocks: inout [MiniClawKit.AssistantBlock]) {
        block.timelineOrder = order
        if order <= 0 {
            // 旧数据无 timelineOrder:排最前(可接受降级)
            blocks.insert(block, at: 0)
            return
        }
        var insertIdx = blocks.count
        for (i, b) in blocks.enumerated() {
            if b.timelineOrder > order {
                insertIdx = i
                break
            }
        }
        blocks.insert(block, at: insertIdx)
    }

    /// 正文片段幂等更新:按 timelineOrder 定位既有 text block 就地更新 content
    /// (保持 block.id,保住高度缓存),不存在才 insertBlock 插入。流式高频调用
    /// 必须增量,避免每 0.25s 重建 text block 导致高度缓存连坐失效。
    /// 防重复(2026-08-10):retry/重建后可能出现旧残留 text block(内容与新片段
    /// 相同但 timelineOrder 不同),更新前先移除这类重复块,避免同一段正文出现两次。
    private func upsertTextBlock(content: String, order: Double, into blocks: inout [MiniClawKit.AssistantBlock]) {
        guard !content.isEmpty else { return }
        // 移除内容完全相同的其他 text 块(旧残留,防正文重复)。
        blocks.removeAll { b in
            b.kind == .text && b.timelineOrder != order && b.content == content
        }
        if let existing = blocks.first(where: { $0.kind == .text && $0.timelineOrder == order }) {
            if existing.content != content { existing.content = content }
        } else {
            let tb = MiniClawKit.AssistantBlock(kind: .text, content: content)
            insertBlock(tb, order: order, into: &blocks)
        }
    }

    /// 既有块的时间线序号:直接读块上记录的 timelineOrder(正文默认 Int.max-1)。
    private func blockOrder(of block: MiniClawKit.AssistantBlock) -> Double {
        block.timelineOrder
    }

    /// 工具状态推断(流式中:执行中 running;结果回填后 success/failed/cancelled)。
    private func toolStatus(for event: ToolCallEvent) -> MiniClawKit.ToolBlockStatus? {
        if event.wasInterrupted { return .cancelled }
        if event.resultText.isEmpty { return .running }
        return event.success ? .success : .failed(message: "")
    }
    var onResume: (() -> Void)?
    var onPause: (() -> Void)?
}
