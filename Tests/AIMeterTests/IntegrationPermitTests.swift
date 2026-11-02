import XCTest
@testable import AIMeter

final class IntegrationPermitTests: XCTestCase {
    func testRevocationPreventsSynchronousActionAndIsPermanent() throws {
        let permit = IntegrationPermit()
        var actions = 0
        XCTAssertEqual(try permit.withPermission { actions += 1; return 7 }, 7)
        permit.revoke()
        for _ in 0..<3 {
            XCTAssertThrowsError(try permit.withPermission { actions += 1 }) { error in
                XCTAssertTrue(error is CancellationError)
            }
        }
        XCTAssertEqual(actions, 1)
    }

    func testRevocationWaitsForTheActualStartCriticalSection() {
        let permit = IntegrationPermit()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let actionDone = DispatchSemaphore(value: 0)
        let revoking = DispatchSemaphore(value: 0)
        let revoked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? permit.withPermission {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            actionDone.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            revoking.signal()
            permit.revoke()
            revoked.signal()
        }
        XCTAssertEqual(revoking.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.03), .timedOut)
        release.signal()
        XCTAssertEqual(actionDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(revoked.wait(timeout: .now() + 1), .success)
        XCTAssertThrowsError(try permit.check())
    }

    func testRevokedPermitStartsNoCredentialTransportAndLivePermitStillWorks() async throws {
        PermitProtocol.state.reset()
        let client = BoundedAPIClient(protocolClasses: [PermitProtocol.self])
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/organization/costs")!)
        request.setValue("Bearer synthetic-key", forHTTPHeaderField: "Authorization")
        let revoked = IntegrationPermit()
        revoked.revoke()
        do {
            _ = try await client.data(for: request, budget: APIReadBudget(), permit: revoked)
            XCTFail("Revoked request started")
        } catch is CancellationError { }
        XCTAssertEqual(PermitProtocol.state.count, 0)
        let response = try await client.data(for: request, budget: APIReadBudget(), permit: IntegrationPermit())
        XCTAssertEqual(response, Data("{}".utf8))
        XCTAssertEqual(PermitProtocol.state.count, 1)
    }

    func testRevokedPermitCannotSpawnAndLivePermitHasNormalOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-permit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("synthetic-marker")
        let arguments = ["-c", "printf synthetic > \"$1\"; printf done", "synthetic-test", marker.path]
        let permit = IntegrationPermit()
        permit.revoke()
        do {
            _ = try await BoundedProcess.run(executable: "/bin/sh", arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin"], permit: permit)
            XCTFail("Revoked process started")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let output = try await BoundedProcess.run(executable: "/bin/sh", arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"], permit: IntegrationPermit())
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "done")
        XCTAssertEqual(try Data(contentsOf: marker), Data("synthetic".utf8))
    }
}

private final class PermitProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var requests = 0
        func reset() { lock.lock(); requests = 0; lock.unlock() }
        func record() { lock.lock(); requests += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record()
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "2"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
