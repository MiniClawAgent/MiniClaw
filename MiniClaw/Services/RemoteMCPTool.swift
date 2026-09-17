import Foundation

/// 动态发现缓存。配置变更时由 MCPConfigStore 使对应 server 失效。
actor MCPToolDiscoveryCache {
    static let shared = MCPToolDiscoveryCache()

    private struct Entry: Codable, Sendable {
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

    // ── [2026-09-17 治本·缺口③] 表落盘 ─────────────────────────────────────────
    /// 为什么：表此前**只在内存** ⇒ App 重启后第一轮必须重新冷拉；那一轮若某台服务器慢
    /// （`discoverTimeout = 3s`）或不可达，它的工具就会缺席 ⇒ 本轮 tools schema 变 ⇒
    /// 上下文缓存从 tools 段整段失效，且模型突然少了一批本来会用的工具。
    /// 处置：每次成功拉表都原子写盘；启动后首次查询时用盘上的表**先把内存表补上**，
    /// 再由既有的 stale-while-revalidate 在后台校正 —— 即"表跨启动延续"。
    private var disk: [String: Entry] = [:]
    private var diskLoaded = false

    private static var diskURL: URL {
        FileSystemManager.shared.configDir.appendingPathComponent("mcp_tool_cache.json")
    }

    private func loadDiskIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard let data = try? Data(contentsOf: Self.diskURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        disk = decoded
        AppLogger.shared.info("[MCP-发现] 磁盘缓存载入 \(decoded.count) 台服务器")
    }

    private func saveDisk() {
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? data.write(to: Self.diskURL, options: .atomic)
    }

    /// 成功拉表后的**唯一**写入点：内存 + 磁盘 + 清失败标记。
    private func store(_ entry: Entry, for id: UUID) {
        entries[id] = entry
        disk[id.uuidString] = entry
        saveDisk()
        failures[id] = nil
    }

    /// 内存里没有时，用盘上的旧表补上（跨启动延续）；随后由 stale 路径在后台校正。
    private func seedFromDiskIfNeeded(_ id: UUID) {
        guard entries[id] == nil, let e = disk[id.uuidString] else { return }
        entries[id] = e
        AppLogger.shared.info("[MCP-发现] 从磁盘恢复旧表, \(e.definitions.count) 个工具")
    }

    func definitions(
        for server: MCPServerConfig,
        bearerToken: String?,
        forceRefresh: Bool = false
    ) async throws -> [MCPRemoteToolDefinition] {
        if !forceRefresh {
            loadDiskIfNeeded()
            seedFromDiskIfNeeded(server.id)
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
                        self.store(Entry(definitions: fresh, fetchedAt: Date()), for: sid)
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
        store(Entry(definitions: definitions, fetchedAt: Date()), for: server.id)
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
        disk[serverId.uuidString] = nil
        saveDisk()
    }

    func invalidateAll() {
        entries.removeAll()
        disk.removeAll()
        saveDisk()
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
        // [2026-09-17 治本·缺口④] 这里原先用 `server.id`（配置**实例** UUID）—— 后果是真机实测到的：
        // 把服务器**删掉再加回来**（参数一字不改）会换 UUID ⇒ 8 个工具**全部改名** ⇒
        // 工具段按名字排序后整块变化 ⇒ `[Cache指纹] tools=` 从 `22b836aa` 变 `e4be6796`，
        // 而工具数(8)与 token 数(15248)**一模一样** ⇒ 纯粹的无谓失效，整段上下文缓存作废。
        // 改为**由"定义"派生**：只取用户可见、且重建配置时不变的四项（名称/URL/命令/参数）。
        let key = serverDefinitionKey(server)
        let tool = sanitize(toolName, maxLength: 22)
        let hash = stableHash("\(key):\(toolName)")
        return "mcp__\(serverName)_\(key.prefix(8))__\(tool)_\(hash)"
    }

    /// 服务器**定义**的稳定键（8 位十六进制 FNV-1a）。
    ///
    /// 为什么不用 `server.id`：那是配置实例身份，**重建配置就会变**，而工具名一旦变，模型侧
    /// 工具段的排序位置与字节就全变 ⇒ 上下文缓存从 tools 段整段失效（真机实测：内容完全相同、
    /// token 数完全相同，仅因换 UUID 就换哈希）。
    /// 为什么不用 `lastStatus`/`lastError`/`lastCheckedAt` 等字段：它们**易变**，会让名字随运行状态抖动。
    /// 分隔符是必要的：否则 `"ab"+"c"` 与 `"a"+"bc"` 会撞成同一个键。
    private static func serverDefinitionKey(_ server: MCPServerConfig) -> String {
        var h: UInt32 = 2_166_136_261
        for part in [server.name, server.endpointURL, server.command, server.args] {
            for byte in part.utf8 {
                h ^= UInt32(byte)
                h &*= 16_777_619
            }
            h ^= 0x1F
            h &*= 16_777_619
        }
        return String(format: "%08x", h)
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
