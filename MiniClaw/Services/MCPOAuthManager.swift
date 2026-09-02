import CryptoKit
import CryptoKit
import Foundation
import MiniClawKit
import SwiftUI
import WebKit

// MARK: - MCP OAuth 2.1（RFC 6749 授权码流 + PKCE 7636 + 动态客户端注册 7591 + 受保护资源发现 9728）
//
// 唐唐 2026-09-01 拍板：需要 OAuth 的 remote MCP 必须支持完整授权流程，
// 授权页使用 **App 内 WebKit**（不切系统浏览器、无需注册 URL scheme——
// redirect 在 WKWebView 导航拦截中捕获）。
//
// 流程：连接/刷新收到 401 → 标记 requiresAuthorization → 列表显示「认证」按钮 →
// 发现授权服务器（/.well-known）→ 动态注册客户端 → PKCE 授权码流（App 内 WebKit）→
// code 换 token → Keychain 存储 → 重新刷新工具。

// MARK: - 数据结构

struct MCPOAuthTokenSet: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenType: String = "Bearer"
    /// token_endpoint（刷新时直接复用，免重新发现）。
    var tokenEndpoint: String?
    /// 授权作用域。
    var scope: String?
}

struct MCPOAuthProtectedResourceMetadata: Codable {
    var resource: String?
    var authorizationServers: [String]?
    var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case resource
    }
}

struct MCPOAuthAuthorizationServerMetadata: Codable {
    var authorizationEndpoint: String
    var tokenEndpoint: String
    var registrationEndpoint: String?
    var scopesSupported: [String]?
    var codeChallengeMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
    }
}

struct MCPOAuthClientRegistrationResponse: Codable {
    var clientId: String
    var clientSecret: String?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
}

// MARK: - 错误

enum MCPOAuthError: LocalizedError {
    case userCancelled
    case missingMetadata
    case http(Int, String)
    case noAuthorizationCode
    case stateMismatch

    var errorDescription: String? {
        switch self {
        case .userCancelled: L10n.l("mcp_oauth_user_cancelled")
        case .missingMetadata: L10n.l("mcp_oauth_missing_metadata")
        case .http(let code, let body): L10n.l("mcp_oauth_http_error") + " (\(code)) \(body.prefix(160))"
        case .noAuthorizationCode: L10n.l("mcp_oauth_no_code")
        case .stateMismatch: L10n.l("mcp_oauth_state_mismatch")
        }
    }
}

/// 401（未授权）判定：MCP 连接/刷新错误是否为需要授权。
func isMCPUnauthorizedError(_ error: Error) -> Bool {
    guard let mcpError = error as? MCPClientError else { return false }
    if case .httpStatus(let code, _) = mcpError { return code == 401 }
    return false
}

// MARK: - Token Keychain 存储（JSON，按 serverId 隔离）

enum MCPOAuthTokenStore {
    static let service = "com.neartop.miniclaw.mcpoauthtoken"

    private static func baseQuery(for serverId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId.uuidString,
        ]
    }

    static func save(_ tokens: MCPOAuthTokenSet, for serverId: UUID) {
        let data = (try? JSONEncoder().encode(tokens)) ?? Data()
        guard !data.isEmpty else { return }
        let query = baseQuery(for: serverId)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load(for serverId: UUID) -> MCPOAuthTokenSet? {
        var query = baseQuery(for: serverId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(MCPOAuthTokenSet.self, from: data)
    }

    static func delete(for serverId: UUID) {
        SecItemDelete(baseQuery(for: serverId) as CFDictionary)
    }
}

// MARK: - PKCE（RFC 7636，S256）

enum MCPOAuthPKCE {
    static func generate() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(bytes)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Array(digest))
        return (verifier, challenge)
    }

    private static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - 管理器

@MainActor
final class MCPOAuthManager: ObservableObject {
    static let shared = MCPOAuthManager()

    /// 进行中的授权流程（驱动设置页 sheet 呈现 App 内 WebKit 认证页）。
    @Published var activeFlow: MCPOAuthFlowContext?
    /// 已完成授权的 server（便于 UI 即时刷新状态）。
    @Published var authorizedServerIDs: Set<UUID> = []

    private var stateValue = ""
    private var codeVerifier = ""
    private var pendingServerID: UUID?
    /// redirect 捕获 → 授权码回传给 startAuthorization 的等待方。
    private var codeContinuation: CheckedContinuation<URL, Error>?

    // loopback 回调（OAuth 2.1 for Native Apps 推荐）：App 内 WebKit 授权后
    // redirect 到 127.0.0.1，由 WebView 导航拦截捕获（导航先被取消，请求不出
    // WKWebView，因此无需真实端口监听）。自定义 scheme 会被部分企业授权服务器
    // 400（ARDOT 实测），故改用 loopback。
    static let redirectScheme = "http"
    static let redirectHost = "127.0.0.1"
    static let redirectPort = 18231
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"

    private init() {}

    // MARK: 状态查询

    func isAuthorized(serverID: UUID) -> Bool {
        MCPOAuthTokenStore.load(for: serverID) != nil
    }

    func deleteAuthorization(serverID: UUID) {
        MCPOAuthTokenStore.delete(for: serverID)
        authorizedServerIDs.remove(serverID)
    }

    // MARK: 授权主流程

    /// 对指定 server 启动完整 OAuth 授权（发现 → 注册 → PKCE 授权 → 换 token）。
    func startAuthorization(server: MCPServerConfig) async throws {
        AppLogger.shared.info("[MCP-OAuth] \(server.name): 授权流程开始 → \(server.endpointURL)")
        pendingServerID = server.id
        let base = server.endpointURL

        // 1. 受保护资源发现（RFC 9728）：优先 server 域的 well-known，
        //    失败则以 server URL 本身作为授权服务器再试。
        var serverMeta: MCPOAuthAuthorizationServerMetadata?
        if let resourceMeta = await discoverProtectedResource(base) {
            AppLogger.shared.info("[MCP-OAuth] 受保护资源发现成功, 授权服务器: \(resourceMeta.authorizationServers ?? [])")
            for asURL in resourceMeta.authorizationServers ?? [] {
                if let meta = await fetchAuthorizationServerMetadata(asURL) {
                    serverMeta = meta
                    break
                }
            }
        }
        if serverMeta == nil {
            // 回退：按 MCP 规范，授权服务器可能直接托管在同一域的 well-known 路径。
            AppLogger.shared.info("[MCP-OAuth] 受保护资源发现未命中, 回退 origin well-known 直探")
            guard let origin = originOf(base),
                  let meta = await fetchAuthorizationServerMetadata(origin)
            else {
                AppLogger.shared.error("[MCP-OAuth] 授权服务器元数据发现失败（authorize/token 端点不可知）")
                throw MCPOAuthError.missingMetadata
            }
            serverMeta = meta
        }
        guard let meta = serverMeta else { throw MCPOAuthError.missingMetadata }
        AppLogger.shared.info("[MCP-OAuth] authorize=\(meta.authorizationEndpoint) token=\(meta.tokenEndpoint) register=\(meta.registrationEndpoint ?? "无")")

        // 2. 动态客户端注册（RFC 7591）。唐唐 2026-09-02：注册失败不再静默回落
        // 硬编码 client_id——未知客户端会在授权确认时被服务器 400（ARDOT 实测）。
        var clientID: String
        var clientSecret: String?
        if let regEndpoint = meta.registrationEndpoint {
            AppLogger.shared.info("[MCP-OAuth] 动态客户端注册: \(regEndpoint)")
            guard let registration = await registerClient(
                registrationEndpoint: regEndpoint,
                serverName: server.name
            ) else {
                AppLogger.shared.error("[MCP-OAuth] 动态客户端注册失败")
                throw MCPOAuthError.missingMetadata
            }
            clientID = registration.clientId
            clientSecret = registration.clientSecret
        } else {
            AppLogger.shared.error("[MCP-OAuth] 服务器未提供动态注册端点，无法获得合法 client_id")
            throw MCPOAuthError.missingMetadata
        }

        // 3. PKCE + 授权 URL。
        let pkce = MCPOAuthPKCE.generate()
        codeVerifier = pkce.verifier
        stateValue = UUID().uuidString
        let scope = meta.scopesSupported?.joined(separator: " ")

        guard var comps = URLComponents(string: meta.authorizationEndpoint) else {
            throw MCPOAuthError.missingMetadata
        }
        var query = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: stateValue),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let scope, !scope.isEmpty { query.append(URLQueryItem(name: "scope", value: scope)) }
        // OAuth 2.1：authorize 请求不得携带 client_secret（secret 只用于 token 端点）。
        comps.queryItems = query
        guard let authorizeURL = comps.url else { throw MCPOAuthError.missingMetadata }
        AppLogger.shared.info("[MCP-OAuth] 授权页 URL: \(authorizeURL.absoluteString)")

        // 4. App 内 WebKit 认证页（sheet），等待 redirect 捕获授权码。
        pendingServerID = server.id
        let code = try await waitForAuthorizationCode(
            serverID: server.id,
            serverName: server.name,
            authorizeURL: authorizeURL
        )

        // 5. code 换 token。
        let tokens = try await exchangeCode(
            code: code,
            meta: meta,
            clientID: clientID,
            clientSecret: clientSecret,
            codeVerifier: pkce.verifier
        )
        MCPOAuthTokenStore.save(tokens, for: server.id)
        authorizedServerIDs.insert(server.id)
        pendingServerID = nil
        AppLogger.shared.info("[MCP-OAuth] \(server.name): 授权完成, token 已入 Keychain")
    }

    // MARK: 等待授权码（continuation）

    private func waitForAuthorizationCode(
        serverID: UUID,
        serverName: String,
        authorizeURL: URL
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            codeContinuation = cont
            activeFlow = MCPOAuthFlowContext(
                serverID: serverID,
                serverName: serverName,
                authorizeURL: authorizeURL,
                onCode: { [weak self] url in
                    self?.codeContinuation?.resume(returning: url)
                    self?.codeContinuation = nil
                    self?.activeFlow = nil
                },
                onCancel: { [weak self] in
                    self?.codeContinuation?.resume(throwing: MCPOAuthError.userCancelled)
                    self?.codeContinuation = nil
                    self?.activeFlow = nil
                }
            )
        }
    }

    /// WebView 捕获到 redirect 回调时由认证页调用。
    func handleRedirect(_ url: URL) {
        AppLogger.shared.info("[MCP-OAuth] redirect 捕获: \(url.absoluteString)")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
        guard state == stateValue else {
            codeContinuation?.resume(throwing: MCPOAuthError.stateMismatch)
            codeContinuation = nil
            activeFlow = nil
            return
        }
        if let error = comps.queryItems?.first(where: { $0.name == "error" })?.value {
            codeContinuation?.resume(throwing: MCPOAuthError.http(0, error))
            codeContinuation = nil
            activeFlow = nil
            return
        }
        guard comps.queryItems?.first(where: { $0.name == "code" })?.value != nil else {
            codeContinuation?.resume(throwing: MCPOAuthError.noAuthorizationCode)
            codeContinuation = nil
            activeFlow = nil
            return
        }
        // 完整 URL 交给等待方（内含 code/state）。
        codeContinuation?.resume(returning: url)
        codeContinuation = nil
        activeFlow = nil
    }

    func cancelAuthorization() {
        codeContinuation?.resume(throwing: MCPOAuthError.userCancelled)
        codeContinuation = nil
        activeFlow = nil
    }

    // MARK: Token 刷新

    /// 用 refresh_token 换新 access_token（401 重试场景）。无可刷新凭据返回 nil。
    func refreshToken(serverID: UUID) async throws -> String? {
        guard let tokens = MCPOAuthTokenStore.load(for: serverID),
              let refreshToken = tokens.refreshToken,
              let endpoint = tokens.tokenEndpoint
        else {
            AppLogger.shared.info("[MCP-OAuth] serverID \(serverID.uuidString): 无 refresh_token，跳过刷新")
            return nil
        }
        AppLogger.shared.info("[MCP-OAuth] refresh_token 刷新开始: \(endpoint)")
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncode([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MCPOAuthError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        let refreshed = try JSONDecoder().decode(MCPOAuthTokenSet.self, from: data)
        var merged = tokens
        merged.accessToken = refreshed.accessToken
        if let rt = refreshed.refreshToken { merged.refreshToken = rt }
        merged.expiresAt = refreshed.expiresAt
        MCPOAuthTokenStore.save(merged, for: serverID)
        return merged.accessToken
    }

    // MARK: - 私有：发现 / 注册 / 交换

    private func originOf(_ url: String) -> String? {
        guard let comps = URLComponents(string: url), let scheme = comps.scheme, let host = comps.host
        else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = comps.port { origin += ":\(port)" }
        return origin
    }

    /// RFC 9728：GET <server>/.well-known/oauth-protected-resource。
    private func discoverProtectedResource(_ serverURL: String) async -> MCPOAuthProtectedResourceMetadata? {
        // 规范允许路径感知的 well-known（插入到 path 之后）——两种都试。
        let wellKnown = URL(string: serverURL)?.deletingLastPathComponent()
            .appendingPathComponent(".well-known/oauth-protected-resource")
        let fallback = originOf(serverURL).flatMap {
            URL(string: $0)?.appendingPathComponent("/.well-known/oauth-protected-resource")
        }
        let candidates: [URL] = [wellKnown, fallback].compactMap { $0 }
        for candidate in candidates {
            if let meta: MCPOAuthProtectedResourceMetadata = await getJSON(candidate) {
                return meta
            }
        }
        return nil
    }

    /// RFC 8414：GET <issuer>/.well-known/oauth-authorization-server。
    private func fetchAuthorizationServerMetadata(_ issuer: String) async -> MCPOAuthAuthorizationServerMetadata? {
        guard let base = URL(string: issuer) else { return nil }
        let candidates = [
            base.appendingPathComponent(".well-known/oauth-authorization-server"),
            base.appendingPathComponent(".well-known/openid-configuration"),
        ]
        for candidate in candidates {
            if let meta: MCPOAuthAuthorizationServerMetadata = await getJSON(candidate) {
                return meta
            }
        }
        return nil
    }

    private func getJSON<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// RFC 7591 动态客户端注册。失败返回 nil（假定客户端已预注册）。
    private func registerClient(
        registrationEndpoint: String,
        serverName: String
    ) async -> MCPOAuthClientRegistrationResponse? {
        guard let url = URL(string: registrationEndpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_name": "MiniClaw (\(serverName))",
            // 同时注册 127.0.0.1 与 localhost 两个 loopback 变体：ARDOT 的授权页 SPA
            // 实测会把 redirect_uri 从 127.0.0.1 改写为 localhost（2026-09-02 真机日志
            // 的 backForward 历史项），authorize 用哪个就按哪个校验——两个都注册才
            // 不会 invalid_redirect_uri。authorize 请求仍固定用 127.0.0.1。
            "redirect_uris": [Self.redirectURI, "http://localhost:\(Self.redirectPort)/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(MCPOAuthClientRegistrationResponse.self, from: data)
    }

    private func exchangeCode(
        code: URL,
        meta: MCPOAuthAuthorizationServerMetadata,
        clientID: String,
        clientSecret: String?,
        codeVerifier: String
    ) async throws -> MCPOAuthTokenSet {
        guard let codeParam = URLComponents(url: code, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw MCPOAuthError.noAuthorizationCode }

        var request = URLRequest(url: URL(string: meta.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncode([
            "grant_type": "authorization_code",
            "code": codeParam,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ] + (clientSecret.map { [("client_secret", $0)] } ?? [])).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code2 = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MCPOAuthError.http(code2, String(decoding: data.prefix(300), as: UTF8.self))
        }

        struct TokenResponse: Codable {
            var accessToken: String
            var refreshToken: String?
            var expiresIn: Int?
            var tokenType: String?
            var scope: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case tokenType = "token_type"
                case scope
            }
        }
        AppLogger.shared.info("[MCP-OAuth] token 交换成功 (\(http.statusCode))")
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let tokens = MCPOAuthTokenSet(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            tokenType: decoded.tokenType ?? "Bearer",
            tokenEndpoint: meta.tokenEndpoint,
            scope: decoded.scope
        )
        return tokens
    }

    private func urlEncode(_ pairs: [(String, String)]) -> String {
        pairs
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&")
    }
}

