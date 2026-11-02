import XCTest
import AIMeterCore
@testable import AIMeter

final class CachePresentationPrivacyTests: XCTestCase {
    @MainActor
    func testLegacyCacheCannotRestoreArbitraryBuiltInPlanOrStatusText() {
        let suite = "AIMeter.CachePrivacy." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "didAutoSeedLocalProvidersV2")
        defaults.set(true, forKey: "didMigrateHonestCostsV3")
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false)
        let marker = "SYNTHETIC_PRIVATE_CACHE_TEXT"
        monitor.applyLocalSnapshot(LocalUsageData(openaiPlanType: marker, providers: [
            "claude_clone": .init(status: marker),
            "windsurf": .init(status: marker),
            "custom_manual": .init(status: "User chosen label")
        ]))
        XCTAssertEqual(monitor.openaiStatus, "unknown")
        XCTAssertEqual(monitor.customProviderLiveUsage["claude_clone"]?.status, "Claude")
        XCTAssertEqual(monitor.customProviderLiveUsage["windsurf"]?.status, "Windsurf")
        XCTAssertEqual(monitor.customProviderLiveUsage["custom_manual"]?.status, "User chosen label")
    }
}
