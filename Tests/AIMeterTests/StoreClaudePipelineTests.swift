import XCTest
import Foundation
import AIMeterCore
@testable import AIMeter

/// End-to-end coverage of the stage-6 Claude slice: saved selection →
/// identity record → verified scoped open → FD-scoped Claude collection
/// → source state → display state. Everything runs on synthetic
/// fixtures in a temporary directory; the bookmark operations are fakes
/// whose bookmark data is just the selected path, while identity capture
/// and the scoped open use the real filesystem implementations.
///
/// The slice's classification rule is pinned throughout: a Claude run
/// never yields confirmed data. Values appear only as the presentation's
/// reference payload, under the `referenceOnly` display state.
final class StoreClaudePipelineTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var logs: URL { root.appendingPathComponent("logs") }
    private var timestamp: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        suite = "AIMeter.StoreClaudePipelineTests." + UUID().uuidString
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

    private func row(input: Int, output: Int, cached: Int) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "message": [
            "usage": ["input_tokens": input, "output_tokens": output,
                      "cache_read_input_tokens": cached]]])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    // One accepted record: 100 input + 20 output + 50 / 10 cached share
    // = 125 monthly tokens, matching StoreClaudeCollectorTests.
    private func selectLogsWithSingleRecord() throws -> StoreBookmarkStore {
        try write(try row(input: 100, output: 20, cached: 50),
                  to: logs.appendingPathComponent("projects/session.jsonl"))
        let store = bookmarks()
        try store.save(logs, sourceID: StoreClaudePipeline.sourceID)
        return store
    }

    func testCompleteRunClassifiesLogTotalsAsReference() async throws {
        let store = try selectLogsWithSingleRecord()
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.sourceStates[StoreClaudePipeline.sourceID], .referenceOnly)
        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertEqual(presentation.reference?.periodUsage?.monthly, 125)
        XCTAssertNil(presentation.reference?.projects)
    }

    func testProjectsTotalsAreReferenceAndStayOutOfPeriodTotals() async throws {
        // No log records at all; the settings JSON inside the selected
        // directory carries only the undated projects totals.
        try write("{\"projects\":{\"synthetic\":{\"lastTotalInputTokens\":100,\"lastTotalOutputTokens\":20,\"lastTotalCacheCreationInputTokens\":10,\"lastTotalCacheReadInputTokens\":50,\"lastCost\":1.5}}}",
                  to: logs.appendingPathComponent(".claude.json"))
        let store = bookmarks()
        try store.save(logs, sourceID: StoreClaudePipeline.sourceID)
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.reference?.projects, StoreClaudeCollector.Estimate(tokens: 135, cost: 1.5))
        XCTAssertNil(presentation.reference?.periodUsage)
    }

    func testZeroRowIsAReferenceZeroNotAMeasuredZero() async throws {
        try write(try row(input: 0, output: 0, cached: 0),
                  to: logs.appendingPathComponent("session.jsonl"))
        let store = bookmarks()
        try store.save(logs, sourceID: StoreClaudePipeline.sourceID)
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        // The scan completed and the value is a real zero, but the slice
        // classifies it as reference: it must not surface as a measured
        // (confirmed) zero.
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.reference?.periodUsage?.monthly, 0)
    }

    func testPartialRunClassifiesValidRowsAsReference() async throws {
        try write(try row(input: 100, output: 20, cached: 50) + "\n{broken}",
                  to: logs.appendingPathComponent("session.jsonl"))
        let store = bookmarks()
        try store.save(logs, sourceID: StoreClaudePipeline.sourceID)
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.reference?.periodUsage?.monthly, 125)
    }

    func testUnselectedSourceProducesNoReference() async throws {
        try write(try row(input: 100, output: 20, cached: 50),
                  to: logs.appendingPathComponent("session.jsonl"))
        let presentation = try await StoreClaudePipeline(bookmarks: bookmarks()).collect()
        XCTAssertEqual(presentation.displayState, .notSelected)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.reference)
    }

    func testSettingsSelectionAloneDoesNotConnect() async throws {
        // The claude.settings file selection is not part of this slice:
        // saving it must not make the logs pipeline produce anything.
        let settings = root.appendingPathComponent("settings.json")
        try write("{\"projects\":{\"synthetic\":{\"lastTotalInputTokens\":100,\"lastTotalOutputTokens\":20,\"lastTotalCacheCreationInputTokens\":10,\"lastTotalCacheReadInputTokens\":50,\"lastCost\":1.5}}}", to: settings)
        let store = bookmarks()
        try store.save(settings, sourceID: "claude.settings")
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .notSelected)
        XCTAssertNil(presentation.reference)
    }

    func testSelectionWithoutIdentityRecordNeedsReselection() async throws {
        try write(try row(input: 100, output: 20, cached: 50),
                  to: logs.appendingPathComponent("session.jsonl"))
        let store = bookmarks(captureIdentity: { _ in nil })
        try store.save(logs, sourceID: StoreClaudePipeline.sourceID)
        XCTAssertNil(store.identity(sourceID: StoreClaudePipeline.sourceID))
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .needsReselection)
        XCTAssertNil(presentation.reference)
    }

    func testReplacedTargetNeedsReselectionAndYieldsNoReference() async throws {
        let store = try selectLogsWithSingleRecord()
        // The selected directory is moved away and a different directory
        // with different contents takes its path before the run.
        let retained = root.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: logs, to: retained)
        try write(try row(input: 999_999, output: 999_999, cached: 0),
                  to: logs.appendingPathComponent("session.jsonl"))
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .needsReselection)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.reference)
    }

    func testEmptyTargetIsNoDataNotZero() async throws {
        let store = bookmarks()
        try store.save(logs, sourceID: StoreClaudePipeline.sourceID)
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .noData)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.reference)
    }

    func testOnlyBrokenRecordsAreUnparseable() async throws {
        try write("{broken}", to: logs.appendingPathComponent("session.jsonl"))
        let store = bookmarks()
        try store.save(logs, sourceID: StoreClaudePipeline.sourceID)
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .unparseable)
        XCTAssertNil(presentation.reference)
    }

    func testFilesOutsideTheSelectionAreNotRead() async throws {
        let store = try selectLogsWithSingleRecord()
        // A sibling directory outside the selection, and a hidden file
        // inside it that the collector's walk skips, both carry values
        // that must never reach the result.
        try write(try row(input: 999_999, output: 999_999, cached: 0),
                  to: root.appendingPathComponent("outside/session.jsonl"))
        try write(try row(input: 999_999, output: 999_999, cached: 0),
                  to: logs.appendingPathComponent(".hidden.jsonl"))
        let presentation = try await StoreClaudePipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .referenceOnly)
        XCTAssertEqual(presentation.reference?.periodUsage?.monthly, 125)
    }

    func testRemovalAfterSuccessReturnsToNotSelected() async throws {
        let store = try selectLogsWithSingleRecord()
        let pipeline = StoreClaudePipeline(bookmarks: store)
        let first = try await pipeline.collect()
        XCTAssertEqual(first.reference?.periodUsage?.monthly, 125)
        store.remove(sourceID: StoreClaudePipeline.sourceID)
        let second = try await pipeline.collect()
        XCTAssertEqual(second.displayState, .notSelected)
        XCTAssertNil(second.reference)
    }

    func testReselectionReadsTheNewTarget() async throws {
        let store = try selectLogsWithSingleRecord()
        let pipeline = StoreClaudePipeline(bookmarks: store)
        let first = try await pipeline.collect()
        XCTAssertEqual(first.reference?.periodUsage?.monthly, 125)
        let other = root.appendingPathComponent("other")
        try write(try row(input: 200, output: 0, cached: 0),
                  to: other.appendingPathComponent("session.jsonl"))
        try store.save(other, sourceID: StoreClaudePipeline.sourceID)
        let second = try await pipeline.collect()
        XCTAssertEqual(second.displayState, .referenceOnly)
        XCTAssertEqual(second.reference?.periodUsage?.monthly, 200)
    }
}
