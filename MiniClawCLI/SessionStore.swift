import Foundation
import SwiftData

/// 会话数据访问层。
/// 方案1（直接读模拟器 SQLite）：本类持有自己的 ModelContainer / ModelContext，
/// 直接打开 App 的 SwiftData 存储文件，**全部访问经由 SwiftData，不写任何裸 SQL**。
///
/// 存储定位：
/// - 传入 --store <path> 时直接使用该文件；
/// - 否则自动扫描 ~/Library/Developer/CoreSimulator 定位 MiniClaw 的 SwiftData 存储。
final class SessionStore {
    let modelContainer: ModelContainer
    let context: ModelContext

    init(storeOverride: String?) throws {
        let url = try SessionStore.resolveStoreURL(override: storeOverride)
        let config = ModelConfiguration(url: url)
        self.modelContainer = try ModelContainer(for: ChatSession.self, ChatMessage.self, configurations: config)
        self.context = ModelContext(modelContainer)
    }

    // MARK: - 模拟器 SQLite 定位

    static func resolveStoreURL(override: String?) throws -> URL {
        if let o = override, !o.isEmpty {
            return URL(fileURLWithPath: o)
        }
        if let discovered = discoverSimulatorStore() {
            return discovered
        }
        throw CLICLIError.storeNotFound
    }

    /// 扫描 CoreSimulator 设备，按 bundle id 找到 MiniClaw 的数据容器并定位 SwiftData 存储文件。
    static func discoverSimulatorStore() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard let devices = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return nil
        }
        let bundleId = "com.neartop.miniclaw.app"
        for device in devices where device.hasDirectoryPath {
            let bundleRoot = device.appendingPathComponent("data/Containers/Bundle/Application")
            let dataRoot = device.appendingPathComponent("data/Containers/Data/Application")
            guard let bundles = try? FileManager.default.contentsOfDirectory(at: bundleRoot, includingPropertiesForKeys: nil) else {
                continue
            }
            var matchingUUIDs: [String] = []
            for b in bundles where b.hasDirectoryPath {
                let plistURL = b.appendingPathComponent("MiniClaw.app/Info.plist")
                guard FileManager.default.fileExists(atPath: plistURL.path),
                      let dict = NSDictionary(contentsOf: plistURL),
                      let bid = dict["CFBundleIdentifier"] as? String, bid == bundleId else {
                    continue
                }
                matchingUUIDs.append(b.lastPathComponent)
            }
            for uuid in matchingUUIDs {
                if let found = findStoreFile(in: dataRoot.appendingPathComponent(uuid)) {
                    return found
                }
            }
        }
        return nil
    }

    /// 在一个 App 数据容器内查找 SwiftData 存储文件（.sqlite / .db / .store）。
    static func findStoreFile(in dataApp: URL) -> URL? {
        let candidates = [
            dataApp.appendingPathComponent("Library/Application Support"),
            dataApp.appendingPathComponent("Documents"),
            dataApp
        ]
        var urls: [URL] = []
        for dir in candidates {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for item in items where !item.hasDirectoryPath {
                let ext = item.pathExtension.lowercased()
                if ["sqlite", "db", "store"].contains(ext) {
                    urls.append(item)
                }
            }
        }
        if let named = urls.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains("miniclaw") }) {
            return named
        }
        return urls.first
    }

    // MARK: - 读取（经 SwiftData）

    func allSessions(limit: Int) -> [ChatSession] {
        let desc = FetchDescriptor<ChatSession>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let all = (try? context.fetch(desc)) ?? []
        return limit > 0 ? Array(all.prefix(limit)) : all
    }

    func session(id: UUID) -> ChatSession? {
        let desc = FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(desc).first
    }

    func list(limit: Int) -> String {
        prettyJSON(allSessions(limit: limit).map { sessionToDict($0) })
    }

    func get(ref: String?) -> String {
        guard let ref, let uuid = UUID(uuidString: ref), let s = session(id: uuid) else {
            return fail("get 需要有效的会话 id")
        }
        var d = sessionToDict(s)
        d["messages"] = s.messages.sorted { $0.createdAt < $1.createdAt }.map { messageToDict($0) }
        return prettyJSON(d)
    }

    func messages(ref: String?) -> String {
        guard let ref, let uuid = UUID(uuidString: ref), let s = session(id: uuid) else {
            return fail("messages 需要有效的会话 id")
        }
        let arr = s.messages.sorted { $0.createdAt < $1.createdAt }.map { messageToDict($0) }
        return prettyJSON(arr)
    }

    func status(ref: String?) -> String {
        guard let ref, let uuid = UUID(uuidString: ref), let s = session(id: uuid) else {
            return fail("status 需要有效的会话 id")
        }
        return prettyJSON([
            "id": s.id.uuidString,
            "title": s.title,
            "status": s.statusRaw,
            "updatedAt": ISO8601DateFormatter().string(from: s.updatedAt),
            "messageCount": s.messages.count
        ])
    }

    func search(keyword: String) -> String {
        let results = allSessions(limit: 0).flatMap { s in
            s.messages
                .filter { $0.content.localizedCaseInsensitiveContains(keyword) }
                .map { (sessionTitle: s.title, message: $0) }
        }
        let arr = results.map { item -> [String: Any] in
            var m = messageToDict(item.message)
            m["sessionTitle"] = item.sessionTitle
            return m
        }
        return prettyJSON(arr)
    }

    // MARK: - 写入（经 SwiftData ModelContext）

    func create(title: String?, model: String?, agentName: String?) -> String {
        let s = ChatSession(
            title: title ?? "新会话",
            modelName: model ?? "未配置",
            agentName: agentName ?? "MiniClaw",
            source: "cli"
        )
        context.insert(s)
        try? context.save()
        return prettyJSON(sessionToDict(s))
    }

    func delete(ref: String?) -> String {
        guard let ref, let uuid = UUID(uuidString: ref) else {
            return fail("delete 需要有效的会话 id")
        }
        guard let s = session(id: uuid) else {
            return fail("未找到会话 \(ref)")
        }
        context.delete(s)
        try? context.save()
        return prettyJSON(["deleted": ref])
    }

    /// 清空全部会话（高风险，受 SecurityGate 保护）。
    func deleteAll() -> String {
        let all = allSessions(limit: 0)
        let count = all.count
        for s in all { context.delete(s) }
        try? context.save()
        return prettyJSON(["deletedAll": count])
    }

    func update(ref: String?, field: String?, value: String?) -> String {
        guard let ref, let uuid = UUID(uuidString: ref) else {
            return fail("update 需要有效的会话 id")
        }
        guard let s = session(id: uuid) else {
            return fail("未找到会话 \(ref)")
        }
        guard let field, let value else {
            return fail("update 需要 --field 与 --value")
        }
        switch field {
        case "title": s.title = value
        case "model": s.modelName = value
        case "agentName": s.agentName = value
        case "status":
            if let st = SessionStatus(rawValue: value) { s.status = st }
        default:
            return fail("update 字段不支持: \(field)（可选: title/model/agentName/status）")
        }
        s.updatedAt = Date()
        try? context.save()
        return prettyJSON(["updated": ref, "field": field])
    }

    @discardableResult
    func appendMessage(sessionID: UUID, role: String, content: String) -> Bool {
        guard let s = session(id: sessionID) else { return false }
        let r = MessageRole(rawValue: role) ?? .user
        let msg = ChatMessage(role: r, content: content)
        msg.session = s
        s.messages.append(msg)
        s.updatedAt = Date()
        try? context.save()
        return true
    }

    func append(ref: String?, role: String, content: String) -> String {
        guard let ref, let uuid = UUID(uuidString: ref) else {
            return fail("append 需要有效的会话 id")
        }
        guard !content.isEmpty else {
            return fail("append 需要 --content")
        }
        guard appendMessage(sessionID: uuid, role: role, content: content) else {
            return fail("未找到会话 \(ref)")
        }
        return prettyJSON(["appended": ref, "role": role])
    }

    func renameSession(id: UUID, title: String) {
        guard let s = session(id: id) else { return }
        s.title = title
        s.updatedAt = Date()
        try? context.save()
    }

    @discardableResult
    func setStatus(id: UUID, status: String) -> Bool {
        guard let s = session(id: id) else { return false }
        if let st = SessionStatus(rawValue: status) { s.status = st }
        s.updatedAt = Date()
        try? context.save()
        return true
    }

    // MARK: - 序列化

    func sessionToDict(_ s: ChatSession) -> [String: Any] {
        [
            "id": s.id.uuidString,
            "title": s.title,
            "model": s.modelName,
            "agentName": s.agentName,
            "status": s.statusRaw,
            "source": s.source,
            "pinned": s.isPinned,
            "createdAt": ISO8601DateFormatter().string(from: s.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: s.updatedAt),
            "messageCount": s.messages.count
        ]
    }

    func messageToDict(_ m: ChatMessage) -> [String: Any] {
        [
            "id": m.id.uuidString,
            "role": m.roleRaw,
            "content": m.content,
            "createdAt": ISO8601DateFormatter().string(from: m.createdAt),
            "attachments": m.attachments,
            "toolCalls": m.toolCalls.map { ["name": $0.name, "success": $0.success] }
        ]
    }
}
