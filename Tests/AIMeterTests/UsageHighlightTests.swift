import XCTest
import AIMeterCore
@testable import AIMeter

final class UsageHighlightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_340_000)

    private func service(_ id: String = "codex", remaining: Double, period: LimitPeriod = .weekly,
                         official: Bool = true) -> HighlightService {
        .init(id: id, name: id, metrics: [.init(period: period, usedTokens: Int(100 - remaining), limitTokens: 100,
                                              serverUsedPercent: official ? 100 - remaining : nil)])
    }

    private func resolve(_ services: [HighlightService], age: TimeInterval = 0, refreshing: Bool = false,
                         failed: Bool = false, hasData: Bool = true) -> UsageHighlight {
        .resolve(services: services, hasData: hasData, updatedAt: now.addingTimeInterval(-age),
                 isRefreshing: refreshing, updateFailed: failed, now: now)
    }

    func testThresholdsUseUnroundedRatioAndMatchGaugeSemantics() {
        for (remaining, tone) in [(0.0, UsageHighlight.Tone.urgent), (14.99, .urgent),
                                  (15, .attention), (34.99, .attention), (35, .calm)] {
            XCTAssertEqual(resolve([service(remaining: remaining)]).tone, tone, "remaining=\(remaining)")
        }
        let tiny = resolve([service(remaining: 0.1)])
        XCTAssertTrue(tiny.message.contains("1%未満"))
        XCTAssertFalse(tiny.message.contains("残り0%"))
    }

    func testLowestEnabledPeriodWinsWithStableServiceAndPeriodTieBreaks() {
        let a = HighlightService(id: "a", name: "A", metrics: [
            .init(period: .monthly, usedTokens: 90, limitTokens: 100),
            .init(period: .fiveHours, usedTokens: 90, limitTokens: 100)
        ])
        let b = service("b", remaining: 10)
        XCTAssertEqual(resolve([b, a]), resolve([a, b]))
        XCTAssertEqual(resolve([b, a]).serviceID, "a")
        XCTAssertTrue(resolve([b, a]).message.contains("5時間"))
        XCTAssertEqual(resolve([a, service("c", remaining: 9.9)]).serviceID, "c")
    }

    func testUnknownAndInvalidDoNotHideKnownLowQuotaOrTurnIntoZero() {
        let unknown = HighlightService(id: "gemini", name: "Gemini", metrics: [
            .init(period: .monthly, usedTokens: 100, limitTokens: 100, requiresOfficialQuota: true)
        ])
        let invalid = HighlightService(id: "invalid", name: "Invalid", metrics: [
            .init(period: .daily, usedTokens: 0, limitTokens: 100, serverUsedPercent: .nan)
        ])
        let message = resolve([unknown, invalid, service(remaining: 12)])
        XCTAssertEqual(message.serviceID, "codex")
        XCTAssertTrue(message.message.contains("12%"))
        XCTAssertTrue(message.detail?.contains("未取得") == true)
        XCTAssertTrue(message.detail?.contains("数値") == true)
        for services in [[unknown], [invalid], [unknown, service(remaining: 90)]] {
            let result = resolve(services)
            XCTAssertNil(result.serviceID)
            XCTAssertFalse(result.message.contains("35%以上"))
            XCTAssertFalse(result.message.contains("0%"))
        }
        let zero = resolve([unknown, service(remaining: 0)])
        XCTAssertTrue(zero.message.contains("残り0%"))
        XCTAssertFalse(zero.message.contains("利用不可"))
    }

    func testInvalidAndUnavailablePeriodsAreRetainedWithinAnOtherwiseHealthyService() {
        let mixed = HighlightService(id: "mixed", name: "Mixed", metrics: [
            .init(period: .daily, usedTokens: 0, limitTokens: 100),
            .init(period: .weekly, usedTokens: -1, limitTokens: 100),
            .init(period: .monthly, usedTokens: 0, limitTokens: 100, requiresOfficialQuota: true)
        ])
        XCTAssertEqual(resolve([mixed]).tone, .checking)
        XCTAssertEqual(resolve([.init(id: "empty", name: "Empty", metrics: [])]).tone, .checking)
    }

    func testEstimatedQuotaIsQualifiedInMainSentenceIncludingZero() {
        for remaining in [0.0, 12.0] {
            let result = resolve([service(remaining: remaining, official: false)])
            XCTAssertTrue(result.message.contains("設定上限の目安"))
            XCTAssertFalse(result.message.contains("利用不可"))
        }
        XCTAssertFalse(resolve([service(remaining: 12)]).message.contains("目安"))
        XCTAssertTrue(resolve([service(remaining: 90, official: false)]).message.contains("目安"))
    }

    func testInitialAndDisabledStatesNeverInventQuota() {
        XCTAssertTrue(resolve([], refreshing: true, hasData: false).message.contains("設定"))
        let services = [service(remaining: 0)]
        for (refreshing, failed, expectedTitle) in [(true, false, "確認中"), (false, true, "取得できなかったよ"),
                                                    (false, false, "こんにちは")] {
            let result = resolve(services, refreshing: refreshing, failed: failed, hasData: false)
            XCTAssertEqual(result.title, expectedTitle)
            XCTAssertNil(result.serviceID)
            XCTAssertFalse(result.message.contains("%"))
        }
    }

    func testLowQuotaSurvivesRefreshFailureAndAgeWithPastTense() {
        for result in [resolve([service(remaining: 12)], refreshing: true),
                       resolve([service(remaining: 12)], failed: true),
                       resolve([service(remaining: 12)], age: 300)] {
            XCTAssertEqual(result.tone, .urgent)
            XCTAssertEqual(result.serviceID, "codex")
            XCTAssertTrue(result.message.contains("前回は"))
            XCTAssertNotNil(result.detail)
        }
        XCTAssertFalse(resolve([service(remaining: 12)], age: 299).message.contains("前回は"))
        for result in [resolve([service(remaining: 90)], failed: true),
                       resolve([service(remaining: 90)], age: 300),
                       resolve([service(remaining: 90)], age: -1)] {
            XCTAssertFalse(result.message.contains("35%以上"))
            XCTAssertTrue(result.message.contains("更新"))
        }
        let noTime = UsageHighlight.resolve(services: [service(remaining: 90)], hasData: true,
                                           updatedAt: nil, isRefreshing: false, updateFailed: false, now: now)
        XCTAssertFalse(noTime.message.contains("35%以上"))
    }

    func testPassedResetDoesNotInventRecoveredQuota() {
        let expired = HighlightService(id: "expired", name: "Expired", metrics: [
            .init(period: .fiveHours, usedTokens: 0, limitTokens: 100, serverUsedPercent: 88,
                  resetTimestamp: Int(now.timeIntervalSince1970) - 1)
        ])
        let result = resolve([expired])
        XCTAssertTrue(result.message.contains("前回は"))
        XCTAssertTrue(result.message.contains("12%"))
        XCTAssertTrue(result.detail?.contains("リセット予定") == true)
    }

    @MainActor
    func testHostUsesVisibleServicesAndPeriodsIndependentlyOfMenuTitleAndViewMode() throws {
        let suite = "AIMeter-Highlight-Test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "didAutoSeedLocalProvidersV2")
        defaults.set(true, forKey: "didMigrateHonestCostsV3")
        let host = UsageMonitor(defaults: defaults, startMonitoring: false)
        host.showGeminiSection = false
        host.showOpenAIInMenuBar = false
        host.openaiEnabledPeriodsCSV = "5h"
        host.openaiTokenLimit5h = 100
        host.openaiTokenLimitWeekly = 100
        host.openaiUsed5h = 88
        host.openaiUsedWeekly = 100
        host.recordUsageUpdate(at: now)
        let result = host.characterHighlight(at: now)
        XCTAssertEqual(result.serviceID, "openai")
        XCTAssertTrue(result.message.contains("5時間"))
        XCTAssertTrue(result.message.contains("12%"))
        host.isDetailedView = true
        host.menuBarPeriodMode = "7d"
        XCTAssertEqual(host.characterHighlight(at: now), result)
        host.showOpenAISection = false
        XCTAssertNil(host.characterHighlight(at: now).serviceID)
        XCTAssertTrue(host.characterHighlight(at: now).message.contains("設定"))
    }
}
