import Foundation

#if os(macOS)
/// 本地 STDIO MCP 客户端（macOS / Simulator / 桌面端可用）。
/// 通过 `Process` 拉起 server 的 command，按 MCP stdio 规范以「换行分隔 JSON」在 stdin/stdout 上做 JSON-RPC。
/// iOS 沙箱禁止拉起任意进程，故 iOS 上走文件末尾的 stub 直接报错。
actor StdioMCPClient: MCPClientProtocol {
    private let server: MCPServerConfig
    private let bearerToken: String?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var initialized = false
    private var negotiatedProtocolVersion = MCPDefaultProtocolVersion
    private var bufferedResponses: [Int: Data] = [:]
    private var waiters: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var pendingIDs = Set<Int>()

    init(server: MCPServerConfig, bearerToken: String?) {
        self.server = server
        self.bearerToken = bearerToken
    }

    func shutdown() async {
        readerTask?.cancel()
        readerTask = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func ensureStarted() throws {
        guard process == nil else { return }
        let command = expandMCPVars(server.command, in: resolveMCPEnv(for: server))
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPClientError.invalidEndpoint
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        let args = expandMCPVars(server.args, in: resolveMCPEnv(for: server))
            .split(separator: " ").map(String.init)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in resolveMCPEnv(for: server) { env[k] = v }
        if let bearerToken, !bearerToken.isEmpty { env["MCP_BEARER_TOKEN"] = bearerToken }
        process.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        self.stdinHandle = stdinPipe.fileHandleForWriting
        try process.run()
        self.process = process
        self.readerTask = Task { [weak self] in
            await self?.consumeStdout(stdoutPipe.fileHandleForReading)
        }
    }

    private func consumeStdout(_ handle: FileHandle) async {
        do {
            for try await line in handle.bytes.lines {
                guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                guard let response = try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: data),
                      response.jsonrpc == "2.0",
                      case .number(let numericID)? = response.id,
                      let id = Int(exactly: numericID) else { continue }
                guard pendingIDs.contains(id) else { bufferedResponses[id] = data; continue }
                pendingIDs.remove(id)
                waiters.removeValue(forKey: id)?.resume(returning: data)
            }
        } catch {
            for (_, waiter) in waiters { waiter.resume(throwing: error) }
            waiters.removeAll()
        }
        // 2026-08-12 修复:EOF(server 进程退出/崩溃)后必须唤醒全部挂起 waiter,
        // 否则 rpc 的 continuation 永久悬挂(全维度审计高危项 4.2)。
        let remaining = waiters
        waiters.removeAll()
        for (_, waiter) in remaining {
            waiter.resume(throwing: MCPClientError.connectionLost("MCP stdio 通道已关闭(server 退出)"))
        }
    }

    private func rpc(method: String, params: MCPJSONValue?) async throws -> MCPJSONValue {
        try ensureStarted()
        let id = nextRequestID
        nextRequestID += 1
        let request = MCPJSONRPCRequest(id: id, method: method, params: params)
        guard let data = try? JSONEncoder().encode(request) else {
            throw MCPClientError.invalidJSON("无法编码 MCP 请求")
        }
        guard let stdin = stdinHandle else { throw MCPClientError.invalidEndpoint }
        try? stdin.write(contentsOf: data + Data("\n".utf8))
        pendingIDs.insert(id)
        // 2026-08-12 修复:加 30s 超时,server 无响应不再永久挂起(全维度审计高危项 4.1)。
        let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.waiters[id] = continuation
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                self.pendingIDs.remove(id)
                self.waiters.removeValue(forKey: id)
                throw MCPClientError.timeout("MCP stdio 请求超时(id=\(id))")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw MCPClientError.timeout("MCP stdio 请求超时(id=\(id))")
            }
            return first
        }
        guard let response = try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: responseData) else {
            throw MCPClientError.invalidResponse("MCP stdio 响应无法解析")
        }
        if let error = response.error { throw MCPClientError.rpc(code: error.code, message: error.message) }
        guard let result = response.result else { throw MCPClientError.invalidResponse("MCP stdio 响应缺少 result") }
        return result
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let result = try await rpc(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPDefaultProtocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("MiniClaw"), "version": .string("1.0")])
            ])
        )
        if let version = result.objectValue?["protocolVersion"]?.stringValue {
            negotiatedProtocolVersion = version
        }
        _ = try? await rpc(method: "notifications/initialized", params: nil)
        initialized = true
    }

    func listTools() async throws -> [MCPRemoteToolDefinition] {
        try await ensureInitialized()
        let result = try await rpc(method: "tools/list", params: .object([:]))
        guard let object = result.objectValue, case .array(let rawTools)? = object["tools"] else {
            throw MCPClientError.invalidResponse("MCP tools/list 缺少 tools 数组")
        }
        return try rawTools.map { value in
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(MCPRemoteToolDefinition.self, from: data)
        }
    }

    func callTool(name: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolCallResult {
        try await ensureInitialized()
        let result = try await rpc(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(arguments)])
        )
        guard let object = result.objectValue else { throw MCPClientError.invalidResponse("MCP tools/call result 不是对象") }
        let isError: Bool
        if case .bool(let value)? = object["isError"] { isError = value } else { isError = false }
        let content: [MCPJSONValue]
        if case .array(let value)? = object["content"] { content = value } else { content = [] }
        let text = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
        return MCPToolCallResult(
            isError: isError,
            text: text.isEmpty ? "MCP 工具调用完成（无文本内容）" : text,
            content: content,
            structuredContent: object["structuredContent"]
        )
    }
}
#else
/// iOS 沙箱禁止拉起本地进程，STDIO MCP 在 iOS 上不可用。直接返回平台限制错误。
actor StdioMCPClient: MCPClientProtocol {
    private let server: MCPServerConfig
    private let bearerToken: String?

    init(server: MCPServerConfig, bearerToken: String?) {
        self.server = server
        self.bearerToken = bearerToken
    }

    func listTools() async throws -> [MCPRemoteToolDefinition] {
        throw MCPClientError.unsupported(
            "STDIO 传输的 MCP 需要拉起本地进程，iOS 沙箱不允许；请在 macOS / Simulator 运行，或改用 HTTP(S) 传输。"
        )
    }

    func callTool(name: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolCallResult {
        throw MCPClientError.unsupported("STDIO 传输的 MCP 在 iOS 上不可用。")
    }

    func shutdown() async {}
}
#endif
