import Foundation
import Security

/// Explicit local maintenance is independent of the service's network setting.
/// Results contain only fixed states; never a credential, fingerprint or suffix.
enum CredentialMaintenance {
    static let account = "openaiAdminKey"

    enum Status: Equatable {
        case unverified
        case nothingToMigrate
        case existingKeyVerified
        case legacyKeyVerified
        case keychainDeleted
        case existingKeyPreserved
        case migrationCompleted
        case deletionCompleted
        case readFailed
        case invalidSavedKey
        case invalidLegacyKey
        case saveFailed
        case verificationFailed
        case deleteFailed
        case legacyRemovalPending
        case legacyRemovalConfirmed

        var isFailure: Bool {
            switch self {
            case .readFailed, .invalidSavedKey, .invalidLegacyKey, .saveFailed,
                 .verificationFailed, .deleteFailed, .legacyRemovalPending:
                return true
            default: return false
            }
        }

        var isComplete: Bool {
            switch self {
            case .existingKeyPreserved, .migrationCompleted, .deletionCompleted, .legacyRemovalConfirmed: return true
            default: return false
            }
        }

        var message: String {
            switch self {
            case .unverified:
                return "保存状態は未確認です。連携をオフにしていても、下の操作で旧設定の移行や保存済みキーの削除ができます。"
            case .nothingToMigrate:
                return "移行できる旧キーは確認できませんでした。保存内容は変更していません。"
            case .existingKeyVerified:
                return "使用可能な保存済みキーを確認しました。旧設定の除去を確認しています。"
            case .legacyKeyVerified:
                return "旧キーのKeychainへの保存を確認しました。旧設定の除去を確認しています。"
            case .keychainDeleted:
                return "Keychainの削除を確認しました。旧設定の除去を確認しています。"
            case .existingKeyPreserved:
                return "保存済みのキーを維持し、旧設定を除去しました。"
            case .migrationCompleted:
                return "旧キーをKeychainへ移行し、旧設定を除去しました。"
            case .deletionCompleted:
                return "この端末のKeychainと旧設定からキーを削除しました。"
            case .readFailed:
                return "Keychainを確認できませんでした。ロック・アクセス許可を確認して再試行してください。旧設定は残しています。"
            case .invalidSavedKey:
                return "保存済みキーを使用可能な値として確認できませんでした。Keychainと旧設定は変更していません。"
            case .invalidLegacyKey:
                return "旧キーの形式を確認できませんでした。Keychainと旧設定は変更していません。"
            case .saveFailed:
                return "旧キーをKeychainへ保存できませんでした。旧設定は残しています。再試行してください。"
            case .verificationFailed:
                return "Keychainへの保存結果を確認できませんでした。旧設定は残しています。再試行してください。"
            case .deleteFailed:
                return "Keychainからキーを削除できませんでした。旧設定は残しています。ロック・アクセス許可を確認して再試行してください。"
            case .legacyRemovalPending:
                return "Keychainの操作は完了しましたが、旧設定の除去を確認できませんでした。完了していないため、もう一度操作してください。"
            case .legacyRemovalConfirmed:
                return "旧設定の除去を確認しました。"
            }
        }
    }

    struct Result: Equatable {
        let status: Status

        /// A Keychain-only success never claims both stores were changed.
        var canClearLegacy: Bool {
            switch status {
            case .existingKeyVerified, .legacyKeyVerified, .keychainDeleted: return true
            default: return false
            }
        }

        /// The owner of UserDefaults removes the property and verifies absence.
        func confirmingLegacyRemoval(_ removed: Bool) -> Result {
            guard canClearLegacy else { return self }
            guard removed else { return Result(status: .legacyRemovalPending) }
            switch status {
            case .existingKeyVerified: return Result(status: .existingKeyPreserved)
            case .legacyKeyVerified: return Result(status: .migrationCompleted)
            case .keychainDeleted: return Result(status: .deletionCompleted)
            default: return self
            }
        }
    }

    static func isUsable(_ value: String) -> Bool {
        BoundedAPIClient.isSafeBearer(value)
    }

    static func usableValue(_ data: Data?) -> String? {
        guard let data, let value = String(data: data, encoding: .utf8), isUsable(value) else { return nil }
        return value
    }

    /// The value is returned only for the normal, enabled restore boundary.
    /// Explicit maintenance discards it and never commits it for network use.
    static func restore(legacyValue: String, operations: KeychainHelper.Operations)
        -> (value: String?, result: Result) {
        let (status, data) = KeychainHelper.read(key: account, operations: operations)
        if status == errSecSuccess {
            guard let value = usableValue(data) else { return (nil, Result(status: .invalidSavedKey)) }
            return (value, Result(status: .existingKeyVerified))
        }
        guard status == errSecItemNotFound else { return (nil, Result(status: .readFailed)) }
        guard !legacyValue.isEmpty else { return (nil, Result(status: .nothingToMigrate)) }
        guard isUsable(legacyValue) else { return (nil, Result(status: .invalidLegacyKey)) }

        // Insert only: an item created concurrently must never be overwritten
        // by a value from the older plaintext store.
        guard KeychainHelper.addIfAbsent(key: account, value: legacyValue, operations: operations) else {
            return (nil, Result(status: .saveFailed))
        }
        guard verifiesStoredValue(legacyValue, operations: operations) else {
            return (nil, Result(status: .verificationFailed))
        }
        return (legacyValue, Result(status: .legacyKeyVerified))
    }

    static func migrateLegacy(legacyValue: String, operations: KeychainHelper.Operations) -> Result {
        restore(legacyValue: legacyValue, operations: operations).result
    }

    static func deleteStored(operations: KeychainHelper.Operations) -> Result {
        let removed = KeychainHelper.save(key: account, value: "", operations: operations)
        return Result(status: removed ? .keychainDeleted : .deleteFailed)
    }

    static func verifiesStoredValue(_ expected: String, operations: KeychainHelper.Operations) -> Bool {
        let (status, data) = KeychainHelper.read(key: account, operations: operations)
        return status == errSecSuccess && usableValue(data) == expected
    }
}
