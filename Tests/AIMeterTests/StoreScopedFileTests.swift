import Darwin
import Foundation
import XCTest
@testable import AIMeter

final class StoreScopedFileTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "AIMeter.StoreScopedFileTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func bookmarks(url: URL, start: @escaping (URL) -> Bool = { _ in true },
                           stop: @escaping (URL) -> Void = { _ in },
                           captureIdentity: ((URL) -> StoreSelectionIdentity?)? = nil) throws -> StoreBookmarkStore {
        var operations = StoreBookmarkStore.Operations(
            create: { _ in Data("synthetic".utf8) },
            resolve: { _ in (url, false) }, start: start, stop: stop)
        if let captureIdentity { operations.captureIdentity = captureIdentity }
        let result = StoreBookmarkStore(defaults: defaults, operations: operations)
        try result.save(url, sourceID: "claude.settings")
        return result
    }

    private func settingsFile() throws -> URL {
        let file = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: file)
        return file
    }

    func testVerifiedFileIsOpenedAndClosed() async throws {
        let file = try settingsFile()
        let store = try bookmarks(url: file)
        let identity = try XCTUnwrap(store.identity(sourceID: "claude.settings"))
        XCTAssertEqual(identity.kind, .file)
        var borrowed: Int32 = -1
        let inode = try await StoreScopedFile(bookmarks: store).withFile(sourceID: "claude.settings") { fd in
            borrowed = fd
            var info = stat()
            XCTAssertEqual(fstat(fd, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
            return info.st_ino
        }
        XCTAssertEqual(inode, identity.inode)
        XCTAssertGreaterThanOrEqual(borrowed, 0)
        XCTAssertEqual(fcntl(borrowed, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testReplacedFileIsRejected() async throws {
        let file = try settingsFile()
        let store = try bookmarks(url: file)
        try FileManager.default.removeItem(at: file)
        try Data("{\"replaced\":true}".utf8).write(to: file)
        var opened = false
        var operations = StoreScopedFile.Operations.live
        let open = operations.openFile
        operations.openFile = { path in opened = true; return try open(path) }
        do {
            _ = try await StoreScopedFile(bookmarks: store, operations: operations)
                .withFile(sourceID: "claude.settings") { _ in XCTFail("Replaced file"); return 0 }
            XCTFail("Expected replacement rejection")
        } catch { XCTAssertEqual(error as? StoreScopedFile.Failure, .changed) }
        XCTAssertFalse(opened)
    }

    func testMissingIdentityRecordNeverStartsAccess() async throws {
        let file = try settingsFile()
        var started = false
        let store = try bookmarks(url: file, start: { _ in started = true; return true },
                                  captureIdentity: { _ in nil })
        XCTAssertNil(store.identity(sourceID: "claude.settings"))
        do {
            _ = try await StoreScopedFile(bookmarks: store).withFile(sourceID: "claude.settings") { _ in
                XCTFail("Unverified file"); return 0
            }
            XCTFail("Expected identity rejection")
        } catch { XCTAssertEqual(error as? StoreScopedFile.Failure, .changed) }
        XCTAssertFalse(started)
    }

    func testDirectoryIdentityIsRejectedForFileEntry() async throws {
        let file = try settingsFile()
        let store = try bookmarks(url: file)
        let directoryIdentity = StoreSelectionIdentity(
            fileResourceIdentifier: Data("synthetic-file-id".utf8), volumeIdentifier: nil,
            device: 42, inode: 1001, kind: .directory)
        var opened = false
        var operations = StoreScopedFile.Operations.live
        operations.openFile = { _ in opened = true; throw StoreScopedFile.Failure.openFailed }
        do {
            _ = try await StoreScopedFile(bookmarks: store, operations: operations)
                .withFile(sourceID: "claude.settings", identity: directoryIdentity) { _ in
                    XCTFail("Directory identity"); return 0
                }
            XCTFail("Expected kind rejection")
        } catch { XCTAssertEqual(error as? StoreScopedFile.Failure, .changed) }
        XCTAssertFalse(opened)
    }

    func testSymlinkFileIsRejectedWithoutFollowingIt() async throws {
        let target = try settingsFile()
        let link = root.appendingPathComponent("settings-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // The link itself cannot be captured (it is never followed), so the
        // recorded identity is synthetic; the lstat type check must still be
        // what rejects the selection.
        let fileIdentity = StoreSelectionIdentity(
            fileResourceIdentifier: Data("synthetic-file-id".utf8), volumeIdentifier: nil,
            device: 42, inode: 2002, kind: .file)
        let store = try bookmarks(url: link, captureIdentity: { _ in fileIdentity })
        do {
            _ = try await StoreScopedFile(bookmarks: store).withFile(sourceID: "claude.settings") { _ in
                XCTFail("Symlink file"); return 0
            }
            XCTFail("Expected symlink rejection")
        } catch { XCTAssertEqual(error as? StoreScopedFile.Failure, .invalidFile) }
    }

    func testDescriptorFileIDMismatchIsRejectedAndClosesDescriptor() async throws {
        let file = try settingsFile()
        let recorded = try XCTUnwrap(StoreSelectionIdentity.capture(url: file))
        let store = try bookmarks(url: file)
        var opened: Int32 = -1
        var operations = StoreScopedFile.Operations.live
        let open = operations.openFile
        operations.openFile = { path in opened = try open(path); return opened }
        operations.descriptorFileID = { _ in recorded.inode + 1 }
        do {
            _ = try await StoreScopedFile(bookmarks: store, operations: operations)
                .withFile(sourceID: "claude.settings") { _ in
                    XCTFail("Descriptor mismatch"); return 0
                }
            XCTFail("Expected descriptor rejection")
        } catch { XCTAssertEqual(error as? StoreScopedFile.Failure, .changed) }
        XCTAssertGreaterThanOrEqual(opened, 0)
        XCTAssertEqual(fcntl(opened, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }
}
