import XCTest
import Foundation
import AIMeterCore
@testable import AIMeter

/// End-to-end coverage of the stage-6 Gemini slice: saved selection →
/// identity record → verified scoped open → FD-scoped Gemini
/// collection → source state → display state. Everything runs on
/// synthetic fixtures in a temporary directory; the bookmark
/// operations are fakes whose bookmark data is just the selected
/// path, while identity capture and the scoped open use the real
/// filesystem implementations.
///
/// The slice's classification rule is pinned throughout: only the
/// separated chats totals can reach the presentation's data, as
/// measured values. Brain records — token-bearing or estimated —
/// never enter them, and the brain input is never opened.
final class StoreGeminiPipelineTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var tmp: URL { root.appendingPathComponent("tmp") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        suite = "AIMeter.StoreGeminiPipelineTests." + UUID().uuidString
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

    /// One chats message with a full token breakdown. Its effective
    /// usage is (input - cached) + output + cached / 10 and its cost
    /// follows the collector's per-token prices.
    private func chatFile(messages: [String]) -> String {
        "{\"messages\":[\(messages.joined(separator: ","))]}"
    }

    private func message(total: Int, input: Int, cached: Int, output: Int,
                         secondsAgo: TimeInterval = 60) -> String {
        "{\"timestamp\":\"\(stamp(secondsAgo))\",\"tokens\":{\"total\":\(total),\"input\":\(input),\"cached\":\(cached),\"output\":\(output)}}"
    }

    /// The standard message: effective 920,000, cost 1.5625 → 1.56.
    private func standardMessage() -> String {
        message(total: 1_100_000, input: 1_000_000, cached: 200_000, output: 100_000)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func chatsFile(in directory: URL) -> URL {
        directory.appendingPathComponent("a/chats/session.json")
    }

    private func selectTmpWithStandardMessage() throws -> StoreBookmarkStore {
        try write(chatFile(messages: [standardMessage()]), to: chatsFile(in: tmp))
        let store = bookmarks()
        try store.save(tmp, sourceID: StoreGeminiPipeline.sourceID)
        return store
    }

    func testCompleteRunYieldsMeasuredChatsData() async throws {
        let store = try selectTmpWithStandardMessage()
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .measuredComplete)
        XCTAssertEqual(presentation.sourceStates[StoreGeminiPipeline.sourceID], .measuredComplete)
        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertEqual(presentation.data?.geminiUsedByPeriod?.monthly, 920_000)
        XCTAssertEqual(presentation.data?.geminiUsedTokens, 920_000)
        XCTAssertEqual(presentation.data?.geminiCostUSD, 1.56)
        // The payload carries Gemini fields only; nothing leaks into
        // another service's frame.
        XCTAssertNil(presentation.data?.openaiUsedByPeriod)
        XCTAssertNil(presentation.data?.openaiUsedTokens)
    }

    func testMeasuredZeroIsAConfirmedZero() async throws {
        try write(chatFile(messages: [message(total: 0, input: 0, cached: 0, output: 0)]),
                  to: chatsFile(in: tmp))
        let store = bookmarks()
        try store.save(tmp, sourceID: StoreGeminiPipeline.sourceID)
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        // A valid record with zero tokens is a measured zero: the data
        // is present, unlike the no-data and unparseable cases below.
        XCTAssertEqual(presentation.displayState, .measuredComplete)
        XCTAssertEqual(presentation.data?.geminiUsedByPeriod?.monthly, 0)
        XCTAssertEqual(presentation.data?.geminiCostUSD, 0)
    }

    func testBrainTranscriptsInsideSelectionAreNotRead() async throws {
        let store = try selectTmpWithStandardMessage()
        // Brain transcripts — one token-bearing with far larger values,
        // one text-estimate record — sit inside the selected directory,
        // including one directly inside the chats component itself.
        // The chats scan reads only `.json` files, so neither can
        // enter the measured totals.
        let tokenRow = "{\"created_at\":\"\(stamp(60))\",\"input_tokens\":9000000,\"cache_read_tokens\":0,\"output_tokens\":9000000}"
        let estimateRow = "{\"created_at\":\"\(stamp(60))\",\"content\":\"abcdefgh\"}"
        try write(tokenRow, to: tmp.appendingPathComponent("antigravity/transcript.jsonl"))
        try write(estimateRow + "\n" + tokenRow, to: tmp.appendingPathComponent("a/chats/transcript.jsonl"))
        try write(tokenRow, to: tmp.appendingPathComponent("transcript_full.jsonl"))
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .measuredComplete)
        XCTAssertEqual(presentation.data?.geminiUsedByPeriod?.monthly, 920_000)
        XCTAssertEqual(presentation.data?.geminiCostUSD, 1.56)
    }

    func testPartialRunYieldsDataWithPartialState() async throws {
        try write(chatFile(messages: [standardMessage()]), to: chatsFile(in: tmp))
        try write("{bad}", to: tmp.appendingPathComponent("b/chats/broken.json"))
        let store = bookmarks()
        try store.save(tmp, sourceID: StoreGeminiPipeline.sourceID)
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .measuredPartial)
        XCTAssertEqual(presentation.data?.geminiUsedByPeriod?.monthly, 920_000)
    }

    func testMessageWithoutTokensIsNoData() async throws {
        // A message with no token breakdown at all cannot be separated
        // into a measured value; it is skipped, leaving no data rather
        // than a zero.
        let bare = "{\"timestamp\":\"\(stamp(60))\",\"role\":\"user\"}"
        try write(chatFile(messages: [bare]), to: chatsFile(in: tmp))
        let store = bookmarks()
        try store.save(tmp, sourceID: StoreGeminiPipeline.sourceID)
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .noData)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.data)
    }

    func testMessageWithIncompleteTokensIsUnparseable() async throws {
        // A total without its input/output breakdown cannot be
        // verified as a measured value, so the run is unparseable and
        // yields no data instead of presenting the total.
        let incomplete = "{\"timestamp\":\"\(stamp(60))\",\"tokens\":{\"total\":500}}"
        try write(chatFile(messages: [incomplete]), to: chatsFile(in: tmp))
        let store = bookmarks()
        try store.save(tmp, sourceID: StoreGeminiPipeline.sourceID)
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .unparseable)
        XCTAssertNil(presentation.data)
    }

    func testUnselectedSourceProducesNoData() async throws {
        try write(chatFile(messages: [standardMessage()]), to: chatsFile(in: tmp))
        let presentation = try await StoreGeminiPipeline(bookmarks: bookmarks()).collect()
        XCTAssertEqual(presentation.displayState, .notSelected)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.data)
    }

    func testSelectionWithoutIdentityRecordNeedsReselection() async throws {
        try write(chatFile(messages: [standardMessage()]), to: chatsFile(in: tmp))
        let store = bookmarks(captureIdentity: { _ in nil })
        try store.save(tmp, sourceID: StoreGeminiPipeline.sourceID)
        XCTAssertNil(store.identity(sourceID: StoreGeminiPipeline.sourceID))
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .needsReselection)
        XCTAssertNil(presentation.data)
    }

    func testReplacedTargetNeedsReselectionAndYieldsNoData() async throws {
        let store = try selectTmpWithStandardMessage()
        // The selected directory is moved away and a different
        // directory with different contents takes its path before the
        // run.
        let retained = root.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: tmp, to: retained)
        let other = message(total: 330, input: 300, cached: 60, output: 30)
        try write(chatFile(messages: [other, other, other]), to: chatsFile(in: tmp))
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .needsReselection)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.data)
    }

    func testEmptyTargetIsNoDataNotZero() async throws {
        let store = bookmarks()
        try store.save(tmp, sourceID: StoreGeminiPipeline.sourceID)
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .noData)
        XCTAssertEqual(presentation.coverage, .none)
        XCTAssertNil(presentation.data)
    }

    func testOnlyBrokenRecordsAreUnparseable() async throws {
        try write("{bad}", to: chatsFile(in: tmp))
        let store = bookmarks()
        try store.save(tmp, sourceID: StoreGeminiPipeline.sourceID)
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .unparseable)
        XCTAssertNil(presentation.data)
    }

    func testFilesOutsideTheSelectionAreNotRead() async throws {
        let store = try selectTmpWithStandardMessage()
        // A sibling directory outside the selection, a hidden
        // directory inside it that the walk skips, and a `.json` file
        // that is not under a `chats` component all carry a small
        // message that must never reach the result.
        let small = chatFile(messages: [message(total: 11, input: 10, cached: 0, output: 1)])
        try write(small, to: root.appendingPathComponent("outside/a/chats/session.json"))
        try write(small, to: tmp.appendingPathComponent(".hidden/chats/session.json"))
        try write(small, to: tmp.appendingPathComponent("a/other/session.json"))
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .measuredComplete)
        XCTAssertEqual(presentation.data?.geminiUsedByPeriod?.monthly, 920_000)
    }

    func testBrainSelectionAloneConnectsNothing() async throws {
        // Selecting only the brain input (a different source of the
        // same service) leaves the chats source unselected: the brain
        // input is not connected in this slice.
        try write(chatFile(messages: [standardMessage()]), to: chatsFile(in: tmp))
        let store = bookmarks()
        try store.save(tmp, sourceID: "gemini.brain")
        let presentation = try await StoreGeminiPipeline(bookmarks: store).collect()
        XCTAssertEqual(presentation.displayState, .notSelected)
        XCTAssertNil(presentation.data)
    }

    func testRemovalAfterSuccessReturnsToNotSelected() async throws {
        let store = try selectTmpWithStandardMessage()
        let pipeline = StoreGeminiPipeline(bookmarks: store)
        let first = try await pipeline.collect()
        XCTAssertEqual(first.data?.geminiUsedByPeriod?.monthly, 920_000)
        store.remove(sourceID: StoreGeminiPipeline.sourceID)
        let second = try await pipeline.collect()
        XCTAssertEqual(second.displayState, .notSelected)
        XCTAssertNil(second.data)
    }

    func testReselectionReadsTheNewTarget() async throws {
        let store = try selectTmpWithStandardMessage()
        let pipeline = StoreGeminiPipeline(bookmarks: store)
        let first = try await pipeline.collect()
        XCTAssertEqual(first.data?.geminiUsedByPeriod?.monthly, 920_000)
        let other = root.appendingPathComponent("other")
        let small = message(total: 330, input: 300, cached: 60, output: 30)
        try write(chatFile(messages: [small]), to: chatsFile(in: other))
        try store.save(other, sourceID: StoreGeminiPipeline.sourceID)
        let second = try await pipeline.collect()
        XCTAssertEqual(second.displayState, .measuredComplete)
        // (300 - 60) + 30 + 60 / 10 = 276.
        XCTAssertEqual(second.data?.geminiUsedByPeriod?.monthly, 276)
    }
}
