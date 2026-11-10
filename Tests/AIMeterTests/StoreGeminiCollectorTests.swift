import XCTest
import Foundation
import Darwin
import AIMeterCore
@testable import AIMeter

final class StoreGeminiCollectorTests: XCTestCase {
    private var root: URL!
    private var brain: URL { root.appendingPathComponent("brain") }
    private var chats: URL { root.appendingPathComponent("tmp") }
    private let now = Date()
    private var timestamp: String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func collect(brain selectedBrain: Bool = true, chats selectedChats: Bool = true,
                         limits: StoreGeminiCollector.Limits = .init()) throws -> StoreGeminiCollector.Result {
        let b = selectedBrain ? Darwin.open(brain.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1
        let c = selectedChats ? Darwin.open(chats.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1
        defer { if b >= 0 { Darwin.close(b) }; if c >= 0 { Darwin.close(c) } }
        if selectedBrain && b < 0 || selectedChats && c < 0 { throw StoreSafeFileTree.Failure.invalidRoot }
        return try StoreGeminiCollector.collect(brainFD: selectedBrain ? b : nil, chatsFD: selectedChats ? c : nil,
                                                limits: limits, now: now)
    }
    func testMatchesExistingDeduplicationAndChatCalculation() throws {
        let first = "{\"created_at\":\"\(timestamp)\",\"input_tokens\":1000000,\"cache_read_tokens\":500000,\"output_tokens\":250000,\"metadata\":{\"a\":1,\"b\":2}}"
        let reordered = "{\"metadata\":{\"b\":2,\"a\":1},\"output_tokens\":250000,\"input_tokens\":1000000,\"cache_read_tokens\":500000,\"created_at\":\"\(timestamp)\"}"
        try write(brain.appendingPathComponent("session/.system_generated/logs/transcript.jsonl"), first + "\n" + first)
        try write(brain.appendingPathComponent("session/.system_generated/logs/transcript_full.jsonl"), reordered)
        let chat = "{\"messages\":[{\"timestamp\":\"\(timestamp)\",\"tokens\":{\"total\":110,\"input\":100,\"cached\":20,\"output\":10}}]}"
        try write(chats.appendingPathComponent("a/chats/session.json"), chat)
        let result = try collect()
        let direct = try LocalUsageCollector.collectStoreSources(["gemini.brain": brain, "gemini.chats": chats], home: root, now: now)
        XCTAssertEqual(result.brain, .complete)
        XCTAssertEqual(result.chats, .complete)
        XCTAssertEqual(result.used, direct.geminiUsedByPeriod)
        XCTAssertEqual(result.cost, direct.geminiCostUSD)
        XCTAssertEqual(result.used.monthly, 2_600_092)
    }
    func testSelectionAndInvalidPartialStates() throws {
        let row = "{\"created_at\":\"\(timestamp)\",\"input_tokens\":12,\"output_tokens\":1}"
        try write(brain.appendingPathComponent("s/transcript.jsonl"), row + "\n{bad}")
        try write(chats.appendingPathComponent("a/chats/bad.json"), "{bad}")
        let result = try collect()
        XCTAssertEqual(result.brain, .partial)
        XCTAssertEqual(result.chats, .invalid)
        XCTAssertEqual(try collect(brain: false, chats: false).brain, .unselected)
        XCTAssertEqual(try collect(brain: true, chats: false).chats, .unselected)
        XCTAssertEqual(try collect(brain: false, chats: true).used.monthly, 0)
    }
    func testSharedByteBudgetAndPerFormatLimitsFailClosed() throws {
        let row = "{\"created_at\":\"\(timestamp)\",\"input_tokens\":12,\"output_tokens\":1}"
        let chat = "{\"messages\":[{\"timestamp\":\"\(timestamp)\",\"tokens\":{\"total\":1}}]}"
        try write(brain.appendingPathComponent("s/transcript.jsonl"), row)
        try write(chats.appendingPathComponent("a/chats/x.json"), chat)
        var limits = StoreGeminiCollector.Limits()
        limits.tree.totalBytes = row.utf8.count + chat.utf8.count - 1
        XCTAssertThrowsError(try collect(limits: limits))
        limits.tree.totalBytes = 10_000
        limits.jsonBytes = chat.utf8.count - 1
        XCTAssertThrowsError(try collect(limits: limits))
        limits.jsonBytes = 10_000
        limits.tree.lineBytes = row.utf8.count - 1
        XCTAssertThrowsError(try collect(limits: limits))
    }

    func testBrainSeparatesValidZeroMissingValuesAndTextEstimate() throws {
        let zero = "{\"created_at\":\"\(timestamp)\",\"input_tokens\":0,\"output_tokens\":0}"
        let missing = "{\"created_at\":\"\(timestamp)\"}"
        let estimate = "{\"created_at\":\"\(timestamp)\",\"content\":\"abcdefgh\"}"
        let file = brain.appendingPathComponent("s/transcript.jsonl")
        try write(file, zero)
        let onlyZero = try collect(chats: false)
        XCTAssertEqual(onlyZero.brain, .complete)
        XCTAssertEqual(onlyZero.used.monthly, 0)
        try write(file, zero + "\n" + missing + "\n" + estimate)
        let mixed = try collect(chats: false)
        XCTAssertEqual(mixed.brain, .partial)
        XCTAssertEqual(mixed.used.monthly, 2)
    }

    func testChatsKeepValidMessagesWhenOtherEntriesAreInvalid() throws {
        let chat = """
        {"messages":[{"timestamp":"\(timestamp)","tokens":{"total":110,"input":100,"cached":20,"output":10}},null,{"tokens":"bad"},{"role":"user"}]}
        """
        try write(chats.appendingPathComponent("a/chats/session.json"), chat)
        let result = try collect(brain: false)
        XCTAssertEqual(result.chats, .partial)
        XCTAssertEqual(result.used.monthly, 92)
    }

    func testNullCachedTokensDoNotBecomeACompleteZeroCache() throws {
        let chat = """
        {"messages":[{"timestamp":"\(timestamp)","tokens":{"total":110,"input":100,"cached":null,"output":10}}]}
        """
        try write(chats.appendingPathComponent("a/chats/session.json"), chat)
        let result = try collect(brain: false)
        XCTAssertEqual(result.chats, .invalid)
    }

    func testEntryAndFileBudgetsAreSharedAcrossRoots() throws {
        let row = "{\"created_at\":\"\(timestamp)\",\"input_tokens\":1,\"output_tokens\":0}"
        let chat = "{\"messages\":[{\"timestamp\":\"\(timestamp)\",\"tokens\":{\"total\":1,\"input\":1,\"output\":0}}]}"
        try write(brain.appendingPathComponent("s/transcript.jsonl"), row)
        try write(chats.appendingPathComponent("s/chats/session.json"), chat)
        var limits = StoreGeminiCollector.Limits()
        limits.tree.entries = 3 // Each root individually fits; their total does not.
        XCTAssertThrowsError(try collect(limits: limits))
        limits.tree.entries = 100
        limits.tree.files = 1 // Both selected files must share this budget.
        XCTAssertThrowsError(try collect(limits: limits))
    }
}
