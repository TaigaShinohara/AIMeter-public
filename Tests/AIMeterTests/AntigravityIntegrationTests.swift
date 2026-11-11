import XCTest
import AIMeterCore
@testable import AIMeter

final class AntigravityIntegrationTests: XCTestCase {
    #if AIMETER_APP_STORE
    func testStoreDoesNotAttemptAntigravityDiscovery() async {
        do {
            _ = try await AntigravityQuotaClient.fetch()
            XCTFail("Store builds must not attempt unverified discovery")
        } catch let failure as AntigravityQuotaClient.Failure {
            XCTAssertEqual(failure, .unsupportedInStore)
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
    }
    #endif

    func testOptInLiveReadOnlyQuotaFetch() async throws {
        guard ProcessInfo.processInfo.environment["AIMETER_VERIFY_ANTIGRAVITY"] == "1" else {
            throw XCTSkip("Live read requires an explicitly enabled local verification run")
        }
        let snapshot = try await AntigravityQuotaClient.fetch()
        XCTAssertFalse(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.windows.contains { $0.remainingFraction != nil })
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.remainingFraction.map { $0.isFinite && (0...1).contains($0) } ?? true })
    }

    @MainActor
    private func monitor() throws -> (UsageMonitor, UserDefaults, String) {
        let suite = "AIMeter-Antigravity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (UsageMonitor(defaults: defaults, startMonitoring: false), defaults, suite)
    }

    private func snapshot(at now: Date) -> AntigravityQuotaSnapshot {
        .init(windows: [
            .init(id: "gemini-5h", title: "Gemini・5時間", period: .fiveHours, remainingFraction: 0.8),
            .init(id: "gemini-week", title: "Gemini・週次", period: .weekly, remainingFraction: 0.4),
            .init(id: "claude-5h", title: "Claude・5時間", period: .fiveHours, remainingFraction: 0),
            .init(id: "unknown", title: "Other model", remainingFraction: nil)
        ], fetchedAt: now)
    }

    @MainActor
    func testQuotaDoesNotReplaceGeminiLogsOrInventTokenAllowance() async throws {
        let (host, defaults, suite) = try monitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        host.showAntigravitySection = true
        host.geminiUsedTokens = 1234
        await host.refreshAntigravityQuota { self.snapshot(at: now) }
        let metrics = host.antigravityMetrics(at: now)
        XCTAssertEqual(metrics.count, 4)
        XCTAssertEqual(Set(metrics.map(\.id)).count, 4)
        XCTAssertEqual(metrics.map(\.remainingSource), [.official, .official, .official, .unavailable])
        XCTAssertEqual(metrics.map(\.remainingPercent), [80, 40, 0, 0])
        XCTAssertTrue(metrics.allSatisfy { $0.usedTokens == 0 && $0.limitTokens == 0 && $0.isQuotaOnly })
        XCTAssertNil(metrics.last?.period)
        XCTAssertEqual(host.geminiUsedTokens, 1234)
        XCTAssertTrue(host.geminiMetrics.allSatisfy { $0.remainingSource == .unavailable })
        for metric in metrics {
            let row = PeriodLimitRowView(metric: metric, isHighlighted: false, showUsageAmounts: true)
            XCTAssertFalse(row.accessibilityUsageValue.contains("tokens"))
            XCTAssertFalse(row.accessibilityUsageValue.contains("目安"))
        }
        let summary = ProviderUsageSection(title: "Antigravity", subtitle: "", usedCostUSD: 0,
                                          budgetUSD: 0, metrics: metrics, highlightedPeriod: nil, isDetailed: false)
        XCTAssertEqual(summary.displayedMetrics, metrics)
    }

    @MainActor
    func testFailureClearsQuotaDisabledDoesNotFetchAndSettingsPersist() async throws {
        let (host, defaults, suite) = try monitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(host.showAntigravitySection)
        await host.refreshAntigravityQuota { XCTFail("Disabled service must not probe"); throw CancellationError() }
        host.showAntigravitySection = true
        await host.refreshAntigravityQuota { self.snapshot(at: Date()) }
        XCTAssertNotNil(host.antigravityQuota)
        await host.refreshAntigravityQuota { throw CancellationError() }
        XCTAssertNil(host.antigravityQuota)
        XCTAssertTrue(host.antigravityMetrics.allSatisfy { !$0.isRemainingAvailable })
        let restarted = UsageMonitor(defaults: defaults, startMonitoring: false)
        XCTAssertTrue(restarted.showAntigravitySection)
        XCTAssertNil(restarted.antigravityQuota)
    }

    @MainActor
    func testOldFutureAndPassedResetValuesAreUnavailable() throws {
        let (host, defaults, suite) = try monitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        for offset in [-121.0, 6.0] {
            host.antigravityQuota = snapshot(at: now.addingTimeInterval(offset))
            XCTAssertTrue(host.antigravityMetrics(at: now).allSatisfy { !$0.isRemainingAvailable })
        }
        host.antigravityQuota = .init(windows: [
            .init(id: "reset", title: "Gemini", remainingFraction: 0, resetAt: now.addingTimeInterval(-1)),
            .init(id: "valid", title: "Claude", remainingFraction: 1, resetAt: now.addingTimeInterval(60)),
            .init(id: "disabled", title: "Other", remainingFraction: 1, isDisabled: true)
        ], fetchedAt: now)
        XCTAssertEqual(host.antigravityMetrics(at: now).map(\.isRemainingAvailable), [false, true, false])
        XCTAssertEqual(host.antigravityMetrics(at: now)[1].quotaExpiresAt,
                       Int(now.addingTimeInterval(60).timeIntervalSince1970))
    }

    @MainActor
    func testMenuSelectsLowestQuotaOfRequestedCadenceAndWidgetKeepsIdentity() async throws {
        let (host, defaults, suite) = try monitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        host.showOpenAISection = false
        host.showGeminiSection = false
        host.customSubscriptions = []
        host.showAntigravitySection = true
        await host.refreshAntigravityQuota { self.snapshot(at: Date()) }
        XCTAssertEqual(AIMeterCardView(monitor: host, isMenuBar: false).totalVisibleProvidersCount, 1)
        host.menuBarDisplayMode = "all"
        host.menuBarPeriodMode = "5h"
        XCTAssertEqual(host.menuBarTitle, "AG:0%")
        host.menuBarPeriodMode = "7d"
        XCTAssertEqual(host.menuBarTitle, "AG:40%")
        XCTAssertEqual(host.activeBottlenecks.first?.remainingPercent, 40)
        host.menuBarPeriodMode = "30d"
        XCTAssertEqual(host.menuBarTitle, "AG:未取得")
        host.menuBarPeriodMode = "min"
        let widget = host.widgetSnapshot()
        let item = try XCTUnwrap(widget.mostCriticalService)
        XCTAssertEqual(item.id, "antigravity")
        XCTAssertEqual(item.quotaWindowLabel, "Claude・5時間")
        XCTAssertTrue(item.isQuotaOnly)
        XCTAssertEqual(item.remainingPercent, 0)
        XCTAssertEqual(item.remainingSource, .official)
    }
}
