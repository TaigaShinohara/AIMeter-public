import XCTest
import Foundation
import Darwin
import SQLite3
import AIMeterCore
@testable import AIMeter

/// All paths and conversation bodies are synthetic; no real account data is read.
final class PrivacyCanaryTests: XCTestCase {
    private var home: URL!
    private var timestamp: String!
    private let forbiddenBodyKeys = Set([
        "content", "thinking", "message", "messages", "entries", "payload",
        "access_token", "api_key", "email", "account"
    ])

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("aimeter-privacy-canary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
    }

    override func tearDownWithError() throws {
        if let home { try FileManager.default.removeItem(at: home) }
    }

    @discardableResult
    private func writeJSON(_ relativePath: String, _ value: Any, newline: Bool = false) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if newline { data.append(10) }
        try data.write(to: url)
        return url
    }

    private func base32(_ text: String) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var value = 0
        var bits = 0
        var output = ""
        for byte in text.utf8 {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(value >> bits) & 31])
            }
            value &= (1 << bits) - 1
        }
        if bits > 0 { output.append(alphabet[(value << (5 - bits)) & 31]) }
        return output
    }

    private func assertNoBodyFields(_ value: Any, file: StaticString = #filePath, line: UInt = #line) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                XCTAssertFalse(forbiddenBodyKeys.contains(key), "Unexpected body/account field: " + key,
                               file: file, line: line)
                assertNoBodyFields(child, file: file, line: line)
            }
        } else if let list = value as? [Any] {
            list.forEach { assertNoBodyFields($0, file: file, line: line) }
        }
    }

    private func assertPrivate(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, file: file, line: line)
        XCTAssertFalse(try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
                       file: file, line: line)
    }

    func testSyntheticConversationBodiesDoNotEnterPersistedUsage() async throws {
        let geminiContent = "AIMETER_PRIVACY_CANARY_GEMINI_CONTENT_20261101"
        let geminiThinking = "AIMETER_PRIVACY_CANARY_GEMINI_THINKING_20261101"
        let grokBody = "AIMETER_PRIVACY_CANARY_GROK_BODY_20261101"
        let claudeBody = "AIMETER_PRIVACY_CANARY_CLAUDE_BODY_20261101"
        let copilotBody = "AIMETER_PRIVACY_CANARY_COPILOT_BODY_20261101"
        let codexBody = "AIMETER_PRIVACY_CANARY_CODEX_BODY_20261101"
        let cursorBody = "AIMETER_PRIVACY_CANARY_CURSOR_BODY_20261101"
        let windsurfBody = "AIMETER_PRIVACY_CANARY_WINDSURF_UNRELATED_BODY_20261101"
        let canaries = [geminiContent, geminiThinking, grokBody, claudeBody,
                        copilotBody, codexBody, cursorBody, windsurfBody]

        try writeJSON(".gemini/antigravity/brain/synthetic/.system_generated/logs/transcript.jsonl", [
            "created_at": timestamp!, "content": geminiContent, "thinking": geminiThinking
        ], newline: true)
        try writeJSON(".claude/projects/synthetic/session.jsonl", [
            "timestamp": timestamp!,
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": claudeBody]],
                "usage": ["input_tokens": 20, "output_tokens": 10]
            ]
        ], newline: true)
        let grokKey = base32("transcript.replicas.privacy-canary")
        try writeJSON("Library/Application Support/Grok Bot/sand-client-persistence/" + grokKey + ".blob", [
            "value": ["entries": [[
                "timestampMs": Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000,
                "content": grokBody
            ]]]
        ])
        try writeJSON(".copilot/session-state/synthetic/events.jsonl", [
            "type": "user.message", "timestamp": timestamp!, "data": ["content": copilotBody]
        ], newline: true)
        try writeJSON(".codex/sessions/synthetic/session.jsonl", [
            "timestamp": timestamp!,
            "payload": [
                "type": "token_count",
                "rate_limits": ["credits": ["balance": 123.45], "plan_type": "pro"],
                "info": ["total_token_usage": ["input_tokens": 40, "cached_input_tokens": 10, "output_tokens": 20]],
                "message": codexBody
            ]
        ], newline: true)
        try writeJSON("Library/Application Support/Cursor/AgentStores/cursor_agent_stores/.control/synthetic/pin.json",
                      ["content": cursorBody])

        // A real application DB may contain unrelated records; this one is entirely synthetic.
        let dbURL = home.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        guard let db else { return XCTFail("Could not open synthetic SQLite fixture") }
        let schema = """
        CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value TEXT);
        INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"planName":"Synthetic","usage":{"usedMessages":7,"messages":100}}');
        INSERT INTO ItemTable VALUES('unrelated.synthetic.record','{"content":"\(windsurfBody)"}');
        """
        let status = sqlite3_exec(db, schema, nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(status, SQLITE_OK)

        let destination = home.appendingPathComponent("usage.json")
        let result = try await LocalUsageCollector.collectAndSave(targetFileURL: destination, home: home)

        // Positive counts prove the fixture was consumed rather than merely skipped.
        XCTAssertEqual(result.geminiUsedTokens, (geminiContent.count + geminiThinking.count) / 4)
        XCTAssertEqual(result.providers?["grokbot"]?.usedByPeriod?.monthly, grokBody.count / 3)
        XCTAssertEqual(result.providers?["claude"]?.usedByPeriod?.monthly, 30)
        XCTAssertEqual(result.providers?["copilot"]?.usedByPeriod?.monthly, 1)
        XCTAssertEqual(result.openaiUsedTokens, 51)
        XCTAssertNil(result.openaiCreditBalance)
        XCTAssertEqual(result.providers?["cursor"]?.usedByPeriod?.monthly, 1)
        XCTAssertEqual(result.providers?["windsurf"]?.usedByPeriod?.monthly, 7)

        let bytes = try Data(contentsOf: destination)
        let serialized = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for canary in canaries {
            XCTAssertFalse(serialized.contains(canary), "Synthetic conversation body was persisted")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        assertNoBodyFields(object)
        XCTAssertNil(object["openaiCreditBalance"])
        try assertPrivate(destination)
        let decoded = try JSONDecoder().decode(LocalUsageData.self, from: bytes)
        XCTAssertEqual(decoded, result)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: home.path)
            .contains { $0.hasSuffix(".tmp") })
    }

}
