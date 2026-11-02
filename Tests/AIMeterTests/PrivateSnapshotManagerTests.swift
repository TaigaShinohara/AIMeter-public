import XCTest
import Foundation
import Darwin
import SQLite3
import AIMeterCore
@testable import AIMeter

final class PrivateSnapshotManagerTests: XCTestCase {
    private var workspace: URL!
    private var root: URL { workspace.appendingPathComponent("manager") }
    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: workspace) }

    private func privateWrite(_ value: String, to url: URL) throws {
        try BoundedInput.writeRegularFileAtomically(Data(value.utf8), to: url)
    }

    func testLiveKernelLockWinsEvenWithStalePIDMetadataAndFinishRemovesOnlyTheSession() throws {
        let session = try PrivateSnapshotManager.begin(root: root)
        defer { session.close() }
        let payload = session.directory.appendingPathComponent("state.vscdb")
        try privateWrite("synthetic-private-database", to: payload)
        let stalePID = PrivateSnapshotManager.Manifest(format: "AIMeter.WindsurfSnapshot", version: 1,
                                                        generation: session.generation, processID: Int32.max,
                                                        createdAt: 1, startedUptime: 0)
        try BoundedInput.writeRegularFileAtomically(JSONEncoder().encode(stalePID),
                                                     to: session.directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try PrivateSnapshotManager.cleanup(root: root), 0)
        XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "synthetic-private-database")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: payload.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try session.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testAbandonedSessionIsRecoveredByOnlyOneOfTwoCleaners() async throws {
        let session = try PrivateSnapshotManager.begin(root: root)
        try privateWrite("synthetic-database", to: session.directory.appendingPathComponent("state.vscdb"))
        try privateWrite("synthetic-wal", to: session.directory.appendingPathComponent("state.vscdb-wal"))
        let directory = session.directory
        // A process exit releases the kernel lease and leaves these files.
        session.close()
        let cleanupRoot = root
        let first = Task.detached { try PrivateSnapshotManager.cleanup(root: cleanupRoot) }
        let second = Task.detached { try PrivateSnapshotManager.cleanup(root: cleanupRoot) }
        let firstRemoved = try await first.value
        let secondRemoved = try await second.value
        XCTAssertEqual(firstRemoved + secondRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnknownMembersAndSymlinksPreserveAllSentinels() throws {
        let unknown = try PrivateSnapshotManager.begin(root: root)
        try privateWrite("other-app-sentinel", to: unknown.directory.appendingPathComponent("sentinel.txt"))
        unknown.close()
        let linked = try PrivateSnapshotManager.begin(root: root)
        let target = workspace.appendingPathComponent("outside.txt")
        try privateWrite("outside-sentinel", to: target)
        try FileManager.default.createSymbolicLink(at: linked.directory.appendingPathComponent("state.vscdb"),
                                                   withDestinationURL: target)
        linked.close()
        XCTAssertEqual(try PrivateSnapshotManager.cleanup(root: root), 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "outside-sentinel")
        XCTAssertEqual(try String(contentsOf: unknown.directory.appendingPathComponent("sentinel.txt"), encoding: .utf8), "other-app-sentinel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.directory.appendingPathComponent("manifest.json").path))
    }

    func testUnrecognizedManifestAndLegacyPrefixAreNeverCleanupTargets() throws {
        let session = try PrivateSnapshotManager.begin(root: root)
        let marker = PrivateSnapshotManager.Manifest(format: "Other.Application", version: 1,
                                                      generation: session.generation, processID: getpid(),
                                                      createdAt: 1, startedUptime: 0)
        try BoundedInput.writeRegularFileAtomically(JSONEncoder().encode(marker),
                                                     to: session.directory.appendingPathComponent("manifest.json"))
        try privateWrite("other-app-database", to: session.directory.appendingPathComponent("state.vscdb"))
        session.close()
        let old = workspace.appendingPathComponent("aimeter-db-old-format")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try privateWrite("legacy-sentinel", to: old.appendingPathComponent("state.vscdb"))
        XCTAssertEqual(try PrivateSnapshotManager.cleanup(root: root), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("state.vscdb").path))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("state.vscdb"), encoding: .utf8), "legacy-sentinel")
    }

    func testUnsafeRootAndLinkedRootFailWithoutChangingTargets() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let sentinel = root.appendingPathComponent("sentinel")
        try privateWrite("unchanged", to: sentinel)
        XCTAssertThrowsError(try PrivateSnapshotManager.begin(root: root))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
        let link = workspace.appendingPathComponent("linked-manager")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try PrivateSnapshotManager.cleanup(root: link))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
    }

    func testRootWithReadACLIsRejectedEvenWithPrivatePOSIXMode() throws {
        let session = try PrivateSnapshotManager.begin(root: root)
        try session.finish()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow list,search,readattr,readextattr,readsecurity", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try PrivateSnapshotManager.begin(root: root))
        XCTAssertThrowsError(try PrivateSnapshotManager.cleanup(root: root))
    }

    func testDatabaseReadAndThrowingCallbackCleanPrivateCopiesAndPreserveSource() throws {
        let source = workspace.appendingPathComponent("source.vscdb")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        let status = sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT,value TEXT); INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{\"usage\":{\"usedMessages\":17}}');", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(status, SQLITE_OK)
        let original = try Data(contentsOf: source)
        let data = try WindsurfDatabase.readPlan(at: source, input: BoundedInput(), snapshotRoot: root)
        XCTAssertNotNil(data)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        enum Synthetic: Error { case stopped }
        XCTAssertThrowsError(try WindsurfDatabase.readPlan(at: source, input: BoundedInput(),
                                                           snapshotReady: { throw Synthetic.stopped }, snapshotRoot: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
