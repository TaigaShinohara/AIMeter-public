import XCTest
import AIMeterCore

final class AntigravityWidgetExpiryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var cache: URL { root.appendingPathComponent("widget.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func quota(_ id: String = "antigravity", expiry: Int? = 1_800_000_120,
                       reset: Int? = nil, ratio: Double = 0.1) -> WidgetServiceItem {
        .init(id: id, name: "Antigravity", shortName: "AG", iconName: "sparkles",
              remainingPercent: Int((ratio * 100).rounded()), remainingRatio: ratio,
              usedTokens: 0, limitTokens: 0, usedDisplay: "", limitDisplay: "", unit: "",
              bottleneckPeriod: .weekly, resetText: "Resets next week", resetTimestamp: reset,
              remainingSource: .official, quotaWindowLabel: "Gemini · 週次", isQuotaOnly: true,
              quotaExpiresAt: expiry)
    }

    private func ordinary() throws -> WidgetServiceItem {
        try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens",
            metrics: [.init(period: .weekly, usedTokens: 50, limitTokens: 100, serverUsedPercent: 50)]
        ))
    }

    private func snapshot(_ items: [WidgetServiceItem]) -> AIMeterWidgetSnapshot {
        .make(services: items, totalCostUSD: 2.5, updatedAt: now, hasData: true,
              updateFailed: true, showUsageAmounts: true)
    }

    func testFreshQuotaRoundTripsAllMetadataAndPrivateCache() throws {
        let original = snapshot([quota()])
        XCTAssertEqual(original.expiringQuotas(at: now), original)
        XCTAssertEqual(try JSONDecoder().decode(AIMeterWidgetSnapshot.self,
                                               from: JSONEncoder().encode(original)), original)
        try SharedStore.saveWidgetSnapshot(original, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache, at: now), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let item = try XCTUnwrap(original.allServices.first)
        XCTAssertEqual(item.quotaExpiresAt, 1_800_000_120)
        XCTAssertEqual(item.quotaWindowLabel, "Gemini · 週次")
        XCTAssertEqual(item.remainingSource, .official)
        XCTAssertTrue(item.usedDisplay.isEmpty)
        XCTAssertTrue(item.limitDisplay.isEmpty)
    }

    func testQuotaExpiresAtExactBoundaryAndReordersAllRedundantLists() throws {
        let normal = try ordinary()
        let original = snapshot([normal, quota()])
        XCTAssertEqual(original.mostCriticalService?.id, "antigravity")
        XCTAssertEqual(original.expiringQuotas(at: now.addingTimeInterval(119)).allServices.first?.id, "antigravity")
        let expired = original.expiringQuotas(at: now.addingTimeInterval(120))
        XCTAssertEqual(expired.mostCriticalService, normal)
        XCTAssertEqual(expired.allServices.map(\.id), ["openai", "antigravity"])
        XCTAssertEqual(expired.topServices, expired.allServices)
        let unavailable = try XCTUnwrap(expired.allServices.last)
        XCTAssertEqual(unavailable.remainingSource, .unavailable)
        XCTAssertEqual(unavailable.remainingRatio, 0)
        XCTAssertEqual(unavailable.remainingPercent, 0)
        XCTAssertEqual(unavailable.usedTokens, 0)
        XCTAssertEqual(unavailable.limitTokens, 0)
        XCTAssertTrue(unavailable.usedDisplay.isEmpty)
        XCTAssertTrue(unavailable.limitDisplay.isEmpty)
        XCTAssertEqual(unavailable.quotaWindowLabel, "Gemini · 週次")
        XCTAssertEqual(expired.updatedAt, now)
        XCTAssertEqual(expired.totalCostUSD, 0)
        XCTAssertTrue(expired.showUsageAmounts)
        XCTAssertTrue(expired.updateFailed)
        XCTAssertEqual(expired.expiringQuotas(at: now.addingTimeInterval(180)), expired)
    }

    func testMissingExpiryFailsClosedEvenForApparentlyFullQuota() throws {
        let original = snapshot([quota(expiry: nil, ratio: 1)])
        let expired = original.expiringQuotas(at: now)
        XCTAssertNil(expired.mostCriticalService)
        XCTAssertEqual(expired.allServices.first?.remainingSource, .unavailable)
        XCTAssertEqual(expired.allServices.first?.remainingPercent, 0)
        XCTAssertTrue(expired.hasData)
        try SharedStore.saveWidgetSnapshot(original, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache, at: now), expired)
    }

    func testDecodingMissingExpiryPropertyAlsoFailsClosedAfterValidation() throws {
        let original = snapshot([quota(expiry: nil)])
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: cache)
        let loaded = SharedStore.loadWidgetSnapshot(from: cache, at: now)
        XCTAssertTrue(loaded.hasData)
        XCTAssertEqual(loaded.schemaVersion, 4)
        XCTAssertNil(loaded.mostCriticalService)
        XCTAssertEqual(loaded.allServices.first?.remainingSource, .unavailable)
    }

    func testResetTimeCanExpireBeforeFreshnessDeadline() throws {
        let item = quota(reset: 1_800_000_030)
        XCTAssertEqual(item.quotaExpirationDate, now.addingTimeInterval(30))
        let original = snapshot([item])
        XCTAssertEqual(original.expiringQuotas(at: now.addingTimeInterval(29)), original)
        XCTAssertEqual(original.expiringQuotas(at: now.addingTimeInterval(30)).allServices.first?.remainingSource,
                       .unavailable)
    }

    func testOrdinaryServicesNeverExpireThroughQuotaCachePolicy() throws {
        let normal = try ordinary()
        let original = snapshot([normal])
        XCTAssertNil(normal.quotaExpirationDate)
        XCTAssertEqual(original.expiringQuotas(at: now.addingTimeInterval(10_000_000)), original)
        try SharedStore.saveWidgetSnapshot(original, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache, at: now.addingTimeInterval(10_000_000)), original)
    }

    func testDifferentExpiriesAreAppliedIndependentlyAndKnownZeroStaysOfficialUntilExpiry() throws {
        let original = snapshot([quota("ag-a", expiry: 1_800_000_030, ratio: 0),
                                 quota("ag-b", expiry: 1_800_000_060, ratio: 0.2), try ordinary()])
        XCTAssertEqual(original.mostCriticalService?.id, "ag-a")
        XCTAssertEqual(original.allServices.first?.remainingSource, .official)
        let firstExpired = original.expiringQuotas(at: now.addingTimeInterval(30))
        XCTAssertEqual(firstExpired.mostCriticalService?.id, "ag-b")
        let bothExpired = original.expiringQuotas(at: now.addingTimeInterval(60))
        XCTAssertEqual(bothExpired.mostCriticalService?.id, "openai")
        XCTAssertEqual(bothExpired.allServices.map(\.id), ["openai", "ag-a", "ag-b"])
    }

    func testInvalidRawCacheIsRejectedBeforeExpiryCanNormalizeIt() throws {
        let original = snapshot([quota(expiry: 1_799_999_999)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["allServices", "topServices"] {
            var items = try XCTUnwrap(object[key] as? [[String: Any]])
            items[0]["remainingRatio"] = 2.0
            items[0]["remainingPercent"] = 200
            object[key] = items
        }
        var critical = try XCTUnwrap(object["mostCriticalService"] as? [String: Any])
        critical["remainingRatio"] = 2.0
        critical["remainingPercent"] = 200
        object["mostCriticalService"] = critical
        try JSONSerialization.data(withJSONObject: object).write(to: cache)
        XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: cache, at: now).hasData)
    }

    func testInvalidExpiryAndFabricatedQuotaAmountsCannotBeSaved() throws {
        XCTAssertThrowsError(try SharedStore.saveWidgetSnapshot(snapshot([quota(expiry: -1)]), to: cache))
        let amounts = WidgetServiceItem(
            id: "antigravity", name: "Antigravity", shortName: "AG", iconName: "sparkles",
            remainingPercent: 10, remainingRatio: 0.1, usedTokens: 1, limitTokens: 10,
            usedDisplay: "1", limitDisplay: "10", unit: "tokens", bottleneckPeriod: nil,
            remainingSource: .official, isQuotaOnly: true, quotaExpiresAt: 1_800_000_120
        )
        XCTAssertThrowsError(try SharedStore.saveWidgetSnapshot(snapshot([amounts]), to: cache))
    }

    func testQuotaMetricsNeverExposeSyntheticTokenAmounts() throws {
        let item = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "antigravity", name: "Antigravity", shortName: "AG", iconName: "sparkles", unit: "tokens",
            metrics: [.init(period: nil, usedTokens: 500, limitTokens: 1_000, serverUsedPercent: 90,
                            requiresOfficialQuota: true, quotaWindowID: "gemini-weekly",
                            quotaWindowLabel: "Gemini · 週次", isQuotaOnly: true,
                            quotaExpiresAt: 1_800_000_120)]
        ))
        XCTAssertEqual(item.remainingPercent, 10)
        XCTAssertEqual(item.usedTokens, 0)
        XCTAssertEqual(item.limitTokens, 0)
        XCTAssertEqual(item.usedDisplay, "")
        XCTAssertEqual(item.limitDisplay, "")
        XCTAssertEqual(item.quotaExpiresAt, 1_800_000_120)
    }

    func testEmptySnapshotRetainsPreferencesWhenExpiring() {
        let empty = AIMeterWidgetSnapshot.empty(updateFailed: true, showUsageAmounts: true)
        XCTAssertEqual(empty.expiringQuotas(at: now), empty)
    }
}
