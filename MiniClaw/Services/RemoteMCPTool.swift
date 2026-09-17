import Foundation

/// 动态发现缓存。配置变更时由 MCPConfigStore 使对应 server 失效。
actor MCPToolDiscoveryCache {
    static let shared = MCPToolDiscoveryCache()

    private struct Entry: Sendable {
        let definitions: [MCPRemoteToolDefinition]
        let fetchedAt: Date
    }

    private var entries: [UUID: Entry] = [:]
    private let lifetime: TimeInterval = 300

    /// [T-perf 2026-09-08] 失败负缓存：不可达服务器每次发送都同步等连接超时
    /// （真机 SendTrace 实证单次发现 14.3s、Watchdog 主线程阻塞 8.8s）——
    /// 失败后 60s 内直接快速跳过，不再拖累发送路径。
    private var failures: [UUID: Date] = [:]
    private let failureTTL: TimeInterval = 60
    private let discoverTimeout: TimeInterval = 3

    private struct DiscoveryTimeout: Error {}

    func definitions(
        for server: MCPServerConfig,
        bearerToken: String?,
        forceRefresh: Bool = false
    ) async throws -> [MCPRemoteToolDefinition] {
        if !forceRefresh {
            if let entry = entries[server.id] {
                let age = Date().timeIntervalSince(entry.fetchedAt)
                if age < lifetime {
                    AppLogger.shared.info("[MCP-发现] \(server.name): 缓存命中, \(entry.definitions.count) 个工具")
                    return entry.definitions
                }
                // [T-perf 2026-09-08] stale-while-revalidate：TTL 过期时**先用旧列表立即
                // 返回**并后台刷新——此前过期即同步重拉（1-2s 网络发现），卡在发送路径
                // 上（SendTrace 实证 +1.5s）。工具列表短时间内的变化延后一轮生效，可接受。
                AppLogger.shared.info("[MCP-发现] \(server.name): 缓存过期(\(Int(age))s), 返回旧列表并后台刷新")
                let token = bearerToken
                let sid = server.id
                let name = server.name
                Task {
                    do {
                        let fresh = try await self.discoverWithTimeout(server: server, bearerToken: token)
                        self.entries[sid] = Entry(definitions: fresh, fetchedAt: Date())
                        self.failures[sid] = nil
                        AppLogger.shared.info("[MCP-发现] \(name): 后台刷新完成, \(fresh.count) 个工具")
                    } catch {
                        self.failures[sid] = Date()
                        AppLogger.shared.info("[MCP-发现] \(name): 后台刷新失败 \(error.localizedDescription)")
                    }
                }
                return entry.definitions
            }
            // [2026-09-17 治本·顺序] **先查表、后查失败名单**（原顺序相反）。
            //
            // 原实现把失败检查放在 `entries` 之前：一台服务器刚失败过（含 >3s 发现超时），
            // 即使表里有完整的旧工具表，这一轮也会 `throw DiscoveryTimeout()` ⇒ 调用方丢掉它的
            // **全部工具** ⇒ 本轮 tools schema 变 ⇒ 上下文缓存从 tools 段整段失效，
            // 且模型突然少了一批本来会用的工具。这与本缓存存在的意义（固定工具表伴随生命周期）直接冲突。
            //
            // 语义修正：**失败只决定"要不要后台刷新"，不决定"工具在不在"**。
            // 有表就用表；真不可达时调用会在执行阶段以明确错误返回，而不是让工具凭空消失。
            // 失败名单只在"从来没有成功拉过表"时决定是否跳过。
            // 注意：本检查位于 `if !forceRefresh` 之内 —— `forceRefresh: true` 必须能绕过它，
            // 否则「手动强刷」会被失败负缓存挡住，逃生口失效。
            if let failedAt = failures[server.id],
               Date().timeIntervalSince(failedAt) < failureTTL {
                AppLogger.shared.info("[MCP-发现] \(server.name): 无可用旧表且近期失败过，本轮跳过发现")
                throw DiscoveryTimeout()
            }
        }
        AppLogger.shared.info("[MCP-发现] \(server.name): listTools 开始 (forceRefresh=\(forceRefresh))")
        let definitions = try await discoverWithTimeout(server: server, bearerToken: bearerToken)
        entries[server.id] = Entry(definitions: definitions, fetchedAt: Date())
        failures[server.id] = nil
        return definitions
    }

    /// 实际网络发现（带 3s 超时竞速）：不可达服务器不再拖满连接超时。
    private func discoverWithTimeout(server: MCPServerConfig, bearerToken: String?) async throws -> [MCPRemoteToolDefinition] {
        try await withThrowingTaskGroup(of: [MCPRemoteToolDefinition].self) { group in
            group.addTask {
                let client = await MCPClientManager.shared.client(for: server, bearerToken: bearerToken)
                return try await client.listTools()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.discoverTimeout * 1_000_000_000))
                throw DiscoveryTimeout()
            }
            guard let first = try await group.next() else {
                throw DiscoveryTimeout()
            }
            group.cancelAll()
            return first
        }
    }

    func tools(
        for server: MCPServerConfig,
        bearerToken: String?,
        forceRefresh: Bool = false
    ) async throws -> [RemoteMCPTool] {
        let definitions = try await definitions(for: server, bearerToken: bearerToken, forceRefresh: forceRefresh)
        let client = await MCPClientManager.shared.client(for: server, bearerToken: bearerToken)
        return definitions.map { RemoteMCPTool(server: server, definition: $0, client: client) }
    }

    func invalidate(serverId: UUID) {
        entries[serverId] = nil
    }

    func invalidateAll() {
        entries.removeAll()
    }
}

/// 将远端 MCP tool 暴露为 MiniClaw AgentTool。
struct RemoteMCPTool: AgentTool, @unchecked Sendable {
    let server: MCPServerConfig
    let definition: MCPRemoteToolDefinition
    let client: MCPClientProtocol

    /// 原始 MCP inputSchema，供 ToolProtocol 支持 raw JSON Schema 后无损接入。
    let rawInputSchema: MCPJSONValue
    let name: String
    let schema: ToolSchema
    let resumePolicy: ResumePolicy = .neverRetry
    let activityParameterName = "__miniclaw_activity"

    init(server: MCPServerConfig, definition: MCPRemoteToolDefinition, client: MCPClientProtocol) {
        self.server = server
        self.definition = definition
        self.client = client
        self.rawInputSchema = definition.inputSchema
        self.name = Self.providerSafeName(server: server, toolName: definition.name)
        self.schema = ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: self.name,
                description: definition.description ?? String(format: String(localized: "mcp_tool_desc_fallback"), definition.name, server.name),
                parameters: Self.toolProtocolSchema(from: definition.inputSchema)
            )
        )
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        var remoteParameters = parameters
        remoteParameters.removeValue(forKey: activityParameterName)
        let arguments: [String: MCPJSONValue]
        do {
            arguments = try remoteParameters.mapValues(MCPJSONValue.init(any:))
        } catch {
            throw ToolError.invalidParameters(error.localizedDescription)
        }
        let result = try await client.callTool(name: definition.name, arguments: arguments)
        var data: [String: Any] = ["content": result.content.map(\.foundationValue)]
        if let structuredContent = result.structuredContent {
            data["structuredContent"] = structuredContent.foundationValue
        }
        return ToolResult(success: !result.isError, text: result.text, data: data, attachments: nil)
    }

    private static func providerSafeName(server: MCPServerConfig, toolName: String) -> String {
        let serverName = sanitize(server.name, maxLength: 10)
        let serverID = server.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        let tool = sanitize(toolName, maxLength: 22)
        let hash = stableHash("\(server.id.uuidString):\(toolName)")
        return "mcp__\(serverName)_\(serverID)__\(tool)_\(hash)"
    }

    private static func sanitize(_ value: String, maxLength: Int) -> String {
        var result = String(value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                return Character(String(scalar))
            }
            return "_"
        })
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        if result.isEmpty { result = "server" }
        if let first = result.unicodeScalars.first,
           !CharacterSet.letters.contains(first), first != "_" {
            result = "_" + result
        }
        return String(result.prefix(maxLength))
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return String(format: "%08x", hash)
    }

    private static func toolProtocolSchema(from raw: MCPJSONValue) -> JSONSchema {
        guard case .object(let object) = schemaValue(from: raw) else {
            return JSONSchema(type: "object", properties: [:])
        }
        return JSONSchema(rawObject: object)
    }

    private static func schemaValue(from raw: MCPJSONValue) -> JSONSchemaValue {
        switch raw {
        case .null:
            return .null
        case .bool(let value):
            return .boolean(value)
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map(schemaValue(from:)))
        case .object(let values):
            return .object(values.mapValues(schemaValue(from:)))
        }
    }
}
