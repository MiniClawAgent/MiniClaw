import Foundation
import Security

/// Keychain-backed storage for OAuth tokens.
/// Each instanceId gets its own Keychain entry with a unique service name.
final class OAuthKeychainStorage: OAuthTokenStorage, @unchecked Sendable {

    static let shared = OAuthKeychainStorage()

    private init() {}

    // MARK: - Public API

    func loadToken(instanceId: String) async throws -> OAuthTokens? {
        // Keychain 读取本身是同步线程安全的，直接复用同步实现。
        Self.loadTokenSync(instanceId: instanceId)
    }

    /// 同步读取（仅 Keychain，无网络）：供同步路径（如端点解析兜底）使用。
    static func loadTokenSync(instanceId: String) -> OAuthTokens? {
        let service = Self.serviceName(for: instanceId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "oauth_tokens",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    func saveToken(_ tokens: OAuthTokens, instanceId: String) async throws {
        let service = Self.serviceName(for: instanceId)
        let data = try JSONEncoder().encode(tokens)

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "oauth_tokens",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "oauth_tokens",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OAuthError.serverError("Keychain write failed: \(status)")
        }
    }

    func deleteToken(instanceId: String) async throws {
        let service = Self.serviceName(for: instanceId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "oauth_tokens",
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    private static func serviceName(for instanceId: String) -> String {
        "com.neartop.miniclaw.oauth.\(instanceId)"
    }
}
