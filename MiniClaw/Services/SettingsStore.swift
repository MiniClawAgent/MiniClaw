import Foundation
import Combine

// MARK: - 审计日志条目

/// 单条配置变更审计记录（before/after 为该域变更前后的 JSON 快照）
struct AuditEntry: Codable, Identifiable {
    var id: UUID
    var timestamp: Date
    var domain: String        // SettingsDomain.rawValue
    var summary: String
    var before: Data?         // 变更前该域 JSON 快照
    var after: Data?          // 变更后该域 JSON 快照
}

// MARK: - 统一配置存储（对齐 spec 9.1：Swift 原生配置存储 + 审计日志，1000 条可回滚）

/// 管理除 providers 外的 13 个配置域，每次变更写入审计日志（环形 1000 条），支持回滚。
/// 注：访问应在主线程进行（文件 IO 为同步调用）。
final class SettingsStore: ObservableObject {
    nonisolated(unsafe) static let shared = SettingsStore()

    /// 当前配置（内存态，落盘见 save）
    @Published var settings: AppSettings

    private let fileURL: URL
    private let auditURL: URL
    private let maxAuditEntries = 1000

    /// 主线程配置快照：后台线程（工具执行 / 记忆整理 / 复盘）读设置统一走这里。
    /// 直接读 `settings` 会与主线程写（设置页改动）竞争——`@Published var` 无锁，
    /// 数组等引用类型字段的写时复制计数竞争可产生悬垂对象（2026-08-13 真机
    /// EXC_BAD_ACCESS：offloadIfLarge → writeFile 崩溃，根因即后台线程裸读 envvars）。
    /// 标记 @MainActor：调用方 await 时自动 hop 到主线程执行，避免闭包捕获 self。
    @MainActor
    func snapshot() -> AppSettings {
        settings
    }

    /// 落盘串行队列（线程治理 2026-08-09）：编码+写盘移后台，主线程只做内存态变更。
    private let ioQueue = DispatchQueue(label: "settings-store-io")

    private var auditLog: [AuditEntry] = []

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniClaw", isDirectory: true)
        let configDir = base.appendingPathComponent("config")
        let legacyFileURL = base.appendingPathComponent("settings.json")
        let legacyAuditURL = base.appendingPathComponent("settings_audit.json")
        self.fileURL = configDir.appendingPathComponent("settings.json")
        self.auditURL = configDir.appendingPathComponent("settings_audit.json")
        // 优先 config 新路径；缺失时回退根层旧文件（兼容迁移前布局）。
        self.settings = SettingsStore.loadSettings(from: fileURL)
        self.auditLog = SettingsStore.loadAudit(from: auditURL)
        // 把根层旧文件搬到 config/（config 已存在则跳过，避免覆盖新数据）。
        SettingsStore.migrateIfNeeded(from: legacyFileURL, to: fileURL)
        SettingsStore.migrateIfNeeded(from: legacyAuditURL, to: auditURL)

        // 迁移兜底：soul.name 旧默认值与种子文件保持一致(历史脏值兼容已移除,
        // 旧设备上的历史脏名不再归正——按用户要求不再兼容旧数据)。

        // 一次性迁移：记忆类功能（向量召回 / 跨对话近况摘要）改为「首次安装默认关闭，由用户自行开启」。
        // 仅对沿用旧默认 true 的已安装设备归正为关闭；标记置位后不再重复执行，
        // 不覆盖用户后续手动开关，也避免每次启动都重写配置。
        let memoryDefaultsOffKey = "migratedMemoryDefaultsOffV1"
        if !UserDefaults.standard.bool(forKey: memoryDefaultsOffKey) {
            settings.memory.embeddingEnabled = false
            UserDefaults.standard.set(true, forKey: memoryDefaultsOffKey)
            save()
        }
    }

    /// 当目标 config 文件不存在且旧根层文件存在时，把它移动到 config/。
    private static func migrateIfNeeded(from legacy: URL, to config: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: config.path),
              fileManager.fileExists(atPath: legacy.path) else { return }
        try? fileManager.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.moveItem(at: legacy, to: config)
    }

    // MARK: - 读写配置

    private static func loadSettings(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    /// 原子写入当前配置到 settings.json
    func save() {
        // 线程治理（2026-08-09）：settings 值快照后编码+原子写盘移 ioQueue，
        // 高频设置变更不再阻塞主线程（写盘为毫秒级 IO）。
        let snapshot = settings
        let url = fileURL
        ioQueue.async {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    // MARK: - 审计日志

    private static func loadAudit(from url: URL) -> [AuditEntry] {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([AuditEntry].self, from: data) else { return [] }
        return arr
    }

    private func persistAudit() {
        // 线程治理（2026-08-09）：审计日志快照后编码+写盘移 ioQueue。
        let snapshot = auditLog
        let url = auditURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// 最近审计记录（按时间倒序，便于 UI 展示）
    var auditEntries: [AuditEntry] {
        auditLog.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - 带审计的更新

    /// 更新某个配置域，并记录 before/after 快照到审计日志
    func update<T: Codable>(domain: SettingsDomain, summary: String, mutate: (inout T) -> Void) {
        guard let current = getDomain(T.self, domain: domain) else { return }
        let before = try? JSONEncoder().encode(current)

        var newValue = current
        mutate(&newValue)
        setDomain(newValue, domain: domain)

        let after = try? JSONEncoder().encode(newValue)
        save()

        let entry = AuditEntry(
            id: UUID(),
            timestamp: Date(),
            domain: domain.rawValue,
            summary: summary,
            before: before,
            after: after
        )
        appendAudit(entry)
    }

    /// 直接替换整个配置域
    func set<T: Codable>(_ value: T, domain: SettingsDomain, summary: String) {
        update(domain: domain, summary: summary) { $0 = value }
    }

    // MARK: - envvars 域级隐私模式（spec 9.2.4）

    /// 读写环境变量隐私模式：开启后 shell / 记忆输出中的变量值自动掩码。
    /// 变更记审计。
    func setEnvvarsPrivacyMode(_ value: Bool) {
        let before = settings.envvarsPrivacyMode
        settings.envvarsPrivacyMode = value
        save()
        let entry = AuditEntry(
            id: UUID(),
            timestamp: Date(),
            domain: SettingsDomain.envvars.rawValue,
            summary: "修改 envvars.privacyMode -> \(value)",
            before: try? JSONEncoder().encode(before),
            after: try? JSONEncoder().encode(value)
        )
        appendAudit(entry)
    }

    private func appendAudit(_ entry: AuditEntry) {
        auditLog.append(entry)
        if auditLog.count > maxAuditEntries {
            auditLog.removeFirst(auditLog.count - maxAuditEntries)
        }
        persistAudit()
    }

    // MARK: - 回滚

    /// 回滚到某条审计记录：恢复该记录变更前（before）的域快照。
    /// 成功返回 true。
    func rollback(to entryId: UUID) -> Bool {
        guard let entry = auditLog.first(where: { $0.id == entryId }),
              let before = entry.before,
              let type = domainType(entry.domain) else { return false }

        guard applySnapshot(before, rawDomain: entry.domain, type: type) else { return false }
        save()

        let rollbackEntry = AuditEntry(
            id: UUID(),
            timestamp: Date(),
            domain: entry.domain,
            summary: "回滚至审计记录 \(entry.id.uuidString.prefix(8))",
            before: nil,
            after: before
        )
        appendAudit(rollbackEntry)
        return true
    }

    // MARK: - 域读写辅助

    private func getDomain<T: Codable>(_ type: T.Type, domain: SettingsDomain) -> T? {
        switch domain {
        case .groups:      return settings.groups as? T
        case .envvars:     return settings.envvars as? T
        case .soul:        return settings.soul as? T
        case .session:     return settings.session as? T
        case .chat:        return settings.chat as? T
        case .speech:      return settings.speech as? T
        case .memory:      return settings.memory as? T
        case .browser:     return settings.browser as? T
        case .appearance:  return settings.appearance as? T
        case .background:  return settings.background as? T
        case .files:       return settings.files as? T
        case .permissions: return settings.permissions as? T
        case .defaults:    return settings.defaults as? T
        case .sync:        return settings.sync as? T
        case .subagent:    return settings.subagent as? T
        }
    }

    private func setDomain<T: Codable>(_ value: T, domain: SettingsDomain) {
        switch domain {
        case .groups:      if let v = value as? [ModelGroup] { settings.groups = v }
        case .envvars:     if let v = value as? [EnvVariable] { settings.envvars = v }
        case .soul:        if let v = value as? SoulConfig { settings.soul = v }
        case .session:     if let v = value as? SessionSettings { settings.session = v }
        case .chat:        if let v = value as? ChatSettings { settings.chat = v }
        case .speech:      if let v = value as? SpeechSettings { settings.speech = v }
        case .memory:      if let v = value as? MemorySettings { settings.memory = v }
        case .browser:     if let v = value as? BrowserSettings { settings.browser = v }
        case .appearance:  if let v = value as? AppearanceSettings { settings.appearance = v }
        case .background:  if let v = value as? BackgroundSettings { settings.background = v }
        case .files:       if let v = value as? FileSettings { settings.files = v }
        case .permissions: if let v = value as? PermissionConfig { settings.permissions = v }
        case .defaults:    if let v = value as? DefaultSettings { settings.defaults = v }
        case .sync:        if let v = value as? SyncConfig { settings.sync = v }
        case .subagent:    if let v = value as? SubAgentSettings { settings.subagent = v }
        }
    }

    private func domainType(_ raw: String) -> Any.Type? {
        guard let d = SettingsDomain(rawValue: raw) else { return nil }
        switch d {
        case .groups:      return [ModelGroup].self
        case .envvars:     return [EnvVariable].self
        case .soul:        return SoulConfig.self
        case .session:     return SessionSettings.self
        case .chat:        return ChatSettings.self
        case .speech:      return SpeechSettings.self
        case .memory:      return MemorySettings.self
        case .browser:     return BrowserSettings.self
        case .appearance:  return AppearanceSettings.self
        case .background:  return BackgroundSettings.self
        case .files:       return FileSettings.self
        case .permissions: return PermissionConfig.self
        case .defaults:    return DefaultSettings.self
        case .sync:        return SyncConfig.self
        case .subagent:    return SubAgentSettings.self
        }
    }

    private func applySnapshot(_ data: Data, rawDomain: String, type: Any.Type) -> Bool {
        guard let d = SettingsDomain(rawValue: rawDomain) else { return false }
        let decoder = JSONDecoder()
        switch d {
        case .groups:      if let v = try? decoder.decode([ModelGroup].self, from: data) { settings.groups = v; return true }
        case .envvars:     if let v = try? decoder.decode([EnvVariable].self, from: data) { settings.envvars = v; return true }
        case .soul:        if let v = try? decoder.decode(SoulConfig.self, from: data) { settings.soul = v; return true }
        case .session:     if let v = try? decoder.decode(SessionSettings.self, from: data) { settings.session = v; return true }
        case .chat:        if let v = try? decoder.decode(ChatSettings.self, from: data) { settings.chat = v; return true }
        case .speech:      if let v = try? decoder.decode(SpeechSettings.self, from: data) { settings.speech = v; return true }
        case .memory:      if let v = try? decoder.decode(MemorySettings.self, from: data) { settings.memory = v; return true }
        case .browser:     if let v = try? decoder.decode(BrowserSettings.self, from: data) { settings.browser = v; return true }
        case .appearance:  if let v = try? decoder.decode(AppearanceSettings.self, from: data) { settings.appearance = v; return true }
        case .background:  if let v = try? decoder.decode(BackgroundSettings.self, from: data) { settings.background = v; return true }
        case .files:       if let v = try? decoder.decode(FileSettings.self, from: data) { settings.files = v; return true }
        case .permissions: if let v = try? decoder.decode(PermissionConfig.self, from: data) { settings.permissions = v; return true }
        case .defaults:    if let v = try? decoder.decode(DefaultSettings.self, from: data) { settings.defaults = v; return true }
        case .sync:        if let v = try? decoder.decode(SyncConfig.self, from: data) { settings.sync = v; return true }
        case .subagent:    if let v = try? decoder.decode(SubAgentSettings.self, from: data) { settings.subagent = v; return true }
        }
        return false
    }
}
