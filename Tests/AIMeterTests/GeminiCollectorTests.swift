import XCTest
import AIMeterCore
@testable import AIMeter

final class GeminiCollectorTests: XCTestCase {
    private var home: URL!
    private var timestamp: String!
    private var snapshot: URL { home.appendingPathComponent("usage.json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func event(_ label: String = "same", input: Int = 100, output: Int = 10) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "created_at": timestamp!, "input_tokens": input, "output_tokens": output,
            "metadata": ["label": label]
        ], options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    @discardableResult
    private func write(_ session: String, _ filename: String, rows: [String]) throws -> URL {
        let url = home.appendingPathComponent(".gemini/antigravity/brain/\(session)/.system_generated/logs/\(filename)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func collect(limits: BoundedInput.Limits = .init()) async throws -> LocalUsageData {
        try await LocalUsageCollector.collectAndSave(targetFileURL: snapshot, home: home, limits: limits)
    }

    func testCopiesWithReorderedJSONKeysCountOnceForUsageAndCost() async throws {
        let first = """
        {"created_at":"\(timestamp!)","input_tokens":1000000,"cache_read_tokens":500000,"output_tokens":250000,"metadata":{"a":1,"b":2}}
        """
        let reordered = """
        { "metadata": { "b": 2, "a": 1 }, "output_tokens": 250000, "cache_read_tokens": 500000, "input_tokens": 1000000, "created_at": "\(timestamp!)" }
        """
        try write("a", "transcript.jsonl", rows: [first])
        try write("a", "transcript_full.jsonl", rows: [reordered])

        let result = try await collect()
        for count in [result.geminiUsedTokens, result.geminiUsedByPeriod?.twoHours,
                      result.geminiUsedByPeriod?.fiveHours, result.geminiUsedByPeriod?.daily,
                      result.geminiUsedByPeriod?.weekly, result.geminiUsedByPeriod?.monthly] {
            XCTAssertEqual(count, 1_300_000)
        }
        XCTAssertEqual(try XCTUnwrap(result.geminiCostUSD), 2.66, accuracy: 0.000_001)
    }

    func testMultisetKeepsLargerMultiplicityInEitherFile() async throws {
        let row = try event()
        try write("more-in-short", "transcript.jsonl", rows: [row, row, row])
        try write("more-in-short", "transcript_full.jsonl", rows: [row, row])
        try write("more-in-full", "transcript.jsonl", rows: [row, row])
        try write("more-in-full", "transcript_full.jsonl", rows: [row, row, row])

        let result = try await collect()
        XCTAssertEqual(result.geminiUsedTokens, 660)
    }

    func testPartialOverlapKeepsEventsUniqueToEitherFileAndTheirRepetitions() async throws {
        let a = try event("a")
        let b = try event("b", input: 200, output: 20)
        let c = try event("c", input: 300, output: 30)
        try write("a", "transcript.jsonl", rows: [a, a, b])
        try write("a", "transcript_full.jsonl", rows: [a, c, c])

        let result = try await collect()
        XCTAssertEqual(result.geminiUsedTokens, 1_100)
    }

    func testSamePayloadInDifferentSessionsAndSingleFileRepetitionsRemain() async throws {
        let row = try event()
        try write("a", "transcript.jsonl", rows: [row])
        try write("a", "transcript_full.jsonl", rows: [row])
        try write("b", "transcript.jsonl", rows: [row])
        try write("b", "transcript_full.jsonl", rows: [row])
        try write("single", "transcript.jsonl", rows: [row, row, row])
        try write("full-only", "transcript_full.jsonl", rows: [row])

        let result = try await collect()
        XCTAssertEqual(result.geminiUsedTokens, 660)
    }

    func testDifferentCanonicalPayloadsAreIntentionallyKept() async throws {
        // Export metadata differs while timestamp and visible content match.
        // Without a guaranteed event ID these are deliberately not merged.
        let first = """
        {"created_at":"\(timestamp!)","input_tokens":100,"output_tokens":10,"content":"synthetic","export":"short"}
        """
        let second = first.replacingOccurrences(of: "\"short\"", with: "\"full\"")
        try write("a", "transcript.jsonl", rows: [first])
        try write("a", "transcript_full.jsonl", rows: [second])

        let result = try await collect()
        XCTAssertEqual(result.geminiUsedTokens, 220)
    }

    func testEstimatedRowsUseTheSameCopySelection() async throws {
        let row = "{\"created_at\":\"\(timestamp!)\",\"content\":\"abcdefghijklmnopqrst\"}"
        try write("a", "transcript.jsonl", rows: [row])
        try write("a", "transcript_full.jsonl", rows: [row])

        let result = try await collect()
        XCTAssertEqual(result.geminiUsedTokens, 5)
    }

    func testDeduplicatedEventsKeepTheirExistingRollingPeriod() async throws {
        let oldTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8 * 86400))
        let row = try event().replacingOccurrences(of: timestamp, with: oldTimestamp)
        try write("a", "transcript.jsonl", rows: [row])
        try write("a", "transcript_full.jsonl", rows: [row])

        let result = try await collect()
        XCTAssertEqual(result.geminiUsedByPeriod?.weekly, 0)
        XCTAssertEqual(result.geminiUsedByPeriod?.monthly, 110)
    }

    func testDuplicateFileStillConsumesTheSharedReadBudgetAndPreservesSnapshot() async throws {
        let row = try event()
        let first = try write("a", "transcript.jsonl", rows: [row])
        let full = try write("a", "transcript_full.jsonl", rows: [row])
        _ = try await collect()
        let previous = try Data(contentsOf: snapshot)
        var limits = BoundedInput.Limits()
        limits.totalBytes = previous.count + (try Data(contentsOf: first).count) + (try Data(contentsOf: full).count) - 1

        do {
            _ = try await collect(limits: limits)
            XCTFail("A duplicate file must not bypass the scan's read budget")
        } catch {
            guard case BoundedInput.Failure.limit = error else { return XCTFail("Expected input limit") }
        }
        XCTAssertEqual(try Data(contentsOf: snapshot), previous)
    }

    func testSessionFingerprintBudgetIsBoundedAndPreservesSnapshot() async throws {
        let row = try event()
        try write("a", "transcript.jsonl", rows: [row])
        try write("a", "transcript_full.jsonl", rows: [row])
        _ = try await collect()
        let previous = try Data(contentsOf: snapshot)
        let manyRows = try (0..<21).map { try event("event-\($0)") }
        try write("a", "transcript.jsonl", rows: manyRows)
        var limits = BoundedInput.Limits()
        limits.entries = 20

        do {
            _ = try await collect(limits: limits)
            XCTFail("Unique fingerprint state must have a finite budget")
        } catch {
            guard case BoundedInput.Failure.limit = error else { return XCTFail("Expected input limit") }
        }
        XCTAssertEqual(try Data(contentsOf: snapshot), previous)
    }

    func testInvalidNumbersInCounterpartStillFailAndPreserveSnapshot() async throws {
        let row = try event()
        try write("a", "transcript.jsonl", rows: [row])
        try write("a", "transcript_full.jsonl", rows: [row])
        _ = try await collect()
        let previous = try Data(contentsOf: snapshot)
        let invalid = "{\"created_at\":\"\(timestamp!)\",\"input_tokens\":-1,\"output_tokens\":10}"
        try write("a", "transcript_full.jsonl", rows: [row, invalid])

        do {
            _ = try await collect()
            XCTFail("The counterpart's numeric validation must not be bypassed")
        } catch {
            XCTAssertTrue(error is UsageNumber.Invalid)
        }
        XCTAssertEqual(try Data(contentsOf: snapshot), previous)
    }
}
