import Foundation
import Darwin
import AIMeterCore

// Some SDKs omit the C function import because `flock` is also a structure.
// An explicitly C-convention pointer avoids declaring a C symbol with Swift ABI.
private typealias SnapshotFlockFunction = @convention(c) (Int32, Int32) -> Int32
private let snapshotLockLibrary = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL)
private let snapshotLockFunction: SnapshotFlockFunction? = {
    guard let library = snapshotLockLibrary, let symbol = dlsym(library, "flock") else { return nil }
    // The library handle intentionally remains alive for this function's lifetime.
    return unsafeBitCast(symbol, to: SnapshotFlockFunction.self)
}()

@discardableResult
private func aimeterSnapshotFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    guard let function = snapshotLockFunction else { errno = ENOSYS; return -1 }
    return function(descriptor, operation)
}

/// Owns only this version's private, recoverable SQLite working copies.
/// A kernel lock, not a PID or the age of a directory, decides whether it is idle.
enum PrivateSnapshotManager {
    static let defaultRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.local.AIMeter.windsurf-snapshots-v1", isDirectory: true)
    private static let allowedFiles: Set<String> = ["manifest.json", "worker.lock", "state.vscdb", "state.vscdb-wal", "state.vscdb-shm"]

    struct Manifest: Codable {
        let format: String
        let version: Int
        let generation: String
        let processID: Int32
        let createdAt: TimeInterval
        let startedUptime: TimeInterval
    }

    final class Session {
        let directory: URL
        let generation: String
        private let rootFD: Int32
        private let directoryFD: Int32
        private let lockFD: Int32
        private var closed = false

        fileprivate init(directory: URL, generation: String, rootFD: Int32, directoryFD: Int32, lockFD: Int32) {
            self.directory = directory; self.generation = generation
            self.rootFD = rootFD; self.directoryFD = directoryFD; self.lockFD = lockFD
        }

        func finish() throws {
            guard !closed else { return }
            defer { close() }
            guard try PrivateSnapshotManager.removeGeneration(generation, rootFD: rootFD,
                                                               directoryFD: directoryFD, lockFD: lockFD) else {
                throw BoundedInput.Failure.file
            }
        }

        /// Releasing the lease does not itself erase files. The next owner can
        /// recover an abandoned session after an abrupt exit in the same way.
        func close() {
            guard !closed else { return }
            closed = true
            aimeterSnapshotFlock(lockFD, LOCK_UN)
            Darwin.close(lockFD); Darwin.close(directoryFD); Darwin.close(rootFD)
        }

        deinit { close() }
    }

    static func withSnapshot<T>(root: URL = defaultRoot, input: BoundedInput,
                                body: (URL) throws -> T) throws -> T {
        let session = try begin(root: root, input: input)
        defer { try? session.finish() }
        let result = try body(session.directory)
        try session.finish()
        return result
    }

    static func begin(root: URL = defaultRoot, input: BoundedInput = BoundedInput()) throws -> Session {
        try input.check()
        try ensureRoot(root)
        try cleanup(root: root, input: input)
        let rootFD = try openDirectory(root.path)
        var accepted = false
        defer { if !accepted { Darwin.close(rootFD) } }
        let generation = UUID().uuidString
        let directory = root.appendingPathComponent(generation, isDirectory: true)
        try createPrivateDirectory(directory.path)
        let directoryFD = try openDirectory(directory.path)
        var lockFD: Int32 = -1
        defer {
            if !accepted {
                if lockFD >= 0 { Darwin.close(lockFD) }
                Darwin.close(directoryFD)
            }
        }
        try BoundedInput.writeRegularFileAtomically(Data(), to: directory.appendingPathComponent("worker.lock"))
        lockFD = try openPrivateFile(directoryFD, "worker.lock", writable: true)
        guard aimeterSnapshotFlock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw BoundedInput.Failure.file }
        let manifest = Manifest(format: "AIMeter.WindsurfSnapshot", version: 1, generation: generation,
                                processID: getpid(), createdAt: Date().timeIntervalSince1970,
                                startedUptime: ProcessInfo.processInfo.systemUptime)
        try BoundedInput.writeRegularFileAtomically(JSONEncoder().encode(manifest),
                                                     to: directory.appendingPathComponent("manifest.json"))
        guard matches(rootFD, child: generation, descriptor: directoryFD) else { throw BoundedInput.Failure.file }
        accepted = true
        return Session(directory: directory, generation: generation, rootFD: rootFD,
                       directoryFD: directoryFD, lockFD: lockFD)
    }

    @discardableResult
    static func cleanup(root: URL = defaultRoot, input: BoundedInput = BoundedInput()) throws -> Int {
        try input.check()
        var info = stat()
        if Darwin.lstat(root.path, &info) != 0 {
            if errno == ENOENT { return 0 }
            throw BoundedInput.Failure.file
        }
        let rootFD = try openDirectory(root.path)
        defer { Darwin.close(rootFD) }
        var removed = 0
        for name in try names(in: rootFD, maximum: 1_024) {
            try input.check()
            guard UUID(uuidString: name)?.uuidString == name else { continue }
            let descriptor = Darwin.openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { Darwin.close(descriptor) }
            guard isPrivate(descriptor, type: S_IFDIR, mode: 0o700),
                  matches(rootFD, child: name, descriptor: descriptor),
                  let lock = try? openPrivateFile(descriptor, "worker.lock", writable: true) else { continue }
            defer { Darwin.close(lock) }
            // The lock remains held through validation and deletion. A live
            // worker or another cleaner wins this race, so this cleaner skips it.
            guard aimeterSnapshotFlock(lock, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { aimeterSnapshotFlock(lock, LOCK_UN) }
            if (try? removeGeneration(name, rootFD: rootFD, directoryFD: descriptor, lockFD: lock)) == true {
                removed += 1
            }
        }
        return removed
    }

    private static func ensureRoot(_ url: URL) throws {
        var info = stat()
        if Darwin.lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw BoundedInput.Failure.file }
            do { try createPrivateDirectory(url.path) }
            catch {
                // Two honest workers can create the root concurrently. Reopen
                // and validate the winner instead of changing existing permissions.
                guard Darwin.lstat(url.path, &info) == 0 else { throw error }
            }
        }
        let fd = try openDirectory(url.path)
        Darwin.close(fd)
    }

    private static func createPrivateDirectory(_ path: String) throws {
        guard !path.utf8.contains(0), var acl = acl_init(0) else {
            throw BoundedInput.Failure.file
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let security = filesec_init() else { throw BoundedInput.Failure.file }
        defer { filesec_free(security) }
        var flags: acl_flagset_t?
        var mode = mode_t(0o700)
        guard acl_get_flagset_np(UnsafeMutableRawPointer(acl), &flags) == 0, let flags,
              acl_add_flag_np(flags, ACL_FLAG_NO_INHERIT) == 0,
              filesec_set_property(security, FILESEC_MODE, &mode) == 0,
              filesec_set_property(security, FILESEC_ACL, &acl) == 0,
              mkdirx_np(path, security) == 0 else { throw BoundedInput.Failure.file }
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BoundedInput.Failure.file }
        guard isPrivate(fd, type: S_IFDIR, mode: 0o700) else {
            Darwin.close(fd); throw BoundedInput.Failure.file
        }
        return fd
    }

    private static func isPrivate(_ fd: Int32, type: mode_t, mode: mode_t) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == type,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == mode,
              type != S_IFREG || info.st_nlink == 1 else { return false }
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            guard acl_valid(acl) == 0, acl_get_entry(acl, 0, &entry) == -1, errno == EINVAL else { return false }
        } else if errno != ENOENT { return false }
        return true
    }

    private static func openPrivateFile(_ directoryFD: Int32, _ name: String, writable: Bool = false) throws -> Int32 {
        let fd = Darwin.openat(directoryFD, name, (writable ? O_RDWR : O_RDONLY) | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BoundedInput.Failure.file }
        guard isPrivate(fd, type: S_IFREG, mode: 0o600) else {
            Darwin.close(fd); throw BoundedInput.Failure.file
        }
        return fd
    }

    private static func matches(_ parentFD: Int32, child: String, descriptor: Int32) -> Bool {
        var pathInfo = stat(), descriptorInfo = stat()
        return fstatat(parentFD, child, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0
            && fstat(descriptor, &descriptorInfo) == 0
            && pathInfo.st_dev == descriptorInfo.st_dev && pathInfo.st_ino == descriptorInfo.st_ino
            && pathInfo.st_mode & S_IFMT == descriptorInfo.st_mode & S_IFMT
    }

    private static func names(in fd: Int32, maximum: Int) throws -> [String] {
        // A new open file description avoids sharing a directory cursor with
        // later validation or another session operation.
        let duplicate = Darwin.openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0 else { throw BoundedInput.Failure.file }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate); throw BoundedInput.Failure.file
        }
        defer { closedir(stream) }
        var names: [String] = []
        while names.count < maximum {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw BoundedInput.Failure.file }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func removeGeneration(_ generation: String, rootFD: Int32,
                                         directoryFD: Int32, lockFD: Int32) throws -> Bool {
        guard matches(rootFD, child: generation, descriptor: directoryFD),
              matches(directoryFD, child: "worker.lock", descriptor: lockFD) else { return false }
        let contents = try names(in: directoryFD, maximum: allowedFiles.count + 1)
        guard Set(contents).isSubset(of: allowedFiles), contents.contains("manifest.json"),
              contents.contains("worker.lock") else { return false }
        let manifestFD = try openPrivateFile(directoryFD, "manifest.json")
        let handle = FileHandle(fileDescriptor: manifestFD, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(manifestFD, &info) == 0, info.st_size > 0, info.st_size <= 4_096 else { return false }
        let data = try handle.read(upToCount: 4_097) ?? Data()
        let expectedKeys: Set<String> = ["format", "version", "generation", "processID", "createdAt", "startedUptime"]
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == expectedKeys else { return false }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard data.count <= 4_096, manifest.format == "AIMeter.WindsurfSnapshot", manifest.version == 1,
              manifest.generation == generation, manifest.processID > 0,
              manifest.createdAt.isFinite, manifest.createdAt > 0,
              manifest.startedUptime.isFinite, manifest.startedUptime >= 0 else { return false }
        // Validate every member before unlinking any of them. All deletion is
        // descriptor-relative, so neither a symlink nor a renamed parent is followed.
        for name in contents {
            let fd = try openPrivateFile(directoryFD, name)
            let same = matches(directoryFD, child: name, descriptor: fd)
            Darwin.close(fd)
            guard same else { return false }
        }
        // Keep the recovery marker until every payload has been removed. If
        // cleanup itself is interrupted, the next launch can still identify it.
        for name in contents where name != "worker.lock" && name != "manifest.json" {
            guard unlinkat(directoryFD, name, 0) == 0 else { throw BoundedInput.Failure.file }
        }
        guard matches(directoryFD, child: "manifest.json", descriptor: manifestFD),
              unlinkat(directoryFD, "manifest.json", 0) == 0,
              matches(directoryFD, child: "worker.lock", descriptor: lockFD),
              unlinkat(directoryFD, "worker.lock", 0) == 0,
              matches(rootFD, child: generation, descriptor: directoryFD),
              unlinkat(rootFD, generation, AT_REMOVEDIR) == 0 else { throw BoundedInput.Failure.file }
        return true
    }
}
