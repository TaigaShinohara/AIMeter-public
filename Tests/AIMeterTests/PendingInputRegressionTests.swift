import XCTest
import Foundation
import Darwin
import SQLite3
import AIMeterCore
@testable import AIMeter

/// Regression coverage for the input changes carried over from the earlier
/// checkout. Every path belongs to a synthetic temporary home.
final class PendingInputRegressionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func assertFileFailure<T>(
        _ operation: @autoclosure () throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case BoundedInput.Failure.file = error else {
                XCTFail("Expected a regular-file boundary failure, got \(type(of: error))", file: file, line: line)
                return
            }
        }
    }

    func testAtomicUpdateKeepsPrivatePermissionsAndLeavesNoTemporaryFiles() throws {
        let destination = root.appendingPathComponent("usage.json")
        let initial = Data("{\"value\":1}".utf8)
        let updated = Data("{\"value\":2}".utf8)
        try BoundedInput.writeRegularFileAtomically(initial, to: destination)
        let firstPermissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(firstPermissions?.intValue, 0o600)

        try BoundedInput.writeRegularFileAtomically(updated, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), updated)
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["usage.json"])
    }

    func testOptionalReadDistinguishesMissingDataFromDanglingSymlinkAndFIFO() throws {
        XCTAssertNil(try BoundedInput().dataIfPresent(at: root.appendingPathComponent("missing.json")))
        let bytes = Data("synthetic".utf8)
        let ordinary = try write("ordinary.json", bytes: bytes)
        XCTAssertEqual(try BoundedInput().dataIfPresent(at: ordinary), bytes)

        let dangling = root.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: root.appendingPathComponent("absent-target.json")
        )
        assertFileFailure(try BoundedInput().dataIfPresent(at: dangling))

        let fifo = root.appendingPathComponent("pipe.json")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        assertFileFailure(try BoundedInput().dataIfPresent(at: fifo))
    }

    func testTraversalAcceptsRegularRootsButRejectsSymlinkAndFIFORoots() throws {
        XCTAssertEqual(try BoundedInput().files(at: root.appendingPathComponent("absent")), [])
        let ordinary = try write("logs/session.jsonl", bytes: Data("{}".utf8))
        XCTAssertEqual(try BoundedInput().files(at: ordinary), [ordinary])
        XCTAssertEqual(try BoundedInput().files(at: ordinary.deletingLastPathComponent()).map(\.lastPathComponent), [ordinary.lastPathComponent])

        let linkedDirectory = root.appendingPathComponent("linked-logs")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: ordinary.deletingLastPathComponent())
        assertFileFailure(try BoundedInput().files(at: linkedDirectory))
        let linkedFile = root.appendingPathComponent("linked-session.jsonl")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: ordinary)
        assertFileFailure(try BoundedInput().files(at: linkedFile))

        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        assertFileFailure(try BoundedInput().files(at: fifo))
    }

    func testAtomicWriterRejectsSymlinkDestinationAndParentWithoutChangingTargets() throws {
        let original = Data("keep-this-value".utf8)
        let target = try write("target.json", bytes: original)
        let destination = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        assertFileFailure(try BoundedInput.writeRegularFileAtomically(Data("new".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)

        let directory = root.appendingPathComponent("real-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let linkedDirectory = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        assertFileFailure(try BoundedInput.writeRegularFileAtomically(
            Data("new".utf8), to: linkedDirectory.appendingPathComponent("usage.json")
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".tmp") })
    }

    func testCollectorRejectsSymlinkWALAndPreservesPreviousAggregateBytes() async throws {
        let dbURL = root.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            XCTFail("Could not create synthetic SQLite database")
            return
        }
        let result = sqlite3_exec(db, """
            CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value TEXT);
            INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"usage":{"usedMessages":17}}');
            """, nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(result, SQLITE_OK)

        let destination = root.appendingPathComponent("usage.json")
        let initial = try await LocalUsageCollector.collectAndSave(
            targetFileURL: destination, customPaths: ["windsurf": dbURL.path], home: root
        )
        XCTAssertEqual(initial.providers?["windsurf"]?.usedByPeriod?.monthly, 17)
        let previousBytes = try Data(contentsOf: destination)
        let targetBytes = Data("synthetic-wal-target".utf8)
        let target = try write("wal-target", bytes: targetBytes)
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        try FileManager.default.createSymbolicLink(at: walURL, withDestinationURL: target)

        do {
            _ = try await LocalUsageCollector.collectAndSave(
                targetFileURL: destination, customPaths: ["windsurf": dbURL.path], home: root
            )
            XCTFail("A WAL symlink must reject collection rather than replacing the previous aggregate")
        } catch {
            guard case BoundedInput.Failure.file = error else {
                XCTFail("Expected WAL file-boundary rejection, got \(type(of: error))")
                return
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), previousBytes)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }
}
