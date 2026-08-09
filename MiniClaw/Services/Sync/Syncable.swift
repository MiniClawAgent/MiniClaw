import Foundation

// MARK: - SyncScope

/// 描述一个 Syncable 类型的记录与其他类型的关系。
/// 传输层据此决定分组（per-session zone keying）和级联删除。
/// @unchecked Sendable：闭包在调用方 @MainActor 上下文中同步执行。
enum SyncScope<T>: @unchecked Sendable {
    /// 每个 App 一条单例记录（如 ProviderConfig）。
    case global
    /// 每个对象一条记录，无父级（如 Session）。
    case perObject(KeyPath<T, String>)
    /// 另一类型的子记录。闭包提取父级 id。
    case perParent(parentType: String, _ parentIdKeyPath: KeyPath<T, String>)
}

// MARK: - ConflictPolicy

/// 冲突解决策略。在类型注册时选择。对齐 ConflictPolicy。
/// @unchecked Sendable：闭包在调用方 @MainActor 上下文中同步执行。
enum ConflictPolicy<T>: @unchecked Sendable {
    /// 比较一个 Date keypath，时间戳较新的一方赢得整条记录。最简单，v2 默认。
    case lastWriteWinsByField(KeyPath<T, Date>)
    /// 信任服务器返回的 etag（CloudKit etag 权威）。
    case lastWriteWinsByServerEtag
    /// 无条件接受传入记录。适用于每设备记录（如设备心跳）。
    case alwaysAccept
    /// 自定义合并函数。
    case custom((_ local: T, _ remote: T) -> T)
}

// MARK: - FieldKind & FieldDescriptor

/// 字段类型标签。定义线上表示。
enum FieldKind {
    case string
    case int
    case double
    case bool
    case date
    case data
    case json(AssetPolicy = .never)
    case asset
}

/// Asset 上传阈值。小 payload 内联为 JSON 字符串，大的走 CKAsset。
enum AssetPolicy {
    case never
    case ifLargerThan(Int)
}

/// 便携字段值——线上传输的统一值类型。
enum PortableFieldValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case null
}

/// 描述 Syncable 类型上的一个同步字段。
/// @unchecked Sendable：闭包在调用方 @MainActor 上下文中同步执行。
struct FieldDescriptor<T>: @unchecked Sendable {
    let cloudKey: String
    let kind: FieldKind
    let isOptional: Bool
    let extract: (T) -> PortableFieldValue
    let apply: (inout T, PortableFieldValue) -> Bool

    // MARK: - Convenience builders

    static func string(_ key: String, _ kp: WritableKeyPath<T, String>, optional: Bool = false) -> FieldDescriptor<T> {
        FieldDescriptor(cloudKey: key, kind: .string, isOptional: optional,
            extract: { .string($0[keyPath: kp]) },
            apply: { model, value in
                if case .string(let s) = value { model[keyPath: kp] = s; return true }
                return false
            })
    }

    static func optionalString(_ key: String, _ kp: WritableKeyPath<T, String?>) -> FieldDescriptor<T> {
        FieldDescriptor(cloudKey: key, kind: .string, isOptional: true,
            extract: { $0[keyPath: kp].map { .string($0) } ?? .null },
            apply: { model, value in
                switch value {
                case .null: model[keyPath: kp] = nil; return true
                case .string(let s): model[keyPath: kp] = s; return true
                default: return false
                }
            })
    }

    static func int(_ key: String, _ kp: WritableKeyPath<T, Int>) -> FieldDescriptor<T> {
        FieldDescriptor(cloudKey: key, kind: .int, isOptional: false,
            extract: { .int($0[keyPath: kp]) },
            apply: { model, value in
                if case .int(let i) = value { model[keyPath: kp] = i; return true }
                return false
            })
    }

    static func optionalInt(_ key: String, _ kp: WritableKeyPath<T, Int?>) -> FieldDescriptor<T> {
        FieldDescriptor(cloudKey: key, kind: .int, isOptional: true,
            extract: { $0[keyPath: kp].map { .int($0) } ?? .null },
            apply: { model, value in
                switch value {
                case .null: model[keyPath: kp] = nil; return true
                case .int(let i): model[keyPath: kp] = i; return true
                default: return false
                }
            })
    }

    static func date(_ key: String, _ kp: WritableKeyPath<T, Date>) -> FieldDescriptor<T> {
        FieldDescriptor(cloudKey: key, kind: .date, isOptional: false,
            extract: { .date($0[keyPath: kp]) },
            apply: { model, value in
                if case .date(let d) = value { model[keyPath: kp] = d; return true }
                return false
            })
    }

    static func optionalDate(_ key: String, _ kp: WritableKeyPath<T, Date?>) -> FieldDescriptor<T> {
        FieldDescriptor(cloudKey: key, kind: .date, isOptional: true,
            extract: { $0[keyPath: kp].map { .date($0) } ?? .null },
            apply: { model, value in
                switch value {
                case .null: model[keyPath: kp] = nil; return true
                case .date(let d): model[keyPath: kp] = d; return true
                default: return false
                }
            })
    }

    static func bool(_ key: String, _ kp: WritableKeyPath<T, Bool>) -> FieldDescriptor<T> {
        FieldDescriptor(cloudKey: key, kind: .bool, isOptional: false,
            extract: { .bool($0[keyPath: kp]) },
            apply: { model, value in
                if case .bool(let b) = value { model[keyPath: kp] = b; return true }
                return false
            })
    }
}

// MARK: - SyncTypeMetadata

/// 描述如何同步一个 Syncable 类型。注册时生成一次，由 SyncCore + 每个 SyncTransport 查询。
/// @unchecked Sendable：闭包在调用方 @MainActor 上下文中同步执行。
struct SyncTypeMetadata<T: Syncable>: @unchecked Sendable {
    let recordType: String
    let idKeyPath: KeyPath<T, String>
    let scope: SyncScope<T>
    let fields: [FieldDescriptor<T>]
    let conflictPolicy: ConflictPolicy<T>
    let version: Int
    let minimumCompatibleVersion: Int?
    let cleanupOnDelete: ((T) -> Void)?

    init(
        recordType: String,
        idKeyPath: KeyPath<T, String>,
        scope: SyncScope<T>,
        fields: [FieldDescriptor<T>],
        conflictPolicy: ConflictPolicy<T>,
        version: Int = 1,
        minimumCompatibleVersion: Int? = nil,
        cleanupOnDelete: ((T) -> Void)? = nil
    ) {
        self.recordType = recordType
        self.idKeyPath = idKeyPath
        self.scope = scope
        self.fields = fields
        self.conflictPolicy = conflictPolicy
        self.version = version
        self.minimumCompatibleVersion = minimumCompatibleVersion
        self.cleanupOnDelete = cleanupOnDelete
    }

    func id(of value: T) -> String { value[keyPath: idKeyPath] }

    func parentId(of value: T) -> (parentType: String, parentId: String)? {
        if case .perParent(let parentType, let kp) = scope {
            return (parentType, value[keyPath: kp])
        }
        return nil
    }
}

// MARK: - Syncable Protocol

/// 应用类型采纳此协议以声明自己可同步。元数据是唯一契约——它携带 schema、序列化器、冲突策略和线上格式。
/// 对齐 Syncable 协议。
protocol Syncable {
    static var syncMetadata: SyncTypeMetadata<Self> { get }
}
