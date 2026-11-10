import Foundation
import XCTest
@testable import AIMeter

final class StoreBookmarkStoreTests: XCTestCase {
    func testSeparateSourcesAndReleaseAfterFailure() async throws {
        let suite = "AIMeter.StoreBookmarksTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/synthetic/one")
        let second = URL(fileURLWithPath: "/synthetic/two")
        var stopped: [URL] = []
        let operations = StoreBookmarkStore.Operations(
            create: { Data($0.path.utf8) },
            resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
            start: { _ in true }, stop: { stopped.append($0) })
        let store = StoreBookmarkStore(defaults: defaults, operations: operations)
        try store.save(first, sourceID: "gemini.brain")
        try store.save(second, sourceID: "gemini.chats")
        do {
            let _: Void = try await store.withAccess(sourceID: "gemini.brain") { url in
                XCTAssertEqual(url, first)
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(stopped, [first])
        store.remove(sourceID: "gemini.brain")
        let result = try await store.withAccess(sourceID: "gemini.chats") { $0 }
        XCTAssertEqual(result, second)
        XCTAssertEqual(stopped, [first, second])
        do {
            _ = try await store.withAccess(sourceID: "gemini.brain") { $0 }
            XCTFail("Removed access must not be restored")
        } catch { XCTAssertEqual(error as? StoreBookmarkStore.Failure, .missing) }
    }

    func testDeniedAccessDoesNotRunOrEraseSavedBookmark() async throws {
        let suite = "AIMeter.StoreBookmarksTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var allowed = false
        var stopped = false
        let url = URL(fileURLWithPath: "/synthetic/source")
        let operations = StoreBookmarkStore.Operations(
            create: { Data($0.path.utf8) }, resolve: { _ in (url, false) },
            start: { _ in allowed }, stop: { _ in stopped = true })
        let store = StoreBookmarkStore(defaults: defaults, operations: operations)
        try store.save(url, sourceID: "codex")
        do {
            _ = try await store.withAccess(sourceID: "codex") { _ in XCTFail("Denied"); return 0 }
            XCTFail("Expected access denial")
        } catch { XCTAssertEqual(error as? StoreBookmarkStore.Failure, .accessDenied) }
        XCTAssertFalse(stopped)
        allowed = true
        let saved = try await store.withAccess(sourceID: "codex") { $0 }
        XCTAssertEqual(saved, url)
        XCTAssertTrue(stopped)
    }

    func testStaleBookmarkIsReplacedWhileAccessIsHeld() async throws {
        let suite = "AIMeter.StoreBookmarksTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(fileURLWithPath: "/synthetic/source")
        var isAccessing = false
        var createdWhileAccessing = false
        var stale = false
        let operations = StoreBookmarkStore.Operations(
            create: { _ in
                if stale { createdWhileAccessing = isAccessing }
                return Data(stale ? "renewed".utf8 : "original".utf8)
            },
            resolve: { _ in (url, stale) },
            start: { _ in isAccessing = true; return true },
            stop: { _ in isAccessing = false })
        let store = StoreBookmarkStore(defaults: defaults, operations: operations)
        try store.save(url, sourceID: "claude")
        stale = true
        _ = try await store.withAccess(sourceID: "claude") { selected in
            XCTAssertTrue(isAccessing)
            return selected
        }
        XCTAssertTrue(createdWhileAccessing)
        XCTAssertFalse(isAccessing)
        let bookmarks = try XCTUnwrap(defaults.dictionary(forKey: "storeSourceBookmarks") as? [String: Data])
        XCTAssertEqual(bookmarks["claude"], Data("renewed".utf8))
    }

    func testStaleRefreshDoesNotRestoreARevokedBookmark() async throws {
        let suite = "AIMeter.StoreBookmarksTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(fileURLWithPath: "/synthetic/source")
        var store: StoreBookmarkStore!
        var refreshing = false
        var stopped = false
        let operations = StoreBookmarkStore.Operations(
            create: { _ in
                if refreshing { store.remove(sourceID: "codex") }
                return Data("bookmark".utf8)
            }, resolve: { _ in (url, true) },
            start: { _ in true }, stop: { _ in stopped = true })
        store = StoreBookmarkStore(defaults: defaults, operations: operations)
        try store.save(url, sourceID: "codex")
        refreshing = true
        do {
            _ = try await store.withAccess(sourceID: "codex") { _ in XCTFail("Revoked"); return 0 }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertTrue(stopped)
        do {
            _ = try await store.withAccess(sourceID: "codex") { $0 }
            XCTFail("Revoked bookmark was restored")
        } catch { XCTAssertEqual(error as? StoreBookmarkStore.Failure, .missing) }
    }

    func testSelectionStatusDoesNotStartAccessAndDoesNotClaimReadability() throws {
        let suite = "AIMeter.StoreBookmarksTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(fileURLWithPath: "/synthetic/source")
        var stale = false
        var startCount = 0
        let operations = StoreBookmarkStore.Operations(
            create: { _ in Data("bookmark".utf8) }, resolve: { _ in (url, stale) },
            start: { _ in startCount += 1; return false }, stop: { _ in XCTFail("Access was not started") })
        let store = StoreBookmarkStore(defaults: defaults, operations: operations)
        XCTAssertEqual(store.selectionStatus(sourceID: "codex"), .unselected)
        try store.save(url, sourceID: "codex")
        XCTAssertEqual(store.selectionStatus(sourceID: "codex"), .saved(url))
        stale = true
        XCTAssertEqual(store.selectionStatus(sourceID: "codex"), .needsReselection)
        XCTAssertEqual(startCount, 0)
    }
}
