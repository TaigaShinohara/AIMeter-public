import Foundation
import XCTest
import AIMeterCore

final class DistributionConfigurationTests: XCTestCase {
    private let storeInfo: [String: Any] = [
        "AIMeterDistribution": "app-store",
        "AIMeterAppGroupIdentifier": "group.example.AIMeter.store",
        "AIMeterKeychainService": "example.AIMeter.store",
        "AIMeterWidgetKind": "example.AIMeter.store.widget",
        "AIMeterURLScheme": "aimeter-store"
    ]

    func testMissingModePreservesDirectIdentitiesAndWidgetPath() throws {
        let config = try DistributionConfiguration(infoDictionary: [:])
        XCTAssertEqual(config.mode, .direct)
        XCTAssertNil(config.appGroupIdentifier)
        XCTAssertEqual(config.keychainService, "com.local.AIMeter")
        XCTAssertEqual(config.widgetKind, "com.local.AIMeter.widget")
        XCTAssertEqual(config.urlScheme, "aimeter")
        XCTAssertEqual(try config.widgetSnapshotURL(home: URL(fileURLWithPath: "/home/test"),
                                                    groupContainer: URL(fileURLWithPath: "/other")),
                       URL(fileURLWithPath: "/home/test/.ai_meter_widget.json"))
    }

    func testStoreUsesExplicitIdentitiesAndGroupContainer() throws {
        let config = try DistributionConfiguration(infoDictionary: storeInfo)
        XCTAssertEqual(config.mode, .appStore)
        XCTAssertEqual(config.appGroupIdentifier, "group.example.AIMeter.store")
        XCTAssertEqual(config.keychainService, "example.AIMeter.store")
        XCTAssertEqual(config.widgetKind, "example.AIMeter.store.widget")
        XCTAssertEqual(config.urlScheme, "aimeter-store")
        XCTAssertEqual(try config.widgetSnapshotURL(home: URL(fileURLWithPath: "/home/test"),
                                                    groupContainer: URL(fileURLWithPath: "/container")),
                       URL(fileURLWithPath: "/container/.ai_meter_widget.json"))
        XCTAssertThrowsError(try config.widgetSnapshotURL(home: URL(fileURLWithPath: "/home/test"), groupContainer: nil)) {
            XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .missingAppGroupContainer)
        }
    }

    func testInvalidDistributionAndMissingStoreValuesFailClosed() {
        XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: [:], requireAppStore: true)) {
            XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .invalidDistribution)
        }
        XCTAssertNoThrow(try DistributionConfiguration(infoDictionary: storeInfo, requireAppStore: true))
        for value: Any in ["store", "", true] {
            XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: ["AIMeterDistribution": value])) {
                XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .invalidDistribution)
            }
        }
        for key in ["AIMeterAppGroupIdentifier", "AIMeterKeychainService", "AIMeterWidgetKind", "AIMeterURLScheme"] {
            for invalid: Any in ["", " ", 42] {
                var info = storeInfo
                info[key] = invalid
                XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: info)) {
                    XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .missingValue(key))
                }
            }
            var info = storeInfo
            info.removeValue(forKey: key)
            XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: info)) {
                XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .missingValue(key))
            }
        }
    }

    func testStoreCannotReuseDirectIdentities() {
        for (key, value) in [("AIMeterKeychainService", "com.local.AIMeter"),
                             ("AIMeterWidgetKind", "com.local.AIMeter.widget"),
                             ("AIMeterURLScheme", "aimeter")] {
            var info = storeInfo
            info[key] = value
            XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: info)) {
                XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .conflictsWithDirectDistribution(key))
            }
        }
    }

    func testStoreRejectsUnexpandedAndUnsafeValues() {
        for key in ["AIMeterAppGroupIdentifier", "AIMeterKeychainService", "AIMeterWidgetKind", "AIMeterURLScheme"] {
            for invalid in ["$(UNEXPANDED)", "valid\nvalue", "valid/value", "valid:value", "valid value"] {
                var info = storeInfo
                info[key] = invalid
                XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: info), "\(key): \(invalid)") {
                    XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .invalidValue(key))
                }
            }
        }
    }

    func testStoreGroupFormsAndSchemeSyntax() {
        for group in ["group.example.store", "ABCDE12345.example.store"] {
            var info = storeInfo
            info["AIMeterAppGroupIdentifier"] = group
            XCTAssertNoThrow(try DistributionConfiguration(infoDictionary: info))
        }
        for group in ["example.store", "group.", "group..store", "ABC.example.store"] {
            var info = storeInfo
            info["AIMeterAppGroupIdentifier"] = group
            XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: info)) {
                XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .invalidValue("AIMeterAppGroupIdentifier"))
            }
        }
        for scheme in ["1store", "store_scheme", "store://", "store%20"] {
            var info = storeInfo
            info["AIMeterURLScheme"] = scheme
            XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: info)) {
                XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .invalidValue("AIMeterURLScheme"))
            }
        }
        var info = storeInfo
        info["AIMeterURLScheme"] = "Store+1.example-test"
        XCTAssertNoThrow(try DistributionConfiguration(infoDictionary: info))
        info["AIMeterURLScheme"] = "AIMETER"
        XCTAssertThrowsError(try DistributionConfiguration(infoDictionary: info)) {
            XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .conflictsWithDirectDistribution("AIMeterURLScheme"))
        }
    }
}
