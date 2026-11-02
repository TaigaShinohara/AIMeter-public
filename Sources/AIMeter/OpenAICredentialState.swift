import Foundation
import Security

/// Editing a key is separate from committing it to Keychain. Callers may use
/// only committedValue for authenticated requests, and may clear a legacy
/// preference only after load/save returns true.
struct OpenAICredentialState {
    var draft = ""
    private(set) var committedValue: String?
    private(set) var error: String?
    private(set) var isLoaded = false

    private let operations: KeychainHelper.Operations
    private static let key = CredentialMaintenance.account

    init(operations: KeychainHelper.Operations = .live) {
        self.operations = operations
    }

    /// A failed read is not absence and cannot authorize overwriting the item.
    /// The returned Bool authorizes clearing the caller's legacy preference.
    @discardableResult
    mutating func load(legacyValue: String) -> Bool {
        isLoaded = true
        committedValue = nil
        draft = legacyValue
        error = nil

        let restored = CredentialMaintenance.restore(legacyValue: legacyValue, operations: operations)
        if let value = restored.value {
            committedValue = value
            draft = value
        }
        if restored.result.status.isFailure { error = restored.result.status.message }
        return restored.result.canClearLegacy
    }

    /// Do not replace the usable key until the intended save/delete succeeds.
    /// A failed mutation also keeps the draft so the user can retry explicitly.
    @discardableResult
    mutating func save() -> Bool {
        // Like a denied load, an explicit failed save should not be followed by
        // an automatic background load that erases its draft or error.
        isLoaded = true
        guard draft.isEmpty || CredentialMaintenance.isUsable(draft) else {
            error = "APIキーの形式を確認できませんでした。入力内容は未保存です。"
            return false
        }
        guard KeychainHelper.save(key: Self.key, value: draft, operations: operations) else {
            error = "APIキーを保存できませんでした。入力内容は未保存です。以前に保存できたキーは変更していません。"
            return false
        }
        if !draft.isEmpty && !CredentialMaintenance.verifiesStoredValue(draft, operations: operations) {
            // A successful write followed by an unreadable/mismatching read is
            // only a partial result, so no newly written value becomes usable.
            committedValue = nil
            error = "APIキーの保存結果を確認できませんでした。再試行してください。"
            return false
        }
        committedValue = draft.isEmpty ? nil : draft
        error = nil
        return true
    }

    /// The monitor must revoke network permits before either explicit action.
    /// Neither action enables the integration nor retains a key for requests.
    mutating func migrateLegacy(legacyValue: String) -> CredentialMaintenance.Result {
        forget()
        return CredentialMaintenance.migrateLegacy(legacyValue: legacyValue, operations: operations)
    }

    mutating func deleteStored() -> CredentialMaintenance.Result {
        forget()
        // Do not let the next enabled timer silently restore/re-migrate a key
        // after this explicit deletion, including a partial two-store failure.
        // An explicit reload or later enable transition can check storage again.
        isLoaded = true
        return CredentialMaintenance.deleteStored(operations: operations)
    }

    /// Disabling the integration discards in-memory credential state without
    /// reading, updating or deleting anything from Keychain.
    mutating func forget() {
        draft = ""
        committedValue = nil
        error = nil
        isLoaded = false
    }
}
