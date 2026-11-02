import XCTest
import Security
import AIMeterCore
@testable import AIMeter

final class MonitorPrivacyTests: XCTestCase {
    /// In-memory preferences: even setup/cleanup never write a personal domain.
    private final class RemovalControlledDefaults: UserDefaults {
        private var values: [String: Any] = [:]
        var refuseLegacyRemoval = true
        private(set) var legacyRemovalAttempts = 0

        override func object(forKey defaultName: String) -> Any? { values[defaultName] }

        override func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value
        }

        override func removeObject(forKey defaultName: String) {
            if defaultName == "openaiAdminKey" {
                legacyRemovalAttempts += 1
                if refuseLegacyRemoval { return }
            }
            values.removeValue(forKey: defaultName)
        }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private var root: URL!

    override func setUpWithError() throws {
        suite = "AIMeter.PrivacyTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "showOpenAISection")
        defaults.set(false, forKey: "showGeminiSection")
        defaults.set(false, forKey: "showAntigravitySection")
        defaults.set(true, forKey: "didAutoSeedLocalProvidersV2")
        defaults.set(true, forKey: "didMigrateHonestCostsV3")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testProviderPolicyUnionsOnlyEnabledBaseIDs() {
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false)
        var first = CustomSubscriptionConfig.preset(forId: "claude")!
        first.id = "claude_first"; first.isEnabled = false
        var second = first
        second.id = "claude_second"; second.isEnabled = true
        monitor.customSubscriptions = [first, second]
        XCTAssertEqual(monitor.enabledLocalProviderIDs, ["claude"])
        monitor.showOpenAISection = true
        XCTAssertEqual(monitor.enabledLocalProviderIDs, ["openai", "claude"])
        monitor.customSubscriptions[1].isEnabled = false
        XCTAssertEqual(monitor.enabledLocalProviderIDs, ["openai"])
    }

    @MainActor
    func testPolicyRevocationPreventsLateLocalCommit() async {
        defaults.set(true, forKey: "showOpenAISection")
        let began = expectation(description: "collector started")
        var oldCommits = 0
        let operations = KeychainHelper.Operations(update: { _, _ in errSecAuthFailed },
            add: { _ in errSecAuthFailed }, delete: { _ in errSecAuthFailed },
            copyMatching: { _ in (errSecItemNotFound, nil) })
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false,
            keychainOperations: operations, localCollector: { ids, permit in
                if ids.contains("openai") {
                    began.fulfill()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    try permit.withPermission { oldCommits += 1 }
                }
                return LocalUsageData(updatedAt: "2026-11-01T00:00:00Z")
            })
        let task = Task { await monitor.refresh() }
        await fulfillment(of: [began], timeout: 2)
        monitor.showOpenAISection = false
        await task.value
        XCTAssertEqual(oldCommits, 0)
        XCTAssertFalse(monitor.enabledLocalProviderIDs.contains("openai"))
    }

    @MainActor
    func testWidgetOffIsNotAppliedUntilPrivateSnapshotWriteSucceeds() throws {
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false)
        monitor.showUsageAmounts = true
        monitor.showOpenAISection = true
        monitor.applyLocalSnapshot(LocalUsageData(openaiUsedTokens: 37, updatedAt: "2026-11-01T00:00:00Z"))
        XCTAssertEqual(monitor.widgetSnapshot().allServices.first?.usedTokens, 37)
        XCTAssertFalse(monitor.setUsageAmountVisibility(false, to: root.appendingPathComponent("missing/cache.json")))
        XCTAssertTrue(monitor.showUsageAmounts)
        XCTAssertTrue(monitor.widgetAmountChangePending)
        XCTAssertNotNil(monitor.widgetSharingError)
        let destination = root.appendingPathComponent("widget.json")
        monitor.publishWidgetSnapshot(to: destination)
        XCTAssertFalse(monitor.showUsageAmounts)
        XCTAssertFalse(monitor.widgetAmountChangePending)
        XCTAssertNil(monitor.widgetSharingError)
        let json = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(json.contains("usedTokens"))
        XCTAssertFalse(json.contains("totalCostUSD"))
    }

    func testHomeNormalizationPreservesBoundariesAndPathSemantics() {
        let home = URL(fileURLWithPath: "/synthetic/account")
        XCTAssertEqual(ProviderPathPreferences.stored(" /synthetic/account/log ", home: home), "~/log")
        XCTAssertEqual(ProviderPathPreferences.stored("/synthetic/account", home: home), "~")
        XCTAssertEqual(ProviderPathPreferences.stored("/synthetic/account-other/log", home: home), "/synthetic/account-other/log")
        XCTAssertEqual(ProviderPathPreferences.stored("/synthetic/account/a/../日本語 log", home: home), "~/a/../日本語 log")
        XCTAssertEqual(ProviderPathPreferences.stored("~/logs", home: home), "~/logs")
    }

    @MainActor
    func testExplicitMaintenanceWorksWhileServiceIsOffWithoutCommittingForNetwork() {
        var stored: Data?
        var reads = 0
        var allowDelete = false
        let operations = KeychainHelper.Operations(update: { _, _ in errSecAuthFailed }, add: { query in
            stored = query[kSecValueData as String] as? Data
            return errSecSuccess
        }, delete: { _ in
            guard allowDelete else { return errSecInteractionNotAllowed }
            stored = nil
            return errSecSuccess
        }, copyMatching: { _ in
            reads += 1
            return (stored == nil ? errSecItemNotFound : errSecSuccess, stored)
        })
        defaults.set("synthetic-legacy", forKey: "openaiAdminKey")
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false, keychainOperations: operations)
        XCTAssertEqual(reads, 0)
        monitor.migrateLegacyOpenAICredential()
        XCTAssertTrue(monitor.openaiCredentialMaintenanceStatus.isComplete)
        XCTAssertNil(defaults.object(forKey: "openaiAdminKey"))
        XCTAssertEqual(stored, Data("synthetic-legacy".utf8))
        XCTAssertEqual(monitor.openaiAdminKey, "")
        XCTAssertFalse(monitor.showOpenAISection)

        defaults.set("synthetic-retained", forKey: "openaiAdminKey")
        monitor.deleteStoredOpenAICredential()
        XCTAssertEqual(monitor.openaiCredentialMaintenanceStatus, .deleteFailed)
        XCTAssertNotNil(defaults.object(forKey: "openaiAdminKey"))
        allowDelete = true
        monitor.deleteStoredOpenAICredential()
        XCTAssertEqual(monitor.openaiCredentialMaintenanceStatus, .deletionCompleted)
        XCTAssertNil(stored)
        XCTAssertNil(defaults.object(forKey: "openaiAdminKey"))
        XCTAssertFalse(monitor.showOpenAISection)
    }

    @MainActor
    func testNormalLegacyRemovalRetryClearsPendingStateOnlyAfterConfirmedAbsence() {
        let synthetic = RemovalControlledDefaults(suiteName: "AIMeter.PrivacyTests.Removal." + UUID().uuidString)!
        synthetic.set(true, forKey: "showOpenAISection")
        synthetic.set(false, forKey: "showGeminiSection")
        synthetic.set(false, forKey: "showAntigravitySection")
        synthetic.set("synthetic-retained-legacy", forKey: "openaiAdminKey")
        var reads = 0
        let saved = Data("synthetic-current-key".utf8)
        let operations = KeychainHelper.Operations(
            update: { _, _ in XCTFail("Existing usable key must not be rewritten"); return errSecAuthFailed },
            add: { _ in XCTFail("Existing usable key must not be replaced"); return errSecAuthFailed },
            delete: { _ in XCTFail("Retry is not a Keychain deletion"); return errSecAuthFailed },
            copyMatching: { _ in reads += 1; return (errSecSuccess, saved) })
        let monitor = UsageMonitor(defaults: synthetic, startMonitoring: false,
                                   keychainOperations: operations)
        XCTAssertEqual(reads, 0)

        monitor.loadOpenAICredentialIfEnabled()
        XCTAssertEqual(monitor.openaiCredentialMaintenanceStatus, .legacyRemovalPending)
        XCTAssertTrue(monitor.openaiCredentialMaintenanceStatus.isFailure)
        XCTAssertFalse(monitor.openaiCredentialMaintenanceStatus.isComplete)
        XCTAssertEqual(synthetic.object(forKey: "openaiAdminKey") as? String, "synthetic-retained-legacy")
        XCTAssertEqual(synthetic.legacyRemovalAttempts, 1)

        synthetic.refuseLegacyRemoval = false
        monitor.retryOpenAICredentialLoad()
        XCTAssertNil(synthetic.object(forKey: "openaiAdminKey"))
        XCTAssertEqual(monitor.openaiCredentialMaintenanceStatus, .legacyRemovalConfirmed)
        XCTAssertFalse(monitor.openaiCredentialMaintenanceStatus.isFailure)
        XCTAssertTrue(monitor.openaiCredentialMaintenanceStatus.isComplete)
        XCTAssertEqual(synthetic.legacyRemovalAttempts, 2)
        XCTAssertEqual(reads, 2)
        XCTAssertNil(monitor.openaiCredentialError)
        XCTAssertFalse(monitor.openaiCredentialMaintenanceStatus.message.contains("synthetic-current-key"))
    }
}
