import XCTest
@testable import AIMeter

final class BoundedAPIClientTests: XCTestCase {
    private var request: URLRequest {
        var result = URLRequest(url: URL(string: "https://api.openai.com/v1/organization/costs")!)
        result.setValue("Bearer synthetic-key", forHTTPHeaderField: "Authorization")
        return result
    }
    override func setUp() { MockAPIProtocol.state.reset(.chunks(status: 200, headers: [:], [Data("synthetic".utf8)])) }

    func testFixedHTTPSDestinationAndBearerValidation() {
        XCTAssertTrue(BoundedAPIClient.isAllowedDestination(request.url!))
        XCTAssertTrue(BoundedAPIClient.isAllowedDestination(URL(string: "https://monitoring.googleapis.com/v3/projects/test-project/timeSeries")!))
        for raw in ["http://api.openai.com/", "https://api.openai.com.evil.invalid/", "https://api.openai.com:444/",
                    "https://user:password@api.openai.com/", "https://api.openai.com/#fragment", "https://127.0.0.1/"] {
            XCTAssertFalse(BoundedAPIClient.isAllowedDestination(URL(string: raw)!))
        }
        for value in ["", "a\r\nInjected: header", "a b", "日本語", String(repeating: "a", count: 16_385)] {
            XCTAssertFalse(BoundedAPIClient.isSafeBearer(value))
        }
        XCTAssertTrue(BoundedAPIClient.isSafeBearer("synthetic._~+/=-"))
    }

    func testNormalResponseUsesOnlySyntheticProtocol() async throws {
        let client = BoundedAPIClient(protocolClasses: [MockAPIProtocol.self])
        let data = try await client.data(for: request, budget: APIReadBudget())
        XCTAssertEqual(String(data: data, encoding: .utf8), "synthetic")
        XCTAssertEqual(MockAPIProtocol.state.urls.count, 1)
    }

    func testUnknownLengthChunksAreBoundedBeforeBufferingWholeResponse() async throws {
        MockAPIProtocol.state.reset(.chunks(status: 200, headers: [:], [Data(repeating: 1, count: 3), Data(repeating: 2, count: 3)]))
        let client = BoundedAPIClient(protocolClasses: [MockAPIProtocol.self])
        do { _ = try await client.data(for: request, budget: APIReadBudget(), maximumBytes: 5); XCTFail("Oversized chunks accepted") }
        catch BoundedAPIClient.Failure.limit { }
    }

    func testDeclaredLengthAndRefreshAggregateAreBounded() async throws {
        let client = BoundedAPIClient(protocolClasses: [MockAPIProtocol.self])
        MockAPIProtocol.state.reset(.chunks(status: 200, headers: ["Content-Length": "100"], []))
        do { _ = try await client.data(for: request, budget: APIReadBudget(), maximumBytes: 5); XCTFail("Oversized length accepted") }
        catch BoundedAPIClient.Failure.limit { }
        MockAPIProtocol.state.reset(.chunks(status: 200, headers: [:], [Data(repeating: 1, count: 4)]))
        let budget = APIReadBudget(maximumBytes: 6)
        let first = try await client.data(for: request, budget: budget)
        XCTAssertEqual(first.count, 4)
        do { _ = try await client.data(for: request, budget: budget); XCTFail("Refresh budget accepted") }
        catch BoundedAPIClient.Failure.limit { }
    }

    func testRedirectDoesNotForwardCredentialToAnotherHost() async throws {
        MockAPIProtocol.state.reset(.redirect)
        let client = BoundedAPIClient(protocolClasses: [MockAPIProtocol.self])
        do { _ = try await client.data(for: request, budget: APIReadBudget()); XCTFail("Redirect accepted") }
        catch { }
        XCTAssertEqual(MockAPIProtocol.state.urls.map(\.host), ["api.openai.com"])
    }

    func testDeadlineAndCancellationDoNotDependOnProtocolCompletion() async throws {
        MockAPIProtocol.state.reset(.hang)
        let client = BoundedAPIClient(protocolClasses: [MockAPIProtocol.self])
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await client.data(for: request, budget: APIReadBudget(seconds: 0.05)); XCTFail("Missing timeout") }
        catch { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let savedRequest = request
        let task = Task { try await client.data(for: savedRequest, budget: APIReadBudget()) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Missing cancellation") }
        catch is CancellationError { }
    }

    func testInvalidDestinationNeverStartsTransport() async throws {
        let client = BoundedAPIClient(protocolClasses: [MockAPIProtocol.self])
        var invalid = request
        invalid.url = URL(string: "https://other.invalid/")!
        do { _ = try await client.data(for: invalid, budget: APIReadBudget()); XCTFail("Invalid destination accepted") }
        catch BoundedAPIClient.Failure.destination { }
        XCTAssertTrue(MockAPIProtocol.state.urls.isEmpty)
    }
}

private final class MockAPIProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case chunks(status: Int, headers: [String: String], [Data]), redirect, hang }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var mode: Mode = .hang
        private var requests: [URL] = []
        func reset(_ value: Mode) { lock.lock(); mode = value; requests = []; lock.unlock() }
        func record(_ url: URL) -> Mode { lock.lock(); defer { lock.unlock() }; requests.append(url); return mode }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requests }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        switch Self.state.record(url) {
        case let .chunks(status, headers, chunks):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            chunks.forEach { client?.urlProtocol(self, didLoad: $0) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            if url.host == "api.openai.com" {
                let destination = URL(string: "https://other.invalid/")!
                let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            } else { client?.urlProtocolDidFinishLoading(self) }
        case .hang: break
        }
    }
    override func stopLoading() { }
}
