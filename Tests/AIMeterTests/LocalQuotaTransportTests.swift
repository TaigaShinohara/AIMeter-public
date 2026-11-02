import XCTest
import Network
@testable import AIMeter

final class LocalQuotaTransportTests: XCTestCase {
    func testHTTPFramingAcceptsFixedChunkedAndCloseDelimitedBodies() throws {
        for message in [
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n1\r\n}\r\n0\r\n\r\n",
            "HTTP/1.0 200 OK\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;test=1\r\n{}\r\n0\r\nX-Test: yes\r\n\r\n"
        ] {
            var parser = LocalHTTPResponseParser()
            var result: Data?
            let bytes = Array(message.utf8)
            for (index, byte) in bytes.enumerated() {
                result = try parser.append(Data([byte]), eof: index == bytes.count - 1) ?? result
            }
            XCTAssertEqual(result, Data("{}".utf8))
        }
    }

    func testHTTPFramingRejectsRedirectCompressionAmbiguityAndTruncation() {
        for message in [
            "HTTP/1.1 302 Moved\r\nLocation: https://example.invalid\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}x\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 1\r\n\r\n",
            "HTTP/1.1 200 OK\r\n Folded: yes\r\n\r\n{}"
        ] {
            var parser = LocalHTTPResponseParser()
            XCTAssertThrowsError(try parser.append(Data(message.utf8), eof: true), message)
        }
    }

    func testHTTPResponseHasHeaderBodyAndWireBudgets() {
        for message in [
            "HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 16_384) + "\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100001\r\n",
            "HTTP/1.0 200 OK\r\n\r\n" + String(repeating: "a", count: 1_048_577)
        ] {
            var parser = LocalHTTPResponseParser()
            XCTAssertThrowsError(try parser.append(Data(message.utf8), eof: true))
        }
    }

    func testConnectedKernelPeerIsVerifiedBeforeTheRequestIsBuilt() async throws {
        let server = try await SyntheticLocalQuotaServer.start()
        defer { server.cancel() }
        let identity = try LocalSocketIdentity.processIdentity(pid: getpid())
        let response = try await LocalQuotaTransport.post(port: server.port, useTLS: false, validatePeer: { tuple in
            guard try LocalSocketIdentity.ownsConnection(tuple, by: identity) else {
                throw AntigravityQuotaClient.Failure.untrustedProcess
            }
        }, request: { Data("POST /synthetic HTTP/1.1\r\nContent-Length: 0\r\nX-Synthetic: safe\r\n\r\n".utf8) })
        XCTAssertEqual(response, Data("{}".utf8))
        XCTAssertTrue(server.receivedString.contains("X-Synthetic: safe"))
    }

    func testRejectedPeerReceivesZeroCredentialBytes() async throws {
        let server = try await SyntheticLocalQuotaServer.start()
        defer { server.cancel() }
        do {
            _ = try await LocalQuotaTransport.post(port: server.port, useTLS: false, validatePeer: { _ in
                throw AntigravityQuotaClient.Failure.untrustedProcess
            }, request: { XCTFail("A rejected peer must never build a credential header"); return Data("SYNTHETIC-SECRET".utf8) })
            XCTFail("Expected peer rejection")
        } catch { XCTAssertEqual(error as? AntigravityQuotaClient.Failure, .untrustedProcess) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(server.receivedString, "")
    }

    func testIPv6OwnerCannotAuthorizeOtherProcessIPv4Listener() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Synthetic separate-process socket fixture needs Python 3")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
        import socket, signal
        signal.alarm(5)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.bind(('127.0.0.1', 0))
            server.listen(1)
            print(server.getsockname()[1], flush=True)
            connection, _ = server.accept()
            with connection:
                connection.settimeout(3)
                received = connection.recv(16384)
            print(len(received), flush=True)
        """]
        child.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        XCTAssertNotEqual(fcntl(descriptor, F_SETFL, O_NONBLOCK), -1)
        try child.run()
        defer {
            if child.isRunning { child.terminate(); kill(child.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
        }
        var output = Data()
        func line() throws -> String {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let end = output.firstIndex(of: 10) {
                    let text = String(decoding: output[..<end], as: UTF8.self)
                    output.removeSubrange(...end)
                    return text
                }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 { output.append(contentsOf: bytes.prefix(count)) }
                else if count == 0 { break }
                else if errno != EAGAIN && errno != EINTR { break }
                usleep(5_000)
            }
            throw AntigravityQuotaClient.Failure.connection
        }
        let port = try XCTUnwrap(UInt16(try line()))
        // The expected process owns only IPv6 at the same numeric port. The
        // IPv4 listener belongs to a different process, even under the same UID.
        let ipv6 = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(ipv6, 0)
        defer { close(ipv6) }
        var v6only: Int32 = 1
        XCTAssertEqual(setsockopt(ipv6, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size)), 0)
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &address.sin6_addr), 1)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(ipv6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(ipv6, 1), 0)
        let identity = try LocalSocketIdentity.processIdentity(pid: getpid())
        XCTAssertTrue(AntigravityQuotaClient.ownedListeningPorts(in: "p\(getpid())\nf1\ntIPv6\nn[::1]:\(port)", pid: getpid()).isEmpty)
        do {
            _ = try await LocalQuotaTransport.post(port: port, useTLS: false, validatePeer: { tuple in
                guard try LocalSocketIdentity.ownsConnection(tuple, by: identity) else {
                    throw AntigravityQuotaClient.Failure.untrustedProcess
                }
            }, request: { XCTFail("The other process must receive no credentials"); return Data("SYNTHETIC-SECRET".utf8) })
            XCTFail("The unrelated IPv4 listener was accepted")
        } catch { XCTAssertEqual(error as? AntigravityQuotaClient.Failure, .untrustedProcess) }
        XCTAssertEqual(try line(), "0")
    }

    func testLateValidationCannotSendAfterTimeoutOrCancellation() async throws {
        for cancel in [false, true] {
            let server = try await SyntheticLocalQuotaServer.start()
            defer { server.cancel() }
            let task = Task {
                try await LocalQuotaTransport.post(port: server.port, useTLS: false, timeout: 0.08, validatePeer: { _ in
                    Thread.sleep(forTimeInterval: 0.2)
                }, request: { XCTFail("An expired operation must not build credentials"); return Data("SYNTHETIC-SECRET".utf8) })
            }
            if cancel { try await Task.sleep(nanoseconds: 20_000_000); task.cancel() }
            do { _ = try await task.value; XCTFail("Expected termination") } catch { }
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(server.receivedString, "")
        }
    }

    func testCompletedAndRejectedRequestsReleaseCapturedCredentialContext() async throws {
        for reject in [false, true] {
            let server = try await SyntheticLocalQuotaServer.start()
            defer { server.cancel() }
            let reference = await capturedContextRequest(port: server.port, reject: reject)
            // The normal resource timeout is three seconds. Context must be
            // released after completion, rather than retained by its timer.
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertNil(reference.value)
        }
    }

    private func capturedContextRequest(port: UInt16, reject: Bool) async -> WeakCredentialContext {
        let context = SyntheticCredentialContext()
        let reference = WeakCredentialContext(context)
        _ = try? await LocalQuotaTransport.post(port: port, useTLS: false, validatePeer: { _ in
            if reject { throw AntigravityQuotaClient.Failure.untrustedProcess }
        }, request: { [context] in
            return Data("POST /synthetic HTTP/1.1\r\nContent-Length: 0\r\nX-Synthetic: \(context.marker)\r\n\r\n".utf8)
        })
        return reference
    }
}

private final class SyntheticCredentialContext: @unchecked Sendable { let marker = UUID().uuidString }
private final class WeakCredentialContext {
    weak var value: SyntheticCredentialContext?
    init(_ value: SyntheticCredentialContext) { self.value = value }
}

private final class SyntheticLocalQuotaServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "AIMeter.synthetic-quota-server")
    let lock = NSLock()
    var received = Data()
    var connections: [NWConnection] = []
    var port: UInt16 { listener.port!.rawValue }
    var receivedString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: received, as: UTF8.self) }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> SyntheticLocalQuotaServer {
        let server = try SyntheticLocalQuotaServer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: server.listener.stateUpdateHandler = nil; continuation.resume()
                case let .failed(error): server.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.newConnectionHandler = { connection in
                server.connections.append(connection)
                connection.start(queue: server.queue)
                server.receive(connection)
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            if let data, !data.isEmpty {
                self.lock.lock(); self.received.append(data); let ready = self.received.range(of: Data([13, 10, 13, 10])) != nil; self.lock.unlock()
                if ready {
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8), completion: .contentProcessed { _ in })
                    return
                }
            }
            if !complete && error == nil { self.receive(connection) }
        }
    }

    func cancel() {
        queue.async { self.listener.cancel(); self.connections.forEach { $0.cancel() } }
    }
}
