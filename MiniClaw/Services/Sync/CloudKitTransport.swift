import Foundation
import CloudKit

// MARK: - CloudKitTransport

/// CloudKit 同步传输层。对齐 ICloudSharedZoneTransport。
@MainActor
final class CloudKitTransport: SyncTransport {

    let capabilities = TransportCapabilities.cloudKit

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init?() {
        let container = CKContainer(identifier: SyncConstants.cloudKitContainerID)
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: SyncConstants.sharedZoneName, ownerName: CKCurrentUserDefaultName)

        self.container = container
        self.database = database
        self.zoneID = zoneID
    }

    var isReady: Bool {
        get async {
            do {
                let status = try await container.accountStatus()
                return status == .available
            } catch {
                AppLogger.shared.error("CloudKit account check failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    // MARK: - Setup

    func ensureZoneExists() async throws {
        let existingZones = try await database.allRecordZones()
        if existingZones.contains(where: { $0.zoneID == zoneID }) {
            AppLogger.shared.info("Zone '\(SyncConstants.sharedZoneName)' already exists")
            return
        }
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)
        AppLogger.shared.info("Zone created: \(SyncConstants.sharedZoneName)")
    }

    // MARK: - Push (Send)

    func send(records: [PortableRecord]) async throws {
        guard !records.isEmpty else { return }

        let upserts = records.filter { $0.operation == .upsert }
        let deletions = records.filter { $0.operation == .delete }

        // 批量保存
        if !upserts.isEmpty {
            let ckRecords = upserts.map { ckRecord(from: $0) }
            let operation = CKModifyRecordsOperation(recordsToSave: ckRecords, recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.isAtomic = false

            return try await withCheckedThrowingContinuation { continuation in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        AppLogger.shared.info("Pushed \(upserts.count) record(s) to CloudKit")
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                operation.perRecordSaveBlock = { _, result in
                    // 可以在这里处理单条成功/失败
                }
                database.add(operation)
            }
        }

        // 批量删除
        if !deletions.isEmpty {
            let ids = deletions.map { CKRecord.ID(recordName: $0.recordId, zoneID: zoneID) }
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
            operation.isAtomic = false

            return try await withCheckedThrowingContinuation { continuation in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        AppLogger.shared.info("Deleted \(deletions.count) record(s) from CloudKit")
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        }
    }

    // MARK: - Pull (Fetch)

    func fetchChanges(recordTypes: [String]?) async throws -> FetchResult {
        let types = recordTypes ?? SyncableTypeRegistry.shared.allRecordTypes

        var allUpserts: [PortableRecord] = []
        var allDeletions: [(recordType: String, recordId: String)] = []

        for recordType in types {
            let (upserts, deletions) = try await fetchByType(recordType)
            allUpserts.append(contentsOf: upserts)
            allDeletions.append(contentsOf: deletions)
        }

        AppLogger.shared.info("Fetched \(allUpserts.count) upserts, \(allDeletions.count) deletions from CloudKit")
        return FetchResult(upserts: allUpserts, deletions: allDeletions, isFullFetch: false)
    }

    private func fetchByType(_ recordType: String) async throws -> ([PortableRecord], [(recordType: String, recordId: String)]) {
        let predicate = NSPredicate(format: "TRUEPREDICATE")
        let query = CKQuery(recordType: recordType, predicate: predicate)

        var upserts: [PortableRecord] = []
        var deletions: [(String, String)] = []

        // 使用 records(matching:) 兼容 API
        let (matchResults, _) = try await database.records(matching: query, desiredKeys: nil, resultsLimit: 1000)

        for (recordID, result) in matchResults {
            switch result {
            case .success(let record):
                if let portable = portableRecord(from: record) {
                    upserts.append(portable)
                }
            case .failure(let error):
                AppLogger.shared.error("Fetch record \(recordID.recordName.prefix(8)) failed: \(error.localizedDescription)")
            }
        }

        return (upserts, deletions)
    }

    // MARK: - Conversion

    private func ckRecord(from record: PortableRecord) -> CKRecord {
        let recordID = CKRecord.ID(recordName: record.recordId, zoneID: zoneID)
        let ckRecord = CKRecord(recordType: record.recordType, recordID: recordID)

        for (key, value) in record.fields {
            ckRecord[key] = ckValue(from: value) as? any CKRecordValue
        }

        if let parentId = record.parentId {
            let parentID = CKRecord.ID(recordName: parentId, zoneID: zoneID)
            ckRecord.parent = CKRecord.Reference(recordID: parentID, action: .deleteSelf)
        }

        return ckRecord
    }

    private func portableRecord(from ckRecord: CKRecord) -> PortableRecord? {
        var fields: [String: PortableFieldValue] = [:]

        for key in ckRecord.allKeys() {
            if let value = ckRecord[key] {
                fields[key] = portableFieldValue(from: value)
            }
        }

        let parentId = ckRecord.parent?.recordID.recordName

        return PortableRecord(
            recordType: ckRecord.recordType,
            recordId: ckRecord.recordID.recordName,
            parentType: nil,
            parentId: parentId,
            fields: fields,
            transportMetadata: ckRecord.recordChangeTag.map { ["etag": $0] } ?? [:]
        )
    }

    // MARK: - Field Value Conversion

    private func ckValue(from pv: PortableFieldValue) -> Any? {
        switch pv {
        case .string(let s): return s
        case .int(let i): return Int64(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 as Int64 : 0 as Int64
        case .date(let d): return d
        case .data(let d): return d as NSData
        case .null: return nil
        }
    }

    private func portableFieldValue(from value: Any) -> PortableFieldValue {
        if let s = value as? String { return .string(s) }
        if let i = value as? Int { return .int(i) }
        if let i = value as? Int64 { return .int(Int(i)) }
        if let d = value as? Double { return .double(d) }
        if let b = value as? Bool { return .bool(b) }
        if let d = value as? Date { return .date(d) }
        if let d = value as? Data { return .data(d) }
        if let d = value as? NSData { return .data(d as Data) }
        return .null
    }
}
