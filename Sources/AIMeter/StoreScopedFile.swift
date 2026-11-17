import Darwin
import Foundation

/// Opens a user-selected single file (for example the Claude auxiliary
/// settings JSON, source `claude.settings`) only while its security scope
/// is active, with the same two-stage identity verification as
/// `StoreScopedDirectory` (docs/STORE_CONNECTION_DESIGN.md, stage 2 of the
/// connection plan): first the resolved URL must still name the target
/// recorded at selection time, then the opened descriptor itself must carry
/// the recorded device and inode, with its `fgetattrlist` file ID equal to
/// the recorded inode. Any mismatch is `Failure.changed`, which callers
/// surface as needing reselection; the file is never read on a mismatch.
///
/// This is the entry point through which a settings descriptor for
/// `StoreClaudeCollector` is obtained, replacing the collector-side ad-hoc
/// stat comparison that had no link back to the selection-time target. The
/// caller borrows the descriptor for the duration of `body` and must not
/// close it, retain it, or pass it to work that outlives the closure.
struct StoreScopedFile {
    enum Failure: Error, Equatable {
        case invalidURL, invalidFile, openFailed, changed
    }

    struct Operations {
        var inspectPath: (String) throws -> stat
        var openFile: (String) throws -> Int32
        var inspectDescriptor: (Int32) throws -> stat
        var descriptorFileID: (Int32) throws -> UInt64
        var captureIdentity: (URL) -> StoreSelectionIdentity?
        var closeDescriptor: (Int32) -> Void

        static let live = Operations(
            inspectPath: { path in
                var info = stat()
                guard Darwin.lstat(path, &info) == 0 else { throw Failure.invalidFile }
                return info
            },
            openFile: { path in
                // O_NONBLOCK keeps a special file from blocking the open;
                // only regular files pass the type checks below.
                let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw Failure.openFailed }
                return fd
            },
            inspectDescriptor: { fd in
                var info = stat()
                guard Darwin.fstat(fd, &info) == 0 else { throw Failure.changed }
                return info
            },
            descriptorFileID: { fd in
                guard let fileID = StoreSelectionIdentity.descriptorFileID(fd) else {
                    throw Failure.changed
                }
                return fileID
            },
            captureIdentity: { StoreSelectionIdentity.capture(url: $0) },
            closeDescriptor: { _ = Darwin.close($0) }
        )
    }

    let bookmarks: StoreBookmarkStore
    var operations: Operations = .live

    /// Opens the selected file after verifying it against the given
    /// selection-time identity record.
    func withFile<T>(sourceID: String, identity: StoreSelectionIdentity,
                     body: (Int32) async throws -> T) async throws -> T {
        try await bookmarks.withAccess(sourceID: sourceID) { url in
            try Task.checkCancellation()
            guard url.isFileURL, !url.path.utf8.contains(0), url.path.hasPrefix("/") else {
                throw Failure.invalidURL
            }
            guard identity.kind == .file else { throw Failure.changed }
            let expected = try operations.inspectPath(url.path)
            guard expected.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidFile }
            // First verification stage: the resolved URL must still name the
            // recorded target, identifiers included.
            guard identity.matches(operations.captureIdentity(url)) else { throw Failure.changed }
            try Task.checkCancellation()
            let fd = try operations.openFile(url.path)
            guard fd >= 0 else { throw Failure.openFailed }
            defer { operations.closeDescriptor(fd) }
            let actual = try operations.inspectDescriptor(fd)
            // Second verification stage: the opened descriptor itself must
            // be the recorded target.
            let fileID = try operations.descriptorFileID(fd)
            guard actual.st_mode & S_IFMT == S_IFREG,
                  actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
                  identity.matchesDescriptor(device: Int64(actual.st_dev),
                                             inode: UInt64(actual.st_ino),
                                             fileID: fileID) else {
                throw Failure.changed
            }
            try Task.checkCancellation()
            return try await body(fd)
        }
    }

    /// Opens the selected file using the identity recorded for it at
    /// selection time. A selection without a recorded identity (including
    /// pre-identity saves) is unverifiable: the scope is never started,
    /// collection never begins, and the failure surfaces as `changed`,
    /// which callers treat as needing reselection.
    func withFile<T>(sourceID: String, body: (Int32) async throws -> T) async throws -> T {
        guard let identity = bookmarks.identity(sourceID: sourceID) else { throw Failure.changed }
        return try await withFile(sourceID: sourceID, identity: identity, body: body)
    }
}
