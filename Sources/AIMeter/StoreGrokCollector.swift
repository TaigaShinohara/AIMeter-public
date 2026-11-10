import Foundation
import AIMeterCore

/// Experimental FD-only collector; the caller owns the security scope and root FD.
/// Transcript values are character-length estimates, not measured tokens. Quota
/// is independent and never converted into a fabricated token allowance. Unlike
/// the direct collector, conflicting caches are not selected by traversal order.
/// This prototype is not connected to the UI and has not been checked with real data.
enum StoreGrokCollector {
    enum State: Equatable { case unselected, notDetected, invalid, partial, complete }
    enum Freshness: Equatable { case unverified }
    struct Quota: Equatable {
        let percent: Double?
        let resetSeconds: Int?
        let costUSD: Double?
        let plan: String?
        /// Collection time, not the cache's update time or proof of current quota.
        let observedAt: Date
        let freshness: Freshness
    }
    struct Result: Equatable {
        let quotaState: State
        let quota: Quota?
        let transcriptState: State
        let estimatedUsage: ProviderPeriodUsageJSON?
        /// Multiple replica files have no established identity or deduplication key.
        let transcriptsMayOverlap: Bool
    }
    struct Limits {
        var tree = StoreSafeFileTree.Limits()
        var jsonBytes = 8 * 1024 * 1024
    }

    private enum Kind { case quota, transcript }

    // Decode only bounded filenames. Reject malformed alphabet/padding instead of
    // skipping characters that could make an unrelated key appear relevant.
    private static func kind(_ name: String) -> Kind? {
        guard name.hasSuffix(".blob") else { return nil }
        let encoded = Array(name.dropLast(5).utf8)
        guard !encoded.isEmpty, [0, 2, 4, 5, 7].contains(encoded.count % 8) else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var accumulator = 0, bits = 0
        var bytes: [UInt8] = []
        for raw in encoded {
            let byte: UInt8
            if (97...122).contains(raw) { byte = raw - 32 } else { byte = raw }
            guard let index = alphabet.firstIndex(of: byte) else { return nil }
            accumulator = (accumulator << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 255))
                accumulator &= (1 << bits) - 1
            }
        }
        guard accumulator == 0, let key = String(bytes: bytes, encoding: .utf8) else { return nil }
        if key.contains("weekly-usage.cache") { return .quota }
        if key.contains("transcript.replicas.") { return .transcript }
        return nil
    }

    static func collect(rootFD: Int32?, limits: Limits = .init(), now: Date = Date(),
                        beforeOpen: ([String]) throws -> Void = { _ in }) throws -> Result {
        guard let rootFD else {
            return Result(quotaState: .unselected, quota: nil, transcriptState: .unselected, estimatedUsage: nil, transcriptsMayOverlap: false)
        }
        guard limits.jsonBytes > 0 else { throw StoreSafeFileTree.Failure.limit }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.tree.seconds
        func check() throws {
            guard !Task.isCancelled else { throw StoreSafeFileTree.Failure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw StoreSafeFileTree.Failure.limit }
        }
        let cutoff = LocalUsageCollector.calculateCutoffs(now: now)
        let keys = ["2h", "5h", "1d", "7d", "30d"]
        var counts = [Int](repeating: 0, count: 5)
        var quotaValid = 0, quotaInvalid = 0, transcriptValid = 0, transcriptInvalid = 0
        var quota: Quota?, conflict = false, transcriptFiles = 0
        _ = try StoreSafeFileTree.read(rootDirectoryFD: rootFD, limits: limits.tree,
            includeFile: { path, _ in path.last.flatMap(kind) != nil },
            descendDirectory: { path, _ in path.last.map { !$0.hasPrefix(".") } ?? false },
            beforeOpen: beforeOpen, visitFile: { path, metadata, next in
                try check()
                guard let name = path.last, let kind = kind(name) else { throw StoreSafeFileTree.Failure.invalidEntry }
                if kind == .transcript { transcriptFiles += 1 }
                guard metadata.size <= Int64(limits.jsonBytes) else { throw StoreSafeFileTree.Failure.limit }
                var data = Data()
                while true {
                    let chunk = try next()
                    if chunk.isEmpty { break }
                    guard chunk.count <= limits.jsonBytes - data.count else { throw StoreSafeFileTree.Failure.limit }
                    data.append(chunk)
                }
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let value = root["value"] as? [String: Any] else {
                    if kind == .quota { quotaInvalid += 1 } else { transcriptInvalid += 1 }
                    return
                }
                try check()
                if kind == .quota {
                    guard let reading = value["reading"] as? [String: Any],
                          let usage = reading["usage"] as? [String: Any] else { quotaInvalid += 1; return }
                    func number(_ key: String) throws -> Double? {
                        guard let raw = usage[key] else { return nil }
                        guard !(raw is NSNull) else { throw UsageNumber.Invalid.number }
                        return try UsageNumber.nonnegative(raw)
                    }
                    do {
                        let percent = try number("percentUsed")
                        let reset: Int?
                        if let raw = usage["nextResetMs"] {
                            guard !(raw is NSNull) else { throw UsageNumber.Invalid.number }
                            reset = try UsageNumber.count(raw) / 1000
                        } else { reset = nil }
                        var cost: Double?
                        if let raw = usage["onDemand"] {
                            guard let demand = raw as? [String: Any], let cents = demand["usedCents"], !(cents is NSNull) else { throw UsageNumber.Invalid.number }
                            cost = try UsageNumber.nonnegative(cents) / 100
                        }
                        var plan: String?
                        if let raw = usage["grokPlanLabel"] {
                            guard let label = raw as? String, !label.isEmpty else { throw UsageNumber.Invalid.number }
                            plan = LocalUsageCollector.safePlan(label, provider: "grokbot")
                        }
                        guard percent != nil || reset != nil || cost != nil || plan != nil else { throw UsageNumber.Invalid.number }
                        let candidate = Quota(percent: percent, resetSeconds: reset, costUSD: cost, plan: plan,
                                              observedAt: now, freshness: .unverified)
                        quotaValid += 1
                        if let previous = quota, previous != candidate { conflict = true }
                        else if quota == nil { quota = candidate }
                    } catch is UsageNumber.Invalid { quotaInvalid += 1 }
                } else {
                    guard let entries = value["entries"] as? [Any] else { transcriptInvalid += 1; return }
                    for item in entries {
                        try check()
                        guard let entry = item as? [String: Any], let rawTime = entry["timestampMs"], !(rawTime is NSNull),
                              let milliseconds = try? UsageNumber.nonnegative(rawTime),
                              let content = (entry["content"] as? String) ?? (entry["message"] as? String), !content.isEmpty else {
                            transcriptInvalid += 1; continue
                        }
                        let date = Date(timeIntervalSince1970: milliseconds / 1000)
                        guard date <= now else { transcriptInvalid += 1; continue }
                        transcriptValid += 1
                        let estimate = max(1, content.count / 3)
                        for (index, key) in keys.enumerated() where date >= (cutoff[key] ?? now) {
                            counts[index] = try UsageNumber.add(counts[index], estimate)
                        }
                    }
                }
            })
        func state(_ valid: Int, _ invalid: Int) -> State {
            valid == 0 ? (invalid == 0 ? .notDetected : .invalid) : (invalid == 0 ? .complete : .partial)
        }
        let periods = transcriptValid > 0 ? ProviderPeriodUsageJSON(twoHours: counts[0], fiveHours: counts[1], daily: counts[2], weekly: counts[3], monthly: counts[4]) : nil
        let mayOverlap = transcriptFiles > 1
        return Result(quotaState: state(quotaValid, quotaInvalid + (conflict ? 1 : 0)), quota: conflict ? nil : quota,
                      transcriptState: state(transcriptValid, transcriptInvalid + (mayOverlap && transcriptValid > 0 ? 1 : 0)),
                      estimatedUsage: periods, transcriptsMayOverlap: mayOverlap)
    }
}
