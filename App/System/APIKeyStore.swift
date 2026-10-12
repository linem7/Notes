import Foundation
import Security

/// API key 存在 Keychain 里：每个 Connection 一条通用密码，service 是 `com.linem7.Notes.apikey`，
/// account 是 Connection ID（ARCHITECTURE §9）。第一次读取后缓存在内存里。
/// 和 Chatbot 不同，这里不绑定 MainActor：Organize 的配置闭包是 `@Sendable` 的，要能在任意线程读 key；缓存用锁保护。
final class APIKeyStore: @unchecked Sendable {
    private static let service = "com.linem7.Notes.apikey"
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func apiKey(for connectionID: UUID) throws(KeychainError) -> String? {
        let account = connectionID.uuidString
        if let cached = lock.withLock({ cache[account] }) { return cached }

        var query = Self.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        lock.withLock { cache[account] = key }
        return key
    }

    func setAPIKey(_ key: String, for connectionID: UUID) throws(KeychainError) {
        let account = connectionID.uuidString
        let query = Self.baseQuery(account: account)
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        lock.withLock { cache[account] = key }
    }

    func deleteAPIKey(for connectionID: UUID) throws(KeychainError) {
        let account = connectionID.uuidString
        let status = SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        lock.withLock { cache[account] = nil }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainError: Error {
    let status: OSStatus
}
