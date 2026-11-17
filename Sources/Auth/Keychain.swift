import Foundation
import Security

/// Generic-password Keychain storage for tokens.
enum Keychain {
    static let service = "app.igreenlight.tokens"

    static func set(_ data: Data, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { log("Keychain", "SecItemAdd(\(account)) failed: \(status)") }
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        return status == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    static func setCodable<T: Encodable>(_ value: T, for account: String) {
        if let d = try? JSONEncoder().encode(value) { set(d, for: account) }
    }

    static func getCodable<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        guard let d = get(account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}
