import XCTest
import AIMeterCore

final class WidgetPrivacySchemaTests: XCTestCase {
    private let forbidden: Set<String> = ["totalCostUSD", "usedTokens", "limitTokens", "usedDisplay", "limitDisplay"]
    private func item() throws -> WidgetServiceItem {
        try XCTUnwrap(WidgetServiceItem.fromMetrics(id: "cursor", name: "User chosen service", shortName: "Svc",
                                                   iconName: "cpu", unit: "tokens",
                                                   metrics: [.init(period: .monthly, usedTokens: 37, limitTokens: 100)]))
    }
    private func assertNoAmounts(_ value: Any, file: StaticString = #filePath, line: UInt = #line) {
        if let object = value as? [String: Any] {
            XCTAssertTrue(Set(object.keys).isDisjoint(with: forbidden), file: file, line: line)
            object.values.forEach { assertNoAmounts($0, file: file, line: line) }
        } else if let array = value as? [Any] {
            array.forEach { assertNoAmounts($0, file: file, line: line) }
        }
    }

    func testHiddenSchemaOmitsAmountsAndCostsWithoutLosingQuotaOrLabels() throws {
        let original = try item()
        let snapshot = AIMeterWidgetSnapshot.make(services: [original], totalCostUSD: 19.5,
                                                   updatedAt: Date(), hasData: true, showUsageAmounts: false)
        let data = try JSONEncoder().encode(snapshot)
        assertNoAmounts(try JSONSerialization.jsonObject(with: data))
        XCTAssertEqual(snapshot.schemaVersion, 4)
        XCTAssertEqual(snapshot.totalCostUSD, 0)
        XCTAssertEqual(snapshot.allServices.first?.usedTokens, 0)
        XCTAssertEqual(snapshot.allServices.first?.name, original.name)
        XCTAssertEqual(snapshot.allServices.first?.remainingPercent, 63)
        XCTAssertEqual(try JSONDecoder().decode(AIMeterWidgetSnapshot.self, from: data), snapshot)
    }

    func testShownSchemaKeepsAmountsButNeverCostAndRejectsMissingAmount() throws {
        let snapshot = AIMeterWidgetSnapshot.make(services: [try item()], totalCostUSD: 19.5,
                                                   updatedAt: Date(), hasData: true, showUsageAmounts: true)
        let data = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["totalCostUSD"])
        var services = try XCTUnwrap(object["allServices"] as? [[String: Any]])
        XCTAssertEqual(services.first?["usedTokens"] as? Int, 37)
        XCTAssertEqual(try JSONDecoder().decode(AIMeterWidgetSnapshot.self, from: data), snapshot)
        services[0].removeValue(forKey: "usedTokens")
        object["allServices"] = services
        XCTAssertThrowsError(try JSONDecoder().decode(AIMeterWidgetSnapshot.self,
                                                      from: JSONSerialization.data(withJSONObject: object)))
    }

    func testLegacyHiddenSchemasDiscardRawValuesBeforeReencoding() throws {
        let snapshot = AIMeterWidgetSnapshot.make(services: [try item()], totalCostUSD: 0,
                                                   updatedAt: Date(), hasData: true, showUsageAmounts: true)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for version in [1, 2, 3] {
            var legacy = base
            legacy["schemaVersion"] = version
            legacy["showUsageAmounts"] = false
            legacy["totalCostUSD"] = 19.5
            for key in ["topServices", "allServices"] {
                var services = try XCTUnwrap(legacy[key] as? [[String: Any]])
                services[0]["usedDisplay"] = "SYNTHETIC_PRIVATE_AMOUNT"
                legacy[key] = services
            }
            var critical = try XCTUnwrap(legacy["mostCriticalService"] as? [String: Any])
            critical["usedDisplay"] = "SYNTHETIC_PRIVATE_AMOUNT"
            legacy["mostCriticalService"] = critical
            let migrated = try JSONDecoder().decode(AIMeterWidgetSnapshot.self,
                                                     from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(migrated.schemaVersion, 4)
            XCTAssertEqual(migrated.allServices.first?.usedTokens, 0)
            XCTAssertEqual(migrated.totalCostUSD, 0)
            let encoded = try JSONEncoder().encode(migrated)
            assertNoAmounts(try JSONSerialization.jsonObject(with: encoded))
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("SYNTHETIC_PRIVATE_AMOUNT"))
        }
    }
}
