import XCTest
import Foundation
import Darwin
import AIMeterCore
@testable import AIMeter

final class StoreCursorCollectorTests: XCTestCase {
    private var root: URL!
    private var control: URL { root.appendingPathComponent("AgentStores/cursor_agent_stores/.control") }
    private let now = Date()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, date: Date? = nil) throws {
        let url = control.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not JSON and must not be read".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date ?? now.addingTimeInterval(-60)], ofItemAtPath: url.path)
    }
    private func collect(limits: StoreCursorCollector.Limits = .init(),
                         beforeOpen: ([String]) throws -> Void = { _ in }) throws -> StoreCursorCollector.Result {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreSafeFileTree.Failure.invalidRoot }
        defer { Darwin.close(fd) }
        return try StoreCursorCollector.collect(rootFD: fd, limits: limits, now: now, beforeOpen: beforeOpen)
    }
    func testUnselectedUnrecognizedEmptyAndValidZero() throws {
        XCTAssertEqual(try StoreCursorCollector.collect(rootFD: nil, now: now).state, .unselected)
        XCTAssertEqual(try collect().state, .notRecognized)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        XCTAssertEqual(try collect().state, .empty)
        try write("old.json", date: now.addingTimeInterval(-31 * 86400))
        let old = try collect()
        XCTAssertEqual(old.state, .complete)
        XCTAssertEqual(old.fileCounts?.monthly, 0)
    }
    func testCountsMatchDirectForRecognizedNonhiddenFixture() throws {
        try write("a.json")
        try write("nested/b.json", date: now.addingTimeInterval(-3 * 3600))
        let result = try collect()
        let existing = try LocalUsageCollector.collectStoreSources(["cursor.agentStores": root], home: root, now: now)
        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(result.fileCounts, existing.providers?["cursor"]?.usedByPeriod)
        XCTAssertEqual(result.fileCounts?.twoHours, 1)
        XCTAssertEqual(result.fileCounts?.fiveHours, 2)
    }
    func testFutureAndHiddenEntriesAreNotCounted() throws {
        try write("future.json", date: now.addingTimeInterval(60))
        XCTAssertEqual(try collect().state, .invalid)
        try write("valid.json")
        try write(".hidden.json")
        try write(".hidden/other.json")
        let result = try collect()
        XCTAssertEqual(result.state, .partial)
        XCTAssertEqual(result.fileCounts?.monthly, 1)
    }
    func testIntermediateSymlinkAndOutsideAreRejected() throws {
        let external = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("AgentStores"), withDestinationURL: external)
        XCTAssertEqual(try collect().state, .invalid)
    }
    func testReplacementAndLimitsFailClosed() throws {
        try write("one.json")
        let file = control.appendingPathComponent("one.json")
        let replacement = root.appendingPathComponent("replacement.json")
        try Data("replacement".utf8).write(to: replacement)
        XCTAssertThrowsError(try collect(beforeOpen: { path in
            guard path.last == "one.json" else { return }
            try FileManager.default.moveItem(at: file, to: self.root.appendingPathComponent("saved.json"))
            try FileManager.default.moveItem(at: replacement, to: file)
        }))
        var limits = StoreCursorCollector.Limits()
        limits.entries = 3
        XCTAssertThrowsError(try collect(limits: limits))
    }
    func testSymlinkNamedJSONIsInvalidAndNeverRead() throws {
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: control.appendingPathComponent("link.json"), withDestinationURL: root.appendingPathComponent("outside.json"))
        XCTAssertEqual(try collect().state, .invalid)
    }
}
