import Darwin
import Foundation

/// Confirms the process at the other end of an already established local TCP
/// connection. A listening port alone cannot authenticate a later connection.
enum LocalSocketIdentity {
    struct ProcessIdentity: Equatable, Sendable {
        let pid: Int32
        let uid: uid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct IPv4LoopbackConnection: Equatable, Sendable {
        let clientPort: UInt16
        let serverPort: UInt16
    }

    private static let maximumDescriptors = 4_096
    private static let maximumInspectionDuration: TimeInterval = 1

    static func processIdentity(pid: Int32) throws -> ProcessIdentity {
        try Task.checkCancellation()
        guard pid > 0 else { throw AntigravityQuotaClient.Failure.untrustedProcess }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard count == Int32(size), info.pbi_pid == UInt32(pid),
              info.pbi_uid == getuid(), info.pbi_start_tvusec < 1_000_000 else {
            throw AntigravityQuotaClient.Failure.untrustedProcess
        }
        return ProcessIdentity(pid: pid, uid: info.pbi_uid,
                               startSeconds: info.pbi_start_tvsec,
                               startMicroseconds: info.pbi_start_tvusec)
    }

    static func ownsConnection(_ connection: IPv4LoopbackConnection,
                               by identity: ProcessIdentity) throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        try checkInspectionBudget(started: started)
        guard connection.clientPort != 0, connection.serverPort != 0 else { return false }
        guard try processIdentity(pid: identity.pid) == identity else {
            throw AntigravityQuotaClient.Failure.untrustedProcess
        }
        let descriptors = try descriptorSnapshot(pid: identity.pid)
        var matchedDescriptor: Int32?
        for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            try checkInspectionBudget(started: started)
            var info = socket_fdinfo()
            let size = MemoryLayout<socket_fdinfo>.size
            let count = proc_pidfdinfo(identity.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                                      &info, Int32(size))
            // Unrelated descriptors may close or be reused while enumerating a
            // busy process. An unreadable record contributes no ownership proof.
            guard count == Int32(size) else { continue }
            if ownsIPv4LoopbackSocket(info, connection: connection) {
                matchedDescriptor = descriptor.proc_fd
                break
            }
        }
        try checkInspectionBudget(started: started)
        guard try processIdentity(pid: identity.pid) == identity else {
            throw AntigravityQuotaClient.Failure.untrustedProcess
        }
        guard let matchedDescriptor else { return false }
        // Recheck the positive record itself instead of requiring every
        // unrelated descriptor to stay unchanged. The caller keeps this same
        // established TCP connection alive and must never retry it on a new one.
        var confirmed = socket_fdinfo()
        let size = MemoryLayout<socket_fdinfo>.size
        let count = proc_pidfdinfo(identity.pid, matchedDescriptor, PROC_PIDFDSOCKETINFO,
                                  &confirmed, Int32(size))
        guard count == Int32(size), ownsIPv4LoopbackSocket(confirmed, connection: connection) else {
            return false
        }
        guard try processIdentity(pid: identity.pid) == identity else {
            throw AntigravityQuotaClient.Failure.untrustedProcess
        }
        try checkInspectionBudget(started: started)
        return true
    }

    /// Pure matching is kept separate so boundary cases can use synthetic kernel
    /// records without probing the user's applications or credentials.
    static func ownsIPv4LoopbackSocket(_ info: socket_fdinfo,
                                      connection: IPv4LoopbackConnection) -> Bool {
        guard connection.clientPort != 0, connection.serverPort != 0,
              info.psi.soi_family == AF_INET,
              info.psi.soi_type == SOCK_STREAM,
              info.psi.soi_protocol == IPPROTO_TCP,
              info.psi.soi_kind == SOCKINFO_TCP else { return false }
        let tcp = info.psi.soi_proto.pri_tcp
        let addresses = tcp.tcpsi_ini
        let loopback = in_addr_t(0x7f00_0001).bigEndian
        return tcp.tcpsi_state == TSI_S_ESTABLISHED
            && addresses.insi_vflag & UInt8(INI_IPV4) != 0
            && addresses.insi_laddr.ina_46.i46a_addr4.s_addr == loopback
            && addresses.insi_faddr.ina_46.i46a_addr4.s_addr == loopback
            && UInt16(bigEndian: UInt16(truncatingIfNeeded: addresses.insi_lport)) == connection.serverPort
            && UInt16(bigEndian: UInt16(truncatingIfNeeded: addresses.insi_fport)) == connection.clientPort
    }

    private static func descriptorSnapshot(pid: Int32) throws -> [proc_fdinfo] {
        try Task.checkCancellation()
        // One extra record distinguishes an exactly full allowed list from a
        // potentially truncated result. Never accept a filled buffer.
        let capacity = maximumDescriptors + 1
        let recordSize = MemoryLayout<proc_fdinfo>.stride
        let byteCapacity = capacity * recordSize
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let count = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32(byteCapacity))
        }
        let recordCount = try descriptorCount(forByteCount: count)
        descriptors.removeSubrange(recordCount..<descriptors.count)
        guard descriptors.allSatisfy({ $0.proc_fd >= 0 }) else {
            throw AntigravityQuotaClient.Failure.untrustedProcess
        }
        descriptors.sort { $0.proc_fd < $1.proc_fd }
        for index in descriptors.indices.dropFirst() {
            guard descriptors[index - 1].proc_fd != descriptors[index].proc_fd else {
                throw AntigravityQuotaClient.Failure.untrustedProcess
            }
        }
        return descriptors
    }

    static func descriptorCount(forByteCount count: Int32) throws -> Int {
        let recordSize = MemoryLayout<proc_fdinfo>.stride
        // A live server needs at least its accepted socket. A zero-length result
        // is also indistinguishable from some libproc errors.
        guard count > 0, Int(count) % recordSize == 0 else {
            throw AntigravityQuotaClient.Failure.untrustedProcess
        }
        let records = Int(count) / recordSize
        guard records <= maximumDescriptors else { throw AntigravityQuotaClient.Failure.limit }
        return records
    }

    private static func checkInspectionBudget(started: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime - started < maximumInspectionDuration else {
            throw AntigravityQuotaClient.Failure.limit
        }
    }
}
