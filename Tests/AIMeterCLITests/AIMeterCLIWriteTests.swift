import Foundation
import XCTest
import AIMeterCore
@testable import AIMeterCLICore

/// Engine-level tests for the write command (`update service`) and the
/// self-check (`verify`). All inputs are synthetic: fixture JSON in a
/// temporary directory and a dedicated UserDefaults suite. No real usage
/// data, preferences domain, or Keychain is touched.
final class AIMeterCLIWriteTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMeterCLIWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "AIMeterCLIWriteTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: Fixtures

    private var usageFileURL: URL { tempDirectory.appendingPathComponent(".ai_meter_usage.json") }
    private var widgetFileURL: URL { tempDirectory.appendingPathComponent(".ai_meter_widget.json") }
    private var ledgerURL: URL { tempDirectory.appendingPathComponent(".ai_meter_cli_idempotency.json") }

    private func makeEnvironment() -> CLIEnvironment {
        CLIEnvironment(
            dataDirectory: tempDirectory,
            defaults: defaults,
            preferenceDomain: suiteName,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func writeUsageFixture() throws {
        let data = LocalUsageData(
            openaiUsedTokens: 300_000_000,
            openaiCostUSD: 12.5,
            geminiUsedTokens: 10_000_000,
            geminiCostUSD: 1.25,
            openaiUsedByPeriod: ProviderPeriodUsageJSON(
                twoHours: 1_000_000, fiveHours: 21_000_000, daily: 30_000_000,
                weekly: 100_000_000, monthly: 300_000_000
            ),
            geminiUsedByPeriod: ProviderPeriodUsageJSON(
                twoHours: 100_000, fiveHours: 500_000, daily: 1_000_000,
                weekly: 3_000_000, monthly: 10_000_000
            ),
            openaiServerUsedPercentByPeriod: ProviderPeriodPercentJSON(
                fiveHours: 42.0, weekly: 10.0, monthly: 37.5
            ),
            openaiResetAtByPeriod: ProviderPeriodUsageJSON(fiveHours: 1_800_000_000),
            providers: [
                "claude": CustomProviderUsageJSON(
                    usedByPeriod: ProviderPeriodUsageJSON(fiveHours: 100_000, weekly: 200_000),
                    costUSD: 3.0
                )
            ],
            detectedProviders: ["claude"],
            source: "local-logs",
            updatedAt: "2026-11-24T00:00:00Z"
        )
        try JSONEncoder().encode(data).write(to: usageFileURL)
    }

    private func writeWidgetFixture() throws {
        let item = WidgetServiceItem(
            id: "openai", name: "OpenAI Codex", shortName: "OAI", iconName: "brain.head.profile",
            remainingPercent: 58, remainingRatio: 0.58,
            usedTokens: 21_000_000, limitTokens: 40_000_000,
            usedDisplay: "21M", limitDisplay: "40M", unit: "tokens",
            bottleneckPeriod: .fiveHours
        )
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [item], totalCostUSD: 0,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            hasData: true, updateFailed: false, showUsageAmounts: true
        )
        try SharedStore.saveWidgetSnapshot(snapshot, to: widgetFileURL)
    }

    private func writeCustomSubscriptionsFixture() throws {
        let encoded = try JSONEncoder().encode([CustomSubscriptionConfig.claudePreset()])
        defaults.set(String(data: encoded, encoding: .utf8), forKey: "customSubscriptionsJSON")
    }

    private func writeAllFixtures() throws {
        try writeUsageFixture()
        try writeWidgetFixture()
        try writeCustomSubscriptionsFixture()
    }

    // MARK: Output helpers

    private func decode(_ result: CLIResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
        return try XCTUnwrap(object as? [String: Any], "output is not a JSON object")
    }

    private func dataObject(_ result: CLIResult) throws -> [String: Any] {
        try XCTUnwrap(try decode(result)["data"] as? [String: Any])
    }

    private func errorObject(_ result: CLIResult) throws -> [String: Any] {
        try XCTUnwrap(try decode(result)["error"] as? [String: Any])
    }

    private func run(_ arguments: [String]) -> CLIResult {
        CLIEngine.run(arguments: arguments, environment: makeEnvironment())
    }

    // MARK: update — built-in services

    func testUpdateBuiltinRoundTripWritesGUIDefaultsKeys() throws {
        try writeAllFixtures()
        let disabled = run(["update", "service", "gemini", "--disabled"])
        XCTAssertEqual(disabled.exitCode, 0)
        let data = try dataObject(disabled)
        XCTAssertEqual(data["service_id"] as? String, "gemini")
        XCTAssertEqual(data["previous_enabled"] as? Bool, true)
        XCTAssertEqual(data["enabled"] as? Bool, false)
        XCTAssertEqual(data["changed"] as? Bool, true)
        XCTAssertEqual(data["dry_run"] as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "showGeminiSection") as? Bool, false)

        // The read side sees the same state through the same key.
        let listed = run(["get", "gemini"])
        XCTAssertEqual(try dataObject(listed)["enabled"] as? Bool, false)

        let enabled = run(["update", "service", "gemini", "--enabled"])
        XCTAssertEqual(enabled.exitCode, 0)
        XCTAssertEqual(try dataObject(enabled)["changed"] as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "showGeminiSection") as? Bool, true)
    }

    func testUpdateAntigravityUsesItsOwnKey() throws {
        let result = run(["update", "service", "antigravity", "--enabled"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try dataObject(result)["previous_enabled"] as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "showAntigravitySection") as? Bool, true)
    }

    func testUpdateAlreadyInTargetStateSucceedsWithoutChange() throws {
        let result = run(["update", "service", "openai", "--enabled"])
        XCTAssertEqual(result.exitCode, 0)
        let data = try dataObject(result)
        XCTAssertEqual(data["changed"] as? Bool, false)
        XCTAssertEqual(data["enabled"] as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "showOpenAISection"))
    }

    // MARK: update — custom services

    func testUpdateCustomServiceRewritesSameJSONDocument() throws {
        try writeAllFixtures()
        let result = run(["update", "service", "claude", "--disabled"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try dataObject(result)["changed"] as? Bool, true)

        let raw = try XCTUnwrap(defaults.string(forKey: "customSubscriptionsJSON"))
        let list = try JSONDecoder().decode([CustomSubscriptionConfig].self, from: Data(raw.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, "claude")
        XCTAssertEqual(list.first?.isEnabled, false)

        let listed = run(["get", "claude"])
        XCTAssertEqual(try dataObject(listed)["enabled"] as? Bool, false)
    }

    func testUpdateCustomServiceRefusesCorruptDocument() throws {
        defaults.set("not json", forKey: "customSubscriptionsJSON")
        // The corrupt document hides the custom service from the read side,
        // so the write must surface as not-found or app failure and must
        // never overwrite the stored value.
        let before = defaults.string(forKey: "customSubscriptionsJSON")
        let result = run(["update", "service", "claude", "--disabled"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(defaults.string(forKey: "customSubscriptionsJSON"), before)
    }

    // MARK: update — dry-run

    func testDryRunReportsChangeButWritesNothing() throws {
        try writeAllFixtures()
        let result = run(["update", "service", "openai", "--disabled", "--dry-run", "--idempotency-key", "dry-1"])
        XCTAssertEqual(result.exitCode, 0)
        let data = try dataObject(result)
        XCTAssertEqual(data["dry_run"] as? Bool, true)
        XCTAssertEqual(data["changed"] as? Bool, true)
        XCTAssertEqual(data["previous_enabled"] as? Bool, true)
        XCTAssertEqual(data["enabled"] as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "showOpenAISection"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    // MARK: update — argument and target errors

    func testUpdateUnknownServiceIsNotFound() throws {
        try writeAllFixtures()
        let result = run(["update", "service", "nosuch", "--enabled"])
        XCTAssertEqual(result.exitCode, 4)
        let error = try errorObject(result)
        XCTAssertEqual(error["code"] as? String, "not_found")
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertTrue((details["known_ids"] as? [String])?.contains("openai") == true)
    }

    func testUpdateArgumentErrors() {
        for arguments in [
            ["update"],
            ["update", "service"],
            ["update", "service", "openai"],
            ["update", "service", "openai", "--enabled", "--disabled"],
            ["update", "openai", "--enabled"],
            ["update", "service", "openai", "extra", "--enabled"],
            ["get", "openai", "--enabled"],
            ["verify", "extra"]
        ] {
            let result = run(arguments)
            XCTAssertEqual(result.exitCode, 1, "\(arguments)")
        }
    }

    // MARK: update — idempotency

    func testIdempotencyKeyReplaysFirstResultWithoutReapplying() throws {
        try writeAllFixtures()
        let first = run(["update", "service", "gemini", "--disabled", "--idempotency-key", "key-1"])
        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(try dataObject(first)["changed"] as? Bool, true)
        XCTAssertEqual(try dataObject(first)["idempotency_recorded"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))

        // Simulate the state being changed back outside the CLI; a replay
        // must return the recorded result and not re-apply the change.
        defaults.set(true, forKey: "showGeminiSection")
        let replay = run(["update", "service", "gemini", "--disabled", "--idempotency-key", "key-1"])
        XCTAssertEqual(replay.exitCode, 0)
        let data = try dataObject(replay)
        XCTAssertEqual(data["idempotent_replay"] as? Bool, true)
        XCTAssertEqual(data["changed"] as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "showGeminiSection") as? Bool, true)
    }

    func testIdempotencyKeyConflictIsInputError() throws {
        try writeAllFixtures()
        let first = run(["update", "service", "gemini", "--disabled", "--idempotency-key", "key-2"])
        XCTAssertEqual(first.exitCode, 0)
        let conflict = run(["update", "service", "openai", "--disabled", "--idempotency-key", "key-2"])
        XCTAssertEqual(conflict.exitCode, 1)
        XCTAssertEqual(try errorObject(conflict)["code"] as? String, "idempotency_conflict")
        XCTAssertNil(defaults.object(forKey: "showOpenAISection"))
    }

    func testVerifyRejectsWriteFlags() throws {
        let result = run(["verify", "--dry-run"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(try errorObject(result)["code"] as? String, "unsupported_flag")
    }

    func testUpdateAndVerifyHelp() {
        let update = run(["update", "--help"])
        XCTAssertEqual(update.exitCode, 0)
        XCTAssertTrue(update.output.contains("--enabled"))
        XCTAssertTrue(update.output.contains("--idempotency-key"))
        let verify = run(["verify", "--help"])
        XCTAssertEqual(verify.exitCode, 0)
        XCTAssertTrue(verify.output.contains("verification_failed"))
    }

    // MARK: verify

    func testVerifyPassesWithFixtures() throws {
        try writeAllFixtures()
        let result = run(["verify"])
        XCTAssertEqual(result.exitCode, 0)
        let data = try dataObject(result)
        XCTAssertEqual(data["passed"] as? Bool, true)
        let summary = try XCTUnwrap(data["summary"] as? [String: Any])
        XCTAssertEqual((summary["fail"] as? NSNumber)?.intValue, 0)
    }

    func testVerifyPassesWithoutFiles() throws {
        let result = run(["verify"])
        XCTAssertEqual(result.exitCode, 0)
        let data = try dataObject(result)
        XCTAssertEqual(data["passed"] as? Bool, true)
        let checks = try XCTUnwrap(data["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first(where: { $0["id"] as? String == "usage_file" })?["status"] as? String, "skipped")
    }

    func testVerifyFailsOnCorruptUsageFile() throws {
        try Data("not json".utf8).write(to: usageFileURL)
        let result = run(["verify"])
        XCTAssertEqual(result.exitCode, 2)
        let error = try errorObject(result)
        XCTAssertEqual(error["code"] as? String, "verification_failed")
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertEqual(details["passed"] as? Bool, false)
        let checks = try XCTUnwrap(details["checks"] as? [[String: Any]])
        let usage = try XCTUnwrap(checks.first(where: { $0["id"] as? String == "usage_file" }))
        XCTAssertEqual(usage["status"] as? String, "fail")
        XCTAssertFalse((usage["remedy"] as? String ?? "").isEmpty)
    }

    func testVerifyFailsOnDuplicateCustomServiceIDs() throws {
        let preset = CustomSubscriptionConfig.claudePreset()
        let encoded = try JSONEncoder().encode([preset, preset])
        defaults.set(String(data: encoded, encoding: .utf8), forKey: "customSubscriptionsJSON")
        let result = run(["verify"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(try errorObject(result)["code"] as? String, "verification_failed")
    }

    func testVerifyFailsOnMalformedTogglePreference() throws {
        defaults.set("yes", forKey: "showOpenAISection")
        let result = run(["verify"])
        XCTAssertEqual(result.exitCode, 2)
        let details = try XCTUnwrap(try errorObject(result)["details"] as? [String: Any])
        let checks = try XCTUnwrap(details["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first(where: { $0["id"] as? String == "preferences" })?["status"] as? String, "fail")
    }

    func testVerifyFailsOnUnknownPeriodPreference() throws {
        defaults.set("5h,9z", forKey: "openaiEnabledPeriodsCSV")
        let result = run(["verify"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(try errorObject(result)["code"] as? String, "verification_failed")
    }

    func testVerifyHumanFormat() throws {
        try writeAllFixtures()
        let result = run(["verify", "--human"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.output.hasPrefix("{"))
        XCTAssertTrue(result.output.contains("合格"))
    }
}
