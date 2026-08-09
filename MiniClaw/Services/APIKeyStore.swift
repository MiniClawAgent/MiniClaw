import Foundation
import Security

// MARK: - API Key 凭证存储（iOS Keychain）

/// 把各 LLM 服务商的 API Key 存入 iOS Keychain，避免明文落盘到 providers.json（spec 9.2 / 9.5 / 12.2）。
/// - 检索键：以 `provider.id.uuidString` 作为 kSecAttrAccount，按服务商唯一隔离。
/// - 可访问性：`kSecAttrAccessibleAfterFirstUnlock`——随加密备份恢复，但不跨设备同步，
///   适合非后台刷新型 App（密钥在首次解锁后可用，满足聊天调用场景）。
enum APIKeyStore {
    private static let service = "com.neartop.miniclaw.providerkey"

    /// 保存 / 更新某服务商的 API Key。已存在则更新，否则新增。
    static func saveKey(_ key: String, for providerId: UUID) {
        let account = providerId.uuidString
        let data = Data(key.utf8)
        guard !data.isEmpty else { deleteKey(for: providerId); return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// 读取某服务商的 API Key；不存在或损坏时返回 nil。
    static func getKey(for providerId: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// 删除某服务商的 API Key（删除服务商时调用）。
    static func deleteKey(for providerId: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 是否存在某服务商的 API Key（不读取明文）。
    static func hasKey(for providerId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId.uuidString,
            kSecReturnData as String: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
