import XCTest
import AIMeterCore
@testable import AIMeter

final class CollectionCapacityTests: XCTestCase {
    func testLargeMonthlyHistoryStreamsAndStillPreservesSnapshotAtBudgetFailure() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        // Four 80 MiB files exceed both the old per-file and combined scan budgets.
        // The large content is synthetic non-usage data, never a personal log.
        let prefix = "{\"type\":\"response_item\",\"text\":\""
        let suffix = "\"}\n"
        let ignoredLine = Data((prefix + String(repeating: "x", count: 16 * 1024 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let usage = Data("{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":10,\"output_tokens\":2}}}}\n".utf8)
        for index in 0..<4 {
            let file = sessions.appendingPathComponent("session-\(index).jsonl")
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            for _ in 0..<(80 * 1024 * 1024 / ignoredLine.count) { try handle.write(contentsOf: ignoredLine) }
            try handle.write(contentsOf: usage)
            try handle.close()
        }
        let destination = home.appendingPathComponent("usage.json")
        let collected = try await LocalUsageCollector.collectAndSave(targetFileURL: destination, home: home)
        XCTAssertEqual(collected.openaiUsedTokens, 48)
        let previous = try Data(contentsOf: destination)
        var restricted = BoundedInput.Limits()
        restricted.totalBytes = 8 * 1024 * 1024
        do {
            _ = try await LocalUsageCollector.collectAndSave(targetFileURL: destination, home: home, limits: restricted)
            XCTFail("The finite total-byte budget must still stop collection")
        } catch {
            guard case BoundedInput.Failure.limit = error else { return XCTFail("Expected input limit") }
        }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }
}
