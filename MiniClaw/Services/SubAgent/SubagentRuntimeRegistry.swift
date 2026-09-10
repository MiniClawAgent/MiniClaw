import Foundation

/// 子代理运行期记录：复用所需的最小状态（身份 + 聚焦 + 对话历史）。
/// 不长期持有活引擎实例（方案 C）：复用前由 `AgentLoopEngine.dispatchSubagent`
/// 重建子引擎，并用这里的 `history` 调 `run(userMessage:history:)` 接续上下文。
struct SubagentRuntimeRecord: Codable, Sendable {
    let id: UUID
    let info: SubagentInfo
    let focus: String?
    /// 角色（profile）名：复用重建引擎时保持人设一致（否则会静默重置为 general）。
    let profile: String?
    var history: [ChatCompletionMessage]
    /// 当前状态（清单注入展示用；终态在 runSubagent 末尾 upsert 时更新）。
    var status: SubagentStatus = .running

    enum CodingKeys: String, CodingKey { case id, info, focus, profile, history, status }

    init(id: UUID, info: SubagentInfo, focus: String?, profile: String?, history: [ChatCompletionMessage], status: SubagentStatus = .running) {
        self.id = id
        self.info = info
        self.focus = focus
        self.profile = profile
        self.history = history
        self.status = status
    }

    /// 兼容旧落盘数据：status 缺键时回落 running（该字段仅展示用途，无功能影响）。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        info = try c.decode(SubagentInfo.self, forKey: .info)
        focus = try c.decodeIfPresent(String.self, forKey: .focus)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        history = try c.decodeIfPresent([ChatCompletionMessage].self, forKey: .history) ?? []
        status = try c.decodeIfPresent(SubagentStatus.self, forKey: .status) ?? .running
    }
}

/// 子代理运行期注册表（按会话持久，线程安全，跨 App 重启恢复）。
///
/// 复用机制原本挂在 `AgentLoopEngine.subagentRegistry` 上，但主引擎每轮用户消息都会被重建
/// （`appState.chatRuntimes[session.id] = nil` 后下次 `buildEngine` 造新实例），注册表随引擎一起
/// 被销毁，导致子代理永远无法跨轮复用。这里把「身份 + 上下文历史」抽出来，按 `sessionID` 存
/// 会话级单例，跨用户轮次存活，使主 智能体能用同一 `subagent_id` 在后续轮次继续向同一子代理派发任务。
///
/// **跨重启恢复(B 方案)**：每次 upsert 后把记录写入 SQLite(`session_blobs` 表,
/// kind=runtime_records,与 subagent_store 同库);App 启动时 `rebuild()` 从库恢复。
/// 恢复后复用分支照常命中，子代理的「身份 + 角色 + 聚焦 + 上下文历史」跨 App 重启不丢。
///
/// **线程安全**：所有对内部字典的读写均通过 `lock` 保护，避免并发数据竞争导致 EXC_BAD_ACCESS 崩溃。
/// 落盘经后台队列做原子写文件，不阻塞主线程。
final class SubagentRuntimeRegistry: @unchecked Sendable {
    static let shared = SubagentRuntimeRegistry()

    /// sessionID -> (subagentID -> 运行期记录)
    private var store: [UUID: [UUID: SubagentRuntimeRecord]] = [:]
    private let lock = NSLock()
    /// 最近关闭记录（sessionID → subID → 关闭时间，60s 过期）。
    /// 2026-09-10：模型有「核实性重复关闭」习惯（对刚关闭的 id 再 close 一次确认），
    /// 此前二次关闭的短码在 store 里已查不到 → 解析层直接报「需要有效的 subagent_id」，
    /// 语义完全误导（模型被迫编造解释）。保留短窗口关闭记录，让二次关闭返回
    /// 「已关闭，无需重复关闭」的正确语义。
    private var recentlyClosed: [UUID: [UUID: Date]] = [:]
    /// 落盘队列（值类型快照 → Data → 原子写入，写文件不占主线程）。
    private let ioQueue = DispatchQueue(label: "subagent-runtime-registry-io")

    private init() {}

    // MARK: - 查询 / 写入

    func record(for sessionID: UUID, subagentID: UUID) -> SubagentRuntimeRecord? {
        lock.lock()
        defer { lock.unlock() }
        return store[sessionID]?[subagentID]
    }

    /// 某会话下全部子代理记录（A 方案清单注入用；按 id 排序保证输出稳定）。
    func allRecords(for sessionID: UUID) -> [SubagentRuntimeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array((store[sessionID] ?? [:]).values).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func upsert(sessionID: UUID, record: SubagentRuntimeRecord) {
        lock.lock()
        var bySub = store[sessionID] ?? [:]
        bySub[record.id] = record
        store[sessionID] = bySub
        lock.unlock()
        persist(sessionID: sessionID)
    }

    /// 仅更新「已存在」的记录（close 竞态防护）：runSubagent 尾处理调用——
    /// 若该子代理已被 close_subagent 删除，则不重建（防止「关闭后记录复活」）。
    func updateIfPresent(sessionID: UUID, record: SubagentRuntimeRecord) {
        lock.lock()
        guard store[sessionID]?[record.id] != nil else {
            lock.unlock()
            return
        }
        store[sessionID]?[record.id] = record
        lock.unlock()
        persist(sessionID: sessionID)
    }

    /// 移除单个子代理记录（close_subagent / 用户长按删除时调用，防止「关闭后又被复用」）。
    func remove(sessionID: UUID, subagentID: UUID) {
        lock.lock()
        store[sessionID]?[subagentID] = nil
        if store[sessionID]?.isEmpty == true { store[sessionID] = nil }
        recentlyClosed[sessionID, default: [:]][subagentID] = Date()
        lock.unlock()
        persist(sessionID: sessionID)
    }

    /// 短码（或完整 UUID 串）是否命中 60s 内刚关闭的子代理；命中返回完整 id。
    /// 过期条目惰性清理；查不到返回 nil（与「从未存在」不可区分——调用方按无效 id 处理）。
    func recentlyClosedID(for sessionID: UUID, token: String) -> UUID? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count >= 4, UUID(uuidString: token) == nil else { return nil }
        let cutoff = Date().addingTimeInterval(-60)
        lock.lock()
        defer { lock.unlock() }
        guard var bySub = recentlyClosed[sessionID] else { return nil }
        if bySub.values.contains(where: { $0 <= cutoff }) {
            bySub = bySub.filter { $0.value > cutoff }
            recentlyClosed[sessionID] = bySub.isEmpty ? nil : bySub
        }
        for (id, _) in bySub where id.uuidString.lowercased().hasPrefix(t) {
            return id
        }
        return nil
    }

    /// 移除某个会话下全部的子代理运行期记录（删除会话时调用，避免内存泄漏）。
    func clear(sessionID: UUID) {
        lock.lock()
        store[sessionID] = nil
        recentlyClosed[sessionID] = nil
        lock.unlock()
        // 同步删除 SQLite 行，避免残留（会话删除路径）。
        ioQueue.async {
            SQLiteStore.shared.deleteBlob(sessionID: sessionID, kind: .runtimeRecords)
        }
    }

    // MARK: - 持久化（跨重启恢复，B 方案）

    /// 落盘快照（值类型，跨线程安全传递）。ChatCompletionMessage 已是 Codable。
    private struct Snapshot: Codable {
        var records: [String: [String: SubagentRuntimeRecord]] = [:]
    }

    /// upsert/remove 后异步落库：锁外取快照 → 后台队列编码写 SQLite。
    private func persist(sessionID: UUID) {
        lock.lock()
        // Snapshot 的 key 是 String（UUID.uuidString），这里做一次显式转换。
        var bySubString: [String: SubagentRuntimeRecord] = [:]
        if let bySub = store[sessionID] {
            for (k, v) in bySub { bySubString[k.uuidString] = v }
        }
        let snapshot = Snapshot(records: [sessionID.uuidString: bySubString])
        lock.unlock()
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            SQLiteStore.shared.saveBlob(sessionID: sessionID, kind: .runtimeRecords, payload: data)
        }
    }

    /// App 启动时调用：从 SQLite 恢复各会话的子代理运行期记录。
    /// 须在 UI 使用注册表前调用一次（幂等：重复调用会覆盖为库内状态）。
    func rebuild() {
        // 冷启动全量读库 + JSON 解码移后台（线程治理 P0）：
        // 内部字典有 lock 保护，后台线程直接写入安全，无需回主线程。
        // 用 GCD 而非 Task.detached：Swift 6.2 的 NSLock 在 async 上下文不可用，
        // GCD 闭包是同步上下文，lock/unlock 合法。
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var recovered: [UUID: [UUID: SubagentRuntimeRecord]] = [:]
            let blobs = SQLiteStore.shared.loadBlobs(kind: .runtimeRecords)
            for (sid, payloadOpt) in blobs {
                guard let data = payloadOpt,
                      let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
                      let bySub = snap.records[sid.uuidString] else { continue }
                var m: [UUID: SubagentRuntimeRecord] = [:]
                for (k, v) in bySub where UUID(uuidString: k) != nil {
                    m[UUID(uuidString: k)!] = v
                }
                if !m.isEmpty { recovered[sid] = m }
            }
            self.lock.lock()
            self.store = recovered
            self.lock.unlock()
        }
    }
}
