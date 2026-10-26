import XCTest
import Security
@testable import AIMeter

final class KeychainHelperTests: XCTestCase {
    private final class FakeKeychain {
        var stored = Data("synthetic-original".utf8)
        var updateStatus = errSecSuccess
        var addStatus = errSecSuccess
        var deleteStatus = errSecSuccess
        var readStatus = errSecSuccess
        var calls: [String] = []
        var lastQuery: [String: Any] = [:]

        var operations: KeychainHelper.Operations {
            .init(
                update: { query, attributes in
                    self.calls.append("update")
                    self.lastQuery = query
                    if self.updateStatus == errSecSuccess {
                        self.stored = attributes[kSecValueData as String] as? Data ?? Data()
                    }
                    return self.updateStatus
                },
                add: { query in
                    self.calls.append("add")
                    self.lastQuery = query
                    if self.addStatus == errSecSuccess {
                        self.stored = query[kSecValueData as String] as? Data ?? Data()
                    }
                    return self.addStatus
                },
                delete: { query in
                    self.calls.append("delete")
                    self.lastQuery = query
                    if self.deleteStatus == errSecSuccess { self.stored = Data() }
                    return self.deleteStatus
                },
                copyMatching: { query in
                    self.calls.append("read")
                    self.lastQuery = query
                    return (self.readStatus, self.stored)
                }
            )
        }
    }

    func testExistingValueIsUpdatedWithoutDeletingOrAdding() {
        let fake = FakeKeychain()
        XCTAssertTrue(KeychainHelper.save(key: "synthetic-account", value: "synthetic-new", operations: fake.operations))
        XCTAssertEqual(fake.calls, ["update"])
        XCTAssertEqual(fake.stored, Data("synthetic-new".utf8))
        XCTAssertEqual(fake.lastQuery[kSecAttrAccount as String] as? String, "synthetic-account")
        XCTAssertEqual(fake.lastQuery[kSecAttrService as String] as? String, KeychainHelper.service)
    }

    func testUpdateFailuresPreserveTheExistingItemAndReportFailure() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let fake = FakeKeychain()
            fake.updateStatus = status
            XCTAssertFalse(KeychainHelper.save(key: "synthetic-account", value: "synthetic-new", operations: fake.operations))
            XCTAssertEqual(fake.calls, ["update"])
            XCTAssertEqual(fake.stored, Data("synthetic-original".utf8))
        }
    }

    func testMissingItemIsAddedOnlyAfterNotFound() {
        let fake = FakeKeychain()
        fake.updateStatus = errSecItemNotFound
        XCTAssertTrue(KeychainHelper.save(key: "synthetic-account", value: "synthetic-new", operations: fake.operations))
        XCTAssertEqual(fake.calls, ["update", "add"])
        XCTAssertEqual(fake.stored, Data("synthetic-new".utf8))
        XCTAssertEqual(fake.lastQuery[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
    }

    func testAddFailureReportsFailureWithoutDeletingAnyItem() {
        for status in [errSecNotAvailable, errSecDuplicateItem] {
            let fake = FakeKeychain()
            fake.updateStatus = errSecItemNotFound
            fake.addStatus = status
            XCTAssertFalse(KeychainHelper.save(key: "synthetic-account", value: "synthetic-new", operations: fake.operations))
            XCTAssertEqual(fake.calls, ["update", "add"])
            XCTAssertEqual(fake.stored, Data("synthetic-original".utf8))
        }
    }

    func testEmptyValueDeletesWithoutUpdatingOrAdding() {
        for status in [errSecSuccess, errSecItemNotFound] {
            let fake = FakeKeychain()
            fake.deleteStatus = status
            XCTAssertTrue(KeychainHelper.save(key: "synthetic-account", value: "", operations: fake.operations))
            XCTAssertEqual(fake.calls, ["delete"])
        }
        let fake = FakeKeychain()
        fake.deleteStatus = errSecInteractionNotAllowed
        XCTAssertFalse(KeychainHelper.save(key: "synthetic-account", value: "", operations: fake.operations))
        XCTAssertEqual(fake.calls, ["delete"])
        XCTAssertEqual(fake.stored, Data("synthetic-original".utf8))
    }

    func testLoadUsesInjectedReadAndRejectsFailureOrInvalidEncoding() {
        let fake = FakeKeychain()
        XCTAssertEqual(KeychainHelper.load(key: "synthetic-account", operations: fake.operations), "synthetic-original")
        XCTAssertEqual(fake.calls, ["read"])
        fake.readStatus = errSecInteractionNotAllowed
        XCTAssertNil(KeychainHelper.load(key: "synthetic-account", operations: fake.operations))
        fake.readStatus = errSecSuccess
        fake.stored = Data([0xff])
        XCTAssertNil(KeychainHelper.load(key: "synthetic-account", operations: fake.operations))
    }
    func testLegacySourceCanBeClearedOnlyAfterSuccessfulRestoreOrMigration() {
        let existing = FakeKeychain()
        let loaded = KeychainHelper.restore(key: "synthetic-account", legacyValue: "synthetic-legacy", operations: existing.operations)
        XCTAssertEqual(loaded.value, "synthetic-original")
        XCTAssertTrue(loaded.canClearLegacy)
        XCTAssertEqual(existing.calls, ["read"])

        for status in [errSecSuccess, errSecNotAvailable] {
            let missing = FakeKeychain()
            missing.readStatus = errSecItemNotFound
            missing.updateStatus = errSecItemNotFound
            missing.addStatus = status
            let result = KeychainHelper.restore(key: "synthetic-account", legacyValue: "synthetic-legacy", operations: missing.operations)
            XCTAssertEqual(result.value, "synthetic-legacy")
            XCTAssertEqual(result.canClearLegacy, status == errSecSuccess)
            XCTAssertFalse(missing.calls.contains("delete"))
        }
        let locked = FakeKeychain()
        locked.readStatus = errSecInteractionNotAllowed
        locked.updateStatus = errSecInteractionNotAllowed
        let failed = KeychainHelper.restore(key: "synthetic-account", legacyValue: "synthetic-legacy", operations: locked.operations)
        XCTAssertFalse(failed.canClearLegacy)
        XCTAssertEqual(locked.stored, Data("synthetic-original".utf8))
    }

    func testRestoreDoesNotWriteWhenTheExistingItemCannotBeRead() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecSuccess] {
            let existing = FakeKeychain()
            existing.readStatus = status
            // A successful read with invalid UTF-8 is also not an absent item.
            if status == errSecSuccess { existing.stored = Data([0xff]) }
            let original = existing.stored
            let result = KeychainHelper.restore(key: "synthetic-account", legacyValue: "synthetic-legacy", operations: existing.operations)
            XCTAssertEqual(result.value, "synthetic-legacy")
            XCTAssertFalse(result.canClearLegacy)
            XCTAssertEqual(existing.calls, ["read"])
            XCTAssertEqual(existing.stored, original)
        }
    }

}
