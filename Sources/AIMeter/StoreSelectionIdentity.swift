import Darwin
import Foundation

/// Result buffer for the `fgetattrlist` call in
/// `StoreSelectionIdentity.descriptorFileID(_:)`: a total length followed by
/// the single `UInt64` file identifier.
private struct DescriptorFileIDBuffer {
    var length: UInt32 = 0
    var fileID: UInt64 = 0
}

/// Identity of a user-selected target, recorded at selection time alongside
/// its security-scoped bookmark. Stage 1 of the Store connection plan
/// (docs/STORE_CONNECTION_DESIGN.md) records this and reads it back; stage 2
/// verifies a reopened target against the record before any collection,
/// through `matches(_:)` for the resolved URL and `matchesDescriptor(...)`
/// for the opened descriptor.
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

    /// Whether a freshly captured identity names the same target as this
    /// record. Every recorded component must match exactly; a missing capture
    /// never matches, so a target whose identifiers cannot be re-read (for
    /// example on a volume without file resource identifiers) fails
    /// verification instead of passing on the strength of its path.
    func matches(_ current: StoreSelectionIdentity?) -> Bool {
        guard let current else { return false }
        return current == self
    }

    /// Whether attributes read from an opened descriptor name the recorded
    /// target: same device and inode, and the descriptor's file ID — read
    /// with `fgetattrlist`, so it describes the opened entity itself rather
    /// than whatever its path names now — equal to the recorded inode.
    func matchesDescriptor(device: Int64, inode: UInt64, fileID: UInt64) -> Bool {
        device == self.device && inode == self.inode && fileID == self.inode
    }

    /// The file ID of an already-open descriptor, read with `fgetattrlist`.
    /// Returns nil when the descriptor's file system cannot provide one;
    /// verification must then fail rather than fall back to the path.
    static func descriptorFileID(_ fd: Int32) -> UInt64? {
        var attributes = attrlist()
        // ATTR_BIT_MAP_COUNT: the count of UInt16-sized fields in attrlist.
        attributes.bitmapcount = 5
        attributes.commonattr = attrgroup_t(ATTR_CMN_FILEID)
        var buffer = DescriptorFileIDBuffer()
        let status = withUnsafeMutableBytes(of: &buffer) { bytes in
            Darwin.fgetattrlist(fd, &attributes, bytes.baseAddress, bytes.count, 0)
        }
        guard status == 0 else { return nil }
        return buffer.fileID
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
