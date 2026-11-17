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

    private static let syntheticDirectoryIdentity = StoreSelectionIdentity(
        fileResourceIdentifier: Data("synthetic-file-id".utf8),
        volumeIdentifier: Data("synthetic-volume-id".utf8),
        device: 42, inode: 1001, kind: .directory)

    private func bookmarks(url: URL, start: @escaping (URL) -> Bool,
                           stop: @escaping (URL) -> Void,
                           captureIdentity: ((URL) -> StoreSelectionIdentity?)? = nil) throws -> StoreBookmarkStore {
        var operations = StoreBookmarkStore.Operations(
            create: { _ in Data("synthetic".utf8) },
            resolve: { _ in (url, false) }, start: start, stop: stop)
        if let captureIdentity { operations.captureIdentity = captureIdentity }
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
        // The link itself cannot be captured (it is never followed), so the
        // recorded identity is synthetic; the lstat type check must still be
        // what rejects the selection.
        let store = try bookmarks(url: link, start: { _ in true }, stop: { _ in stopped = true },
                                  captureIdentity: { _ in Self.syntheticDirectoryIdentity })
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

    func testMissingIdentityRecordNeverStartsAccess() async throws {
        var started = false
        let store = try bookmarks(url: root, start: { _ in started = true; return true },
                                  stop: { _ in }, captureIdentity: { _ in nil })
        XCTAssertNil(store.identity(sourceID: "codex"))
        do {
            _ = try await StoreScopedDirectory(bookmarks: store).withRoot(sourceID: "codex") { _ in
                XCTFail("Unverified directory"); return 0
            }
            XCTFail("Expected identity rejection")
        } catch { XCTAssertEqual(error as? StoreScopedDirectory.Failure, .changed) }
        XCTAssertFalse(started)
    }

    func testAncestorReplacedBeforeAccessIsRejected() async throws {
        // root/parent/selected is chosen; afterwards root/parent is replaced
        // by a link to root/outside, so the same path names a different
        // directory than the one recorded at selection time. The replacement
        // predates any lstat this access performs, so only the recorded
        // identity can detect it.
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let selected = parent.appendingPathComponent("selected", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideSelected = outside.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideSelected, withIntermediateDirectories: true)
        var stopped = false
        let store = try bookmarks(url: selected, start: { _ in true }, stop: { _ in stopped = true })
        let moved = root.appendingPathComponent("parent-moved", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        var opened = false
        var operations = StoreScopedDirectory.Operations.live
        let open = operations.openDirectory
        operations.openDirectory = { path in opened = true; return try open(path) }
        do {
            _ = try await StoreScopedDirectory(bookmarks: store, operations: operations)
                .withRoot(sourceID: "codex") { _ in XCTFail("Replaced ancestor"); return 0 }
            XCTFail("Expected ancestor replacement rejection")
        } catch { XCTAssertEqual(error as? StoreScopedDirectory.Failure, .changed) }
        XCTAssertFalse(opened)
        XCTAssertTrue(stopped)
    }

    func testTargetReplacedBeforeAccessIsRejected() async throws {
        // The selected directory itself is moved away and a different
        // directory takes its path before access begins.
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let retained = root.appendingPathComponent("retained", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        var stopped = false
        let store = try bookmarks(url: selected, start: { _ in true }, stop: { _ in stopped = true })
        try FileManager.default.moveItem(at: selected, to: retained)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        var opened = false
        var operations = StoreScopedDirectory.Operations.live
        let open = operations.openDirectory
        operations.openDirectory = { path in opened = true; return try open(path) }
        do {
            _ = try await StoreScopedDirectory(bookmarks: store, operations: operations)
                .withRoot(sourceID: "codex") { _ in XCTFail("Replaced target"); return 0 }
            XCTFail("Expected target replacement rejection")
        } catch { XCTAssertEqual(error as? StoreScopedDirectory.Failure, .changed) }
        XCTAssertFalse(opened)
        XCTAssertTrue(stopped)
    }

    func testInodeReuseWithDifferentFileIdentifierIsRejected() async throws {
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let recorded = try XCTUnwrap(StoreSelectionIdentity.capture(url: selected))
        let store = try bookmarks(url: selected, start: { _ in true }, stop: { _ in })
        XCTAssertEqual(store.identity(sourceID: "codex"), recorded)
        // The entity behind the path now reports the recorded device and
        // inode (a reused inode) but a different file resource identifier:
        // the recorded target is gone even though the numbers line up.
        var operations = StoreScopedDirectory.Operations.live
        operations.captureIdentity = { _ in
            StoreSelectionIdentity(fileResourceIdentifier: Data("different-entity".utf8),
                                   volumeIdentifier: recorded.volumeIdentifier,
                                   device: recorded.device, inode: recorded.inode,
                                   kind: .directory)
        }
        do {
            _ = try await StoreScopedDirectory(bookmarks: store, operations: operations)
                .withRoot(sourceID: "codex") { _ in XCTFail("Reused inode"); return 0 }
            XCTFail("Expected inode reuse rejection")
        } catch { XCTAssertEqual(error as? StoreScopedDirectory.Failure, .changed) }
    }

    func testDescriptorFileIDMismatchIsRejectedAndClosesDescriptor() async throws {
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let recorded = try XCTUnwrap(StoreSelectionIdentity.capture(url: selected))
        let store = try bookmarks(url: selected, start: { _ in true }, stop: { _ in })
        var opened: Int32 = -1
        var operations = StoreScopedDirectory.Operations.live
        let open = operations.openDirectory
        operations.openDirectory = { path in opened = try open(path); return opened }
        operations.descriptorFileID = { _ in recorded.inode + 1 }
        do {
            _ = try await StoreScopedDirectory(bookmarks: store, operations: operations)
                .withRoot(sourceID: "codex") { _ in XCTFail("Descriptor mismatch"); return 0 }
            XCTFail("Expected descriptor rejection")
        } catch { XCTAssertEqual(error as? StoreScopedDirectory.Failure, .changed) }
        XCTAssertGreaterThanOrEqual(opened, 0)
        XCTAssertEqual(fcntl(opened, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testExplicitRecordedIdentityOpensSelectedDirectory() async throws {
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let store = try bookmarks(url: selected, start: { _ in true }, stop: { _ in })
        let identity = try XCTUnwrap(store.identity(sourceID: "codex"))
        let inode = try await StoreScopedDirectory(bookmarks: store)
            .withRoot(sourceID: "codex", identity: identity) { fd in
                var info = stat()
                XCTAssertEqual(fstat(fd, &info), 0)
                return info.st_ino
            }
        XCTAssertEqual(inode, identity.inode)
    }

    func testFileIdentityIsRejectedForDirectoryRoot() async throws {
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let store = try bookmarks(url: selected, start: { _ in true }, stop: { _ in })
        let fileIdentity = StoreSelectionIdentity(
            fileResourceIdentifier: Data("synthetic-file-id".utf8), volumeIdentifier: nil,
            device: 42, inode: 2002, kind: .file)
        var opened = false
        var operations = StoreScopedDirectory.Operations.live
        operations.openDirectory = { _ in opened = true; throw StoreScopedDirectory.Failure.openFailed }
        do {
            _ = try await StoreScopedDirectory(bookmarks: store, operations: operations)
                .withRoot(sourceID: "codex", identity: fileIdentity) { _ in
                    XCTFail("File identity"); return 0
                }
            XCTFail("Expected kind rejection")
        } catch { XCTAssertEqual(error as? StoreScopedDirectory.Failure, .changed) }
        XCTAssertFalse(opened)
    }
}
