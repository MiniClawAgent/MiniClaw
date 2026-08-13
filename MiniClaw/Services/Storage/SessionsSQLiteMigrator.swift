import Foundation

/// 「每会话 JSON 文件」→「SQLite 单库」的一次性迁移(2026-08-12)。
///
/// 数据源(全部会话数据 + 会话附属):
/// - `Documents/MiniClaw-Sessions/<uuid>/session.json`(会话主数据)
/// - `Documents/MiniClaw-Sessions/<uuid>/subagent/{subagent_store,runtime_records}.json`
/// - `Documents/MiniClaw/runs/<sessionID>.json`(暂停/恢复检查点)
/// - `Documents/MiniClaw/queue/<sessionID>.json` 与 `<sessionID>.draft.json`(排队/草稿)
///
/// 目标:`SQLiteStore`(`Documents/MiniClaw/sessions/miniclaw.db`)。
/// 迁移成功后,已迁移的 JSON 文件**移入** `Documents/MiniClaw/migration-backup/<时间戳>/`
/// 冷备份(不再留在读取路径,避免双份不一致);确认数据正常后可手动删除该备份目录。
/// 文件产物(workspace/attachments/browser/offloads)、记忆、配置、缓存日志不在本次范围。
///
/// 幂等:UserDefaults 标志 + SQLite 已存在会话行则跳过。失败仅日志,不阻断启动。
enum SessionsSQLiteMigrator {
    private static let migrationDoneKey = "MiniClaw.SessionsSQLiteMigrated"

    static func migrateIfNeeded() {
        // 幂等 1:本次迁移已执行过。
        if UserDefaults.standard.bool(forKey: migrationDoneKey) { return }
        // 幂等 2:SQLite 已有会话数据(新安装直写 / 标志丢失后的二次启动)。
        if SQLiteStore.shared.sessionCount() > 0 {
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            return
        }
        let fm = FileManager.default
        let backupRoot = FileSystemManager.shared.miniClawRoot
            .appendingPathComponent("migration-backup", isDirectory: true)
            .appendingPathComponent(Self.timestamp(), isDirectory: true)

        var migratedSessions = 0

        // 1) 会话主数据 + 会话级附属(按会话目录扫描)。
        let base = SessionFileRouter.sessionsHostBase
        if let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for entry in entries where entry.hasDirectoryPath {
                guard let sid = UUID(uuidString: entry.lastPathComponent) else { continue }
                // 1a. session.json → sessions/messages
                let sessionFile = entry.appendingPathComponent("session.json")
                if let data = try? Data(contentsOf: sessionFile),
                   let session = try? JSONDecoder().decode(ChatSession.self, from: data) {
                    SQLiteStore.shared.saveSession(session)
                    migratedSessions += 1
                    Self.backup(fm, file: sessionFile, to: backupRoot.appendingPathComponent(sid.uuidString + "-session.json"))
                }
                // 1b. subagent_store.json / runtime_records.json → session_blobs(原样字节)
                let subDir = entry.appendingPathComponent("subagent", isDirectory: true)
                let subFile = subDir.appendingPathComponent("subagent_store.json")
                if let data = try? Data(contentsOf: subFile) {
                    SQLiteStore.shared.saveBlob(sessionID: sid, kind: .subagentStore, payload: data)
                    Self.backup(fm, file: subFile, to: backupRoot.appendingPathComponent(sid.uuidString + "-subagent_store.json"))
                }
                let rtFile = subDir.appendingPathComponent("runtime_records.json")
                if let data = try? Data(contentsOf: rtFile) {
                    SQLiteStore.shared.saveBlob(sessionID: sid, kind: .runtimeRecords, payload: data)
                    Self.backup(fm, file: rtFile, to: backupRoot.appendingPathComponent(sid.uuidString + "-runtime_records.json"))
                }
            }
        }

        // 2) 扁平共享目录:runs(检查点)与 queue(排队/草稿)。
        Self.migrateFlatDir(fm, subdir: "runs", backupRoot: backupRoot, prefix: "runs-") { sid, data, isDraft in
            SQLiteStore.shared.saveBlob(sessionID: sid, kind: .agentTask, payload: data)
        }
        Self.migrateFlatDir(fm, subdir: "queue", backupRoot: backupRoot, prefix: "queue-") { sid, data, isDraft in
            SQLiteStore.shared.saveBlob(sessionID: sid, kind: isDraft ? .pendingDraft : .pendingQueue, payload: data)
        }

        UserDefaults.standard.set(true, forKey: migrationDoneKey)
        AppLogger.shared.info("SessionsSQLiteMigrator: 完成,迁移会话 \(migratedSessions) 个,备份目录 \(backupRoot.path)",
                              category: "Session", subsystem: "SQLite")
    }

    /// 迁移扁平目录下按会话 ID 命名的 JSON 文件(如 runs/<id>.json、queue/<id>.draft.json)。
    private static func migrateFlatDir(_ fm: FileManager, subdir: String, backupRoot: URL,
                                       prefix: String, write: (UUID, Data, Bool) -> Void) {
        let dir = FileSystemManager.shared.miniClawRoot.appendingPathComponent(subdir, isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.lastPathComponent
            let isDraft = name.hasSuffix(".draft.json")
            let baseName = isDraft ? String(name.dropLast(".draft.json".count)) : String(name.dropLast(".json".count))
            guard let sid = UUID(uuidString: baseName) else { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            write(sid, data, isDraft)
            Self.backup(fm, file: file, to: backupRoot.appendingPathComponent(prefix + name))
        }
    }

    /// 把已迁移的 JSON 移入备份目录(移动失败则复制后删除原文件)。
    private static func backup(_ fm: FileManager, file: URL, to dest: URL) {
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: file, to: dest)
        } catch {
            if let data = try? Data(contentsOf: file) {
                try? data.write(to: dest, options: .atomic)
                try? fm.removeItem(at: file)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
