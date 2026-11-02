import Foundation
import Darwin

/// A private process group and nonblocking pipes make timeout/cancellation
/// independent of stdout EOF or a cooperative child. No shell is introduced.
enum BoundedProcess {
    struct Limits: Sendable {
        var seconds: TimeInterval = 8
        var stdoutBytes = 65_536
        var stderrBytes = 65_536
        var terminationGrace: TimeInterval = 0.2
        var killGrace: TimeInterval = 0.5
    }

    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
    }

    enum Failure: Error { case launch, outputLimit, timeout, exit, cleanup }

    // If an owned child cannot be reaped in bounded cleanup, do not pile up
    // retries. This concerns only this runner, not unrelated system processes.
    private static let gate = CleanupGate()
    private final class CleanupGate: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked = false
        func check() throws {
            lock.lock(); defer { lock.unlock() }
            if blocked { throw Failure.cleanup }
        }
        func block() { lock.lock(); blocked = true; lock.unlock() }
    }

    static func run(executable: String, arguments: [String], environment: [String: String],
                    limits: Limits = Limits(), permit: IntegrationPermit? = nil) async throws -> Output {
        let worker = Task.detached(priority: .utility) {
            try runSynchronously(executable: executable, arguments: arguments,
                                 environment: environment, limits: limits, permit: permit)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func runSynchronously(executable: String, arguments: [String],
                                         environment: [String: String], limits: Limits,
                                         permit: IntegrationPermit?) throws -> Output {
        try gate.check()
        try Task.checkCancellation()
        guard limits.seconds > 0, limits.stdoutBytes >= 0, limits.stderrBytes >= 0,
              limits.terminationGrace >= 0, limits.killGrace >= 0,
              !([executable] + arguments + Array(environment.keys) + Array(environment.values))
                .contains(where: { $0.utf8.contains(0) }) else { throw Failure.launch }
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard Darwin.pipe(&out) == 0 else { throw Failure.launch }
        guard Darwin.pipe(&err) == 0 else {
            out.forEach { Darwin.close($0) }; throw Failure.launch
        }
        defer { (out + err).filter { $0 >= 0 }.forEach { Darwin.close($0) } }
        for fd in out + err {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { throw Failure.launch }
        }
        for fd in [out[0], err[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw Failure.launch }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.launch }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.launch }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw Failure.launch
        }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        var pid: pid_t = 0
        let launchStatus: Int32
        if let permit {
            launchStatus = try permit.withPermission {
                posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
            }
        } else {
            try Task.checkCancellation()
            launchStatus = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        }
        guard launchStatus == 0 else { throw Failure.launch }
        Darwin.close(out[1]); out[1] = -1
        Darwin.close(err[1]); err[1] = -1
        let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
        var output = Data()
        var errors = Data()
        var outEOF = false
        var errEOF = false
        var exited = false
        var reaped = false
        var ownsWaitableChild = true

        // Do not reap the group leader until after signalling its group. Keeping
        // it waitable prevents the group identifier from being reused meanwhile.
        func childExited() throws -> Bool {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                return info.si_pid == pid
            }
            if errno == EINTR { return false }
            if errno == ECHILD { ownsWaitableChild = false; gate.block() }
            throw Failure.cleanup
        }
        func reap(until end: TimeInterval) -> Bool {
            var status: Int32 = 0
            while ProcessInfo.processInfo.systemUptime < end {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { return true }
                if result == -1 && errno != EINTR {
                    if errno == ECHILD { ownsWaitableChild = false }
                    return false
                }
                usleep(5_000)
            }
            return false
        }
        defer {
            if !reaped && ownsWaitableChild {
                // POSIX_SPAWN_SETPGROUP assigned only this child a new group.
                kill(-pid, SIGTERM)
                let termEnd = ProcessInfo.processInfo.systemUptime + limits.terminationGrace
                while ProcessInfo.processInfo.systemUptime < termEnd {
                    if (try? childExited()) == true { break }
                    usleep(5_000)
                }
                if ownsWaitableChild { kill(-pid, SIGKILL) }
                if !reap(until: ProcessInfo.processInfo.systemUptime + limits.killGrace) { gate.block() }
            }
        }
        func drain(_ fd: Int32, into data: inout Data, maximum: Int, eof: inout Bool) throws {
            var bytes = [UInt8](repeating: 0, count: 8192)
            // Bound each turn so a noisy stdout cannot starve stderr/deadline.
            for _ in 0..<8 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    guard count <= maximum - data.count else { throw Failure.outputLimit }
                    data.append(contentsOf: bytes.prefix(count))
                } else if count == 0 { eof = true; return }
                else if errno == EINTR { continue }
                else if errno == EAGAIN { return }
                else { throw Failure.exit }
            }
        }
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timeout }
            try drain(out[0], into: &output, maximum: limits.stdoutBytes, eof: &outEOF)
            try drain(err[0], into: &errors, maximum: limits.stderrBytes, eof: &errEOF)
            exited = try childExited()
            if exited && outEOF && errEOF { break }
            usleep(5_000)
        }
        // A child that closed its pipes may still leave descendants. Stop that
        // group before reaping its leader, even on the normal completion path.
        kill(-pid, SIGKILL)
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { throw Failure.cleanup }
        guard reap(until: ProcessInfo.processInfo.systemUptime + limits.killGrace) else {
            gate.block(); throw Failure.cleanup
        }
        reaped = true
        guard info.si_code == CLD_EXITED, info.si_status == 0 else { throw Failure.exit }
        return Output(stdout: output, stderr: errors)
    }
}
