import Foundation
import CryptoKit
import AIMeterCore

/// Experimental only. The caller owns each optional security-scoped directory FD.
/// A nil FD is unselected; no fallback path is consulted.
enum StoreGeminiCollector {
    enum SourceState: Equatable { case unselected, notDetected, invalid, partial, complete }
    struct Result: Equatable {
        let brain: SourceState
        let chats: SourceState
        /// Period totals aggregated from both inputs together. Kept for
        /// the existing combined consumers; a caller that presents one
        /// input's values must use the separated totals below instead,
        /// never this sum.
        let used: ProviderPeriodUsageJSON
        let raw: ProviderPeriodUsageJSON
        let cost: Double
        /// True only when an included brain record used the text-length estimate.
        let brainUsesEstimate: Bool
        /// Period totals aggregated from the brain input alone. Brain
        /// records without token values fall back to a text-length
        /// estimate, so these totals can include estimated values (see
        /// `brainUsesEstimate`); the first Store release does not
        /// present them in any frame.
        var brainUsed: ProviderPeriodUsageJSON = ProviderPeriodUsageJSON()
        /// Period totals aggregated from the chats input alone. The
        /// chats parser has no estimate path: a message counts only
        /// when its full token breakdown is present, so these totals
        /// are measured values, already separated from every brain
        /// record (docs/STORE_CONNECTION_DESIGN.md, stage 6).
        var chatsUsed: ProviderPeriodUsageJSON = ProviderPeriodUsageJSON()
        /// Cost aggregated from the brain input alone.
        var brainCost: Double = 0
        /// Cost aggregated from the chats input alone.
        var chatsCost: Double = 0
    }
    struct Limits {
        var tree = StoreSafeFileTree.Limits()
        var jsonBytes = 8 * 1024 * 1024
    }
    private struct InputFile {
        let path: [String]
        let data: Data
    }

    static func collect(brainFD: Int32?, chatsFD: Int32?, limits: Limits = .init(),
                        now: Date = Date()) throws -> Result {
        guard limits.jsonBytes > 0, limits.tree.lineBytes > 0, limits.tree.totalBytes >= 0 else {
            throw StoreSafeFileTree.Failure.limit
        }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.tree.seconds
        var consumed = 0
        var totalEntries = 0, totalFiles = 0
        let cutoff = now.addingTimeInterval(-30 * 86400)
        func check() throws {
            guard !Task.isCancelled else { throw StoreSafeFileTree.Failure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw StoreSafeFileTree.Failure.limit }
        }
        func scan(_ fd: Int32, brain: Bool) throws -> [InputFile] {
            var files: [InputFile] = []
            var treeLimits = limits.tree
            treeLimits.seconds = deadline - ProcessInfo.processInfo.systemUptime
            treeLimits.totalBytes = limits.tree.totalBytes - consumed
            guard treeLimits.seconds > 0 else { throw StoreSafeFileTree.Failure.limit }
            _ = try StoreSafeFileTree.read(rootDirectoryFD: fd, limits: treeLimits, includeFile: { path, metadata in
                guard let name = path.last, metadata.modificationTime >= cutoff else { return false }
                if brain { return name == "transcript.jsonl" || name == "transcript_full.jsonl" }
                return name.hasSuffix(".json") && path.dropLast().contains("chats")
            }, descendDirectory: { path, _ in
                guard let name = path.last else { return false }
                return !name.hasPrefix(".") || (brain && name == ".system_generated")
            }, onEntry: {
                guard totalEntries < limits.tree.entries else { throw StoreSafeFileTree.Failure.limit }
                totalEntries += 1
            }, onFile: {
                guard totalFiles < limits.tree.files else { throw StoreSafeFileTree.Failure.limit }
                totalFiles += 1
            }, visitFile: { path, _, next in
                var data = Data()
                while true {
                    try check()
                    let chunk = try next()
                    if chunk.isEmpty { break }
                    guard chunk.count <= limits.tree.totalBytes - consumed else { throw StoreSafeFileTree.Failure.limit }
                    consumed += chunk.count
                    if !brain && chunk.count > limits.jsonBytes - data.count { throw StoreSafeFileTree.Failure.limit }
                    data.append(chunk)
                }
                files.append(InputFile(path: path, data: data))
            })
            return files.sorted { $0.path.lexicographicallyPrecedes($1.path) }
        }
        let brainFiles = try brainFD.map { try scan($0, brain: true) }
        let chatFiles = try chatsFD.map { try scan($0, brain: false) }
        // Aggregation is tracked per input from the start, so each
        // input's totals can be reported on their own; the combined
        // totals returned in `used`/`raw`/`cost` are the element-wise
        // sums of the two, exactly as the single-accumulator version
        // produced.
        var brainUsed = [Int](repeating: 0, count: 5), brainRaw = brainUsed
        var chatsUsed = [Int](repeating: 0, count: 5), chatsRaw = chatsUsed
        let intervals: [TimeInterval] = [7200, 18000, 86400, 604800, 2592000]
        var brainCost = 0.0, chatsCost = 0.0
        func add(date: Date, effective: Int, rawCount: Int, stepCost: Double,
                 used: inout [Int], raw: inout [Int], cost: inout Double) throws {
            try check()
            for i in intervals.indices where date >= now.addingTimeInterval(-intervals[i]) {
                used[i] = try UsageNumber.add(used[i], effective)
                raw[i] = try UsageNumber.add(raw[i], rawCount)
            }
            if date >= cutoff { cost = try UsageNumber.add(cost, stepCost) }
        }
        var brainValid = 0, brainInvalid = 0
        var brainUsesEstimate = false
        if let brainFiles {
            let groups = Dictionary(grouping: brainFiles) { Array($0.path.dropLast()) }
            for key in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let files = groups[key]!.sorted { $0.path.lexicographicallyPrecedes($1.path) }
                var unmatched: [Data: Int] = [:]
                for (index, file) in files.enumerated() {
                    for line in file.data.split(separator: 10, omittingEmptySubsequences: false) {
                        try check()
                        guard line.count <= limits.tree.lineBytes, line.count <= limits.jsonBytes else {
                            throw StoreSafeFileTree.Failure.limit
                        }
                        if line.isEmpty { continue }
                        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                              let timestamp = obj["created_at"] as? String,
                              let date = LocalUsageCollector.parseISODate(timestamp) else { brainInvalid += 1; continue }
                        let effective: Int, rawCount: Int, stepCost: Double
                        let estimated: Bool
                        let tokenKeys = ["input_tokens", "cache_read_tokens", "output_tokens"]
                        let hasTokenValues = tokenKeys.contains { obj[$0] != nil }
                        if hasTokenValues {
                            guard let input = obj["input_tokens"], !(input is NSNull),
                                  let output = obj["output_tokens"], !(output is NSNull),
                                  !(obj["cache_read_tokens"] is NSNull),
                                  let inp = try? UsageNumber.count(input),
                                  let cached = try? UsageNumber.count(obj["cache_read_tokens"]),
                                  let out = try? UsageNumber.count(output) else { brainInvalid += 1; continue }
                            let sum = try UsageNumber.sum([inp, cached, out])
                            effective = try UsageNumber.sum([inp, out, cached / 10]); rawCount = sum
                            stepCost = (Double(inp) * 1.25 + Double(cached) * 0.3125 + Double(out) * 5) / 1_000_000
                            estimated = false
                        } else {
                            let content = (obj["content"] as? String ?? "") + (obj["thinking"] as? String ?? "")
                            guard !content.isEmpty else { brainInvalid += 1; continue }
                            effective = max(1, content.count / 4); rawCount = effective
                            stepCost = Double(effective) * 2 / 1_000_000
                            estimated = true
                        }
                        brainValid += 1
                        guard date >= cutoff else { continue }
                        if files.count > 1 {
                            let canonical = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
                            let fingerprint = Data(SHA256.hash(data: canonical))
                            if index == 0 { unmatched[fingerprint, default: 0] += 1 }
                            else if let count = unmatched[fingerprint], count > 0 { unmatched[fingerprint] = count - 1; continue }
                        }
                        if estimated { brainUsesEstimate = true }
                        try add(date: date, effective: effective, rawCount: rawCount, stepCost: stepCost,
                                used: &brainUsed, raw: &brainRaw, cost: &brainCost)
                    }
                }
            }
        }
        var chatValid = 0, chatInvalid = 0
        if let chatFiles {
            for file in chatFiles {
                try check()
                guard let obj = (try? JSONSerialization.jsonObject(with: file.data)) as? [String: Any],
                      let messages = obj["messages"] as? [Any] else { chatInvalid += 1; continue }
                for item in messages {
                    try check()
                    guard let msg = item as? [String: Any] else { chatInvalid += 1; continue }
                    guard let tokenValue = msg["tokens"] else { continue }
                    guard let tokens = tokenValue as? [String: Any] else { chatInvalid += 1; continue }
                    guard let timestamp = msg["timestamp"] as? String, let date = LocalUsageCollector.parseISODate(timestamp),
                          let totalValue = tokens["total"], !(totalValue is NSNull),
                          let inputValue = tokens["input"], !(inputValue is NSNull),
                          let outputValue = tokens["output"], !(outputValue is NSNull),
                          !(tokens["cached"] is NSNull),
                          let total = try? UsageNumber.count(tokens["total"]),
                          let cached = try? UsageNumber.count(tokens["cached"]),
                          let out = try? UsageNumber.count(tokens["output"]),
                          let inp = try? UsageNumber.count(tokens["input"]), cached <= inp else { chatInvalid += 1; continue }
                    let uncached = try UsageNumber.difference(inp, cached)
                    chatValid += 1
                    try add(date: date, effective: try UsageNumber.sum([uncached, out, cached / 10]), rawCount: total,
                            stepCost: (Double(uncached) * 1.25 + Double(cached) * 0.3125 + Double(out) * 5) / 1_000_000,
                            used: &chatsUsed, raw: &chatsRaw, cost: &chatsCost)
                }
            }
        }
        func state(_ selected: Bool, _ valid: Int, _ invalid: Int) -> SourceState {
            if !selected { return .unselected }
            if valid == 0 { return invalid > 0 ? .invalid : .notDetected }
            return invalid > 0 ? .partial : .complete
        }
        func periods(_ a: [Int]) -> ProviderPeriodUsageJSON {
            ProviderPeriodUsageJSON(twoHours: a[0], fiveHours: a[1], daily: a[2], weekly: a[3], monthly: a[4])
        }
        func combined(_ a: [Int], _ b: [Int]) throws -> [Int] {
            try zip(a, b).map { pair in try UsageNumber.add(pair.0, pair.1) }
        }
        return Result(brain: state(brainFD != nil, brainValid, brainInvalid), chats: state(chatsFD != nil, chatValid, chatInvalid),
                      used: periods(try combined(brainUsed, chatsUsed)), raw: periods(try combined(brainRaw, chatsRaw)),
                      cost: round((brainCost + chatsCost) * 100) / 100,
                      brainUsesEstimate: brainUsesEstimate,
                      brainUsed: periods(brainUsed), chatsUsed: periods(chatsUsed),
                      brainCost: round(brainCost * 100) / 100, chatsCost: round(chatsCost * 100) / 100)
    }
}
