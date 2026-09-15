import Foundation
import SQLite3

/// 会话数据 SQLite 存储层(2026-08-12,由「每会话 JSON 文件」迁移而来)。
///
/// 存储范围(用户拍板):会话主数据(sessions/messages 两表)+ 会话附属数据
/// (session_blobs 统一表,存原始 JSON 字节保真);其余(文件产物/记忆/配置/缓存日志)
/// 保持文件系统不变。
///
/// 库位置:`Documents/MiniClaw/sessions/miniclaw.db`(WAL 模式)。备份 = 复制单个 db 文件
/// (注意 WAL 一致性:备份前先 checkpoint 或连同 -wal/-shm 一起复制)。
///
/// 线程模型:单句柄 + 串行队列,所有读写经 queue 串行执行;对外暴露同步方法,
/// 高频写由上层各自的串行队列合并提交(与原有「JSON 文件读同步/写异步」语义对齐)。
final class SQLiteStore: @unchecked Sendable {
    static let shared = SQLiteStore()

    /// 附属 blob 的类别(按会话聚合,每会话每类一行)。
    enum BlobKind: String {
        case subagentStore = "subagent_store"
        case runtimeRecords = "runtime_records"
        case agentTask = "agent_task"
        case pendingQueue = "pending_queue"
        case pendingDraft = "pending_draft"
    }

    /// 会话持久化行快照(纯值类型,可在主线程提取后跨线程传送到存储队列落库,
    /// 避免把非 Sendable 的 ChatSession 对象带进 DispatchQueue.async 闭包)。
    struct SessionPersistRows: Sendable {
        struct MessageRow: Sendable {
            var id: UUID
            var roleRaw: String
            var content: String
            var createdAt: Date
            var isStreaming: Bool
            /// 2026-08-12 治本:消息级暂停标志(暂停即落盘,重启后指示器/内容可恢复)。
            var isPaused: Bool
            var wasStopped: Bool?
            var wasInterrupted: Bool
            var taskElapsedSeconds: Double?
            var toolCallName: String?
            var toolCallResult: String?
            var toolCallsData: Data?
            var attachmentsData: Data?
            var reasoning: String?
            var previewText: String?
            var reasoningSegmentsData: Data?
            /// [2026-09-15 缓存治本] API 请求体里 content 之后必须逐字重放的后缀（易变段快照）。
            var apiContextSuffix: String?
        }
        var id: UUID
        var title: String
        var titleIsPlaceholder: Bool
        var createdAt: Date
        var updatedAt: Date
        var modelName: String
        var agentName: String
        var source: String
        var statusRaw: String
        var isPinned: Bool
        var reviewedMessageCount: Int
        var icon: String?
        var iconColor: String?
        var iconBackgroundColor: String?
        var thinkingLevel: String?
        var summary: String?
        var compactAnchorID: UUID?
        var compactSummary: String?
        var disabledMCPServerIDs: [UUID]?
        var messages: [MessageRow]

        /// 主线程调用:把 ChatSession(含消息)提取为值类型快照。
        static func extract(from session: ChatSession) -> SessionPersistRows {
            SessionPersistRows(
                id: session.id, title: session.title, titleIsPlaceholder: session.titleIsPlaceholder,
                createdAt: session.createdAt, updatedAt: session.updatedAt,
                modelName: session.modelName, agentName: session.agentName, source: session.source,
                statusRaw: session.statusRaw, isPinned: session.isPinned,
                reviewedMessageCount: session.reviewedMessageCount, icon: session.icon,
                iconColor: session.iconColor, iconBackgroundColor: session.iconBackgroundColor,
                thinkingLevel: session.thinkingLevel, summary: session.summary,
                compactAnchorID: session.compactAnchorID, compactSummary: session.compactSummary,
                disabledMCPServerIDs: session.disabledMCPServerIDs,
                messages: session.messages.map {
                    MessageRow(id: $0.id, roleRaw: $0.roleRaw, content: $0.content, createdAt: $0.createdAt,
                               isStreaming: $0.isStreaming, isPaused: $0.isPaused, wasStopped: $0.wasStopped,
                               wasInterrupted: $0.wasInterrupted, taskElapsedSeconds: $0.taskElapsedSeconds,
                               toolCallName: $0.toolCallName, toolCallResult: $0.toolCallResult,
                               toolCallsData: $0.toolCallsData, attachmentsData: $0.attachmentsData,
                               reasoning: $0.reasoning, previewText: $0.previewText,
                               reasoningSegmentsData: $0.reasoningSegmentsData,
                               apiContextSuffix: $0.apiContextSuffix)
                }
            )
        }
    }

    private let queue = DispatchQueue(label: "MiniClaw.SQLiteStore")
    private var db: OpaquePointer?
    private var opened = false

    private init() {}

    /// 库文件路径:Documents/MiniClaw/sessions/miniclaw.db
    /// (虚拟路径 /var/MiniClaw/sessions/miniclaw.db,2026-08-13 一步到位迁入子目录,
    /// 未上线不做旧库迁移)。
    private var dbURL: URL {
        FileSystemManager.shared.miniClawRoot.appendingPathComponent("sessions/miniclaw.db")
    }

    /// 打开(或已打开则跳过)+ PRAGMA + 建表。仅内部调用。
    private func openIfNeeded() {
        guard !opened else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rc = sqlite3_open(dbURL.path, &db)
        guard rc == SQLITE_OK, db != nil else {
            AppLogger.shared.error("SQLiteStore.open 失败: rc=\(rc)", category: "Session", subsystem: "SQLite")
            return
        }
        _ = exec("PRAGMA journal_mode=WAL")
        _ = exec("PRAGMA foreign_keys=ON")
        _ = exec("PRAGMA busy_timeout=5000")
        // createTables 失败绝不置 opened：否则表缺失时后续 prepare 全部失败且被静默忽略,
        // 会话写入永久丢失(2026-08-12 回归修复)。
        guard createTables() else {
            AppLogger.shared.error("SQLiteStore.createTables 失败,存储不可用(本次会话数据不落盘)",
                                   category: "Session", subsystem: "SQLite")
            if let db { sqlite3_close(db) }
            db = nil
            return
        }
        // 2026-08-12 紧急修复:旧库迁移——messages 表新增 is_paused 列时,
        // CREATE TABLE IF NOT EXISTS 不会给已存在的旧表加列;旧库 SELECT/INSERT
        // 带 is_paused 会报 no such column → 重启后所有会话读不出来(首页全空)。
        migrateSchemaIfNeeded()
        opened = true
    }

    /// 列级迁移:检查指定表是否缺列,缺则 ALTER TABLE 补上。
    /// PRAGMA table_info 列序: cid, name, type, notnull, dflt_value, pk。
    private func ensureColumn(table: String, column: String, definition: String) {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil)
        guard rc == SQLITE_OK, stmt != nil else {
            AppLogger.shared.error("SQLiteStore 迁移:PRAGMA table_info(\(table)) 失败 rc=\(rc)",
                                   category: "Session", subsystem: "SQLite")
            return
        }
        defer { sqlite3_finalize(stmt) }
        var hasColumn = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if colText(stmt, 1) == column { hasColumn = true; break }
        }
        if !hasColumn {
            if exec("ALTER TABLE \(table) ADD COLUMN \(definition)") {
                AppLogger.shared.info("SQLiteStore 迁移:\(table) 表已补 \(column) 列", category: "Session", subsystem: "SQLite")
            } else {
                AppLogger.shared.error("SQLiteStore 迁移:ALTER TABLE \(table) ADD \(column) 失败",
                                       category: "Session", subsystem: "SQLite")
            }
        }
    }

    /// 列级迁移集合:messages.is_paused + messages.api_context_suffix
    /// + sessions.compact_anchor_id/compact_summary。
    private func migrateSchemaIfNeeded() {
        ensureColumn(table: "messages", column: "is_paused", definition: "is_paused INTEGER NOT NULL DEFAULT 0")
        // [2026-09-15 缓存治本] 易变段快照后缀:旧库缺列时补上,否则带该列的 SELECT/INSERT 会报
        // no such column → 所有会话读不出来(与 is_paused 同款事故)。
        ensureColumn(table: "messages", column: "api_context_suffix", definition: "api_context_suffix TEXT")
        ensureColumn(table: "sessions", column: "compact_anchor_id", definition: "compact_anchor_id TEXT")
        ensureColumn(table: "sessions", column: "compact_summary", definition: "compact_summary TEXT")
    }

    /// 无参 SQL 执行(DDL/DML)。返回是否成功。
    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            if let errMsg {
                AppLogger.shared.error("SQLiteStore.exec 失败: \(String(cString: errMsg)) SQL=\(String(sql.prefix(100)))",
                                       category: "Session", subsystem: "SQLite")
                sqlite3_free(errMsg)
            }
            return false
        }
        return true
    }

    private func createTables() -> Bool {
        exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            title_is_placeholder INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            model_name TEXT NOT NULL,
            agent_name TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'app',
            status_raw TEXT NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            reviewed_message_count INTEGER NOT NULL DEFAULT 0,
            icon TEXT,
            icon_color TEXT,
            icon_background_color TEXT,
            thinking_level TEXT,
            summary TEXT,
            compact_anchor_id TEXT,
            compact_summary TEXT,
            disabled_mcp_server_ids TEXT
        );
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            role_raw TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            is_streaming INTEGER NOT NULL DEFAULT 0,
            is_paused INTEGER NOT NULL DEFAULT 0,
            was_stopped INTEGER,
            was_interrupted INTEGER NOT NULL DEFAULT 0,
            task_elapsed_seconds REAL,
            tool_call_name TEXT,
            tool_call_result TEXT,
            tool_calls_data BLOB,
            attachments_data BLOB,
            reasoning TEXT,
            preview_text TEXT,
            reasoning_segments_data BLOB,
            api_context_suffix TEXT,
            sort_order INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, sort_order);
        CREATE TABLE IF NOT EXISTS session_blobs (
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            payload BLOB,
            PRIMARY KEY (session_id, kind)
        );
        """)
    }

    // MARK: - 编码辅助

    private static func d(_ date: Date) -> Double { date.timeIntervalSince1970 }
    private static func date(_ v: Double) -> Date { Date(timeIntervalSince1970: v) }
    private static func i(_ b: Bool) -> Int64 { b ? 1 : 0 }
    private static func b(_ v: Int64) -> Bool { v != 0 }
    /// [UUID]? → JSON 文本或 nil。
    private static func mcpIDsJSON(_ ids: [UUID]?) -> String? {
        guard let ids else { return nil }
        guard let data = try? JSONEncoder().encode(ids.map(\.uuidString)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func mcpIDs(_ json: String?) -> [UUID]? {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return arr.compactMap { UUID(uuidString: $0) }
    }

    // MARK: - 会话主数据

    /// 持久化一个会话(便捷入口:内部提取行快照;迁移器等同步场景使用)。
    func saveSession(_ session: ChatSession) {
        saveSessionRows(SessionPersistRows.extract(from: session))
    }

    /// 持久化一个会话(含消息):事务内 upsert sessions 行 + 全量替换 messages 行。
    /// 返回是否成功;任何 prepare/bind/step/COMMIT 失败都会回滚并记录日志(不静默丢数据)。
    @discardableResult
    func saveSessionRows(_ rows: SessionPersistRows) -> Bool {
        queue.sync {
            openIfNeeded()
            guard let db else {
                AppLogger.shared.error("SQLiteStore.saveSessionRows: 数据库未打开,会话 \(rows.id) 未落盘",
                                       category: "Session", subsystem: "SQLite")
                return false
            }
            guard exec("BEGIN TRANSACTION") else {
                AppLogger.shared.error("SQLiteStore.saveSessionRows: BEGIN 失败 session=\(rows.id)",
                                       category: "Session", subsystem: "SQLite")
                return false
            }
            let sid = rows.id.uuidString
            let ok = upsertSessionRow(db, sid: sid, rows: rows)
                && replaceMessageRows(db, sid: sid, rows: rows.messages)
            if ok {
                guard exec("COMMIT") else {
                    _ = exec("ROLLBACK")
                    AppLogger.shared.error("SQLiteStore.saveSessionRows: COMMIT 失败(已回滚) session=\(rows.id)",
                                           category: "Session", subsystem: "SQLite")
                    return false
                }
            } else {
                _ = exec("ROLLBACK")
                AppLogger.shared.error("SQLiteStore.saveSessionRows: 写入失败(已回滚) session=\(rows.id)",
                                       category: "Session", subsystem: "SQLite")
            }
            return ok
        }
    }

    private func upsertSessionRow(_ db: OpaquePointer, sid: String, rows: SessionPersistRows) -> Bool {
        let sql = """
        INSERT INTO sessions (id, title, title_is_placeholder, created_at, updated_at, model_name, agent_name,
                              source, status_raw, is_pinned, reviewed_message_count, icon, icon_color,
                              icon_background_color, thinking_level, summary, compact_anchor_id,
                              compact_summary, disabled_mcp_server_ids)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, title_is_placeholder=excluded.title_is_placeholder,
            created_at=excluded.created_at, updated_at=excluded.updated_at,
            model_name=excluded.model_name, agent_name=excluded.agent_name,
            source=excluded.source, status_raw=excluded.status_raw,
            is_pinned=excluded.is_pinned, reviewed_message_count=excluded.reviewed_message_count,
            icon=excluded.icon, icon_color=excluded.icon_color,
            icon_background_color=excluded.icon_background_color,
            thinking_level=excluded.thinking_level, summary=excluded.summary,
            compact_anchor_id=excluded.compact_anchor_id, compact_summary=excluded.compact_summary,
            disabled_mcp_server_ids=excluded.disabled_mcp_server_ids
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            AppLogger.shared.error("SQLiteStore.upsertSessionRow: prepare 失败 session=\(rows.id)",
                                   category: "Session", subsystem: "SQLite")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, utf8(sid), -1, transient)
        sqlite3_bind_text(stmt, 2, utf8(rows.title), -1, transient)
        sqlite3_bind_int64(stmt, 3, Self.i(rows.titleIsPlaceholder))
        sqlite3_bind_double(stmt, 4, Self.d(rows.createdAt))
        sqlite3_bind_double(stmt, 5, Self.d(rows.updatedAt))
        sqlite3_bind_text(stmt, 6, utf8(rows.modelName), -1, transient)
        sqlite3_bind_text(stmt, 7, utf8(rows.agentName), -1, transient)
        sqlite3_bind_text(stmt, 8, utf8(rows.source), -1, transient)
        sqlite3_bind_text(stmt, 9, utf8(rows.statusRaw), -1, transient)
        sqlite3_bind_int64(stmt, 10, Self.i(rows.isPinned))
        sqlite3_bind_int64(stmt, 11, Int64(rows.reviewedMessageCount))
        bindOptText(stmt, 12, rows.icon)
        bindOptText(stmt, 13, rows.iconColor)
        bindOptText(stmt, 14, rows.iconBackgroundColor)
        bindOptText(stmt, 15, rows.thinkingLevel)
        bindOptText(stmt, 16, rows.summary)
        bindOptText(stmt, 17, rows.compactAnchorID?.uuidString)
        bindOptText(stmt, 18, rows.compactSummary)
        bindOptText(stmt, 19, Self.mcpIDsJSON(rows.disabledMCPServerIDs))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            AppLogger.shared.error("SQLiteStore.upsertSessionRow: step 失败 session=\(rows.id) err=\(String(cString: sqlite3_errmsg(db)))",
                                   category: "Session", subsystem: "SQLite")
            return false
        }
        return true
    }

    private func replaceMessageRows(_ db: OpaquePointer, sid: String, rows: [SessionPersistRows.MessageRow]) -> Bool {
        // 1) 删除旧消息行(失败不静默)
        var del: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM messages WHERE session_id = ?", -1, &del, nil) == SQLITE_OK else {
            AppLogger.shared.error("SQLiteStore.replaceMessageRows: DELETE prepare 失败 session=\(sid)",
                                   category: "Session", subsystem: "SQLite")
            return false
        }
        sqlite3_bind_text(del, 1, utf8(sid), -1, transient)
        let delOK = sqlite3_step(del) == SQLITE_DONE
        sqlite3_finalize(del)
        guard delOK else {
            AppLogger.shared.error("SQLiteStore.replaceMessageRows: DELETE step 失败 session=\(sid)",
                                   category: "Session", subsystem: "SQLite")
            return false
        }

        let sql = """
        INSERT OR REPLACE INTO messages (id, session_id, role_raw, content, created_at, is_streaming,
                                         is_paused, was_stopped, was_interrupted, task_elapsed_seconds,
                                         tool_call_name, tool_call_result, tool_calls_data, attachments_data,
                                         reasoning, preview_text, reasoning_segments_data, api_context_suffix,
                                         sort_order)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            AppLogger.shared.error("SQLiteStore.replaceMessageRows: INSERT prepare 失败 session=\(sid)",
                                   category: "Session", subsystem: "SQLite")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for (idx, m) in rows.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, utf8(m.id.uuidString), -1, transient)
            sqlite3_bind_text(stmt, 2, utf8(sid), -1, transient)
            sqlite3_bind_text(stmt, 3, utf8(m.roleRaw), -1, transient)
            sqlite3_bind_text(stmt, 4, utf8(m.content), -1, transient)
            sqlite3_bind_double(stmt, 5, Self.d(m.createdAt))
            sqlite3_bind_int64(stmt, 6, Self.i(m.isStreaming))
            sqlite3_bind_int64(stmt, 7, Self.i(m.isPaused))
            bindOptInt64(stmt, 8, m.wasStopped.map { Self.i($0) })
            sqlite3_bind_int64(stmt, 9, Self.i(m.wasInterrupted))
            bindOptDouble(stmt, 10, m.taskElapsedSeconds)
            bindOptText(stmt, 11, m.toolCallName)
            bindOptText(stmt, 12, m.toolCallResult)
            bindOptBlob(stmt, 13, m.toolCallsData)
            bindOptBlob(stmt, 14, m.attachmentsData)
            bindOptText(stmt, 15, m.reasoning)
            bindOptText(stmt, 16, m.previewText)
            bindOptBlob(stmt, 17, m.reasoningSegmentsData)
            bindOptText(stmt, 18, m.apiContextSuffix)
            sqlite3_bind_int64(stmt, 19, Int64(idx))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                AppLogger.shared.error("SQLiteStore.replaceMessageRows: INSERT step 失败 session=\(sid) idx=\(idx)",
                                       category: "Session", subsystem: "SQLite")
                return false
            }
        }
        return true
    }

    /// 全量读取所有会话(含消息),按 updatedAt 降序。
    func loadSessions() -> [ChatSession] {
        queue.sync {
            openIfNeeded()
            guard let db else { return [] }
            var result: [ChatSession] = []
            var sstmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                SELECT id, title, title_is_placeholder, created_at, updated_at, model_name, agent_name,
                       source, status_raw, is_pinned, reviewed_message_count, icon, icon_color,
                       icon_background_color, thinking_level, summary, compact_anchor_id,
                       compact_summary, disabled_mcp_server_ids
                FROM sessions ORDER BY updated_at DESC
                """, -1, &sstmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(sstmt) }
            while sqlite3_step(sstmt) == SQLITE_ROW {
                let session = ChatSession(
                    id: UUID(uuidString: colText(sstmt, 0)) ?? UUID(),
                    title: colText(sstmt, 1),
                    modelName: colText(sstmt, 5),
                    agentName: colText(sstmt, 6),
                    source: colText(sstmt, 7),
                    status: SessionStatus(rawValue: colText(sstmt, 8)) ?? .idle,
                    isPinned: Self.b(colInt64(sstmt, 9))
                )
                session.titleIsPlaceholder = Self.b(colInt64(sstmt, 2))
                session.createdAt = Self.date(colDouble(sstmt, 3))
                session.updatedAt = Self.date(colDouble(sstmt, 4))
                session.reviewedMessageCount = Int(colInt64(sstmt, 10))
                session.icon = colOptText(sstmt, 11)
                session.iconColor = colOptText(sstmt, 12)
                session.iconBackgroundColor = colOptText(sstmt, 13)
                session.thinkingLevel = colOptText(sstmt, 14)
                session.summary = colOptText(sstmt, 15)
                if let anchorStr = colOptText(sstmt, 16), let anchorUUID = UUID(uuidString: anchorStr) {
                    session.compactAnchorID = anchorUUID
                }
                session.compactSummary = colOptText(sstmt, 17)
                session.disabledMCPServerIDs = Self.mcpIDs(colOptText(sstmt, 18))
                result.append(session)
            }
            // 批量取消息
            var mstmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                SELECT id, session_id, role_raw, content, created_at, is_streaming, is_paused,
                       was_stopped, was_interrupted, task_elapsed_seconds, tool_call_name,
                       tool_call_result, tool_calls_data, attachments_data, reasoning, preview_text,
                       reasoning_segments_data, api_context_suffix
                FROM messages ORDER BY session_id, sort_order ASC
                """, -1, &mstmt, nil) == SQLITE_OK else { return result }
            defer { sqlite3_finalize(mstmt) }
            var bySession: [UUID: [ChatMessage]] = [:]
            while sqlite3_step(mstmt) == SQLITE_ROW {
                guard let sid = UUID(uuidString: colText(mstmt, 1)) else { continue }
                let msg = ChatMessage(role: MessageRole(rawValue: colText(mstmt, 2)) ?? .user, content: colText(mstmt, 3))
                msg.id = UUID(uuidString: colText(mstmt, 0)) ?? UUID()
                msg.createdAt = Self.date(colDouble(mstmt, 4))
                msg.isStreaming = Self.b(colInt64(mstmt, 5))
                msg.isPaused = Self.b(colInt64(mstmt, 6))
                msg.wasStopped = colOptInt64(mstmt, 7).map { Self.b($0) }
                msg.wasInterrupted = Self.b(colInt64(mstmt, 8))
                msg.taskElapsedSeconds = colOptDouble(mstmt, 9)
                msg.toolCallName = colOptText(mstmt, 10)
                msg.toolCallResult = colOptText(mstmt, 11)
                msg.toolCallsData = colOptBlob(mstmt, 12)
                msg.attachmentsData = colOptBlob(mstmt, 13)
                msg.reasoning = colOptText(mstmt, 14)
                msg.previewText = colOptText(mstmt, 15)
                msg.reasoningSegmentsData = colOptBlob(mstmt, 16)
                msg.apiContextSuffix = colOptText(mstmt, 17)
                bySession[sid, default: []].append(msg)
            }
            for session in result {
                if let msgs = bySession[session.id] {
                    session.attachMessages(msgs)
                }
            }
            return result
        }
    }

    /// 删除一个会话的全部行(sessions + messages + session_blobs,外键 CASCADE)。
    func deleteSessionRows(id: UUID) {
        queue.sync {
            openIfNeeded()
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, utf8(id.uuidString), -1, transient)
            sqlite3_step(stmt)
        }
    }

    /// 是否已有会话行(迁移器幂等判断用)。
    func sessionCount() -> Int {
        queue.sync {
            openIfNeeded()
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sessions", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(colInt64(stmt, 0))
        }
    }

    // MARK: - 会话附属 blob

    func saveBlob(sessionID: UUID, kind: BlobKind, payload: Data?) {
        queue.sync {
            openIfNeeded()
            guard let db else { return }
            let sql = """
            INSERT INTO session_blobs (session_id, kind, payload) VALUES (?,?,?)
            ON CONFLICT(session_id, kind) DO UPDATE SET payload=excluded.payload
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, utf8(sessionID.uuidString), -1, transient)
            sqlite3_bind_text(stmt, 2, utf8(kind.rawValue), -1, transient)
            if let payload {
                sqlite3_bind_blob(stmt, 3, (payload as NSData).bytes, Int32(payload.count), transient)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_step(stmt)
        }
    }

    /// 读取某类全部 blob:[sessionID: payload](nil payload 的行 = 已清空)。
    func loadBlobs(kind: BlobKind) -> [UUID: Data?] {
        queue.sync {
            openIfNeeded()
            guard let db else { return [:] }
            var result: [UUID: Data?] = [:]
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT session_id, payload FROM session_blobs WHERE kind = ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, utf8(kind.rawValue), -1, transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let sid = UUID(uuidString: colText(stmt, 0)) else { continue }
                result[sid] = colOptBlob(stmt, 1)
            }
            return result
        }
    }

    /// 读取某会话某类 blob(无行或 payload 为 NULL 返回 nil)。
    func loadBlob(sessionID: UUID, kind: BlobKind) -> Data? {
        queue.sync {
            openIfNeeded()
            guard let db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM session_blobs WHERE session_id = ? AND kind = ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, utf8(sessionID.uuidString), -1, transient)
            sqlite3_bind_text(stmt, 2, utf8(kind.rawValue), -1, transient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return colOptBlob(stmt, 0)
        }
    }

    /// 删除某会话某类 blob(nil payload 的等价操作)。
    func deleteBlob(sessionID: UUID, kind: BlobKind) {
        queue.sync {
            openIfNeeded()
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM session_blobs WHERE session_id = ? AND kind = ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, utf8(sessionID.uuidString), -1, transient)
            sqlite3_bind_text(stmt, 2, utf8(kind.rawValue), -1, transient)
            sqlite3_step(stmt)
        }
    }

    // MARK: - 绑定 / 读取辅助

    private var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func utf8(_ s: String) -> UnsafePointer<CChar>? { (s as NSString).utf8String }

    private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, idx, utf8(v), -1, transient) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindOptInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Int64?) {
        if let v { sqlite3_bind_int64(stmt, idx, v) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindOptDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(stmt, idx, v) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindOptBlob(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Data?) {
        if let v { sqlite3_bind_blob(stmt, idx, (v as NSData).bytes, Int32(v.count), transient) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }
    private func colOptText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL, let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
    private func colDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double { sqlite3_column_double(stmt, idx) }
    private func colOptDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, idx)
    }
    private func colInt64(_ stmt: OpaquePointer?, _ idx: Int32) -> Int64 { sqlite3_column_int64(stmt, idx) }
    private func colOptInt64(_ stmt: OpaquePointer?, _ idx: Int32) -> Int64? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, idx)
    }
    private func colOptBlob(_ stmt: OpaquePointer?, _ idx: Int32) -> Data? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, idx) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, idx))
        return Data(bytes: bytes, count: count)
    }
}
