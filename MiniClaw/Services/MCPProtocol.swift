import Foundation

let MCPDefaultProtocolVersion = "2024-11-05"

/// MCP 协议中的任意 JSON 值。
indirect enum MCPJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MCPJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: MCPJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    init(any value: Any) throws {
        switch value {
        case is NSNull: self = .null
        case let value as Bool: self = .bool(value)
        case let value as String: self = .string(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as [Any]: self = .array(try value.map(MCPJSONValue.init(any:)))
        case let value as [String: Any]: self = .object(try value.mapValues(MCPJSONValue.init(any:)))
        default: throw MCPClientError.invalidJSON(String(format: String(localized: "mcp_unsupported_param_type"), String(describing: type(of: value))))
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.foundationValue)
        case .object(let value): value.mapValues(\.foundationValue)
        }
    }

    var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    func jsonString(pretty: Bool = false) -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        if pretty,
           let object = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: formatted, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct MCPRemoteToolDefinition: Codable, Hashable, Sendable {
    let name: String
    let description: String?
    let inputSchema: MCPJSONValue

    private enum CodingKeys: String, CodingKey { case name, description, inputSchema }

    init(name: String, description: String?, inputSchema: MCPJSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try values.decodeIfPresent(MCPJSONValue.self, forKey: .inputSchema) ?? .object(["type": .string("object")])
    }
}

struct MCPToolCallResult: Sendable {
    let isError: Bool
    let text: String
    let content: [MCPJSONValue]
    let structuredContent: MCPJSONValue?
}

enum MCPClientError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidJSON(String)
    case transport(String)
    case httpStatus(Int, String)
    case rpc(code: Int, message: String)
    case invalidResponse(String)
    case responseTimeout(Int)
    case timeout(String)
    case connectionLost(String)
    case paginationLimit
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: String(localized: "mcp_err_invalid_endpoint")
        case .invalidJSON(let message), .transport(let message), .invalidResponse(let message): message
        case .httpStatus(let status, let body): "MCP HTTP \(status): \(body)"
        case .rpc(let code, let message): "MCP RPC \(code): \(message)"
        case .responseTimeout(let requestID): String(format: String(localized: "mcp_err_response_timeout"), requestID)
        case .timeout(let message): message
        case .connectionLost(let message): message
        case .paginationLimit: String(localized: "mcp_err_pagination_limit")
        case .unsupported(let message): message
        }
    }
}

/// MCP 客户端统一协议：远端 HTTP/SSE 与本地 STDIO 实现都遵循，
/// 使 MCPClientManager / MCPToolDiscoveryCache / RemoteMCPTool 与具体传输解耦。
protocol MCPClientProtocol: Sendable {
    func listTools() async throws -> [MCPRemoteToolDefinition]
    func callTool(name: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolCallResult
    func shutdown() async
}

/// 把字符串中的 `$VAR` / `${VAR}` 引用替换为环境变量值（未命中保持原样）。
/// 用于把 MCP server 配置里的 `${API_KEY}` 在发送请求时展开为真实密钥。
func expandMCPVars(_ input: String, in env: [String: String]) -> String {
    guard input.contains("$"), !env.isEmpty else { return input }
    var result = input
    for (key, value) in env {
        result = result.replacingOccurrences(of: "${}\(key)", with: value)
        result = result.replacingOccurrences(of: "$\(key)", with: value)
    }
    return result
}

/// 解析 env 表：server.envVars 优先，未命中的 key 回退全局「环境变量」设置（EnvVarStore）。
func resolveMCPEnv(for server: MCPServerConfig) -> [String: String] {
    var merged = server.envVars
    for v in SettingsStore.shared.settings.envvars where !v.key.isEmpty {
        if merged[v.key] == nil { merged[v.key] = v.value }
    }
    return merged
}

struct MCPJSONRPCRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int?
    let method: String
    let params: MCPJSONValue?
}

struct MCPJSONRPCResponse: Decodable, Sendable {
    let jsonrpc: String?
    let id: MCPJSONValue?
    let result: MCPJSONValue?
    let error: RPCError?

    struct RPCError: Decodable, Sendable {
        let code: Int
        let message: String
    }
}
