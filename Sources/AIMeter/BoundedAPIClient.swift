import Foundation

/// Shared by every optional API request in a refresh, including pagination.
final class APIReadBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: TimeInterval
    private let maximumBytes: Int
    private var consumed = 0

    init(maximumBytes: Int = 32 * 1024 * 1024, seconds: TimeInterval = 60) {
        self.maximumBytes = maximumBytes
        deadline = ProcessInfo.processInfo.systemUptime + seconds
    }

    func remainingSeconds() throws -> TimeInterval {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw BoundedAPIClient.Failure.limit }
        return remaining
    }

    func consume(_ count: Int) throws {
        _ = try remainingSeconds()
        lock.lock(); defer { lock.unlock() }
        guard count >= 0, count <= maximumBytes - consumed else { throw BoundedAPIClient.Failure.limit }
        consumed += count
    }
}

/// Credential-bearing API requests never follow redirects, use proxy/cookie
/// credentials, or buffer an unbounded body. External HTTPS keeps OS trust.
final class BoundedAPIClient: @unchecked Sendable {
    enum Failure: Error { case destination, response, limit }
    static let allowedHosts: Set<String> = ["api.openai.com", "monitoring.googleapis.com"]
    static let maximumResponseBytes = 8 * 1024 * 1024
    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }

    static func isAllowedDestination(_ url: URL) -> Bool {
        url.scheme == "https" && allowedHosts.contains(url.host ?? "")
            && (url.port == nil || url.port == 443) && url.user == nil
            && url.password == nil && url.fragment == nil
    }

    static func isSafeBearer(_ value: String) -> Bool {
        (1...16_384).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || [45, 95, 46, 126, 43, 47, 61].contains($0)
        }
    }

    func data(for request: URLRequest, budget: APIReadBudget,
              maximumBytes: Int = BoundedAPIClient.maximumResponseBytes,
              permit: IntegrationPermit? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard let url = request.url, Self.isAllowedDestination(url), maximumBytes >= 0 else { throw Failure.destination }
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            guard authorization.hasPrefix("Bearer "), Self.isSafeBearer(String(authorization.dropFirst(7))) else {
                throw Failure.destination
            }
        }
        let duration = min(30, try budget.remainingSeconds())
        let operation = RequestOperation(url: url, budget: budget, maximumBytes: maximumBytes, permit: permit)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.timeoutIntervalForRequest = min(15, duration)
        configuration.timeoutIntervalForResource = duration
        configuration.waitsForConnectivity = false
        configuration.protocolClasses = protocolClasses
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(request: request, configuration: configuration,
                                duration: duration, continuation: continuation)
            }
        } onCancel: { operation.finish(.failure(CancellationError())) }
    }

    private final class RequestOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL
        private let budget: APIReadBudget
        private let maximumBytes: Int
        private let permit: IntegrationPermit?
        private var continuation: CheckedContinuation<Data, Error>?
        private var result: Result<Data, Error>?
        private var session: URLSession?
        private var timer: DispatchWorkItem?
        private var buffer = Data()
        private var acceptedResponse = false

        init(url: URL, budget: APIReadBudget, maximumBytes: Int, permit: IntegrationPermit?) {
            self.url = url; self.budget = budget; self.maximumBytes = maximumBytes; self.permit = permit
        }

        func start(request: URLRequest, configuration: URLSessionConfiguration,
                   duration: TimeInterval, continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            if let result {
                lock.unlock(); continuation.resume(with: result); return
            }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(Failure.limit)) }
            timer = timeout
            // Start under the same lock used by cancellation. A pre-cancelled
            // operation must not create an in-flight request with credentials.
            do {
                if let permit {
                    try permit.withPermission { session.dataTask(with: request).resume() }
                } else {
                    try Task.checkCancellation()
                    session.dataTask(with: request).resume()
                }
            } catch {
                lock.unlock(); finish(.failure(error)); return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration, execute: timeout)
            lock.unlock()
        }

        func finish(_ outcome: Result<Data, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = outcome
            let savedContinuation = continuation
            continuation = nil
            let savedSession = session
            session = nil
            timer?.cancel(); timer = nil
            lock.unlock()
            savedSession?.invalidateAndCancel()
            savedContinuation?.resume(with: outcome)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, http.url == url,
                  (200...299).contains(http.statusCode) else {
                completionHandler(.cancel); finish(.failure(Failure.response)); return
            }
            do { _ = try budget.remainingSeconds() }
            catch { completionHandler(.cancel); finish(.failure(error)); return }
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                completionHandler(.cancel); finish(.failure(Failure.limit)); return
            }
            lock.lock(); acceptedResponse = true; let done = result != nil; lock.unlock()
            completionHandler(done ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            do {
                guard acceptedResponse, data.count <= maximumBytes - buffer.count else { throw Failure.limit }
                try budget.consume(data.count)
                buffer.append(data)
                lock.unlock()
            } catch {
                lock.unlock(); finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)); return }
            lock.lock(); let data = buffer; let accepted = acceptedResponse; lock.unlock()
            finish(accepted ? .success(data) : .failure(Failure.response))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
            finish(.failure(Failure.destination))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  challenge.protectionSpace.protocol == "https",
                  challenge.protectionSpace.host == url.host,
                  challenge.protectionSpace.port == 443 else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
