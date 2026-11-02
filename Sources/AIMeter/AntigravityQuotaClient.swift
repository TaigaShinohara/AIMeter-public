import Foundation
import Security
import Darwin
import AIMeterCore

/// Reads the quota already available to the signed-in desktop app. Credentials
/// stay in memory and are sent only to listeners owned by its verified process.
enum AntigravityQuotaClient {
    enum Failure: LocalizedError, Equatable {
        case notRunning, untrustedProcess, missingToken, unavailable, connection, invalidResponse, limit

        var errorDescription: String? {
            switch self {
            case .notRunning: return "Antigravityを起動してから更新してください"
            case .untrustedProcess: return "Antigravityの実行元を確認できませんでした"
            case .missingToken: return "Antigravityのローカル接続情報を確認できませんでした"
            case .unavailable: return "Antigravityから公式残量を取得できませんでした"
            case .connection: return "Antigravityとのローカル接続に失敗しました"
            case .invalidResponse: return "Antigravityの残量データを読み取れませんでした"
            case .limit: return "Antigravityの残量取得が処理上限に達しました"
            }
        }
    }

    private static let executablePath = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
    private static let bundlePath = "/Applications/Antigravity.app"
    private static let servicePath = "/exa.language_server_pb.LanguageServerService/"
    private static let maximumBytes = 1_048_576

    private struct Server: Sendable {
        let identity: LocalSocketIdentity.ProcessIdentity
        var pid: Int32 { identity.pid }
        let token: String
        let extensionToken: String?
        let extensionPort: Int?
        let ports: [Int]
    }

    private struct Endpoint: Sendable {
        let server: Server
        let port: Int
        let scheme: String
        var token: String { scheme == "http" ? server.extensionToken ?? server.token : server.token }
    }

    static func fetch() async throws -> AntigravityQuotaSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        let discovery = Task.detached(priority: .utility) { try discoverServers() }
        let servers = try await withTaskCancellationHandler {
            try await discovery.value
        } onCancel: { discovery.cancel() }
        var endpoints: [Endpoint] = []
        for server in servers {
            endpoints += server.ports.map { Endpoint(server: server, port: $0, scheme: "https") }
            if let port = server.extensionPort, server.ports.contains(port) {
                endpoints.append(Endpoint(server: server, port: port, scheme: "http"))
            }
        }
        var lastFailure = Failure.unavailable
        // A legacy response from one listener must not mask a richer summary
        // provided by another verified Antigravity instance.
        for method in ["RetrieveUserQuotaSummary", "GetUserStatus"] {
            for endpoint in endpoints {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime - started < 12 else { throw Failure.limit }
                do {
                    let data = try await request(method: method, endpoint: endpoint)
                    let fetchedAt = Date()
                    do {
                        if method == "RetrieveUserQuotaSummary" {
                            return try AntigravityQuotaParser.parseSummary(data: data, fetchedAt: fetchedAt)
                        }
                        return try AntigravityQuotaParser.parseUserStatus(data: data, fetchedAt: fetchedAt)
                    } catch let failure as AntigravityQuotaParser.Failure {
                        lastFailure = failure == .unavailable ? .unavailable : .invalidResponse
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as URLError where error.code == .cancelled {
                    if Task.isCancelled { throw CancellationError() }
                    lastFailure = .connection
                } catch let failure as Failure { lastFailure = failure }
                catch { lastFailure = .connection }
            }
        }
        throw lastFailure
    }

    private static func request(method: String, endpoint: Endpoint) async throws -> Data {
        guard ["RetrieveUserQuotaSummary", "GetUserStatus"].contains(method),
              let port = UInt16(exactly: endpoint.port), port > 0 else { throw Failure.connection }
        let server = endpoint.server
        return try await LocalQuotaTransport.post(port: port, useTLS: endpoint.scheme == "https", validatePeer: { tuple in
            // Authenticate the process and its accepted connection, not just a
            // same-number listening port observed before connect.
            _ = try validateProcess(server.pid, expected: server.identity)
            // Plain HTTP can become ready just before the server accepts. Wait
            // briefly without sending; never fall back to listener-only proof.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            var accepted = false
            repeat {
                if try LocalSocketIdentity.ownsConnection(tuple, by: server.identity) {
                    accepted = true; break
                }
                usleep(10_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard accepted else { throw Failure.untrustedProcess }
            _ = try validateProcess(server.pid, expected: server.identity)
        }, request: {
            let token = endpoint.token
            guard isSafeToken(token) else { throw Failure.missingToken }
            let header = "POST \(servicePath)\(method) HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(port)\r\n"
                + "Content-Type: application/json\r\nAccept: application/json\r\n"
                + "Accept-Encoding: identity\r\nConnect-Protocol-Version: 1\r\n"
                + "X-Codeium-Csrf-Token: \(token)\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            return Data(header.utf8)
        })
    }

    private static func discoverServers() throws -> [Server] {
        let listing = try subprocess("/bin/ps", ["-axo", "pid=,uid="], maximum: maximumBytes)
        let pids = processIdentifiers(in: listing, uid: getuid())
        var servers: [Server] = []
        var missingToken = false
        for pid in pids {
            try Task.checkCancellation()
            guard processPath(pid) == executablePath else { continue }
            let identity = try validateProcess(pid)
            let arguments = try subprocess("/bin/ps", ["-ww", "-p", String(pid), "-o", "args="], maximum: 65_536)
            guard let token = flag("csrf_token", in: arguments), isSafeToken(token) else {
                missingToken = true
                continue
            }
            let ports = try listeningPorts(pid: pid)
            guard !ports.isEmpty else { continue }
            let extensionToken = flag("extension_server_csrf_token", in: arguments).flatMap { isSafeToken($0) ? $0 : nil }
            let extensionPort = flag("extension_server_port", in: arguments).flatMap(Int.init)
            guard try validateProcess(pid, expected: identity) == identity else { throw Failure.untrustedProcess }
            servers.append(Server(identity: identity, token: token, extensionToken: extensionToken,
                                  extensionPort: extensionPort, ports: ports))
            guard servers.count < 3 else { break }
        }
        guard !servers.isEmpty else { throw missingToken ? Failure.missingToken : Failure.notRunning }
        return servers
    }

    private static func processPath(_ pid: Int32) -> String? {
        // libproc's PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; its macro is
        // not imported by every supported Swift SDK.
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return count > 0 ? String(cString: buffer) : nil
    }

    private static func validateProcess(_ pid: Int32, expected: LocalSocketIdentity.ProcessIdentity? = nil) throws -> LocalSocketIdentity.ProcessIdentity {
        try Task.checkCancellation()
        let identity = try LocalSocketIdentity.processIdentity(pid: pid)
        guard expected == nil || identity == expected else { throw Failure.untrustedProcess }
        guard processPath(pid) == executablePath else { throw Failure.untrustedProcess }
        let owner = try subprocess("/bin/ps", ["-p", String(pid), "-o", "uid="], maximum: 128)
        guard owner.trimmingCharacters(in: .whitespacesAndNewlines) == String(getuid()) else {
            throw Failure.untrustedProcess
        }
        var requirement: SecRequirement?
        let team = "anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        guard SecRequirementCreateWithString(team as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw Failure.untrustedProcess }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary,
                                            [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, signatureFlags, requirement) == errSecSuccess else {
            throw Failure.untrustedProcess
        }
        var app: SecStaticCode?
        var appRequirement: SecRequirement?
        let appRule = team + " and identifier \"com.google.antigravity\""
        guard SecRequirementCreateWithString(appRule as CFString, [], &appRequirement) == errSecSuccess,
              let appRequirement,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundlePath) as CFURL, [], &app) == errSecSuccess,
              let app, SecStaticCodeCheckValidity(app, signatureFlags, appRequirement) == errSecSuccess else {
            throw Failure.untrustedProcess
        }
        guard try LocalSocketIdentity.processIdentity(pid: pid) == identity,
              processPath(pid) == executablePath else { throw Failure.untrustedProcess }
        return identity
    }

    // kSecCSStrictValidate | kSecCSNoNetworkAccess. Signature validation must
    // not turn this local-only integration into an external network request.
    private static var signatureFlags: SecCSFlags { SecCSFlags(rawValue: (1 << 4) | (1 << 29)) }

    private static func listeningPorts(pid: Int32) throws -> [Int] {
        let output = try subprocess("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fpftn"], maximum: 16_384,
                                    allowEmptyFailure: true)
        return ownedListeningPorts(in: output, pid: pid)
    }

    // These parsers intentionally accept only the small numeric/token fields
    // needed for discovery; no process descriptions or response bodies escape.
    static func processIdentifiers(in output: String, uid: uid_t) -> [Int32] {
        output.split(separator: "\n").prefix(20_000).compactMap { row in
            let fields = row.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0,
                  let owner = uid_t(fields[1]), owner == uid else { return nil }
            return pid
        }
    }

    static func ownedListeningPorts(in output: String, pid: Int32) -> [Int] {
        var correctProcess = false
        var ipv4 = false
        var ports = Set<Int>()
        for row in output.split(separator: "\n") {
            if row.first == "p" {
                correctProcess = Int32(row.dropFirst()) == pid
                ipv4 = false
                continue
            }
            if row.first == "f" { ipv4 = false; continue }
            if row.first == "t" { ipv4 = row == "tIPv4"; continue }
            guard correctProcess, ipv4, row.first == "n", let colon = row.lastIndex(of: ":"),
                  let port = Int(row[row.index(after: colon)...]), (1...65_535).contains(port) else { continue }
            let address = String(row[row.index(after: row.startIndex)..<colon])
            // This client uses IPv4 only. A wildcard must explicitly be IPv4;
            // IPv6/mapped/unknown-family listeners cannot authorize this endpoint.
            guard ["127.0.0.1", "*", "0.0.0.0"].contains(address) else { continue }
            ports.insert(port)
            if ports.count == 8 { break }
        }
        return ports.sorted()
    }

    static func flag(_ name: String, in arguments: String) -> String? {
        let fields = arguments.split(whereSeparator: \.isWhitespace)
        var result: String?
        for (index, field) in fields.enumerated() {
            let value: String?
            if field == "--\(name)", fields.indices.contains(index + 1) { value = String(fields[index + 1]) }
            else if field.hasPrefix("--\(name)=") { value = String(field.dropFirst(name.count + 3)) }
            else { value = nil }
            if let value {
                guard result == nil else { return nil }
                result = value
            }
        }
        return result
    }

    static func isSafeToken(_ token: String) -> Bool {
        (1...4096).contains(token.utf8.count) && token.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95, 46, 126, 43, 47, 61].contains($0)
        }
    }

    private static func subprocess(_ path: String, _ arguments: [String], maximum: Int,
                                   allowEmptyFailure: Bool = false) throws -> String {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw Failure.connection }
        do { try process.run() } catch { throw Failure.connection }
        defer {
            if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
        }
        let started = ProcessInfo.processInfo.systemUptime
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < 2 else { throw Failure.limit }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard count <= maximum - data.count else { throw Failure.limit }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EINTR { throw Failure.connection }
            else { usleep(10_000) }
        }
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < 2 else { throw Failure.limit }
            usleep(1_000)
        }
        guard process.terminationStatus == 0 || (allowEmptyFailure && data.isEmpty) else { throw Failure.connection }
        guard let string = String(data: data, encoding: .utf8) else { throw Failure.invalidResponse }
        return string
    }
}
