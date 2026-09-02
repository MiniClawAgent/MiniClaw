import AuthenticationServices
import CryptoKit
import Foundation
import MiniClawKit
import Network
import SwiftUI

// MARK: - MCP OAuth 2.1（RFC 6749 授权码流 + PKCE 7636 + 动态客户端注册 7591 + 受保护资源发现 9728 + resource indicator 8707）
//
// 授权页用 **ASWebAuthenticationSession**（系统 Safari 会话，App 内 WebKit 方案已废弃——
// 2026-09-02 唐唐拍板：iOS 审核不允许 OAuth 走 WebView）。redirect 保持 loopback
// http://127.0.0.1:18231/callback（ARDOT 实测自定义 scheme 会被授权服务器 400）：
// ASWebAuthenticationSession 不拦截 http 回调，由 **本地 NWListener 监听**接收授权码，
// 收到后主动 cancel 会话。DCR/PKCE/resource/token 交换与 WebView 时代完全一致。
//
// 流程：连接/刷新收到 401 → 标记 requiresAuthorization → 列表显示「认证」按钮 →
// 发现授权服务器 → 动态注册客户端 → PKCE 授权码流（系统 Safari 会话）→
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
    /// RFC 8707 resource indicator（refresh 时须携带与 authorize 相同的值）。
    var resource: String?
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
    case loopbackFailure
    case sessionStartFailed

    var errorDescription: String? {
        switch self {
        case .userCancelled: L10n.l("mcp_oauth_user_cancelled")
        case .missingMetadata: L10n.l("mcp_oauth_missing_metadata")
        case .http(let code, let body): L10n.l("mcp_oauth_http_error") + " (\(code)) \(body.prefix(160))"
        case .noAuthorizationCode: L10n.l("mcp_oauth_no_code")
        case .stateMismatch: L10n.l("mcp_oauth_state_mismatch")
        case .loopbackFailure: L10n.l("mcp_oauth_loopback_failure")
        case .sessionStartFailed: L10n.l("mcp_oauth_session_start_failed")
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
final class MCPOAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPOAuthManager()

    /// 授权会话进行中（设置页据此显示加载态并禁用「认证」按钮）。
    @Published var isAuthorizing = false
    /// 进行中授权的 server（加载态显示在该 server 行）。
    @Published private(set) var pendingServerID: UUID?
    /// 已完成授权的 server（便于 UI 即时刷新状态）。
    @Published var authorizedServerIDs: Set<UUID> = []

    /// ASWebAuthenticationSession 必须被强持有——局部变量会被 ARC 释放导致
    /// 授权弹窗一闪即逝（ASWebAuthenticationSession 经典坑）。
    private var authSession: ASWebAuthenticationSession?
    /// loopback 回调监听（OAuth redirect 是 http://127.0.0.1:18231/callback，
    /// 系统会话不拦截 http 回调，由本地监听接收授权码）。
    private var loopbackListener: NWListener?

    private var stateValue = ""
    private var codeVerifier = ""
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

    override private init() {}

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
        //    元数据里的 resource 字段（RFC 8707 resource indicator）须保留——
        //    authorize/token 必带（ARDOT 实测缺失时 authorize 400 {"error":"invalid_target"}）。
        var serverMeta: MCPOAuthAuthorizationServerMetadata?
        var resourceMeta: MCPOAuthProtectedResourceMetadata?
        if let meta = await discoverProtectedResource(base) {
            resourceMeta = meta
            AppLogger.shared.info("[MCP-OAuth] 受保护资源发现成功, resource=\(meta.resource ?? "无"), 授权服务器: \(meta.authorizationServers ?? [])")
            for asURL in meta.authorizationServers ?? [] {
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
        // RFC 8707 resource indicator（MCP 规范要求）：优先用受保护资源元数据声明的
        // resource，缺省用 MCP server URL（去 query/fragment）。authorize/token 均须携带。
        let resource = resourceIndicator(resourceMeta?.resource ?? base)

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
            URLQueryItem(name: "resource", value: resource),
        ]
        if let scope, !scope.isEmpty { query.append(URLQueryItem(name: "scope", value: scope)) }
        // OAuth 2.1：authorize 请求不得携带 client_secret（secret 只用于 token 端点）。
        comps.queryItems = query
        guard let authorizeURL = comps.url else { throw MCPOAuthError.missingMetadata }
        AppLogger.shared.info("[MCP-OAuth] 授权页 URL: \(authorizeURL.absoluteString)")

        // 4. 系统 Safari 授权会话（ASWebAuthenticationSession），等待 loopback 监听捕获授权码。
        let code = try await waitForAuthorizationCode(
            serverID: server.id,
            authorizeURL: authorizeURL
        )

        // 5. code 换 token（resource 参数与 authorize 一致，RFC 8707）。
        let tokens = try await exchangeCode(
            code: code,
            meta: meta,
            clientID: clientID,
            clientSecret: clientSecret,
            codeVerifier: pkce.verifier,
            resource: resource
        )
        MCPOAuthTokenStore.save(tokens, for: server.id)
        authorizedServerIDs.insert(server.id)
        // token 变化即失效该 server 的客户端缓存：MCPClientManager 按 serverId 缓存
        // 且 bearerToken 创建时固化，不清缓存则后续请求仍用空/旧 token（401 复发）。
        Task { await MCPClientManager.shared.invalidate(serverId: server.id) }
        AppLogger.shared.info("[MCP-OAuth] \(server.name): 授权完成, token 已入 Keychain")
    }

    // MARK: 授权会话（ASWebAuthenticationSession + loopback 监听）

    /// 拉起系统授权会话并等待授权码。两条捕获路径：
    /// ① 主路径——本地 NWListener 收到 http://127.0.0.1:18231/callback 请求；
    /// ② 兜底——系统会话 completion 返回匹配 loopback 的回调 URL。
    private func waitForAuthorizationCode(
        serverID: UUID,
        authorizeURL: URL
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            codeContinuation = cont
            pendingServerID = serverID
            isAuthorizing = true
            do {
                try startLoopbackListener()
            } catch {
                codeContinuation = nil
                pendingServerID = nil
                isAuthorizing = false
                cont.resume(throwing: MCPOAuthError.loopbackFailure)
                return
            }
            startAuthSession(url: authorizeURL)
        }
    }

    private func startAuthSession(url: URL) {
        // callbackURLScheme 传 "http"：系统若支持按 scheme 拦截则作兜底路径；
        // 正常路径是浏览器真实导航到 loopback → 本地监听收码 → 这里主动 cancel。
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: Self.redirectScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in self?.sessionDidFinish(callbackURL: callbackURL, error: error) }
        }
        session.presentationContextProvider = self
        // 共享 Safari 登录态：服务商侧已登录时再次授权免重复验证（非无痕）。
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() {
            finishFlow(.failure(MCPOAuthError.sessionStartFailed))
        }
    }

    private func sessionDidFinish(callbackURL: URL?, error: Error?) {
        // loopback 命中（系统拦截兜底路径）。
        if let url = callbackURL,
           url.host == Self.redirectHost, url.port == Self.redirectPort, url.path == "/callback" {
            AppLogger.shared.info("[MCP-OAuth] 会话回调命中 loopback: \(url.absoluteString)")
            handleRedirect(url)
            return
        }
        if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
            finishFlow(.failure(MCPOAuthError.userCancelled))
            return
        }
        if let error {
            finishFlow(.failure(MCPOAuthError.http(0, error.localizedDescription)))
            return
        }
        // 其它情况（监听路径已完成收尾）——幂等忽略。
    }

    /// 收尾：回传/抛出结果并释放会话与监听（幂等，continuation 只 resume 一次）。
    private func finishFlow(_ result: Result<URL, Error>) {
        isAuthorizing = false
        pendingServerID = nil
        if let cont = codeContinuation {
            codeContinuation = nil
            cont.resume(with: result)
        }
        authSession?.cancel()
        authSession = nil
        loopbackListener?.cancel()
        loopbackListener = nil
    }

    /// 本地 loopback 监听：绑定 127.0.0.1:18231，接收浏览器授权完成后的真实导航。
    private func startLoopbackListener() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: UInt16(Self.redirectPort)) else {
            throw MCPOAuthError.loopbackFailure
        }
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handleLoopbackConnection(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in self?.finishFlow(.failure(MCPOAuthError.loopbackFailure)) }
            }
        }
        listener.start(queue: DispatchQueue(label: "mcp-oauth-loopback", qos: .userInitiated))
        loopbackListener = listener
        AppLogger.shared.info("[MCP-OAuth] loopback 监听就绪: \(Self.redirectURI)")
    }

    private func handleLoopbackConnection(_ connection: NWConnection) {
        // 已取到码（监听已停）后到达的残留连接直接关闭。
        guard loopbackListener != nil else { connection.cancel(); return }
        receiveLoopbackRequest(connection, accumulated: Data())
    }

    /// 累积接收直到 HTTP 头结束（\r\n\r\n），再解析请求行。
    private func receiveLoopbackRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                if let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)),
                   let requestLine = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                       .split(separator: "\r\n", omittingEmptySubsequences: true).first {
                    self.completeLoopbackRequest(connection, requestLine: String(requestLine))
                } else if error != nil || isComplete || buffer.count > 65536 {
                    connection.cancel()
                } else {
                    self.receiveLoopbackRequest(connection, accumulated: buffer)
                }
            }
        }
    }

    /// 解析 "GET /callback?code=... HTTP/1.1"，回一个本地完成页并交给 handleRedirect 校验。
    private func completeLoopbackRequest(_ connection: NWConnection, requestLine: String) {
        let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        AppLogger.shared.info("[MCP-OAuth] loopback 请求: \(requestLine.prefix(120))")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1"></head>\
        <body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:80px">\
        <h2>\(L10n.l("mcp_oauth_loopback_done"))</h2></body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
        guard target.hasPrefix("/callback?") else { return } // 非回调请求（如探活）忽略，继续监听
        loopbackListener?.cancel()
        loopbackListener = nil
        if let url = URL(string: "http://127.0.0.1:\(Self.redirectPort)\(target)") {
            handleRedirect(url)
        } else {
            finishFlow(.failure(MCPOAuthError.noAuthorizationCode))
        }
    }

    /// loopback/系统回调捕获到 redirect 后调用：校验 state/error/code 并回传授权码。
    private func handleRedirect(_ url: URL) {
        AppLogger.shared.info("[MCP-OAuth] redirect 捕获: \(url.absoluteString)")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            finishFlow(.failure(MCPOAuthError.noAuthorizationCode))
            return
        }
        let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
        guard state == stateValue else {
            finishFlow(.failure(MCPOAuthError.stateMismatch))
            return
        }
        if let error = comps.queryItems?.first(where: { $0.name == "error" })?.value {
            finishFlow(.failure(MCPOAuthError.http(0, error)))
            return
        }
        guard comps.queryItems?.first(where: { $0.name == "code" })?.value != nil else {
            finishFlow(.failure(MCPOAuthError.noAuthorizationCode))
            return
        }
        // 完整 URL 交给等待方（内含 code/state）。
        finishFlow(.success(url))
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
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
        ] + (tokens.resource.map { [("resource", $0)] } ?? [])).data(using: .utf8)
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
        // token 轮换 → 同步失效客户端缓存（同 startAuthorization，防旧 client 带旧 token）。
        Task { await MCPClientManager.shared.invalidate(serverId: serverID) }
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
        codeVerifier: String,
        resource: String
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
            "resource": resource,
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
            scope: decoded.scope,
            resource: resource
        )
        return tokens
    }

    /// RFC 8707：resource indicator 为绝对 URI，去除 query/fragment。
    private func resourceIndicator(_ url: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        comps.query = nil
        comps.fragment = nil
        return comps.string ?? url
    }

    private func urlEncode(_ pairs: [(String, String)]) -> String {
        pairs
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&")
    }
}

