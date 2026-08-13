import Foundation

// MARK: - Agent Task（暂停/恢复检查点）

/// 一次 智能体回复的运行状态。
///
/// 与 `ChatSession.status`（会话级：idle/running/completed）不同，这是
/// **引擎循环级** 的细粒度状态机，用于支撑「暂停 → 恢复」。
///
/// - `running`：循环正常推进中。v1 会在每轮完成后把 `messages` 落盘为此状态，
///   以支持 App 被系统杀死后的冷恢复（下次进入会话自动续跑）。
/// - `paused`：用户在某安全点（流式回合结束、或某个工具执行完）请求了暂停，
///   上下文已快照到 `messages`，等待用户点「继续」重放。
/// - `completed` / `failed` / `cancelled`：终态（v1 落盘后即清除检查点文件，一般不持久化）。
/// - `interrupted`：启动时发现上次是 `running` 但 App 已被杀，转为该状态以提示用户。
/// - `pausing`：过渡态，引擎已收到暂停请求但尚在安全点之间（v1 几乎瞬时落地，不持久化）。
enum AgentTaskStatus: String, Codable {
    case running
    case pausing
    case paused
    case completed
    case failed
    case cancelled
    case interrupted
}

/// 一个会话「当前正在进行的回复」的可持久化检查点。
///
/// 这是暂停/恢复的唯一真源：暂停瞬间把引擎循环的权威上下文 `messages`
/// （含 system + 历史 + 已完成的 assistant/tool 回合 + 本轮已收文本）整体落盘；
/// 恢复时直接重放 `messages` 开一个新 Loop，无需从 SwiftData 会话历史重建
/// （会话历史在 `ChatView` 构建时过滤掉了 tool 角色消息，无法还原工具配对）。
struct AgentTask: Codable, Identifiable {
    /// 检查点 ID，恒等于 `sessionID`（一个会话同时只有一个活跃任务）。
    var id: UUID
    /// 所属会话（同时用作落盘文件名 `runs/<sessionID>.json` 的 key）。
    var sessionID: UUID
    /// 当前状态。
    var status: AgentTaskStatus
    /// 引擎循环的权威消息上下文（恢复时整体重放）。
    var messages: [ChatCompletionMessage]
    /// 恢复时继续使用的候选端点索引（避免每轮跳回主模型）。
    var activeEndpointIndex: Int
    /// 排队中的用户消息（回复进行中用户继续发来的内容）。
    var pendingUserInputs: [String]
    /// 循环迭代计数（熔断/安全阀用，恢复后延续）。
    var loopIteration: Int
    /// 某条助手气泡的 ID：暂停/恢复时续写同一气泡，避免生成第二个回复气泡。
    var assistantMessageID: UUID?
    /// 最后更新时间（用于排查与排序）。
    var updatedAt: Date

    init(
        id: UUID,
        sessionID: UUID,
        status: AgentTaskStatus,
        messages: [ChatCompletionMessage],
        activeEndpointIndex: Int,
        pendingUserInputs: [String],
        loopIteration: Int,
        assistantMessageID: UUID?,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.status = status
        self.messages = messages
        self.activeEndpointIndex = activeEndpointIndex
        self.pendingUserInputs = pendingUserInputs
        self.loopIteration = loopIteration
        self.assistantMessageID = assistantMessageID
        self.updatedAt = updatedAt
    }
}

/// 检查点持久化：按会话 ID 存入 SQLite(`session_blobs` 表,kind=agent_task)。
///
/// 落盘时机(v1)：
/// - 每轮助手回合完成后写 `running`(支撑 App 被杀冷恢复)；
/// - 用户暂停的安全点写 `paused`；
/// - 终态(完成/失败/取消)立即删除,避免残留误导恢复。
final class AgentTaskStore: @unchecked Sendable {
    static let shared = AgentTaskStore()

    /// 检查点读写串行队列：save/load/clear 全部经此排队。
    /// 引擎循环（后台）每轮写检查点与主线程 cancel()/stopGeneration() 的 clear 并发执行时，
    /// 串行化保证"先 clear 后写残留 .running"、"先写后 clear 正常清除"二选一，
    /// 不会出现交错(配合 saveCheckpoint 的活跃性守卫，彻底杜绝已取消任务"复活")。
    private let queue = DispatchQueue(label: "miniclaw-agent-task-store")

    func save(_ task: AgentTask) {
        queue.sync {
            do {
                let data = try JSONEncoder().encode(task)
                SQLiteStore.shared.saveBlob(sessionID: task.sessionID, kind: .agentTask, payload: data)
            } catch {
                AppLogger.shared.error("保存 AgentTask 检查点失败（session=\(task.sessionID.uuidString.prefix(8))）：\(error.localizedDescription)", category: "Agent", subsystem: "Checkpoint")
            }
        }
    }

    func load(sessionID: UUID) -> AgentTask? {
        queue.sync {
            guard let data = SQLiteStore.shared.loadBlob(sessionID: sessionID, kind: .agentTask) else { return nil }
            do {
                return try JSONDecoder().decode(AgentTask.self, from: data)
            } catch {
                AppLogger.shared.error("读取 AgentTask 检查点失败（session=\(sessionID.uuidString.prefix(8))）：\(error.localizedDescription)", category: "Agent", subsystem: "Checkpoint")
                return nil
            }
        }
    }

    func clear(sessionID: UUID) {
        queue.sync {
            SQLiteStore.shared.deleteBlob(sessionID: sessionID, kind: .agentTask)
        }
    }

    /// 启动时调用：若上次是 `running`（说明 App 被杀、循环未正常收尾），
    /// 转为 `interrupted` 以便 UI 显式提示用户「上次回复中断，可继续」。
    /// 注意：load/save 内部已自带 queue.sync 串行化，此处**不能**再包一层 sync
    /// （串行队列递归同步自身 = 死锁）。
    func markInterruptedIfRunning(sessionID: UUID) {
        guard let task = load(sessionID: sessionID), task.status == .running else { return }
        var updated = task
        updated.status = .interrupted
        updated.updatedAt = Date()
        save(updated)
    }
}

// MARK: - 排队消息 / 输入草稿持久化

/// 把「排队消息」与「输入栏未发送草稿」落盘为磁盘真源，
/// 使它们跨 **杀后台 / 退出会话 / App 重启** 仍可被用户重新进入会话后继续编辑或推给 智能体。
///
/// 背景：此前排队队列只存在于 `AppState.pendingUserMessages`（内存字典），
/// 回复进行中被杀后台即丢失；草稿 `inputText` 仅存于 `ChatView` 的 `@State`，
/// 退出会话即清空。现统一以 SQLite(`session_blobs` 表,kind=pending_queue / pending_draft)
/// 为磁盘真源：
/// - 队列：每次增删都落盘，且与内存字典保持单一方向同步（字典变 → 写盘）；
///   进入会话时由 `ChatView.restorePersistedState()` 从盘恢复到字典。
/// - 草稿：输入变化即落盘；消息真正发出时清空。
///
/// 注意：排队队列的磁盘真源是这里，**不是** `AgentTask.pendingUserInputs`
/// （检查点只在暂停/恢复瞬间短暂携带，且 `resume()` 会清空它，避免引擎内循环重复处理）。
final class PendingMessageStore: @unchecked Sendable {
    static let shared = PendingMessageStore()

    /// 草稿 blob 落盘/清空完成广播（2026-08-13）：首页笔图标据此即时重算。
    static let pendingDraftDidChange = Notification.Name("pendingDraftDidChange")

    /// 落盘串行队列（线程治理 2026-08-09）：发消息/排队/草稿高频写库移后台。
    private let ioQueue = DispatchQueue(label: "pending-message-store-io")

    // MARK: 排队队列

    /// 落盘当前排队队列；空数组等价于清空（删除 blob）。落库移后台（线程治理 2026-08-09）。
    func save(_ messages: [PendingUserMessage], for sessionID: UUID) {
        let sid = sessionID
        ioQueue.async { [self] in
            do {
                if messages.isEmpty {
                    SQLiteStore.shared.deleteBlob(sessionID: sid, kind: .pendingQueue)
                    return
                }
                let data = try JSONEncoder().encode(messages)
                SQLiteStore.shared.saveBlob(sessionID: sid, kind: .pendingQueue, payload: data)
            } catch {
                AppLogger.shared.error("保存排队消息失败（session=\(sid.uuidString.prefix(8))）：\(error.localizedDescription)", category: "Agent", subsystem: "Queue")
            }
        }
    }

    /// 读取落盘的排队队列；无记录返回 `nil`。
    func load(for sessionID: UUID) -> [PendingUserMessage]? {
        guard let data = SQLiteStore.shared.loadBlob(sessionID: sessionID, kind: .pendingQueue) else { return nil }
        do {
            return try JSONDecoder().decode([PendingUserMessage].self, from: data)
        } catch {
            AppLogger.shared.error("读取排队消息失败（session=\(sessionID.uuidString.prefix(8))）：\(error.localizedDescription)", category: "Agent", subsystem: "Queue")
            return nil
        }
    }

    // MARK: 输入草稿

    /// 落盘输入栏未发送内容；空白文本等价于清空（删除 blob）。落库移后台（线程治理 2026-08-09）。
    func saveDraft(_ text: String, for sessionID: UUID) {
        let sid = sessionID
        ioQueue.async { [self] in
            do {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SQLiteStore.shared.deleteBlob(sessionID: sid, kind: .pendingDraft)
                } else {
                    let payload = ["text": text]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    SQLiteStore.shared.saveBlob(sessionID: sid, kind: .pendingDraft, payload: data)
                }
                // 2026-08-13 治标：草稿落盘/清空完成后广播——首页会话行的笔图标
                // (hasDraft) 是读时计算且列表不随草稿文件变化重绘，不广播会残留。
                NotificationCenter.default.post(
                    name: PendingMessageStore.pendingDraftDidChange,
                    object: nil,
                    userInfo: ["sessionID": sid]
                )
            } catch {
                AppLogger.shared.error("保存输入草稿失败（session=\(sid.uuidString.prefix(8))）：\(error.localizedDescription)", category: "Agent", subsystem: "Draft")
            }
        }
    }

    /// 读取落盘的输入草稿；无记录或空白返回 `nil`。
    func loadDraft(for sessionID: UUID) -> String? {
        guard let data = SQLiteStore.shared.loadBlob(sessionID: sessionID, kind: .pendingDraft) else { return nil }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    /// 清空某会话的输入草稿（消息真正发出时调用）。删除移后台（线程治理 2026-08-09）。
    func clearDraft(for sessionID: UUID) {
        let sid = sessionID
        ioQueue.async { [self] in
            SQLiteStore.shared.deleteBlob(sessionID: sid, kind: .pendingDraft)
        }
    }
}
