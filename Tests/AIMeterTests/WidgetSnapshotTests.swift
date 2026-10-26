import XCTest
import AIMeterCore

final class WidgetSnapshotTests: XCTestCase {
    private var root: URL!
    private var cache: URL { root.appendingPathComponent("widget.json") }
    private let updatedAt = Date(timeIntervalSince1970: 1_792_400_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func item(_ id: String = "gemini", used: Int = 60) throws -> WidgetServiceItem {
        try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: id, name: id, shortName: id, iconName: "cpu", unit: "tokens",
            metrics: [PeriodUsageMetric(period: .weekly, usedTokens: used, limitTokens: 100)]
        ))
    }

    private func unavailableItem(_ id: String = "gemini", used: Int = 60) throws -> WidgetServiceItem {
        try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: id, name: id, shortName: id, iconName: "cpu", unit: "tokens",
            metrics: [PeriodUsageMetric(period: .monthly, usedTokens: used, limitTokens: 100,
                                        requiresOfficialQuota: true)]
        ))
    }

    private func legacyObject(from snapshot: AIMeterWidgetSnapshot) throws -> [String: Any] {
        let data = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 1
        for key in ["allServices", "topServices"] {
            var services = try XCTUnwrap(object[key] as? [[String: Any]])
            for index in services.indices { services[index].removeValue(forKey: "remainingSource") }
            object[key] = services
        }
        if var critical = object["mostCriticalService"] as? [String: Any] {
            critical.removeValue(forKey: "remainingSource")
            object["mostCriticalService"] = critical
        }
        return object
    }

    func testMissingCorruptAndLegacyCachesRemainEmptyWithoutSampleValues() throws {
        for bytes in [nil, Data("{bad".utf8), Data("{\"openaiUsedByPeriod\":{\"5h\":50}}".utf8)] {
            if let bytes { try bytes.write(to: cache) }
            let snapshot = SharedStore.loadWidgetSnapshot(from: cache)
            XCTAssertFalse(snapshot.hasData)
            XCTAssertTrue(snapshot.allServices.isEmpty)
            XCTAssertNil(snapshot.updatedAt)
            XCTAssertEqual(snapshot.totalCostUSD, 0)
        }
    }

    func testRoundTripKeepsHostValuesAndWritesPrivateFile() throws {
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [try item("cursor", used: 40), try item("gemini", used: 80)],
            totalCostUSD: 2.75, updatedAt: updatedAt, hasData: true, updateFailed: true,
            showUsageAmounts: true
        )
        try SharedStore.saveWidgetSnapshot(snapshot, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), snapshot)
        XCTAssertTrue(SharedStore.loadWidgetSnapshot(from: cache).showUsageAmounts)
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["widget.json"])
        let replacement = AIMeterWidgetSnapshot.make(
            services: [try item("gemini", used: 10)], totalCostUSD: 1,
            updatedAt: updatedAt.addingTimeInterval(60), hasData: true
        )
        try SharedStore.saveWidgetSnapshot(replacement, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), replacement)
    }

    func testLegacySnapshotWithoutUsageAmountPreferenceKeepsHostValues() throws {
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 2.75,
            updatedAt: updatedAt, hasData: true, updateFailed: true
        )
        let data = try JSONEncoder().encode(snapshot)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "showUsageAmounts")
        try JSONSerialization.data(withJSONObject: legacy).write(to: cache)

        let restored = SharedStore.loadWidgetSnapshot(from: cache)
        XCTAssertEqual(restored, snapshot)
        XCTAssertFalse(restored.showUsageAmounts)
        XCTAssertTrue(restored.hasData)
        XCTAssertTrue(restored.updateFailed)
    }

    func testUsageAmountPreferenceDefaultsOffAndSurvivesEmptySnapshots() throws {
        XCTAssertFalse(AIMeterWidgetSnapshot.empty().showUsageAmounts)
        XCTAssertFalse(AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 1, updatedAt: updatedAt, hasData: true
        ).showUsageAmounts)

        let empty = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 1, updatedAt: updatedAt,
            hasData: false, updateFailed: true, showUsageAmounts: true
        )
        XCTAssertEqual(empty, .empty(updateFailed: true, showUsageAmounts: true))
        XCTAssertTrue(empty.showUsageAmounts)
        try SharedStore.saveWidgetSnapshot(empty, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), empty)
    }

    func testEmptyServiceSelectionIsDistinctFromNoSuccessfulData() throws {
        let disabled = AIMeterWidgetSnapshot.make(
            services: [], totalCostUSD: 0, updatedAt: updatedAt, hasData: true
        )
        try SharedStore.saveWidgetSnapshot(disabled, to: cache)
        let read = SharedStore.loadWidgetSnapshot(from: cache)
        XCTAssertTrue(read.hasData)
        XCTAssertTrue(read.allServices.isEmpty)
        XCTAssertEqual(read.updatedAt, updatedAt)

        let noData = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 20, updatedAt: updatedAt,
            hasData: false, updateFailed: true
        )
        XCTAssertEqual(noData, .empty(updateFailed: true))
        try SharedStore.saveWidgetSnapshot(noData, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), noData)
    }

    func testMalformedPresentationCannotSupplyMetersOrFalseUpdateTime() throws {
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 1, updatedAt: updatedAt, hasData: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("schemaVersion", 3 as Any), ("totalCostUSD", -1),
                             ("updatedAt", "invalid"), ("hasData", false),
                             ("showUsageAmounts", "invalid"),
                             ("allServices", [] as [Any])] {
            var invalid = original
            invalid[key] = value
            try JSONSerialization.data(withJSONObject: invalid).write(to: cache)
            XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: cache).hasData, key)
        }
        var invalid = original
        var services = try XCTUnwrap(invalid["allServices"] as? [[String: Any]])
        services[0]["remainingRatio"] = 2.0
        invalid["allServices"] = services
        try JSONSerialization.data(withJSONObject: invalid).write(to: cache)
        XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: cache).hasData)
    }

    func testInvalidWritePreservesPreviousCacheAndSymlinkTarget() throws {
        let previous = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 2, updatedAt: updatedAt, hasData: true
        )
        try SharedStore.saveWidgetSnapshot(previous, to: cache)
        let invalid = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: -1, updatedAt: updatedAt, hasData: true
        )
        XCTAssertThrowsError(try SharedStore.saveWidgetSnapshot(invalid, to: cache))
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), previous)

        let target = root.appendingPathComponent("unrelated.txt")
        let original = Data("unchanged".utf8)
        try original.write(to: target)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: target)
        XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: cache).hasData)
        try SharedStore.saveWidgetSnapshot(previous, to: cache)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), previous)
    }

    func testMetricsUseServerPercentAndOnlySuppliedEnabledPeriods() throws {
        let metrics = [
            PeriodUsageMetric(period: .fiveHours, usedTokens: 50, limitTokens: 100, serverUsedPercent: 20),
            PeriodUsageMetric(period: .weekly, usedTokens: 5, limitTokens: 100, serverUsedPercent: 95)
        ]
        let selected = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens", metrics: metrics
        ))
        XCTAssertEqual(selected.bottleneckPeriod, .weekly)
        XCTAssertEqual(selected.remainingPercent, 5)
        XCTAssertEqual(selected.remainingSource, .official)
        let enabled = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens", metrics: [metrics[0]]
        ))
        XCTAssertEqual(enabled.bottleneckPeriod, .fiveHours)
        XCTAssertEqual(enabled.remainingPercent, 80)
        XCTAssertNil(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens", metrics: []
        ))
    }

    func testUnavailableOfficialQuotaKeepsEstimatedUseWithoutInventingALimit() throws {
        let metrics = [
            PeriodUsageMetric(period: .fiveHours, usedTokens: 5, limitTokens: 100,
                              requiresOfficialQuota: true),
            PeriodUsageMetric(period: .monthly, usedTokens: 700, limitTokens: 800,
                              resetTimestamp: 1_800_000_000, requiresOfficialQuota: true)
        ]
        let selected = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "gemini", name: "Gemini", shortName: "Gem", iconName: "cpu", unit: "tokens", metrics: metrics
        ))
        XCTAssertEqual(selected.remainingSource, .unavailable)
        XCTAssertFalse(selected.isRemainingAvailable)
        XCTAssertEqual(selected.bottleneckPeriod, .monthly)
        XCTAssertEqual(selected.usedTokens, 700)
        XCTAssertEqual(selected.usedDisplay, "700")
        XCTAssertEqual(selected.limitTokens, 0)
        XCTAssertTrue(selected.limitDisplay.isEmpty)
        XCTAssertNil(selected.remainingResetText())

        let official = PeriodUsageMetric(period: .weekly, usedTokens: 50, limitTokens: 100,
                                         serverUsedPercent: 20, requiresOfficialQuota: true)
        let available = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "gemini", name: "Gemini", shortName: "Gem", iconName: "cpu", unit: "tokens",
            metrics: metrics + [official]
        ))
        XCTAssertEqual(available.remainingSource, .official)
        XCTAssertTrue(available.isRemainingAvailable)
        XCTAssertEqual(available.bottleneckPeriod, .weekly)
        XCTAssertEqual(available.remainingPercent, 80)
    }

    func testKnownQuotasRankBeforeUnavailableAndAllUnavailableRemainVisible() throws {
        let unknown = try unavailableItem()
        let configured = try item("cursor", used: 40)
        XCTAssertEqual(configured.remainingSource.percentText(configured.remainingPercent), "約60%")
        XCTAssertEqual(unknown.remainingSource.percentText(unknown.remainingPercent), "未取得")
        let official = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens",
            metrics: [.init(period: .weekly, usedTokens: 20, limitTokens: 100, serverUsedPercent: 90)]
        ))
        let mixed = AIMeterWidgetSnapshot.make(
            services: [unknown, configured, official], totalCostUSD: 0,
            updatedAt: updatedAt, hasData: true
        )
        XCTAssertEqual(official.remainingSource.percentText(official.remainingPercent), "10%")
        XCTAssertEqual(mixed.schemaVersion, 2)
        XCTAssertEqual(mixed.allServices.map(\.id), ["openai", "cursor", "gemini"])
        XCTAssertEqual(mixed.topServices, mixed.allServices)
        XCTAssertEqual(mixed.mostCriticalService?.id, "openai")
        try SharedStore.saveWidgetSnapshot(mixed, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), mixed)

        let allUnavailable = AIMeterWidgetSnapshot.make(
            services: [unknown], totalCostUSD: 0, updatedAt: updatedAt,
            hasData: true, showUsageAmounts: true
        )
        XCTAssertNil(allUnavailable.mostCriticalService)
        XCTAssertTrue(allUnavailable.hasData)
        XCTAssertEqual(allUnavailable.topServices, [unknown])
        XCTAssertEqual(allUnavailable.allServices, [unknown])
        try SharedStore.saveWidgetSnapshot(allUnavailable, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), allUnavailable)
    }

    func testLegacyGeminiPercentageMigratesToUnavailableWithoutLosingOtherServices() throws {
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [try item("gemini", used: 90), try item("cursor", used: 40)],
            totalCostUSD: 2.75, updatedAt: updatedAt, hasData: true,
            updateFailed: true, showUsageAmounts: true
        )
        var legacy = try legacyObject(from: snapshot)
        legacy.removeValue(forKey: "showUsageAmounts")
        try JSONSerialization.data(withJSONObject: legacy).write(to: cache)

        let migrated = SharedStore.loadWidgetSnapshot(from: cache)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertTrue(migrated.hasData)
        XCTAssertTrue(migrated.updateFailed)
        XCTAssertFalse(migrated.showUsageAmounts)
        XCTAssertEqual(migrated.updatedAt, updatedAt)
        XCTAssertEqual(migrated.totalCostUSD, 2.75)
        XCTAssertEqual(migrated.mostCriticalService?.id, "cursor")
        XCTAssertEqual(migrated.allServices.map(\.id), ["cursor", "gemini"])
        XCTAssertEqual(migrated.topServices, migrated.allServices)
        XCTAssertEqual(migrated.allServices.last?.remainingSource, .unavailable)
        XCTAssertEqual(migrated.allServices.last?.usedTokens, 90)
        XCTAssertEqual(migrated.allServices.first?.remainingSource, .configuredLimit)
        try SharedStore.saveWidgetSnapshot(migrated, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), migrated)

        let onlyGemini = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 0, updatedAt: updatedAt, hasData: true
        )
        try JSONSerialization.data(withJSONObject: legacyObject(from: onlyGemini)).write(to: cache)
        let unknown = SharedStore.loadWidgetSnapshot(from: cache)
        XCTAssertTrue(unknown.hasData)
        XCTAssertNil(unknown.mostCriticalService)
        XCTAssertEqual(unknown.allServices.map(\.id), ["gemini"])
        XCTAssertEqual(unknown.allServices.first?.remainingSource, .unavailable)
    }

    func testServiceSourceDefaultsConservativelyWhenDecodingLegacyItems() throws {
        for id in ["gemini", "cursor"] {
            let original = try item(id)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            object.removeValue(forKey: "remainingSource")
            let decoded = try JSONDecoder().decode(WidgetServiceItem.self,
                                                    from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.remainingSource, id == "gemini" ? .unavailable : .configuredLimit)
        }
    }

    func testUnavailableQuotaCannotBecomeMostCriticalOrBreakServiceOrdering() throws {
        let unknown = try unavailableItem()
        let known = try item("cursor")
        for invalid in [
            AIMeterWidgetSnapshot(mostCriticalService: unknown, topServices: [known, unknown],
                                  allServices: [known, unknown], totalCostUSD: 0,
                                  updatedAt: updatedAt, hasData: true),
            AIMeterWidgetSnapshot(mostCriticalService: known, topServices: [unknown, known],
                                  allServices: [unknown, known], totalCostUSD: 0,
                                  updatedAt: updatedAt, hasData: true)
        ] {
            XCTAssertThrowsError(try SharedStore.saveWidgetSnapshot(invalid, to: cache))
        }

        let valid = AIMeterWidgetSnapshot.make(services: [known, unknown], totalCostUSD: 0,
                                               updatedAt: updatedAt, hasData: true)
        var malformed = try legacyObject(from: valid)
        malformed["topServices"] = [] as [Any]
        try JSONSerialization.data(withJSONObject: malformed).write(to: cache)
        XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: cache).hasData)
    }
    func testResetCountdownUsesCurrentTimeAfterHostStops() throws {
        let reset = Int(updatedAt.timeIntervalSince1970) + 4800
        let item = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "claude", name: "Claude", shortName: "Cld", iconName: "cpu", unit: "tokens",
            metrics: [.init(period: .fiveHours, usedTokens: 20, limitTokens: 100, resetTimestamp: reset)]
        ))
        let snapshot = AIMeterWidgetSnapshot.make(services: [item], totalCostUSD: 0,
                                                  updatedAt: updatedAt, hasData: true)
        try SharedStore.saveWidgetSnapshot(snapshot, to: cache)
        let restored = try XCTUnwrap(SharedStore.loadWidgetSnapshot(from: cache).mostCriticalService)
        XCTAssertNil(restored.resetText)
        XCTAssertEqual(restored.remainingResetText(at: updatedAt), "あと1時間20分")
        XCTAssertEqual(restored.remainingResetText(at: updatedAt.addingTimeInterval(3600)), "あと20分")
        XCTAssertEqual(restored.remainingResetText(at: updatedAt.addingTimeInterval(5000)), "即時リセット")
    }

}
