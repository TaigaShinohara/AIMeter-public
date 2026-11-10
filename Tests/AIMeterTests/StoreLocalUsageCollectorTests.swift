import XCTest
import Foundation
import AIMeterCore
@testable import AIMeter

final class StoreLocalUsageCollectorTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var timestamp: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ path: String, _ object: [String: Any]) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try data.write(to: url)
        return url
    }

    func testMissingSourcesDoNotReadHomeOrPreviousSnapshot() throws {
        try write("home/.claude/projects/session.jsonl", ["timestamp": timestamp,
                  "message": ["usage": ["input_tokens": 99]]])
        try write("home/.gemini/antigravity/brain/session/transcript.jsonl",
                  ["created_at": timestamp, "input_tokens": 100])
        try write("home/.ai_meter_usage.json", ["providers": ["claude": ["status": "synthetic"]]])
        let result = try LocalUsageCollector.collectStoreSources([:], home: home)
        XCTAssertNil(result.openaiUsedTokens)
        XCTAssertNil(result.geminiUsedTokens)
        XCTAssertTrue(result.providers?.isEmpty == true)
        XCTAssertTrue(result.detectedProviders?.isEmpty == true)
    }

    func testGeminiSourcesAreIndependentAndNeverReadHomeDefaults() throws {
        try write("selected/brain/session/transcript.jsonl", ["created_at": timestamp, "input_tokens": 10])
        try write("selected/tmp/project/chats/session.json", ["messages": [["timestamp": timestamp,
                  "tokens": ["total": 20, "input": 20, "cached": 0, "output": 0]]]])
        try write("home/.gemini/antigravity/brain/session/transcript.jsonl", ["created_at": timestamp, "input_tokens": 1000])
        try write("home/.gemini/tmp/project/chats/session.json", ["messages": [["timestamp": timestamp,
                  "tokens": ["total": 2000, "input": 2000, "cached": 0, "output": 0]]]])
        let brain = root.appendingPathComponent("selected/brain")
        let chats = root.appendingPathComponent("selected/tmp")
        XCTAssertEqual(try LocalUsageCollector.collectStoreSources(["gemini.brain": brain], home: home).geminiUsedTokens, 10)
        XCTAssertEqual(try LocalUsageCollector.collectStoreSources(["gemini.chats": chats], home: home).geminiUsedTokens, 20)
        XCTAssertEqual(try LocalUsageCollector.collectStoreSources(["gemini.brain": brain, "gemini.chats": chats], home: home).geminiUsedTokens, 30)
    }

    func testClaudeSettingsAreExplicitAndInternalSettingsTakePriority() throws {
        try write("selected/claude/projects/session.jsonl", ["timestamp": timestamp,
                  "message": ["usage": ["input_tokens": 7, "output_tokens": 3]]])
        try write("home/.claude.json", ["claudeMaxTier": "20x"])
        let settings = try write("selected/settings.json", ["claudeMaxTier": "20x"])
        let logs = root.appendingPathComponent("selected/claude")
        let noSettings = try LocalUsageCollector.collectStoreSources(["claude.logs": logs], home: home)
        XCTAssertEqual(noSettings.providers?["claude"]?.usedByPeriod?.monthly, 10)
        XCTAssertEqual(noSettings.providers?["claude"]?.status, "Pro")
        let external = try LocalUsageCollector.collectStoreSources(["claude.logs": logs, "claude.settings": settings], home: home)
        XCTAssertEqual(external.providers?["claude"]?.status, "Max (20x)")
        try write("selected/claude/.claude.json", ["claudeMaxTier": "5x"])
        let internalFirst = try LocalUsageCollector.collectStoreSources(["claude.logs": logs, "claude.settings": settings], home: home)
        XCTAssertEqual(internalFirst.providers?["claude"]?.status, "Max (5x)")
    }

    func testSelectedGrokAndCursorNeedNoAuxiliaryHomePaths() throws {
        let grok = root.appendingPathComponent("selected/grok")
        let cursor = root.appendingPathComponent("selected/cursor")
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        let result = try LocalUsageCollector.collectStoreSources(["grokbot.persistence": grok, "cursor.agentStores": cursor], home: home)
        XCTAssertNotNil(result.providers?["grokbot"])
        XCTAssertNotNil(result.providers?["cursor"])
    }

    func testRejectsUnknownSourcesAndWindsurfFileSelection() throws {
        let file = try write("selected/state.vscdb", [:])
        XCTAssertThrowsError(try LocalUsageCollector.collectStoreSources(["unknown": file], home: home))
        XCTAssertThrowsError(try LocalUsageCollector.collectStoreSources(["windsurf.databaseDirectory": file], home: home))
    }

    func testCursorRejectsSymlinkAtEveryFixedControlComponent() throws {
        let components = ["AgentStores", "cursor_agent_stores", ".control"]
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("outside/secret.json", ["synthetic": true])
        for depth in components.indices {
            let selected = root.appendingPathComponent("cursor-\(depth)")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            var parent = selected
            for component in components.prefix(depth) {
                parent.appendPathComponent(component, isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent(components[depth]),
                                                       withDestinationURL: outside)
            XCTAssertThrowsError(try LocalUsageCollector.collectStoreSources(["cursor.agentStores": selected], home: home))
        }
    }
}
