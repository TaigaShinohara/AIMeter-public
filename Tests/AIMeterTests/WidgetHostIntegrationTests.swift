import XCTest
import AIMeterCore
@testable import AIMeter

final class WidgetHostIntegrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "AIMeter-Widget-Test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "didAutoSeedLocalProvidersV2")
        defaults.set(true, forKey: "didMigrateHonestCostsV3")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func monitor() -> UsageMonitor {
        // No Keychain, collector, timers, real preferences or service requests.
        UsageMonitor(defaults: defaults, startMonitoring: false)
    }

    private var usage: LocalUsageData {
        LocalUsageData(openaiUsedTokens: 100, openaiCostUSD: 2, geminiUsedTokens: 50,
                       geminiCostUSD: 3, openaiUsedByPeriod: .init(fiveHours: 10, weekly: 90),
                       geminiUsedByPeriod: .init(fiveHours: 40, monthly: 50),
                       updatedAt: "2026-10-24T00:00:00Z")
    }

    @MainActor
    func testEnabledServicesPeriodsAndCostsMatchHostIncludingGemini() throws {
        let host = monitor()
        host.applyLocalSnapshot(usage)
        host.openaiEnabledPeriodsCSV = "5h,7d"
        host.openaiTokenLimit5h = 100
        host.openaiTokenLimitWeekly = 100
        host.geminiEnabledPeriodsCSV = "5h,30d"
        host.geminiTokenLimit5h = 50
        host.geminiTokenLimit = 100
        // Menu bar title visibility does not hide a service from the main card/Widget.
        host.showOpenAIInMenuBar = false
        let initial = host.widgetSnapshot()
        XCTAssertEqual(Set(initial.allServices.map(\.id)), ["openai", "gemini"])
        let codex = try XCTUnwrap(initial.allServices.first { $0.id == "openai" })
        XCTAssertEqual(codex.bottleneckPeriod, .weekly)
        XCTAssertEqual(codex.remainingPercent, 10)
        let gemini = try XCTUnwrap(initial.allServices.first { $0.id == "gemini" })
        XCTAssertEqual(gemini.bottleneckPeriod, .monthly)
        XCTAssertEqual(gemini.usedTokens, 50)
        XCTAssertEqual(gemini.remainingSource, .unavailable)
        XCTAssertEqual(initial.totalCostUSD, host.totalCostUSD)

        host.openaiEnabledPeriodsCSV = "5h"
        host.showGeminiSection = false
        let changed = host.widgetSnapshot()
        XCTAssertEqual(changed.allServices.map(\.id), ["openai"])
        XCTAssertEqual(changed.mostCriticalService?.remainingPercent, 90)
        XCTAssertEqual(changed.totalCostUSD, 2)
        host.showOpenAISection = false
        XCTAssertTrue(host.widgetSnapshot().hasData)
        XCTAssertTrue(host.widgetSnapshot().allServices.isEmpty)
        XCTAssertEqual(host.widgetSnapshot().totalCostUSD, 0)
    }

    @MainActor
    func testManualAndLiveUsageResolveExactlyLikeTheHostAndNoPresetsAreInvented() throws {
        let host = monitor()
        host.showOpenAISection = false
        host.showGeminiSection = false
        host.applyLocalSnapshot(usage)
        XCTAssertTrue(host.widgetSnapshot().allServices.isEmpty)
        var subscription = CustomSubscriptionConfig.cursorPreset()
        subscription.id = "cursor_test"
        subscription.enabledPeriodRawValues = ["1d"]
        subscription.limitDaily = 100
        subscription.manualUsedDaily = 80
        subscription.usedCostUSD = 7
        host.customSubscriptions = [subscription]
        host.customProviderLiveUsage = ["cursor": .init(usedByPeriod: .init(daily: 30), costUSD: 5)]
        let snapshot = host.widgetSnapshot()
        XCTAssertEqual(snapshot.allServices.map(\.id), ["cursor_test"])
        XCTAssertEqual(snapshot.mostCriticalService?.usedTokens, 80)
        XCTAssertEqual(snapshot.mostCriticalService?.remainingPercent, host.metrics(for: subscription).first?.remainingPercent)
        XCTAssertEqual(snapshot.totalCostUSD, 7)
        host.customSubscriptions[0].isEnabled = false
        XCTAssertTrue(host.widgetSnapshot().allServices.isEmpty)
    }

    @MainActor
    func testCurrentResolvedAPIStyleValuesAndFailureStateSurviveCacheRoundTrip() throws {
        let host = monitor()
        host.applyLocalSnapshot(usage)
        host.openaiEnabledPeriodsCSV = "5h"
        host.openaiTokenLimit5h = 100
        // Simulate the resolved properties after optional API refresh; no HTTP request.
        host.openaiUsed5h = 85
        host.openaiCostUSD = 12.5
        host.openaiStatus = "API"
        host.geminiUsed5h = 100_000
        host.collectionError = "Synthetic failure"
        let cache = root.appendingPathComponent("widget.json")
        host.publishWidgetSnapshot(to: cache)
        let read = SharedStore.loadWidgetSnapshot(from: cache)
        XCTAssertEqual(read, host.widgetSnapshot())
        XCTAssertEqual(read.allServices.first { $0.id == "openai" }?.remainingPercent, 15)
        XCTAssertEqual(read.totalCostUSD, host.totalCostUSD)
        XCTAssertEqual(read.updatedAt, ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z"))
        XCTAssertTrue(read.updateFailed)
        XCTAssertNil(host.widgetSharingError)
    }

    @MainActor
    func testAPISuccessAfterLocalFailureSharesItsActualAcquisitionTime() {
        let host = monitor()
        host.openaiUsed5h = 20
        host.openaiStatus = "API"
        let apiTime = Date(timeIntervalSince1970: 1_792_800_000)
        host.recordUsageUpdate(at: apiTime)
        host.collectionError = "Synthetic local failure"
        XCTAssertTrue(host.widgetSnapshot().hasData)
        XCTAssertTrue(host.widgetSnapshot().updateFailed)
        XCTAssertEqual(host.widgetSnapshot().updatedAt, apiTime)
        XCTAssertEqual(host.lastUpdated, apiTime)
    }

    @MainActor
    func testNoDataAndWriteFailureDoNotInventValuesOrARecentAcquisition() {
        let host = monitor()
        XCTAssertEqual(host.widgetSnapshot(), .empty())
        XCTAssertNil(host.lastUpdated)
        host.collectionError = "Synthetic failure"
        XCTAssertEqual(host.widgetSnapshot(), .empty(updateFailed: true))
        host.publishWidgetSnapshot(to: root.appendingPathComponent("missing/widget.json"))
        XCTAssertNotNil(host.widgetSharingError)
        XCTAssertEqual(host.widgetSnapshot().totalCostUSD, 0)
        XCTAssertNil(host.widgetSnapshot().updatedAt)
    }

    @MainActor
    func testRestartRestoresLastLocalValuesWhenFirstCollectionFails() throws {
        let usageFile = root.appendingPathComponent("usage.json")
        try JSONEncoder().encode(usage).write(to: usageFile)
        let restarted = monitor()
        restarted.restoreLocalSnapshot(from: usageFile)
        let previous = restarted.widgetSnapshot()
        XCTAssertEqual(restarted.lastUpdated, previous.updatedAt)
        restarted.collectionError = "Synthetic first-refresh failure"
        let cache = root.appendingPathComponent("widget.json")
        restarted.publishWidgetSnapshot(to: cache)
        let failed = SharedStore.loadWidgetSnapshot(from: cache)
        XCTAssertTrue(failed.hasData)
        XCTAssertTrue(failed.updateFailed)
        XCTAssertEqual(failed.allServices, previous.allServices)
        XCTAssertEqual(failed.updatedAt, previous.updatedAt)
        XCTAssertEqual(failed.totalCostUSD, previous.totalCostUSD)
    }

    @MainActor
    func testSettingsNotificationRepublishesWithoutACollectorOrNetworkRefresh() async throws {
        let host = monitor()
        host.applyLocalSnapshot(usage)
        let cache = root.appendingPathComponent("widget.json")
        host.publishWidgetSnapshot(to: cache)
        host.observeWidgetSettings(to: cache)
        host.showGeminiSection = false
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache).allServices.map(\.id), ["openai"])
    }
}
