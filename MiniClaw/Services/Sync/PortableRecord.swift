import Foundation

// MARK: - PortableRecord

/// 传输层中立的记录格式。所有 SyncTransport 都以这个格式收发记录。
/// 对齐 PortableRecord：前向兼容（unknownFields 保留未知字段，不截断）。
struct PortableRecord: Sendable {
    /// 记录类型名（如 "SessionV2"、"MessageV2"）。
    let recordType: String
    /// 记录唯一 ID（也作为 CloudKit recordName）。
    let recordId: String
    /// 父级类型名（perParent scope 时非 nil）。
    let parentType: String?
    /// 父级 ID。
    let parentId: String?
    /// 字段值表（cloudKey → value）。
    var fields: [String: PortableFieldValue]
    /// 未知字段（本 build 不认识但保留 round-trip 的字段，前向兼容）。
    var unknownFields: [String: AnySendableValue]?
    /// 传输层元数据（etag 等），由传输层填充。
    var transportMetadata: [String: String]
    /// 记录 schema 版本。
    let schemaVersion: Int
    /// 最低兼容版本（高于此版本的记录被旧客户端跳过）。
    let minimumCompatibleVersion: Int?
    /// 操作类型：upsert 或 delete。
    let operation: Operation

    enum Operation: String, Sendable {
        case upsert
        case delete
    }

    init(
        recordType: String,
        recordId: String,
        parentType: String? = nil,
        parentId: String? = nil,
        fields: [String: PortableFieldValue] = [:],
        unknownFields: [String: AnySendableValue]? = nil,
        transportMetadata: [String: String] = [:],
        schemaVersion: Int = 1,
        minimumCompatibleVersion: Int? = nil,
        operation: Operation = .upsert
    ) {
        self.recordType = recordType
        self.recordId = recordId
        self.parentType = parentType
        self.parentId = parentId
        self.fields = fields
        self.unknownFields = unknownFields
        self.transportMetadata = transportMetadata
        self.schemaVersion = schemaVersion
        self.minimumCompatibleVersion = minimumCompatibleVersion
        self.operation = operation
    }
}

// MARK: - AnySendableValue (for unknownFields round-tripping)

/// 类型擦除的可发送值，用于保留未知字段。
/// 只支持常见的 CloudKit 值类型。
enum AnySendableValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case null
}

// MARK: - SyncOutcome

/// 同步操作结果。
struct SyncOutcome: Sendable {
    let recordsSent: Int
    let recordsReceived: Int
    let errors: [SyncError]
    let duration: TimeInterval
}

struct SyncError: Error, Sendable {
    let message: String
    let recordType: String?
    let recordId: String?
}

// MARK: - SyncableTypeRegistry

/// 类型擦除的 Syncable 元数据注册表。SyncCore 通过它查询任意类型的元数据。
/// 对齐 SyncableTypeRegistry。
@MainActor
final class SyncableTypeRegistry {
    static let shared = SyncableTypeRegistry()

    /// 类型擦除的元数据容器。
    struct AnySyncTypeMetadata: Sendable {
        let recordType: String
        let extractFields: @Sendable (Any) -> [String: PortableFieldValue]
        let applyFields: @Sendable (inout Any, [String: PortableFieldValue]) -> Bool
        let extractId: @Sendable (Any) -> String
        let extractParent: @Sendable (Any) -> (parentType: String, parentId: String)?
        let conflictResolver: @Sendable (Any, Any) -> Any
        let schemaVersion: Int
        let minimumCompatibleVersion: Int?
    }

    private var metadatas: [String: AnySyncTypeMetadata] = [:]

    private init() {}

    func register<T: Syncable>(_ type: T.Type) {
        let meta = T.syncMetadata
        let recordType = meta.recordType
        let fields = meta.fields
        let version = meta.version
        let minCompat = meta.minimumCompatibleVersion
        let conflictPolicy = meta.conflictPolicy

        // 捕获字段副本而非 meta 本身（meta 含非 Sendable 闭包，不可跨并发边界传递）
        let capturedFields = fields
        let capturedPolicy = conflictPolicy

        let metadata = AnySyncTypeMetadata(
            recordType: recordType,
            extractFields: { value in
                guard let typed = value as? T else { return [:] }
                var result: [String: PortableFieldValue] = [:]
                for fd in capturedFields {
                    result[fd.cloudKey] = fd.extract(typed)
                }
                return result
            },
            applyFields: { value, fieldsDict in
                guard var typed = value as? T else { return false }
                var changed = false
                for fd in capturedFields {
                    if let fv = fieldsDict[fd.cloudKey] {
                        if fd.apply(&typed, fv) { changed = true }
                    }
                }
                if changed { value = typed as Any }
                return changed
            },
            extractId: { value in
                guard let typed = value as? T else { return "" }
                return meta.id(of: typed)
            },
            extractParent: { value in
                guard let typed = value as? T else { return nil }
                return meta.parentId(of: typed)
            },
            conflictResolver: { local, remote in
                guard let l = local as? T, let r = remote as? T else { return remote }
                switch capturedPolicy {
                case .lastWriteWinsByField(let kp):
                    return l[keyPath: kp] >= r[keyPath: kp] ? l : r
                case .lastWriteWinsByServerEtag:
                    return r
                case .alwaysAccept:
                    return r
                case .custom(let resolver):
                    return resolver(l, r)
                }
            },
            schemaVersion: version,
            minimumCompatibleVersion: minCompat
        )
        metadatas[recordType] = metadata
    }

    func metadata(for recordType: String) -> AnySyncTypeMetadata? {
        metadatas[recordType]
    }

    var allRecordTypes: [String] {
        Array(metadatas.keys)
    }
}
