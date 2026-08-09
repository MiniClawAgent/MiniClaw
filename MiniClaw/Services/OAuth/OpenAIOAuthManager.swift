import Foundation
import UIKit
import SafariServices
import CryptoKit
import os.log

private let logger = Logger(subsystem: "com.neartop.miniclaw", category: "OpenAIOAuth")

/// OpenAI OAuth implementation using PKCE flow.
@MainActor
final class OpenAIOAuthManager: NSObject, OAuthManager, ObservableObject {

    static let shared = OpenAIOAuthManager()

    // MARK: - OAuth Config

    let providerType = "openai"
    private let authURL = "https://auth.openai.com/oauth/authorize"
    private let tokenURL = "https://auth.openai.com/oauth/token"
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let callbackPort: UInt16 = 1455
    private var redirectURI: String { "http://localhost:\(callbackPort)/auth/callback" }
    private let scopes = "openid profile email offline_access"

    private let refreshBuffer: TimeInterval = 5 * 60

    // MARK: - Published State

    @Published private(set) var isAuthenticating = false

    // MARK: - Private

    private var callbackServer: OAuthCallbackServer?
    private weak var safariVC: SFSafariViewController?
    private let refreshSingleFlight = OAuthRefreshSingleFlight<OAuthTokens>()
    private let storage: OAuthTokenStorage

    init(storage: OAuthTokenStorage = OAuthKeychainStorage.shared) {
        self.storage = storage
        super.init()
    }

    // MARK: - OAuthManager

    func validAccessToken(instanceId: String) async throws -> String {
        guard var tokens = try await storage.loadToken(instanceId: instanceId) else {
            throw OAuthError.notAuthenticated("OpenAI: no token for instance \(instanceId)")
        }

        if let refreshToken = tokens.refreshToken, tokens.isExpired {
            tokens = try await refreshSingleFlight.run(instanceId: instanceId) { [weak self] in
                guard let self else { throw OAuthError.serverError("Manager deallocated") }
                return try await self.performRefresh(refreshToken: refreshToken, instanceId: instanceId)
            }
        }

        guard !tokens.accessToken.isEmpty else {
            throw OAuthError.tokenInvalid("OpenAI: access token empty for instance \(instanceId)")
        }
        return tokens.accessToken
    }

    func refreshIfNeeded(instanceId: String) async throws {
        guard var tokens = try await storage.loadToken(instanceId: instanceId) else {
            throw OAuthError.notAuthenticated("OpenAI: no token for instance \(instanceId)")
        }

        if let refreshToken = tokens.refreshToken, tokens.isExpired {
            tokens = try await refreshSingleFlight.run(instanceId: instanceId) { [weak self] in
                guard let self else { throw OAuthError.serverError("Manager deallocated") }
                return try await self.performRefresh(refreshToken: refreshToken, instanceId: instanceId)
            }
        }
    }

    func startOAuthFlow(instanceId: String) async throws -> OAuthTokens {
        logger.info("=== OpenAI OAuth login started ===")
        callbackServer?.stop()
        callbackServer = nil
        isAuthenticating = true
        defer {
            isAuthenticating = false
            callbackServer?.stop()
            callbackServer = nil
            safariVC?.dismiss(animated: true)
            safariVC = nil
        }

        let (verifier, challenge) = Self.generatePKCE()
        let state = Self.generateState()

        // 1. Start local HTTP server
        let server = OAuthCallbackServer(port: callbackPort, callbackPath: "/auth/callback")
        self.callbackServer = server
        try server.start()

        // 2. Build authorization URL
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        let authorizationURL = components.url!

        // 3. Open in-app Safari
        presentSafariViewController(url: authorizationURL)

        // 4. Wait for callback
        let result = try await server.waitForCallback(timeout: 300)

        // 5. Validate state
        guard result.state == state else {
            throw OAuthError.stateMismatch
        }

        // 6. Exchange code for token
        let tokens = try await exchangeCode(result.code, verifier: verifier)

        // 7. Persist（按服务商实例隔离存储，instanceId = provider.id）
        try await storage.saveToken(tokens, instanceId: instanceId)

        logger.info("=== OpenAI OAuth login complete ===")
        return tokens
    }

    func handleCallback(url: URL) async throws {
        throw OAuthError.invalidCallback("Use startOAuthFlow instead")
    }

    func logout(instanceId: String) async throws {
        logger.info("Logout — clearing token (instance: \(instanceId))")
        try await storage.deleteToken(instanceId: instanceId)
    }

    // MARK: - Token Refresh

    private func performRefresh(refreshToken: String, instanceId: String) async throws -> OAuthTokens {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
            "scope": scopes,
        ]

        var tokens = try await postTokenRequest(body: body, context: "Token refresh")
        if tokens.refreshToken == nil {
            tokens.refreshToken = refreshToken
        }
        try await storage.saveToken(tokens, instanceId: instanceId)
        return tokens
    }

    // MARK: - Token Exchange

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthTokens {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]

        return try await postTokenRequest(body: body, context: "Token exchange")
    }

    private func postTokenRequest(body: [String: String], context: String) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData

        logger.info("\(context) POST \(self.tokenURL)")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"

        logger.info("\(context) Response status: \(statusCode)")

        guard (200..<300).contains(statusCode) else {
            logger.error("\(context) FAILED — status \(statusCode)")
            throw OAuthError.networkError("\(context) failed with status \(statusCode): \(responseBody)")
        }

        return try parseTokenResponse(data)
    }

    private func parseTokenResponse(_ data: Data) throws -> OAuthTokens {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let accessToken = json["access_token"] as? String else {
            throw OAuthError.serverError("Missing access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? TimeInterval
        let expiresAt = expiresIn.map { Date().addingTimeInterval($0) }

        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            tokenType: json["token_type"] as? String ?? "Bearer"
        )
    }

    // MARK: - PKCE

    private static func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()

        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hash).base64URLEncoded()

        return (verifier, challenge)
    }

    private static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    // MARK: - In-App Safari

    private func presentSafariViewController(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController { topVC = presented }
        let vc = SFSafariViewController(url: url)
        topVC.present(vc, animated: true)
        self.safariVC = vc
    }
}

// MARK: - Helpers

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
