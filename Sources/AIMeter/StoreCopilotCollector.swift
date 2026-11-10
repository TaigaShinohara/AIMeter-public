import Foundation
import AIMeterCore

/// Prototype only. The caller holds the security scope and owns the root FD.
/// Message counts and cumulative checkpoints are deliberately not conflated.
/// Unlike the direct collector, each checkpoint retains its own event time;
/// an older maximum is never assigned a newer checkpoint's time. Checkpoints
/// are estimates, and this prototype is not connected to production UI.
enum StoreCopilotCollector {
    enum State: Equatable { case unselected, notDetected, invalid, partial, complete }
    struct Checkpoint: Equatable {
        let timestamp: Date
        let premiumRequestCost: Double
    }
    struct Result: Equatable {
        let state: State
        /// Nil means no valid user.message was found, not a confirmed zero.
        let messageCounts: ProviderPeriodUsageJSON?
        /// Latest observed checkpoint per file. These are cumulative and have
        /// no proven period start; they are not rolling-window consumption.
        let checkpoints: [Checkpoint]
        /// Files whose latest timestamp has conflicting values.
        let indeterminateCheckpoints: Int
    }
    struct Limits {
        var tree = StoreSafeFileTree.Limits()
        var jsonBytes = 1024 * 1024
    }

    static func collect(rootFD: Int32?, limits: Limits = .init(), now: Date = Date()) throws -> Result {
        guard let rootFD else { return Result(state: .unselected, messageCounts: nil, checkpoints: [], indeterminateCheckpoints: 0) }
        guard limits.jsonBytes > 0, limits.tree.lineBytes > 0 else { throw StoreSafeFileTree.Failure.limit }
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let cutoffs = LocalUsageCollector.calculateCutoffs(now: now)
        let keys = ["2h", "5h", "1d", "7d", "30d"]
        var counts = [Int](repeating: 0, count: 5)
        var validMessages = 0, validCheckpoints = 0, invalid = 0
        var checkpoints: [Checkpoint] = []
        var timestampCount = 0, indeterminate = 0
        _ = try StoreSafeFileTree.read(rootDirectoryFD: rootFD, limits: limits.tree,
            includeFile: { path, metadata in
                path.last == "events.jsonl" && metadata.modificationTime >= cutoff
            }, descendDirectory: { path, _ in
                guard let name = path.last else { return false }
                return !name.hasPrefix(".")
            }, visitFile: { _, _, nextChunk in
                var pending = Data()
                var values: [Date: Double] = [:]
                var conflicts: Set<Date> = []
                var latestDate: Date?
                func accept(_ data: Data) throws {
                    guard !data.isEmpty else { return }
                    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        invalid += 1; return
                    }
                    guard let type = object["type"] as? String else { return }
                    guard type == "user.message" || type == "session.usage_checkpoint" else { return }
                    guard let rawTime = object["timestamp"] as? String,
                          let date = LocalUsageCollector.parseISODate(rawTime), date <= now else { invalid += 1; return }
                    if type == "user.message" {
                        validMessages += 1
                        for (index, key) in keys.enumerated() where date >= (cutoffs[key] ?? cutoff) {
                            counts[index] = try UsageNumber.add(counts[index], 1)
                        }
                        return
                    }
                    guard let payload = object["data"] as? [String: Any],
                          let accounting = payload["accountingSnapshot"] as? [String: Any],
                          let raw = accounting["totalPremiumRequestCost"], !(raw is NSNull),
                          let value = try? UsageNumber.nonnegative(raw) else { invalid += 1; return }
                    validCheckpoints += 1
                    if let previous = values[date] {
                        if previous != value && conflicts.insert(date).inserted { invalid += 1 }
                    } else {
                        guard timestampCount < limits.tree.entries else { throw StoreSafeFileTree.Failure.limit }
                        timestampCount += 1
                        values[date] = value
                    }
                    if latestDate == nil || date > latestDate! { latestDate = date }
                }
                func append(_ bytes: Data) throws {
                    guard bytes.count <= limits.tree.lineBytes - pending.count,
                          bytes.count <= limits.jsonBytes - pending.count else { throw StoreSafeFileTree.Failure.limit }
                    pending.append(bytes)
                }
                while true {
                    let chunk = try nextChunk()
                    if chunk.isEmpty { break }
                    var start = chunk.startIndex
                    while let end = chunk[start...].firstIndex(of: 10) {
                        try append(chunk[start..<end])
                        try accept(pending)
                        pending.removeAll(keepingCapacity: true)
                        start = end + 1
                    }
                    if start < chunk.endIndex { try append(chunk[start...]) }
                }
                if !pending.isEmpty { try accept(pending) }
                if let latestDate {
                    if conflicts.contains(latestDate) { indeterminate += 1 }
                    else if let value = values[latestDate] {
                        checkpoints.append(Checkpoint(timestamp: latestDate, premiumRequestCost: value))
                    }
                }
            })
        let valid = validMessages + validCheckpoints
        let state: State = valid == 0 ? (invalid == 0 ? .notDetected : .invalid) : (invalid == 0 ? .complete : .partial)
        let periods: ProviderPeriodUsageJSON? = validMessages > 0 ?
            ProviderPeriodUsageJSON(twoHours: counts[0], fiveHours: counts[1], daily: counts[2], weekly: counts[3], monthly: counts[4]) : nil
        checkpoints.sort { $0.timestamp == $1.timestamp ? $0.premiumRequestCost < $1.premiumRequestCost : $0.timestamp < $1.timestamp }
        return Result(state: state, messageCounts: periods, checkpoints: checkpoints, indeterminateCheckpoints: indeterminate)
    }
}
