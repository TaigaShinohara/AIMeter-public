import XCTest
import Foundation
import Darwin
import SQLite3
import AIMeterCore
@testable import AIMeter

final class LocalCollectionPrivacyTests: XCTestCase {
    private var home: URL!
    private var destination: URL { home.appendingPathComponent("usage.json") }
    private var timestamp: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    @discardableResult
    private func write(_ path: String, _ data: Data) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    private func json(_ path: String, _ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try write(path, data)
    }

    func testDisabledProvidersNeverOpenTheirSourcesAndArePrunedFromTheCache() async throws {
        let paths = [".codex/sessions", ".gemini/antigravity/brain", ".gemini/tmp", ".claude", ".claude.json",
                     "Library/Application Support/Grok Bot/sand-client-persistence", ".grokbot",
                     ".copilot/session-state", "Library/Application Support/Cursor", ".cursor",
                     "Library/Application Support/Windsurf/User/globalStorage/state.vscdb"]
        for path in paths {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        }
        let previous = LocalUsageData(openaiUsedTokens: 77, geminiUsedTokens: 88,
                                      providers: ["claude": .init(usedByPeriod: .init(monthly: 99))])
        try JSONEncoder().encode(previous).write(to: destination)
        let result = try await LocalUsageCollector.collectAndSave(targetFileURL: destination,
                                                                  enabledProviderIDs: [], home: home)
        XCTAssertNil(result.openaiUsedTokens)
        XCTAssertNil(result.geminiUsedTokens)
        XCTAssertTrue(result.providers?.isEmpty == true)
        XCTAssertTrue(result.detectedProviders?.isEmpty == true)
        let saved = try JSONDecoder().decode(LocalUsageData.self, from: Data(contentsOf: destination))
        XCTAssertEqual(saved, result)
        for path in paths {
            var info = stat()
            XCTAssertEqual(lstat(home.appendingPathComponent(path).path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO)
        }
    }

    func testEnabledClonesAndCodexAliasCollectOnlyTheirBaseOnce() async throws {
        try json(".claude/projects/synthetic/session.jsonl", ["timestamp": timestamp,
                 "message": ["usage": ["input_tokens": 7, "output_tokens": 3]]])
        try json(".codex/sessions/session.jsonl", ["timestamp": timestamp, "payload": [
            "type": "token_count", "info": ["total_token_usage": ["input_tokens": 11, "output_tokens": 2]]]])
        let first = try await LocalUsageCollector.collectAndSave(targetFileURL: destination,
                                                                 enabledProviderIDs: ["claude_a", "claude_b"], home: home)
        XCTAssertEqual(first.providers?["claude"]?.usedByPeriod?.monthly, 10)
        XCTAssertEqual(Set(first.providers?.keys.map { $0 } ?? []), ["claude"])
        XCTAssertNil(first.openaiUsedTokens)
        let second = try await LocalUsageCollector.collectAndSave(targetFileURL: destination,
                                                                  enabledProviderIDs: ["codex_clone"], home: home)
        XCTAssertEqual(second.openaiUsedTokens, 13)
        XCTAssertNil(second.geminiUsedTokens)
        XCTAssertTrue(second.providers?.isEmpty == true)
    }

    func testRevokedCommitPermitPreservesExistingBytes() async throws {
        let previous = Data("{\"source\":\"synthetic-previous\"}".utf8)
        try previous.write(to: destination)
        let permit = IntegrationPermit()
        permit.revoke()
        do {
            _ = try await LocalUsageCollector.collectAndSave(targetFileURL: destination,
                                                             enabledProviderIDs: [], commitPermit: permit, home: home)
            XCTFail("A revoked generation must not save")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    func testKnownCloneCacheAndInactiveManualRowsArePrunedButActiveManualValuesRemain() async throws {
        try json(".claude/projects/synthetic/session.jsonl", ["timestamp": timestamp,
                 "message": ["usage": ["input_tokens": 7, "output_tokens": 3]]])
        let prior = LocalUsageData(providers: [
            "claude_a": .init(usedByPeriod: .init(monthly: 999), status: "SYNTHETIC_OLD_CLONE"),
            "custom_active": .init(usedByPeriod: .init(monthly: 5), status: "User chosen label"),
            "custom_inactive": .init(usedByPeriod: .init(monthly: 6), status: "SYNTHETIC_INACTIVE_LABEL")
        ])
        try JSONEncoder().encode(prior).write(to: destination)
        let result = try await LocalUsageCollector.collectAndSave(targetFileURL: destination,
                                                                  enabledProviderIDs: ["claude_a", "custom_active"], home: home)
        XCTAssertEqual(Set(result.providers?.keys.map { $0 } ?? []), ["claude", "custom_active"])
        XCTAssertEqual(result.providers?["claude"]?.usedByPeriod?.monthly, 10)
        XCTAssertEqual(result.providers?["custom_active"]?.usedByPeriod?.monthly, 5)
        XCTAssertEqual(result.providers?["custom_active"]?.status, "User chosen label")
        let saved = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(saved.contains("SYNTHETIC_OLD_CLONE"))
        XCTAssertFalse(saved.contains("SYNTHETIC_INACTIVE_LABEL"))
    }

    func testGrokClassifiesBlobNameBeforeReadingAndRedactsUnknownPlan() async throws {
        let base = "Library/Application Support/Grok Bot/sand-client-persistence/"
        // The unrelated file is larger than the JSON budget and cannot be UTF-8 decoded.
        try write(base + "OVXHEZLMMF2GKZBOMNQWG2DF.blob", Data(repeating: 0xff, count: 512))
        let canary = "SYNTHETIC_PRIVATE_PLAN_CANARY"
        try json(base + "O5SWK23MPEWXK43BM5SS4Y3BMNUGK.blob", ["value": ["reading": [
            "usage": ["percentUsed": 25, "grokPlanLabel": canary]]]])
        var limits = BoundedInput.Limits()
        limits.jsonBytes = 256
        let result = try await LocalUsageCollector.collectAndSave(targetFileURL: destination,
                                                                  enabledProviderIDs: ["grokbot"], home: home, limits: limits)
        XCTAssertEqual(result.providers?["grokbot"]?.usedByPeriod?.weekly, 2_500_000)
        XCTAssertEqual(result.providers?["grokbot"]?.status, "Grok Bot")
        XCTAssertFalse(try String(contentsOf: destination, encoding: .utf8).contains(canary))
    }

    func testPrivatePlanTextIsNotReserializedButUsageAndUserDefinedStatusRemain() async throws {
        let canary = "SYNTHETIC_PRIVATE_PLAN_CANARY"
        try json(".claude.json", ["claudeMaxTier": canary])
        try json(".codex/sessions/session.jsonl", ["timestamp": timestamp, "payload": [
            "type": "token_count", "rate_limits": ["plan_type": canary],
            "info": ["total_token_usage": ["input_tokens": 11, "output_tokens": 2]]]])
        let database = home.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        let status = sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT,value TEXT); INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{\"planName\":\"\(canary)\",\"usage\":{\"usedMessages\":17}}');", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(status, SQLITE_OK)
        let prior = LocalUsageData(providers: ["grokbot": .init(usedByPeriod: .init(monthly: 42), status: canary),
                                              "custom_test": .init(usedByPeriod: .init(monthly: 5), status: "User chosen label")])
        try JSONEncoder().encode(prior).write(to: destination)
        let result = try await LocalUsageCollector.collectAndSave(targetFileURL: destination,
                                                                  enabledProviderIDs: ["openai", "claude", "grokbot", "windsurf", "custom_test"], home: home)
        XCTAssertEqual(result.openaiUsedTokens, 13)
        XCTAssertEqual(result.openaiPlanType, "unknown")
        XCTAssertEqual(result.providers?["claude"]?.status, "Claude")
        XCTAssertEqual(result.providers?["grokbot"]?.usedByPeriod?.monthly, 42)
        XCTAssertEqual(result.providers?["grokbot"]?.status, "Grok Bot")
        XCTAssertEqual(result.providers?["windsurf"]?.usedByPeriod?.monthly, 17)
        XCTAssertEqual(result.providers?["windsurf"]?.status, "Windsurf")
        XCTAssertEqual(result.providers?["custom_test"]?.status, "User chosen label")
        XCTAssertFalse(try String(contentsOf: destination, encoding: .utf8).contains(canary))
    }
}
