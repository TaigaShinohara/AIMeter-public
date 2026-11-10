import Foundation
import XCTest
import AIMeterCore

final class DistributionStorageTests: XCTestCase {
    func testDirectSnapshotDoesNotConsultGroupProvider() throws {
        let configuration = try DistributionConfiguration(infoDictionary: [:])
        let url = try SharedStore.resolvedWidgetSnapshotURL(configuration: configuration) { _ in
            XCTFail("Direct distribution must not resolve a group")
            return nil
        }
        XCTAssertEqual(url, SharedStore.widgetSnapshotFileURL)
    }

    func testStoreSnapshotRequiresAndUsesDeclaredGroup() throws {
        let configuration = try DistributionConfiguration(infoDictionary: [
            "AIMeterDistribution": "app-store",
            "AIMeterAppGroupIdentifier": "group.example.AIMeter.store",
            "AIMeterKeychainService": "example.AIMeter.store",
            "AIMeterWidgetKind": "example.AIMeter.store.widget",
            "AIMeterURLScheme": "aimeter-store"
        ])
        let url = try SharedStore.resolvedWidgetSnapshotURL(configuration: configuration) { group in
            XCTAssertEqual(group, "group.example.AIMeter.store")
            return URL(fileURLWithPath: "/synthetic/group")
        }
        XCTAssertEqual(url, URL(fileURLWithPath: "/synthetic/group/.ai_meter_widget.json"))
        XCTAssertThrowsError(try SharedStore.resolvedWidgetSnapshotURL(configuration: configuration) { _ in nil }) {
            XCTAssertEqual($0 as? DistributionConfiguration.ConfigurationError, .missingAppGroupContainer)
        }
    }
}
