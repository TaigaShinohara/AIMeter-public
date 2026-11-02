import Foundation
import Network
import Security

/// A fresh, non-retrying TCP connection. HTTP credentials do not enter Network
/// until the already-established connection has passed the kernel peer check.
enum LocalQuotaTransport {
    static func post(
        port: UInt16, useTLS: Bool, timeout: TimeInterval = 3,
        validatePeer: @escaping @Sendable (LocalSocketIdentity.IPv4LoopbackConnection) throws -> Void,
        request: @escaping @Sendable () throws -> Data
    ) async throws -> Data {
        guard port > 0, timeout > 0, timeout.isFinite else { throw AntigravityQuotaClient.Failure.connection }
        let operation = Request(port: port, useTLS: useTLS, timeout: timeout,
                                validatePeer: validatePeer, request: request)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }

    private final class Request: @unchecked Sendable {
        let queue = DispatchQueue(label: "AIMeter.verified-loopback")
        let connection: NWConnection
        let port: UInt16
        let timeout: TimeInterval
        let validatePeer: @Sendable (LocalSocketIdentity.IPv4LoopbackConnection) throws -> Void
        let request: @Sendable () throws -> Data
        var continuation: CheckedContinuation<Data, Error>?
        var timer: DispatchWorkItem?
        var cancelled = false
        var finished = false
        var checkedTuple: LocalSocketIdentity.IPv4LoopbackConnection?
        var parser = LocalHTTPResponseParser()

        init(port: UInt16, useTLS: Bool, timeout: TimeInterval,
             validatePeer: @escaping @Sendable (LocalSocketIdentity.IPv4LoopbackConnection) throws -> Void,
             request: @escaping @Sendable () throws -> Data) {
            self.port = port
            self.timeout = timeout
            self.validatePeer = validatePeer
            self.request = request
            let tls = useTLS ? NWProtocolTLS.Options() : nil
            if let tls {
                // The TLS handshake carries no HTTP credential. The accepted
                // socket's process is authenticated separately before send.
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                    complete(true)
                }, queue)
                sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            }
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            parameters.requiredInterfaceType = .loopback
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            parameters.preferNoProxies = true
            parameters.multipathServiceType = .disabled
            connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        }

        func start(_ continuation: CheckedContinuation<Data, Error>) {
            queue.async {
                self.continuation = continuation
                if self.cancelled { self.finish(.failure(CancellationError())); return }
                let timer = DispatchWorkItem { [weak operation = self] in
                    operation?.finish(.failure(AntigravityQuotaClient.Failure.limit))
                }
                self.timer = timer
                self.queue.asyncAfter(deadline: .now() + self.timeout, execute: timer)
                self.connection.stateUpdateHandler = { [weak operation = self] state in
                    guard let operation, !operation.finished else { return }
                    switch state {
                    case .ready: operation.authenticateConnectedPeer()
                    case .waiting, .failed: operation.finish(.failure(AntigravityQuotaClient.Failure.connection))
                    case .cancelled:
                        operation.finish(.failure(operation.cancelled ? CancellationError() : AntigravityQuotaClient.Failure.connection))
                    default: break
                    }
                }
                self.connection.pathUpdateHandler = { [weak operation = self] path in
                    guard let operation, !operation.finished, let tuple = operation.checkedTuple else { return }
                    guard operation.tuple(path) == tuple else {
                        operation.finish(.failure(AntigravityQuotaClient.Failure.untrustedProcess)); return
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }

        func cancel() {
            queue.async {
                self.cancelled = true
                if self.continuation != nil { self.finish(.failure(CancellationError())) }
            }
        }

        private func tuple(_ path: NWPath?) -> LocalSocketIdentity.IPv4LoopbackConnection? {
            guard let path, path.usesInterfaceType(.loopback),
                  case let .hostPort(localHost, localPort) = path.localEndpoint,
                  case let .hostPort(remoteHost, remotePort) = path.remoteEndpoint,
                  case let .ipv4(localAddress) = localHost,
                  case let .ipv4(remoteAddress) = remoteHost,
                  localAddress == .loopback, remoteAddress == .loopback,
                  localPort.rawValue > 0, remotePort.rawValue == port else { return nil }
            return .init(clientPort: localPort.rawValue, serverPort: remotePort.rawValue)
        }

        private func authenticateConnectedPeer() {
            guard checkedTuple == nil, let tuple = tuple(connection.currentPath) else {
                finish(.failure(AntigravityQuotaClient.Failure.untrustedProcess)); return
            }
            checkedTuple = tuple
            // Signature/FD inspection can block; the serial transport queue must
            // remain available to cancel/timeout without authorizing a late send.
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try self.validatePeer(tuple) }
                self.queue.async {
                    guard !self.finished, !self.cancelled else { return }
                    do {
                        try result.get()
                        guard self.tuple(self.connection.currentPath) == tuple,
                              case .ready = self.connection.state else {
                            throw AntigravityQuotaClient.Failure.untrustedProcess
                        }
                        // Build the header only after validation; never use
                        // .idempotent, restart, or a different connection here.
                        let data = try self.request()
                        guard data.count <= 16_384 else { throw AntigravityQuotaClient.Failure.limit }
                        self.connection.send(content: data, completion: .contentProcessed { [weak operation = self] error in
                            guard let operation, !operation.finished else { return }
                            if error != nil { operation.finish(.failure(AntigravityQuotaClient.Failure.connection)) }
                            else { operation.receive() }
                        })
                    } catch { self.finish(.failure(error)) }
                }
            }
        }

        private func receive() {
            guard !finished else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.finished else { return }
                do {
                    if let result = try self.parser.append(data ?? Data(), eof: complete) {
                        self.finish(.success(result)); return
                    }
                    if error != nil { throw AntigravityQuotaClient.Failure.connection }
                    self.receive()
                } catch { self.finish(.failure(error)) }
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            timer?.cancel()
            timer = nil
            connection.stateUpdateHandler = nil
            connection.pathUpdateHandler = nil
            connection.cancel()
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }
}

/// Bounded HTTP/1 response framing for the one-shot local connection. No
/// redirects, compression, ambiguous lengths, or connection reuse are allowed.
struct LocalHTTPResponseParser {
    private enum Phase {
        case headers, fixed(Int), untilEOF, chunkSize, chunk(Int), chunkEnd, trailers, complete
    }
    private var phase = Phase.headers
    private var pending = Data()
    private var body = Data()
    private var wireBytes = 0
    private let maximumBody = 1_048_576
    private let maximumHeaders = 16_384
    private let maximumWire = 1_048_576 + 131_072

    mutating func append(_ data: Data, eof: Bool = false) throws -> Data? {
        guard data.count <= maximumWire - wireBytes else { throw AntigravityQuotaClient.Failure.limit }
        wireBytes += data.count
        pending.append(data)
        while true {
            switch phase {
            case .headers:
                guard let end = pending.range(of: Data([13, 10, 13, 10])) else {
                    guard pending.count <= maximumHeaders else { throw AntigravityQuotaClient.Failure.limit }
                    if eof { throw AntigravityQuotaClient.Failure.invalidResponse }
                    return nil
                }
                let length = pending.distance(from: pending.startIndex, to: end.upperBound)
                guard length <= maximumHeaders else { throw AntigravityQuotaClient.Failure.limit }
                let header = pending.prefix(length - 4)
                pending.removeFirst(length)
                try parseHeaders(Data(header))
            case let .fixed(remaining):
                if remaining == 0 { phase = .complete; continue }
                let count = min(remaining, pending.count)
                try consume(count)
                phase = .fixed(remaining - count)
                if count < remaining {
                    if eof { throw AntigravityQuotaClient.Failure.invalidResponse }
                    return nil
                }
            case .untilEOF:
                try consume(pending.count)
                if !eof { return nil }
                phase = .complete
            case .chunkSize:
                guard let range = pending.range(of: Data([13, 10])) else {
                    guard pending.count <= 1024 else { throw AntigravityQuotaClient.Failure.limit }
                    if eof { throw AntigravityQuotaClient.Failure.invalidResponse }
                    return nil
                }
                let length = pending.distance(from: pending.startIndex, to: range.lowerBound)
                guard length <= 1024,
                      let line = String(data: pending.prefix(length), encoding: .ascii),
                      let first = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                      !first.isEmpty, first.count <= 8,
                      first.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let size = Int(first, radix: 16) else { throw AntigravityQuotaClient.Failure.invalidResponse }
                guard size <= maximumBody - body.count else { throw AntigravityQuotaClient.Failure.limit }
                pending.removeFirst(length + 2)
                phase = size == 0 ? .trailers : .chunk(size)
            case let .chunk(remaining):
                let count = min(remaining, pending.count)
                try consume(count)
                phase = count == remaining ? .chunkEnd : .chunk(remaining - count)
                if count < remaining {
                    if eof { throw AntigravityQuotaClient.Failure.invalidResponse }
                    return nil
                }
            case .chunkEnd:
                guard pending.count >= 2 else {
                    if eof { throw AntigravityQuotaClient.Failure.invalidResponse }
                    return nil
                }
                guard pending.prefix(2) == Data([13, 10]) else { throw AntigravityQuotaClient.Failure.invalidResponse }
                pending.removeFirst(2)
                phase = .chunkSize
            case .trailers:
                if pending.starts(with: [13, 10]) {
                    pending.removeFirst(2); phase = .complete; continue
                }
                guard let end = pending.range(of: Data([13, 10, 13, 10])) else {
                    guard pending.count <= maximumHeaders else { throw AntigravityQuotaClient.Failure.limit }
                    if eof { throw AntigravityQuotaClient.Failure.invalidResponse }
                    return nil
                }
                let length = pending.distance(from: pending.startIndex, to: end.upperBound)
                guard length <= maximumHeaders else { throw AntigravityQuotaClient.Failure.limit }
                let trailers = try fields(Data(pending.prefix(length - 4)))
                guard trailers["content-length"] == nil, trailers["transfer-encoding"] == nil else {
                    throw AntigravityQuotaClient.Failure.invalidResponse
                }
                pending.removeFirst(length)
                phase = .complete
            case .complete:
                guard pending.isEmpty else { throw AntigravityQuotaClient.Failure.invalidResponse }
                return body
            }
        }
    }

    private mutating func consume(_ count: Int) throws {
        guard count <= maximumBody - body.count else { throw AntigravityQuotaClient.Failure.limit }
        body.append(pending.prefix(count))
        pending.removeFirst(count)
    }

    private func fields(_ data: Data) throws -> [String: String] {
        guard data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: data, encoding: .ascii) else { throw AntigravityQuotaClient.Failure.invalidResponse }
        var result: [String: String] = [:]
        if text.isEmpty { return result }
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { throw AntigravityQuotaClient.Failure.invalidResponse }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }), result[key] == nil else { throw AntigravityQuotaClient.Failure.invalidResponse }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { throw AntigravityQuotaClient.Failure.invalidResponse }
            result[key] = value
        }
        return result
    }

    private mutating func parseHeaders(_ data: Data) throws {
        guard let lineEnd = data.range(of: Data([13, 10])) else {
            // A status line with no fields is still a valid close-delimited response.
            try status(data)
            phase = .untilEOF
            return
        }
        try status(Data(data[..<lineEnd.lowerBound]))
        let headers = try fields(Data(data[lineEnd.upperBound...]))
        guard headers["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true else {
            throw AntigravityQuotaClient.Failure.invalidResponse
        }
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else {
                throw AntigravityQuotaClient.Failure.invalidResponse
            }
            phase = .chunkSize
        } else if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(raw) else {
                throw AntigravityQuotaClient.Failure.invalidResponse
            }
            guard length <= maximumBody else { throw AntigravityQuotaClient.Failure.limit }
            phase = .fixed(length)
        } else { phase = .untilEOF }
    }

    private func status(_ data: Data) throws {
        guard let text = String(data: data, encoding: .ascii), !text.contains("\r"), !text.contains("\n") else {
            throw AntigravityQuotaClient.Failure.invalidResponse
        }
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(parts[0]),
              parts[1].utf8.count == 3, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let code = Int(parts[1]), (200...299).contains(code) else { throw AntigravityQuotaClient.Failure.unavailable }
    }
}
