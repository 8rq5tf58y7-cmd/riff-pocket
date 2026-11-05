import Foundation
import Security

/// Plaud token, API keys and Riffado key live here — never in UserDefaults.
enum Keychain {
    private static let service = "RiffPocket"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ data: Data, for key: String) {
        SecItemDelete(base(key) as CFDictionary)
        var add = base(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func data(_ key: String) -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func string(_ key: String) -> String? {
        data(key).map { String(decoding: $0, as: UTF8.self) }
    }

    static func setString(_ value: String?, for key: String) {
        if let v = value, !v.isEmpty { set(Data(v.utf8), for: key) } else { delete(key) }
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}
