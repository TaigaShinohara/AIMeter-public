import Foundation
import Darwin
import AIMeterCore

/// Prototype. Callers retain active security scopes and own both borrowed FDs.
/// No paths outside the selected directory or selected settings FD are read.
enum StoreClaudeCollector {
    enum LogState: Equatable { case unselected, notDetected, invalid, partial, complete }
    enum SettingsState: Equatable { case unselected, absent, internalValid, externalValid, internalInvalid, externalInvalid }
    enum ProjectsState: Equatable { case unavailable, notDetected, incomplete, complete }
    struct Estimate: Equatable { let tokens: Int; let cost: Double }
    struct Result: Equatable {
        let logs: LogState
        let settings: SettingsState
        let used: ProviderPeriodUsageJSON?
        let logCost: Double?
        let plan: String?
        let projects: ProjectsState
        /// No time range is known for these project totals.
        let undatedProjects: Estimate?
    }
    struct Limits {
        var tree = StoreSafeFileTree.Limits()
        var jsonBytes = 8 * 1024 * 1024
    }

    static func collect(logsFD: Int32?, settingsFD: Int32?, limits: Limits = .init(),
                        now: Date = Date()) throws -> Result {
        guard limits.tree.entries > 0, limits.tree.files > 0, limits.tree.totalBytes >= 0,
              limits.tree.fileBytes >= 0, limits.tree.lineBytes > 0, limits.jsonBytes > 0,
              limits.tree.seconds.isFinite, limits.tree.seconds > 0 else { throw StoreSafeFileTree.Failure.limit }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.tree.seconds
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let intervals: [TimeInterval] = [7200, 18000, 86400, 604800, 2592000]
        var bytes = 0, entries = 0, files = 0
        var used = [Int](repeating: 0, count: 5), cost = 0.0
        var valid = 0, invalid = 0
        var internalData: Data?
        func check() throws {
            guard !Task.isCancelled else { throw StoreSafeFileTree.Failure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw StoreSafeFileTree.Failure.limit }
        }
        func budget(_ size: Int) throws {
            guard size <= limits.tree.totalBytes - bytes else { throw StoreSafeFileTree.Failure.limit }
            bytes += size
        }
        func inspectInternal(_ fd: Int32) throws -> stat? {
            var value = stat()
            if fstatat(fd, ".claude.json", &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
            if errno == ENOENT { return nil }
            throw StoreSafeFileTree.Failure.io
        }
        func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
            a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
            a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
        let expectedInternal: stat?
        if let logsFD {
            var root = stat()
            guard logsFD >= 0, fstat(logsFD, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { throw StoreSafeFileTree.Failure.invalidRoot }
            expectedInternal = try inspectInternal(logsFD)
            // Reject an unsafe or ambiguous internal entry, never fall back to external.
            if let expectedInternal, expectedInternal.st_mode & S_IFMT != S_IFREG { throw StoreSafeFileTree.Failure.invalidEntry }
            _ = try StoreSafeFileTree.read(rootDirectoryFD: logsFD, limits: limits.tree, includeFile: { path, metadata in
                if path == [".claude.json"] { return true }
                guard let name = path.last, !name.hasPrefix(".") else { return false }
                return name.hasSuffix(".jsonl") && metadata.modificationTime >= cutoff
            }, descendDirectory: { path, _ in
                guard let name = path.last else { return false }
                return !name.hasPrefix(".")
            }, onEntry: {
                guard entries < limits.tree.entries else { throw StoreSafeFileTree.Failure.limit }; entries += 1
            }, onFile: {
                guard files < limits.tree.files else { throw StoreSafeFileTree.Failure.limit }; files += 1
            }, visitFile: { path, metadata, next in
                let isSettings = path == [".claude.json"]
                if isSettings {
                    guard let expectedInternal, metadata.device == UInt64(truncatingIfNeeded: expectedInternal.st_dev),
                          metadata.inode == UInt64(expectedInternal.st_ino) else { throw StoreSafeFileTree.Failure.invalidEntry }
                }
                var data = Data()
                while true {
                    try check()
                    let chunk = try next()
                    if chunk.isEmpty { break }
                    try budget(chunk.count)
                    if isSettings && chunk.count > limits.jsonBytes - data.count { throw StoreSafeFileTree.Failure.limit }
                    data.append(chunk)
                }
                if isSettings { internalData = data; return }
                for line in data.split(separator: 10, omittingEmptySubsequences: false) {
                    try check()
                    guard line.count <= limits.tree.lineBytes, line.count <= limits.jsonBytes else { throw StoreSafeFileTree.Failure.limit }
                    if line.isEmpty { continue }
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { invalid += 1; continue }
                    let message = obj["message"] as? [String: Any]
                    guard let usageValue = message?["usage"] ?? obj["usage"] else { continue }
                    guard let usage = usageValue as? [String: Any] else { invalid += 1; continue }
                    guard let timestamp = (obj["timestamp"] as? String) ?? (obj["createdAt"] as? String),
                          let date = LocalUsageCollector.parseISODate(timestamp),
                          let inputValue = usage["input_tokens"], !(inputValue is NSNull),
                          let outputValue = usage["output_tokens"], !(outputValue is NSNull),
                          !(usage["cache_read_input_tokens"] is NSNull),
                          let input = try? UsageNumber.count(inputValue), let output = try? UsageNumber.count(outputValue),
                          let cached = try? UsageNumber.count(usage["cache_read_input_tokens"]) else { invalid += 1; continue }
                    valid += 1
                    let effective = try UsageNumber.sum([input, output, cached / 10])
                    for i in intervals.indices where date >= now.addingTimeInterval(-intervals[i]) {
                        used[i] = try UsageNumber.add(used[i], effective)
                    }
                    if date >= cutoff { cost = try UsageNumber.add(cost, (Double(input) * 3 + Double(cached) * 0.30 + Double(output) * 15) / 1_000_000) }
                }
            })
            let after = try inspectInternal(logsFD)
            switch (expectedInternal, after) {
            case (nil, nil): break
            case let (a?, b?) where same(a, b) && internalData != nil: break
            default: throw StoreSafeFileTree.Failure.invalidEntry
            }
        } else { expectedInternal = nil }

        // pread preserves the caller's file offset; inspect the opened descriptor
        // before and after reading. The caller must establish the grant itself.
        func readExternal(_ fd: Int32) throws -> Data {
            guard fd >= 0 else { throw StoreSafeFileTree.Failure.invalidRoot }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_size >= 0, before.st_size <= Int64(min(limits.jsonBytes, limits.tree.fileBytes)),
                  files < limits.tree.files, entries < limits.tree.entries else { throw StoreSafeFileTree.Failure.invalidEntry }
            guard before.st_size <= Int64(limits.tree.totalBytes - bytes) else { throw StoreSafeFileTree.Failure.limit }
            files += 1; entries += 1
            var data = Data(), offset: off_t = 0
            while offset < before.st_size {
                try check()
                let amount = min(32 * 1024, Int(before.st_size - offset), limits.tree.totalBytes - bytes)
                guard amount > 0 else { throw StoreSafeFileTree.Failure.limit }
                var buffer = [UInt8](repeating: 0, count: amount)
                let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
                guard count >= 0 else { throw StoreSafeFileTree.Failure.io }
                guard count > 0 else { throw StoreSafeFileTree.Failure.invalidEntry }
                guard count <= limits.jsonBytes - data.count, count <= limits.tree.fileBytes - data.count else { throw StoreSafeFileTree.Failure.limit }
                try budget(count)
                data.append(contentsOf: buffer.prefix(count)); offset += off_t(count)
            }
            var after = stat()
            guard fstat(fd, &after) == 0, same(before, after) else { throw StoreSafeFileTree.Failure.invalidEntry }
            return data
        }
        let settingsData: Data?
        let internalSelected = expectedInternal != nil
        if internalSelected { settingsData = internalData }
        else if let settingsFD { settingsData = try readExternal(settingsFD) }
        else { settingsData = nil }
        var plan: String?, estimate: Estimate?
        var settingsValid = false
        var projectsState: ProjectsState = .unavailable
        if let settingsData, let obj = (try? JSONSerialization.jsonObject(with: settingsData)) as? [String: Any] {
            settingsValid = true
            projectsState = .notDetected
            if let tier = obj["claudeMaxTier"] as? String { plan = LocalUsageCollector.safePlan(tier, provider: "claude") }
            if let projects = obj["projects"] as? [String: Any] {
                var total = 0, totalCost = 0.0
                do {
                    for value in projects.values {
                        try check()
                        guard let project = value as? [String: Any] else { throw UsageNumber.Invalid.number }
                        for key in ["lastTotalInputTokens", "lastTotalOutputTokens", "lastTotalCacheCreationInputTokens", "lastTotalCacheReadInputTokens", "lastCost"] {
                            guard let field = project[key], !(field is NSNull) else { throw UsageNumber.Invalid.number }
                        }
                        total = try UsageNumber.sum([total, UsageNumber.count(project["lastTotalInputTokens"]), UsageNumber.count(project["lastTotalOutputTokens"]), UsageNumber.count(project["lastTotalCacheCreationInputTokens"]), UsageNumber.count(project["lastTotalCacheReadInputTokens"]) / 10])
                        totalCost = try UsageNumber.add(totalCost, UsageNumber.nonnegative(project["lastCost"]))
                    }
                    if !projects.isEmpty {
                        estimate = Estimate(tokens: total, cost: totalCost)
                        projectsState = .complete
                    }
                } catch is UsageNumber.Invalid { projectsState = .incomplete; estimate = nil }
            } else if obj["projects"] != nil { projectsState = .incomplete }
        }
        let settings: SettingsState = internalSelected ? (settingsValid ? .internalValid : .internalInvalid) :
            (settingsFD != nil ? (settingsValid ? .externalValid : .externalInvalid) : (logsFD == nil ? .unselected : .absent))
        let logs: LogState = logsFD == nil ? .unselected : valid > 0 ? (invalid > 0 ? .partial : .complete) : invalid > 0 ? .invalid : .notDetected
        let periods = valid > 0 ? ProviderPeriodUsageJSON(twoHours: used[0], fiveHours: used[1], daily: used[2], weekly: used[3], monthly: used[4]) : nil
        return Result(logs: logs, settings: settings, used: periods, logCost: valid > 0 ? round(cost * 100) / 100 : nil, plan: plan, projects: projectsState, undatedProjects: estimate)
    }
}
