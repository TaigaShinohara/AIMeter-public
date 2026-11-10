import XCTest
import Foundation
import Darwin
import AIMeterCore
@testable import AIMeter

final class StoreClaudeCollectorTests: XCTestCase {
    private var root: URL!
    private var logs: URL { root.appendingPathComponent("logs") }
    private var settings: URL { root.appendingPathComponent("settings.json") }
    private let now = Date()
    private var timestamp: String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func collect(logsSelected: Bool = true, settingsSelected: Bool = false,
                         limits: StoreClaudeCollector.Limits = .init()) throws -> StoreClaudeCollector.Result {
        let logFD = logsSelected ? Darwin.open(logs.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1
        let settingsFD = settingsSelected ? Darwin.open(settings.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) : -1
        defer { if logFD >= 0 { Darwin.close(logFD) }; if settingsFD >= 0 { Darwin.close(settingsFD) } }
        guard (!logsSelected || logFD >= 0) && (!settingsSelected || settingsFD >= 0) else { throw StoreSafeFileTree.Failure.invalidRoot }
        return try StoreClaudeCollector.collect(logsFD: logsSelected ? logFD : nil,
                                                settingsFD: settingsSelected ? settingsFD : nil,
                                                limits: limits, now: now)
    }
    private func row(input: Int = 100, output: Int = 20, cached: Int = 50) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"message\":{\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cached)}}}"
    }
    func testValidRowsMatchExistingLogCalculationAndKeepDuplicates() throws {
        try write(logs.appendingPathComponent("projects/session.jsonl"), row() + "\n" + row())
        let result = try collect()
        let existing = try LocalUsageCollector.collectStoreSources(["claude.logs": logs], home: root, now: now)
        XCTAssertEqual(result.logs, .complete)
        XCTAssertEqual(result.used, existing.providers?["claude"]?.usedByPeriod)
        XCTAssertEqual(result.logCost, existing.providers?["claude"]?.costUSD)
        XCTAssertEqual(result.used?.monthly, 250)
        XCTAssertEqual(result.settings, .absent)
        XCTAssertNil(result.plan)
    }
    func testInternalSettingsPriorityAndInvalidDoesNotFallBack() throws {
        try write(settings, "{\"claudeMaxTier\":\"20x\"}")
        XCTAssertEqual(try collect(settingsSelected: true).settings, .externalValid)
        try write(logs.appendingPathComponent(".claude.json"), "{\"claudeMaxTier\":\"5x\"}")
        let internalResult = try collect(settingsSelected: true)
        XCTAssertEqual(internalResult.settings, .internalValid)
        XCTAssertEqual(internalResult.plan, "Max (5x)")
        try write(logs.appendingPathComponent(".claude.json"), "{broken}")
        let invalid = try collect(settingsSelected: true)
        XCTAssertEqual(invalid.settings, .internalInvalid)
        XCTAssertNil(invalid.plan)
        let unselected = try collect(logsSelected: false, settingsSelected: false)
        XCTAssertEqual(unselected.logs, .unselected)
        XCTAssertEqual(unselected.settings, .unselected)
    }
    func testProjectEstimateIsUndatedAndDoesNotPopulatePeriods() throws {
        try write(settings, "{\"projects\":{\"synthetic\":{\"lastTotalInputTokens\":100,\"lastTotalOutputTokens\":20,\"lastTotalCacheCreationInputTokens\":10,\"lastTotalCacheReadInputTokens\":50,\"lastCost\":1.5}}}")
        let result = try collect(settingsSelected: true)
        XCTAssertEqual(result.logs, .notDetected)
        XCTAssertNil(result.used)
        XCTAssertEqual(result.projects, .complete)
        XCTAssertEqual(result.undatedProjects, .init(tokens: 135, cost: 1.5))
    }
    func testExplicitInvalidUsageIsNotAnUnrelatedMessage() throws {
        let file = logs.appendingPathComponent("session.jsonl")
        let unrelated = "{\"timestamp\":\"\(timestamp)\",\"message\":{\"text\":\"hello\"}}"
        try write(file, unrelated)
        XCTAssertEqual(try collect().logs, .notDetected)
        for value in ["null", "1", "[]"] {
            let bad = "{\"timestamp\":\"\(timestamp)\",\"message\":{\"usage\":\(value)}}"
            try write(file, bad)
            XCTAssertEqual(try collect().logs, .invalid)
            try write(file, row() + "\n" + bad)
            XCTAssertEqual(try collect().logs, .partial)
        }
        let nullCache = "{\"timestamp\":\"\(timestamp)\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0,\"cache_read_input_tokens\":null}}"
        try write(file, nullCache)
        XCTAssertEqual(try collect().logs, .invalid)
        try write(file, row() + "\n" + nullCache)
        XCTAssertEqual(try collect().logs, .partial)
    }
    func testIncompleteProjectsCannotAppearAsCompleteEstimate() throws {
        let complete = "{\"lastTotalInputTokens\":0,\"lastTotalOutputTokens\":0,\"lastTotalCacheCreationInputTokens\":0,\"lastTotalCacheReadInputTokens\":0,\"lastCost\":0}"
        for (json, expected) in [("{}", StoreClaudeCollector.ProjectsState.notDetected),
                                 ("{\"projects\":{}}", .notDetected),
                                 ("{\"projects\":null}", .incomplete),
                                 ("{\"projects\":{\"a\":{}}}", .incomplete),
                                 ("{\"projects\":{\"a\":{\"lastTotalInputTokens\":null}}}", .incomplete),
                                 ("{\"projects\":{\"a\":\(complete),\"b\":{}}}", .incomplete)] {
            try write(settings, json)
            let result = try collect(settingsSelected: true)
            XCTAssertEqual(result.projects, expected)
            XCTAssertNil(result.undatedProjects)
        }
        try write(settings, "{\"projects\":{\"a\":\(complete)}}")
        let result = try collect(settingsSelected: true)
        XCTAssertEqual(result.projects, .complete)
        XCTAssertEqual(result.undatedProjects, .init(tokens: 0, cost: 0))
    }
    func testZeroPartialAndInvalidAreDistinct() throws {
        let file = logs.appendingPathComponent("session.jsonl")
        try write(file, row(input: 0, output: 0, cached: 0))
        XCTAssertEqual(try collect().logs, .complete)
        XCTAssertEqual(try collect().used?.monthly, 0)
        try write(file, row() + "\n{broken}")
        XCTAssertEqual(try collect().logs, .partial)
        try write(file, "{broken}")
        XCTAssertEqual(try collect().logs, .invalid)
    }
    func testSharedLimitsFailClosedAndInternalSymlinkDoesNotFallback() throws {
        let value = row()
        let external = "{\"claudeMaxTier\":\"20x\"}"
        try write(logs.appendingPathComponent("session.jsonl"), value)
        try write(settings, external)
        var limits = StoreClaudeCollector.Limits()
        limits.tree.totalBytes = value.utf8.count + external.utf8.count - 1
        XCTAssertThrowsError(try collect(settingsSelected: true, limits: limits))
        limits.tree.totalBytes += 1
        XCTAssertEqual(try collect(settingsSelected: true, limits: limits).settings, .externalValid)
        limits.tree.totalBytes = 10_000
        limits.tree.lineBytes = value.utf8.count - 1
        XCTAssertThrowsError(try collect(settingsSelected: true, limits: limits))
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent(".claude.json"), withDestinationURL: settings)
        XCTAssertThrowsError(try collect(settingsSelected: true))
    }
}
