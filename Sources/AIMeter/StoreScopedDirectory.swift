import Darwin
import Foundation

/// Opens a user-selected directory only while its security scope is active.
/// The caller borrows the descriptor for the duration of `body` and must not
/// close it, retain it, or pass it to work that outlives the closure.
///
/// Before `body` runs, the target is verified in two stages against the
/// identity recorded at selection time (docs/STORE_CONNECTION_DESIGN.md,
/// stage 2 of the connection plan). First the resolved URL must still name
/// the recorded target: re-capturing its file resource and volume
/// identifiers detects a target — or an ancestor — replaced before the first
/// lstat, which the lstat/fstat comparison below cannot distinguish. Then
/// the opened descriptor itself must carry the recorded device and inode,
/// and its `fgetattrlist` file ID must equal the recorded inode, binding the
/// descriptor to the selection-time entity rather than to whatever the path
/// names at that moment. Any mismatch is `Failure.changed`, which callers
/// surface as needing reselection; no collection starts on a mismatch.
struct StoreScopedDirectory {
    enum Failure: Error, Equatable {
        case invalidURL, invalidDirectory, openFailed, changed
    }

    struct Operations {
        var inspectPath: (String) throws -> stat
        var openDirectory: (String) throws -> Int32
        var inspectDescriptor: (Int32) throws -> stat
        var descriptorFileID: (Int32) throws -> UInt64
        var captureIdentity: (URL) -> StoreSelectionIdentity?
        var closeDescriptor: (Int32) -> Void

        static let live = Operations(
            inspectPath: { path in
                var info = stat()
                guard Darwin.lstat(path, &info) == 0 else { throw Failure.invalidDirectory }
                return info
            },
            openDirectory: { path in
                let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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

    /// Opens the selected directory after verifying it against the given
    /// selection-time identity record.
    func withRoot<T>(sourceID: String, identity: StoreSelectionIdentity,
                     body: (Int32) async throws -> T) async throws -> T {
        try await bookmarks.withAccess(sourceID: sourceID) { url in
            try Task.checkCancellation()
            guard url.isFileURL, !url.path.utf8.contains(0), url.path.hasPrefix("/") else {
                throw Failure.invalidURL
            }
            guard identity.kind == .directory else { throw Failure.changed }
            let expected = try operations.inspectPath(url.path)
            guard expected.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidDirectory }
            // First verification stage: the resolved URL must still name the
            // recorded target, identifiers included.
            guard identity.matches(operations.captureIdentity(url)) else { throw Failure.changed }
            try Task.checkCancellation()
            let fd = try operations.openDirectory(url.path)
            guard fd >= 0 else { throw Failure.openFailed }
            defer { operations.closeDescriptor(fd) }
            let actual = try operations.inspectDescriptor(fd)
            // Second verification stage: the opened descriptor itself must
            // be the recorded target.
            let fileID = try operations.descriptorFileID(fd)
            guard actual.st_mode & S_IFMT == S_IFDIR,
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

    /// Opens the selected directory using the identity recorded for it at
    /// selection time. A selection without a recorded identity (including
    /// pre-identity saves) is unverifiable: the scope is never started,
    /// collection never begins, and the failure surfaces as `changed`,
    /// which callers treat as needing reselection.
    func withRoot<T>(sourceID: String, body: (Int32) async throws -> T) async throws -> T {
        guard let identity = bookmarks.identity(sourceID: sourceID) else { throw Failure.changed }
        return try await withRoot(sourceID: sourceID, identity: identity, body: body)
    }
}
