import Combine
import Foundation
import Security

/// 独立于 AppSettings 的远端 MCP 配置存储。
@MainActor
final class MCPConfigStore: ObservableObject {
    static let shared = MCPConfigStore()

    @Published private(set) var servers: [MCPServerConfig]
    private let fileURL: URL

    /// 落盘串行队列（线程治理 2026-08-09）：编码+写盘移后台，主线程只做内存态变更。
    private let ioQueue = DispatchQueue(label: "mcp-config-store-io")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileSystemManager.shared.configDir.appendingPathComponent("mcp_servers.json")
        self.servers = Self.load(from: self.fileURL)
        reconcileBearerTokenFlags()
    }

    func server(id: UUID) -> MCPServerConfig? {
        servers.first { $0.id == id }
    }

    func upsert(_ server: MCPServerConfig, bearerToken: String? = nil) {
        var stored = server
        if let bearerToken {
            let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                MCPBearerTokenStore.deleteToken(for: server.id)
            } else {
                MCPBearerTokenStore.saveToken(token, for: server.id)
            }
            stored.hasBearerToken = !token.isEmpty
        } else {
            stored.hasBearerToken = MCPBearerTokenStore.hasToken(for: server.id)
        }

        if let index = servers.firstIndex(where: { $0.id == stored.id }) {
            servers[index] = stored
        } else {
            servers.append(stored)
        }
        persist()
        Task {
            await MCPClientManager.shared.invalidate(serverId: stored.id)
            await MCPToolDiscoveryCache.shared.invalidate(serverId: stored.id)
        }
    }

    func remove(id: UUID) {
        servers.removeAll { $0.id == id }
        MCPBearerTokenStore.deleteToken(for: id)
        persist()
        Task {
            await MCPClientManager.shared.invalidate(serverId: id)
            await MCPToolDiscoveryCache.shared.invalidate(serverId: id)
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].isEnabled = enabled
        persist()
        Task {
            await MCPClientManager.shared.invalidate(serverId: id)
            await MCPToolDiscoveryCache.shared.invalidate(serverId: id)
        }
    }

    func bearerToken(for id: UUID) -> String? {
        MCPBearerTokenStore.getToken(for: id)
    }

    func updateDiscovery(id: UUID, toolCount: Int, error: Error?) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].lastCheckedAt = Date()
        servers[index].lastToolCount = error == nil ? toolCount : 0
        servers[index].lastStatus = error == nil ? .connected : .failed
        servers[index].lastError = error?.localizedDescription
        persist()
    }

    func markConnecting(id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].lastStatus = .connecting
        servers[index].lastError = nil
    }

    func refresh(id: UUID) async {
        guard let server = server(id: id), server.isEnabled else { return }
        markConnecting(id: id)
        let token = bearerToken(for: id)
        do {
            let tools = try await MCPToolDiscoveryCache.shared.definitions(
                for: server,
                bearerToken: token,
                forceRefresh: true
            )
            updateDiscovery(id: id, toolCount: tools.count, error: nil)
        } catch {
            updateDiscovery(id: id, toolCount: 0, error: error)
        }
    }

    func refreshAll() async {
        let ids = servers.filter(\.isEnabled).map(\.id)
        for id in ids { await refresh(id: id) }
    }

    // MARK: - Claude Desktop 配置导入 / 导出

    /// 导出为 Claude Desktop 格式的 `mcpServers` 配置（仅含已启用的 server）。
    /// HTTP/SSE server → `{ url, headers }`；STDIO server → `{ command, args, env }`。
    /// Bearer 令牌 会注入到 headers 的 Authorization 字段（明文，符合 Claude Desktop 格式）。
    func exportClaudeDesktopConfig(for exportServers: [MCPServerConfig]) -> String {
        var entries: [String: [String: Any]] = [:]
        for server in exportServers where server.isEnabled {
            var entry: [String: Any] = [:]
            switch server.transport {
            case .stdio:
                entry["command"] = server.command
                let args = server.args.split(separator: " ").map(String.init)
                if !args.isEmpty { entry["args"] = args }
                if !server.envVars.isEmpty { entry["env"] = server.envVars }
            default:
                entry["url"] = server.endpointURL
                var headers = server.customHeaders
                if server.hasBearerToken, let token = bearerToken(for: server.id), !token.isEmpty {
                    headers["Authorization"] = "Bearer \(token)"
                }
                if !headers.isEmpty { entry["headers"] = headers }
            }
            entries[server.name] = entry
        }
        let root: [String: Any] = ["mcpServers": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\n  \"mcpServers\": {}\n}"
        }
        return string
    }

    /// 从 Claude Desktop 格式的 JSON 解析出 MCPServerConfig 列表（供调用方 upsert）。
    /// 支持 `command`(→stdio) 与 `url`(→http/sse) 两种形态，并识别 `headers` / `env`。
    func importClaudeDesktopConfig(_ json: String) throws -> [MCPServerConfig] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serversDict = root["mcpServers"] as? [String: Any] else {
            throw MCPClientError.invalidJSON("不是有效的 Claude Desktop 配置：缺少 mcpServers 字典")
        }
        var result: [MCPServerConfig] = []
        for (name, value) in serversDict {
            guard let entry = value as? [String: Any] else { continue }
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported MCP" : name
            if let command = entry["command"] as? String, !command.isEmpty {
                let args = (entry["args"] as? [String])?.joined(separator: " ") ?? ""
                let env = (entry["env"] as? [String: String]) ?? [:]
                result.append(MCPServerConfig(
                    name: displayName,
                    endpointURL: "",
                    transport: .stdio,
                    isEnabled: true,
                    customHeaders: [:],
                    envVars: env,
                    command: command,
                    args: args
                ))
            } else if let url = entry["url"] as? String, !url.isEmpty {
                let headers = (entry["headers"] as? [String: String]) ?? [:]
                let transport: MCPTransport = url.lowercased().contains("/sse") ? .legacySSE : .http
                let hasBearer = headers["Authorization"]?.hasPrefix("Bearer ") ?? false
                var customHeaders = headers
                customHeaders.removeValue(forKey: "Authorization")
                let config = MCPServerConfig(
                    name: displayName,
                    endpointURL: url,
                    transport: transport,
                    isEnabled: true,
                    hasBearerToken: hasBearer,
                    customHeaders: customHeaders
                )
                if hasBearer, let token = headers["Authorization"]?.dropFirst("Bearer ".count) {
                    // Bearer 令牌 不写进 MCPServerConfig 明文；调用方 upsert 时通过 bearerToken 参数入库。
                    importedBearerTokens[config.id] = String(token)
                }
                result.append(config)
            }
        }
        return result
    }

    /// 导入时暂存 Bearer 令牌（key = server id），由调用方在 upsert 时取出传入。
    private var importedBearerTokens: [UUID: String] = [:]

    /// 取回导入时暂存的 Bearer 令牌（取后清除）。
    func takeImportedBearerToken(for id: UUID) -> String? {
        importedBearerTokens.removeValue(forKey: id)
    }

    private func reconcileBearerTokenFlags() {
        var changed = false
        for index in servers.indices {
            let actual = MCPBearerTokenStore.hasToken(for: servers[index].id)
            if servers[index].hasBearerToken != actual {
                servers[index].hasBearerToken = actual
                changed = true
            }
        }
        if changed { persist() }
    }

    private static func load(from url: URL) -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: url),
              let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return servers
    }

    private func persist() {
        // 线程治理（2026-08-09）：servers 值快照后编码+原子写盘移 ioQueue。
        let snapshot = servers
        let url = fileURL
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.shared.error("保存 MCP 配置失败: \(error.localizedDescription)", category: "MCP")
            }
        }
    }
}

/// Bearer 令牌 凭据存储；account 为 MCP server UUID。
enum MCPBearerTokenStore {
    static let service = "com.neartop.miniclaw.mcpbearertoken"

    static func saveToken(_ token: String, for serverId: UUID) {
        let data = Data(token.utf8)
        guard !data.isEmpty else { deleteToken(for: serverId); return }
        let query = baseQuery(for: serverId)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func getToken(for serverId: UUID) -> String? {
        var query = baseQuery(for: serverId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func hasToken(for serverId: UUID) -> Bool {
        SecItemCopyMatching(baseQuery(for: serverId) as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken(for serverId: UUID) {
        SecItemDelete(baseQuery(for: serverId) as CFDictionary)
    }

    private static func baseQuery(for serverId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId.uuidString
        ]
    }
}
