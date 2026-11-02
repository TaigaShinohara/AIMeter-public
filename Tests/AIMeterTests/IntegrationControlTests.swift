import XCTest
import Security
@testable import AIMeter

final class IntegrationControlTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "AIMeter-Integration-Control-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        IntegrationControlProtocol.state.reset()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        IntegrationControlProtocol.state.reset()
    }

    @MainActor
    private func monitor(_ keychain: ControlKeychain, openAI: Bool = true, gemini: Bool = false,
                         token: ((APIReadBudget, IntegrationPermit) async -> String?)? = nil) -> UsageMonitor {
        defaults.set(openAI, forKey: "showOpenAISection")
        defaults.set(gemini, forKey: "showGeminiSection")
        defaults.set(false, forKey: "showAntigravitySection")
        defaults.set("synthetic-project", forKey: "gcpProjectId")
        return UsageMonitor(defaults: defaults, startMonitoring: false,
                            apiClient: BoundedAPIClient(protocolClasses: [IntegrationControlProtocol.self]),
                            keychainOperations: keychain.operations, gcloudTokenProvider: token)
    }

    @MainActor
    func testDisabledServicesDoNotReadKeysRequestTokensOrStartHTTPAfterRepeatedRefreshAndRestart() async {
        let keychain = ControlKeychain("synthetic-saved")
        defaults.set("synthetic-retained-legacy", forKey: "openaiAdminKey")
        var tokenCalls = 0
        let token: (APIReadBudget, IntegrationPermit) async -> String? = { _, _ in
            tokenCalls += 1
            return "synthetic-token"
        }
        let host = monitor(keychain, openAI: false, gemini: false, token: token)
        host.loadOpenAICredentialIfEnabled()
        host.retryOpenAICredentialLoad()
        for _ in 0..<3 { await host.refreshConfiguredAPIs() }
        let restarted = monitor(keychain, openAI: false, gemini: false, token: token)
        restarted.loadOpenAICredentialIfEnabled()
        await restarted.refreshConfiguredAPIs()
        XCTAssertTrue(keychain.calls.isEmpty)
        XCTAssertEqual(tokenCalls, 0)
        XCTAssertTrue(IntegrationControlProtocol.state.requests.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "openaiAdminKey"), "synthetic-retained-legacy")
        XCTAssertEqual(host.openaiAdminKey, "")
        XCTAssertNil(host.lastUpdated)
    }

    @MainActor
    func testEnabledOpenAIUsesCommittedKeyAndPreservesNormalUsageAndCostAggregation() async {
        let keychain = ControlKeychain("synthetic-committed")
        let host = monitor(keychain)
        host.loadOpenAICredentialIfEnabled()
        host.openaiAdminKeyDraft = "synthetic-unsaved-draft"
        await host.refreshConfiguredAPIs()
        XCTAssertEqual(keychain.calls, ["read"])
        XCTAssertEqual(host.openaiAdminKey, "synthetic-committed")
        XCTAssertEqual(host.openaiAdminKeyDraft, "synthetic-unsaved-draft")
        XCTAssertEqual(host.openaiUsedTokens, 10)
        XCTAssertEqual(host.openaiUsed5h, 10)
        XCTAssertEqual(host.openaiCostUSD, 1.25)
        XCTAssertEqual(host.openaiStatus, "API")
        XCTAssertNotNil(host.lastUpdated)
        let requests = IntegrationControlProtocol.state.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.openai.com" })
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-committed"
        })
    }

    @MainActor
    func testEditingAfterDisableReenableRestoresBeforeAcceptingTheDraft() async {
        let keychain = ControlKeychain("synthetic-committed")
        let host = monitor(keychain)
        host.loadOpenAICredentialIfEnabled()
        XCTAssertEqual(keychain.calls, ["read"])
        host.showOpenAISection = false
        XCTAssertEqual(host.openaiAdminKey, "")
        host.showOpenAISection = true
        // The existing Settings form can remain mounted across this toggle.
        // No explicit onAppear/load call occurs before accepting its edit.
        host.openaiAdminKeyDraft = "synthetic-new-unsaved-draft"
        XCTAssertEqual(host.openaiAdminKey, "synthetic-committed")
        await host.refreshConfiguredAPIs()
        XCTAssertEqual(host.openaiAdminKeyDraft, "synthetic-new-unsaved-draft")
        XCTAssertEqual(host.openaiAdminKey, "synthetic-committed")
        XCTAssertEqual(keychain.calls, ["read", "read"])
        XCTAssertEqual(IntegrationControlProtocol.state.requests.count, 3)
        XCTAssertTrue(IntegrationControlProtocol.state.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-committed"
        })
    }

    @MainActor
    func testDisablingPendingOpenAIStopsSubsequentRequestsAndPublication() async {
        let started = expectation(description: "First OpenAI request started")
        IntegrationControlProtocol.state.reset(hang: true, onStart: { started.fulfill() })
        let host = monitor(ControlKeychain("synthetic-committed"))
        host.openaiUsedTokens = 77
        host.openaiUsed5h = 8
        let refresh = Task { await host.refreshConfiguredAPIs() }
        await fulfillment(of: [started], timeout: 1)
        host.showOpenAISection = false
        let disabledAt = ProcessInfo.processInfo.systemUptime
        await refresh.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - disabledAt, 1)
        XCTAssertEqual(IntegrationControlProtocol.state.requests.count, 1)
        XCTAssertEqual(host.openaiUsedTokens, 77)
        XCTAssertEqual(host.openaiUsed5h, 8)
        XCTAssertEqual(host.openaiStatus, "実ログ")
        XCTAssertNil(host.lastUpdated)
        XCTAssertEqual(host.openaiAdminKey, "")
        XCTAssertEqual(host.openaiAdminKeyDraft, "")
    }

    @MainActor
    func testLateTokenAfterDisableStartsNoHTTPAndPublishesNothing() async {
        let started = expectation(description: "Synthetic token operation started")
        let gate = ControlTokenGate(onStart: { started.fulfill() })
        let host = monitor(ControlKeychain(), openAI: false, gemini: true,
                           token: { _, _ in await gate.wait() })
        host.geminiUsedTokens = 77
        let refresh = Task { await host.refreshConfiguredAPIs() }
        await fulfillment(of: [started], timeout: 1)
        host.showGeminiSection = false
        gate.resume("synthetic-late-token")
        await refresh.value
        XCTAssertTrue(IntegrationControlProtocol.state.requests.isEmpty)
        XCTAssertEqual(host.geminiUsedTokens, 77)
        XCTAssertEqual(host.geminiStatus, "実ログ")
        XCTAssertNil(host.lastUpdated)
    }

    @MainActor
    func testDirectDefaultsDisableReenableRevokesThePendingToken() async {
        let started = expectation(description: "Token operation before direct defaults change")
        let gate = ControlTokenGate(onStart: { started.fulfill() })
        let host = monitor(ControlKeychain(), openAI: false, gemini: true,
                           token: { _, _ in await gate.wait() })
        host.geminiUsedTokens = 77
        let refresh = Task { await host.refreshConfiguredAPIs() }
        await fulfillment(of: [started], timeout: 1)
        // This bypasses UsageMonitor's property observers. Returning to true
        // must not make the old permission valid again.
        defaults.set(false, forKey: "showGeminiSection")
        defaults.set(true, forKey: "showGeminiSection")
        gate.resume("synthetic-obsolete-token")
        await refresh.value
        XCTAssertTrue(IntegrationControlProtocol.state.requests.isEmpty)
        XCTAssertEqual(host.geminiUsedTokens, 77)
        XCTAssertEqual(host.geminiStatus, "実ログ")
        XCTAssertNil(host.lastUpdated)
    }

    @MainActor
    func testDirectDefaultsProjectChangeRevokesThePendingToken() async {
        let started = expectation(description: "Token operation for previous project")
        let gate = ControlTokenGate(onStart: { started.fulfill() })
        let host = monitor(ControlKeychain(), openAI: false, gemini: true,
                           token: { _, _ in await gate.wait() })
        host.geminiUsedTokens = 77
        let refresh = Task { await host.refreshConfiguredAPIs() }
        await fulfillment(of: [started], timeout: 1)
        defaults.set("synthetic-other-project", forKey: "gcpProjectId")
        gate.resume("synthetic-old-project-token")
        await refresh.value
        XCTAssertTrue(IntegrationControlProtocol.state.requests.isEmpty)
        XCTAssertEqual(host.geminiUsedTokens, 77)
        XCTAssertEqual(host.geminiStatus, "実ログ")
        XCTAssertNil(host.lastUpdated)
    }

    @MainActor
    func testBackgroundDefaultsRevokesBeforeMainActorReceivesTheChange() async {
        let started = expectation(description: "Synthetic background token worker started")
        let releaseWorker = DispatchSemaphore(value: 0)
        let workerDone = DispatchSemaphore(value: 0)
        let backgroundDone = DispatchSemaphore(value: 0)
        let recorder = ControlStartRecorder()
        let host = monitor(ControlKeychain(), openAI: false, gemini: true, token: { _, permit in
            await Task.detached { () -> String? in
                started.fulfill()
                defer { workerDone.signal() }
                guard waitForControlSignal(releaseWorker, seconds: 2) == .success else { return nil }
                // Model the runner's actual start boundary. The revoked lease
                // must reject this even while MainActor cleanup is queued.
                return try? permit.withPermission {
                    recorder.record()
                    return "synthetic-late-worker-token"
                }
            }.value
        })
        let refresh = Task { await host.refreshConfiguredAPIs() }
        await fulfillment(of: [started], timeout: 1)
        let isolatedDefaults = ControlDefaultsBox(defaults!)
        DispatchQueue.global().async {
            isolatedDefaults.setGeminiEnabled(false)
            isolatedDefaults.setGeminiEnabled(true)
            releaseWorker.signal()
            recorder.recordWorkerCompletion(waitForControlSignal(workerDone, seconds: 1) == .success)
            backgroundDone.signal()
        }
        // Keep MainActor notification cleanup from participating in the proof.
        // Every blocking wait is bounded, and no real process/network starts.
        XCTAssertEqual(waitForControlSignal(backgroundDone, seconds: 1.5), .success)
        XCTAssertTrue(recorder.workerCompleted)
        XCTAssertEqual(recorder.count, 0)
        await refresh.value
        XCTAssertTrue(IntegrationControlProtocol.state.requests.isEmpty)
        XCTAssertEqual(host.geminiStatus, "実ログ")
        XCTAssertNil(host.lastUpdated)
    }

    @MainActor
    func testDisableReenableDoesNotLetOldTokenOverwriteNewRefresh() async {
        let started = expectation(description: "Old token operation started")
        let gate = ControlTokenGate(onStart: { started.fulfill() })
        var tokenCalls = 0
        let host = monitor(ControlKeychain(), openAI: false, gemini: true, token: { _, _ in
            tokenCalls += 1
            if tokenCalls == 1 { return await gate.wait() }
            return "synthetic-current-token"
        })
        let oldRefresh = Task { await host.refreshConfiguredAPIs() }
        await fulfillment(of: [started], timeout: 1)
        host.showGeminiSection = false
        host.showGeminiSection = true
        await host.refreshConfiguredAPIs()
        XCTAssertEqual(host.geminiUsedTokens, 9)
        XCTAssertEqual(host.geminiStatus, "GCP")
        let requestsBeforeOldReturn = IntegrationControlProtocol.state.requests
        let updatedBeforeOldReturn = host.lastUpdated
        XCTAssertEqual(requestsBeforeOldReturn.count, 5)
        gate.resume("synthetic-obsolete-token")
        await oldRefresh.value
        XCTAssertEqual(IntegrationControlProtocol.state.requests.count, requestsBeforeOldReturn.count)
        XCTAssertTrue(IntegrationControlProtocol.state.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-current-token"
        })
        XCTAssertEqual(host.geminiUsedTokens, 9)
        XCTAssertEqual(host.lastUpdated, updatedBeforeOldReturn)
        XCTAssertEqual(tokenCalls, 2)
    }

    @MainActor
    func testCallerPreservesFailedDraftAndLegacyUntilSuccessfulDeletePreventsResurrection() {
        let keychain = ControlKeychain("synthetic-original")
        defaults.set("synthetic-retained-legacy", forKey: "openaiAdminKey")
        keychain.readFailure = errSecInteractionNotAllowed
        let host = monitor(keychain)
        host.loadOpenAICredentialIfEnabled()
        XCTAssertEqual(host.openaiAdminKey, "")
        XCTAssertEqual(host.openaiAdminKeyDraft, "synthetic-retained-legacy")
        XCTAssertNotNil(host.openaiCredentialError)
        XCTAssertEqual(defaults.string(forKey: "openaiAdminKey"), "synthetic-retained-legacy")

        host.openaiAdminKeyDraft = "synthetic-unsaved"
        keychain.updateFailure = errSecAuthFailed
        XCTAssertFalse(host.saveOpenAICredential())
        host.loadOpenAICredentialIfEnabled()
        XCTAssertEqual(host.openaiAdminKeyDraft, "synthetic-unsaved")
        XCTAssertEqual(host.openaiAdminKey, "")
        XCTAssertNotNil(host.openaiCredentialError)
        XCTAssertEqual(keychain.calls, ["read", "update"])
        XCTAssertEqual(keychain.stored, Data("synthetic-original".utf8))

        host.openaiAdminKeyDraft = ""
        keychain.deleteFailure = errSecInteractionNotAllowed
        XCTAssertFalse(host.saveOpenAICredential())
        XCTAssertEqual(defaults.string(forKey: "openaiAdminKey"), "synthetic-retained-legacy")
        XCTAssertEqual(keychain.stored, Data("synthetic-original".utf8))
        keychain.deleteFailure = nil
        XCTAssertTrue(host.saveOpenAICredential())
        XCTAssertNil(defaults.object(forKey: "openaiAdminKey"))
        XCTAssertNil(keychain.stored)
        XCTAssertNil(host.openaiCredentialError)

        keychain.readFailure = nil
        let restarted = monitor(keychain)
        restarted.loadOpenAICredentialIfEnabled()
        XCTAssertEqual(restarted.openaiAdminKey, "")
        XCTAssertEqual(restarted.openaiAdminKeyDraft, "")
        XCTAssertNil(keychain.stored)
        XCTAssertFalse(keychain.calls.contains("add"))
    }

    @MainActor
    func testSaveAndDeleteAreRefusedWhileIntegrationIsDisabled() {
        let keychain = ControlKeychain("synthetic-original")
        defaults.set("synthetic-legacy", forKey: "openaiAdminKey")
        let host = monitor(keychain, openAI: false)
        host.openaiAdminKeyDraft = "synthetic-edited"
        XCTAssertFalse(host.saveOpenAICredential())
        host.openaiAdminKeyDraft = ""
        XCTAssertFalse(host.saveOpenAICredential())
        XCTAssertTrue(keychain.calls.isEmpty)
        XCTAssertEqual(keychain.stored, Data("synthetic-original".utf8))
        XCTAssertEqual(defaults.string(forKey: "openaiAdminKey"), "synthetic-legacy")
    }

    @MainActor
    func testMalformedEnablePreferencesNeverAuthorizeCredentialOrRemoteStarts() async {
        // CFPreferences may canonicalize 0/1 as real CFBoolean values. Use
        // unambiguously numeric values to test rejection of persisted numbers.
        let malformed: [Any] = ["false", "true", "unexpected", NSNumber(value: 2),
                                NSNumber(value: -1), NSNumber(value: 0.5), [true], Data([1])]
        for (index, value) in malformed.enumerated() {
            IntegrationControlProtocol.state.reset()
            let keychain = ControlKeychain("synthetic-committed")
            var tokenCalls = 0
            let host = monitor(keychain, openAI: true, gemini: true, token: { _, _ in
                tokenCalls += 1
                return "synthetic-token"
            })
            defaults.set(value, forKey: "showOpenAISection")
            defaults.set(value, forKey: "showGeminiSection")
            host.loadOpenAICredentialIfEnabled()
            await host.refreshConfiguredAPIs()
            XCTAssertTrue(keychain.calls.isEmpty, "synthetic case \(index)")
            XCTAssertEqual(tokenCalls, 0, "synthetic case \(index)")
            XCTAssertTrue(IntegrationControlProtocol.state.requests.isEmpty, "synthetic case \(index)")
            XCTAssertNil(host.lastUpdated, "synthetic case \(index)")
        }
    }

    @MainActor
    func testInvalidProjectPreferencesNeverRequestAToken() async {
        let invalid: [Any] = [NSNumber(value: 123456), ["project"], Data([1]), "", "bad/path", "-invalid"]
        for value in invalid {
            IntegrationControlProtocol.state.reset()
            var tokenCalls = 0
            let keychain = ControlKeychain()
            let host = monitor(keychain, openAI: false, gemini: true, token: { _, _ in
                tokenCalls += 1
                return "synthetic-token"
            })
            defaults.set(value, forKey: "gcpProjectId")
            await host.refreshConfiguredAPIs()
            XCTAssertEqual(tokenCalls, 0)
            XCTAssertTrue(keychain.calls.isEmpty)
            XCTAssertTrue(IntegrationControlProtocol.state.requests.isEmpty)
            XCTAssertNil(host.lastUpdated)
        }
    }

    @MainActor
    func testRepeatedOpenAIDailyCursorRejectsBeforePublishingPartialUsage() async {
        IntegrationControlProtocol.state.reset(script: { _, _ in
            .http(200, IntegrationControlProtocol.usagePage(tokens: 3, nextPage: "repeated-page"))
        })
        let host = monitor(ControlKeychain("synthetic-committed"))
        host.openaiUsedTokens = 77
        host.openaiUsed5h = 8
        host.openaiCostUSD = 99
        await host.refreshConfiguredAPIs()
        let requests = IntegrationControlProtocol.state.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { IntegrationControlProtocol.query("bucket_width", in: $0) == "1d" })
        XCTAssertEqual(host.openaiUsedTokens, 77)
        XCTAssertEqual(host.openaiUsed5h, 8)
        XCTAssertEqual(host.openaiCostUSD, 99)
        XCTAssertEqual(host.openaiStatus, "実ログ")
        XCTAssertNil(host.lastUpdated)
    }

    @MainActor
    func testExactlyTenOpenAIDailyPagesAggregateBeforeNormalHourlyAndCostRequests() async {
        IntegrationControlProtocol.state.reset(script: { request, ordinal in
            guard request.url?.path.hasSuffix("/usage/completions") == true,
                  IntegrationControlProtocol.query("bucket_width", in: request) == "1d" else { return .normal }
            return .http(200, IntegrationControlProtocol.usagePage(tokens: 3,
                nextPage: ordinal < 10 ? "day-\(ordinal + 1)" : nil))
        })
        let keychain = ControlKeychain("synthetic-committed")
        let host = monitor(keychain)
        await host.refreshConfiguredAPIs()
        let requests = IntegrationControlProtocol.state.requests
        XCTAssertEqual(requests.count, 12)
        let daily = requests.filter { IntegrationControlProtocol.query("bucket_width", in: $0) == "1d"
            && $0.url?.path.hasSuffix("/usage/completions") == true }
        XCTAssertEqual(daily.count, 10)
        XCTAssertNil(daily.first.flatMap { IntegrationControlProtocol.query("page", in: $0) })
        XCTAssertEqual(daily.dropFirst().compactMap { IntegrationControlProtocol.query("page", in: $0) },
                       (2...10).map { "day-\($0)" })
        XCTAssertEqual(host.openaiUsedTokens, 30)
        XCTAssertEqual(host.openaiUsed5h, 10)
        XCTAssertEqual(host.openaiCostUSD, 1.25)
        XCTAssertEqual(host.openaiStatus, "API")
        XCTAssertNotNil(host.lastUpdated)
        XCTAssertEqual(keychain.calls, ["read"])
    }

    @MainActor
    func testOpenAIPageLimitRejectsBeforeAnEleventhPageOrPartialPublication() async {
        IntegrationControlProtocol.state.reset(script: { _, ordinal in
            .http(200, IntegrationControlProtocol.usagePage(tokens: 3, nextPage: "day-\(ordinal + 1)"))
        })
        let host = monitor(ControlKeychain("synthetic-committed"))
        host.openaiUsedTokens = 77
        host.openaiUsed5h = 8
        await host.refreshConfiguredAPIs()
        XCTAssertEqual(IntegrationControlProtocol.state.requests.count, 10)
        XCTAssertTrue(IntegrationControlProtocol.state.requests.allSatisfy {
            IntegrationControlProtocol.query("bucket_width", in: $0) == "1d"
        })
        XCTAssertEqual(host.openaiUsedTokens, 77)
        XCTAssertEqual(host.openaiUsed5h, 8)
        XCTAssertEqual(host.openaiStatus, "実ログ")
        XCTAssertNil(host.lastUpdated)
    }

    @MainActor
    func testGCPRepeatedAndExcessiveCursorsRemainBoundedWithoutFalseSuccess() async {
        for repeated in [true, false] {
            IntegrationControlProtocol.state.reset(script: { _, ordinal in
                .http(200, IntegrationControlProtocol.monitoringPage(tokens: 9,
                    nextPage: repeated ? "repeated-page" : "page-\(ordinal + 1)"))
            })
            let host = monitor(ControlKeychain(), openAI: false, gemini: true,
                               token: { _, _ in "synthetic-token" })
            host.geminiUsedTokens = 77
            host.geminiUsed5h = 8
            await host.refreshConfiguredAPIs()
            let requests = IntegrationControlProtocol.state.requests
            // The caller tries token_count, then its existing request_count
            // fallback. Both independent queries must obey the same limit.
            XCTAssertEqual(requests.count, repeated ? 4 : 20)
            let filters = requests.compactMap { IntegrationControlProtocol.query("filter", in: $0) }
            XCTAssertEqual(filters.filter { $0.contains("token_count") }.count, repeated ? 2 : 10)
            XCTAssertEqual(filters.filter { $0.contains("request_count") }.count, repeated ? 2 : 10)
            XCTAssertEqual(host.geminiUsedTokens, 77)
            XCTAssertEqual(host.geminiUsed5h, 8)
            XCTAssertEqual(host.geminiStatus, "実ログ")
            XCTAssertNil(host.lastUpdated)
        }
    }

    @MainActor
    func testOpenAIAuthenticationPermissionAndRateFailuresKeepPriorValuesWithoutFurtherRequests() async {
        for status in [401, 403, 429] {
            IntegrationControlProtocol.state.reset(script: { _, _ in .http(status, [:]) })
            let host = monitor(ControlKeychain("synthetic-committed"))
            host.openaiUsedTokens = 77
            host.openaiUsed5h = 8
            host.openaiCostUSD = 99
            await host.refreshConfiguredAPIs()
            XCTAssertEqual(IntegrationControlProtocol.state.requests.count, 1)
            XCTAssertEqual(host.openaiUsedTokens, 77)
            XCTAssertEqual(host.openaiUsed5h, 8)
            XCTAssertEqual(host.openaiCostUSD, 99)
            XCTAssertEqual(host.openaiStatus, "実ログ")
            XCTAssertNil(host.lastUpdated)
        }
    }

    @MainActor
    func testRepeatedNormalAndRejectedRefreshesKeepStableRequestAndCredentialCounts() async {
        let keychain = ControlKeychain("synthetic-committed")
        let host = monitor(keychain)
        for _ in 0..<10 { await host.refreshConfiguredAPIs() }
        XCTAssertEqual(IntegrationControlProtocol.state.requests.count, 30)
        XCTAssertEqual(keychain.calls, ["read"])
        let previousUpdate = host.lastUpdated
        IntegrationControlProtocol.state.reset(script: { _, _ in .http(403, [:]) })
        for _ in 0..<5 { await host.refreshConfiguredAPIs() }
        XCTAssertEqual(IntegrationControlProtocol.state.requests.count, 5)
        XCTAssertEqual(keychain.calls, ["read"])
        XCTAssertEqual(host.lastUpdated, previousUpdate)
        XCTAssertEqual(host.openaiUsedTokens, 10)
        XCTAssertEqual(host.openaiCostUSD, 1.25)
    }
}

/// This synchronous barrier deliberately keeps MainActor cleanup from helping
/// the revocation proof. All waits have the same short deadlines as the fixture.
private func waitForControlSignal(_ semaphore: DispatchSemaphore, seconds: TimeInterval) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + seconds)
}

/// Foundation's UserDefaults supports concurrent access. Only the UUID test
/// suite's single setting is exposed across queues; no monitor state is shared.
private final class ControlDefaultsBox: @unchecked Sendable {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func setGeminiEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: "showGeminiSection") }
}

private final class ControlStartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var completed = false
    func record() { lock.lock(); starts += 1; lock.unlock() }
    func recordWorkerCompletion(_ value: Bool) { lock.lock(); completed = value; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var workerCompleted: Bool { lock.lock(); defer { lock.unlock() }; return completed }
}

private final class ControlKeychain {
    var stored: Data?
    var calls: [String] = []
    var readFailure: OSStatus?
    var updateFailure: OSStatus?
    var deleteFailure: OSStatus?

    init(_ value: String? = nil) { stored = value.map { Data($0.utf8) } }

    var operations: KeychainHelper.Operations {
        .init(update: { _, attributes in
            self.calls.append("update")
            if let status = self.updateFailure { return status }
            guard self.stored != nil else { return errSecItemNotFound }
            self.stored = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }, add: { query in
            self.calls.append("add")
            guard self.stored == nil else { return errSecDuplicateItem }
            self.stored = query[kSecValueData as String] as? Data
            return errSecSuccess
        }, delete: { _ in
            self.calls.append("delete")
            if let status = self.deleteFailure { return status }
            guard self.stored != nil else { return errSecItemNotFound }
            self.stored = nil
            return errSecSuccess
        }, copyMatching: { _ in
            self.calls.append("read")
            if let status = self.readFailure { return (status, nil) }
            return (self.stored == nil ? errSecItemNotFound : errSecSuccess, self.stored)
        })
    }
}

private final class ControlTokenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var returned: String?
    private var hasReturned = false
    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) { self.onStart = onStart }

    func wait() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasReturned {
                let value = returned
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
                onStart()
            }
        }
    }

    func resume(_ value: String?) {
        lock.lock()
        returned = value
        hasReturned = true
        let saved = continuation
        continuation = nil
        lock.unlock()
        saved?.resume(returning: value)
    }
}

private final class IntegrationControlProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case normal
        case http(Int, [String: Any])
        case hang
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [URLRequest] = []
        private var hang = false
        private var onStart: (() -> Void)?
        private var script: ((URLRequest, Int) -> Reply)?

        func reset(hang: Bool = false, onStart: (() -> Void)? = nil,
                   script: ((URLRequest, Int) -> Reply)? = nil) {
            lock.lock()
            captured = []; self.hang = hang; self.onStart = onStart; self.script = script
            lock.unlock()
        }

        func record(_ request: URLRequest) -> Reply {
            lock.lock()
            captured.append(request)
            let ordinal = captured.count
            let hangs = hang
            let callback = onStart
            let response = script
            lock.unlock()
            callback?()
            return hangs ? .hang : response?(request, ordinal) ?? .normal
        }

        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.state.record(request)
        guard let url = request.url else { return }
        let status: Int
        let json: [String: Any]
        switch reply {
        case .hang: return
        case let .http(code, object): status = code; json = object
        case .normal: status = 200; json = Self.normalJSON(for: url)
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func query(_ name: String, in request: URLRequest) -> String? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == name }?.value
    }

    static func usagePage(tokens: Int, nextPage: String?) -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970)
        var page: [String: Any] = ["data": [["start_time": now, "end_time": now + 3600,
            "results": [["input_tokens": tokens, "output_tokens": 0]]]], "has_more": nextPage != nil]
        if let nextPage { page["next_page"] = nextPage }
        return page
    }

    static func monitoringPage(tokens: Int, nextPage: String?) -> [String: Any] {
        var page: [String: Any] = ["timeSeries": [["points": [["value": ["int64Value": String(tokens)]]]]]]
        if let nextPage { page["nextPageToken"] = nextPage }
        return page
    }

    private static func normalJSON(for url: URL) -> [String: Any] {
        if url.host == "monitoring.googleapis.com" {
            return monitoringPage(tokens: 9, nextPage: nil)
        } else if url.path.hasSuffix("/costs") {
            return ["data": [["results": [["amount": ["value": 1.25]]]]], "has_more": false]
        } else {
            return usagePage(tokens: 10, nextPage: nil)
        }
    }

    override func stopLoading() { }
}
