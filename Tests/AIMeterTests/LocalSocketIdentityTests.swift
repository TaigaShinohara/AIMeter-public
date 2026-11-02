import Darwin
import XCTest
@testable import AIMeter

final class LocalSocketIdentityTests: XCTestCase {
    private let connection = LocalSocketIdentity.IPv4LoopbackConnection(clientPort: 54_321, serverPort: 12_345)

    private func acceptedSocket() -> socket_fdinfo {
        var info = socket_fdinfo()
        info.psi.soi_family = AF_INET
        info.psi.soi_type = SOCK_STREAM
        info.psi.soi_protocol = IPPROTO_TCP
        info.psi.soi_kind = Int32(SOCKINFO_TCP)
        info.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_ESTABLISHED
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = inet_addr("127.0.0.1")
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4.s_addr = inet_addr("127.0.0.1")
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(connection.serverPort.bigEndian)
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport = Int32(connection.clientPort.bigEndian)
        return info
    }

    func testOnlyEstablishedInverseIPv4LoopbackTupleMatches() {
        XCTAssertTrue(LocalSocketIdentity.ownsIPv4LoopbackSocket(acceptedSocket(), connection: connection))
        let reversed = LocalSocketIdentity.IPv4LoopbackConnection(clientPort: connection.serverPort,
                                                                serverPort: connection.clientPort)
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(acceptedSocket(), connection: reversed))
    }

    func testFamilyProtocolTypeKindAndEstablishedStateAreRequired() {
        var info = acceptedSocket()
        info.psi.soi_family = AF_INET6
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
        info = acceptedSocket()
        info.psi.soi_type = SOCK_DGRAM
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
        info = acceptedSocket()
        info.psi.soi_protocol = IPPROTO_UDP
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
        info = acceptedSocket()
        info.psi.soi_kind = Int32(SOCKINFO_IN)
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
        for state in [TSI_S_LISTEN, TSI_S_SYN_SENT, TSI_S_SYN_RECEIVED, TSI_S__CLOSE_WAIT, TSI_S_TIME_WAIT] {
            info = acceptedSocket()
            info.psi.soi_proto.pri_tcp.tcpsi_state = state
            XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
        }
        info = acceptedSocket()
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV6)
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
    }

    func testBothAddressesMustBeTheExactRequestedLoopbackAddress() {
        for address in ["0.0.0.0", "127.0.0.2", "192.0.2.1"] {
            var info = acceptedSocket()
            info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = inet_addr(address)
            XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
            info = acceptedSocket()
            info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4.s_addr = inet_addr(address)
            XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
        }
    }

    func testBothPortsAndNonzeroClientPortAreRequired() {
        var info = acceptedSocket()
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(12_346).bigEndian)
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
        info = acceptedSocket()
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport = Int32(UInt16(54_322).bigEndian)
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(info, connection: connection))
        let zeroClient = LocalSocketIdentity.IPv4LoopbackConnection(clientPort: 0, serverPort: connection.serverPort)
        let zeroServer = LocalSocketIdentity.IPv4LoopbackConnection(clientPort: connection.clientPort, serverPort: 0)
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(acceptedSocket(), connection: zeroClient))
        XCTAssertFalse(LocalSocketIdentity.ownsIPv4LoopbackSocket(acceptedSocket(), connection: zeroServer))
    }

    func testCurrentProcessIdentityUsesKernelOwnerAndStartTime() throws {
        let identity = try LocalSocketIdentity.processIdentity(pid: getpid())
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertEqual(identity.uid, getuid())
        XCTAssertGreaterThan(identity.startSeconds, 0)
        XCTAssertLessThan(identity.startMicroseconds, 1_000_000)
        XCTAssertEqual(try LocalSocketIdentity.processIdentity(pid: getpid()), identity)
    }

    func testDescriptorReadsRejectErrorsPartialRecordsAndTheTruncationSentinel() throws {
        let size = Int32(MemoryLayout<proc_fdinfo>.stride)
        XCTAssertEqual(try LocalSocketIdentity.descriptorCount(forByteCount: size), 1)
        XCTAssertEqual(try LocalSocketIdentity.descriptorCount(forByteCount: 4_096 * size), 4_096)
        for count in [Int32(-1), 0, size - 1, size + 1] {
            XCTAssertThrowsError(try LocalSocketIdentity.descriptorCount(forByteCount: count)) {
                XCTAssertEqual($0 as? AntigravityQuotaClient.Failure, .untrustedProcess)
            }
        }
        for count in [4_097 * size, 4_098 * size] {
            XCTAssertThrowsError(try LocalSocketIdentity.descriptorCount(forByteCount: count)) {
                XCTAssertEqual($0 as? AntigravityQuotaClient.Failure, .limit)
            }
        }
    }

    func testInvalidPidAndChangedProcessIncarnationFailClosed() throws {
        for pid in [Int32(0), Int32(-1)] {
            XCTAssertThrowsError(try LocalSocketIdentity.processIdentity(pid: pid)) {
                XCTAssertEqual($0 as? AntigravityQuotaClient.Failure, .untrustedProcess)
            }
        }
        let current = try LocalSocketIdentity.processIdentity(pid: getpid())
        let stale = LocalSocketIdentity.ProcessIdentity(pid: current.pid, uid: current.uid,
                                                       startSeconds: current.startSeconds + 1,
                                                       startMicroseconds: current.startMicroseconds)
        XCTAssertThrowsError(try LocalSocketIdentity.ownsConnection(connection, by: stale)) {
            XCTAssertEqual($0 as? AntigravityQuotaClient.Failure, .untrustedProcess)
        }
        let otherOwner = LocalSocketIdentity.ProcessIdentity(pid: current.pid, uid: current.uid ^ 1,
                                                            startSeconds: current.startSeconds,
                                                            startMicroseconds: current.startMicroseconds)
        XCTAssertThrowsError(try LocalSocketIdentity.ownsConnection(connection, by: otherOwner)) {
            XCTAssertEqual($0 as? AntigravityQuotaClient.Failure, .untrustedProcess)
        }
    }

    func testKernelOwnershipRequiresTheAcceptedSocketAndExactClientPort() throws {
        let listener = try makeSocket()
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listener, 1) == 0 else { throw socketError() }
        let serverPort = try localPort(of: listener)
        address.sin_port = serverPort.bigEndian

        let client = try makeSocket()
        defer { Darwin.close(client) }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw socketError() }
        let tuple = LocalSocketIdentity.IPv4LoopbackConnection(clientPort: try localPort(of: client),
                                                             serverPort: serverPort)
        let identity = try LocalSocketIdentity.processIdentity(pid: getpid())
        // The listening socket and the client-side socket cannot establish
        // ownership of the server's accepted endpoint.
        XCTAssertFalse(try LocalSocketIdentity.ownsConnection(tuple, by: identity))
        var accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else { throw socketError() }
        defer { if accepted >= 0 { Darwin.close(accepted) } }
        XCTAssertTrue(try LocalSocketIdentity.ownsConnection(tuple, by: identity))
        let otherClientPort = tuple.clientPort == UInt16.max ? tuple.clientPort - 1 : tuple.clientPort + 1
        let wrongTuple = LocalSocketIdentity.IPv4LoopbackConnection(clientPort: otherClientPort,
                                                                  serverPort: serverPort)
        XCTAssertFalse(try LocalSocketIdentity.ownsConnection(wrongTuple, by: identity))
        Darwin.close(accepted)
        accepted = -1
        XCTAssertFalse(try LocalSocketIdentity.ownsConnection(tuple, by: identity))
    }

    private func makeSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw socketError() }
        return descriptor
    }

    private func localPort(of descriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0, length == socklen_t(MemoryLayout<sockaddr_in>.size),
              address.sin_family == sa_family_t(AF_INET), address.sin_port != 0 else {
            throw socketError()
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private func socketError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
