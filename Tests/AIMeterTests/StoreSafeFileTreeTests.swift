import XCTest
import Foundation
import Darwin
@testable import AIMeter

final class StoreSafeFileTreeTests: XCTestCase {
    private var root: URL!
    private var selected: URL { root.appendingPathComponent("selected") }
    private var outside: URL { root.appendingPathComponent("outside") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("value"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func read(limits: StoreSafeFileTree.Limits = .init(),
                      includeFile: ([String], StoreSafeFileTree.Metadata) -> Bool = { _, _ in true },
                      descendDirectory: ([String], StoreSafeFileTree.Metadata) -> Bool = { _, _ in true },
                      cancelled: () -> Bool = { false },
                      beforeOpen: ([String]) throws -> Void = { _ in }) throws -> [StoreSafeFileTree.File] {
        let fd = Darwin.open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreSafeFileTree.Failure.invalidRoot }
        defer { Darwin.close(fd) }
        return try StoreSafeFileTree.read(rootDirectoryFD: fd, limits: limits,
                                          includeFile: includeFile, descendDirectory: descendDirectory,
                                          cancelled: cancelled, beforeOpen: beforeOpen)
    }

    func testSkipsLinksAndReadsNestedRegularFiles() throws {
        let nested = selected.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: nested.appendingPathComponent("value"))
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertEqual(try read(), [
            .init(components: ["nested", "value"], data: Data("inside".utf8))
        ])
    }

    func testReplacementWithLinkBeforeChildOpenIsRejected() throws {
        let child = selected.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertThrowsError(try read(beforeOpen: { components in
            guard components == ["child"] else { return }
            try FileManager.default.moveItem(at: child, to: self.root.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: child, withDestinationURL: self.outside)
        }))
    }

    func testReplacingOpenedParentKeepsReadingTheOriginalDirectory() throws {
        let child = selected.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: child.appendingPathComponent("value"))
        let files = try read(beforeOpen: { components in
            guard components == ["child", "value"] else { return }
            try FileManager.default.moveItem(at: child, to: self.root.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: child, withDestinationURL: self.outside)
        })
        XCTAssertEqual(files, [.init(components: ["child", "value"], data: Data("inside".utf8))])
    }

    func testReplacementWithAnotherRegularFileIsRejected() throws {
        let original = selected.appendingPathComponent("value")
        let replacement = root.appendingPathComponent("replacement")
        try Data("original".utf8).write(to: original)
        try Data("replacement".utf8).write(to: replacement)
        XCTAssertThrowsError(try read(beforeOpen: { components in
            guard components == ["value"] else { return }
            try FileManager.default.moveItem(at: original, to: self.root.appendingPathComponent("moved-file"))
            try FileManager.default.moveItem(at: replacement, to: original)
        })) {
            XCTAssertEqual($0 as? StoreSafeFileTree.Failure, .invalidEntry)
        }
    }

    func testReplacementWithAnotherDirectoryIsRejected() throws {
        let original = selected.appendingPathComponent("child")
        let replacement = root.appendingPathComponent("replacement-directory")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        XCTAssertThrowsError(try read(beforeOpen: { components in
            guard components == ["child"] else { return }
            try FileManager.default.moveItem(at: original, to: self.root.appendingPathComponent("moved-directory"))
            try FileManager.default.moveItem(at: replacement, to: original)
        })) {
            XCTAssertEqual($0 as? StoreSafeFileTree.Failure, .invalidEntry)
        }
    }

    func testBudgetsAndCancellationFailWithoutPartialResults() throws {
        try Data("1234".utf8).write(to: selected.appendingPathComponent("value"))
        var limits = StoreSafeFileTree.Limits()
        limits.totalBytes = 3
        XCTAssertThrowsError(try read(limits: limits)) {
            XCTAssertEqual($0 as? StoreSafeFileTree.Failure, .limit)
        }
        XCTAssertThrowsError(try read(cancelled: { true })) {
            XCTAssertEqual($0 as? StoreSafeFileTree.Failure, .cancelled)
        }
    }

    func testNonDirectoryRootDescriptorIsRejected() throws {
        let fd = Darwin.open(outside.appendingPathComponent("value").path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        XCTAssertThrowsError(try StoreSafeFileTree.read(rootDirectoryFD: fd, includeFile: { _, _ in true }, descendDirectory: { _, _ in true }))
    }

    func testNegativeAndClosedRootDescriptorsAreRejected() throws {
        for fd in [Int32(-1), Int32(AT_FDCWD)] {
            XCTAssertThrowsError(try StoreSafeFileTree.read(rootDirectoryFD: fd, includeFile: { _, _ in true }, descendDirectory: { _, _ in true })) {
                XCTAssertEqual($0 as? StoreSafeFileTree.Failure, .invalidRoot)
            }
        }
        let fd = Darwin.open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        XCTAssertEqual(Darwin.close(fd), 0)
        XCTAssertThrowsError(try StoreSafeFileTree.read(rootDirectoryFD: fd, includeFile: { _, _ in true }, descendDirectory: { _, _ in true })) {
            XCTAssertEqual($0 as? StoreSafeFileTree.Failure, .invalidRoot)
        }
    }

    func testRepeatedReadsDoNotConsumeCallerDirectoryOffset() throws {
        try Data("inside".utf8).write(to: selected.appendingPathComponent("value"))
        let fd = Darwin.open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        let first = try StoreSafeFileTree.read(rootDirectoryFD: fd, includeFile: { _, _ in true }, descendDirectory: { _, _ in true })
        XCTAssertEqual(first, [.init(components: ["value"], data: Data("inside".utf8))])
        XCTAssertEqual(try StoreSafeFileTree.read(rootDirectoryFD: fd, includeFile: { _, _ in true }, descendDirectory: { _, _ in true }), first)
    }

    func testSelectionSkipsOpeningExcludedFilesAndDirectories() throws {
        try Data("keep".utf8).write(to: selected.appendingPathComponent("keep.json"))
        try Data(repeating: 7, count: 100).write(to: selected.appendingPathComponent("exclude.json"))
        let excluded = selected.appendingPathComponent("excluded-directory")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data("not read".utf8).write(to: excluded.appendingPathComponent("hidden.json"))
        var opened: [[String]] = []
        var limits = StoreSafeFileTree.Limits()
        limits.fileBytes = 4
        limits.totalBytes = 4
        let files = try read(limits: limits, includeFile: { path, metadata in
            path.last == "keep.json" && metadata.size == 4
        }, descendDirectory: { path, _ in
            path != ["excluded-directory"]
        }, beforeOpen: { opened.append($0) })
        XCTAssertEqual(files, [.init(components: ["keep.json"], data: Data("keep".utf8))])
        XCTAssertEqual(opened, [["keep.json"]])
    }

    func testFileSelectionChangingAfterInspectionFailsInsteadOfSkipping() throws {
        let file = selected.appendingPathComponent("value")
        try Data("inside".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try read(includeFile: { _, metadata in metadata.permissions & 0o200 != 0 },
                                      beforeOpen: { components in
            guard components == ["value"] else { return }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        })) {
            XCTAssertEqual($0 as? StoreSafeFileTree.Failure, .invalidEntry)
        }
    }

    func testDirectorySelectionChangingAfterInspectionFailsInsteadOfSkipping() throws {
        let directory = selected.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try read(descendDirectory: { _, metadata in metadata.permissions & 0o200 != 0 },
                                      beforeOpen: { components in
            guard components == ["child"] else { return }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        })) {
            XCTAssertEqual($0 as? StoreSafeFileTree.Failure, .invalidEntry)
        }
    }
}
