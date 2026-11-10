import XCTest
import Foundation
import Darwin
import AIMeterCore
@testable import AIMeter

final class StoreCodexCollectionTests: XCTestCase {
    private var root: URL!
    private var sessions: URL { root.appendingPathComponent("sessions") }
    private var timestamp: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func row(input: Int, cached: Int = 0, output: Int = 0) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "payload": [
            "type": "token_count", "info": ["total_token_usage": ["input_tokens": input,
                      "cached_input_tokens": cached, "output_tokens": output]]]])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func store(limits: StoreSafeFileTree.Limits = .init(),
                       beforeOpen: ([String]) throws -> Void = { _ in }) throws -> LocalUsageCollector.StoreCodexOutcome {
        let fd = Darwin.open(sessions.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreSafeFileTree.Failure.invalidRoot }
        defer { Darwin.close(fd) }
        return try LocalUsageCollector.collectStoreCodex(rootFD: fd, limits: limits, beforeOpen: beforeOpen)
    }

    func testNoMatchingValidRecordsIsNotDetectedAndValidZeroIsComplete() throws {
        XCTAssertEqual(try store(), .notDetected)
        try Data("{\"type\":\"token_count\"}\n".utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        XCTAssertEqual(try store(), .notDetected)
        try Data((try row(input: 0)).utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .complete(result) = try store() else { return XCTFail("Expected a valid zero result") }
        XCTAssertEqual(result.openaiUsedTokens, 0)
    }

    func testMalformedCandidateAlongsideValidRecordsIsPartial() throws {
        let malformed = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{}}}"
        let contents = try row(input: 12) + "\n" + malformed + "\n"
        try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial result") }
        XCTAssertEqual(result.openaiUsedTokens, 12)
    }

    func testUnrelatedMarkerAndRateLimitOnlyEventDoNotMakeUsagePartial() throws {
        let message = "{\"payload\":{\"type\":\"message\",\"content\":\"token_count\"}}"
        let unrelated = "{\"type\":\"token_count\"}"
        let quota = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":25}}}}"
        let contents = try [row(input: 12), message, unrelated, quota].joined(separator: "\n")
        try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .complete(result) = try store() else { return XCTFail("Expected complete result") }
        XCTAssertEqual(result.openaiUsedTokens, 12)
        XCTAssertEqual(result.openaiServerUsedPercentByPeriod?.fiveHours, 25)
    }

    func testRateLimitOnlyDoesNotFabricateZeroUsage() throws {
        let quota = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":25}}}}"
        try Data(quota.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .quotaOnly(result, partial) = try store() else { return XCTFail("Expected quota only") }
        XCTAssertFalse(partial)
        XCTAssertNil(result.openaiUsedTokens)
        XCTAssertNil(result.openaiUsedByPeriod)
        XCTAssertNil(result.openaiCostUSD)
        XCTAssertEqual(result.openaiServerUsedPercentByPeriod?.fiveHours, 25)
    }

    func testQuotaOnlyWithInvalidUsageIsExplicitlyPartial() throws {
        let quota = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\"bad\",\"output_tokens\":0}},\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":25}}}}"
        try Data(quota.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .quotaOnly(result, partial) = try store() else { return XCTFail("Expected quota only") }
        XCTAssertTrue(partial)
        XCTAssertNil(result.openaiUsedTokens)
        XCTAssertNil(result.openaiUsedByPeriod)
        XCTAssertNil(result.openaiCostUSD)
        XCTAssertEqual(result.openaiServerUsedPercentByPeriod?.fiveHours, 25)
    }

    func testMalformedUsageStopsSameFileWithoutShiftingLaterPeriods() throws {
        let formatter = ISO8601DateFormatter()
        let older = formatter.string(from: Date().addingTimeInterval(-2 * 86400))
        let recent = formatter.string(from: Date().addingTimeInterval(-60))
        func usage(_ time: String, _ count: Int) -> String {
            "{\"timestamp\":\"\(time)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(count),\"output_tokens\":0}}}}"
        }
        let invalid = "{\"timestamp\":\"\(recent)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\"bad\",\"output_tokens\":0}},\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":55}}}}"
        let first = [usage(older, 100), invalid, usage(recent, 200)].joined(separator: "\n")
        try Data(first.utf8).write(to: sessions.appendingPathComponent("first.jsonl"))
        try Data(usage(recent, 7).utf8).write(to: sessions.appendingPathComponent("second.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial") }
        XCTAssertEqual(result.openaiUsedTokens, 107)
        XCTAssertEqual(result.openaiUsedByPeriod?.daily, 7)
        XCTAssertEqual(result.openaiServerUsedPercentByPeriod?.fiveHours, 55)
    }

    func testUnparseableLineStopsSameFileAndKeepsPriorUsage() throws {
        let contents = try [row(input: 12), "{invalid-json", row(input: 200)].joined(separator: "\n")
        try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial") }
        XCTAssertEqual(result.openaiUsedTokens, 12)
    }

    func testMalformedQuotaOnlyDoesNotStopValidUsage() throws {
        let badQuota = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":\"bad\"}}}}"
        let contents = try [row(input: 12), badQuota, row(input: 20)].joined(separator: "\n")
        try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial") }
        XCTAssertEqual(result.openaiUsedTokens, 20)
    }

    func testInvalidUsageOrMalformedJSONDoesNotDiscardValidUsage() throws {
        let invalidUsage = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\"invalid\"}}}}"
        let invalidJSON = "{\"payload\":{\"type\":\"token_count\""
        let contents = try [row(input: 12), invalidUsage, invalidJSON].joined(separator: "\n")
        try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial result") }
        XCTAssertEqual(result.openaiUsedTokens, 12)
    }

    func testOnlyMalformedEventsAreInvalidRatherThanNotDetected() throws {
        let invalid = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{}}}"
        try Data(invalid.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        XCTAssertEqual(try store(), .invalidData)
    }

    func testInvalidQuotaDoesNotDiscardValidUsageOrEarlierQuota() throws {
        let goodQuota = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":25}}}}"
        let badQuota = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":12,\"output_tokens\":0}},\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":\"invalid\"}}}}"
        try Data((goodQuota + "\n" + badQuota).utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial result") }
        XCTAssertEqual(result.openaiUsedTokens, 12)
        XCTAssertEqual(result.openaiServerUsedPercentByPeriod?.fiveHours, 25)
    }

    func testEscapedEventTypeIsDecodedAndCollected() throws {
        let escaped = try row(input: 23).replacingOccurrences(of: "\"token_count\"", with: "\"token_c\\u006funt\"")
        try Data(escaped.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .complete(result) = try store() else { return XCTFail("Expected escaped token_count") }
        XCTAssertEqual(result.openaiUsedTokens, 23)
    }

    func testNewestQuotaUsesActualTimeAcrossOffsetsAndFractionalSeconds() throws {
        let offset = ISO8601DateFormatter()
        offset.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(secondsFromGMT: 0)
        utc.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let older = offset.string(from: Date().addingTimeInterval(-120))
        let newer = utc.string(from: Date().addingTimeInterval(-60))
        func quota(_ time: String, _ percent: Int) -> String {
            "{\"timestamp\":\"\(time)\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":\(percent)}}}}"
        }
        let contents = try [row(input: 2), quota(older, 80), quota(newer, 20)].joined(separator: "\n")
        try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .complete(result) = try store() else { return XCTFail("Expected complete result") }
        XCTAssertEqual(result.openaiServerUsedPercentByPeriod?.fiveHours, 20)
    }

    func testNullQuotaDoesNotInventZeroPercent() throws {
        let value = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":12,\"output_tokens\":0}},\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":null}}}}"
        try Data(value.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial result") }
        XCTAssertEqual(result.openaiUsedTokens, 12)
        XCTAssertNil(result.openaiServerUsedPercentByPeriod?.fiveHours)
    }

    func testEmptyQuotaCannotEraseEarlierValidQuota() throws {
        let formatter = ISO8601DateFormatter()
        let older = formatter.string(from: Date().addingTimeInterval(-120))
        let newer = formatter.string(from: Date().addingTimeInterval(-60))
        let good = "{\"timestamp\":\"\(older)\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":25}}}}"
        for empty in ["{}", "{\"primary\":{}}", "{\"primary\":null}"] {
            let value = "{\"timestamp\":\"\(newer)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":12,\"output_tokens\":0}},\"rate_limits\":\(empty)}}"
            try Data((good + "\n" + value).utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
            guard case let .partial(result) = try store() else { return XCTFail("Expected partial result for \(empty)") }
            XCTAssertEqual(result.openaiUsedTokens, 12)
            XCTAssertEqual(result.openaiServerUsedPercentByPeriod?.fiveHours, 25)
        }
    }

    func testEmptyWindowIsPartialEvenIfAnotherWindowIsUsable() throws {
        let value = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":12,\"output_tokens\":0}},\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":25},\"secondary\":{}}}}"
        try Data(value.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial result") }
        XCTAssertEqual(result.openaiUsedTokens, 12)
        XCTAssertEqual(result.openaiServerUsedPercentByPeriod?.fiveHours, 25)
    }

    func testIncompleteAndInconsistentUsageCannotBecomeZeroOrComplete() throws {
        let variants = [
            "{\"output_tokens\":0}",
            "{\"input_tokens\":0}",
            "{\"input_tokens\":0,\"output_tokens\":0,\"cached_input_tokens\":1}"
        ]
        for totals in variants {
            let invalid = "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(totals)}}}"
            try Data(invalid.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
            XCTAssertEqual(try store(), .invalidData)
            let contents = try row(input: 12) + "\n" + invalid
            try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
            guard case let .partial(result) = try store() else { return XCTFail("Expected partial result for \(totals)") }
            XCTAssertEqual(result.openaiUsedTokens, 12)
        }
    }

    func testCounterRegressionAndImpossibleCachedDeltaStopThatFile() throws {
        let invalid: [(input: Int, cached: Int, output: Int)] = [
            (99, 30, 10),  // input decreased
            (100, 29, 10), // cached decreased
            (100, 30, 9),  // output decreased
            (101, 35, 10)  // cached delta exceeds input delta
        ]
        for value in invalid {
            let contents = try [row(input: 100, cached: 30, output: 10),
                                row(input: value.input, cached: value.cached, output: value.output),
                                row(input: 200, cached: 40, output: 20)].joined(separator: "\n")
            try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
            guard case let .partial(result) = try store() else { return XCTFail("Expected partial result for \(value)") }
            // Only the first, trustworthy cumulative value is included.
            XCTAssertEqual(result.openaiUsedTokens, 83)
        }
    }

    func testCounterDiscontinuityDoesNotPreventCollectingOtherFiles() async throws {
        let discontinuous = try [row(input: 100), row(input: 80), row(input: 130)].joined(separator: "\n")
        try Data(discontinuous.utf8).write(to: sessions.appendingPathComponent("first.jsonl"))
        try Data((try row(input: 7)).utf8).write(to: sessions.appendingPathComponent("second.jsonl"))
        guard case let .partial(result) = try store() else { return XCTFail("Expected partial result") }
        XCTAssertEqual(result.openaiUsedTokens, 107)

        // The direct-distribution collector retains its prior clamping policy.
        let direct = try await LocalUsageCollector.collectAndSave(targetFileURL: root.appendingPathComponent("result.json"),
            customPaths: ["openai": sessions.path], enabledProviderIDs: ["openai"], home: root)
        XCTAssertEqual(direct.openaiUsedTokens, 157)
    }

    func testConsistentCounterIncrementsRemainComplete() throws {
        let contents = try [row(input: 100, cached: 30, output: 10),
                            row(input: 110, cached: 35, output: 15)].joined(separator: "\n")
        try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        guard case let .complete(result) = try store() else { return XCTFail("Expected complete result") }
        XCTAssertEqual(result.openaiUsedTokens, 93)
    }

    func testDirectAndStoreMatchAndUnrelatedFilesAreNotOpened() async throws {
        let contents = try row(input: 100, cached: 20, output: 10) + "\n" + row(input: 150, cached: 30, output: 20)
        try Data(contents.utf8).write(to: sessions.appendingPathComponent("log.jsonl"))
        try Data(repeating: 7, count: 2048).write(to: sessions.appendingPathComponent("ignored.txt"))
        var opened: [[String]] = []
        guard case let .complete(storeResult) = try store(beforeOpen: { opened.append($0) }) else {
            return XCTFail("Expected complete result")
        }
        let direct = try await LocalUsageCollector.collectAndSave(targetFileURL: root.appendingPathComponent("result.json"),
            customPaths: ["openai": sessions.path], enabledProviderIDs: ["openai"], home: root)
        XCTAssertEqual(opened, [["log.jsonl"]])
        XCTAssertEqual(storeResult.openaiUsedTokens, direct.openaiUsedTokens)
        XCTAssertEqual(storeResult.openaiUsedByPeriod, direct.openaiUsedByPeriod)
        XCTAssertEqual(storeResult.openaiCostUSD, direct.openaiCostUSD)
        XCTAssertEqual(storeResult.openaiServerUsedPercentByPeriod, direct.openaiServerUsedPercentByPeriod)
    }

    func testReplacementBeforeOpenFailsWithoutReturningData() throws {
        let file = sessions.appendingPathComponent("log.jsonl")
        try Data((try row(input: 20)).utf8).write(to: file)
        let replacement = root.appendingPathComponent("replacement")
        try Data((try row(input: 99)).utf8).write(to: replacement)
        XCTAssertThrowsError(try store(beforeOpen: { path in
            guard path == ["log.jsonl"] else { return }
            try FileManager.default.moveItem(at: file, to: self.root.appendingPathComponent("old"))
            try FileManager.default.moveItem(at: replacement, to: file)
        }))
    }

    func testOversizedLineFailsEvenWhenItAppearsUnrelated() throws {
        let file = sessions.appendingPathComponent("log.jsonl")
        var limits = StoreSafeFileTree.Limits()
        limits.lineBytes = 256
        let unrelated = String(repeating: "x", count: 500) + "\n"
        try Data((unrelated + (try row(input: 4))).utf8).write(to: file)
        XCTAssertThrowsError(try store(limits: limits))
        try Data((String(repeating: "x", count: 500) + "\"token_count\"").utf8).write(to: file)
        XCTAssertThrowsError(try store(limits: limits))
    }
}
