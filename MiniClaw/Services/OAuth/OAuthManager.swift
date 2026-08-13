import Foundation

// MARK: - OAuth 令牌 Storage Protocol

/// Protocol for persisting OAuth tokens per provider instance.
/// Each provider implements its own storage backed by Keychain.
protocol OAuthTokenStorage: Sendable {
    func loadToken(instanceId: String) async throws -> OAuthTokens?
    func saveToken(_ tokens: OAuthTokens, instanceId: String) async throws
    func deleteToken(instanceId: String) async throws
}

// MARK: - OAuth Tokens Data Model

/// Unified OAuth 令牌 representation shared across all providers.
struct OAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenType: String

    /// True when the token is within 5 minutes of expiry (or already expired).
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-300)
    }
}

// MARK: - OAuth Manager Protocol

/// Protocol that every provider-specific OAuth manager must conform to.
/// Isolated to MainActor for thread-safe state management.
@MainActor
protocol OAuthManager: AnyObject {
    var providerType: String { get }
    func validAccessToken(instanceId: String) async throws -> String
    func refreshIfNeeded(instanceId: String) async throws
    func startOAuthFlow(instanceId: String) async throws -> OAuthTokens
    func handleCallback(url: URL) async throws
    func logout(instanceId: String) async throws
}

// MARK: - OAuth Error Types

enum OAuthError: LocalizedError, Sendable {
    case notAuthenticated(String)
    case tokenExpired(String)
    case refreshFailed(String)
    case invalidCallback(String)
    case networkError(String)
    case tokenInvalid(String)
    case stateMismatch
    case callbackTimeout
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let detail): return String(format: L10n.l("oauth_not_authenticated"), detail)
        case .tokenExpired(let detail): return String(format: L10n.l("oauth_token_expired"), detail)
        case .refreshFailed(let detail): return String(format: L10n.l("oauth_refresh_failed"), detail)
        case .invalidCallback(let detail): return String(format: L10n.l("oauth_invalid_callback"), detail)
        case .networkError(let detail): return String(format: L10n.l("oauth_network_error"), detail)
        case .tokenInvalid(let detail): return String(format: L10n.l("oauth_token_invalid"), detail)
        case .stateMismatch: return L10n.l("oauth_state_mismatch")
        case .callbackTimeout: return L10n.l("oauth_callback_timeout")
        case .serverError(let detail): return String(format: L10n.l("oauth_server_error"), detail)
        }
    }
}
