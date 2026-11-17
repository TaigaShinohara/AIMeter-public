import XCTest
import Foundation
import AIMeterCore
@testable import AIMeter

/// End-to-end coverage of the stage-4 vertical slice: saved selection →
/// identity record → verified scoped open → Codex collection → source
/// state → display state. Everything runs on synthetic fixtures in a
/// temporary directory; the bookmark operations are fakes whose bookmark
/// data is just the selected path, while identity capture and the scoped
/// open use the real filesystem implementations.
final class StoreCodexPipelineTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var sessions: URL { root.appendingPathComponent("sessions") }
    private var timestamp: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        suite = "AIMeter.StoreCodexPipelineTests." + UUID().uuidString
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

    private func row(input: Int, cached: Int = 0, output: Int = 0) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "payload": [
            "type": "token_count", "info": ["total_token_usage": ["input_tokens": input,
                      "cached_input_tokens": cached, "output_tokens": output]]]])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func writeLog(_ contents: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: directory.appendingPathComponent("log.jsonl"))
    }

    // One accepted record: (100 - 30) uncached + 10 output + 30 / 10 cached
    // share = 83 monthly tokens, matching StoreCodexCollectionTests.
    private func selectSessionsWithSingleRecord() throws -> StoreBookmarkStore {
        try writeLog(try row(input: 100, cached: 30, output: 10), in: sessions)
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCodexPipeline.sourceID)
        return store
    }

    func testCompleteRunFlowsFromSelectionToDisplayState() async throws {
        let store = try selectSessionsWithSingleRecord()
        let presentation = try await StoreCodexPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .measuredComplete)
        XCTAssertEqual(presentation.sourceStates[StoreCodexPipeline.sourceID], .measuredComplete)
        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertTrue(presentation.missingSources.isEmpty)
        XCTAssertEqual(presentation.data?.openaiUsedTokens, 83)
        XCTAssertEqual(presentation.data?.source, "store_selected_sources")
    }

    func testMeasuredZeroIsPresentedAsData() async throws {
        try writeLog(try row(input: 0), in: sessions)
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCodexPipeline.sourceID)
        let presentation = try await StoreCodexPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .measuredComplete)
        XCTAssertEqual(presentation.data?.openaiUsedTokens, 0)
    }

    func testUnselectedSourceProducesNoData() async throws {
        try writeLog(try row(input: 100, cached: 30, output: 10), in: sessions)
        let presentation = try await StoreCodexPipeline(bookmarks: bookmarks()).collect()
        XCTAssertEqual(presentation.displayState, .notSelected)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.data)
    }

    func testSelectionWithoutIdentityRecordNeedsReselection() async throws {
        try writeLog(try row(input: 100, cached: 30, output: 10), in: sessions)
        let store = bookmarks(captureIdentity: { _ in nil })
        try store.save(sessions, sourceID: StoreCodexPipeline.sourceID)
        XCTAssertNil(store.identity(sourceID: StoreCodexPipeline.sourceID))
        let presentation = try await StoreCodexPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .needsReselection)
        XCTAssertNil(presentation.data)
    }

    func testReplacedTargetNeedsReselectionAndYieldsNoData() async throws {
        let store = try selectSessionsWithSingleRecord()
        // The selected directory is moved away and a different directory
        // with different contents takes its path before the run.
        let retained = root.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: sessions, to: retained)
        try writeLog(try row(input: 999), in: sessions)
        let presentation = try await StoreCodexPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .needsReselection)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.data)
    }

    func testEmptyTargetIsNoDataNotZero() async throws {
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCodexPipeline.sourceID)
        let presentation = try await StoreCodexPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .noData)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.data)
    }

    func testOnlyMalformedRecordsAreUnparseable() async throws {
        let invalid = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{}}}"
        try writeLog(invalid, in: sessions)
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCodexPipeline.sourceID)
        let presentation = try await StoreCodexPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .unparseable)
        XCTAssertNil(presentation.data)
    }

    func testPartialRunPresentsMeasuredPartialWithData() async throws {
        let invalidUsage = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\"invalid\"}}}}"
        try writeLog(try row(input: 100, cached: 30, output: 10) + "\n" + invalidUsage, in: sessions)
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCodexPipeline.sourceID)
        let presentation = try await StoreCodexPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .measuredPartial)
        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertTrue(presentation.missingSources.isEmpty)
        XCTAssertEqual(presentation.data?.openaiUsedTokens, 83)
    }

    func testQuotaOnlyRunIsMeasuredButWithholdsUsageData() async throws {
        let quota = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":25}}}}"
        try writeLog(quota, in: sessions)
        let store = bookmarks()
        try store.save(sessions, sourceID: StoreCodexPipeline.sourceID)
        let presentation = try await StoreCodexPipeline(bookmarks: store).collect()
        // The scan is measured and complete, but the payload carries no
        // usage totals; presenting it would render absent usage as zero.
        XCTAssertEqual(presentation.displayState, .measuredComplete)
        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertNil(presentation.data)
    }

    func testRemovalAfterSuccessReturnsToNotSelected() async throws {
        let store = try selectSessionsWithSingleRecord()
        let pipeline = StoreCodexPipeline(bookmarks: store)
        let first = try await pipeline.collect()
        XCTAssertEqual(first.data?.openaiUsedTokens, 83)
        store.remove(sourceID: StoreCodexPipeline.sourceID)
        let second = try await pipeline.collect()
        XCTAssertEqual(second.displayState, .notSelected)
        XCTAssertNil(second.data)
    }

    func testReselectionReadsTheNewTarget() async throws {
        let store = try selectSessionsWithSingleRecord()
        let pipeline = StoreCodexPipeline(bookmarks: store)
        let first = try await pipeline.collect()
        XCTAssertEqual(first.data?.openaiUsedTokens, 83)
        let other = root.appendingPathComponent("other")
        try writeLog(try row(input: 200), in: other)
        try store.save(other, sourceID: StoreCodexPipeline.sourceID)
        let second = try await pipeline.collect()
        XCTAssertEqual(second.displayState, .measuredComplete)
        XCTAssertEqual(second.data?.openaiUsedTokens, 200)
    }
}
