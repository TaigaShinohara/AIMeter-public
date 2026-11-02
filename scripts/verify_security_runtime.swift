// Compile this verifier with the production KeychainHelper.swift and all
// Sources/AIMeterCore/*.swift files. It never sets a default keychain or writes
// a search list. Both production snapshot writers use explicit synthetic URLs.
// Create-time OS registration is detected and treated as an isolation failure.
// All item operations explicitly select one newly created test keychain.
// No application credentials, home-directory files, or service APIs are used.
import Foundation
import Security
import Darwin

// Public libSystem membership API; this SDK does not expose the declaration
// through the Swift Darwin module. The fixture needs the local everyone group,
// not another user's credentials or account data.
@_silgen_name("mbr_gid_to_uuid")
private func probe_group_to_uuid(_ gid: gid_t, _ uuid: UnsafeMutablePointer<UInt8>) -> Int32

@main
private enum VerifySecurityRuntime {
    private static let directoryPrefix = "aimeter-security-probe-"
    private static let keychainFilename = "probe.keychain-db"

    private struct ProbeFailure: Error {
        let stage: String
        let status: OSStatus?
        init(_ stage: String, _ status: OSStatus? = nil) { self.stage = stage; self.status = status }
    }

    private final class Report {
        var checks: [String: Bool] = [:]
        var statuses: [String: Int32] = [:]
        var observation: [String: Any] = [:]
        var failure: String?

        func encoded() throws -> Data {
            var object: [String: Any] = [
                "probe": "AIMeter synthetic runtime verification",
                "checks": checks,
                "statuses": statuses,
                "observations": observation,
                "passed": failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 },
                "limitations": ["same_user_processes_only", "not_a_Widget_Sandbox_test", "not_an_API_permission_test",
                    "explicit_custom_file_keychain_only", "not_a_login_or_Data_Protection_keychain_policy_test",
                    "synthetic_keychain_file_permissions_are_restricted_by_this_probe",
                    "production_helpers_with_explicit_synthetic_urls_only", "not_an_app_candidate_or_cross_uid_file_test"]
            ]
            if let failure { object["failureStage"] = failure }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--reader" {
            reader(arguments)
            return
        }
        let report = Report()
        do {
            let reader: URL?
            if arguments.isEmpty { reader = nil }
            else if arguments.count == 2, arguments[0] == "--untrusted-reader" {
                reader = try checkedReaderExecutable(arguments[1], report: report)
            } else { throw ProbeFailure("arguments") }
            try run(reader: reader, report: report)
        } catch let failure as ProbeFailure {
            report.failure = failure.stage
            if let status = failure.status { report.statuses["failure"] = status }
        } catch {
            // Never print framework error descriptions, paths, payloads or
            // credential-related diagnostics.
            report.failure = "unexpected_system_failure"
        }
        do {
            let encoded = try report.encoded()
            FileHandle.standardOutput.write(encoded)
            FileHandle.standardOutput.write(Data([10]))
            exit(report.failure == nil && !report.checks.isEmpty && report.checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch {
            FileHandle.standardOutput.write(Data("{\"passed\":false,\"failureStage\":\"report_encoding\"}\n".utf8))
            exit(1)
        }
    }

    private static func run(reader: URL?, report: Report) throws {
        let originalConfiguration = try keychainConfiguration()
        var originalInteraction: DarwinBoolean = false
        var interaction = SecKeychainGetUserInteractionAllowed(&originalInteraction)
        guard interaction == errSecSuccess else { throw ProbeFailure("interaction_snapshot", interaction) }
        interaction = SecKeychainSetUserInteractionAllowed(false)
        guard interaction == errSecSuccess else { throw ProbeFailure("interaction_disable", interaction) }
        defer {
            let status = SecKeychainSetUserInteractionAllowed(originalInteraction.boolValue)
            report.statuses["restoreInteraction"] = status
            report.checks["interactionRestored"] = status == errSecSuccess
        }

        guard let nativeTemporaryParent = canonicalPath(FileManager.default.temporaryDirectory.path) else {
            throw ProbeFailure("temporary_parent")
        }
        let temporaryParent = URL(fileURLWithPath: nativeTemporaryParent, isDirectory: true)
        let root = temporaryParent.appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let originalRoot = try metadata(root)
        guard originalRoot.directory, originalRoot.uid == getuid(), originalRoot.mode == 0o700 else {
            throw ProbeFailure("temporary_directory")
        }
        var createdKeychain: SecKeychain?
        defer {
            if let createdKeychain {
                // This reference is assigned only by our successful Create call.
                // No opened or default keychain is ever eligible for deletion.
                let status = SecKeychainDelete(createdKeychain)
                report.statuses["deleteTemporaryKeychain"] = status
                report.checks["temporaryKeychainDeleted"] = status == errSecSuccess
            }
            do {
                report.checks["keychainConfigurationRestored"] = try keychainConfiguration() == originalConfiguration
                let current = try metadata(root)
                guard current.directory, current.uid == originalRoot.uid,
                      current.inode == originalRoot.inode, current.device == originalRoot.device,
                      current.mode == 0o700 else {
                    throw ProbeFailure("temporary_directory_changed")
                }
                try FileManager.default.removeItem(at: root)
                report.checks["temporaryDirectoryRemoved"] = true
            } catch { report.checks["temporaryDirectoryRemoved"] = false }
        }
        try verifyFiles(root: root, report: report)
        try verifyWidgetFiles(root: root, report: report)

        let keychainURL = root.appendingPathComponent(keychainFilename)
        guard !FileManager.default.fileExists(atPath: keychainURL.path) else { throw ProbeFailure("keychain_path_exists") }
        // This synthetic password stays in memory and is never put in argv,
        // output, environment, a password file, or a persistent application item.
        var password = Array((UUID().uuidString + UUID().uuidString).utf8)
        defer { password.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var newKeychain: SecKeychain?
        let created = password.withUnsafeBytes { bytes in
            SecKeychainCreate(keychainURL.path, UInt32(bytes.count), bytes.baseAddress, false, nil, &newKeychain)
        }
        report.statuses["createTemporaryKeychain"] = created
        guard created == errSecSuccess, let keychain = newKeychain else { throw ProbeFailure("create_temporary_keychain", created) }
        createdKeychain = keychain
        report.checks["keychainConfigurationUnchangedByCreate"] = try keychainConfiguration() == originalConfiguration
        guard report.checks["keychainConfigurationUnchangedByCreate"] == true else {
            // Some OS versions may register a newly created file-based keychain.
            // Treat that as an unmet isolation condition; Delete only our new ref.
            throw ProbeFailure("keychain_create_changed_configuration")
        }
        let binding = try keychainStorageBinding(keychain, requested: keychainURL)
        report.observation["createdKeychainPath"] = binding.diagnostics
        guard binding.matches else { throw ProbeFailure("created_keychain_path") }
        let createdFile = try checkedRegularFile(keychainURL)
        report.observation["temporaryKeychainOSCreatedMode"] = Int(createdFile.mode)
        report.observation["temporaryKeychainOSCreatedModeOctal"] = String(format: "%03o", UInt32(createdFile.mode))
        let keychainFile = try restrictNewKeychainFile(keychainURL, expected: createdFile,
                                                       root: root, rootIdentity: originalRoot)
        report.checks["temporaryKeychainStorageIdentityPreserved"] = keychainFile.inode == createdFile.inode
            && keychainFile.device == createdFile.device && keychainFile.uid == createdFile.uid
        report.checks["temporaryKeychainFileOwnerAnd0600"] = keychainFile.uid == getuid() && keychainFile.mode == 0o600
        report.observation["temporaryKeychainExtendedACLEntries"] = try extendedACLEntries(keychainURL)
        let account = "synthetic-" + UUID().uuidString
        let operations = operations(keychain: keychain, report: report)
        let first = "synthetic-initial-" + UUID().uuidString
        let updated = "synthetic-updated-" + UUID().uuidString

        report.checks["keychainSave"] = try quiet { KeychainHelper.save(key: account, value: first, operations: operations) }
        report.checks["keychainRead"] = try quiet { KeychainHelper.load(key: account, operations: operations) == first }
        report.checks["keychainUpdate"] = try quiet { KeychainHelper.save(key: account, value: updated, operations: operations) }
        report.checks["keychainReadUpdated"] = try quiet { KeychainHelper.load(key: account, operations: operations) == updated }
        guard report.checks["keychainReadUpdated"] == true else { throw ProbeFailure("synthetic_item_roundtrip") }

        if let reader {
            let beforeReader = try checkedRegularFile(keychainURL)
            report.observation["temporaryKeychainModeBeforeReader"] = Int(beforeReader.mode)
            report.observation["itemACLTestScope"] = "different_signature_same_uid"
            guard beforeReader.uid == getuid(), beforeReader.mode == 0o600 else {
                throw ProbeFailure("keychain_file_mode_changed")
            }
            let result = try runReader(reader, keychain: keychainURL, account: account)
            report.observation["untrustedReader"] = result
            let status = result["status"] as? Int32 ?? (result["status"] as? NSNumber)?.int32Value
            let deniedByAuthentication = status == errSecInteractionNotAllowed || status == errSecAuthFailed
                || status == errSecUserCanceled
            report.checks["untrustedReaderDenied"] = result["canRead"] as? Bool == false && deniedByAuthentication
        } else {
            report.observation["untrustedReader"] = "not_requested"
            report.observation["itemACLTestScope"] = "not_requested"
        }

        let locked = SecKeychainLock(keychain)
        report.statuses["lockTemporaryKeychain"] = locked
        guard locked == errSecSuccess else { throw ProbeFailure("lock_temporary_keychain", locked) }
        report.checks["lockedReadRejected"] = try quiet { KeychainHelper.load(key: account, operations: operations) == nil }
        report.checks["lockedUpdateRejected"] = try quiet {
            !KeychainHelper.save(key: account, value: "synthetic-rejected-update", operations: operations)
        }
        let restored = try quiet { KeychainHelper.restore(key: account, legacyValue: "synthetic-legacy", operations: operations) }
        report.checks["lockedRestorePreservesLegacy"] = restored.value == "synthetic-legacy" && !restored.canClearLegacy
        let unlocked = password.withUnsafeBytes { bytes in
            SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
        }
        report.statuses["unlockTemporaryKeychain"] = unlocked
        guard unlocked == errSecSuccess else { throw ProbeFailure("unlock_temporary_keychain", unlocked) }
        report.checks["lockedFailurePreservedExistingItem"] = try quiet {
            KeychainHelper.load(key: account, operations: operations) == updated
        }
        report.checks["syntheticItemDelete"] = try quiet { KeychainHelper.save(key: account, value: "", operations: operations) }
        report.checks["syntheticItemAbsentAfterDelete"] = try quiet { KeychainHelper.load(key: account, operations: operations) == nil }
    }

    private struct FileMetadata {
        let uid: uid_t
        let mode: mode_t
        let inode: ino_t
        let device: dev_t
        let directory: Bool
        let ordinary: Bool
    }

    private static func metadata(_ url: URL) throws -> FileMetadata {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw ProbeFailure("file_metadata") }
        return .init(uid: value.st_uid, mode: value.st_mode & 0o777,
                     inode: value.st_ino, device: value.st_dev,
                     directory: value.st_mode & S_IFMT == S_IFDIR,
                     ordinary: value.st_mode & S_IFMT == S_IFREG)
    }

    private static func extendedACLEntries(_ url: URL) throws -> Int {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProbeFailure("file_acl_open") }
        defer { close(descriptor) }
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports an absent extended ACL as ENOENT. The already
            // opened descriptor distinguishes this from a vanished pathname.
            if errno == ENOENT { return 0 }
            throw ProbeFailure("file_acl")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw ProbeFailure("file_acl_invalid") }
        var entry: acl_entry_t?
        for index in 0...128 {
            if acl_get_entry(acl, Int32(index), &entry) != 0 {
                guard errno == EINVAL else { throw ProbeFailure("file_acl_iteration") }
                return index
            }
        }
        throw ProbeFailure("file_acl_budget")
    }

    private static func verifyFiles(root: URL, report: Report) throws {
        let destination = root.appendingPathComponent("synthetic-snapshot.json")
        let first = Data("{\"synthetic\":1}".utf8)
        let updated = Data("{\"synthetic\":2}".utf8)
        try BoundedInput.writeRegularFileAtomically(first, to: destination)
        let initial = try metadata(destination)
        try BoundedInput.writeRegularFileAtomically(updated, to: destination)
        let final = try metadata(destination)
        report.checks["fileOwnerAnd0600"] = final.ordinary && final.uid == getuid() && final.mode == 0o600
        report.checks["fileAtomicReplacement"] = initial.inode != final.inode
        report.checks["fileRoundtrip"] = try BoundedInput().data(at: destination) == updated
        let fileACLCount = try extendedACLEntries(destination)
        let directoryACLCount = try extendedACLEntries(root)
        report.observation["fileExtendedACLEntries"] = fileACLCount
        report.observation["directoryExtendedACLEntries"] = directoryACLCount
        report.checks["noUnexpectedExtendedFileACL"] = fileACLCount == 0
        report.checks["noUnexpectedExtendedDirectoryACL"] = directoryACLCount == 0

        let link = root.appendingPathComponent("synthetic-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        do { _ = try BoundedInput().data(at: link); report.checks["symlinkReadRejected"] = false }
        catch { report.checks["symlinkReadRejected"] = true }
        do { try BoundedInput.writeRegularFileAtomically(first, to: link); report.checks["symlinkWriteRejected"] = false }
        catch { report.checks["symlinkWriteRejected"] = true }
        report.checks["symlinkTargetPreserved"] = try BoundedInput().data(at: destination) == updated

        let fifo = root.appendingPathComponent("synthetic-fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw ProbeFailure("fifo_create") }
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try BoundedInput().data(at: fifo); report.checks["fifoReadRejected"] = false }
        catch { report.checks["fifoReadRejected"] = true }
        report.checks["fifoRejectionDidNotBlock"] = ProcessInfo.processInfo.systemUptime - started < 1
    }

    private static func widgetFixture(used: Int = 25, cost: Double = 0) throws -> AIMeterWidgetSnapshot {
        guard let item = WidgetServiceItem.fromMetrics(
            id: "synthetic", name: "Synthetic", shortName: "S", iconName: "cpu", unit: "tokens",
            metrics: [PeriodUsageMetric(period: .monthly, usedTokens: used, limitTokens: 100)]
        ) else { throw ProbeFailure("widget_fixture") }
        return .make(services: [item], totalCostUSD: cost,
                     updatedAt: Date(timeIntervalSince1970: 1_792_400_000), hasData: true)
    }

    /// Each field and the service count satisfy the model's individual limits;
    /// the serialized document exceeds the independent 1 MiB write budget.
    private static func oversizedWidgetFixture() -> AIMeterWidgetSnapshot {
        let field = String(repeating: "x", count: 512)
        let items = (0..<256).map { index in
            let prefix = String(index)
            return WidgetServiceItem(
                id: prefix + String(repeating: "x", count: 512 - prefix.count),
                name: field, shortName: field, iconName: field,
                remainingPercent: 50, remainingRatio: 0.5, usedTokens: 1, limitTokens: 2,
                usedDisplay: field, limitDisplay: field, unit: field, bottleneckPeriod: .monthly,
                resetText: field, quotaWindowLabel: field
            )
        }
        return .make(services: items, totalCostUSD: 0,
                     updatedAt: Date(timeIntervalSince1970: 1_792_400_000), hasData: true)
    }

    private static func syntheticDirectoryEntries(_ url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    private static func widgetWriteIsRejected(_ snapshot: AIMeterWidgetSnapshot, to url: URL) -> Bool {
        do { try SharedStore.saveWidgetSnapshot(snapshot, to: url); return false }
        catch { return true }
    }

    /// Install a read-only, file-inheritable ACE on one new synthetic child
    /// directory. An independently created control file proves inheritance is
    /// active before the production writer's result can count as a test.
    private static func installSyntheticInheritableACL(on directory: URL, below root: URL) throws {
        let before = try metadata(directory)
        let rootInfo = try metadata(root)
        guard directory.lastPathComponent == "synthetic-widget-inherited-acl",
              canonicalPath(directory.deletingLastPathComponent().path) == canonicalPath(root.path),
              before.directory, before.uid == getuid(), before.mode == 0o700,
              rootInfo.directory, rootInfo.uid == getuid(), rootInfo.mode == 0o700 else {
            throw ProbeFailure("widget_acl_fixture_scope")
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProbeFailure("widget_acl_fixture_open") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == before.device,
              opened.st_ino == before.inode, opened.st_uid == before.uid,
              opened.st_mode & S_IFMT == S_IFDIR, opened.st_mode & 0o777 == before.mode,
              let group = getgrnam("everyone") else { throw ProbeFailure("widget_acl_fixture_identity") }
        var groupUUID = UUID().uuid
        let resolved = withUnsafeMutableBytes(of: &groupUUID) {
            probe_group_to_uuid(group.pointee.gr_gid, $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        guard resolved == 0 else { throw ProbeFailure("widget_acl_fixture_group") }
        var acl = acl_init(1)
        guard acl != nil else { throw ProbeFailure("widget_acl_fixture_allocate") }
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        guard acl_create_entry(&acl, &entry) == 0, let entry,
              acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 else {
            throw ProbeFailure("widget_acl_fixture_entry")
        }
        let qualifierStatus = withUnsafeBytes(of: groupUUID) { acl_set_qualifier(entry, $0.baseAddress!) }
        var permissions: acl_permset_t?
        var flags: acl_flagset_t?
        guard qualifierStatus == 0,
              acl_get_permset(entry, &permissions) == 0, let permissions,
              acl_clear_perms(permissions) == 0, acl_add_perm(permissions, ACL_READ_DATA) == 0,
              acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
              acl_clear_flags_np(flags) == 0,
              acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 0,
              acl_add_flag_np(flags, ACL_ENTRY_ONLY_INHERIT) == 0,
              let acl, acl_valid(acl) == 0,
              acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else {
            throw ProbeFailure("widget_acl_fixture_install")
        }
        let after = try metadata(directory)
        guard after.directory, after.uid == before.uid, after.mode == before.mode,
              after.inode == before.inode, after.device == before.device else {
            throw ProbeFailure("widget_acl_fixture_changed")
        }
    }

    private static func verifyWidgetFiles(root: URL, report: Report) throws {
        let plain = root.appendingPathComponent("synthetic-widget-plain", isDirectory: true)
        let inherited = root.appendingPathComponent("synthetic-widget-inherited-acl", isDirectory: true)
        for directory in [plain, inherited] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let info = try metadata(directory)
            guard info.directory, info.uid == getuid(), info.mode == 0o700 else {
                throw ProbeFailure("widget_directory")
            }
        }
        report.observation["widgetWriterScope"] = "production_SharedStore_with_explicit_synthetic_destination"
        report.observation["widgetPlainDirectoryExtendedACLEntries"] = try extendedACLEntries(plain)
        let previous = try widgetFixture()
        let updated = try widgetFixture(used: 50)
        let cache = plain.appendingPathComponent("widget.json")
        try SharedStore.saveWidgetSnapshot(previous, to: cache)
        let initial = try checkedRegularFile(cache)
        try SharedStore.saveWidgetSnapshot(updated, to: cache)
        let final = try checkedRegularFile(cache)
        let oldBytes = try BoundedInput().data(at: cache)
        report.checks["widgetFileOwnerAnd0600"] = final.uid == getuid() && final.mode == 0o600
        report.checks["widgetAtomicReplacement"] = initial.inode != final.inode
        report.checks["widgetRoundtrip"] = SharedStore.loadWidgetSnapshot(from: cache) == updated
        let plainACL = try extendedACLEntries(cache)
        report.observation["widgetPlainFileExtendedACLEntries"] = plainACL
        report.checks["widgetPlainFileHasNoExtendedACL"] = plainACL == 0

        let invalid = try widgetFixture(cost: -1)
        let oversized = oversizedWidgetFixture()
        let oversizedBytes = try JSONEncoder().encode(oversized).count
        report.observation["widgetOversizeFixtureEncodedBytes"] = oversizedBytes
        report.checks["widgetOversizeFixtureExceedsLimit"] = oversizedBytes > 1024 * 1024
        for (label, snapshot) in [("Invalid", invalid), ("Oversize", oversized)] {
            let entries = try syntheticDirectoryEntries(plain)
            report.checks["widget\(label)WriteRejected"] = widgetWriteIsRejected(snapshot, to: cache)
            report.checks["widget\(label)WritePreservesOldCache"] = try BoundedInput().data(at: cache) == oldBytes
            report.checks["widget\(label)WriteLeavesNoTemporaryFiles"] = try syntheticDirectoryEntries(plain) == entries
        }

        let target = plain.appendingPathComponent("synthetic-link-target")
        let targetBytes = Data("synthetic-link-target-unchanged".utf8)
        try BoundedInput.writeRegularFileAtomically(targetBytes, to: target)
        let link = plain.appendingPathComponent("widget-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        report.checks["widgetSymlinkReadRejected"] = !SharedStore.loadWidgetSnapshot(from: link).hasData
        for (label, snapshot) in [("Invalid", invalid), ("Oversize", oversized)] {
            let entries = try syntheticDirectoryEntries(plain)
            report.checks["widget\(label)SymlinkWriteRejected"] = widgetWriteIsRejected(snapshot, to: link)
            report.checks["widget\(label)SymlinkPreserved"] = try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path
            report.checks["widget\(label)SymlinkTargetPreserved"] = try BoundedInput().data(at: target) == targetBytes
            report.checks["widget\(label)SymlinkWriteLeavesNoTemporaryFiles"] = try syntheticDirectoryEntries(plain) == entries
        }
        try SharedStore.saveWidgetSnapshot(updated, to: link)
        let replacedLink = try checkedRegularFile(link)
        report.checks["widgetSymlinkDestinationSafelyReplaced"] = replacedLink.uid == getuid()
            && replacedLink.mode == 0o600 && SharedStore.loadWidgetSnapshot(from: link) == updated
        report.checks["widgetSymlinkTargetPreserved"] = try BoundedInput().data(at: target) == targetBytes

        let fifo = plain.appendingPathComponent("widget-fifo.json")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw ProbeFailure("widget_fifo_create") }
        var started = ProcessInfo.processInfo.systemUptime
        report.checks["widgetFIFOReadRejected"] = !SharedStore.loadWidgetSnapshot(from: fifo).hasData
        report.checks["widgetFIFOReadDidNotBlock"] = ProcessInfo.processInfo.systemUptime - started < 1
        started = ProcessInfo.processInfo.systemUptime
        try SharedStore.saveWidgetSnapshot(updated, to: fifo)
        let replacedFIFO = try checkedRegularFile(fifo)
        report.checks["widgetFIFODestinationSafelyReplaced"] = replacedFIFO.uid == getuid()
            && replacedFIFO.mode == 0o600 && SharedStore.loadWidgetSnapshot(from: fifo) == updated
        report.checks["widgetFIFOWriteDidNotBlock"] = ProcessInfo.processInfo.systemUptime - started < 1

        let blocked = plain.appendingPathComponent("widget-directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let sentinel = blocked.appendingPathComponent("synthetic-sentinel")
        let sentinelBytes = Data("synthetic-directory-unchanged".utf8)
        try BoundedInput.writeRegularFileAtomically(sentinelBytes, to: sentinel)
        let blockedIdentity = try metadata(blocked)
        let beforeRename = try syntheticDirectoryEntries(plain)
        report.checks["widgetRenameFailureRejected"] = widgetWriteIsRejected(updated, to: blocked)
        let afterRename = try metadata(blocked)
        let afterSentinelBytes = try BoundedInput().data(at: sentinel)
        report.checks["widgetRenameFailurePreservesDestination"] = afterRename.directory
            && afterRename.inode == blockedIdentity.inode && afterRename.device == blockedIdentity.device
            && afterSentinelBytes == sentinelBytes
        report.checks["widgetRenameFailurePreservesOtherCache"] = try BoundedInput().data(at: cache) == oldBytes
        report.checks["widgetRenameFailureLeavesNoTemporaryFiles"] = try syntheticDirectoryEntries(plain) == beforeRename

        try installSyntheticInheritableACL(on: inherited, below: root)
        let parentACL = try extendedACLEntries(inherited)
        let control = inherited.appendingPathComponent("synthetic-inheritance-control")
        let descriptor = open(control.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProbeFailure("widget_acl_control_create") }
        guard close(descriptor) == 0 else { throw ProbeFailure("widget_acl_control_close") }
        let controlACL = try extendedACLEntries(control)
        report.observation["widgetInheritedDirectoryExtendedACLEntries"] = parentACL
        report.observation["widgetInheritanceControlExtendedACLEntries"] = controlACL
        report.checks["widgetInheritedACLFixtureEffective"] = parentACL > 0 && controlACL > 0

        let inheritedCache = inherited.appendingPathComponent("widget.json")
        try SharedStore.saveWidgetSnapshot(updated, to: inheritedCache)
        let inheritedFile = try checkedRegularFile(inheritedCache)
        let fileACL = try extendedACLEntries(inheritedCache)
        report.observation["widgetInheritedFileExtendedACLEntries"] = fileACL
        report.checks["widgetInheritedFileOwnerAnd0600"] = inheritedFile.uid == getuid() && inheritedFile.mode == 0o600
        report.checks["widgetInheritedFileHasNoExtendedACL"] = fileACL == 0
        report.checks["widgetInheritedFileRoundtrip"] = SharedStore.loadWidgetSnapshot(from: inheritedCache) == updated
        report.checks["widgetInheritedWriteLeavesNoTemporaryFiles"] = try syntheticDirectoryEntries(inherited)
            == Set(["synthetic-inheritance-control", "widget.json"])

        // The Widget fixture exposed a retained inherited read ACE at mode 0600
        // before any Core fix. Measure the aggregate producer independently;
        // never normalize either output's ACL in the probe to make it pass.
        report.observation["inheritedACLWriterPolicy"] = "both_production_writers_observed_without_output_acl_repair"
        let aggregate = inherited.appendingPathComponent("aggregate.json")
        let aggregateFirst = Data("{\"synthetic\":1}".utf8)
        let aggregateUpdated = Data("{\"synthetic\":2}".utf8)
        let widgetBeforeAggregate = try BoundedInput().data(at: inheritedCache)
        try BoundedInput.writeRegularFileAtomically(aggregateFirst, to: aggregate)
        let aggregateInitial = try checkedRegularFile(aggregate)
        report.observation["aggregateInheritedInitialExtendedACLEntries"] = try extendedACLEntries(aggregate)
        try BoundedInput.writeRegularFileAtomically(aggregateUpdated, to: aggregate)
        let aggregateFinal = try checkedRegularFile(aggregate)
        let aggregateACL = try extendedACLEntries(aggregate)
        report.observation["aggregateInheritedFileExtendedACLEntries"] = aggregateACL
        report.checks["aggregateInheritedFileOwnerAnd0600"] = aggregateFinal.uid == getuid()
            && aggregateFinal.mode == 0o600
        report.checks["aggregateInheritedAtomicReplacement"] = aggregateFinal.inode != aggregateInitial.inode
        report.checks["aggregateInheritedFileHasNoExtendedACL"] = aggregateACL == 0
        report.checks["aggregateInheritedFileRoundtrip"] = try BoundedInput().data(at: aggregate) == aggregateUpdated
        report.checks["aggregateInheritedWritePreservesWidgetData"] = try BoundedInput().data(at: inheritedCache)
            == widgetBeforeAggregate

        let aggregateLink = inherited.appendingPathComponent("aggregate-link.json")
        try FileManager.default.createSymbolicLink(at: aggregateLink, withDestinationURL: aggregate)
        let beforeAggregateLink = try syntheticDirectoryEntries(inherited)
        do {
            try BoundedInput.writeRegularFileAtomically(aggregateFirst, to: aggregateLink)
            report.checks["aggregateInheritedSymlinkWriteRejected"] = false
        } catch { report.checks["aggregateInheritedSymlinkWriteRejected"] = true }
        report.checks["aggregateInheritedSymlinkPreserved"] = try FileManager.default
            .destinationOfSymbolicLink(atPath: aggregateLink.path) == aggregate.path
        report.checks["aggregateInheritedSymlinkTargetPreserved"] = try BoundedInput().data(at: aggregate)
            == aggregateUpdated
        report.checks["aggregateInheritedSymlinkWriteLeavesNoTemporaryFiles"] = try syntheticDirectoryEntries(inherited)
            == beforeAggregateLink
        report.checks["aggregateInheritedWriteLeavesNoTemporaryFiles"] = try syntheticDirectoryEntries(inherited)
            == Set(["synthetic-inheritance-control", "widget.json", "aggregate.json", "aggregate-link.json"])
        let parentACLAfterAggregate = try extendedACLEntries(inherited)
        let controlACLAfterAggregate = try extendedACLEntries(control)
        report.checks["aggregateInheritedACLFixtureStillEffective"] = parentACLAfterAggregate > 0
            && controlACLAfterAggregate > 0
    }

    private static func operations(keychain: SecKeychain, report: Report) -> KeychainHelper.Operations {
        func scoped(_ query: [String: Any]) -> [String: Any] {
            var value = query
            value[kSecMatchSearchList as String] = [keychain]
            return value
        }
        return .init(update: { query, attributes in
            let status = SecItemUpdate(scoped(query) as CFDictionary, attributes as CFDictionary)
            report.statuses["lastUpdate"] = status
            return status
        }, add: { query in
            var value = query
            value[kSecUseKeychain as String] = keychain
            let status = SecItemAdd(value as CFDictionary, nil)
            report.statuses["lastAdd"] = status
            return status
        }, delete: { query in
            let status = SecItemDelete(scoped(query) as CFDictionary)
            report.statuses["lastDelete"] = status
            return status
        }, copyMatching: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(scoped(query) as CFDictionary, &item)
            report.statuses["lastRead"] = status
            return (status, item as? Data)
        })
    }

    private struct KeychainConfiguration: Equatable {
        let defaultPath: String
        let searchPaths: [String]
    }

    private static func keychainConfiguration() throws -> KeychainConfiguration {
        var defaultKeychain: SecKeychain?
        let defaultStatus = SecKeychainCopyDefault(&defaultKeychain)
        guard defaultStatus == errSecSuccess, let defaultKeychain else {
            throw ProbeFailure("default_keychain_snapshot", defaultStatus)
        }
        var list: CFArray?
        let searchStatus = SecKeychainCopySearchList(&list)
        guard searchStatus == errSecSuccess, let keychains = list as? [SecKeychain] else {
            throw ProbeFailure("keychain_search_snapshot", searchStatus)
        }
        return try .init(defaultPath: keychainPath(defaultKeychain), searchPaths: keychains.map(keychainPath))
    }

    private static func keychainPath(_ keychain: SecKeychain) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4096)
        var length = UInt32(bytes.count)
        let status = SecKeychainGetPath(keychain, &length, &bytes)
        guard status == errSecSuccess, length > 0, Int(length) < bytes.count else { throw ProbeFailure("keychain_path", status) }
        return String(cString: bytes)
    }

    private static func quiet<T>(_ action: () -> T) throws -> T {
        let saved = dup(STDOUT_FILENO)
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard saved >= 0, null >= 0 else {
            if saved >= 0 { close(saved) }
            if null >= 0 { close(null) }
            throw ProbeFailure("stdout_isolation")
        }
        fflush(stdout)
        guard dup2(null, STDOUT_FILENO) >= 0 else {
            close(saved); close(null); throw ProbeFailure("stdout_isolation")
        }
        close(null)
        defer { fflush(stdout); dup2(saved, STDOUT_FILENO); close(saved) }
        return action()
    }

    /// Use native canonical paths plus the opened object's identity. URL's
    /// equality also includes representation details such as directory flags.
    private static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count < Int(PATH_MAX) else { return nil }
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &bytes) != nil else { return nil }
        return String(cString: bytes)
    }

    private static func checkedRegularFile(_ url: URL) throws -> FileMetadata {
        let before = try metadata(url)
        guard before.ordinary else { throw ProbeFailure("regular_file_scope") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProbeFailure("regular_file_open") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_ino == before.inode, opened.st_dev == before.device,
              opened.st_uid == before.uid, (opened.st_mode & 0o777) == before.mode else {
            throw ProbeFailure("regular_file_changed")
        }
        return before
    }

    /// Restrict only the storage file just returned by our successful Create.
    /// Binding has already proved its logical/physical path correspondence.
    private static func restrictNewKeychainFile(_ url: URL, expected: FileMetadata,
                                                root: URL, rootIdentity: FileMetadata) throws -> FileMetadata {
        let currentRoot = try metadata(root)
        guard let canonicalRoot = canonicalPath(root.path),
              let canonicalParent = canonicalPath(url.deletingLastPathComponent().path),
              url.lastPathComponent == keychainFilename, canonicalParent == canonicalRoot,
              currentRoot.directory, currentRoot.uid == getuid(), currentRoot.mode == 0o700,
              currentRoot.inode == rootIdentity.inode, currentRoot.device == rootIdentity.device,
              expected.ordinary, expected.uid == getuid() else {
            throw ProbeFailure("keychain_file_restrict_scope")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProbeFailure("keychain_file_restrict_open") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == expected.uid, opened.st_ino == expected.inode,
              opened.st_dev == expected.device, (opened.st_mode & 0o777) == expected.mode else {
            throw ProbeFailure("keychain_file_restrict_changed")
        }
        guard fchmod(descriptor, 0o600) == 0,
              fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == expected.uid, opened.st_ino == expected.inode,
              opened.st_dev == expected.device, (opened.st_mode & 0o777) == 0o600 else {
            throw ProbeFailure("keychain_file_restrict")
        }
        let after = try checkedRegularFile(url)
        guard after.inode == expected.inode, after.device == expected.device,
              after.uid == expected.uid, after.mode == 0o600 else {
            throw ProbeFailure("keychain_file_restrict_path_changed")
        }
        return after
    }

    private static func sameFile(_ lhs: FileMetadata, _ rhs: FileMetadata) -> Bool {
        lhs.ordinary && rhs.ordinary && lhs.inode == rhs.inode && lhs.device == rhs.device
            && lhs.uid == rhs.uid && lhs.mode == rhs.mode
    }

    private static func keychainStorageBinding(_ keychain: SecKeychain, requested: URL)
        throws -> (matches: Bool, diagnostics: [String: Any]) {
        let returned = try keychainPath(keychain)
        let returnedURL = URL(fileURLWithPath: returned)
        let expectedParent = canonicalPath(requested.deletingLastPathComponent().path)
        let actualParent = canonicalPath(returnedURL.deletingLastPathComponent().path)
        let expectedCanonical = canonicalPath(requested.path)
        let expectedFile = try? checkedRegularFile(requested)
        let directFile = try? checkedRegularFile(returnedURL)
        let databaseURL = URL(fileURLWithPath: returnedURL.path + "-db")
        let databaseFile = try? checkedRegularFile(databaseURL)
        let parentMatches = expectedParent != nil && expectedParent == actualParent
        let directMatches = expectedCanonical != nil && canonicalPath(returnedURL.path) == expectedCanonical
            && expectedFile != nil && directFile != nil && sameFile(expectedFile!, directFile!)
        // Legacy SecKeychain APIs may return the logical .keychain name while
        // the physical storage is .keychain-db. Allow only that one exact suffix
        // mapping to the already checked file in the same newly created folder.
        let databaseMatches = returnedURL.lastPathComponent.hasSuffix(".keychain")
            && requested.lastPathComponent == returnedURL.lastPathComponent + "-db"
            && expectedCanonical != nil && canonicalPath(databaseURL.path) == expectedCanonical
            && expectedFile != nil && databaseFile != nil && sameFile(expectedFile!, databaseFile!)
        let suffix: String
        if returnedURL.lastPathComponent.hasSuffix(".keychain-db") { suffix = "keychain-db" }
        else if returnedURL.lastPathComponent.hasSuffix(".keychain") { suffix = "keychain" }
        else { suffix = "other" }
        let diagnostics: [String: Any] = [
            "returnedBasenameSuffix": suffix,
            "returnedAbsolute": returned.hasPrefix("/"),
            "returnedLexicalPathEqualsReturnedPath": returnedURL.path == returned,
            "canonicalParentMatches": parentMatches,
            "requestedFileExists": expectedFile != nil,
            "returnedPathEqualsRequestedPath": returned == requested.path,
            "returnedCanonicalEqualsRequestedCanonical": expectedCanonical != nil
                && canonicalPath(returnedURL.path) == expectedCanonical,
            "requestedFoundationResolvedEqualsRequestedPath": requested.resolvingSymlinksInPath().path == requested.path,
            "requestedRealpathEqualsRequestedPath": expectedCanonical == requested.path,
            "directStorageMatchesInode": directMatches,
            "logicalStorageMatchesInode": databaseMatches
        ]
        return (returned.hasPrefix("/") && returnedURL.path == returned
                && parentMatches && (directMatches || databaseMatches), diagnostics)
    }

    private static func checkedReaderExecutable(_ path: String, report: Report) throws -> URL {
        let url = URL(fileURLWithPath: path)
        let info = try checkedRegularFile(url)
        let resolved = canonicalPath(path)
        report.observation["readerExecutablePath"] = [
            "absolute": path.hasPrefix("/"),
            "lexicalPathEqualsRequestedPath": url.path == path,
            "foundationResolvedPathEqualsRequestedPath": url.resolvingSymlinksInPath().path == path,
            "realpathEqualsRequestedPath": resolved == path,
            "uidEqualsCurrent": info.uid == getuid(),
            "mode": Int(info.mode),
            "hasExecuteBit": info.mode & 0o111 != 0,
            "groupOrOtherWritable": info.mode & 0o022 != 0
        ]
        guard path.hasPrefix("/"), url.path == path, resolved == path,
              info.uid == getuid(), info.mode & 0o111 != 0, info.mode & 0o022 == 0 else {
            throw ProbeFailure("reader_executable")
        }
        return URL(fileURLWithPath: resolved!)
    }

    private static func checkedReaderKeychain(_ path: String, account: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        let root = url.deletingLastPathComponent()
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let rootInfo = try metadata(root)
        let fileInfo = try checkedRegularFile(url)
        let suffix = String(root.lastPathComponent.dropFirst(directoryPrefix.count))
        guard path.hasPrefix("/"), path == url.path, canonicalPath(path) == path,
              url.lastPathComponent == keychainFilename,
              canonicalPath(root.deletingLastPathComponent().path) == canonicalPath(parent.path),
              root.lastPathComponent.hasPrefix(directoryPrefix), UUID(uuidString: suffix) != nil,
              rootInfo.directory, rootInfo.uid == getuid(), rootInfo.mode == 0o700,
              fileInfo.uid == getuid(), fileInfo.mode & 0o077 == 0,
              account.hasPrefix("synthetic-"), UUID(uuidString: String(account.dropFirst(10))) != nil else {
            throw ProbeFailure("reader_scope")
        }
        return url
    }

    private static func reader(_ arguments: [String]) {
        var status = errSecParam
        var canRead = false
        var pathDiagnostics: [String: Any] = [:]
        if arguments.count == 3 {
            do {
                let url = try checkedReaderKeychain(arguments[1], account: arguments[2])
                guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw ProbeFailure("reader_interaction") }
                var keychain: SecKeychain?
                status = SecKeychainOpen(url.path, &keychain)
                if status == errSecSuccess, let keychain {
                    let binding = try keychainStorageBinding(keychain, requested: url)
                    pathDiagnostics = binding.diagnostics
                    guard binding.matches else { throw ProbeFailure("reader_keychain_path") }
                    var value: CFTypeRef?
                    let query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: KeychainHelper.service,
                        kSecAttrAccount as String: arguments[2],
                        kSecMatchSearchList as String: [keychain],
                        kSecReturnData as String: true,
                        kSecMatchLimit as String: kSecMatchLimitOne
                    ]
                    status = SecItemCopyMatching(query as CFDictionary, &value)
                    canRead = status == errSecSuccess && value is Data
                }
            } catch { status = errSecParam }
        }
        let object: [String: Any] = ["canRead": canRead, "status": status, "pathDiagnostics": pathDiagnostics]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
        // The parent interprets the exact status and distinguishes an ACL denial
        // from a missing item or malformed scope. No item bytes are returned.
        exit(0)
    }

    private static func runReader(_ executable: URL, keychain: URL, account: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--reader", keychain.path, account]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                               "TMPDIR": FileManager.default.temporaryDirectory.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw ProbeFailure("reader_pipe") }
        try process.run()
        defer {
            if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeFailure("reader_timeout") }
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard data.count + count <= 4096 else { throw ProbeFailure("reader_output_limit") }
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EINTR { throw ProbeFailure("reader_pipe") }
            else { usleep(5_000) }
        }
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeFailure("reader_timeout") }
            usleep(5_000)
        }
        guard process.terminationStatus == 0,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["canRead"] is Bool, result["status"] is NSNumber else { throw ProbeFailure("reader_result") }
        return result
    }
}
