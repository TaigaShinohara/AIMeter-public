import Darwin
import Foundation
import XCTest
@testable import AIMeter

final class StoreScopedDirectoryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "AIMeter.StoreScopedDirectoryTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func bookmarks(url: URL, start: @escaping (URL) -> Bool,
                           stop: @escaping (URL) -> Void) throws -> StoreBookmarkStore {
        let operations = StoreBookmarkStore.Operations(
            create: { _ in Data("synthetic".utf8) },
            resolve: { _ in (url, false) }, start: start, stop: stop)
        let result = StoreBookmarkStore(defaults: defaults, operations: operations)
        try result.save(url, sourceID: "codex")
        return result
    }

    func testDescriptorIsScopedAndClosedAfterCancellation() async throws {
        var scoped = false
        var borrowed: Int32 = -1
        let store = try bookmarks(url: root, start: { _ in scoped = true; return true },
                                  stop: { _ in scoped = false })
        let directory = StoreScopedDirectory(bookmarks: store)
        do {
            let _: Void = try await directory.withRoot(sourceID: "codex") { fd in
                XCTAssertTrue(scoped)
                borrowed = fd
                var info = stat()
                XCTAssertEqual(fstat(fd, &info), 0)
                XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertFalse(scoped)
        XCTAssertGreaterThanOrEqual(borrowed, 0)
        XCTAssertEqual(fcntl(borrowed, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testDeniedScopeNeverOpensDirectory() async throws {
        var opened = false
        var stopped = false
        let store = try bookmarks(url: root, start: { _ in false }, stop: { _ in stopped = true })
        var operations = StoreScopedDirectory.Operations.live
        operations.openDirectory = { _ in opened = true; throw StoreScopedDirectory.Failure.openFailed }
        let directory = StoreScopedDirectory(bookmarks: store, operations: operations)
        do {
            _ = try await directory.withRoot(sourceID: "codex") { _ in XCTFail("Denied scope"); return 0 }
            XCTFail("Expected scope denial")
        } catch { XCTAssertEqual(error as? StoreBookmarkStore.Failure, .accessDenied) }
        XCTAssertFalse(opened)
        XCTAssertFalse(stopped)
    }

    func testSymlinkIsRejectedWithoutFollowingIt() async throws {
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var stopped = false
        let store = try bookmarks(url: link, start: { _ in true }, stop: { _ in stopped = true })
        do {
            _ = try await StoreScopedDirectory(bookmarks: store).withRoot(sourceID: "codex") { _ in XCTFail("Symlink"); return 0 }
            XCTFail("Expected symlink rejection")
        } catch { XCTAssertEqual(error as? StoreScopedDirectory.Failure, .invalidDirectory) }
        XCTAssertTrue(stopped)
    }

    func testReplacementAfterInspectionClosesDescriptorAndRejectsResult() async throws {
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let retained = root.appendingPathComponent("retained", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        var stopped = false
        var opened: Int32 = -1
        let store = try bookmarks(url: selected, start: { _ in true }, stop: { _ in stopped = true })
        var operations = StoreScopedDirectory.Operations.live
        let open = operations.openDirectory
        operations.openDirectory = { path in
            try FileManager.default.moveItem(at: selected, to: retained)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            opened = try open(path)
            return opened
        }
        do {
            _ = try await StoreScopedDirectory(bookmarks: store, operations: operations).withRoot(sourceID: "codex") { _ in
                XCTFail("Changed directory"); return 0
            }
            XCTFail("Expected replacement rejection")
        } catch { XCTAssertEqual(error as? StoreScopedDirectory.Failure, .changed) }
        XCTAssertTrue(stopped)
        XCTAssertGreaterThanOrEqual(opened, 0)
        XCTAssertEqual(fcntl(opened, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }
}
