import Foundation
import SQLite3

/// 旧 SwiftData 数据迁移器(iOS16 适配 2026-08-12):
/// 持久层由 SwiftData(miniclaw.sqlite)切换为 JSON 文件存储后,首次启动把旧库数据
/// 迁移到新格式(Documents/MiniClaw-Sessions/<uuid>/session.json),避免用户会话丢失。
/// 仅在「新格式目录无任何 session.json」且「旧库存在」时执行一次;幂等,失败仅记日志。
enum LegacySwiftDataMigrator {
    private static let migrationDoneKey = "MiniClaw.LegacySwiftDataMigrated"

    /// 启动时调用(MiniClawApp.init 内,SessionManager.load 之前)。
    static func migrateIfNeeded() {
        // 已迁移过/新格式已有数据 → 跳过
        if UserDefaults.standard.bool(forKey: migrationDoneKey) { return }
        // 会话数据已在 SQLite 单库(SessionsSQLiteMigrator 迁移后)→ 无需再迁旧库,
        // 否则会重新生成无人消费的 session.json(垃圾文件)。
        if SQLiteStore.shared.sessionCount() > 0 {
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            return
        }
        let fm = FileManager.default
        let storeRoot = SessionFileRouter.sessionsHostBase
        if let entries = try? fm.contentsOfDirectory(at: storeRoot, includingPropertiesForKeys: nil),
           entries.contains(where: { $0.hasDirectoryPath && fm.fileExists(atPath: $0.appendingPathComponent("session.json").path) }) {
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            return
        }
        // 旧库路径(与旧 makeContainer 一致:Application Support/miniclaw.sqlite)
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbURL = dir.appendingPathComponent("miniclaw.sqlite")
        guard fm.fileExists(atPath: dbURL.path) else {
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            return
        }
        do {
            let count = try migrate(dbURL: dbURL, storeRoot: storeRoot)
            AppLogger.shared.info("旧 SwiftData 数据迁移完成: \(count) 个会话", category: "Lifecycle", subsystem: "Migration")
        } catch {
            AppLogger.shared.error("旧 SwiftData 数据迁移失败(可忽略,新会话从空开始): \(error)", category: "Lifecycle", subsystem: "Migration")
        }
        UserDefaults.standard.set(true, forKey: migrationDoneKey)
    }

    private static func migrate(dbURL: URL, storeRoot: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw MigrateError.openFailed
        }
        defer { sqlite3_close(db) }

        // 1) 读会话表
        let sessionQuery = "SELECT ZID, ZTITLE, ZTITLEISPLACEHOLDER, ZCREATEDAT, ZUPDATEDAT, ZMODELNAME, ZAGENTNAME, ZSOURCE, ZSTATUSRAW, ZISPINNED, ZREVIEWEDMESSAGECOUNT, ZICON, ZICONCOLOR, ZTHINKINGLEVEL, ZSUMMARY, Z_PK FROM ZCHATSESSION ORDER BY ZUPDATEDAT DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sessionQuery, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            // 表不存在 = 旧库不是本项目 schema
            throw MigrateError.schemaMismatch
        }
        defer { sqlite3_finalize(stmt) }

        var sessions: [(id: UUID, title: String, titleIsPlaceholder: Bool, createdAt: Date, updatedAt: Date,
                        modelName: String, agentName: String, source: String, statusRaw: String, isPinned: Bool,
                        reviewedMessageCount: Int, icon: String?, iconColor: String?, thinkingLevel: String?,
                        summary: String?, pk: Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idBlob = sqlite3_column_blob(stmt, 0) else { continue }
            let idLen = Int(sqlite3_column_bytes(stmt, 0))
            guard idLen == 16 else { continue }
            let id = idBlob.assumingMemoryBound(to: UInt8.self)
            let uuid = UUID(uuid: (
                id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]
            ))
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "新会话"
            sessions.append((
                id: uuid,
                title: title,
                titleIsPlaceholder: sqlite3_column_int(stmt, 2) != 0,
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                modelName: sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "未配置",
                agentName: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "MiniClaw",
                source: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "app",
                statusRaw: sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "idle",
                isPinned: sqlite3_column_int(stmt, 9) != 0,
                reviewedMessageCount: Int(sqlite3_column_int(stmt, 10)),
                icon: sqlite3_column_text(stmt, 11).map { String(cString: $0) },
                iconColor: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
                thinkingLevel: sqlite3_column_text(stmt, 13).map { String(cString: $0) },
                summary: sqlite3_column_text(stmt, 14).map { String(cString: $0) },
                pk: sqlite3_column_int64(stmt, 15)
            ))
        }

        // 2) 读消息表(按会话外键分组)
        let msgQuery = "SELECT ZID, ZROLERAW, ZCONTENT, ZCREATEDAT, ZISSTREAMING, ZWASSTOPPED, ZWASINTERRUPTED, ZTASKELAPSEDSECONDS, ZTOOLCALLNAME, ZTOOLCALLRESULT, ZTOOLCALLSDATA, ZATTACHMENTSDATA, ZREASONING, ZPREVIEWTEXT, ZREASONINGSEGMENTSDATA, ZSESSION FROM ZCHATMESSAGE ORDER BY ZCREATEDAT ASC"
        var msgStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, msgQuery, -1, &msgStmt, nil) == SQLITE_OK, let msgStmt else {
            throw MigrateError.schemaMismatch
        }
        defer { sqlite3_finalize(msgStmt) }

        var messagesBySession: [Int64: [ChatMessage]] = [:]
        while sqlite3_step(msgStmt) == SQLITE_ROW {
            guard let idBlob = sqlite3_column_blob(msgStmt, 0) else { continue }
            let idLen = Int(sqlite3_column_bytes(msgStmt, 0))
            guard idLen == 16 else { continue }
            let id = idBlob.assumingMemoryBound(to: UInt8.self)
            let uuid = UUID(uuid: (
                id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]
            ))
            let msg = ChatMessage(id: uuid, role: MessageRole(rawValue: sqlite3_column_text(msgStmt, 1).map { String(cString: $0) } ?? "") ?? .user,
                                  content: sqlite3_column_text(msgStmt, 2).map { String(cString: $0) } ?? "")
            msg.createdAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(msgStmt, 3))
            msg.isStreaming = sqlite3_column_int(msgStmt, 4) != 0
            if sqlite3_column_type(msgStmt, 5) != SQLITE_NULL { msg.wasStopped = sqlite3_column_int(msgStmt, 5) != 0 }
            msg.wasInterrupted = sqlite3_column_int(msgStmt, 6) != 0
            if sqlite3_column_type(msgStmt, 7) != SQLITE_NULL { msg.taskElapsedSeconds = sqlite3_column_double(msgStmt, 7) }
            msg.toolCallName = sqlite3_column_text(msgStmt, 8).map { String(cString: $0) }
            msg.toolCallResult = sqlite3_column_text(msgStmt, 9).map { String(cString: $0) }
            if let b = sqlite3_column_blob(msgStmt, 10), sqlite3_column_bytes(msgStmt, 10) > 0 {
                msg.toolCallsData = Data(bytes: b, count: Int(sqlite3_column_bytes(msgStmt, 10)))
            }
            if let b = sqlite3_column_blob(msgStmt, 11), sqlite3_column_bytes(msgStmt, 11) > 0 {
                msg.attachmentsData = Data(bytes: b, count: Int(sqlite3_column_bytes(msgStmt, 11)))
            }
            msg.reasoning = sqlite3_column_text(msgStmt, 12).map { String(cString: $0) }
            msg.previewText = sqlite3_column_text(msgStmt, 13).map { String(cString: $0) }
            if let b = sqlite3_column_blob(msgStmt, 14), sqlite3_column_bytes(msgStmt, 14) > 0 {
                msg.reasoningSegmentsData = Data(bytes: b, count: Int(sqlite3_column_bytes(msgStmt, 14)))
            }
            let sessionPK = sqlite3_column_int64(msgStmt, 15)
            messagesBySession[sessionPK, default: []].append(msg)
        }

        // 3) 逐会话落盘新格式
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var migrated = 0
        for s in sessions {
            let dir = storeRoot.appendingPathComponent(s.id.uuidString, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let session = ChatSession(id: s.id, title: s.title, modelName: s.modelName,
                                      agentName: s.agentName, source: s.source, status: SessionStatus(rawValue: s.statusRaw) ?? .idle,
                                      isPinned: s.isPinned)
            session.titleIsPlaceholder = s.titleIsPlaceholder
            session.createdAt = s.createdAt
            session.updatedAt = s.updatedAt
            session.reviewedMessageCount = s.reviewedMessageCount
            session.icon = s.icon
            session.iconColor = s.iconColor
            session.thinkingLevel = s.thinkingLevel
            session.summary = s.summary
            session.attachMessages(messagesBySession[s.pk] ?? [])
            let data = try encoder.encode(session)
            try data.write(to: dir.appendingPathComponent("session.json"), options: .atomic)
            migrated += 1
        }
        return migrated
    }

    private enum MigrateError: Error {
        case openFailed
        case schemaMismatch
    }
}
