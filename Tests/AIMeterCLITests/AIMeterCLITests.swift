import Foundation
import XCTest
import AIMeterCore
@testable import AIMeterCLICore

/// Engine-level tests for the read-only CLI. All inputs are synthetic:
/// fixture JSON in a temporary directory and a dedicated UserDefaults
/// suite. No real usage data, preferences domain, or Keychain is touched.
final class AIMeterCLITests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMeterCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "AIMeterCLITests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: Fixtures

    private var usageFileURL: URL { tempDirectory.appendingPathComponent(".ai_meter_usage.json") }
    private var widgetFileURL: URL { tempDirectory.appendingPathComponent(".ai_meter_widget.json") }

    private func makeEnvironment(dataDirectory: URL? = nil) -> CLIEnvironment {
        CLIEnvironment(
            dataDirectory: dataDirectory ?? tempDirectory,
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

    private func decode(_ result: CLIResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
        return try XCTUnwrap(object as? [String: Any], "output is not a JSON object", file: file, line: line)
    }

    private func dataObject(_ result: CLIResult) throws -> [String: Any] {
        try XCTUnwrap(try decode(result)["data"] as? [String: Any])
    }

    private func service(in result: CLIResult, id: String) throws -> [String: Any] {
        let services = try XCTUnwrap(try dataObject(result)["services"] as? [[String: Any]])
        return try XCTUnwrap(services.first(where: { $0["id"] as? String == id }), "service \(id) missing")
    }

    private func frames(of service: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(service["frames"] as? [[String: Any]])
    }

    // MARK: Argument parsing and envelope

    func testNoCommandIsInputError() throws {
        let result = CLIEngine.run(arguments: [], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 1)
        let json = try decode(result)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
    }

    func testUnknownCommandIsInputError() throws {
        let result = CLIEngine.run(arguments: ["bogus"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual((try decode(result)["error"] as? [String: Any])?["code"] as? String, "unknown_command")
    }

    func testHelpAnswers() {
        let top = CLIEngine.run(arguments: ["--help"], environment: makeEnvironment())
        XCTAssertEqual(top.exitCode, 0)
        XCTAssertTrue(top.output.contains("status"))
        XCTAssertTrue(top.output.contains("doctor"))

        let get = CLIEngine.run(arguments: ["get", "--help"], environment: makeEnvironment())
        XCTAssertEqual(get.exitCode, 0)
        XCTAssertTrue(get.output.contains("サービスID"))
    }

    func testWriteFlagsAreExplicitlyUnsupported() throws {
        for arguments in [["list", "--dry-run"], ["list", "--yes"], ["status", "--idempotency-key", "abc"]] {
            let result = CLIEngine.run(arguments: arguments, environment: makeEnvironment())
            XCTAssertEqual(result.exitCode, 1, "\(arguments)")
            let error = try XCTUnwrap(try decode(result)["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "unsupported_flag", "\(arguments)")
        }
    }

    func testConflictingFormatsAndBadTimeoutAreInputErrors() {
        for arguments in [["status", "--json", "--human"], ["status", "--timeout", "abc"], ["status", "--timeout", "0"], ["get"], ["get", "openai", "extra"], ["status", "--bogus"]] {
            let result = CLIEngine.run(arguments: arguments, environment: makeEnvironment())
            XCTAssertEqual(result.exitCode, 1, "\(arguments)")
        }
        let ok = CLIEngine.run(arguments: ["status", "--timeout", "5"], environment: makeEnvironment())
        XCTAssertEqual(ok.exitCode, 0)
    }

    func testSuccessEnvelopeShape() throws {
        let result = CLIEngine.run(arguments: ["status"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        let json = try decode(result)
        XCTAssertEqual(json["ok"] as? Bool, true)
        let meta = try XCTUnwrap(json["meta"] as? [String: Any])
        XCTAssertEqual((meta["schema_version"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(meta["command"] as? String, "status")
        XCTAssertFalse((meta["request_id"] as? String ?? "").isEmpty)
    }

    // MARK: status

    func testStatusWithFixtures() throws {
        try writeAllFixtures()
        let result = CLIEngine.run(arguments: ["status"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        let data = try dataObject(result)
        let app = try XCTUnwrap(data["app"] as? [String: Any])
        XCTAssertEqual(app["distribution"] as? String, "direct")
        let inner = try XCTUnwrap(data["data"] as? [String: Any])
        let usage = try XCTUnwrap(inner["usage_snapshot"] as? [String: Any])
        XCTAssertEqual(usage["exists"] as? Bool, true)
        XCTAssertEqual(usage["updated_at"] as? String, "2026-11-24T00:00:00Z")
        XCTAssertEqual(usage["source"] as? String, "local-logs")
        let widget = try XCTUnwrap(inner["widget_snapshot"] as? [String: Any])
        XCTAssertEqual((widget["schema_version"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual(widget["has_data"] as? Bool, true)
        XCTAssertEqual(widget["update_failed"] as? Bool, false)
        let services = try XCTUnwrap(inner["services"] as? [String: Any])
        XCTAssertEqual((services["known"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((services["enabled"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(inner["setup_completed"] as? Bool, true)
        let notes = try XCTUnwrap(data["notes"] as? [String])
        XCTAssertTrue(notes.contains(where: { $0.contains("App Store") }))
    }

    func testStatusWithoutFiles() throws {
        let result = CLIEngine.run(arguments: ["status"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        let inner = try XCTUnwrap(try dataObject(result)["data"] as? [String: Any])
        let usage = try XCTUnwrap(inner["usage_snapshot"] as? [String: Any])
        XCTAssertEqual(usage["exists"] as? Bool, false)
        XCTAssertTrue(usage["updated_at"] is NSNull)
    }

    // MARK: list / get

    func testListFramesAndSources() throws {
        try writeAllFixtures()
        let result = CLIEngine.run(arguments: ["list"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        let data = try dataObject(result)
        XCTAssertEqual(data["has_data"] as? Bool, true)
        XCTAssertEqual((data["count"] as? NSNumber)?.intValue, 4)

        let openai = try service(in: result, id: "openai")
        let openaiFrames = try frames(of: openai)
        XCTAssertEqual(openaiFrames.map { $0["period"] as? String }, ["5h", "7d", "30d"])
        let fiveHours = try XCTUnwrap(openaiFrames.first(where: { $0["period"] as? String == "5h" }))
        XCTAssertEqual((fiveHours["remaining_percent"] as? NSNumber)?.intValue, 58)
        XCTAssertEqual(fiveHours["remaining_source"] as? String, "official")
        XCTAssertEqual((fiveHours["used_tokens"] as? NSNumber)?.intValue, 21_000_000)
        let weekly = try XCTUnwrap(openaiFrames.first(where: { $0["period"] as? String == "7d" }))
        XCTAssertEqual((weekly["remaining_percent"] as? NSNumber)?.intValue, 90)
        let bottleneck = try XCTUnwrap(openai["bottleneck"] as? [String: Any])
        XCTAssertEqual(bottleneck["period"] as? String, "5h")

        let gemini = try service(in: result, id: "gemini")
        let geminiFrames = try frames(of: gemini)
        XCTAssertEqual(geminiFrames.map { $0["period"] as? String }, ["5h", "1d", "7d", "30d"])
        let monthly = try XCTUnwrap(geminiFrames.first(where: { $0["period"] as? String == "30d" }))
        XCTAssertEqual(monthly["remaining_source"] as? String, "unavailable")
        XCTAssertTrue(monthly["remaining_percent"] is NSNull)
        XCTAssertEqual((monthly["used_tokens"] as? NSNumber)?.intValue, 10_000_000)

        let antigravity = try service(in: result, id: "antigravity")
        XCTAssertEqual(antigravity["has_data"] as? Bool, false)
        XCTAssertEqual(antigravity["enabled"] as? Bool, false)
        let agFrames = try frames(of: antigravity)
        XCTAssertEqual(agFrames.first?["id"] as? String, "antigravity-unavailable")
        XCTAssertEqual(agFrames.first?["remaining_source"] as? String, "unavailable")
    }

    func testGetCustomServiceUsesLiveAndManualUsage() throws {
        try writeAllFixtures()
        let result = CLIEngine.run(arguments: ["get", "claude"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        let service = try dataObject(result)
        XCTAssertEqual(service["kind"] as? String, "custom")
        let serviceFrames = try frames(of: service)
        XCTAssertEqual(serviceFrames.map { $0["period"] as? String }, ["5h", "7d"])
        let fiveHours = try XCTUnwrap(serviceFrames.first(where: { $0["period"] as? String == "5h" }))
        XCTAssertEqual((fiveHours["used_tokens"] as? NSNumber)?.intValue, 100_000)
        XCTAssertEqual((fiveHours["remaining_percent"] as? NSNumber)?.intValue, 93)
    }

    func testGetUnknownServiceIsNotFound() throws {
        try writeAllFixtures()
        let result = CLIEngine.run(arguments: ["get", "nosuch"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 4)
        let json = try decode(result)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "not_found")
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertTrue((details["known_ids"] as? [String])?.contains("openai") == true)
    }

    func testListWithoutFilesStillAnswers() throws {
        let result = CLIEngine.run(arguments: ["list"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        let data = try dataObject(result)
        XCTAssertEqual(data["has_data"] as? Bool, false)
        XCTAssertEqual((data["count"] as? NSNumber)?.intValue, 3)
        let get = CLIEngine.run(arguments: ["get", "gemini"], environment: makeEnvironment())
        XCTAssertEqual(get.exitCode, 0)
    }

    func testHumanFormatIsSeparateFromJSON() throws {
        try writeAllFixtures()
        let result = CLIEngine.run(arguments: ["list", "--human"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.output.hasPrefix("{"))
        XCTAssertTrue(result.output.contains("OpenAI Codex"))
        XCTAssertTrue(result.output.contains("58%"))
    }

    func testDataDirOverride() throws {
        try writeAllFixtures()
        let empty = tempDirectory.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let result = CLIEngine.run(
            arguments: ["status", "--data-dir", tempDirectory.path],
            environment: makeEnvironment(dataDirectory: empty)
        )
        XCTAssertEqual(result.exitCode, 0)
        let inner = try XCTUnwrap(try dataObject(result)["data"] as? [String: Any])
        let usage = try XCTUnwrap(inner["usage_snapshot"] as? [String: Any])
        XCTAssertEqual(usage["exists"] as? Bool, true)
    }

    // MARK: history

    func testHistoryIsHonestAboutMissingPersistence() throws {
        try writeAllFixtures()
        let result = CLIEngine.run(arguments: ["history"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        let data = try dataObject(result)
        XCTAssertEqual(data["persistent_history_available"] as? Bool, false)
        let last = try XCTUnwrap(data["last_update"] as? [String: Any])
        XCTAssertEqual(last["updated_at"] as? String, "2026-11-24T00:00:00Z")
        XCTAssertEqual(last["update_failed"] as? Bool, false)
        XCTAssertEqual(last["source"] as? String, "local-logs")
    }

    // MARK: doctor

    private func check(in result: CLIResult, id: String) throws -> [String: Any] {
        let checks = try XCTUnwrap(try dataObject(result)["checks"] as? [[String: Any]])
        return try XCTUnwrap(checks.first(where: { $0["id"] as? String == id }), "check \(id) missing")
    }

    func testDoctorHealthy() throws {
        try writeAllFixtures()
        let result = CLIEngine.run(arguments: ["doctor"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try check(in: result, id: "usage_file")["status"] as? String, "ok")
        XCTAssertEqual(try check(in: result, id: "widget_file")["status"] as? String, "ok")
        XCTAssertEqual(try check(in: result, id: "custom_subscriptions")["status"] as? String, "ok")
        XCTAssertEqual(try check(in: result, id: "openai_api_key")["status"] as? String, "unknown")
        XCTAssertEqual(try check(in: result, id: "gcp_project")["status"] as? String, "warning")
        let summary = try XCTUnwrap(try dataObject(result)["summary"] as? [String: Any])
        XCTAssertEqual((summary["error"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((summary["unknown"] as? NSNumber)?.intValue, 1)
    }

    func testDoctorWithoutFilesWarnsButPasses() throws {
        let result = CLIEngine.run(arguments: ["doctor"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try check(in: result, id: "usage_file")["status"] as? String, "warning")
        XCTAssertEqual(try check(in: result, id: "widget_file")["status"] as? String, "warning")
    }

    func testDoctorDetectsCorruptUsageFile() throws {
        try Data("not json".utf8).write(to: usageFileURL)
        let result = CLIEngine.run(arguments: ["doctor"], environment: makeEnvironment())
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(try check(in: result, id: "usage_file")["status"] as? String, "error")
    }

    func testDoctorReportsLegacyKeyPresenceWithoutValue() throws {
        defaults.set("synthetic-legacy-value", forKey: "openaiAdminKey")
        let result = CLIEngine.run(arguments: ["doctor"], environment: makeEnvironment())
        XCTAssertEqual(try check(in: result, id: "legacy_openai_key")["status"] as? String, "warning")
        XCTAssertFalse(result.output.contains("synthetic-legacy-value"))
    }

    func testDoctorNeverLeaksCredentialMaterial() throws {
        try writeAllFixtures()
        defaults.set("synthetic-legacy-value", forKey: "openaiAdminKey")
        defaults.set("synthetic-project", forKey: "gcpProjectId")
        let result = CLIEngine.run(arguments: ["doctor"], environment: makeEnvironment())
        XCTAssertFalse(result.output.contains("synthetic-legacy-value"))
        XCTAssertFalse(result.output.contains("synthetic-project"))
        XCTAssertEqual(try check(in: result, id: "gcp_project")["status"] as? String, "ok")
    }
}
