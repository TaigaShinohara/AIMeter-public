import Foundation
import Security
#if !AIMETER_SECURITY_PROBE
import AIMeterCore
#endif

// Security operations are injectable so tests never touch the user's Keychain.
enum KeychainHelper {
    static var service: String { (try? DistributionConfiguration.current().keychainService) ?? "" }

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
        let service = Self.service
        guard !service.isEmpty else { return false }
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

    /// Migration may create an absent item, but must not overwrite a saved item
    /// that appeared after the caller's read. Duplicate-item failures retain the
    /// older source so the caller can retry without losing either value.
    @discardableResult
    static func addIfAbsent(key: String, value: String, operations: Operations = .live) -> Bool {
        let service = Self.service
        guard !service.isEmpty else { return false }
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = operations.add(query)
        guard status == errSecSuccess else {
            print("[AIMeter] Keychain migration SecItemAdd failed with OSStatus \(status)")
            return false
        }
        return true
    }

    /// The caller may clear legacy preferences only after a successful read/save.
    static func restore(key: String, legacyValue: String, operations: Operations = .live)
        -> (value: String?, canClearLegacy: Bool) {
        guard !service.isEmpty else { return (nil, false) }
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
        guard addIfAbsent(key: key, value: legacyValue, operations: operations) else {
            return (legacyValue, false)
        }
        let (confirmedStatus, confirmedData) = read(key: key, operations: operations)
        return (legacyValue, confirmedStatus == errSecSuccess && confirmedData == Data(legacyValue.utf8))
    }

    static func load(key: String, operations: Operations = .live) -> String? {
        let (status, data) = read(key: key, operations: operations)
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Keep the same query for callers that must distinguish absence from a
    // locked, denied or malformed saved item before deciding to migrate.
    static func read(key: String, operations: Operations) -> (OSStatus, Data?) {
        let service = Self.service
        guard !service.isEmpty else { return (errSecParam, nil) }
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
