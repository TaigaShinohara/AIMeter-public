import XCTest
import Security
@testable import AIMeter

final class OpenAICredentialStateTests: XCTestCase {
    private final class FakeKeychain {
        var stored: Data?
        var readFailure: OSStatus?
        var updateFailure: OSStatus?
        var addFailure: OSStatus?
        var deleteFailure: OSStatus?
        var readResults: [(OSStatus, Data?)] = []
        var calls: [String] = []

        init(_ value: String? = nil) {
            stored = value.map { Data($0.utf8) }
        }

        var operations: KeychainHelper.Operations {
            .init(update: { query, attributes in
                self.checkQuery(query)
                self.calls.append("update")
                if let status = self.updateFailure { return status }
                guard self.stored != nil else { return errSecItemNotFound }
                self.stored = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            }, add: { query in
                self.checkQuery(query)
                self.calls.append("add")
                if let status = self.addFailure { return status }
                guard self.stored == nil else { return errSecDuplicateItem }
                self.stored = query[kSecValueData as String] as? Data
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
            XCTAssertEqual(query[kSecAttrService as String] as? String, KeychainHelper.service)
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "openaiAdminKey")
        }
    }

    func testInitializationAndForgetNeverAccessKeychain() {
        let keychain = FakeKeychain("synthetic-saved")
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(keychain.calls.isEmpty)
        XCTAssertNil(state.committedValue)
        XCTAssertFalse(state.isLoaded)
        state.draft = "synthetic-uncommitted"
        state.forget()
        XCTAssertTrue(keychain.calls.isEmpty)
        XCTAssertEqual(state.draft, "")
        XCTAssertNil(state.committedValue)
        XCTAssertNil(state.error)
        XCTAssertFalse(state.isLoaded)
    }

    func testSavedValueLoadsWithoutRewriteAndAuthorizesLegacyClear() {
        let keychain = FakeKeychain("synthetic-saved")
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(state.load(legacyValue: "synthetic-obsolete-legacy"))
        XCTAssertEqual(state.committedValue, "synthetic-saved")
        XCTAssertEqual(state.draft, "synthetic-saved")
        XCTAssertTrue(state.isLoaded)
        XCTAssertNil(state.error)
        XCTAssertEqual(keychain.calls, ["read"])
    }

    func testAbsentItemAndEmptyLegacyAreValidWithoutMutation() {
        let keychain = FakeKeychain()
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertFalse(state.load(legacyValue: ""))
        XCTAssertTrue(state.isLoaded)
        XCTAssertNil(state.committedValue)
        XCTAssertEqual(state.draft, "")
        XCTAssertNil(state.error)
        XCTAssertEqual(keychain.calls, ["read"])
    }

    func testUnreadableOrMalformedSavedItemDoesNotMigrateOrBecomeUsable() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecSuccess] {
            let keychain = FakeKeychain("synthetic-original")
            if status == errSecSuccess { keychain.stored = Data([0xff]) }
            else { keychain.readFailure = status }
            let original = keychain.stored
            var state = OpenAICredentialState(operations: keychain.operations)
            XCTAssertFalse(state.load(legacyValue: "synthetic-retained-legacy"))
            XCTAssertNil(state.committedValue)
            XCTAssertEqual(state.draft, "synthetic-retained-legacy")
            XCTAssertTrue(state.isLoaded)
            XCTAssertNotNil(state.error)
            XCTAssertFalse(state.error?.contains("synthetic-retained-legacy") ?? true)
            XCTAssertEqual(keychain.calls, ["read"])
            XCTAssertEqual(keychain.stored, original)
        }
    }

    func testEmptyOrMissingDataOnSuccessfulReadIsNotAbsence() {
        let keychain = FakeKeychain("")
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertFalse(state.load(legacyValue: "synthetic-legacy"))
        XCTAssertNil(state.committedValue)
        XCTAssertEqual(keychain.calls, ["read"])
        XCTAssertEqual(keychain.stored, Data())

        let emptyResult = KeychainHelper.Operations(
            update: { _, _ in XCTFail("Cannot update an unreadable item"); return errSecSuccess },
            add: { _ in XCTFail("Cannot add over an unreadable item"); return errSecSuccess },
            delete: { _ in XCTFail("Cannot delete an unreadable item"); return errSecSuccess },
            copyMatching: { _ in (errSecSuccess, nil) }
        )
        var missingData = OpenAICredentialState(operations: emptyResult)
        XCTAssertFalse(missingData.load(legacyValue: "synthetic-legacy"))
        XCTAssertNil(missingData.committedValue)
        XCTAssertEqual(missingData.draft, "synthetic-legacy")
    }

    func testLegacyMigrationCommitsOnlyAfterSuccessfulAddAndSurvivesRestart() {
        let keychain = FakeKeychain()
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(state.load(legacyValue: "synthetic-legacy"))
        XCTAssertEqual(state.committedValue, "synthetic-legacy")
        XCTAssertEqual(keychain.calls, ["read", "add", "read"])

        var restarted = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(restarted.load(legacyValue: ""))
        XCTAssertEqual(restarted.committedValue, "synthetic-legacy")
        XCTAssertEqual(keychain.calls, ["read", "add", "read", "read"])
    }

    func testFailedLegacyMigrationPreservesDraftWithoutUsingItForRequests() {
        let keychain = FakeKeychain()
        keychain.addFailure = errSecNotAvailable
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertFalse(state.load(legacyValue: "synthetic-legacy"))
        XCTAssertNil(state.committedValue)
        XCTAssertEqual(state.draft, "synthetic-legacy")
        XCTAssertTrue(state.isLoaded)
        XCTAssertNotNil(state.error)
        XCTAssertNil(keychain.stored)
        XCTAssertEqual(keychain.calls, ["read", "add"])

        keychain.addFailure = nil
        XCTAssertTrue(state.save())
        XCTAssertEqual(state.committedValue, "synthetic-legacy")
        XCTAssertNil(state.error)
    }

    func testEditingDoesNotChangeCommittedValueUntilSaveSucceeds() {
        let keychain = FakeKeychain("synthetic-original")
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(state.load(legacyValue: ""))
        state.draft = "synthetic-edited"
        XCTAssertEqual(state.committedValue, "synthetic-original")
        XCTAssertEqual(keychain.calls, ["read"])

        keychain.updateFailure = errSecInteractionNotAllowed
        XCTAssertFalse(state.save())
        XCTAssertEqual(state.committedValue, "synthetic-original")
        XCTAssertEqual(state.draft, "synthetic-edited")
        XCTAssertNotNil(state.error)
        XCTAssertEqual(keychain.stored, Data("synthetic-original".utf8))

        var restarted = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(restarted.load(legacyValue: ""))
        XCTAssertEqual(restarted.committedValue, "synthetic-original")

        keychain.updateFailure = nil
        XCTAssertTrue(state.save())
        XCTAssertEqual(state.committedValue, "synthetic-edited")
        XCTAssertNil(state.error)
        XCTAssertEqual(keychain.stored, Data("synthetic-edited".utf8))
    }

    func testFailedNewSaveDoesNotBecomeCommitted() {
        let keychain = FakeKeychain()
        keychain.addFailure = errSecNotAvailable
        var state = OpenAICredentialState(operations: keychain.operations)
        state.draft = "synthetic-new"
        XCTAssertFalse(state.save())
        XCTAssertNil(state.committedValue)
        XCTAssertEqual(state.draft, "synthetic-new")
        XCTAssertTrue(state.isLoaded)
        XCTAssertNotNil(state.error)
        XCTAssertNil(keychain.stored)
        XCTAssertEqual(keychain.calls, ["update", "add"])
    }

    func testDeleteFailureKeepsCommittedValueAndSuccessfulDeleteSurvivesRestart() {
        let keychain = FakeKeychain("synthetic-original")
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(state.load(legacyValue: ""))
        state.draft = ""
        keychain.deleteFailure = errSecAuthFailed
        XCTAssertFalse(state.save())
        XCTAssertEqual(state.committedValue, "synthetic-original")
        XCTAssertEqual(state.draft, "")
        XCTAssertNotNil(state.error)
        XCTAssertEqual(keychain.stored, Data("synthetic-original".utf8))

        keychain.deleteFailure = nil
        XCTAssertTrue(state.save())
        XCTAssertNil(state.committedValue)
        XCTAssertTrue(state.isLoaded)
        XCTAssertNil(state.error)
        XCTAssertNil(keychain.stored)
        XCTAssertEqual(keychain.calls, ["read", "delete", "delete"])

        var restarted = OpenAICredentialState(operations: keychain.operations)
        XCTAssertFalse(restarted.load(legacyValue: ""))
        XCTAssertNil(restarted.committedValue)
    }

    func testMigrationReadbackFailureNeverCommitsAnUnverifiedValue() {
        let results: [(OSStatus, Data?)] = [
            (errSecInteractionNotAllowed, nil), (errSecItemNotFound, nil),
            (errSecSuccess, Data()), (errSecSuccess, Data([0xff])),
            (errSecSuccess, Data("synthetic-different".utf8))
        ]
        for result in results {
            let keychain = FakeKeychain()
            keychain.readResults = [(errSecItemNotFound, nil), result]
            var state = OpenAICredentialState(operations: keychain.operations)
            XCTAssertFalse(state.load(legacyValue: "synthetic-retained-legacy"))
            XCTAssertNil(state.committedValue)
            XCTAssertEqual(state.draft, "synthetic-retained-legacy")
            XCTAssertEqual(keychain.calls, ["read", "add", "read"])
            XCTAssertFalse(state.error?.contains("synthetic-retained-legacy") ?? true)
        }
    }

    func testSaveReadbackFailureDoesNotAuthorizeRequestsWithTheNewValue() {
        let keychain = FakeKeychain("synthetic-original")
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(state.load(legacyValue: ""))
        state.draft = "synthetic-new"
        keychain.readFailure = errSecInteractionNotAllowed
        XCTAssertFalse(state.save())
        XCTAssertNil(state.committedValue)
        XCTAssertEqual(state.draft, "synthetic-new")
        XCTAssertNotNil(state.error)
        XCTAssertEqual(keychain.stored, Data("synthetic-new".utf8))
        XCTAssertEqual(keychain.calls, ["read", "update", "read"])
        XCTAssertFalse(state.error?.contains("synthetic-new") ?? true)
    }

    func testUnusableSavedOrDraftValuesNeverAuthorizeLegacyClearOrMutation() {
        for invalid in [" ", "synthetic\nheader", "秘密", String(repeating: "x", count: 16_385)] {
            let keychain = FakeKeychain(invalid)
            var state = OpenAICredentialState(operations: keychain.operations)
            XCTAssertFalse(state.load(legacyValue: "synthetic-retained-legacy"))
            XCTAssertNil(state.committedValue)
            XCTAssertEqual(keychain.calls, ["read"])
            state.draft = invalid
            XCTAssertFalse(state.save())
            XCTAssertEqual(keychain.calls, ["read"])
            XCTAssertEqual(keychain.stored, Data(invalid.utf8))
        }
    }

    func testExplicitMaintenanceDoesNotRetainCredentialsForNetworkUse() {
        let keychain = FakeKeychain()
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(keychain.calls.isEmpty)
        let migrated = state.migrateLegacy(legacyValue: "synthetic-legacy")
        XCTAssertTrue(migrated.canClearLegacy)
        XCTAssertNil(state.committedValue)
        XCTAssertEqual(state.draft, "")
        XCTAssertFalse(state.isLoaded)
        XCTAssertEqual(keychain.calls, ["read", "add", "read"])

        XCTAssertTrue(state.load(legacyValue: ""))
        let deleted = state.deleteStored()
        XCTAssertTrue(deleted.canClearLegacy)
        XCTAssertNil(state.committedValue)
        XCTAssertEqual(state.draft, "")
        XCTAssertTrue(state.isLoaded)
        XCTAssertNil(keychain.stored)
    }

    func testForgetLoadedOrFailedStateDoesNotChangePersistentItem() {
        let keychain = FakeKeychain("synthetic-original")
        var state = OpenAICredentialState(operations: keychain.operations)
        XCTAssertTrue(state.load(legacyValue: ""))
        state.draft = "synthetic-unsaved"
        keychain.updateFailure = errSecAuthFailed
        XCTAssertFalse(state.save())
        let calls = keychain.calls
        state.forget()
        XCTAssertEqual(keychain.calls, calls)
        XCTAssertEqual(keychain.stored, Data("synthetic-original".utf8))
        XCTAssertEqual(state.draft, "")
        XCTAssertNil(state.committedValue)
        XCTAssertNil(state.error)
        XCTAssertFalse(state.isLoaded)
    }
}
