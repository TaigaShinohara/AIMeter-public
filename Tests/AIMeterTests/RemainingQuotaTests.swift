import XCTest
import AIMeterCore
@testable import AIMeter

final class RemainingQuotaTests: XCTestCase {
    func testWidgetKeepsOfficialZeroCriticalBesideUnknownGeminiAfterReload() throws {
        let official = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "GPT", iconName: "cpu", unit: "tokens",
            metrics: [.init(period: .fiveHours, usedTokens: 100, limitTokens: 100,
                            serverUsedPercent: 100)]
        ))
        let unknown = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "gemini", name: "Gemini", shortName: "Gem", iconName: "sparkle", unit: "tokens",
            metrics: [.init(period: .monthly, usedTokens: 45_000_000, limitTokens: 40_000_000,
                            requiresOfficialQuota: true)]
        ))
        let snapshot = AIMeterWidgetSnapshot.make(services: [unknown, official], totalCostUSD: 0,
                                                  updatedAt: Date(), hasData: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("widget.json")
        try SharedStore.saveWidgetSnapshot(snapshot, to: cache)
        let restored = SharedStore.loadWidgetSnapshot(from: cache)
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.mostCriticalService?.id, "openai")
        XCTAssertEqual(restored.mostCriticalService?.remainingSource, .official)
        XCTAssertEqual(restored.mostCriticalService?.remainingPercent, 0)
        XCTAssertEqual(restored.allServices.last?.remainingSource, .unavailable)
    }

    func testOfficialZeroIsDifferentFromMissingQuotaAndConfiguredEstimate() {
        let missing = PeriodUsageMetric(period: .weekly, usedTokens: 45_000_000,
                                       limitTokens: 15_000_000, requiresOfficialQuota: true)
        XCTAssertTrue(missing.isValid)
        XCTAssertFalse(missing.isRemainingAvailable)
        XCTAssertEqual(missing.remainingSource, .unavailable)
        XCTAssertEqual(missing.remainingSource.percentText(missing.remainingPercent), "未取得")
        var official = missing
        official.serverUsedPercent = 100
        XCTAssertTrue(official.isRemainingAvailable)
        XCTAssertEqual(official.remainingSource, .official)
        XCTAssertEqual(official.remainingSource.percentText(official.remainingPercent), "0%")
        official.serverUsedPercent = 0
        XCTAssertEqual(official.remainingSource.percentText(official.remainingPercent), "100%")
        var invalid = missing
        invalid.usedTokens = -1
        XCTAssertFalse(invalid.isValid)
        XCTAssertFalse(invalid.isRemainingAvailable)
        let configured = PeriodUsageMetric(period: .weekly, usedTokens: 25, limitTokens: 100)
        XCTAssertEqual(configured.remainingSource.percentText(configured.remainingPercent), "約75%")
    }

    @MainActor
    func testGeminiRemainsUnknownAtAnyUsageOrConfiguredLimitAcrossMenuModes() throws {
        let suite = "AIMeter-Quota-Test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UsageMonitor(defaults: defaults, startMonitoring: false)
        host.showOpenAISection = false
        host.geminiUsedTokens = 45_000_000
        host.geminiUsedWeekly = 44_000_000
        host.geminiTokenLimit = 1
        host.geminiTokenLimitWeekly = 100_000_000
        XCTAssertTrue(host.geminiMetrics.allSatisfy { $0.isValid && !$0.isRemainingAvailable })
        XCTAssertTrue(host.activeBottlenecks.isEmpty)
        XCTAssertNil(host.activeMetric(for: host.geminiMetrics))
        for mode in MenuBarDisplayMode.allCases {
            host.menuBarDisplayMode = mode.rawValue
            XCTAssertTrue(host.menuBarTitle.contains("未取得"), mode.rawValue)
            XCTAssertFalse(host.menuBarTitle.contains("%"), mode.rawValue)
            XCTAssertFalse(host.menuBarTitle.contains("⚠"), mode.rawValue)
        }
        host.menuBarPeriodMode = "7d"
        XCTAssertNil(host.activeMetric(for: host.geminiMetrics))
        host.showOpenAISection = true
        host.openaiServerPct = .init(fiveHours: 100)
        host.openaiEnabledPeriodsCSV = "5h"
        host.menuBarDisplayMode = MenuBarDisplayMode.smart.rawValue
        XCTAssertTrue(host.menuBarTitle.contains("GPT 残0%"))
        XCTAssertEqual(host.activeBottlenecks.map(\.id), ["openai"])
        host.menuBarDisplayMode = MenuBarDisplayMode.all.rawValue
        XCTAssertTrue(host.menuBarTitle.contains("Gem:未取得"))
        XCTAssertTrue(host.menuBarTitle.contains("GPT:0%"))
    }

    @MainActor
    func testUnknownRowsKeepUsageSeparateAndErrorsDistinct() {
        let missing = PeriodUsageMetric(period: .monthly, usedTokens: 500,
                                       limitTokens: 100, requiresOfficialQuota: true)
        let row = PeriodLimitRowView(metric: missing, isHighlighted: false)
        XCTAssertEqual(row.accessibilityUsageValue, "公式残量は未取得")
        let withUsage = PeriodLimitRowView(metric: missing, isHighlighted: false, showUsageAmounts: true)
        XCTAssertTrue(withUsage.accessibilityUsageValue.contains("推定使用量 500 tokens"))
        XCTAssertFalse(withUsage.accessibilityUsageValue.contains("パーセント"))
        var invalid = missing
        invalid.usedTokens = -1
        XCTAssertEqual(PeriodLimitRowView(metric: invalid, isHighlighted: false).accessibilityUsageValue, "数値エラー")
        let summary = ProviderUsageSection(title: "Gemini", subtitle: "実ログ", usedCostUSD: 0,
                                          budgetUSD: 0, metrics: [missing], highlightedPeriod: nil,
                                          isDetailed: false)
        XCTAssertEqual(summary.displayedMetrics, [missing])
    }
}
