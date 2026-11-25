import Foundation
import Security

/**
 SK-L1: the visitor session token (and the push token) are credentials — they belong in the
 Keychain, not UserDefaults. Minimal generic-password wrapper with no third-party dependency.

 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable after the device's first
 unlock (a chat SDK must work behind a lock screen), never synced to iCloud or migrated to
 another device, and wiped with an app uninstall.
 */
final class KeychainStore: Sendable {

    private let service: String

    init(service: String = "id.nara.livechat.sdk") {
        self.service = service
    }

    func string(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, key: String) {
        guard let value else { remove(key); return }
        let data = Data(value.utf8)
        let query = baseQuery(key)
        // Update in place; add on first write (with the accessibility class attached).
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    /// Wipes every item of this service (test isolation; uninstall does this for real).
    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
