import Foundation
import Darwin

/// Experimental fd-relative reader. The caller holds the security scope for the
/// root until this operation returns. It does not establish source validity or
/// whether the files are suitable for any particular collector. Hard links and
/// mounted filesystems can expose data whose provenance is outside the tree.
/// The visitor reads selected files from borrowed descriptors without reopening paths.
enum StoreSafeFileTree {
    struct Limits {
        var entries = 10_000
        var depth = 32
        var files = 5_000
        var fileBytes = 8 * 1024 * 1024
        var totalBytes = 64 * 1024 * 1024
        var lineBytes = 1024 * 1024
        var seconds: TimeInterval = 30
    }

    struct File: Equatable {
        let components: [String]
        let data: Data
    }

    struct Metadata: Equatable {
        let size: Int64
        let device: UInt64
        let inode: UInt64
        let permissions: UInt16
        let modificationTime: Date

        fileprivate init(_ value: stat) {
            size = value.st_size
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(value.st_ino)
            permissions = UInt16(value.st_mode & 0o7777)
            modificationTime = Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        }
    }

    enum Failure: Error, Equatable {
        case invalidRoot, invalidEntry, io, limit, cancelled
    }

    /// `beforeOpen` exists to exercise replacement races deterministically.
    /// It is called after inspecting a child and before opening it relative to
    /// its already-open parent. The returned data is never read by pathname.
    /// Selection closures receive relative components and no-follow metadata;
    /// they can be called again after open and should be side-effect free.
    static func read(rootDirectoryFD: Int32, limits: Limits = Limits(),
                     includeFile: ([String], Metadata) -> Bool,
                     descendDirectory: ([String], Metadata) -> Bool,
                     cancelled: () -> Bool = { Task.isCancelled },
                     onEntry: () throws -> Void = {},
                     onFile: () throws -> Void = {},
                     beforeOpen: ([String]) throws -> Void = { _ in },
                     visitFile: (([String], Metadata, () throws -> Data) throws -> Void)? = nil) throws -> [File] {
        guard limits.entries > 0, limits.depth >= 0,
              limits.files > 0, limits.fileBytes >= 0, limits.totalBytes >= 0, limits.lineBytes >= 0,
              limits.seconds > 0, limits.seconds.isFinite else { throw Failure.invalidRoot }
        // In particular, AT_FDCWD is negative: it must never turn an invalid
        // input into access to the process's current working directory.
        var callerStat = stat()
        guard rootDirectoryFD >= 0, fstat(rootDirectoryFD, &callerStat) == 0,
              callerStat.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidRoot }
        let heldFD = fcntl(rootDirectoryFD, F_DUPFD_CLOEXEC, 0)
        guard heldFD >= 0 else { throw Failure.invalidRoot }
        defer { Darwin.close(heldFD) }
        var heldStat = stat()
        guard fstat(heldFD, &heldStat) == 0, heldStat.st_mode & S_IFMT == S_IFDIR,
              heldStat.st_dev == callerStat.st_dev, heldStat.st_ino == callerStat.st_ino else {
            throw Failure.invalidRoot
        }
        let rootFD = openat(heldFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.invalidRoot }
        defer { Darwin.close(rootFD) }
        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR,
              rootStat.st_dev == heldStat.st_dev, rootStat.st_ino == heldStat.st_ino else {
            throw Failure.invalidRoot
        }

        let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
        var entryCount = 0
        var fileCount = 0
        var totalBytes = 0
        var result: [File] = []

        func check() throws {
            guard !cancelled() else { throw Failure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.limit }
        }

        func scan(_ directoryFD: Int32, components: [String]) throws {
            try check()
            // fdopendir owns its fd; open a separate file description so its
            // directory offset never changes the caller's descriptor.
            let iteratorFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard iteratorFD >= 0 else { throw Failure.io }
            guard let directory = fdopendir(iteratorFD) else {
                Darwin.close(iteratorFD)
                throw Failure.io
            }
            defer { closedir(directory) }
            while true {
                try check()
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw Failure.io }
                    break
                }
                let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                        String(validatingUTF8: $0)
                    }
                }
                guard let name, !name.contains("/") else { throw Failure.invalidEntry }
                if name == "." || name == ".." { continue }
                guard entryCount < limits.entries else { throw Failure.limit }
                entryCount += 1
                try onEntry()
                let path = components + [name]
                var observed = stat()
                guard fstatat(directoryFD, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
                let mode = observed.st_mode & S_IFMT
                if mode == S_IFLNK { continue }
                guard mode == S_IFDIR || mode == S_IFREG else { continue }
                let selected = mode == S_IFDIR ? descendDirectory(path, Metadata(observed)) : includeFile(path, Metadata(observed))
                if !selected { continue }
                if mode == S_IFDIR, path.count > limits.depth { throw Failure.limit }
                if mode == S_IFREG {
                    guard fileCount < limits.files else { throw Failure.limit }
                    fileCount += 1
                    try onFile()
                }
                try beforeOpen(path)
                try check()
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (mode == S_IFDIR ? O_DIRECTORY : 0)
                let childFD = openat(directoryFD, name, flags)
                guard childFD >= 0 else { throw Failure.io }
                defer { Darwin.close(childFD) }
                var actual = stat()
                guard fstat(childFD, &actual) == 0, actual.st_mode & S_IFMT == mode,
                      actual.st_dev == observed.st_dev, actual.st_ino == observed.st_ino else {
                    throw Failure.invalidEntry
                }
                let stillSelected = mode == S_IFDIR ? descendDirectory(path, Metadata(actual)) : includeFile(path, Metadata(actual))
                guard stillSelected else { throw Failure.invalidEntry }
                if mode == S_IFDIR {
                    try scan(childFD, components: path)
                } else {
                    guard actual.st_size >= 0, actual.st_size <= Int64(limits.fileBytes) else { throw Failure.limit }
                    var consumed = 0
                    var reachedEOF = false
                    func nextChunk() throws -> Data {
                        try check()
                        if reachedEOF { return Data() }
                        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                        let count = buffer.withUnsafeMutableBytes { bytes in
                            Darwin.read(childFD, bytes.baseAddress, bytes.count)
                        }
                        guard count >= 0 else { throw Failure.io }
                        if count == 0 { reachedEOF = true; return Data() }
                        guard count <= limits.fileBytes - consumed,
                              count <= limits.totalBytes - totalBytes else { throw Failure.limit }
                        consumed += count
                        totalBytes += count
                        return Data(buffer.prefix(count))
                    }
                    if let visitFile {
                        try visitFile(path, Metadata(actual), nextChunk)
                        guard reachedEOF else { throw Failure.invalidEntry }
                        var after = stat()
                        guard fstat(childFD, &after) == 0, Metadata(after) == Metadata(actual) else {
                            throw Failure.invalidEntry
                        }
                    } else {
                        var data = Data()
                        while true {
                            let chunk = try nextChunk()
                            if chunk.isEmpty { break }
                            data.append(chunk)
                        }
                        result.append(File(components: path, data: data))
                    }
                }
            }
        }

        try scan(rootFD, components: [])
        return result.sorted { $0.components.lexicographicallyPrecedes($1.components) }
    }
}
