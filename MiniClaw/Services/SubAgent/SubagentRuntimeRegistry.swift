import Foundation

/// 子代理运行期记录：复用所需的最小状态（身份 + 聚焦 + 对话历史）。
/// 不长期持有活引擎实例（方案 C）：复用前由 `AgentLoopEngine.spawnSubagent`
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
/// **跨重启恢复（B 方案）**：每次 upsert 后把记录落盘到
/// `MiniClaw-Sessions/<会话UUID>/subagent/runtime_records.json`（与 subagent_store.json 同目录，
/// 职责单一、随会话目录删除自动消失）；App 启动时 `rebuild()` 扫描恢复。
/// 恢复后复用分支照常命中，子代理的「身份 + 角色 + 聚焦 + 上下文历史」跨 App 重启不丢。
///
/// **线程安全**：所有对内部字典的读写均通过 `lock` 保护，避免并发数据竞争导致 EXC_BAD_ACCESS 崩溃。
/// 落盘经后台队列做原子写文件，不阻塞主线程。
final class SubagentRuntimeRegistry: @unchecked Sendable {
    nonisolated(unsafe) static let shared = SubagentRuntimeRegistry()

    /// sessionID -> (subagentID -> 运行期记录)
    private var store: [UUID: [UUID: SubagentRuntimeRecord]] = [:]
    private let lock = NSLock()
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
        lock.unlock()
        persist(sessionID: sessionID)
    }

    /// 移除某个会话下全部的子代理运行期记录（删除会话时调用，避免内存泄漏）。
    func clear(sessionID: UUID) {
        lock.lock()
        store[sessionID] = nil
        lock.unlock()
        // 文件随会话目录删除自动消失，这里不再单独删（避免半删残留）。
    }

    // MARK: - 持久化（跨重启恢复，B 方案）

    /// 会话级文件路径：`MiniClaw-Sessions/<会话UUID>/subagent/runtime_records.json`。
    private func fileURL(for sessionID: UUID) -> URL {
        let base = SessionFileRouter.shared.sessionHostDirectory(for: sessionID)
        return base.appendingPathComponent("subagent", isDirectory: true)
            .appendingPathComponent("runtime_records.json")
    }

    /// 落盘快照（值类型，跨线程安全传递）。ChatCompletionMessage 已是 Codable。
    private struct Snapshot: Codable {
        var records: [String: [String: SubagentRuntimeRecord]] = [:]
    }

    /// upsert/remove 后异步落盘：锁外取快照 → 后台队列编码写文件。
    private func persist(sessionID: UUID) {
        lock.lock()
        // Snapshot 的 key 是 String（UUID.uuidString），这里做一次显式转换。
        var bySubString: [String: SubagentRuntimeRecord] = [:]
        if let bySub = store[sessionID] {
            for (k, v) in bySub { bySubString[k.uuidString] = v }
        }
        let snapshot = Snapshot(records: [sessionID.uuidString: bySubString])
        lock.unlock()
        let url = fileURL(for: sessionID)
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// App 启动时调用：扫描全部会话目录，恢复各会话的子代理运行期记录。
    /// 须在 UI 使用注册表前调用一次（幂等：重复调用会覆盖为磁盘状态）。
    func rebuild() {
        // 冷启动双扫全部会话目录 + JSON 解码移后台（线程治理 P0）：
        // 内部字典有 lock 保护，后台线程直接写入安全，无需回主线程。
        // 用 GCD 而非 Task.detached：Swift 6.2 的 NSLock 在 async 上下文不可用，
        // GCD 闭包是同步上下文，lock/unlock 合法。
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var recovered: [UUID: [UUID: SubagentRuntimeRecord]] = [:]
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: SessionFileRouter.sessionsHostBase,
                includingPropertiesForKeys: nil
            ) else { return }
            for entry in entries {
                guard let sid = UUID(uuidString: entry.lastPathComponent) else { continue }
                let url = entry.appendingPathComponent("subagent", isDirectory: true)
                    .appendingPathComponent("runtime_records.json")
                guard let data = try? Data(contentsOf: url),
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
