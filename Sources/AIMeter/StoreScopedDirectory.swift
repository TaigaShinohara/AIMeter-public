import Darwin
import Foundation

/// Opens a user-selected directory only while its security scope is active.
/// The caller borrows the descriptor for the duration of `body` and must not
/// close it, retain it, or pass it to work that outlives the closure.
///
/// Comparing lstat and fstat detects replacement of the final path component.
/// It does not independently prove the bookmark's OS grant or prevent an
/// ancestor from being swapped before lstat; those remain integration checks.
struct StoreScopedDirectory {
    enum Failure: Error, Equatable {
        case invalidURL, invalidDirectory, openFailed, changed
    }

    struct Operations {
        var inspectPath: (String) throws -> stat
        var openDirectory: (String) throws -> Int32
        var inspectDescriptor: (Int32) throws -> stat
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
            closeDescriptor: { _ = Darwin.close($0) }
        )
    }

    let bookmarks: StoreBookmarkStore
    var operations: Operations = .live

    func withRoot<T>(sourceID: String, body: (Int32) async throws -> T) async throws -> T {
        try await bookmarks.withAccess(sourceID: sourceID) { url in
            try Task.checkCancellation()
            guard url.isFileURL, !url.path.utf8.contains(0), url.path.hasPrefix("/") else {
                throw Failure.invalidURL
            }
            let expected = try operations.inspectPath(url.path)
            guard expected.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidDirectory }
            try Task.checkCancellation()
            let fd = try operations.openDirectory(url.path)
            guard fd >= 0 else { throw Failure.openFailed }
            defer { operations.closeDescriptor(fd) }
            let actual = try operations.inspectDescriptor(fd)
            guard actual.st_mode & S_IFMT == S_IFDIR,
                  actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else {
                throw Failure.changed
            }
            try Task.checkCancellation()
            return try await body(fd)
        }
    }
}
