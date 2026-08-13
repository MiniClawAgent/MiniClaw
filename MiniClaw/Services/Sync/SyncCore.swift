import Foundation
import os.log

// MARK: - SyncDirtyReason

/// 记录被标记为 dirty 的原因。
enum SyncDirtyReason: String, Sendable {
    case localUpsert
    case localDelete
    case migrationInitialPush
    case retryAfterTransientFailure
    case other
}

// MARK: - SyncCore

/// 中央调度器，在应用写入和已配置的 transport 之间分发。
/// 对齐 SyncCore。
@MainActor
final class SyncCore {
    static let shared = SyncCore()
    private init() {}

    // MARK: - Configuration

    private(set) var transports: [SyncTransport] = []
    private(set) var isRunning: Bool = false

    /// 已注册的 hydrator（按 recordType 索引）。
    private var hydrators: [String: any SyncHydrator] = [:]

    // 同步状态 UI 时间戳。
    private(set) var lastSendAt: Date?
    private(set) var lastFetchAt: Date?
    private(set) var totalSent: Int = 0
    private(set) var totalReceived: Int = 0

    // MARK: - Dirty Queue

    private var dirtyRecords: Set<DirtyKey> = []
    private var sendDebounceTask: Task<Void, Never>?
    private let debounceDelay: TimeInterval = 3.0

    private struct DirtyKey: Hashable {
        let recordType: String
        let recordId: String
        /// 2026-08-12 修复:删除操作标记——此前 markDeleted 与 markDirty 混同,
        /// sendNow 只构建存在的记录,已删除的 recordId 不在 buildAll 结果里被过滤掉,
        /// 删除永远无法推送到远端(全维度审计高危项 2.2)。
        let isDeletion: Bool
    }

    // MARK: - Lifecycle

    func registerTransport(_ transport: SyncTransport) {
        transports.append(transport)
        AppLogger.shared.info("Transport registered: \(transport.capabilities.name)")
    }

    /// 注册 hydrator。按 recordType 索引。
    func registerHydrator<H: SyncHydrator>(_ hydrator: H) {
        let recordType = H.SyncType.syncMetadata.recordType
        hydrators[recordType] = hydrator
        AppLogger.shared.info("Hydrator registered: \(recordType)")
    }

    func start() async {
        guard !isRunning else { return }
        for transport in transports {
            let ready = await transport.isReady
            AppLogger.shared.info("Transport \(transport.capabilities.name) ready=\(ready)")
        }
        isRunning = true
        AppLogger.shared.info("SyncCore started: \(transports.count) transport(s), \(hydrators.count) hydrator(s)")
        Task { await fetchFromAllTransports() }
    }

    func stop() {
        isRunning = false
        sendDebounceTask?.cancel()
        sendDebounceTask = nil
        AppLogger.shared.info("SyncCore stopped")
    }

    // MARK: - Mark Dirty (Push Path)

    func markDirty(recordType: String, recordId: String, reason: SyncDirtyReason = .localUpsert) {
        guard isRunning else { return }
        let key = DirtyKey(recordType: recordType, recordId: recordId, isDeletion: false)
        dirtyRecords.insert(key)
        AppLogger.shared.info("Dirty+: type=\(recordType) id=\(recordId.prefix(8)) reason=\(reason.rawValue) queue=\(dirtyRecords.count)")
        scheduleSend()
    }

    func markDeleted(recordType: String, recordId: String) {
        guard isRunning else { return }
        let key = DirtyKey(recordType: recordType, recordId: recordId, isDeletion: true)
        dirtyRecords.insert(key)
        AppLogger.shared.info("DirtyDelete: type=\(recordType) id=\(recordId.prefix(8)) queue=\(dirtyRecords.count)")
        scheduleSend()
    }

    /// 标记某类型全部记录为 dirty（全量重推）。由 hydrator.buildAll() 生成记录。
    func markAllDirty(recordType: String) {
        guard isRunning else { return }
        // 直接触发一次该类型的全量构建并推送
        Task { await pushFullType(recordType) }
    }

    /// 标记所有类型全部 dirty（首次同步 / 强制重推）。
    func markEverythingDirty() {
        guard isRunning else { return }
        for recordType in hydrators.keys {
            Task { await pushFullType(recordType) }
        }
    }

    // MARK: - Send (Push)

    private func scheduleSend() {
        sendDebounceTask?.cancel()
        sendDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.debounceDelay ?? 3.0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sendNow()
        }
    }

    /// 立即推送所有 dirty 记录。
    func sendNow() async {
        sendDebounceTask?.cancel()
        sendDebounceTask = nil

        guard !dirtyRecords.isEmpty else { return }
        let toSend = dirtyRecords
        dirtyRecords.removeAll()

        AppLogger.shared.info("Send: \(toSend.count) dirty key(s)")

        // 按 recordType 分组，让 hydrator 构建 PortableRecord
        var allRecords: [PortableRecord] = []
        let grouped = Dictionary(grouping: Array(toSend)) { $0.recordType }

        for (recordType, keys) in grouped {
            guard let hydrator = hydrators[recordType] else {
                AppLogger.shared.warn("No hydrator for \(recordType), skipping \(keys.count) records")
                continue
            }
            // 删除操作走 buildDeletion(构建 operation == .delete 的记录),
            // 其余走 buildRecords——修复删除永不推送(全维度审计 2.2)。
            let deletions = keys.filter { $0.isDeletion }
            let upserts = keys.filter { !$0.isDeletion }
            var records: [PortableRecord] = []
            if !upserts.isEmpty {
                records += await buildRecords(hydrator: hydrator, keys: upserts)
            }
            for dk in deletions {
                records.append(hydrator.buildDeletion(id: dk.recordId))
            }
            allRecords.append(contentsOf: records)
        }

        guard !allRecords.isEmpty else {
            AppLogger.shared.info("Send: all records filtered out, nothing to send")
            return
        }

        // 向所有 transport 广播
        for transport in transports {
            do {
                let ready = await transport.isReady
                guard ready else {
                    // 2026-08-12 修复:未就绪时把本批放回队列,否则本地变更永久丢失(审计 2.1)。
                    AppLogger.shared.warn("Transport \(transport.capabilities.name) not ready, requeue \(toSend.count) key(s)")
                    for key in toSend { dirtyRecords.insert(key) }
                    return
                }
                try await transport.send(records: allRecords)
                totalSent += allRecords.count
                AppLogger.shared.info("Pushed \(allRecords.count) record(s) via \(transport.capabilities.name)")
            } catch {
                AppLogger.shared.error("Send error: \(error.localizedDescription)")
                // 放回 dirty 队列重试
                for key in toSend { dirtyRecords.insert(key) }
            }
        }

        lastSendAt = Date()
    }

    /// 全量推送某类型：用 hydrator.buildAll() 构建所有记录并推送。
    private func pushFullType(_ recordType: String) async {
        guard let hydrator = hydrators[recordType] else { return }
        let records = await hydrator.buildAll()
        guard !records.isEmpty else { return }

        for transport in transports {
            do {
                let ready = await transport.isReady
                guard ready else { continue }
                try await transport.send(records: records)
                totalSent += records.count
            } catch {
                AppLogger.shared.error("Full push error for \(recordType): \(error.localizedDescription)")
            }
        }
        lastSendAt = Date()
    }

    /// 从 dirty key 构建 PortableRecord。单条记录用 hydrator.buildAll() 过滤。
    private func buildRecords(hydrator: any SyncHydrator, keys: [DirtyKey]) async -> [PortableRecord] {
        // 对于 per-record dirty，用 buildAll() 构建全部再过滤（简化实现）
        let allRecords = await hydrator.buildAll()
        let idSet = Set(keys.map { $0.recordId })
        return allRecords.filter { idSet.contains($0.recordId) }
    }

    // MARK: - Fetch (Pull Path)

    func fetchFromAllTransports() async {
        guard isRunning else { return }
        AppLogger.shared.info("Fetch: from \(transports.count) transport(s)")

        for transport in transports {
            do {
                let ready = await transport.isReady
                guard ready else { continue }
                let result = try await transport.fetchChanges(recordTypes: nil)
                AppLogger.shared.info("Fetch \(transport.capabilities.name): \(result.upserts.count) upserts, \(result.deletions.count) deletions")

                // 合并入站记录
                for record in result.upserts {
                    await processInbound(record)
                }
                for deletion in result.deletions {
                    await processDeletion(recordType: deletion.recordType, recordId: deletion.recordId)
                }

                totalReceived += result.upserts.count
            } catch {
                AppLogger.shared.error("Fetch error: \(error.localizedDescription)")
            }
        }

        lastFetchAt = Date()
    }

    // MARK: - Inbound Merge

    /// 合并一条入站记录到本地存储。
    func processInbound(_ record: PortableRecord) async {
        guard let hydrator = hydrators[record.recordType] else {
            AppLogger.shared.warn("No hydrator for inbound type \(record.recordType)")
            return
        }
        await hydrator.merge(record)
    }

    /// 处理远程删除。
    func processDeletion(recordType: String, recordId: String) async {
        guard let hydrator = hydrators[recordType] else {
            AppLogger.shared.warn("No hydrator for deletion type \(recordType)")
            return
        }
        await hydrator.applyDeletion(recordId: recordId)
    }
}
