import XCTest
import AIMeterCore

final class AntigravityQuotaParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func bucket(_ id: String = "gemini-weekly", fraction: Any? = 0.75,
                        extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["bucketId": id, "displayName": id]
        result["remainingFraction"] = fraction
        result.merge(extra, uniquingKeysWith: { _, new in new })
        return result
    }

    private func summary(_ buckets: [[String: Any]]) throws -> Data {
        try data(["response": ["groups": [["displayName": "Gemini Models", "buckets": buckets]]]])
    }

    private func model(_ id: String = "gemini-pro", fraction: Any? = 0.75,
                       reset: Any? = nil) -> [String: Any] {
        var quota: [String: Any] = [:]
        quota["remainingFraction"] = fraction
        quota["resetTime"] = reset
        return ["modelOrAlias": ["model": id], "label": "Gemini Pro", "quotaInfo": quota]
    }

    private func status(_ models: [[String: Any]]) throws -> Data {
        try data(["userStatus": ["email": "synthetic@example.invalid",
                                  "cascadeModelConfigData": ["clientModelConfigs": models]]])
    }

    private func assertFailure(_ expected: AntigravityQuotaParser.Failure,
                               _ operation: () throws -> AntigravityQuotaSnapshot,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? AntigravityQuotaParser.Failure, expected, file: file, line: line)
        }
    }

    func testSummaryPreservesBothFamiliesAndExplicitCadences() throws {
        let payload: [String: Any] = ["response": ["groups": [
            ["displayName": "Gemini Models", "buckets": [
                bucket("gemini-session", fraction: 0, extra: ["window": "session"]),
                bucket("gemini-weekly", fraction: 1, extra: ["window": "weekly"])
            ]],
            ["displayName": "Claude and GPT models", "buckets": [
                bucket("claude-gpt-session", fraction: 0.25),
                bucket("claude-gpt-weekly", fraction: 0.5)
            ]]
        ]]]
        let result = try AntigravityQuotaParser.parseSummary(data: data(payload), fetchedAt: now)
        XCTAssertEqual(result.fetchedAt, now)
        XCTAssertEqual(result.windows.map(\.id), ["bucket:gemini-session", "bucket:gemini-weekly",
                                                "bucket:claude-gpt-session", "bucket:claude-gpt-weekly"])
        XCTAssertEqual(result.windows.map(\.remainingFraction), [0, 1, 0.25, 0.5])
        XCTAssertEqual(result.windows.map(\.period), [.fiveHours, .weekly, .fiveHours, .weekly])
        XCTAssertTrue(result.windows[2].title.contains("Claude and GPT models"))
    }

    func testSupportsDirectGroupsNestedRemainingAndDeprecatedFlatBuckets() throws {
        let nested = bucket(extra: ["remaining": ["remainingFraction": 0.5]])
            .filter { $0.key != "remainingFraction" }
        let result = try AntigravityQuotaParser.parseSummary(data: data([
            "groups": [["displayName": "Gemini", "buckets": [nested]]]
        ]))
        XCTAssertEqual(result.windows.first?.remainingFraction, 0.5)
        let flat = try AntigravityQuotaParser.parseSummary(data: data(["response": ["buckets": [bucket()]]]))
        XCTAssertEqual(flat.windows.first?.remainingFraction, 0.75)
    }

    func testMissingDisabledAndAbsoluteAmountQuotasStayUnknown() throws {
        let result = try AntigravityQuotaParser.parseSummary(data: summary([
            bucket("gemini-weekly", fraction: 0),
            bucket("other-weekly", fraction: nil, extra: ["resetTime": "2027-01-16T09:00:00Z"]),
            bucket("disabled-session", fraction: 1, extra: ["disabled": true]),
            bucket("credits", fraction: nil, extra: ["remainingAmount": 42])
        ]))
        XCTAssertEqual(result.windows[0].remainingFraction, 0)
        XCTAssertNil(result.windows[1].remainingFraction)
        XCTAssertNotNil(result.windows[1].resetAt)
        XCTAssertNil(result.windows[2].remainingFraction)
        XCTAssertTrue(result.windows[2].isDisabled)
        XCTAssertNil(result.windows[3].remainingFraction)
        XCTAssertNil(result.windows[3].period)
    }

    func testAllUnknownDisabledOrAvailabilityOnlyAreUnavailable() throws {
        for payload in [try summary([]),
                        try summary([bucket(fraction: nil)]),
                        try summary([bucket(extra: ["disabled": true])]),
                        try data(["models": ["gemini": ["available": true]]]),
                        try data(["response": [:]])] {
            assertFailure(.unavailable) { try AntigravityQuotaParser.parseSummary(data: payload) }
        }
        assertFailure(.unavailable) {
            try AntigravityQuotaParser.parseUserStatus(data: status([model(fraction: nil)]))
        }
    }

    func testFractionRejectsBooleansStringsNegativeAndOutOfRange() throws {
        for value in [true, "0.5", -0.01, 1.01, 9_007_199_254_740_992.0] as [Any] {
            assertFailure(.invalidResponse) {
                try AntigravityQuotaParser.parseSummary(data: summary([bucket(fraction: value)]))
            }
            assertFailure(.invalidResponse) {
                try AntigravityQuotaParser.parseUserStatus(data: status([model(fraction: value)]))
            }
        }
        for literal in ["NaN", "Infinity", "1e1000"] {
            let payload = Data("{\"groups\":[{\"buckets\":[{\"bucketId\":\"gemini-weekly\",\"remainingFraction\":\(literal)}]}]}".utf8)
            assertFailure(.invalidResponse) { try AntigravityQuotaParser.parseSummary(data: payload) }
        }
    }

    func testInvalidCounterpartIsNotSilentlyDiscardedAfterValidBucket() throws {
        for extra in [["disabled": 1], ["remainingAmount": -1],
                      ["remaining": "invalid"], ["resetTime": true]] as [[String: Any]] {
            assertFailure(.invalidResponse) {
                try AntigravityQuotaParser.parseSummary(data: summary([
                    bucket(), bucket("another-session", extra: extra)
                ]))
            }
        }
    }

    func testResetTimeAcceptsISOAndProtobufTimestampWithoutInventingCadence() throws {
        let iso = "2027-01-15T08:00:00.125Z"
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let result = try AntigravityQuotaParser.parseSummary(data: summary([
            bucket("custom-window", extra: ["resetTime": iso, "description": "Resets tomorrow"]),
            bucket("other-window", extra: ["resetTime": ["seconds": String(Int(date.timeIntervalSince1970)), "nanos": 125_000_000]])
        ]))
        XCTAssertEqual(result.windows[0].resetAt, date.addingTimeInterval(0.125))
        XCTAssertEqual(result.windows[0].resetAt, result.windows[1].resetAt)
        XCTAssertEqual(result.windows[0].resetDescription, "Resets tomorrow")
        XCTAssertTrue(result.windows.allSatisfy { $0.period == nil })
        let legacy = try AntigravityQuotaParser.parseUserStatus(data: status([model(reset: String(Int(date.timeIntervalSince1970)))]))
        XCTAssertEqual(legacy.windows.first?.resetAt, date)
        XCTAssertNil(legacy.windows.first?.period)
    }

    func testResetTimeRejectsNonfiniteOverflowBooleanAndMalformedValues() throws {
        for value in ["NaN", "Infinity", "-1", "9999999999999999999", "not-a-date", true,
                      ["seconds": "NaN"], ["seconds": "100", "nanos": 1_000_000_000],
                      ["seconds": "100.5"], ["seconds": "100", "nanos": true]] as [Any] {
            assertFailure(.invalidResponse) {
                try AntigravityQuotaParser.parseSummary(data: summary([bucket(extra: ["resetTime": value])]))
            }
        }
    }

    func testExplicitUnknownWindowDoesNotFallBackToWeeklyID() throws {
        let result = try AntigravityQuotaParser.parseSummary(data: summary([
            bucket(extra: ["window": "rolling-custom"]), bucket("notweekly")
        ]))
        XCTAssertTrue(result.windows.allSatisfy { $0.period == nil })
    }

    func testLegacyModelsRetainIdentityAndUnknownResetOnlyRows() throws {
        let result = try AntigravityQuotaParser.parseUserStatus(data: status([
            model("gemini-pro", fraction: 0),
            model("gemini-flash", fraction: 1),
            model("claude-sonnet", fraction: nil, reset: "2027-01-15T08:00:00Z"),
            ["modelOrAlias": ["model": "availability-only"], "label": "Available"]
        ]))
        XCTAssertEqual(result.windows.map(\.id), ["model:gemini-pro", "model:gemini-flash", "model:claude-sonnet"])
        XCTAssertEqual(result.windows.map(\.remainingFraction), [0, 1, nil])
        XCTAssertTrue(result.windows.allSatisfy { $0.period == nil })
        let encoded = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic@example.invalid"))
        XCTAssertEqual(try JSONDecoder().decode(AntigravityQuotaSnapshot.self, from: encoded), result)
    }

    func testDuplicateIDsAndExcessiveWindowsRejectEntireResponse() throws {
        assertFailure(.invalidResponse) {
            try AntigravityQuotaParser.parseSummary(data: summary([bucket(), bucket()]))
        }
        assertFailure(.invalidResponse) {
            try AntigravityQuotaParser.parseUserStatus(data: status([model(), model()]))
        }
        let many = (0...AntigravityQuotaParser.maximumWindows).map { bucket("bucket-\($0)") }
        assertFailure(.invalidResponse) { try AntigravityQuotaParser.parseSummary(data: summary(many)) }
        let separateGroups = (0..<2).map { index in
            ["displayName": "group-\(index)", "buckets": (0..<33).map { bucket("bucket-\(index)-\($0)") }] as [String: Any]
        }
        assertFailure(.invalidResponse) {
            try AntigravityQuotaParser.parseSummary(data: data(["groups": separateGroups]))
        }
    }

    func testUntrustedLabelsAreBoundedAndSingleLineWhileIdentityIsValidated() throws {
        let result = try AntigravityQuotaParser.parseSummary(data: data(["groups": [[
            "displayName": "Gemini\n\u{202e} Models", "buckets": [bucket(extra: [
                "displayName": String(repeating: "a", count: 200),
                "description": "Resets\n\t tomorrow\u{0}"
            ])]
        ]]]))
        XCTAssertLessThanOrEqual(result.windows[0].title.count, 160)
        XCTAssertFalse(result.windows[0].title.contains("\n"))
        XCTAssertFalse(result.windows[0].title.contains("\u{202e}"))
        XCTAssertEqual(result.windows[0].resetDescription, "Resets tomorrow")
        for id in ["", "\n", "malicious\u{202e}", String(repeating: "a", count: 257)] {
            assertFailure(.invalidResponse) {
                try AntigravityQuotaParser.parseSummary(data: summary([bucket(id)]))
            }
        }
    }

    func testMalformedSchemaOversizedDataAndErrorResponsesRemainSafe() throws {
        for payload in [Data(), Data("[]".utf8), Data("not json".utf8),
                        Data(repeating: 32, count: AntigravityQuotaParser.maximumResponseBytes + 1),
                        try data(["response": "invalid"]), try data(["groups": true]),
                        try data(["groups": [["buckets": "invalid"]]])] {
            assertFailure(.invalidResponse) { try AntigravityQuotaParser.parseSummary(data: payload) }
        }
        for code in ["PERMISSION_DENIED", 7] as [Any] {
            assertFailure(.unavailable) {
                try AntigravityQuotaParser.parseSummary(data: data(["code": code, "message": "private response"]))
            }
        }
        XCTAssertFalse(AntigravityQuotaParser.Failure.invalidResponse.localizedDescription.contains("private response"))
    }
}
