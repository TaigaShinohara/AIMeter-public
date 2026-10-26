import XCTest
import Foundation
import AIMeterCore

final class SelectiveLogStreamingTests: XCTestCase {
    private var root: URL!
    private let marker = "\"token_count\""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func input(lineBytes: Int = 64) -> BoundedInput {
        var limits = BoundedInput.Limits()
        limits.lineBytes = lineBytes
        return BoundedInput(limits: limits)
    }

    private func write(_ data: Data, name: String = "session.jsonl") throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func assertLimit<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case BoundedInput.Failure.limit = error else {
                XCTFail("Expected input limit, got \(type(of: error))", file: file, line: line)
                return
            }
        }
    }

    func testLiteralMarkerAcrossReadBoundaryIsDelivered() throws {
        var bytes = Data(repeating: 120, count: 32 * 1024 - 4)
        bytes.append(Data(marker.utf8))
        bytes.append(Data(" payload\n".utf8))
        let url = try write(bytes)
        var lines: [String] = []
        try input(lineBytes: 64 * 1024).lines(at: url, containing: marker) { lines.append($0) }
        XCTAssertEqual(lines, [String(decoding: bytes.dropLast(), as: UTF8.self)])
    }

    func testOversizedNonUTF8UnrelatedLineIsSkippedAndNextUsageIsDelivered() throws {
        var bytes = Data(repeating: 0xff, count: 128 * 1024)
        let expected = "{\"type\":\"token_count\"}"
        bytes.append(Data("\n\(expected)\n".utf8))
        let url = try write(bytes)
        var lines: [String] = []
        try input().lines(at: url, containing: marker) { lines.append($0) }
        XCTAssertEqual(lines, [expected])
    }

    func testMarkerFoundAfterDiscardIncludingAcrossReadBoundaryStillRejectsLine() throws {
        var bytes = Data(repeating: 120, count: 32 * 1024 - 4)
        bytes.append(Data(marker.utf8))
        bytes.append(Data("\n".utf8))
        let url = try write(bytes)
        var calls = 0
        assertLimit(try input().lines(at: url, containing: marker) { _ in calls += 1 })
        XCTAssertEqual(calls, 0)
    }

    func testMatchingLineCannotExceedLimitBeforeOrAfterItsMarker() throws {
        for (index, bytes) in [
            Data((marker + String(repeating: "x", count: 100)).utf8),
            Data((String(repeating: "x", count: 100) + marker).utf8)
        ].enumerated() {
            let url = try write(bytes, name: "usage-\(index).jsonl")
            assertLimit(try input().lines(at: url, containing: marker) { _ in XCTFail("Oversized usage was delivered") })
        }
    }

    func testEOFDeliversMatchingLineAndDropsOversizedUnrelatedLine() throws {
        let expected = "{\"type\":\"token_count\"}"
        var lines: [String] = []
        let matching = try write(Data(expected.utf8))
        try input().lines(at: matching, containing: marker) { lines.append($0) }
        XCTAssertEqual(lines, [expected])

        let unrelated = try write(Data(repeating: 120, count: 70 * 1024), name: "unrelated.jsonl")
        try input().lines(at: unrelated, containing: marker) { _ in XCTFail("Unrelated EOF line was delivered") }
    }

    func testMarkerTailDoesNotMatchAcrossNewline() throws {
        // Each half is shorter than the limit; the first two lines must not be
        // joined into a marker by the overlap buffer.
        let url = try write(Data("\"token_\ncount\"\n\(marker)".utf8))
        var lines: [String] = []
        try input().lines(at: url, containing: marker) { lines.append($0) }
        XCTAssertEqual(lines, [marker])
    }

    func testDefaultAndEmptyMarkerKeepStrictLineAndEncodingChecks() throws {
        let empty = try write(Data(), name: "empty.jsonl")
        assertLimit(try input().lines(at: empty, containing: String(repeating: "x", count: 65)) { _ in })

        let oversized = try write(Data(repeating: 120, count: 65))
        assertLimit(try input().lines(at: oversized) { _ in })
        assertLimit(try input().lines(at: oversized, containing: "") { _ in })

        let invalid = try write(Data([0xff, 10]), name: "invalid.jsonl")
        XCTAssertThrowsError(try input().lines(at: invalid) { _ in }) { error in
            guard case BoundedInput.Failure.encoding = error else {
                return XCTFail("Expected strict UTF-8 rejection")
            }
        }
        try input().lines(at: invalid, containing: marker) { _ in XCTFail("Unrelated invalid bytes were delivered") }
        var invalidMatching = Data(marker.utf8)
        invalidMatching.append(0xff)
        let matching = try write(invalidMatching, name: "invalid-usage.jsonl")
        XCTAssertThrowsError(try input().lines(at: matching, containing: marker) { _ in }) { error in
            guard case BoundedInput.Failure.encoding = error else {
                return XCTFail("Expected matching-line UTF-8 rejection")
            }
        }
    }

    func testSkippingDoesNotBypassFileTotalByteOrCancellationBudgets() throws {
        let url = try write(Data(repeating: 120, count: 80))
        var limits = BoundedInput.Limits()
        limits.fileBytes = 64
        assertLimit(try BoundedInput(limits: limits).lines(at: url, containing: marker) { _ in })

        let first = try write(Data(repeating: 120, count: 64), name: "first.jsonl")
        let second = try write(Data(repeating: 120, count: 64), name: "second.jsonl")
        limits = .init()
        limits.lineBytes = 16
        limits.totalBytes = 96
        let budget = BoundedInput(limits: limits)
        try budget.lines(at: first, containing: marker) { _ in }
        assertLimit(try budget.lines(at: second, containing: marker) { _ in })

        let large = try write(Data(repeating: 120, count: 256 * 1024), name: "cancel.jsonl")
        var checks = 0
        let cancelled = BoundedInput(cancelled: {
            checks += 1
            return checks > 8
        })
        XCTAssertThrowsError(try cancelled.lines(at: large, containing: marker) { _ in }) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}
