import Foundation

struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var endpointURL: String
    var transport: MCPTransport
    var isEnabled: Bool
    var hasBearerToken: Bool
    /// 自定义请求头（如 X-API-Key）。随每次请求发送；协议保留头由系统托管，此处设置会被忽略。
    /// 值支持 `${VAR}` / `$VAR` 展开（见 envVars / 全局环境变量）。
    var customHeaders: [String: String]
    /// 环境变量密钥（如 API_KEY）。仅在本地配置；发送请求时展开进 URL 与自定义请求头。
    /// 建议机密写在全局「环境变量」里，本字段只放 `${VAR}` 引用，避免明文落盘。
    var envVars: [String: String]
    /// STDIO 传输启动命令（仅 transport == .stdio 时生效）。
    var command: String
    /// STDIO 传输启动参数（空格分隔；展开 ${VAR} 后按空白切分）。
    var args: String
    var lastStatus: MCPServerStatus
    var lastError: String?
    var lastToolCount: Int
    var lastCheckedAt: Date?
    /// 来源插件（manifest.id）：由 mcp 配置包导入的 server 记录来源，
    /// 删除该插件时连带删除其导入的 server；手动添加的为 nil。
    var sourcePlugin: String? = nil
    /// 认证需求（唐唐 2026-09-01：mcp 插件必须声明认证方式）：
    /// servers.json 条目的 auth 字段（"oauth"）导入时落到此标记；
    /// true 时列表显示「认证」按钮，走 MCP OAuth 2.1 授权流程。
    var requiresAuthorization: Bool? = false

    init(
        id: UUID = UUID(),
        name: String,
        endpointURL: String,
        transport: MCPTransport = .auto,
        isEnabled: Bool = true,
        hasBearerToken: Bool = false,
        customHeaders: [String: String] = [:],
        envVars: [String: String] = [:],
        command: String = "",
        args: String = "",
        lastStatus: MCPServerStatus = .unknown,
        lastError: String? = nil,
        lastToolCount: Int = 0,
        lastCheckedAt: Date? = nil,
        requiresAuthorization: Bool? = false
    ) {
        self.id = id
        self.name = name
        self.endpointURL = endpointURL
        self.transport = transport
        self.isEnabled = isEnabled
        self.hasBearerToken = hasBearerToken
        self.customHeaders = customHeaders
        self.envVars = envVars
        self.command = command
        self.args = args
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.lastToolCount = lastToolCount
        self.lastCheckedAt = lastCheckedAt
        self.requiresAuthorization = requiresAuthorization
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpointURL, transport, isEnabled, hasBearerToken, customHeaders
        case envVars, command, args
        case lastStatus, lastError, lastToolCount, lastCheckedAt, sourcePlugin
        case requiresAuthorization
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "MCP Server"
        endpointURL = try values.decodeIfPresent(String.self, forKey: .endpointURL) ?? ""
        transport = try values.decodeIfPresent(MCPTransport.self, forKey: .transport) ?? .auto
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        hasBearerToken = try values.decodeIfPresent(Bool.self, forKey: .hasBearerToken) ?? false
        customHeaders = try values.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        envVars = try values.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try values.decodeIfPresent(String.self, forKey: .args) ?? ""
        lastStatus = try values.decodeIfPresent(MCPServerStatus.self, forKey: .lastStatus) ?? .unknown
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        lastToolCount = try values.decodeIfPresent(Int.self, forKey: .lastToolCount) ?? 0
        lastCheckedAt = try values.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        sourcePlugin = try values.decodeIfPresent(String.self, forKey: .sourcePlugin)
        requiresAuthorization = try values.decodeIfPresent(Bool.self, forKey: .requiresAuthorization) ?? false
    }
}

enum MCPTransport: String, Codable, CaseIterable, Sendable {
    case auto
    case http
    case legacySSE
    case stdio
}

enum MCPServerStatus: String, Codable, Sendable {
    case unknown
    case connecting
    case connected
    case failed
}

/// 环境变量
