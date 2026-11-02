import Foundation
import XCTest
@testable import AIMeter

/// Runs the shipping handoff script against synthetic directories. System
/// inspection, signalling, verification and launch commands are fixture tools;
/// the only real renames are restricted to this test's private directory.
final class UpdateInstallerTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let destination: URL
        let retained: URL
        let candidate: URL
        let tool: URL

        init() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("AIMeter-installer-\(UUID().uuidString)", isDirectory: true)
            let fixtureDestination = fixtureRoot.appendingPathComponent("Apps with spaces $literal ; 'quoted' $(echo harmless)")
                .appendingPathComponent("AIMeter.app", isDirectory: true)
            let fixtureRetained = fixtureRoot.appendingPathComponent(".AIMeter-update $literal 'quoted'", isDirectory: true)
            root = fixtureRoot
            destination = fixtureDestination
            retained = fixtureRetained
            candidate = fixtureRetained.appendingPathComponent("expanded/AIMeter.app", isDirectory: true)
            tool = fixtureRoot.appendingPathComponent("fixture commands 'quoted'.sh")
            for directory in [destination, candidate] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
            }
            try write("old", to: destination.appendingPathComponent("generation"))
            try write("new", to: candidate.appendingPathComponent("generation"))
            try write("keep", to: root.appendingPathComponent("unrelated-sentinel"))
            try write(Self.commandStub, to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func contents(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        func generation(at app: URL) throws -> String {
            try String(contentsOf: app.appendingPathComponent("generation"), encoding: .utf8)
        }

        private func write(_ value: String, to url: URL) throws {
            try value.write(to: url, atomically: true, encoding: .utf8)
        }

        private func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        func run(fault: String = "", parentMode: String = "gone") throws -> Int32 {
            let commands = ["/usr/bin/codesign": "codesign", "/usr/sbin/spctl": "spctl",
                            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister": "register",
                            "/usr/bin/pluginkit": "pluginkit",
                            "/usr/bin/open": "open", "/bin/ps": "ps", "/bin/kill": "kill",
                            "/bin/sleep": "sleep", "/bin/mv": "mv", "/bin/echo": "echo"]
            var script = UpdateInstallation.installerScript
            for (command, name) in commands {
                script = script.replacingOccurrences(of: command, with: shellQuote(tool.path) + " " + name)
            }
            // Fail closed if a fixture replacement stops matching the shipping
            // script; this test must never inspect or signal actual apps.
            for command in commands.keys {
                guard !script.contains(command) else {
                    throw NSError(domain: "UpdateInstallerFixture", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Unreplaced command: \(command)"])
                }
            }
            let scriptURL = retained.appendingPathComponent("fixture-install.sh")
            try write(script, to: scriptURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path, "987654", destination.path, candidate.path, retained.path]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                                   "FIXTURE_ROOT": root.path, "FIXTURE_DESTINATION": destination.path,
                                   "FIXTURE_CANDIDATE": candidate.path, "FIXTURE_FAULT": fault,
                                   "FIXTURE_PARENT_MODE": parentMode]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                XCTFail("Synthetic installer exceeded its fixture deadline")
            } else {
                process.waitUntilExit()
            }
            return process.terminationStatus
        }

        private static let commandStub = #"""
        #!/bin/bash
        set -u
        command="$1"
        shift
        last=""
        for argument in "$@"; do last="$argument"; done
        case "$command" in
          codesign)
            [[ "$FIXTURE_FAULT" == "signature" && "$last" == "$FIXTURE_CANDIDATE" ]] && exit 12
            exit 0
            ;;
          spctl) exit 0 ;;
          register)
            [[ "$last" == "$FIXTURE_DESTINATION" && -f "$last/generation" ]] || exit 125
            generation="$(<"$last/generation")"
            [[ "$FIXTURE_FAULT" == "registration" && "$generation" == "new" ]] && exit 15
            exit 0
            ;;
          pluginkit)
            [[ "$last" == "$FIXTURE_DESTINATION/Contents/PlugIns/AIMeterWidget.appex" ]] || exit 125
            exit 0
            ;;
          ps)
            if [[ -f "$FIXTURE_ROOT/running" && "$(<"$FIXTURE_ROOT/running")" == "1" ]]; then
                printf '4242 %s/Contents/MacOS/AIMeter\n' "$FIXTURE_DESTINATION"
            fi
            exit 0
            ;;
          kill)
            if [[ "$1" == "-0" && "$2" == "987654" ]]; then
                checks=0
                [[ -f "$FIXTURE_ROOT/parent-checks" ]] && checks="$(<"$FIXTURE_ROOT/parent-checks")"
                checks=$((checks + 1))
                printf '%s' "$checks" >"$FIXTURE_ROOT/parent-checks"
                [[ "$FIXTURE_PARENT_MODE" == "alive" ]] && exit 0
                [[ "$FIXTURE_PARENT_MODE" == "wait-then-exit" && "$checks" -le 3 ]] && exit 0
                exit 1
            fi
            if [[ "$1" == "-0" && "$2" == "4242" ]]; then
                [[ -f "$FIXTURE_ROOT/running" && "$(<"$FIXTURE_ROOT/running")" == "1" ]]
                exit $?
            fi
            if [[ "$1" == "-TERM" && "$2" == "4242" ]]; then
                printf '0' >"$FIXTURE_ROOT/running"
                exit 0
            fi
            exit 125
            ;;
          sleep)
            printf '%s\n' "$1" >>"$FIXTURE_ROOT/sleeps"
            exit 0
            ;;
          open)
            [[ "$last" == "$FIXTURE_DESTINATION" && -f "$last/generation" ]] || exit 125
            generation="$(<"$last/generation")"
            printf '%s\n' "$generation" >>"$FIXTURE_ROOT/launches"
            [[ "$FIXTURE_FAULT" == "open" && "$generation" == "new" ]] && exit 13
            printf '1' >"$FIXTURE_ROOT/running"
            exit 0
            ;;
          mv)
            [[ "$#" -eq 2 ]] || exit 125
            case "$1" in "$FIXTURE_ROOT"/*) ;; *) exit 125 ;; esac
            case "$2" in "$FIXTURE_ROOT"/*) ;; *) exit 125 ;; esac
            if [[ "$FIXTURE_FAULT" == "rename" && "$1" == "$FIXTURE_CANDIDATE" ]]; then exit 14; fi
            exec /bin/mv "$@"
            ;;
          echo) printf '%s\n' "$*" ;;
          *) exit 125 ;;
        esac
        """#
    }

    func testSuccessfulHandoffWaitsForParentAndPreservesPreviousWithLiteralPaths() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.run(parentMode: "wait-then-exit"), 0)
        XCTAssertEqual(try fixture.generation(at: fixture.destination), "new")
        XCTAssertEqual(try fixture.generation(at: fixture.retained.appendingPathComponent("previous.app")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.candidate.path))
        XCTAssertEqual(try String(contentsOf: fixture.retained.appendingPathComponent("result"), encoding: .utf8), "installed")
        XCTAssertEqual(try fixture.contents("launches"), "new\n")
        XCTAssertEqual(try fixture.contents("unrelated-sentinel"), "keep")
        XCTAssertGreaterThanOrEqual(Int(try fixture.contents("parent-checks")) ?? 0, 5)
    }

    func testCandidateVerificationFailureLeavesCurrentAppInPlace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertNotEqual(try fixture.run(fault: "signature"), 0)
        XCTAssertEqual(try fixture.generation(at: fixture.destination), "old")
        XCTAssertEqual(try fixture.generation(at: fixture.candidate), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.retained.appendingPathComponent("previous.app").path))
        XCTAssertEqual(try String(contentsOf: fixture.retained.appendingPathComponent("result"), encoding: .utf8), "failed")
        XCTAssertEqual(try fixture.contents("launches"), "old\n")
    }

    func testCandidateRenameFailureRestoresThePreviousApp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertNotEqual(try fixture.run(fault: "rename"), 0)
        XCTAssertEqual(try fixture.generation(at: fixture.destination), "old")
        XCTAssertEqual(try fixture.generation(at: fixture.candidate), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.retained.appendingPathComponent("previous.app").path))
        XCTAssertEqual(try fixture.contents("launches"), "old\n")
    }

    func testNewAppLaunchFailureRollsBackAndRetainsFailedCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertNotEqual(try fixture.run(fault: "open"), 0)
        XCTAssertEqual(try fixture.generation(at: fixture.destination), "old")
        XCTAssertEqual(try fixture.generation(at: fixture.retained.appendingPathComponent("failed.app")), "new")
        XCTAssertEqual(try String(contentsOf: fixture.retained.appendingPathComponent("result"), encoding: .utf8), "restored")
        XCTAssertEqual(try fixture.contents("launches"), "new\nold\n")
    }

    func testParentTimeoutLeavesBothBundlesUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertNotEqual(try fixture.run(parentMode: "alive"), 0)
        XCTAssertEqual(try fixture.generation(at: fixture.destination), "old")
        XCTAssertEqual(try fixture.generation(at: fixture.candidate), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.retained.appendingPathComponent("previous.app").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("launches").path))
        XCTAssertEqual(try fixture.contents("parent-checks"), "151")
        XCTAssertEqual(try String(contentsOf: fixture.retained.appendingPathComponent("result"), encoding: .utf8), "failed")
    }

    func testRegistrationFailureRollsBackBeforeLaunchingTheCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertNotEqual(try fixture.run(fault: "registration"), 0)
        XCTAssertEqual(try fixture.generation(at: fixture.destination), "old")
        XCTAssertEqual(try fixture.generation(at: fixture.retained.appendingPathComponent("failed.app")), "new")
        XCTAssertEqual(try fixture.contents("launches"), "old\n")
    }
}
