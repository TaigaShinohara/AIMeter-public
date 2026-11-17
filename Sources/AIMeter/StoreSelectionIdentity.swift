import Darwin
import Foundation

/// Identity of a user-selected target, recorded at selection time alongside
/// its security-scoped bookmark. Stage 1 of the Store connection plan
/// (docs/STORE_CONNECTION_DESIGN.md) only records this and reads it back;
/// verifying a reopened target against the record is stage 2.
///
/// A selection counts as identified only when the file resource identifier
/// was obtained. Environments that cannot provide one (for example some
/// network volumes) leave the selection unidentified, and callers must treat
/// it as needing reselection rather than trusting the path implicitly.
struct StoreSelectionIdentity: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case directory
        case file
        case other
    }

    /// Bytes of `URLResourceValues.fileResourceIdentifier` for the selected
    /// target. The identifier names the file entity within its volume and
    /// survives renames and moves inside that volume, unlike the path.
    let fileResourceIdentifier: Data
    /// Bytes of `URLResourceValues.volumeIdentifier`, when the volume
    /// provides one.
    let volumeIdentifier: Data?
    /// `st_dev` of the descriptor opened at selection time.
    let device: Int64
    /// `st_ino` of the descriptor opened at selection time.
    let inode: UInt64
    /// What the selected target was when it was recorded.
    let kind: Kind

    /// Captures the identity of a target the user has just selected, while
    /// the selection grant is in effect. Returns nil when the identity cannot
    /// be established; callers must not fall back to trusting the path.
    static func capture(url: URL) -> StoreSelectionIdentity? {
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey])
        guard let fileIdentifier = identifierData(values?.fileResourceIdentifier) else { return nil }
        // O_NONBLOCK keeps a special file (for example a FIFO) from blocking
        // the capture; only the descriptor's metadata is read.
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { return nil }
        let kind: Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        default: kind = .other
        }
        return StoreSelectionIdentity(
            fileResourceIdentifier: fileIdentifier,
            volumeIdentifier: identifierData(values?.volumeIdentifier),
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            kind: kind)
    }

    /// Normalizes the opaque identifier objects Foundation returns into
    /// storable bytes. Local volumes hand back data objects; anything else is
    /// archived so that later comparison stays a byte comparison.
    private static func identifierData(_ value: Any?) -> Data? {
        guard let value else { return nil }
        if let data = value as? Data { return data }
        if let string = value as? String { return Data(string.utf8) }
        if let object = value as? NSObject {
            return try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
        }
        return nil
    }
}
