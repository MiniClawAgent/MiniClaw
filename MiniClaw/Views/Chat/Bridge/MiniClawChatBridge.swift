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
    let vm = MessageListModel(browserTabPool: BrowserEngineAdapter.shared.pool(for: nil))

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
    private var bridgeCache: [String: RenderMessage] = [:]
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

        // [2026-09-09 进入长会话卡顿] `bridgedMessage` 内会对未渲染的文本块**同步**
        // 跑 cmark 解析 + 富文本构造，50+ 消息会话一次 refresh 就是上百次串行渲染
        // = 主线程卡数秒（用户报告的「进入长会话 50+ 消息卡」）。
        // 会话进入时视口在底部（最新消息），因此只对**尾部**若干条消息现场渲染；
        // 其余留给 cell 首次配置时由 MarkdownView 按需渲染（不白屏，成本摊进滑动）。
        // 已经渲染过的块（第二次进入、统一缓存命中）走零成本路径，不受影响。
        let syncRenderTailCount = 20
        let renderFrom = max(0, sorted.count - syncRenderTailCount)
        let messages = sorted.enumerated().map { idx,m in
            bridgedMessage(for: m, allowsSyncRender: idx >= renderFrom)
        }
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
                // [2026-09-09 流式切分收敛·治本] 先算出**目标 text 块集合**（与终态
                // buildBlocks 完全同构：id=det(mid,startOffset)、order 同规则），再统一
                // upsert + **孤儿清理**。此前边遍历边 upsert：工具 position 赋值与正文
                // token 到达存在竞态（onToolExecutionBegin 时最后一批 token 可能尚未
                // 进入 streamingContent/pendingText → position 少记），cursor 漂移后旧
                // startOffset 的块不再被任何 upsert 命中、又不被删除 → 流式显示截短
                //（真机：正文段只剩「三」一个字，重进会话才恢复完整）。目标集收敛后：
                // 无论时序怎么抖，每次 refresh 后 text 块集合 = 当前 (events, content)
                // 的正确切分，且 id 与终态完全一致 → 终态合并零跳变。
                let content = runtime.streamingContent
                var targets: [(startOffset: Int, content: String, order: Double)] = []
                var cursor = 0
                for (order, position) in events {
                    let p = min(max(position, 0), content.count)
                    if p > cursor {
                        let startIdx = content.index(content.startIndex, offsetBy: cursor)
                        let endIdx = content.index(content.startIndex, offsetBy: p)
                        targets.append((cursor, String(content[startIdx..<endIdx]), order - 0.5))
                    }
                    cursor = max(cursor, p)
                }
                if cursor < content.count {
                    let startIdx = content.index(content.startIndex, offsetBy: cursor)
                    // [2026-09-13 P4·两套尾部 order 收敛] 原先这里写死 `Double(Int.max - 1)`，
                    // 而终态 `MiniClawChatAdapter.buildBlocks` 的尾部基准是 `maxEventOrder + 0.5`
                    // ⇒ **同一个块在流式与终态拿到两个不同的 order**，只能靠终态合并时事后同步
                    //（`bridgedMessage` 里同步 timelineOrder）⇒ 排序键跳变。
                    // 更硬的理由是精度：`Int.max` 量级下 Double 的**精度间隔是 2048**，
                    // 任何 `+0.05*k` 子序都会被吞成同一个值（终态 2026-09-12 的
                    // 「文件指示器总在最终回复上面」就是这个坑，同规则注释见 Adapter 尾部）。
                    // 改为与终态**同一条规则**：`maxEventOrder + 0.5` —— 仍严格大于所有事件 order
                    // 与「事件前正文段」（后者 = eventOrder - 0.5，恒小于事件本身），
                    // 同时落在 Double 精确表示范围内，子序不丢。两条路径从此同构。
                    let tailBase = (events.map { $0.order }.max() ?? 0) + 0.5
                    targets.append((cursor, String(content[startIdx..<content.endIndex]), tailBase))
                }
                // 孤儿清理：不在目标集的 text 块 = 旧切分残留（position 漂移产物），
                // 删除使其不再占据显示。thinking/tool 块不在本清理范围
                //（§② 前缀匹配、§③ toolUseId 幂等各自管理）。
                let targetIDs = Set(targets.map { MiniClawChatAdapter.textBlockID(messageID: lastAI.id, startOffset: $0.startOffset) })
                let orphanIDs = lastAI.blocks.filter { $0.kind == .text && !targetIDs.contains($0.id) }.map(\.id)
                if !orphanIDs.isEmpty {
                    lastAI.blocks.removeAll { $0.kind == .text && !targetIDs.contains($0.id) }
                }
                for t in targets {
                    upsertTextBlock(messageID: lastAI.id,
                                    content: t.content,
                                    startOffset: t.startOffset,
                                    order: t.order,
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
                    let tb = AssistantBlock(id: seg.id, kind: .thinking, content: seg.text)
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
        // [Probe 2026-09-11] 终态合并观测：回复结束这次刷新合并进的各文本块长度——
        // 对照 Persist 的 content 字数，若 textLens 偏短 = 终帧合并缺尾（Bridge 层病）；
        // 若 textLens 完整而界面仍短 = cell 未被 reconfigure（列表层病）。
        if endTransition {
            let lastAI = messages.last(where: { $0.role == .assistant })
            let textLens = (lastAI?.blocks ?? []).compactMap { b -> Int? in
                b.kind == .text ? b.content.count : nil
            }
            AppLogger.shared.warning(
                "[BridgeProbe] endTransition contentCnt=\(lastAI?.content.count ?? -1) textLens=\(textLens) fpSame=\(fp == lastFingerprint ? 1 : 0) throttled=\(throttled ? 1 : 0) suspended=\(vm.streamingUIUpdatesSuspended ? 1 : 0)",
                category: "BridgeProbe")
        }

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
    private func bridgedMessage(for model: ChatMessage,
                                allowsSyncRender: Bool = true) -> RenderMessage {
        let key = model.id.uuidString
        let fresh = MiniClawChatAdapter.convert(model)
        // 同步渲染累计字符预算（条数之外再加一道"体积"闸门）：syncRenderTailCount 只限条数，
        // 子代理一次返回几万字符时，尾部 20 条里夹着的超长消息同步渲染会把主线程卡住数秒
        // （看门狗强杀嫌疑）。20000 字符约等于数屏正文，覆盖绝大多数正常消息；超预算的块跳过
        // 同步渲染是安全的——cell 首次配置时 MarkdownView 会按需渲染（不白屏）。
        let syncRenderCharBudget = 20000
        if let cached = bridgeCache[key] {
            // 内容签名完全一致:复用缓存对象(block.id 稳定,高度缓存可命中)。
            if blockSignature(cached) == blockSignature(fresh) {
                return cached
            }
            // 流式中的消息(终态前 SwiftData 未落盘):始终保留 cached 并就地同步
            // 已落盘部分(blocks 结构变化时也复用旧对象)。流式状态(正文/思考/工具)
            // 由 refresh() 的实时合并补充,若此处替换新对象会导致 block.id 全变、
            // 高度缓存连坐失效、bind4a 订阅断链——加剧「一次性吐出」(2026-08-10)。
            // [2026-09-09 治本] **禁止在流式分支回写滞后快照**：
            // `mergeTextContent` + `cached.content = fresh.content` 会把实时块内容
            // 打回**滞后的落盘快照**（content 落盘有延迟），下一次 refresh 的
            // runtime 实时合并又写回新值 → 同一块内容在「旧段/新段」之间反复横跳
            // （真机日志实证：CACHE-WIPE 两段正文交替 20+ 次）、正文段被截短成
            // 开头几个字（图 1「凌晨」）、结束后短值固化 + 渲染层 skip 锁死成空白
            //（图 3 中间正文"消失"）。流式内容一律以 runtime 实时合并为唯一来源。
            if model.isStreaming {
                cached.isAwaitingModelResponse = fresh.isAwaitingModelResponse
                return cached
            }
            // 终态消息(isStreaming == false):**就地合并** fresh——保留 cached
            // 对象身份:footer 状态行/耗时绑定在 cached 上(@Published),换新对象会让
            // 已绑定 cell 收不到变更,终态耗时/状态要重进会话才显示(2026-09-05 修复)。
            cached.content = fresh.content
            // [2026-09-09 流式→终态跳变治本] **同 id 块就地同步字段，禁止整体替换
            // blocks 数组**。身份统一后流式块与终态块 id 相同但**对象不同**：整体
            // 替换后 cell 仍绑定旧 AssistantBlock（其 @Published 链随之停摆——
            // Bridge 后续只更新新对象），而 applySnapshot 因 item 集合不变（id 相同）
            // 短路、不 reconfigure → 已显示 cell 停在流式最后值，直到滚动触发
            // 复用重配才跳到终态内容 = 「回复刚结束中间会话又刷出来 / 上下滑动
            // 又变回不完整」（真机 IMG_4602/4603，2026-09-09 12:26）。
            // 同 id 就地同步：对象身份稳定 → cell 实时刷新；且块级渲染缓存
            // （cachedMarkdown/cachedAttributedString）不因换对象而连坐失效。
            // 结构变化（新增/删除/换 id）才允许 fresh 新对象入列。
            var oldByID: [UUID: AssistantBlock] = [:]
            for b in cached.blocks { oldByID[b.id] = b }
            var merged: [AssistantBlock] = []
            merged.reserveCapacity(fresh.blocks.count)
            for fb in fresh.blocks {
                if let ob = oldByID[fb.id] {
                    // 同 id：内容变了才清块级渲染缓存（正常路径流式块内容与终态
                    // 一致——身份统一的初衷——缓存保留零成本；不一致说明切分漂移，
                    // 清缓存换正确性）。thinking 展开态/用户手动标志保留旧对象的。
                    if ob.content != fb.content {
                        ob.content = fb.content
                        ob.cachedMarkdown = nil
                        ob.cachedAttributedString = nil
                    }
                    ob.kind = fb.kind
                    ob.toolStatus = fb.toolStatus
                    ob.toolSummary = fb.toolSummary
                    ob.toolDuration = fb.toolDuration
                    ob.toolInputArgs = fb.toolInputArgs
                    ob.toolUseId = fb.toolUseId
                    ob.imageFilePath = fb.imageFilePath
                    ob.browserURL = fb.browserURL
                    ob.wasBackgroundSuspended = fb.wasBackgroundSuspended
                    ob.streamingFileContent = fb.streamingFileContent
                    if ob.timelineOrder != fb.timelineOrder { ob.timelineOrder = fb.timelineOrder }
                    merged.append(ob)
                } else {
                    merged.append(fb)
                }
            }
            cached.blocks = merged
            // [T-perf 2026-09-08] 签名真变化的终态消息：补文本块渲染缓存
            //（cacheRenderedContent 内部接入进程级统一缓存——第二次进入零渲染；
            // 同步主线程执行——后台化方案曾致所有会话白屏一秒，已回退）。
            // [2026-09-09] 同步渲染**限量**：见 `syncRenderTailCount` 说明。
            // 长会话（50+ 消息）若在此对全部历史块串行渲染，进入即主线程卡数秒。
            // 非尾部消息跳过——cell 首次配置时 MarkdownView 会按需渲染（不白屏）。
            if allowsSyncRender {
                var charBudget = syncRenderCharBudget
                let blocks = cached.blocks
                for (i, blk) in blocks.enumerated() {
                    // [2026-09-11 尾部行裁切修复] 不再以「缓存缺失」为前置条件——
                    // 陈旧缓存必须追赶内容（由 cacheRenderedContent 内部按内容指纹
                    // 判定，内容没变时零成本直接返回）。
                    guard blk.kind == .text else { continue }
                    // 至少保证最后一条消息一定渲染，避免最新内容不渲染导致白屏/闪烁。
                    let isLast = i == blocks.count - 1
                    let estimated = blk.content.count
                    if !isLast, estimated > charBudget { continue }
                    charBudget -= estimated
                    blk.cacheRenderedContent()
                }
            }
            cached.error = fresh.error
            cached.usage = fresh.usage
            cached.streamInterruptCount = fresh.streamInterruptCount
            cached.isAwaitingModelResponse = fresh.isAwaitingModelResponse
            cached.wasStopped = fresh.wasStopped
            cached.wasInterrupted = fresh.wasInterrupted
            cached.taskElapsedSeconds = fresh.taskElapsedSeconds
            cached.attachments = fresh.attachments
            return cached
        }
        bridgeCache[key] = fresh
        // [T-perf 2026-09-08] 新消息首次入缓存：补文本块渲染缓存（同步——
        // cacheRenderedContent 内部接入进程级统一缓存，第二次进入同会话零渲染；
        // 后台化方案曾致所有会话白屏一秒，已回退）。流式中的消息跳过。
        if !model.isStreaming {
            // 同上：只渲染尾部消息的块（限量），避免长会话进入时主线程串行渲染。
            if allowsSyncRender {
                var charBudget = syncRenderCharBudget
                let blocks = fresh.blocks
                for (i, blk) in blocks.enumerated() {
                    // [2026-09-11 尾部行裁切修复] 不再以「缓存缺失」为前置条件——
                    // 陈旧缓存必须追赶内容（由 cacheRenderedContent 内部按内容指纹
                    // 判定，内容没变时零成本直接返回）。
                    guard blk.kind == .text else { continue }
                    // 至少保证最后一条消息一定渲染，避免最新内容不渲染导致白屏/闪烁。
                    let isLast = i == blocks.count - 1
                    let estimated = blk.content.count
                    if !isLast, estimated > charBudget { continue }
                    charBudget -= estimated
                    blk.cacheRenderedContent()
                }
            }
        }
        return fresh
    }

    // [2026-09-13 重构·删除死码] 此处原有两个零调用辅助：
    //   `blockStructure(_:)`（块数 + 类型签名）与 `kindTag(_:)`（类型 → 单字符标签）。
    // 全库核查：**两者都只有定义、没有任何调用点**。就地复用的判据实际由下方
    // `blockSignature` 唯一承担（它更完整：含 content.count + toolStatus + isAwaitingModelResponse）。
    // 删除后「就地复用」只剩**一个出入口** —— 与本次重构的目标一致。

    /// 块级渲染签名(块类型+内容量+工具状态+流式标志):
    /// 签名相同 → 渲染等价 → 可安全复用旧对象(含 block.id/message.id)。
    private func blockSignature(_ msg: RenderMessage) -> String {
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
    private func insertBlock(_ block: AssistantBlock, order: Double, into blocks: inout [AssistantBlock]) {
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

    /// 正文片段幂等更新：按 **block.id**（= messageID + startOffset，确定性）定位既有
    /// text block 就地更新 content（保持 block.id，保住高度缓存与渲染实例），不存在才
    /// insertBlock 插入。流式高频调用必须增量，避免每 0.25s 重建 text block 导致
    /// 高度缓存连坐失效。
    ///
    /// 旧残留块的清理**不在本函数**：由调用点的孤儿清理承担（删除所有 id ∉ targetIDs
    /// 的 text 块）。本函数只负责「该 id 的块」的幂等更新 / 新建。
    ///
    /// [2026-09-09 身份统一] 新建块改用与终态 buildBlocks 同款的确定性 id
    ///（messageID+startOffset）——此前流式块是随机 id、终态重建后 id 全变，
    /// diffable 视为全新 item 全量重建 cell = 「回复刚结束界面又重放一遍」
    /// + configureCell MISS + 高度缓存连坐失效。
    private func upsertTextBlock(messageID: UUID, content: String, startOffset: Int,
                                 order: Double, into blocks: inout [AssistantBlock]) {
        guard !content.isEmpty else { return }
        // [2026-09-09 崩溃修复] 幂等判定口径必须与 id 派生口径一致 —— **按 block.id**。
        // 旧实现按 timelineOrder 匹配，而 id 只由 (messageID, startOffset) 派生：
        // 同一段正文会先以「尾部整段」身份（order = Int.max-1, startOffset = 0）建成，
        // 之后事件到达把该段切成 eventOrder-0.5 的新身份时，按 order 找不到既有块 →
        // 再建一个**同 id**（同为 offset=0）的块；此时旧块内容（当时的整段正文）
        // 与新内容（切到事件位置的前缀）不等，任何「按内容相等」的判定都不会命中 →
        // 两个 id 相同的 assistantBlock 共存 → diffable 重复 identifier 崩溃。
        let targetID = MiniClawChatAdapter.textBlockID(messageID: messageID, startOffset: startOffset)
        // [2026-09-13 治本] 此处原有「按 content 移除同内容的其它 text 块」的去重，已删除。
        // 它建立在**错误前提**上：假设「内容相同的 text 块 = 旧残留」。该前提只成立于随机
        // id 时代（同一段正文每次 refresh 都以新 id 新建，故需按内容去重）；自 2026-09-09
        // 改用确定性 id（messageID+startOffset）后前提不再成立——幂等由下方按 id 分支承担，
        // 切分回退留下的旧残留由调用点的孤儿清理（id ∉ targetIDs 全删）承担，本条成了纯冗余。
        // 而且**有害**：同一消息内若存在多个内容逐字相同的正文块（多轮工具循环里每轮都回
        // 「思考完毕」这类固定短语），逐 target upsert 时会互相删除、只剩最后一个 →
        // 流式中整屏只显示 1 个，直到终态 buildBlocks 才补齐。真机实证：9 个 4 字块，
        // endTransition 时块索引恰好后移 8（= 9−1）。
        if let existing = blocks.first(where: { $0.kind == .text && $0.id == targetID }) {
            // 同一段正文身份不变:就地更新内容与位置(保住高度缓存与渲染实例)。
            if existing.content != content {
                // [2026-09-09 诊断] 正常流式只增长（新内容以旧为前缀）。**变短** =
                // 切分回退（重试回滚 / 事件 position 漂移 / 段切分点变化），曾表现
                // 为「正文截短成开头几个字（图 1『好的，』）」。低频异常路径，打
                // warn 供真机日志一锤定音；不阻断（截短是数据事实，渲染须跟随）。
                if content.count < existing.content.count {
                    AppLogger.shared.warn(
                        "[TextUpsert] SHRINK block=\(existing.id.uuidString.prefix(8)) len \(existing.content.count)→\(content.count) startOffset=\(startOffset) msgId=\(messageID.uuidString.prefix(8)) — 切分回退，请带此日志复盘",
                        category: "Bridge", subsystem: "Stream")
                }
                existing.content = content
                existing.cachedMarkdown = nil
                existing.cachedAttributedString = nil
            }
            if existing.timelineOrder != order { existing.timelineOrder = order }
        } else {
            let tb = MiniClawChatAdapter.makeTextBlock(
                messageID: messageID, startOffset: startOffset, content: content, order: order)
            insertBlock(tb, order: order, into: &blocks)
        }
    }

    // [2026-09-13 重构·删除死码] 此处原有两个零调用辅助：
    //   `blockOrder(of:)`（读块上记录的 timelineOrder）与 `toolStatus(for:)`（按 ToolCallEvent 推断状态）。
    // 全库核查：两者都**只有定义、没有任何调用点**（唯一同名的 `toolStatus(for:message:)` 在
    // `MiniClawChatAdapter`，是该类型自己的另一个方法）。工具状态推断因此只剩适配器一处 —— 入口统一。
    var onResume: (() -> Void)?
    var onPause: (() -> Void)?
}
