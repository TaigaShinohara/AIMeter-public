import XCTest
import Security
@testable import AIMeter

final class CredentialMaintenanceTests: XCTestCase {
    private final class SyntheticDefaults {
        var legacy: String?
        var refuseRemoval = false

        init(_ value: String?) { legacy = value }

        func finish(_ result: CredentialMaintenance.Result) -> CredentialMaintenance.Result {
            guard result.canClearLegacy else { return result }
            if !refuseRemoval { legacy = nil }
            return result.confirmingLegacyRemoval(legacy == nil)
        }
    }

    private final class FakeKeychain {
        var stored: Data?
        var readFailure: OSStatus?
        var addFailure: OSStatus?
        var deleteFailure: OSStatus?
        var readResults: [(OSStatus, Data?)] = []
        var concurrentValueOnAdd: Data?
        var calls: [String] = []

        init(_ value: String? = nil) { stored = value.map { Data($0.utf8) } }

        var operations: KeychainHelper.Operations {
            .init(update: { _, _ in
                XCTFail("Legacy maintenance must never update an existing item")
                return errSecParam
            }, add: { query in
                self.checkQuery(query)
                self.calls.append("add")
                if let concurrent = self.concurrentValueOnAdd {
                    self.stored = concurrent
                    return errSecDuplicateItem
                }
                if let status = self.addFailure { return status }
                guard self.stored == nil else { return errSecDuplicateItem }
                self.stored = query[kSecValueData as String] as? Data
                XCTAssertEqual(query[kSecAttrAccessible as String] as? String,
                               kSecAttrAccessibleAfterFirstUnlock as String)
                return errSecSuccess
            }, delete: { query in
                self.checkQuery(query)
                self.calls.append("delete")
                if let status = self.deleteFailure { return status }
                guard self.stored != nil else { return errSecItemNotFound }
                self.stored = nil
                return errSecSuccess
            }, copyMatching: { query in
                self.checkQuery(query)
                self.calls.append("read")
                if !self.readResults.isEmpty { return self.readResults.removeFirst() }
                if let status = self.readFailure { return (status, nil) }
                return (self.stored == nil ? errSecItemNotFound : errSecSuccess, self.stored)
            })
        }

        private func checkQuery(_ query: [String: Any]) {
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.local.AIMeter")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "openaiAdminKey")
            XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        }
    }

    func testExistingUsableKeyIsPreservedBeforeLegacyRemovalCanComplete() {
        let keychain = FakeKeychain("synthetic-saved")
        let defaults = SyntheticDefaults("synthetic-older")
        let pending = CredentialMaintenance.migrateLegacy(legacyValue: defaults.legacy!, operations: keychain.operations)
        XCTAssertEqual(pending.status, .existingKeyVerified)
        XCTAssertTrue(pending.canClearLegacy)
        XCTAssertFalse(pending.status.isComplete)
        XCTAssertEqual(defaults.legacy, "synthetic-older")
        XCTAssertEqual(defaults.finish(pending).status, .existingKeyPreserved)
        XCTAssertNil(defaults.legacy)
        XCTAssertEqual(keychain.stored, Data("synthetic-saved".utf8))
        XCTAssertEqual(keychain.calls, ["read"])
    }

    func testMissingKeyIsInsertedAndReadBackBeforeRemovingLegacyPreference() {
        let keychain = FakeKeychain()
        let defaults = SyntheticDefaults("synthetic-legacy")
        let pending = CredentialMaintenance.migrateLegacy(legacyValue: defaults.legacy!, operations: keychain.operations)
        XCTAssertEqual(pending.status, .legacyKeyVerified)
        XCTAssertEqual(keychain.calls, ["read", "add", "read"])
        XCTAssertEqual(defaults.legacy, "synthetic-legacy")
        let completed = defaults.finish(pending)
        XCTAssertEqual(completed.status, .migrationCompleted)
        XCTAssertTrue(completed.status.isComplete)
        XCTAssertFalse(completed.canClearLegacy)
        XCTAssertNil(defaults.legacy)
    }

    func testUnreadableOrInvalidSavedItemsKeepBothStoresUnchanged() {
        let results: [(OSStatus, Data?)] = [
            (errSecInteractionNotAllowed, nil), (errSecAuthFailed, nil),
            (errSecNotAvailable, nil), (errSecSuccess, nil), (errSecSuccess, Data()),
            (errSecSuccess, Data([0xff])), (errSecSuccess, Data(" ".utf8)),
            (errSecSuccess, Data("synthetic\nheader".utf8))
        ]
        for readResult in results {
            let keychain = FakeKeychain("synthetic-existing")
            keychain.readResults = [readResult]
            let original = keychain.stored
            let defaults = SyntheticDefaults("synthetic-retained")
            let result = defaults.finish(CredentialMaintenance.migrateLegacy(
                legacyValue: defaults.legacy!, operations: keychain.operations))
            XCTAssertTrue(result.status.isFailure)
            XCTAssertFalse(result.canClearLegacy)
            XCTAssertFalse(result.status.isComplete)
            XCTAssertEqual(defaults.legacy, "synthetic-retained")
            XCTAssertEqual(keychain.stored, original)
            XCTAssertEqual(keychain.calls, ["read"])
            XCTAssertFalse(result.status.message.contains("synthetic-retained"))
        }
    }

    func testMissingItemDoesNotAuthorizeRemovalOfEmptyOrInvalidLegacyPreference() {
        for legacy in ["", " ", "synthetic\nheader", "秘密", String(repeating: "x", count: 16_385)] {
            let keychain = FakeKeychain()
            let defaults = SyntheticDefaults(legacy)
            let result = defaults.finish(CredentialMaintenance.migrateLegacy(
                legacyValue: legacy, operations: keychain.operations))
            XCTAssertFalse(result.canClearLegacy)
            XCTAssertFalse(result.status.isComplete)
            XCTAssertEqual(defaults.legacy, legacy)
            XCTAssertNil(keychain.stored)
            XCTAssertEqual(keychain.calls, ["read"])
        }
    }

    func testConcurrentRegistrationCannotBeOverwrittenByLegacyMigration() {
        let keychain = FakeKeychain()
        keychain.concurrentValueOnAdd = Data("synthetic-concurrent-current".utf8)
        let defaults = SyntheticDefaults("synthetic-old")
        let result = defaults.finish(CredentialMaintenance.migrateLegacy(
            legacyValue: defaults.legacy!, operations: keychain.operations))
        XCTAssertEqual(result.status, .saveFailed)
        XCTAssertEqual(keychain.calls, ["read", "add"])
        XCTAssertEqual(keychain.stored, Data("synthetic-concurrent-current".utf8))
        XCTAssertEqual(defaults.legacy, "synthetic-old")
    }

    func testFailedInsertionDoesNotRemoveTheOnlyLegacyCopy() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let keychain = FakeKeychain()
            keychain.addFailure = status
            let defaults = SyntheticDefaults("synthetic-retained")
            let result = defaults.finish(CredentialMaintenance.migrateLegacy(
                legacyValue: defaults.legacy!, operations: keychain.operations))
            XCTAssertEqual(result.status, .saveFailed)
            XCTAssertEqual(defaults.legacy, "synthetic-retained")
            XCTAssertNil(keychain.stored)
            XCTAssertEqual(keychain.calls, ["read", "add"])
        }
    }

    func testSavedButUnverifiedValuesArePartialResultsAndRetainLegacy() {
        let results: [(OSStatus, Data?)] = [
            (errSecInteractionNotAllowed, nil), (errSecItemNotFound, nil),
            (errSecSuccess, nil), (errSecSuccess, Data()), (errSecSuccess, Data([0xff])),
            (errSecSuccess, Data("synthetic-wrong-value".utf8))
        ]
        for readback in results {
            let keychain = FakeKeychain()
            keychain.readResults = [(errSecItemNotFound, nil), readback]
            let defaults = SyntheticDefaults("synthetic-intended")
            let result = defaults.finish(CredentialMaintenance.migrateLegacy(
                legacyValue: defaults.legacy!, operations: keychain.operations))
            XCTAssertEqual(result.status, .verificationFailed)
            XCTAssertEqual(defaults.legacy, "synthetic-intended")
            XCTAssertEqual(keychain.calls, ["read", "add", "read"])
            XCTAssertFalse(result.status.isComplete)
        }
    }

    func testPreferenceRemovalFailureIsPartialAndCanBeRetriedWithoutOverwritingKey() {
        let keychain = FakeKeychain()
        let defaults = SyntheticDefaults("synthetic-legacy")
        defaults.refuseRemoval = true
        let incomplete = defaults.finish(CredentialMaintenance.migrateLegacy(
            legacyValue: defaults.legacy!, operations: keychain.operations))
        XCTAssertEqual(incomplete.status, .legacyRemovalPending)
        XCTAssertTrue(incomplete.status.isFailure)
        XCTAssertFalse(incomplete.status.isComplete)
        XCTAssertEqual(defaults.legacy, "synthetic-legacy")
        XCTAssertEqual(keychain.stored, Data("synthetic-legacy".utf8))
        defaults.refuseRemoval = false
        let retried = defaults.finish(CredentialMaintenance.migrateLegacy(
            legacyValue: defaults.legacy!, operations: keychain.operations))
        XCTAssertEqual(retried.status, .existingKeyPreserved)
        XCTAssertTrue(retried.status.isComplete)
        XCTAssertNil(defaults.legacy)
        XCTAssertEqual(keychain.calls, ["read", "add", "read", "read"])
    }

    func testDeletionNeedsNoCredentialReadAndCompletesOnlyAfterLegacyRemoval() {
        for existing in [nil, "synthetic-saved"] as [String?] {
            let keychain = FakeKeychain(existing)
            let defaults = SyntheticDefaults("synthetic-old")
            let result = CredentialMaintenance.deleteStored(operations: keychain.operations)
            XCTAssertEqual(result.status, .keychainDeleted)
            XCTAssertTrue(result.canClearLegacy)
            XCTAssertFalse(result.status.isComplete)
            XCTAssertEqual(keychain.calls, ["delete"])
            XCTAssertNil(keychain.stored)
            XCTAssertEqual(defaults.finish(result).status, .deletionCompleted)
            XCTAssertNil(defaults.legacy)
        }
    }

    func testDeletionFailurePreservesBothStoresAndCannotBeReportedAsComplete() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let keychain = FakeKeychain("synthetic-saved")
            keychain.deleteFailure = status
            let defaults = SyntheticDefaults("synthetic-old")
            let result = defaults.finish(CredentialMaintenance.deleteStored(operations: keychain.operations))
            XCTAssertEqual(result.status, .deleteFailed)
            XCTAssertFalse(result.confirmingLegacyRemoval(true).status.isComplete)
            XCTAssertEqual(keychain.stored, Data("synthetic-saved".utf8))
            XCTAssertEqual(defaults.legacy, "synthetic-old")
            XCTAssertEqual(keychain.calls, ["delete"])
        }
    }

    func testDeletionWithRetainedPreferenceIsNotASuccessfulTwoStoreDeletion() {
        let keychain = FakeKeychain("synthetic-saved")
        let defaults = SyntheticDefaults("synthetic-old")
        defaults.refuseRemoval = true
        let result = defaults.finish(CredentialMaintenance.deleteStored(operations: keychain.operations))
        XCTAssertEqual(result.status, .legacyRemovalPending)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertNil(keychain.stored)
        XCTAssertEqual(defaults.legacy, "synthetic-old")
        defaults.refuseRemoval = false
        let retried = defaults.finish(CredentialMaintenance.deleteStored(operations: keychain.operations))
        XCTAssertEqual(retried.status, .deletionCompleted)
        XCTAssertNil(defaults.legacy)
        XCTAssertEqual(keychain.calls, ["delete", "delete"])
    }
}
