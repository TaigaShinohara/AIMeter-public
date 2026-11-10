import Foundation
import CryptoKit
import AIMeterCore

/// Experimental only. The caller owns each optional security-scoped directory FD.
/// A nil FD is unselected; no fallback path is consulted.
enum StoreGeminiCollector {
    enum SourceState: Equatable { case unselected, invalid, partial, complete }
    struct Result: Equatable {
        let brain: SourceState
        let chats: SourceState
        let used: ProviderPeriodUsageJSON
        let raw: ProviderPeriodUsageJSON
        let cost: Double
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
        var used = [Int](repeating: 0, count: 5), raw = used
        let intervals: [TimeInterval] = [7200, 18000, 86400, 604800, 2592000]
        var cost = 0.0
        func add(date: Date, effective: Int, rawCount: Int, stepCost: Double) throws {
            try check()
            for i in intervals.indices where date >= now.addingTimeInterval(-intervals[i]) {
                used[i] = try UsageNumber.add(used[i], effective)
                raw[i] = try UsageNumber.add(raw[i], rawCount)
            }
            if date >= cutoff { cost = try UsageNumber.add(cost, stepCost) }
        }
        var brainValid = 0, brainInvalid = 0
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
                        } else {
                            let content = (obj["content"] as? String ?? "") + (obj["thinking"] as? String ?? "")
                            guard !content.isEmpty else { brainInvalid += 1; continue }
                            effective = max(1, content.count / 4); rawCount = effective
                            stepCost = Double(effective) * 2 / 1_000_000
                        }
                        brainValid += 1
                        guard date >= cutoff else { continue }
                        if files.count > 1 {
                            let canonical = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
                            let fingerprint = Data(SHA256.hash(data: canonical))
                            if index == 0 { unmatched[fingerprint, default: 0] += 1 }
                            else if let count = unmatched[fingerprint], count > 0 { unmatched[fingerprint] = count - 1; continue }
                        }
                        try add(date: date, effective: effective, rawCount: rawCount, stepCost: stepCost)
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
                            stepCost: (Double(uncached) * 1.25 + Double(cached) * 0.3125 + Double(out) * 5) / 1_000_000)
                }
            }
        }
        func state(_ selected: Bool, _ valid: Int, _ invalid: Int) -> SourceState {
            if !selected { return .unselected }
            if valid == 0 { return .invalid }
            return invalid > 0 ? .partial : .complete
        }
        func periods(_ a: [Int]) -> ProviderPeriodUsageJSON {
            ProviderPeriodUsageJSON(twoHours: a[0], fiveHours: a[1], daily: a[2], weekly: a[3], monthly: a[4])
        }
        return Result(brain: state(brainFD != nil, brainValid, brainInvalid), chats: state(chatsFD != nil, chatValid, chatInvalid),
                      used: periods(used), raw: periods(raw), cost: round(cost * 100) / 100)
    }
}
