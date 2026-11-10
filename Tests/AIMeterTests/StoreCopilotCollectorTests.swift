import XCTest
import Foundation
import Darwin
import AIMeterCore
@testable import AIMeter

final class StoreCopilotCollectorTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private func stamp(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func collect(_ limits: StoreCopilotCollector.Limits = .init()) throws -> StoreCopilotCollector.Result {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreSafeFileTree.Failure.invalidRoot }
        defer { Darwin.close(fd) }
        return try StoreCopilotCollector.collect(rootFD: fd, limits: limits, now: now)
    }
    private func message(_ ago: TimeInterval) -> String {
        "{\"type\":\"user.message\",\"timestamp\":\"\(stamp(ago))\"}"
    }
    private func checkpoint(_ ago: TimeInterval, _ value: Int) -> String {
        "{\"type\":\"session.usage_checkpoint\",\"timestamp\":\"\(stamp(ago))\",\"data\":{\"accountingSnapshot\":{\"totalPremiumRequestCost\":\(value)}}}"
    }
    func testMessagePeriodsMatchExistingCollector() throws {
        try write("s/events.jsonl", [message(60), message(3 * 3600), message(8 * 86400)].joined(separator: "\n"))
        let result = try collect()
        let existing = try LocalUsageCollector.collectStoreSources(["copilot.sessions": root], home: root, now: now)
        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(result.messageCounts, existing.providers?["copilot"]?.usedByPeriod)
        XCTAssertEqual(result.messageCounts?.twoHours, 1)
        XCTAssertEqual(result.messageCounts?.fiveHours, 2)
        XCTAssertEqual(result.messageCounts?.weekly, 2)
        XCTAssertEqual(result.messageCounts?.monthly, 3)
    }
    func testCheckpointUsesOwnTimeAndIsIndependentOfOrder() throws {
        let old = checkpoint(9 * 86400, 100), new = checkpoint(60, 1)
        try write("s/events.jsonl", old + "\n" + new)
        let forward = try collect()
        try write("s/events.jsonl", new + "\n" + old)
        let reverse = try collect()
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.state, .complete)
        XCTAssertNil(forward.messageCounts)
        XCTAssertEqual(forward.checkpoints.count, 1)
        XCTAssertEqual(forward.checkpoints.first?.premiumRequestCost, 1)
        XCTAssertEqual(forward.checkpoints.first?.timestamp, LocalUsageCollector.parseISODate(stamp(60)))
    }
    func testUnselectedMissingInvalidPartialAndExplicitZero() throws {
        XCTAssertEqual(try StoreCopilotCollector.collect(rootFD: nil, now: now).state, .unselected)
        XCTAssertEqual(try collect().state, .notDetected)
        try write("s/events.jsonl", "{\"type\":\"other\"}")
        XCTAssertEqual(try collect().state, .notDetected)
        let bad = "{\"type\":\"session.usage_checkpoint\",\"timestamp\":\"\(stamp(60))\",\"data\":{\"accountingSnapshot\":{\"totalPremiumRequestCost\":null}}}"
        try write("s/events.jsonl", bad)
        XCTAssertEqual(try collect().state, .invalid)
        try write("s/events.jsonl", checkpoint(60, 0))
        let zero = try collect()
        XCTAssertEqual(zero.state, .complete)
        XCTAssertEqual(zero.checkpoints.first?.premiumRequestCost, 0)
        XCTAssertNil(zero.messageCounts)
        try write("s/events.jsonl", checkpoint(60, 0) + "\n" + bad)
        XCTAssertEqual(try collect().state, .partial)
    }
    func testOlderTimestampConflictsAreIndependentOfRowOrder() throws {
        let first = checkpoint(3600, 2), conflict = checkpoint(3600, 3), latest = checkpoint(60, 9)
        try write("s/events.jsonl", [first, latest, conflict].joined(separator: "\n"))
        let forward = try collect()
        try write("s/events.jsonl", [conflict, first, latest].joined(separator: "\n"))
        let reverse = try collect()
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.state, .partial)
        XCTAssertEqual(forward.checkpoints.first?.premiumRequestCost, 9)
        XCTAssertEqual(forward.indeterminateCheckpoints, 0)
    }
    func testLatestConflictIsIndeterminatePerFile() throws {
        let first = checkpoint(60, 2), conflict = checkpoint(60, 3)
        try write("a/events.jsonl", first + "\n" + conflict)
        try write("b/events.jsonl", checkpoint(60, 5))
        let forward = try collect()
        try write("a/events.jsonl", conflict + "\n" + first)
        let reverse = try collect()
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.state, .partial)
        XCTAssertEqual(forward.indeterminateCheckpoints, 1)
        XCTAssertEqual(forward.checkpoints.map(\.premiumRequestCost), [5])
    }
    func testCurrentAndFutureEventsHaveDifferentStates() throws {
        try write("s/events.jsonl", message(0))
        XCTAssertEqual(try collect().state, .complete)
        try write("s/events.jsonl", message(-2))
        XCTAssertEqual(try collect().state, .invalid)
        try write("s/events.jsonl", message(0) + "\n" + checkpoint(-2, 1))
        XCTAssertEqual(try collect().state, .partial)
    }
    func testCheckpointTimestampTrackingIsBounded() throws {
        try write("s/events.jsonl", [checkpoint(10, 1), checkpoint(20, 2), checkpoint(30, 3)].joined(separator: "\n"))
        var limits = StoreCopilotCollector.Limits()
        limits.tree.entries = 2
        XCTAssertThrowsError(try collect(limits))
    }
    func testLimitsAndSelection() throws {
        let line = message(60)
        try write("s/events.jsonl", line)
        try write("s/ignored.jsonl", String(repeating: "x", count: 10_000))
        var limits = StoreCopilotCollector.Limits()
        limits.tree.totalBytes = line.utf8.count
        XCTAssertEqual(try collect(limits).state, .complete)
        limits.tree.totalBytes -= 1
        XCTAssertThrowsError(try collect(limits))
        limits.tree.totalBytes = 10_000
        limits.tree.lineBytes = line.utf8.count - 1
        XCTAssertThrowsError(try collect(limits))
    }
}
