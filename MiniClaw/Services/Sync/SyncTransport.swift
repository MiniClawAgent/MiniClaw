import Foundation

// MARK: - SyncTransport

/// 传输层协议。SyncCore 向所有已注册的 transport 广播 PortableRecord。
/// 对齐 SyncTransport：传输层中立，CloudKit/LAN/其他实现都采纳此协议。
/// Sendable 以支持从 @MainActor 上下文调用 async 方法。
protocol SyncTransport: AnyObject, Sendable {
    /// 传输层能力声明。
    var capabilities: TransportCapabilities { get }

    /// 推送一批记录到远端。调用方保证按 recordType 分批。
    func send(records: [PortableRecord]) async throws

    /// 拉取远端变更。返回新增/修改的记录 + 删除通知。
    func fetchChanges(recordTypes: [String]?) async throws -> FetchResult

    /// 确认传输层是否就绪（如 CloudKit 账号已登录）。
    var isReady: Bool { get async }
}

// MARK: - TransportCapabilities

struct TransportCapabilities: Sendable {
    /// 是否支持 per-record 删除（vs 整文件覆盖）。
    let supportsPerRecordDelete: Bool
    /// 是否支持资产上传（文件附件）。
    let supportsAssets: Bool
    /// 是否支持 etag 冲突检测。
    let supportsEtag: Bool
    /// 传输层名称（用于日志）。
    let name: String

    static let cloudKit = TransportCapabilities(
        supportsPerRecordDelete: true,
        supportsAssets: true,
        supportsEtag: true,
        name: "CloudKit"
    )
}

// MARK: - FetchResult

/// 拉取结果。
struct FetchResult: Sendable {
    var upserts: [PortableRecord]
    var deletions: [(recordType: String, recordId: String)]
    /// 传输层是否报告「此次为全量拉取」（用于 reconcileAfterFullFetch）。
    var isFullFetch: Bool
}
