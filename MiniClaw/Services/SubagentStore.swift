import Foundation
import Observation

/// 会话级子代理仓库：按 `sessionID` 维护两类数据，二者都跨「主 智能体的一轮回复」存活，
/// 因此子代理头像与对话在整段会话里持续可查（满足「头像常驻、用户随时回看子代理做了什么」）。
///
/// 关键设计：把**流式对话内容**（`SubagentConversation`）与**轻量头像卡片**（`SubagentCard`）
/// 分离。主聊天页只观察 `cards`（仅在启动/结束/出错时变化），详情页只观察对应
/// `SubagentConversation`（随 词元 流式变化），从而让「子代理每收到一个 令牌」的刷新
/// 被隔离在详情页内部，主聊天页不会随之重绘——避免界面卡顿。
///
/// 详情页渲染直接复用主会话页的 `MessageBubbleView`：任务（主 智能体指派）以 `.user` 角色呈现
/// （绿色气泡，与普通会话里用户消息完全一致）；子代理回复以 `.assistant` 角色呈现
/// （无聊天背景、头像 + 名称 + 正文 + 工具指示器 + 思考块），与主线渲染形式一模一样。
///
/// 持久化：会话隔离存储——每个会话的子代理数据独立落盘到
/// `Documents/MiniClaw-Sessions/<会话UUID>/subagent/subagent_store.json`
/// （对应 guest 内 `/var/MiniClaw/<会话>/subagent/`），随每次变更（去抖）写本会话小文件，
/// 并在 App 启动时由 `SubagentStore.load()` 扫描全部会话目录恢复。
/// 会话删除时文件随会话目录一并消失，无跨会话共用文件。
///
/// 注意：本存储以值类型字典/数组承载，所有写入都通过「取出副本 → 修改 → 写回」的方式，
/// 确保 `@Observable` 能正确发出变更通知（直接对下标结果做 in-place 修改不会回写）。
/// `@MainActor`：全部写方法由 ChatView 的 onSubagentEvent 在主线程调用，快照构造与编码
/// 也在主线程完成（与写操作同线程，消除数据竞争），ioQueue 仅收值类型 Data 做原子落盘。
@MainActor
@Observable
final class SubagentStore {
    /// @MainActor 类的单例：初始化与访问均在主线程（调用方全部是 MainActor 上下文）。
    static let shared = SubagentStore()

    /// sessionID -> 该会话下方的悬浮头像卡片（id/name/status）。
    private var cards: [UUID: [SubagentCard]] = [:]
    /// sessionID -> 该会话下各子代理的完整对话（按子代理 id 索引）。
    private var conversations: [UUID: [UUID: SubagentConversation]] = [:]

    // MARK: - 持久化（去抖写盘 + 启动恢复）

    private let ioQueue = DispatchQueue(label: "subagent-store-io")
    private var saveTask: Task<Void, Never>?
    /// 自上次落盘后有变更、等待去抖写入的会话集合（写方法负责登记）。
    private var dirtySessions: Set<UUID> = []

    /// 落盘快照：JSON key 用字符串（UUID 的 uuidString）。
    private struct Snapshot: Codable {
        var cards: [String: [SubagentCard]] = [:]
        var conversations: [String: [String: SubagentConversation]] = [:]
    }

    /// 会话级文件路径：`MiniClaw-Sessions/<会话UUID>/subagent/subagent_store.json`。
    /// 目录由 SessionFileRouter 在会话首次触达时创建（sessionSubdirs 已含 subagent）。
    private func fileURL(for sessionID: UUID) -> URL {
        let base = SessionFileRouter.shared.sessionHostDirectory(for: sessionID)
        return base.appendingPathComponent("subagent", isDirectory: true)
            .appendingPathComponent("subagent_store.json")
    }

    /// App 启动时调用：扫描全部会话目录，逐个恢复头像与对话。
    /// 须在 UI 使用该存储前于主线程执行一次。
    func load() {
        // 冷启动双扫全部会话目录 + JSON 解码移后台（线程治理 P0）：
        // 主线程执行会阻塞首屏；回主线程仅一次性赋值（@Observable 隔离保持）。
        Task.detached(priority: .userInitiated) { [weak self] in
            var c: [UUID: [SubagentCard]] = [:]
            var conv: [UUID: [UUID: SubagentConversation]] = [:]
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: SessionFileRouter.sessionsHostBase,
                includingPropertiesForKeys: nil
            ) else { return }
            for entry in entries {
                guard let sid = UUID(uuidString: entry.lastPathComponent) else { continue }
                let url = entry.appendingPathComponent("subagent", isDirectory: true)
                    .appendingPathComponent("subagent_store.json")
                guard let data = try? Data(contentsOf: url),
                      let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { continue }
                if let list = snap.cards[sid.uuidString] {
                    c[sid] = list
                }
                if let sub = snap.conversations[sid.uuidString] {
                    var m: [UUID: SubagentConversation] = [:]
                    for (ik, v) in sub where UUID(uuidString: ik) != nil {
                        m[UUID(uuidString: ik)!] = v
                    }
                    conv[sid] = m
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.cards = c
                self.conversations = conv
                // 启动恢复：运行中被杀的子代理没有终态，统一标记「已取消」，
                // 避免重启后出现永久的「处理中」僵尸卡片（P4）。
                for sid in self.cards.keys {
                    guard var list = self.cards[sid] else { continue }
                    for i in list.indices where list[i].status == .running {
                        list[i].status = .cancelled
                    }
                    self.cards[sid] = list
                }
                for sid in self.conversations.keys {
                    if let conv = self.conversations[sid] {
                        for c in conv.values where c.status == .running {
                            c.status = .cancelled
                        }
                    }
                }
            }
        }
    }

    /// 去抖保存：多次连续变更（如流式 令牌）会合并为一次写盘。
    /// 只写「有变更的会话」自己的小文件（会话隔离）。
    /// 线程模型：快照构造与 JSON 编码在主线程（@MainActor，与所有写操作同线程）完成——
    /// 字典与 SubagentConversation/SubagentMsg 均为引用类型，后台队列并发读取与主线程写入
    /// 构成数据竞争（Dictionary 并发扩容可 EXC_BAD_ACCESS）。ioQueue 只负责把编码后的
    /// Data（值类型）原子落盘。
    /// 挂起中的去抖保存任务标记（避免流式期间每 令牌 取消+重建 Task 的主线程开销）。
    private var pendingSave = false

    private func scheduleSave(sessionID: UUID) {
        dirtySessions.insert(sessionID)
        // 降频(2026-08-07 卡顿修复):原实现每 token cancel+重建 Task、500ms 主线程全量编码——
        // 子代理流式期间主线程被持续占满 → 会话页卡。改为固定 2s 去抖窗口 + 单次挂起任务,
        // 终态(完成/出错/取消)经 flushNow 立即落盘,不再有丢尾窗口。
        guard !pendingSave else { return }
        pendingSave = true
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pendingSave = false
            await self?.encodeAndWrite()
        }
    }

    /// 终态立即落盘(不等去抖窗口):完成/出错/取消时调用,防「窗口内 App 被杀丢最后一批」。
    /// 先提交节流缓冲(不丢尾包),再落盘(落盘内容与界面完全一致)。
    func flushNow() {
        saveTask?.cancel()
        pendingSave = false
        commitPending()
        Task { await encodeAndWrite() }
    }

    /// ~100ms 单窗口调度(与主会话 scheduleFlush 同构):一个窗口只起一次 sleep 任务。
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.flushScheduled = false
            self?.commitPending()
        }
    }

    /// 批量提交缓冲到对话(先思考后正文,顺序与主会话一致);触发一次 @Observable 变更与一次落盘调度。
    private func commitPending() {
        // 1) 思考缓冲
        let reasonings = pendingSubagentReasoning
        pendingSubagentReasoning = [:]
        for (sid, bySub) in reasonings {
            for (subID, pieces) in bySub {
                guard let conv = conversations[sid]?[subID], !pieces.isEmpty else { continue }
                let m = currentOrNewResponse(conv)
                for (piece, index, order) in pieces {
                    if let idx = m.reasoningSegments.firstIndex(where: { $0.index == index }) {
                        m.reasoningSegments[idx].text += piece
                    } else {
                        m.reasoningSegments.append(ReasoningSegment(index: index, text: piece, position: m.text.count, timelineOrder: order))
                    }
                }
            }
        }
        // 2) 正文缓冲
        let texts = pendingSubagentText
        pendingSubagentText = [:]
        for (sid, bySub) in texts {
            var touched = false
            for (subID, piece) in bySub where !piece.isEmpty {
                guard let conv = conversations[sid]?[subID] else { continue }
                let m = currentOrNewResponse(conv)
                m.text += piece
                m.isStreaming = true
                touched = true
            }
            if touched { scheduleSave(sessionID: sid) }
        }
    }

    /// 主线程构造各脏会话快照并编码，把值类型 Data + 目标 URL 交给后台队列落盘。
    private func encodeAndWrite() async {
        let dirty = dirtySessions
        dirtySessions.removeAll()
        guard !dirty.isEmpty else { return }
        var jobs: [(Data, URL)] = []
        for sid in dirty {
            guard let data = encodeSnapshot(for: sid) else { continue }
            jobs.append((data, fileURL(for: sid)))
        }
        ioQueue.async {
            for (data, url) in jobs {
                // 写前确保 subagent 目录存在（旧会话目录可能缺该子目录）：
                // .atomic 写入目标目录不存在时会静默失败 → 持久化永久失效。
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try data.write(to: url, options: [.atomic])
                } catch {
                    NSLog("[SubagentStore] ⚠️ 落盘失败 \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    /// 主线程构造「单个会话」的快照并编码（只含该会话的 cards/conversations）。
    private func encodeSnapshot(for sessionID: UUID) -> Data? {
        var sc: [String: [SubagentCard]] = [:]
        if let list = cards[sessionID] { sc[sessionID.uuidString] = list }
        var sconv: [String: [String: SubagentConversation]] = [:]
        if let sub = conversations[sessionID] {
            var m: [String: SubagentConversation] = [:]
            for (ik, v) in sub { m[ik.uuidString] = v }
            sconv[sessionID.uuidString] = m
        }
        let snap = Snapshot(cards: sc, conversations: sconv)
        return try? JSONEncoder().encode(snap)
    }

    // MARK: - 头像（仅供主聊天页悬浮条读取）

    func avatars(for sessionID: UUID) -> [SubagentCard] {
        cards[sessionID] ?? []
    }

    // MARK: - 对话（仅供详情页读取）

    func conversation(for sessionID: UUID, subagentID: UUID) -> SubagentConversation? {
        conversations[sessionID]?[subagentID]
    }

    // MARK: - 写入（由 ChatView 的 onSubagentEvent 在主线程调用）

    /// 子代理首次启动：新建头像卡片 + 新建对话（首条任务消息）。
    /// 若该 id 已存在（重启后复用断链 / 旧对话仍在），**追加任务并重置状态而非覆盖**，
    /// 避免历史对话被静默丢弃（P4）且错误态被续用（P7）。
    func startSubagent(sessionID: UUID, info: SubagentInfo) {
        var convMap = conversations[sessionID] ?? [:]
        if let existing = convMap[info.id] {
            existing.status = .running
            existing.messages.append(SubagentMsg(role: .task, text: info.task, isStreaming: false))
        } else {
            let conv = SubagentConversation(id: info.id, name: info.name, status: .running)
            conv.messages.append(SubagentMsg(role: .task, text: info.task, isStreaming: false))
            convMap[info.id] = conv
        }
        conversations[sessionID] = convMap

        var list = cards[sessionID] ?? []
        if let idx = list.firstIndex(where: { $0.id == info.id }) {
            list[idx].status = .running
        } else {
            list.append(SubagentCard(id: info.id, name: info.name, status: .running))
        }
        cards[sessionID] = list
        scheduleSave(sessionID: sessionID)
    }

    /// 同一子代理被追加新任务（复用场景）：在已有对话里追加一条 task 消息，
    /// 并把状态重置为运行中（出错/完成后复用的子代理不再保留旧态，P7）。
    func addTask(sessionID: UUID, info: SubagentInfo, task: String) {
        guard let conv = conversations[sessionID]?[info.id] else { return }
        conv.status = .running
        conv.messages.append(SubagentMsg(role: .task, text: task, isStreaming: false))
        if var list = cards[sessionID], let idx = list.firstIndex(where: { $0.id == info.id }) {
            list[idx].status = .running
            cards[sessionID] = list
        }
        scheduleSave(sessionID: sessionID)
    }

    /// 流式 词元：累加到「当前正在流式」的回复消息（无则新建流式回复消息）。
    /// 「当前回复」= 对话里最后一条消息若为 `.response` 即它，否则新建一条（保证复用新任务时
    /// 不会把内容错 append 到上一条已完成回复）。
    /// 正文 词元 节流缓冲（2026-08-07，与主会话 ChatSessionRuntime 同构）：
    /// 每 词元 先入缓冲，~100ms 单窗口批量提交——详情页重绘 + Markdown 全量解析
    /// 从「每 词元 一次」降到约 10fps，与主会话流式规格完全一致。
    private var pendingSubagentText: [UUID: [UUID: String]] = [:]
    /// 思考 词元 节流缓冲（与正文共享同一提交窗口，先刷思考后刷正文，顺序同主会话）。
    private var pendingSubagentReasoning: [UUID: [UUID: [(piece: String, index: Int, order: Int)]]] = [:]
    /// 节流调度标志：一个窗口只起一次 sleep 任务（避免每 token 建 Task）。
    private var flushScheduled = false

    func appendToken(sessionID: UUID, info: SubagentInfo, piece: String) {
        pendingSubagentText[sessionID, default: [:]][info.id, default: ""] += piece
        scheduleFlush()
    }

    /// 子代理工具调用：挂到「当前回复」上（与主线 streamingToolCalls 同语义）。
    /// position 修正：与主会话一致 = 事件发生时「已输出正文长度」（主会话用
    /// streamingContent.count）。原实现硬编码 0 导致 MessageBubbleView 的
    /// 文本片段插入逻辑失效（entryPos > textCursor 恒 false）→ 思考/工具卡全部
    /// 堆在正文前、正文整体甩到末尾，与主会话「穿插」观感不一致。
    func appendToolCall(sessionID: UUID, info: SubagentInfo, event: ToolCallEvent) {
        guard let conv = conversations[sessionID]?[info.id] else { return }
        let m = currentOrNewResponse(conv)
        var ev = event
        ev.position = m.text.count
        m.toolCalls.append(ev)
        scheduleSave(sessionID: sessionID)
    }

    /// 子代理工具结果：按模型调用 id 精确配对回填（并发同名工具防串台，与主链路一致）。
    func appendToolResult(sessionID: UUID, info: SubagentInfo, callID: String, name: String, resultText: String, success: Bool, duration: TimeInterval) {
        guard let conv = conversations[sessionID]?[info.id] else { return }
        let m = currentOrNewResponse(conv)
        if let idx = m.toolCalls.firstIndex(where: { $0.callID == callID }) {
            m.toolCalls[idx].resultText = resultText
            m.toolCalls[idx].success = success
            m.toolCalls[idx].duration = duration
        }
        scheduleSave(sessionID: sessionID)
    }

    /// 子代理分段思考：按迭代序号把思考切成独立段（命中已存在段则追加文本，否则新建段）。
    /// 新建段的 position 与主会话同语义 = 当前已输出正文长度（m.text.count）。
    func appendReasoning(sessionID: UUID, info: SubagentInfo, text: String, index: Int, timelineOrder: Int) {
        pendingSubagentReasoning[sessionID, default: [:]][info.id, default: []].append((text, index, timelineOrder))
        scheduleFlush()
    }

    /// 更新子代理头部模型信息（运行结束时写入：实际模型 + 思考强度，供详情页头部展示）。
    func updateModelInfo(sessionID: UUID, info: SubagentInfo, modelDisplay: String, thinkingDisplay: String) {
        guard let conv = conversations[sessionID]?[info.id] else { return }
        conv.modelDisplay = modelDisplay
        conv.thinkingDisplay = thinkingDisplay
        scheduleSave(sessionID: sessionID)
    }

    /// 子代理出错：状态置红 + 把错误文本并入「当前回复」并标记为已中断（与主线被中断回复一致）。
    func markError(sessionID: UUID, info: SubagentInfo, desc: String) {        if let conv = conversations[sessionID]?[info.id] {
            conv.status = .error
            let m = currentOrNewResponse(conv)
            m.wasInterrupted = true
            m.isStreaming = false
            if m.text.isEmpty {
                m.text = String(format: L10n.tr("⚠️ %@"), desc)
            } else {
                m.text += String(format: L10n.tr("\n\n⚠️ %@"), desc)
            }
        }
        if var list = cards[sessionID], let idx = list.firstIndex(where: { $0.id == info.id }) {
            list[idx].status = .error
            cards[sessionID] = list
        }
        scheduleSave(sessionID: sessionID)
            flushNow()
}

    /// 子代理结束：标记在途回复结束并置「已完成」。**保留头像与对话**（不移除），供用户随时回看。
    /// 仅运行中状态升级为已完成——已取消/已出错是终态，不覆盖（B2）。
    func finishSubagent(sessionID: UUID, info: SubagentInfo) {
        if let conv = conversations[sessionID]?[info.id] {
            if conv.status == .running {
                conv.status = .completed
            }
            if let last = conv.messages.last, last.role == .response {
                last.isStreaming = false
            }
        }
        if var list = cards[sessionID], let idx = list.firstIndex(where: { $0.id == info.id }) {
            if list[idx].status == .running {
                list[idx].status = .completed
            }
            cards[sessionID] = list
        }
        scheduleSave(sessionID: sessionID)
            flushNow()
}

    /// 子代理被取消/中断：置「已取消」（终态，运行期事件与启动恢复共用）。
    func markCancelled(sessionID: UUID, subagentID: UUID) {
        if let conv = conversations[sessionID]?[subagentID] {
            conv.status = .cancelled
            if let last = conv.messages.last, last.role == .response {
                last.isStreaming = false
                last.wasInterrupted = true
            }
        }
        if var list = cards[sessionID], let idx = list.firstIndex(where: { $0.id == subagentID }) {
            list[idx].status = .cancelled
            cards[sessionID] = list
        }
        scheduleSave(sessionID: sessionID)
            flushNow()
}

    /// 用户长按头像手动移除某个子代理（清理悬浮条）。
    func removeSubagent(sessionID: UUID, subagentID: UUID) {
        var convMap = conversations[sessionID] ?? [:]
        convMap[subagentID] = nil
        conversations[sessionID] = convMap

        if var list = cards[sessionID] {
            list.removeAll { $0.id == subagentID }
            cards[sessionID] = list
        }
        scheduleSave(sessionID: sessionID)
    }

    /// 会话被删除时整体清理：清内存 + 删除该会话的 subagent 文件（随会话目录消失）。
    func clearSession(_ sessionID: UUID) {
        conversations[sessionID] = nil
        cards[sessionID] = nil
        dirtySessions.remove(sessionID)
        saveTask?.cancel()
        // 直接拼 URL，不经 sessionHostDirectory：避免 ensureHostDirs 在会话目录
        // 已删除后重建整棵空目录树（与 SessionManager 的目录删除竞态）。
        let url = SessionFileRouter.sessionsHostBase
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("subagent", isDirectory: true)
            .appendingPathComponent("subagent_store.json")
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 内部辅助

    /// 取得「当前正在流式」的回复消息：若对话最后一条是 `.response` 则取其引用，
    /// 否则新建一条空白流式回复并追加。返回引用（SubagentMsg 为 class），调用方直接改其属性即可触发观察。
    private func currentOrNewResponse(_ conv: SubagentConversation) -> SubagentMsg {
        if let last = conv.messages.last, last.role == .response {
            return last
        }
        let m = SubagentMsg(role: .response, text: "", isStreaming: true)
        conv.messages.append(m)
        return m
    }
}
