import XCTest
import AIMeterCore
import Darwin
@testable import AIMeter

final class BoundedIntegrationsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AIMeter-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func executable(_ relative: String = "sdk/bin/gcloud") throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf synthetic\n".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o700), 0)
        return file
    }

    func testTrustedResolvedPathRejectsWritableHigherAncestor() throws {
        let file = try executable()
        let resolved = try XCTUnwrap(ExecutableTrust.executable(at: file.path))
        var originalInfo = stat(), resolvedInfo = stat()
        XCTAssertEqual(lstat(file.path, &originalInfo), 0)
        XCTAssertEqual(lstat(resolved, &resolvedInfo), 0)
        XCTAssertEqual(originalInfo.st_dev, resolvedInfo.st_dev)
        XCTAssertEqual(originalInfo.st_ino, resolvedInfo.st_ino)
        XCTAssertEqual(resolvedInfo.st_mode & S_IFMT, S_IFREG)
        let link = root.appendingPathComponent("gcloud-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(ExecutableTrust.executable(at: link.path), resolved)
        let ancestor = root.appendingPathComponent("sdk")
        XCTAssertEqual(chmod(ancestor.path, 0o775), 0)
        XCTAssertNil(ExecutableTrust.executable(at: file.path))
        XCTAssertNil(ExecutableTrust.executable(at: link.path))
        XCTAssertEqual(chmod(ancestor.path, 0o700), 0)
        XCTAssertNotNil(ExecutableTrust.executable(at: link.path))
    }

    func testACLWriteGrantIsRejectedEvenWithPrivateMode() throws {
        let file = try executable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow write,append,delete,writeattr,writeextattr,writesecurity,chown", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(ExecutableTrust.executable(at: file.path))
    }

    func testStickySharedDirectoryIsOnlyAllowedAsAnAncestor() throws {
        let file = try executable("shared/owned/bin/gcloud")
        let shared = root.appendingPathComponent("shared")
        XCTAssertEqual(chmod(shared.path, 0o1777), 0)
        XCTAssertNil(ExecutableTrust.directory(at: shared.path))
        XCTAssertThrowsError(try GcloudEnvironment.make(home: root.path,
            inherited: ["CLOUDSDK_CONFIG": shared.path]))
        XCTAssertNotNil(ExecutableTrust.executable(at: file.path))
        XCTAssertNotNil(ExecutableTrust.directory(at: file.deletingLastPathComponent().path))
    }

    func testIntermediateSymlinkTargetAncestorsAreAlsoChecked() throws {
        let file = try executable("protected/bin/gcloud")
        let aliases = root.appendingPathComponent("aliases")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: aliases, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let intermediate = aliases.appendingPathComponent("sdk")
        try FileManager.default.createSymbolicLink(at: intermediate,
            withDestinationURL: root.appendingPathComponent("protected"))
        let entry = bin.appendingPathComponent("gcloud")
        try FileManager.default.createSymbolicLink(at: entry,
            withDestinationURL: intermediate.appendingPathComponent("bin/gcloud"))
        XCTAssertNotNil(ExecutableTrust.executable(at: entry.path))
        XCTAssertEqual(chmod(aliases.path, 0o775), 0)
        XCTAssertNil(ExecutableTrust.executable(at: entry.path))
        XCTAssertNotNil(ExecutableTrust.executable(at: file.path))
    }

    func testGcloudEnvironmentDoesNotInheritCredentialOrLoaderInjection() throws {
        let environment = try GcloudEnvironment.make(home: root.path, inherited: [
            "HOME": "unrelated", "PYTHONPATH": "/untrusted", "DYLD_LIBRARY_PATH": "/untrusted",
            "CLOUDSDK_ACTIVE_CONFIG_NAME": "synthetic", "USER": "synthetic"
        ])
        XCTAssertEqual(environment["HOME"], root.path)
        XCTAssertEqual(environment["USER"], "synthetic")
        XCTAssertNil(environment["PYTHONPATH"])
        XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
        XCTAssertNil(environment["CLOUDSDK_AUTH_ACCESS_TOKEN"])
        XCTAssertNil(environment["CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE"])
        XCTAssertEqual(environment["CLOUDSDK_CORE_DISABLE_PROMPTS"], "1")
        XCTAssertEqual(environment["CLOUDSDK_ACTIVE_CONFIG_NAME"], "synthetic")
        XCTAssertThrowsError(try GcloudEnvironment.make(home: root.path,
            inherited: ["CLOUDSDK_AUTH_ACCESS_TOKEN": "synthetic-credential"]))
        XCTAssertThrowsError(try GcloudEnvironment.make(home: root.path,
            inherited: ["CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE": "/untrusted"]))
        XCTAssertThrowsError(try GcloudEnvironment.make(home: root.path,
                                                      inherited: ["CLOUDSDK_PYTHON": "/missing/python"]))
    }

    func testDefaultGcloudConfigurationUsesCheckedDirectory() throws {
        let configuration = root.appendingPathComponent(".config/gcloud", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let environment = try GcloudEnvironment.make(home: root.path, inherited: [:])
        XCTAssertEqual(environment["CLOUDSDK_CONFIG"], ExecutableTrust.directory(at: configuration.path))
    }

    func testAbsentDefaultGcloudConfigurationDoesNotCreateOrChangeSelection() throws {
        let configurationParent = root.appendingPathComponent(".config", isDirectory: true)
        let configuration = configurationParent.appendingPathComponent("gcloud", isDirectory: true)
        let expected = URL(fileURLWithPath: try XCTUnwrap(ExecutableTrust.directory(at: root.path)),
                           isDirectory: true).appendingPathComponent(".config/gcloud").path
        let noParent = try GcloudEnvironment.make(home: root.path, inherited: [:])
        XCTAssertEqual(noParent["CLOUDSDK_CONFIG"], expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationParent.path))
        try FileManager.default.createDirectory(at: configurationParent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let noConfiguration = try GcloudEnvironment.make(home: root.path, inherited: [:])
        XCTAssertEqual(noConfiguration["CLOUDSDK_CONFIG"], expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.path))
    }

    func testDefaultGcloudConfigurationRejectsWritableParentAndDanglingSymlink() throws {
        let configurationParent = root.appendingPathComponent(".config", isDirectory: true)
        let configuration = configurationParent.appendingPathComponent("gcloud", isDirectory: true)
        try FileManager.default.createDirectory(at: configurationParent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(chmod(configurationParent.path, 0o775), 0)
        XCTAssertThrowsError(try GcloudEnvironment.make(home: root.path, inherited: [:]))
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try GcloudEnvironment.make(home: root.path, inherited: [:]))
        XCTAssertEqual(chmod(configurationParent.path, 0o700), 0)
        XCTAssertNoThrow(try GcloudEnvironment.make(home: root.path, inherited: [:]))
        try FileManager.default.removeItem(at: configuration)
        try FileManager.default.createSymbolicLink(at: configuration,
            withDestinationURL: root.appendingPathComponent("missing-target"))
        XCTAssertThrowsError(try GcloudEnvironment.make(home: root.path, inherited: [:]))
    }

    func testNormalSubprocessDrainsBothPipesAndPreservesArguments() async throws {
        let output = try await BoundedProcess.run(executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$1\"; printf note >&2", "fixture", "synthetic;literal"],
            environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "synthetic;literal")
        XCTAssertEqual(String(data: output.stderr, encoding: .utf8), "note")
    }

    func testOversizedStderrReturnsWithoutWaitingForEOF() async throws {
        var limits = BoundedProcess.Limits(); limits.seconds = 0.5; limits.stderrBytes = 100
        do {
            _ = try await BoundedProcess.run(executable: "/bin/sh",
                arguments: ["-c", "while :; do printf 'synthetic-error-output' >&2; done"],
                environment: ["PATH": "/usr/bin:/bin"], limits: limits)
            XCTFail("Oversized output was accepted")
        } catch BoundedProcess.Failure.outputLimit { }
    }

    func testTermIgnoringProcessAndInheritedPipeAreBounded() async throws {
        var limits = BoundedProcess.Limits()
        limits.seconds = 0.15; limits.terminationGrace = 0.05; limits.killGrace = 0.5
        for script in ["trap '' TERM; while :; do :; done", "sleep 30 & exit 0"] {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", script],
                    environment: ["PATH": "/usr/bin:/bin"], limits: limits)
                XCTFail("The fixture should time out")
            } catch BoundedProcess.Failure.timeout { }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        }
    }

    func testProcessCancellationDoesNotWaitForPipeEOF() async throws {
        let task = Task {
            try await BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "sleep 30"],
                                         environment: ["PATH": "/usr/bin:/bin"])
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled process returned success") }
        catch is CancellationError { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
}
