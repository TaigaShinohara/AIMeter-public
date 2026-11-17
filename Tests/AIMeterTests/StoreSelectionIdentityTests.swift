import Foundation
import XCTest
@testable import AIMeter

final class StoreSelectionIdentityTests: XCTestCase {
    func testCodableRoundTripPreservesAllFields() throws {
        let identity = StoreSelectionIdentity(
            fileResourceIdentifier: Data([0x00, 0x01, 0xFE, 0xFF]),
            volumeIdentifier: Data("volume".utf8),
            device: 1_677_721_604, inode: 9_007_199_254_740_993, kind: .file)
        let data = try JSONEncoder().encode(identity)
        XCTAssertEqual(try JSONDecoder().decode(StoreSelectionIdentity.self, from: data), identity)
    }

    func testCaptureRecordsDirectoryIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMeterIdentityTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try XCTUnwrap(StoreSelectionIdentity.capture(url: directory))
        XCTAssertEqual(identity.kind, .directory)
        XCTAssertFalse(identity.fileResourceIdentifier.isEmpty)
        XCTAssertNotEqual(identity.inode, 0)
        // Capturing the same directory again yields the same identity.
        XCTAssertEqual(StoreSelectionIdentity.capture(url: directory), identity)
    }

    func testCaptureRecordsFileIdentity() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMeterIdentityTests-" + UUID().uuidString + ".json")
        try Data("{}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = try XCTUnwrap(StoreSelectionIdentity.capture(url: file))
        XCTAssertEqual(identity.kind, .file)
        XCTAssertFalse(identity.fileResourceIdentifier.isEmpty)
        XCTAssertNotEqual(identity.inode, 0)
    }

    func testCaptureDistinguishesSiblingTargets() throws {
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMeterIdentityTests-" + UUID().uuidString, isDirectory: true)
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMeterIdentityTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let firstIdentity = try XCTUnwrap(StoreSelectionIdentity.capture(url: first))
        let secondIdentity = try XCTUnwrap(StoreSelectionIdentity.capture(url: second))
        XCTAssertNotEqual(firstIdentity.fileResourceIdentifier, secondIdentity.fileResourceIdentifier)
        XCTAssertNotEqual(firstIdentity.inode, secondIdentity.inode)
    }

    func testCaptureReturnsNilForMissingTarget() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMeterIdentityTests-missing-" + UUID().uuidString, isDirectory: true)
        XCTAssertNil(StoreSelectionIdentity.capture(url: missing))
    }
}
