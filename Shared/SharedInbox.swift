import Foundation

/// 分享收件箱：App Group 共享容器的读写入口，主 App 与 ShareExtension 共用。
///
/// 双编原因见 `PendingTaskShare`（扩展不可链接主 App）。只依赖 Foundation
/// （`APPLICATION_EXTENSION_API_ONLY = YES` 下亦可用）。
enum SharedInbox {
    /// 需与开发者后台创建的 App Group 一致；主 App 与 ShareExtension 的
    /// entitlements 都要声明它，否则 `containerURL` 返回 nil。
    static let appGroupID = "group.com.neartop.miniclaw.app"

    /// 共享内容有效期（秒）。超时视为弃用内容：清理并**明确告知用户**，
    /// 不静默丢弃（用户是显式分享进来的）。
    static let ttl: TimeInterval = 300

    private static let pendingKey = "pendingTaskShare"

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// 附件中转目录：扩展写入，主 App 读取后清理。
    static var fileDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("ShareInbox",isDirectory: true)
    }

    // MARK: - 写入（ShareExtension）

    @discardableResult
    static func ensureDirectory() -> Bool {
        guard let dir = fileDirectory else { return false }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        }
        return true
    }

    static func save(_ share: PendingTaskShare) {
        guard let defaults = sharedDefaults else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(share) else { return }
        defaults.set(data,forKey: pendingKey)
    }

    // MARK: - 读取 / 清理（主 App）

    static func load() -> PendingTaskShare? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pendingKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingTaskShare.self,from: data)
    }

    static func clear() {
        sharedDefaults?.removeObject(forKey: pendingKey)
        cleanFiles()
    }

    /// 清空附件中转目录（每次消费或清理记录时调用，避免共享容器堆积）。
    static func cleanFiles() {
        guard let dir = fileDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}
