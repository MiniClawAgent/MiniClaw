import Foundation
import os.log

private let logger = AppLogger.shared

// MARK: - PortableRecordBuilder

/// 从 Syncable 类型构建 PortableRecord 的工具。
@MainActor
enum PortableRecordBuilder {
    static func build<T: Syncable>(from value: T) -> PortableRecord {
        let meta = T.syncMetadata
        let registry = SyncableTypeRegistry.shared
        guard let anyMeta = registry.metadata(for: meta.recordType) else {
            fatalError("Type \(meta.recordType) not registered")
        }

        let fields = anyMeta.extractFields(value)
        let parentId = meta.parentId(of: value)

        return PortableRecord(
            recordType: meta.recordType,
            recordId: meta.id(of: value),
            parentType: parentId?.parentType,
            parentId: parentId?.parentId,
            fields: fields,
            schemaVersion: meta.version,
            minimumCompatibleVersion: meta.minimumCompatibleVersion
        )
    }
}

// MARK: - PortableFieldValue Extensions

extension PortableFieldValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var dateValue: Date? {
        if case .date(let d) = self { return d }
        return nil
    }
}

// MARK: - SyncHydrator Protocol

/// 同步 Hydrator 协议。每种 Syncable 类型实现一个 Hydrator。
@MainActor
protocol SyncHydrator {
    associatedtype SyncType: Syncable

    /// 从本地数据构建所有需要推送的 PortableRecord。
    func buildAll() async -> [PortableRecord]

    /// 构建单条删除记录。
    func buildDeletion(id: String) -> PortableRecord

    /// 合并一条入站记录到本地存储。
    func merge(_ record: PortableRecord) async

    /// 处理远程删除。
    func applyDeletion(recordId: String) async
}

// MARK: - ProviderConfigHydrator

/// 供应商配置同步 Hydrator（whole-file 模式）。
struct ProviderConfigHydrator: SyncHydrator {
    typealias SyncType = SyncedProviderConfig

    func buildAll() async -> [PortableRecord] {
        let container = ProviderFileStore.load()
        let synced = SyncedProviderConfig.from(container)
        return [PortableRecordBuilder.build(from: synced)]
    }

    func buildDeletion(id: String) -> PortableRecord {
        fatalError("ProviderConfig should not be deleted")
    }

    func merge(_ record: PortableRecord) async {
        guard let configJson = record.fields["configJson"]?.stringValue else { return }
        guard let jsonData = configJson.data(using: .utf8) else { return }

        if let container = try? JSONDecoder().decode(ProvidersContainer.self, from: jsonData) {
            await MainActor.run {
                ProviderFileStore.save(container)
            }
            logger.info("[ProviderConfigHydrator] Merged (\(container.providers.count) providers)")
        }
    }

    func applyDeletion(recordId: String) async {}
}

// MARK: - EnvVarHydrator

/// 环境变量同步 Hydrator（per-record 模式）。
struct EnvVarHydrator: SyncHydrator {
    typealias SyncType = SyncedEnvVar

    func buildAll() async -> [PortableRecord] {
        let envvars = SettingsStore.shared.settings.envvars
        return envvars.map { env in
            let synced = SyncedEnvVar.from(env)
            return PortableRecordBuilder.build(from: synced)
        }
    }

    func buildDeletion(id: String) -> PortableRecord {
        PortableRecord(recordType: "EnvVarItem", recordId: id, operation: .delete)
    }

    func merge(_ record: PortableRecord) async {
        guard let entryId = record.fields["entryId"]?.stringValue,
              let key = record.fields["key"]?.stringValue,
              let valueB64 = record.fields["valueB64"]?.stringValue else { return }

        let decodedValue = Data(base64Encoded: valueB64).flatMap { String(data: $0, encoding: .utf8) } ?? ""

        await MainActor.run {
            var envvars = SettingsStore.shared.settings.envvars
            if let idx = envvars.firstIndex(where: { $0.id.uuidString == entryId }) {
                envvars[idx].key = key
                envvars[idx].value = decodedValue
            } else {
                let newEnv = EnvVariable(
                    id: UUID(uuidString: entryId) ?? UUID(),
                    key: key,
                    value: decodedValue,
                    isSecret: (record.fields["isSecret"]?.intValue ?? 0) == 1
                )
                envvars.append(newEnv)
            }
            SettingsStore.shared.set(envvars, domain: .envvars, summary: "iCloud sync merge envvar")
        }
    }

    func applyDeletion(recordId: String) async {
        await MainActor.run {
            var envvars = SettingsStore.shared.settings.envvars
            envvars.removeAll { $0.id.uuidString == recordId }
            SettingsStore.shared.set(envvars, domain: .envvars, summary: "iCloud sync delete envvar")
        }
    }
}

// MARK: - SoulHydrator

/// 灵魂（SOUL.md）同步 Hydrator。whole-file LWW。
struct SoulHydrator: SyncHydrator {
    typealias SyncType = SyncedSoul

    func buildAll() async -> [PortableRecord] {
        let url = FileSystemManager.shared.memoryDir.appendingPathComponent("SOUL.md")
        let content = await Task.detached { () -> String in
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
        guard !content.isEmpty else { return [] }
        let synced = SyncedSoul(contentMarkdown: content, updatedAt: Date())
        return [PortableRecordBuilder.build(from: synced)]
    }

    func buildDeletion(id: String) -> PortableRecord {
        fatalError("Soul should not be deleted")
    }

    func merge(_ record: PortableRecord) async {
        guard let content = record.fields["contentMarkdown"]?.stringValue else { return }
        guard let updatedAt = record.fields["updatedAt"]?.dateValue else { return }

        let file = FileSystemManager.shared.memoryDir.appendingPathComponent("SOUL.md")
        let localMTime = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard localMTime == nil || updatedAt > localMTime! else {
            logger.info("[SoulHydrator] Local SOUL.md is newer, skipping merge")
            return
        }

        do {
            try content.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: updatedAt], ofItemAtPath: file.path)
            logger.info("[SoulHydrator] Merged SOUL.md (\(content.count) chars)")
        } catch {
            logger.error("[SoulHydrator] Write failed: \(error.localizedDescription)")
        }
    }

    func applyDeletion(recordId: String) async {}
}

// MARK: - MemoryHydrator

/// 记忆同步 Hydrator。支持 MEMORY.md（全局）和每日日志（per-date）。
struct MemoryHydrator: SyncHydrator {
    typealias SyncType = SyncedMemoryDaily

    private var memoryDir: URL { FileSystemManager.shared.memoryDir }

    func buildAll() async -> [PortableRecord] {
        var records: [PortableRecord] = []

        // 1. MEMORY.md（全局记忆）
        let memFile = memoryDir.appendingPathComponent("MEMORY.md")
        if let content = try? String(contentsOf: memFile, encoding: .utf8), !content.isEmpty {
            let synced = SyncedMemoryGlobal(contentMarkdown: content, updatedAt: Date())
            records.append(PortableRecordBuilder.build(from: synced))
        }

        // 2. 最近 N 天的每日日志
        let calendar = Calendar.current
        let files = (try? FileManager.default.contentsOfDirectory(at: memoryDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dailyFiles = files.filter {
            $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }

        let cutoffDate = calendar.date(byAdding: .day, value: -SyncConstants.memoryDailySyncWindowDays, to: Date())!
        for file in dailyFiles {
            let dateKey = file.deletingPathExtension().lastPathComponent
            guard let fileDate = ISO8601DateFormatter().date(from: dateKey + "T00:00:00Z") ?? dateFormatter.date(from: dateKey) else { continue }
            guard fileDate >= cutoffDate else { continue }

            if let content = try? String(contentsOf: file, encoding: .utf8) {
                let synced = SyncedMemoryDaily(dateKey: dateKey, entriesJson: content, updatedAt: Date())
                records.append(PortableRecordBuilder.build(from: synced))
            }
        }

        logger.info("[MemoryHydrator] Built \(records.count) records (1 global + \(records.count - 1) daily)")
        return records
    }

    func buildDeletion(id: String) -> PortableRecord {
        fatalError("Memory logs should not be deleted")
    }

    func merge(_ record: PortableRecord) async {
        // 区分全局记忆和每日日志
        if record.recordId == "memory-global" {
            await mergeGlobal(record)
        } else {
            await mergeDaily(record)
        }
    }

    func applyDeletion(recordId: String) async {
        if recordId == "memory-global" {
            // 不删除全局记忆
        } else {
            // 每日日志：删除对应文件
            let file = memoryDir.appendingPathComponent("\(recordId).md")
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Private

    private func mergeGlobal(_ record: PortableRecord) async {
        guard let content = record.fields["contentMarkdown"]?.stringValue else { return }
        guard let updatedAt = record.fields["updatedAt"]?.dateValue else { return }

        let file = memoryDir.appendingPathComponent("MEMORY.md")
        let localMTime = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard localMTime == nil || updatedAt > localMTime! else { return }

        do {
            try content.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: updatedAt], ofItemAtPath: file.path)
            logger.info("[MemoryHydrator] Merged MEMORY.md")
        } catch {
            logger.error("[MemoryHydrator] MEMORY.md write failed: \(error.localizedDescription)")
        }
    }

    private func mergeDaily(_ record: PortableRecord) async {
        guard let dateKey = record.fields["dateKey"]?.stringValue else { return }
        guard let entriesJson = record.fields["entriesJson"]?.stringValue else { return }
        guard let updatedAt = record.fields["updatedAt"]?.dateValue else { return }

        let file = memoryDir.appendingPathComponent("\(dateKey).md")
        let localMTime = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard localMTime == nil || updatedAt > localMTime! else { return }

        do {
            try entriesJson.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: updatedAt], ofItemAtPath: file.path)
            logger.info("[MemoryHydrator] Merged daily \(dateKey)")
        } catch {
            logger.error("[MemoryHydrator] Daily \(dateKey) write failed: \(error.localizedDescription)")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private let dateFormatter = Self.dateFormatter
}

// MARK: - SkillHydrator

/// 技能同步 Hydrator。同步技能启用状态和安装元数据（不同步技能文件内容）。
struct SkillHydrator: SyncHydrator {
    typealias SyncType = SyncedSkill

    func buildAll() async -> [PortableRecord] {
        let skillPackages = SkillManager.shared.loadSkills()
        let enabledStates = SettingsStore.shared.settings.skillEnabledStates
        let installDates = SettingsStore.shared.settings.skillInstallDates

        return skillPackages.map { skill in
            let synced = SyncedSkill(
                skillId: skill.id.uuidString,
                name: skill.name,
                skillDescription: skill.description,
                version: skill.version,
                directoryName: skill.directoryName,
                isEnabled: (enabledStates[skill.name] ?? true) ? 1 : 0,
                installDate: installDates[skill.name] ?? skill.installDate,
                updatedAt: Date()
            )
            return PortableRecordBuilder.build(from: synced)
        }
    }

    func buildDeletion(id: String) -> PortableRecord {
        PortableRecord(recordType: "SkillV2", recordId: id, operation: .delete)
    }

    func merge(_ record: PortableRecord) async {
        guard let name = record.fields["name"]?.stringValue else { return }
        guard let isEnabled = record.fields["isEnabled"]?.intValue else { return }

        await MainActor.run {
            SettingsStore.shared.settings.skillEnabledStates[name] = isEnabled == 1
            SkillManager.shared.invalidateSkillsCache()
        }
        logger.info("[SkillHydrator] Merged skill '\(name)' enabled=\(isEnabled == 1)")
    }

    func applyDeletion(recordId: String) async {
        // 技能删除需要删除文件系统中的技能目录
        // TODO: 实现技能文件删除
    }
}

// MARK: - SessionHydrator

/// 会话同步 Hydrator。暂存桩——SwiftData 双 ModelContainer 会冲突，
/// 待后续通过通知机制集成。
struct SessionHydrator: SyncHydrator {
    typealias SyncType = SyncedSession

    func buildAll() async -> [PortableRecord] {
        // TODO: 通过通知机制让拥有 ModelContext 的 View 层构建记录
        []
    }

    func buildDeletion(id: String) -> PortableRecord {
        PortableRecord(recordType: "SessionV2", recordId: id, operation: .delete)
    }

    func merge(_ record: PortableRecord) async {
        // TODO: 通过通知机制让 View 层创建/更新会话
    }

    func applyDeletion(recordId: String) async {
        // TODO: 通过通知机制让 View 层删除会话
    }
}
