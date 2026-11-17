import XCTest
import Foundation
import AIMeterCore
@testable import AIMeter

/// End-to-end coverage of the stage-6 Copilot slice: saved selection →
/// identity record → verified scoped open → FD-scoped Copilot
/// collection → source state → display state. Everything runs on
/// synthetic fixtures in a temporary directory; the bookmark operations
/// are fakes whose bookmark data is just the selected path, while
/// identity capture and the scoped open use the real filesystem
/// implementations.
///
/// The slice's classification rule is pinned throughout: a Copilot run
/// never yields confirmed data. Values appear only as the
/// presentation's reference payload, under the `referenceOnly` display
/// state, with message counts and cumulative checkpoints kept in
/// separate frames.
final class StoreCopilotPipelineTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var sessions: URL { root.appendingPathComponent("sessions") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        suite = "AIMeter.StoreCopilotPipelineTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func bookmarks(captureIdentity: ((URL) -> StoreSelectionIdentity?)? = nil) -> StoreBookmarkStore {
        var operations = StoreBookmarkStore.Operations(
            create: { Data($0.path.utf8) },
            resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
            start: { _ in true },
            stop: { _ in })
        if let captureIdentity { operations.captureIdentity = captureIdentity }
        return StoreBookmarkStore(defaults: defaults, operations: operations)
    }

    private func stamp(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
    }

    private func message(secondsAgo: TimeInterval = 60) -> String {
        "{\"type\":\"user.message\",\"timestamp\":\"\(stamp(secondsAgo))\"}"
    }

    private func checkpoint(_ value: Int, secondsAgo: TimeInterval = 60) -> String {
        "{\"type\":\"session.usage_checkpoint\",\"timestamp\":\"\(stamp(secondsAgo))\",\"data\":{\"accountingSnapshot\":{\"totalPremiumRequestCost\":\(value)}}}"
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func eventsFile(in directory: URL) -> URL {
        directory.appendingPathComponent("s1/events.jsonl")
    }

    // One message one minute ago: it falls inside every period window,
    // so each period count is 1, matching StoreCopilotCollectorTests.
    private func selectSessionsWithSingleMessage() throws -> StoreBookmarkStore {
        try write(message(), to: eventsFile(in: sessions))
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        return store
    }

    func testCompleteRunClassifiesMessageCountsAsReference() async throws {
        let store = try selectSessionsWithSingleMessage()
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.sourceStates[StoreCopilotPipeline.sourceID], .referenceOnly)
        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertEqual(presentation.reference?.messageCounts?.twoHours, 1)
        XCTAssertEqual(presentation.reference?.messageCounts?.monthly, 1)
        XCTAssertEqual(presentation.reference?.checkpoints.count, 0)
        XCTAssertEqual(presentation.reference?.indeterminateCheckpoints, 0)
    }

    func testCheckpointsAreReferenceAndStaySeparateFromMessageCounts() async throws {
        // No messages at all; the events file carries only a cumulative
        // checkpoint, which has no proven period start.
        try write(checkpoint(42), to: eventsFile(in: sessions))
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertNil(presentation.reference?.messageCounts)
        XCTAssertEqual(presentation.reference?.checkpoints.count, 1)
        XCTAssertEqual(presentation.reference?.checkpoints.first?.premiumRequestCost, 42)
    }

    func testMessagesAndCheckpointsKeepSeparateFrames() async throws {
        try write([message(), checkpoint(7)].joined(separator: "\n"), to: eventsFile(in: sessions))
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        // The checkpoint's cumulative cost never enters the period
        // message counts, and the message never becomes a checkpoint.
        XCTAssertEqual(presentation.reference?.messageCounts?.monthly, 1)
        XCTAssertEqual(presentation.reference?.checkpoints.map(\.premiumRequestCost), [7])
    }

    func testZeroCheckpointIsAReferenceZeroNotAMeasuredZero() async throws {
        try write(checkpoint(0), to: eventsFile(in: sessions))
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        // The scan completed and the value is a real zero, but the slice
        // classifies it as reference: it must not surface as a measured
        // (confirmed) zero.
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.reference?.checkpoints.first?.premiumRequestCost, 0)
    }

    func testPartialRunClassifiesValidRowsAsReference() async throws {
        try write([message(), "{broken}"].joined(separator: "\n"), to: eventsFile(in: sessions))
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.reference?.messageCounts?.monthly, 1)
    }

    func testUnselectedSourceProducesNoReference() async throws {
        try write(message(), to: eventsFile(in: sessions))
        let presentation = try await StoreCopilotPipeline(bookmarks: bookmarks()).collect()
        XCTAssertEqual(presentation.displayState, .notSelected)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.reference)
    }

    func testSelectionWithoutIdentityRecordNeedsReselection() async throws {
        try write(message(), to: eventsFile(in: sessions))
        let store = bookmarks(captureIdentity: { _ in nil })
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        XCTAssertNil(store.identity(sourceID: StoreCopilotPipeline.sourceID))
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .needsReselection)
        XCTAssertNil(presentation.reference)
    }

    func testReplacedTargetNeedsReselectionAndYieldsNoReference() async throws {
        let store = try selectSessionsWithSingleMessage()
        // The selected directory is moved away and a different directory
        // with different contents takes its path before the run.
        let retained = root.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: sessions, to: retained)
        try write([message(), message(), message(), message(), message()].joined(separator: "\n"),
                  to: eventsFile(in: sessions))
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .needsReselection)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.reference)
    }

    func testEmptyTargetIsNoDataNotZero() async throws {
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .noData)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.reference)
    }

    func testOnlyBrokenRecordsAreUnparseable() async throws {
        try write("{broken}", to: eventsFile(in: sessions))
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .unparseable)
        XCTAssertNil(presentation.reference)
    }

    func testIndeterminateOnlyCheckpointsAreUnparseable() async throws {
        // Two checkpoints at the same latest timestamp disagree, so the
        // collector withholds the value entirely: nothing readable
        // remains, which is unparseable rather than data-absent.
        try write([checkpoint(2), checkpoint(3)].joined(separator: "\n"), to: eventsFile(in: sessions))
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCopilotPipeline.sourceID)
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .unparseable)
        XCTAssertNil(presentation.reference)
    }

    func testFilesOutsideTheSelectionAreNotRead() async throws {
        let store = try selectSessionsWithSingleMessage()
        // A sibling directory outside the selection, a hidden directory
        // inside it that the collector's walk skips, and a file whose
        // name is not events.jsonl all carry messages that must never
        // reach the result.
        let five = [message(), message(), message(), message(), message()].joined(separator: "\n")
        try write(five, to: root.appendingPathComponent("outside/events.jsonl"))
        try write(five, to: sessions.appendingPathComponent(".hidden/events.jsonl"))
        try write(five, to: sessions.appendingPathComponent("s1/notes.jsonl"))
        let presentation = try await StoreCopilotPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.reference?.messageCounts?.monthly, 1)
    }

    func testRemovalAfterSuccessReturnsToNotSelected() async throws {
        let store = try selectSessionsWithSingleMessage()
        let pipeline = StoreCopilotPipeline(bookmarks: store)
        let first = try await pipeline.collect()
        XCTAssertEqual(first.reference?.messageCounts?.monthly, 1)
        store.remove(sourceID: StoreCopilotPipeline.sourceID)
        let second = try await pipeline.collect()
        XCTAssertEqual(second.displayState, .notSelected)
        XCTAssertNil(second.reference)
    }

    func testReselectionReadsTheNewTarget() async throws {
        let store = try selectSessionsWithSingleMessage()
        let pipeline = StoreCopilotPipeline(bookmarks: store)
        let first = try await pipeline.collect()
        XCTAssertEqual(first.reference?.messageCounts?.monthly, 1)
        let other = root.appendingPathComponent("other")
        try write([message(), message(), message()].joined(separator: "\n"),
                  to: eventsFile(in: other))
        try store.save(other, sourceID: StoreCopilotPipeline.sourceID)
        let second = try await pipeline.collect()
        XCTAssertEqual(second.displayState, .referenceOnly)
        XCTAssertEqual(second.reference?.messageCounts?.monthly, 3)
    }
}
