import XCTest
import AIMeterCore
@testable import AIMeter

final class UsagePresentationTests: XCTestCase {
    @MainActor
    func testAmountsDefaultOffAndPersistWithoutChangingPeriodSelection() throws {
        let suite = "AIMeter-Presentation-Test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false)
        XCTAssertFalse(monitor.showUsageAmounts)
        XCTAssertFalse(monitor.widgetSnapshot().showUsageAmounts)
        monitor.isDetailedView = true
        monitor.showUsageAmounts = true
        monitor.applyLocalSnapshot(.init(openaiUsedTokens: 25, openaiCostUSD: 0,
                                        geminiUsedTokens: 0, geminiCostUSD: 0))
        XCTAssertTrue(monitor.widgetSnapshot().showUsageAmounts)
        let restarted = UsageMonitor(defaults: defaults, startMonitoring: false)
        XCTAssertTrue(restarted.showUsageAmounts)
        XCTAssertTrue(restarted.isDetailedView)
        restarted.showUsageAmounts = false
        XCTAssertTrue(restarted.isDetailedView)
    }

    @MainActor
    func testAccessibilityFollowsVisibleAmountsAndRetainsInvalidState() {
        let metric = PeriodUsageMetric(period: .fiveHours, usedTokens: 25, limitTokens: 100)
        let percentageOnly = PeriodLimitRowView(metric: metric, isHighlighted: false)
        XCTAssertEqual(percentageOnly.accessibilityUsageValue, "設定上限からの目安、残り 75パーセント")
        let requests = PeriodLimitRowView(metric: metric, isHighlighted: false,
                                         unit: "req", showUsageAmounts: true)
        XCTAssertFalse(requests.accessibilityUsageValue.contains("25"))
        XCTAssertTrue(requests.accessibilityUsageValue.contains("75 req"))
        let invalid = PeriodUsageMetric(period: .fiveHours, usedTokens: -1, limitTokens: 100)
        for showAmounts in [false, true] {
            let row = PeriodLimitRowView(metric: invalid, isHighlighted: false,
                                         showUsageAmounts: showAmounts)
            XCTAssertEqual(row.accessibilityUsageValue, "数値エラー")
        }
    }
}
