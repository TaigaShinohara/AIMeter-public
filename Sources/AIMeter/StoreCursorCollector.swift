import Foundation
import Darwin
import AIMeterCore

/// Experimental, not connected to production UI. Unlike the direct collector,
/// only the recognized AgentStores control tree is used; hidden descendants,
/// symlinks and future timestamps do not contribute. The counts are file mtime
/// proxies, not confirmed requests or official usage. No JSON content is read.
enum StoreCursorCollector {
    enum State: Equatable { case unselected, notRecognized, empty, invalid, partial, complete }
    struct Result: Equatable {
        let state: State
        let fileCounts: ProviderPeriodUsageJSON?
    }
    struct Limits {
        var entries = 10_000
        var files = 5_000
        var depth = 32
        var seconds: TimeInterval = 30
    }

    /// Caller holds the security scope and owns rootFD for this entire call.
    static func collect(rootFD: Int32?, limits: Limits = .init(), now: Date = Date(),
                        beforeOpen: ([String]) throws -> Void = { _ in }) throws -> Result {
        guard let rootFD else { return Result(state: .unselected, fileCounts: nil) }
        guard limits.entries > 0, limits.files > 0, limits.depth >= 0,
              limits.seconds.isFinite, limits.seconds > 0 else { throw StoreSafeFileTree.Failure.limit }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
        var entryCount = 0, fileCount = 0, valid = 0, invalid = 0
        var counts = [Int](repeating: 0, count: 5)
        let cutoffs = LocalUsageCollector.calculateCutoffs(now: now)
        let keys = ["2h", "5h", "1d", "7d", "30d"]
        func check() throws {
            guard !Task.isCancelled else { throw StoreSafeFileTree.Failure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw StoreSafeFileTree.Failure.limit }
        }
        func sameIdentity(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
        }
        func sameMetadata(_ a: stat, _ b: stat) -> Bool {
            sameIdentity(a, b) && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
        func openChild(_ parent: Int32, name: String, path: [String], observed: stat) throws -> Int32 {
            try beforeOpen(path)
            try check()
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw StoreSafeFileTree.Failure.invalidEntry }
            var actual = stat()
            guard fstat(fd, &actual) == 0, actual.st_mode & S_IFMT == S_IFDIR, sameIdentity(observed, actual) else {
                Darwin.close(fd); throw StoreSafeFileTree.Failure.invalidEntry
            }
            return fd
        }
        var rootInfo = stat()
        guard rootFD >= 0, fstat(rootFD, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { throw StoreSafeFileTree.Failure.invalidRoot }
        let held = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
        guard held >= 0 else { throw StoreSafeFileTree.Failure.invalidRoot }
        defer { Darwin.close(held) }
        var checkRoot = stat()
        guard fstat(held, &checkRoot) == 0, sameIdentity(rootInfo, checkRoot) else { throw StoreSafeFileTree.Failure.invalidRoot }
        var parent = held
        var opened: [Int32] = []
        var observedPath: [(Int32, String, stat)] = []
        defer { for fd in opened.reversed() { Darwin.close(fd) } }
        var path: [String] = []
        for name in ["AgentStores", "cursor_agent_stores", ".control"] {
            try check()
            guard entryCount < limits.entries else { throw StoreSafeFileTree.Failure.limit }
            entryCount += 1
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return Result(state: .notRecognized, fileCounts: nil) }
                throw StoreSafeFileTree.Failure.io
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { return Result(state: .invalid, fileCounts: nil) }
            path.append(name)
            observedPath.append((parent, name, info))
            let next = try openChild(parent, name: name, path: path, observed: info)
            opened.append(next); parent = next
        }
        func scan(_ directory: Int32, path: [String], depth: Int) throws {
            try check()
            var before = stat()
            guard fstat(directory, &before) == 0 else { throw StoreSafeFileTree.Failure.io }
            let iteratorFD = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard iteratorFD >= 0 else { throw StoreSafeFileTree.Failure.io }
            guard let stream = fdopendir(iteratorFD) else { Darwin.close(iteratorFD); throw StoreSafeFileTree.Failure.io }
            defer { closedir(stream) }
            while true {
                try check(); errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw StoreSafeFileTree.Failure.io }
                    break
                }
                let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
                }
                guard let name, !name.contains("/") else { throw StoreSafeFileTree.Failure.invalidEntry }
                if name == "." || name == ".." { continue }
                guard entryCount < limits.entries else { throw StoreSafeFileTree.Failure.limit }
                entryCount += 1
                if name.hasPrefix(".") { continue }
                var observed = stat()
                guard fstatat(directory, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else { throw StoreSafeFileTree.Failure.io }
                let mode = observed.st_mode & S_IFMT
                if mode == S_IFDIR {
                    guard depth < limits.depth else { throw StoreSafeFileTree.Failure.limit }
                    let child = try openChild(directory, name: name, path: path + [name], observed: observed)
                    defer { Darwin.close(child) }
                    try scan(child, path: path + [name], depth: depth + 1)
                } else if name.hasSuffix(".json") {
                    guard mode == S_IFREG else { invalid += 1; continue }
                    guard fileCount < limits.files else { throw StoreSafeFileTree.Failure.limit }
                    fileCount += 1
                    try beforeOpen(path + [name]); try check()
                    var after = stat()
                    guard fstatat(directory, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                          sameMetadata(observed, after) else { throw StoreSafeFileTree.Failure.invalidEntry }
                    let date = Date(timeIntervalSince1970: Double(observed.st_mtimespec.tv_sec) + Double(observed.st_mtimespec.tv_nsec) / 1_000_000_000)
                    guard date <= now else { invalid += 1; continue }
                    valid += 1
                    for (index, key) in keys.enumerated() where date >= (cutoffs[key] ?? now) {
                        counts[index] = try UsageNumber.add(counts[index], 1)
                    }
                }
            }
            var after = stat()
            guard fstat(directory, &after) == 0, sameMetadata(before, after) else { throw StoreSafeFileTree.Failure.invalidEntry }
        }
        try scan(parent, path: path, depth: 0)
        for (directory, name, expected) in observedPath {
            var actual = stat()
            guard fstatat(directory, name, &actual, AT_SYMLINK_NOFOLLOW) == 0,
                  sameIdentity(expected, actual) else { throw StoreSafeFileTree.Failure.invalidEntry }
        }
        if valid == 0 {
            return Result(state: invalid > 0 ? .invalid : .empty, fileCounts: nil)
        }
        let periods = ProviderPeriodUsageJSON(twoHours: counts[0], fiveHours: counts[1], daily: counts[2], weekly: counts[3], monthly: counts[4])
        return Result(state: invalid > 0 ? .partial : .complete, fileCounts: periods)
    }
}
