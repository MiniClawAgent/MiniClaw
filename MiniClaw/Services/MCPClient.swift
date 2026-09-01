import Foundation

/// MCP 凭据只允许随同源重定向继续发送；跨源 30x 直接停止，避免 Bearer 令牌 外泄。
private final class MCPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuredEndpoint: URL?

    init(configuredEndpoint: URL?) {
        self.configuredEndpoint = configuredEndpoint
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let configuredEndpoint,
              let redirectedURL = request.url,
              RemoteMCPClient.isSameOrigin(redirectedURL, configuredEndpoint) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor MCPClientManager {
    static let shared = MCPClientManager()

    private var clients: [UUID: MCPClientProtocol] = [:]

    func client(for server: MCPServerConfig, bearerToken: String?) -> MCPClientProtocol {
        if let client = clients[server.id] { return client }
        let client: MCPClientProtocol
        if server.transport == .stdio {
            client = StdioMCPClient(server: server, bearerToken: bearerToken)
        } else {
            client = RemoteMCPClient(server: server, bearerToken: bearerToken)
        }
        clients[server.id] = client
        return client
    }

    func invalidate(serverId: UUID) async {
        if let client = clients.removeValue(forKey: serverId) { await client.shutdown() }
    }

    func invalidateAll() async {
        let activeClients = Array(clients.values)
        clients.removeAll()
        for client in activeClients { await client.shutdown() }
    }
}

/// 单个远端 MCP server 的 JSON-RPC session。actor 串行化 initialize、分页与工具调用。
actor RemoteMCPClient {
    private let server: MCPServerConfig
    private let bearerToken: String?
    private let customHeaders: [String: String]
    private let redirectDelegate: MCPRedirectDelegate
    private let session: URLSession
    private let streamingSession: URLSession
    private var nextRequestID = 1
    private var sessionID: String?
    private var negotiatedProtocolVersion = MCPDefaultProtocolVersion
    private var initialized = false
    private var legacyMessageEndpoint: URL?
    private var autoSelectedLegacy = false
    private var legacyReaderTask: Task<Void, Never>?
    private var legacyEndpointWaiters: [UUID: CheckedContinuation<URL, any Error>] = [:]
    private let legacyEndpointTimeoutNanoseconds: UInt64 = 30_000_000_000
    private var legacyResponseWaiters: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var legacyPendingResponseIDs = Set<Int>()
    private var legacyBufferedResponses: [Int: Data] = [:]
    private let legacyResponseTimeoutNanoseconds: UInt64 = 30_000_000_000

    init(server: MCPServerConfig, bearerToken: String?, session: URLSession? = nil) {
        self.server = server
        self.bearerToken = bearerToken
        // 发送前把配置里的 ${VAR} 引用展开为真实环境变量值（server.envVars 优先，回退全局环境变量）。
        self.customHeaders = server.customHeaders.mapValues { expandMCPVars($0, in: resolveMCPEnv(for: server)) }
        let configuredEndpoint = URL(string: server.endpointURL)
        let redirectDelegate = MCPRedirectDelegate(configuredEndpoint: configuredEndpoint)
        self.redirectDelegate = redirectDelegate
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        }
        let streamingConfiguration = URLSessionConfiguration.ephemeral
        streamingConfiguration.timeoutIntervalForRequest = 86_400
        streamingConfiguration.timeoutIntervalForResource = 604_800
        streamingConfiguration.waitsForConnectivity = false
        self.streamingSession = URLSession(
            configuration: streamingConfiguration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    func shutdown() async {
        legacyReaderTask?.cancel()
        legacyReaderTask = nil
        streamingSession.invalidateAndCancel()
        failLegacyStream(CancellationError())
    }

    func listTools() async throws -> [MCPRemoteToolDefinition] {
        try await ensureInitialized()
        var tools: [MCPRemoteToolDefinition] = []
        var cursor: String?
        var seenCursors = Set<String>()

        for _ in 0..<100 {
            var params: [String: MCPJSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await rpc(method: "tools/list", params: .object(params))
            guard let object = result.objectValue,
                  case .array(let rawTools)? = object["tools"] else {
                throw MCPClientError.invalidResponse(L10n.l("mcp_tools_list_missing"))
            }
            tools.append(contentsOf: try rawTools.map(decodeTool))
            guard let next = object["nextCursor"]?.stringValue, !next.isEmpty else { return tools }
            guard seenCursors.insert(next).inserted else { throw MCPClientError.paginationLimit }
            cursor = next
        }
        throw MCPClientError.paginationLimit
    }

    func callTool(name: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolCallResult {
        try await ensureInitialized()
        let result = try await rpc(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(arguments)])
        )
        guard let object = result.objectValue else {
            throw MCPClientError.invalidResponse(L10n.l("mcp_tools_call_not_object"))
        }
        let isError: Bool
        if case .bool(let value)? = object["isError"] { isError = value } else { isError = false }
        let content: [MCPJSONValue]
        if case .array(let value)? = object["content"] { content = value } else { content = [] }
        let structured = object["structuredContent"]
        return MCPToolCallResult(
            isError: isError,
            text: Self.mergeContent(content, structuredContent: structured),
            content: content,
            structuredContent: structured
        )
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let result = try await rpc(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPDefaultProtocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("MiniClaw"),
                    "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                ])
            ]),
            allowUninitialized: true
        )
        if let version = result.objectValue?["protocolVersion"]?.stringValue {
            negotiatedProtocolVersion = version
        }
        try await sendNotification(method: "notifications/initialized", params: nil)
        initialized = true
    }

    private func rpc(method: String, params: MCPJSONValue?, allowUninitialized: Bool = false) async throws -> MCPJSONValue {
        if !allowUninitialized && !initialized { try await ensureInitialized() }
        let id = nextRequestID
        nextRequestID += 1
        let request = MCPJSONRPCRequest(id: id, method: method, params: params)
        let responseData = try await send(request)
        let response = try decodeResponse(responseData)
        guard response.jsonrpc == "2.0", case .number(let responseID)? = response.id, Int(exactly: responseID) == id else {
            throw MCPClientError.invalidResponse(L10n.l("mcp_jsonrpc_id_mismatch"))
        }
        if let error = response.error { throw MCPClientError.rpc(code: error.code, message: error.message) }
        guard let result = response.result else { throw MCPClientError.invalidResponse(L10n.l("mcp_jsonrpc_missing_result")) }
        return result
    }

    private func sendNotification(method: String, params: MCPJSONValue?) async throws {
        _ = try await send(MCPJSONRPCRequest(id: nil, method: method, params: params), expectsResponse: false)
    }

    private func send(_ message: MCPJSONRPCRequest, expectsResponse: Bool = true) async throws -> Data {
        let expandedURLString = expandMCPVars(server.endpointURL, in: resolveMCPEnv(for: server))
        guard let configuredURL = URL(string: expandedURLString),
              ["http", "https"].contains(configuredURL.scheme?.lowercased() ?? "") else {
            throw MCPClientError.invalidEndpoint
        }
        switch server.transport {
        case .http:
            return try await post(message, to: configuredURL, expectsResponse: expectsResponse)
        case .legacySSE:
            return try await legacySend(message, endpoint: configuredURL, expectsResponse: expectsResponse)
        case .stdio:
            throw MCPClientError.unsupported(L10n.l("mcp_remote_http_only"))
        case .auto:
            if autoSelectedLegacy {
                return try await legacySend(message, endpoint: configuredURL, expectsResponse: expectsResponse)
            }
            do {
                return try await post(message, to: configuredURL, expectsResponse: expectsResponse)
            } catch MCPClientError.httpStatus(let status, _) where status == 404 || status == 405 {
                autoSelectedLegacy = true
                return try await legacySend(message, endpoint: configuredURL, expectsResponse: expectsResponse)
            }
        }
    }

    /// 把用户自定义的请求头注入到请求中；协议保留头（Content-Type / Accept /
    /// MCP-Protocol-Version / Mcp-Session-Id / Authorization）由系统托管，此处跳过，
    /// 避免用户配置覆盖导致协议握手失败。
    private func applyCustomHeaders(to request: inout URLRequest) {
        let reserved = Set([
            "content-type", "accept", "mcp-protocol-version",
            "mcp-session-id", "authorization"
        ])
        for (name, value) in customHeaders where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            guard !reserved.contains(name.lowercased()) else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func post(_ message: MCPJSONRPCRequest, to url: URL, expectsResponse: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let bearerToken, !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        applyCustomHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(message)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MCPClientError.invalidResponse(L10n.l("mcp_response_not_http"))
            }
            if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !value.isEmpty { sessionID = value }
            if http.statusCode != 200 {
                AppLogger.shared.info("[MCP-HTTP] \(http.statusCode) \(http.url?.absoluteString ?? "")")
            }
            guard (200..<300).contains(http.statusCode) else {
                AppLogger.shared.info("[MCP-HTTP] \(http.statusCode) 响应体: \(String(decoding: data.prefix(300), as: UTF8.self))")
                throw MCPClientError.httpStatus(http.statusCode, String(decoding: data.prefix(2048), as: UTF8.self))
            }
            if !expectsResponse { return data }
            return try Self.extractJSON(
                from: data,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                requestID: message.id
            )
        } catch let error as MCPClientError {
            throw error
        } catch {
            throw MCPClientError.transport(error.localizedDescription)
        }
    }

    private func legacySend(_ message: MCPJSONRPCRequest, endpoint: URL, expectsResponse: Bool) async throws -> Data {
        let messageURL = try await ensureLegacyStream(endpoint: endpoint)
        var request = URLRequest(url: messageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let bearerToken, !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        applyCustomHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(message)

        let requestID = expectsResponse ? message.id : nil
        // 先登记 request id 再发 POST；SSE response 可能在 POST 返回前到达。
        if let requestID { legacyPendingResponseIDs.insert(requestID) }
        let postData: Data
        let response: URLResponse
        do {
            (postData, response) = try await session.data(for: request)
        } catch {
            if let requestID { cancelLegacyResponse(requestID: requestID) }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            if let requestID { cancelLegacyResponse(requestID: requestID) }
            throw MCPClientError.invalidResponse(L10n.l("mcp_legacy_post_not_http"))
        }
        guard (200..<300).contains(http.statusCode) else {
            if let requestID { cancelLegacyResponse(requestID: requestID) }
            throw MCPClientError.httpStatus(http.statusCode, String(decoding: postData.prefix(2048), as: UTF8.self))
        }
        guard let requestID else { return postData }
        if !postData.isEmpty,
           (try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: postData)) != nil {
            legacyPendingResponseIDs.remove(requestID)
            legacyBufferedResponses.removeValue(forKey: requestID)
            return postData
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let buffered = legacyBufferedResponses.removeValue(forKey: requestID) {
                    legacyPendingResponseIDs.remove(requestID)
                    continuation.resume(returning: buffered)
                } else {
                    legacyResponseWaiters[requestID] = continuation
                    Task { [legacyResponseTimeoutNanoseconds] in
                        do {
                            try await Task.sleep(nanoseconds: legacyResponseTimeoutNanoseconds)
                            self.timeoutLegacyResponse(requestID: requestID)
                        } catch {
                            // Timer task only ends early during shutdown; waiter cleanup is handled elsewhere.
                        }
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelLegacyResponse(requestID: requestID) }
        }
    }

    private func timeoutLegacyResponse(requestID: Int) {
        guard legacyPendingResponseIDs.remove(requestID) != nil else { return }
        legacyBufferedResponses.removeValue(forKey: requestID)
        legacyResponseWaiters.removeValue(forKey: requestID)?.resume(
            throwing: MCPClientError.responseTimeout(requestID)
        )
    }

    private func cancelLegacyResponse(requestID: Int) {
        guard legacyPendingResponseIDs.remove(requestID) != nil else { return }
        legacyBufferedResponses.removeValue(forKey: requestID)
        legacyResponseWaiters.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
    }

    private func ensureLegacyStream(endpoint: URL) async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let legacyMessageEndpoint {
                    continuation.resume(returning: legacyMessageEndpoint)
                    return
                }
                legacyEndpointWaiters[waiterID] = continuation
                if legacyReaderTask == nil {
                    legacyReaderTask = Task { await self.consumeLegacyStream(endpoint: endpoint) }
                }
                Task { [legacyEndpointTimeoutNanoseconds] in
                    do {
                        try await Task.sleep(nanoseconds: legacyEndpointTimeoutNanoseconds)
                        self.timeoutLegacyEndpoint(waiterID: waiterID)
                    } catch {
                        // Cancellation cleanup is handled by the caller/shutdown path.
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelLegacyEndpoint(waiterID: waiterID) }
        }
    }

    private func timeoutLegacyEndpoint(waiterID: UUID) {
        legacyEndpointWaiters.removeValue(forKey: waiterID)?.resume(
            throwing: MCPClientError.transport(L10n.l("mcp_legacy_sse_endpoint_timeout"))
        )
    }

    private func cancelLegacyEndpoint(waiterID: UUID) {
        legacyEndpointWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    private func consumeLegacyStream(endpoint: URL) async {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 86_400
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if let bearerToken, !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
            applyCustomHeaders(to: &request)
            let (bytes, response) = try await streamingSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw MCPClientError.invalidResponse(L10n.l("mcp_legacy_sse_not_http")) }
            guard (200..<300).contains(http.statusCode) else { throw MCPClientError.httpStatus(http.statusCode, L10n.l("mcp_legacy_sse_conn_failed")) }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                throw MCPClientError.invalidResponse(L10n.l("mcp_legacy_sse_not_event_stream"))
            }

            var eventName: String?
            var dataLines: [String] = []
            for try await line in bytes.lines {
                if line.isEmpty {
                    try processLegacyEvent(name: eventName, data: dataLines.joined(separator: "\n"), baseURL: endpoint)
                    eventName = nil
                    dataLines.removeAll(keepingCapacity: true)
                } else if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }
            throw MCPClientError.transport(L10n.l("mcp_legacy_sse_closed"))
        } catch {
            failLegacyStream(error)
        }
    }

    private func processLegacyEvent(name: String?, data: String, baseURL: URL) throws {
        guard !data.isEmpty else { return }
        if name == "endpoint" {
            guard legacyMessageEndpoint == nil else { return }
            guard let resolved = URL(string: data.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: baseURL)?.absoluteURL,
                  Self.isSameOrigin(resolved, baseURL),
                  resolved.user == nil, resolved.password == nil, resolved.fragment == nil else {
                throw MCPClientError.invalidResponse(L10n.l("mcp_legacy_sse_origin_mismatch"))
            }
            legacyMessageEndpoint = resolved
            let waiters = legacyEndpointWaiters.values
            legacyEndpointWaiters.removeAll()
            waiters.forEach { $0.resume(returning: resolved) }
            return
        }
        guard let payload = data.data(using: .utf8),
              let response = try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: payload),
              response.jsonrpc == "2.0",
              case .number(let numericID)? = response.id,
              let id = Int(exactly: numericID) else { return }
        guard legacyPendingResponseIDs.contains(id) else { return }
        if let waiter = legacyResponseWaiters.removeValue(forKey: id) {
            legacyPendingResponseIDs.remove(id)
            waiter.resume(returning: payload)
        } else {
            // Response 可能早于 POST 完成；只缓存已登记的 request id，避免未知 id 无界占用内存。
            legacyBufferedResponses[id] = payload
        }
    }

    private func failLegacyStream(_ error: Error) {
        legacyReaderTask = nil
        legacyMessageEndpoint = nil
        let endpointWaiters = legacyEndpointWaiters.values
        legacyEndpointWaiters.removeAll()
        endpointWaiters.forEach { $0.resume(throwing: error) }
        let responseWaiters = legacyResponseWaiters.values
        legacyResponseWaiters.removeAll()
        responseWaiters.forEach { $0.resume(throwing: error) }
        legacyPendingResponseIDs.removeAll()
        legacyBufferedResponses.removeAll()
    }

    fileprivate static func isSameOrigin(_ candidate: URL, _ configured: URL) -> Bool {
        guard let candidateScheme = candidate.scheme?.lowercased(),
              let configuredScheme = configured.scheme?.lowercased(),
              let candidateHost = candidate.host?.lowercased(),
              let configuredHost = configured.host?.lowercased() else { return false }
        func port(_ url: URL, scheme: String) -> Int {
            url.port ?? (scheme == "https" ? 443 : 80)
        }
        return candidateScheme == configuredScheme
            && candidateHost == configuredHost
            && port(candidate, scheme: candidateScheme) == port(configured, scheme: configuredScheme)
    }

    private func decodeResponse(_ data: Data) throws -> MCPJSONRPCResponse {
        do { return try JSONDecoder().decode(MCPJSONRPCResponse.self, from: data) }
        catch { throw MCPClientError.invalidResponse(String(format: L10n.l("mcp_parse_failed"), error.localizedDescription)) }
    }

    private func decodeTool(_ value: MCPJSONValue) throws -> MCPRemoteToolDefinition {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MCPRemoteToolDefinition.self, from: data)
    }

    private static func mergeContent(_ content: [MCPJSONValue], structuredContent: MCPJSONValue?) -> String {
        var pieces: [String] = []
        for item in content {
            if let object = item.objectValue,
               object["type"]?.stringValue == "text",
               let text = object["text"]?.stringValue {
                pieces.append(text)
            } else {
                pieces.append(item.jsonString(pretty: true))
            }
        }
        if let structuredContent, pieces.isEmpty { pieces.append(structuredContent.jsonString(pretty: true)) }
        return pieces.isEmpty ? L10n.l("mcp_no_text_content") : pieces.joined(separator: "\n")
    }

    private static func extractJSON(from data: Data, contentType: String?, requestID: Int?) throws -> Data {
        let lower = contentType?.lowercased() ?? ""
        if lower.contains("text/event-stream") || String(decoding: data.prefix(32), as: UTF8.self).contains("data:") {
            let payloads = parseSSE(data).compactMap { event -> Data? in
                guard !event.data.isEmpty else { return nil }
                return event.data.data(using: .utf8)
            }
            if let requestID {
                for payload in payloads {
                    guard let response = try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: payload),
                          response.jsonrpc == "2.0",
                          case .number(let numericID)? = response.id,
                          Int(exactly: numericID) == requestID else { continue }
                    return payload
                }
                throw MCPClientError.invalidResponse(L10n.l("mcp_sse_missing_request_id"))
            }
            guard let payload = payloads.last else {
                throw MCPClientError.invalidResponse(L10n.l("mcp_sse_missing_data"))
            }
            return payload
        }
        return data
    }

    private struct SSEEvent {
        var event: String?
        var data: String
    }

    private static func parseSSE(_ data: Data) -> [SSEEvent] {
        let normalized = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            var event: String?
            var dataLines: [String] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("event:") { event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                else if line.hasPrefix("data:") { dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
        }
    }
}

extension RemoteMCPClient: MCPClientProtocol {}
