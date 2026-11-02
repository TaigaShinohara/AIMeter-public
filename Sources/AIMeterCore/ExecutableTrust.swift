import Foundation
import Darwin

// membership.h is a public libSystem C API but is not exported by Darwin's
// Swift module in every supported SDK. Keep its scalar/pointer signature here.
@_silgen_name("mbr_uid_to_uuid")
private func aimeter_uid_to_uuid(_ uid: uid_t, _ uuid: UnsafeMutablePointer<UInt8>) -> Int32

/// This is a local installation/ownership check, not package provenance or a
/// sandbox for a compromised SDK. Return the path actually checked for launch.
public enum ExecutableTrust {
    public static func executable(at path: String, currentUID: uid_t = geteuid()) -> String? {
        guard let resolved = checkedPath(path, currentUID: currentUID, directory: false) else { return nil }
        return FileManager.default.isExecutableFile(atPath: resolved) ? resolved : nil
    }

    public static func directory(at path: String, currentUID: uid_t = geteuid()) -> String? {
        checkedPath(path, currentUID: currentUID, directory: true)
    }

    private static func checkedPath(_ path: String, currentUID: uid_t, directory: Bool) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        // Walk readlink targets too, not just the original and final paths. A
        // trusted symlink can otherwise transit an attacker-writable alias and
        // finish inside an apparently trusted SDK directory.
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        var remaining = path.split(separator: "/").map(String.init)
        var links = 0
        var components = 0
        guard secureObject(resolved.path, currentUID: currentUID, allowSticky: true) else { return nil }
        while !remaining.isEmpty {
            components += 1
            guard components <= 4096 else { return nil }
            let part = remaining.removeFirst()
            if part == "." { continue }
            if part == ".." { resolved.deleteLastPathComponent(); continue }
            let next = resolved.appendingPathComponent(part)
            guard secureObject(next.path, currentUID: currentUID, allowSticky: true) else { return nil }
            var info = stat()
            guard lstat(next.path, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                links += 1
                guard links <= 40 else { return nil }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.readlink(next.path, &bytes, bytes.count)
                guard count > 0, count < bytes.count,
                      let target = String(bytes: bytes.prefix(count), encoding: .utf8) else { return nil }
                if target.hasPrefix("/") { resolved = URL(fileURLWithPath: "/", isDirectory: true) }
                remaining = target.split(separator: "/").map(String.init) + remaining
            } else {
                guard remaining.isEmpty || (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
                resolved = next
            }
        }
        var info = stat()
        guard lstat(resolved.path, &info) == 0,
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else { return nil }
        // Sticky shared ancestors protect existing owned entries, but a final
        // configuration/PATH directory must not accept other users' new files.
        guard secureObject(resolved.path, currentUID: currentUID, allowSticky: false) else { return nil }
        return resolved.path
    }

    private static func secureObject(_ path: String, currentUID: uid_t, allowSticky: Bool) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0 || info.st_uid == currentUID else { return false }
        let kind = info.st_mode & S_IFMT
        // Symlink ownership and its ancestors are checked here. Every ancestor
        // of the resolved target is checked separately, including the SDK root.
        if kind == S_IFLNK { return true }
        guard kind == S_IFREG || kind == S_IFDIR else { return false }
        // ACL absence is reported as ENOENT on Darwin. Query an opened object
        // so absence cannot be confused with the pathname disappearing.
        let descriptor = Darwin.open(path, O_EVTONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev,
              opened.st_ino == info.st_ino, opened.st_mode == info.st_mode,
              opened.st_uid == info.st_uid else { return false }
        let sticky = allowSticky && kind == S_IFDIR && (info.st_mode & S_ISVTX) != 0
        guard (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 || sticky else { return false }
        return secureACL(descriptor, currentUID: currentUID)
    }

    private static func secureACL(_ descriptor: Int32, currentUID: uid_t) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        // Darwin returns 0 for success and EINVAL past the last index, unlike
        // several other POSIX ACL implementations. Indexes also bound work.
        for index in 0..<4096 {
            guard acl_get_entry(acl, Int32(index), &entry) == 0 else { return errno == EINVAL }
            guard let entry else { return false }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { return false }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else { return false }
            let mutable = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                           ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY,
                           ACL_CHANGE_OWNER].contains { acl_get_perm_np(permissions, $0) == 1 }
            guard mutable else { continue }
            // A grant to any other user/group can permit replacement even when
            // POSIX mode bits look private. Unknown principals fail closed.
            guard let principal = acl_get_qualifier(entry) else { return false }
            defer { acl_free(principal) }
            if !principalMatches(principal, uid: 0) && !principalMatches(principal, uid: currentUID) { return false }
        }
        return false
    }

    private static func principalMatches(_ principal: UnsafeMutableRawPointer, uid: uid_t) -> Bool {
        var uuid = UUID().uuid
        let result = withUnsafeMutableBytes(of: &uuid) {
            aimeter_uid_to_uuid(uid, $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        return result == 0 && withUnsafeBytes(of: uuid) { memcmp(principal, $0.baseAddress!, 16) == 0 }
    }
}
