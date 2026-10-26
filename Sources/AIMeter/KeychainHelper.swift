import Foundation
import Security

// Security operations are injectable so tests never touch the user's Keychain.
enum KeychainHelper {
    static let service = "com.local.AIMeter"

    struct Operations {
        var update: ([String: Any], [String: Any]) -> OSStatus
        var add: ([String: Any]) -> OSStatus
        var delete: ([String: Any]) -> OSStatus
        var copyMatching: ([String: Any]) -> (OSStatus, Data?)

        static let live = Operations(
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            delete: { SecItemDelete($0 as CFDictionary) },
            copyMatching: { query in
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                return (status, item as? Data)
            }
        )
    }

    @discardableResult
    static func save(key: String, value: String, operations: Operations = .live) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if value.isEmpty {
            let status = operations.delete(query)
            if status == errSecSuccess || status == errSecItemNotFound { return true }
            print("[AIMeter] Keychain SecItemDelete failed with OSStatus \(status)")
            return false
        }

        guard let data = value.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = operations.update(query, attributes)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            // An inaccessible/locked item may still exist. Never delete or replace it.
            print("[AIMeter] Keychain SecItemUpdate failed with OSStatus \(updateStatus)")
            return false
        }

        let addQuery = query.merging(attributes) { _, new in new }
        let addStatus = operations.add(addQuery)
        guard addStatus == errSecSuccess else {
            print("[AIMeter] Keychain SecItemAdd failed with OSStatus \(addStatus)")
            return false
        }
        return true
    }

    /// The caller may clear legacy preferences only after a successful read/save.
    static func restore(key: String, legacyValue: String, operations: Operations = .live)
        -> (value: String?, canClearLegacy: Bool) {
        let (status, data) = read(key: key, operations: operations)
        if status == errSecSuccess, let data,
           let saved = String(data: data, encoding: .utf8), !saved.isEmpty {
            return (saved, true)
        }
        // A locked/unreadable item is not evidence that it is absent.
        guard status == errSecItemNotFound else {
            return (legacyValue.isEmpty ? nil : legacyValue, false)
        }
        guard !legacyValue.isEmpty else { return (nil, false) }
        return (legacyValue, save(key: key, value: legacyValue, operations: operations))
    }

    static func load(key: String, operations: Operations = .live) -> String? {
        let (status, data) = read(key: key, operations: operations)
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func read(key: String, operations: Operations) -> (OSStatus, Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return operations.copyMatching(query)
    }
}
