import XCTest
import Foundation
import Darwin
@testable import AIMeter

final class StoreGrokCollectorTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func encode(_ value: String) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, accumulator = 0, result = ""
        for byte in value.utf8 {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[(accumulator >> bits) & 31])
                accumulator &= (1 << bits) - 1
            }
        }
        if bits > 0 { result.append(alphabet[(accumulator << (5 - bits)) & 31]) }
        return result + ".blob"
    }
    private func write(_ key: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: root.appendingPathComponent(encode(key)))
    }
    private func collect(_ limits: StoreGrokCollector.Limits = .init(),
                         beforeOpen: ([String]) throws -> Void = { _ in }) throws -> StoreGrokCollector.Result {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreSafeFileTree.Failure.invalidRoot }
        defer { Darwin.close(fd) }
        return try StoreGrokCollector.collect(rootFD: fd, limits: limits, now: now, beforeOpen: beforeOpen)
    }
    private func weekly(_ usage: [String: Any]) -> [String: Any] {
        ["value": ["reading": ["usage": usage]]]
    }
    private func transcript(_ entries: [Any]) -> [String: Any] { ["value": ["entries": entries]] }

    func testEmptyAndValidZeroQuotaAndUnrelatedCanary() throws {
        XCTAssertEqual(try collect().quotaState, .notDetected)
        XCTAssertEqual(try StoreGrokCollector.collect(rootFD: nil).quotaState, .unselected)
        try write("weekly-usage.cache", weekly(["percentUsed": 0, "nextResetMs": 1000,
                                                 "onDemand": ["usedCents": 0]]))
        let unrelated = encode("unrelated.cache")
        try Data(repeating: 0x7f, count: 10000).write(to: root.appendingPathComponent(unrelated))
        var opened: [[String]] = []
        var limits = StoreGrokCollector.Limits()
        limits.jsonBytes = 512
        let result = try collect(limits, beforeOpen: { opened.append($0) })
        XCTAssertEqual(result.quotaState, .complete)
        XCTAssertEqual(result.quota?.percent, 0)
        XCTAssertEqual(result.quota?.resetSeconds, 1)
        XCTAssertEqual(result.quota?.costUSD, 0)
        XCTAssertNil(result.estimatedUsage)
        XCTAssertFalse(opened.contains([unrelated]))
    }

    func testConflictingCachesAreIndeterminateAndInvalidDataIsPartial() throws {
        try write("weekly-usage.cache.a", weekly(["percentUsed": 20]))
        try write("weekly-usage.cache.b", weekly(["percentUsed": 30]))
        var result = try collect()
        XCTAssertEqual(result.quotaState, .partial)
        XCTAssertNil(result.quota)
        try write("weekly-usage.cache.b", weekly(["percentUsed": NSNull()]))
        result = try collect()
        XCTAssertEqual(result.quotaState, .partial)
        XCTAssertEqual(result.quota?.percent, 20)
        try write("weekly-usage.cache.a", weekly(["percentUsed": NSNull()]))
        XCTAssertEqual(try collect().quotaState, .invalid)
    }

    func testTranscriptWindowsAndInvalidEntriesAreSeparate() throws {
        let recent = now.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        let future = now.addingTimeInterval(60).timeIntervalSince1970 * 1000
        try write("transcript.replicas.a", transcript([["timestampMs": recent, "content": "abcdef"],
                                                        ["timestampMs": future, "content": "abcdef"],
                                                        ["timestampMs": recent, "content": ""],
                                                        ["timestampMs": NSNull(), "content": "abcdef"]]))
        let result = try collect()
        XCTAssertEqual(result.transcriptState, .partial)
        XCTAssertEqual(result.estimatedUsage?.weekly, 2)
        XCTAssertEqual(result.quotaState, .notDetected)
        XCTAssertNil(result.quota)
    }

    func testSharedBudgetAndSymlinkFailClosed() throws {
        try write("weekly-usage.cache", weekly(["percentUsed": 20]))
        try write("transcript.replicas.a", transcript([["timestampMs": now.timeIntervalSince1970 * 1000, "content": "abc"]]))
        var limits = StoreGrokCollector.Limits()
        limits.tree.totalBytes = 1
        XCTAssertThrowsError(try collect(limits))
        limits.tree.totalBytes = 10000
        limits.jsonBytes = 1
        XCTAssertThrowsError(try collect(limits))
        let link = root.appendingPathComponent(encode("weekly-usage.cache.link"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(encode("weekly-usage.cache")))
        var opened: [[String]] = []
        _ = try collect(beforeOpen: { opened.append($0) })
        XCTAssertFalse(opened.contains([link.lastPathComponent]))
    }

    func testOldCacheIsOnlyObservedAndFreshnessRemainsUnknown() throws {
        let key = "weekly-usage.cache"
        try write(key, weekly(["percentUsed": 20]))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-365 * 86400)],
                                              ofItemAtPath: root.appendingPathComponent(encode(key)).path)
        let result = try collect()
        XCTAssertEqual(result.quota?.percent, 20)
        XCTAssertEqual(result.quota?.observedAt, now)
        XCTAssertEqual(result.quota?.freshness, .unverified)
    }

    func testMultipleReplicasExposePossibleOverlap() throws {
        let entry: [String: Any] = ["timestampMs": now.addingTimeInterval(-60).timeIntervalSince1970 * 1000,
                                    "content": "abcdef"]
        try write("transcript.replicas.a", transcript([entry]))
        var result = try collect()
        XCTAssertEqual(result.transcriptState, .complete)
        XCTAssertFalse(result.transcriptsMayOverlap)
        try write("transcript.replicas.b", transcript([entry]))
        result = try collect()
        XCTAssertEqual(result.transcriptState, .partial)
        XCTAssertTrue(result.transcriptsMayOverlap)
        XCTAssertEqual(result.estimatedUsage?.monthly, 4)
    }

    func testEmptyReplicasAreNotDetectedDespitePossibleOverlap() throws {
        try write("transcript.replicas.a", transcript([]))
        try write("transcript.replicas.b", transcript([]))
        let result = try collect()
        XCTAssertEqual(result.transcriptState, .notDetected)
        XCTAssertTrue(result.transcriptsMayOverlap)
        XCTAssertNil(result.estimatedUsage)
        try write("transcript.replicas.b", transcript([NSNull()]))
        XCTAssertEqual(try collect().transcriptState, .invalid)
    }

    func testInvalidBase32NamesAreNotOpened() throws {
        let valid = "O5SWK23MPEWXK43BM5SS4Y3BMNUGKLRQ"
        let badNames = [valid.replacingOccurrences(of: "SS", with: "ß") + ".blob",
                        valid + "A.blob", "O5SWK23MPEWXK43BM5SS4Y3BMNUGL.blob"]
        for name in badNames {
            try Data(repeating: 0x7f, count: 1024).write(to: root.appendingPathComponent(name))
        }
        var limits = StoreGrokCollector.Limits()
        limits.jsonBytes = 16
        var opened: [[String]] = []
        let result = try collect(limits, beforeOpen: { opened.append($0) })
        XCTAssertEqual(result.quotaState, .notDetected)
        XCTAssertTrue(opened.isEmpty)
    }
}
