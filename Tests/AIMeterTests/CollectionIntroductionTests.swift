import XCTest
import Security
import SwiftUI
import AppKit
import AIMeterCore
@testable import AIMeter

final class CollectionIntroductionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "AIMeter-Collection-Introduction-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNewInstallWaitsAndPriorStartupPreservesExistingChoice() {
        XCTAssertFalse(CollectionIntroduction.hasAcknowledged(in: defaults))
        defaults.set(false, forKey: "showOpenAISection")
        defaults.set(true, forKey: "didCalibrateRealLimitsV1")
        XCTAssertTrue(CollectionIntroduction.hasAcknowledged(in: defaults))
        XCTAssertFalse(defaults.bool(forKey: "showOpenAISection"))

        // An explicit pending state wins over migration, and malformed values
        // must never stand in for the user's acknowledgment.
        for value in [false, 1, "true"] as [Any] {
            defaults.set(value, forKey: CollectionIntroduction.acknowledgmentPreference)
            XCTAssertFalse(CollectionIntroduction.hasAcknowledged(in: defaults))
        }
        defaults.set(true, forKey: CollectionIntroduction.acknowledgmentPreference)
        XCTAssertTrue(CollectionIntroduction.hasAcknowledged(in: defaults))
    }

    @MainActor
    func testLiveNewInstallDoesNotStartCollectionOrReadCredentials() async {
        var keyReads = 0
        var collections = 0
        var tokenRequests = 0
        let monitor = UsageMonitor(defaults: defaults,
            keychainOperations: noCredentials { keyReads += 1 },
            gcloudTokenProvider: { _, _ in tokenRequests += 1; return nil },
            localCollector: { _, _ in collections += 1; return LocalUsageData() })
        XCTAssertTrue(monitor.requiresCollectionIntroduction)
        monitor.showAntigravitySection = true
        defaults.set("synthetic-project", forKey: "gcpProjectId")

        monitor.loadOpenAICredentialIfEnabled()
        monitor.retryOpenAICredentialLoad()
        await monitor.refresh()
        await monitor.refreshConfiguredAPIs()
        await monitor.refreshAntigravityQuota {
            XCTFail("First launch must not probe another application's local API")
            throw CancellationError()
        }
        XCTAssertEqual(collections, 0)
        XCTAssertEqual(keyReads, 0)
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertNil(monitor.lastUpdated)
        XCTAssertFalse(defaults.bool(forKey: "didCalibrateRealLimitsV1"))
        XCTAssertFalse(CollectionIntroduction.hasAcknowledged(in: defaults))
    }

    @MainActor
    func testStartPersistsChoiceAndOnlySelectedSourcesReachCollector() async {
        var collectedIDs: [Set<String>] = []
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false,
            requiresCollectionIntroduction: true,
            keychainOperations: noCredentials {},
            localCollector: { ids, _ in
                collectedIDs.append(ids)
                return LocalUsageData(updatedAt: "2026-11-02T00:00:00Z")
            })
        monitor.showOpenAISection = false
        monitor.showGeminiSection = true
        await monitor.refresh()
        XCTAssertTrue(collectedIDs.isEmpty)

        monitor.beginCollection()
        monitor.beginCollection()
        XCTAssertFalse(monitor.requiresCollectionIntroduction)
        XCTAssertTrue(CollectionIntroduction.hasAcknowledged(in: defaults))
        XCTAssertFalse(monitor.showOpenAISection)
        XCTAssertTrue(monitor.showGeminiSection)
        await monitor.refresh()
        XCTAssertEqual(collectedIDs, [["gemini"]])
    }

    @MainActor
    func testSyntheticIntroductionSelectionsAndCollectionFailureRender() async throws {
        var collections = 0
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false,
            requiresCollectionIntroduction: true,
            keychainOperations: noCredentials {},
            localCollector: { _, _ in
                collections += 1
                throw NSError(domain: "AIMeterSyntheticCollectionFailure", code: 1)
            })
        monitor.autoShowWidgetOnLaunch = false
        for selected in [true, false] {
            monitor.showOpenAISection = selected
            monitor.showGeminiSection = selected
            await monitor.refresh()
            XCTAssertEqual(collections, 0, "Rendering and changing the selection must not start collection")
            for dark in [false, true] {
                let content = CollectionIntroductionView(monitor: monitor)
                    .frame(width: 320)
                    .padding(14)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                try renderSyntheticPreview(content,
                    name: "introduction-\(selected ? "selected" : "all-off")-\(dark ? "dark" : "light")",
                    maximumHeight: 1600)
            }
        }

        monitor.showOpenAISection = true
        monitor.beginCollection()
        await monitor.refresh()
        XCTAssertEqual(collections, 1)
        XCTAssertNotNil(monitor.collectionError)
        let failedCard = AIMeterCardView(monitor: monitor, isMenuBar: true)
            .background(Color(nsColor: .windowBackgroundColor))
        try renderSyntheticPreview(failedCard, name: "introduction-collection-failure", maximumHeight: 1400)
    }

    @MainActor
    func testNavigationAndModeSelectionNeverStartCollectionOrOverwriteSavedSettings() async {
        var collections = 0
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false,
            requiresCollectionIntroduction: true, keychainOperations: noCredentials {},
            localCollector: { _, _ in collections += 1; return LocalUsageData() })
        monitor.isDetailedView = true
        monitor.menuBarDisplayMode = "compact"
        monitor.showOpenAISection = false
        monitor.showGeminiSection = false

        let controller = OnboardingController()
        _ = CollectionIntroductionView(monitor: monitor)
        XCTAssertTrue(monitor.isDetailedView, "Opening the introduction preserves saved display settings")
        controller.completeOnboarding(monitor: monitor)
        XCTAssertTrue(monitor.requiresCollectionIntroduction, "Only the final consent step can start collection")
        controller.goBack()
        XCTAssertEqual(controller.currentPage, .overview)
        controller.goNext()
        XCTAssertEqual(controller.currentPage, .display)
        controller.selectDisplayMode(false, applyTo: monitor)
        XCTAssertFalse(monitor.isDetailedView)
        XCTAssertEqual(controller.currentPage, .display, "A selection must not auto-advance")
        controller.selectDisplayMode(true, applyTo: monitor)
        controller.goBack()
        controller.skipToConnection()
        controller.goNext()
        XCTAssertEqual(controller.currentPage, .services)
        await monitor.refresh()
        XCTAssertEqual(collections, 0)
        XCTAssertTrue(monitor.requiresCollectionIntroduction)
        XCTAssertFalse(CollectionIntroduction.hasAcknowledged(in: defaults))
        XCTAssertEqual(monitor.menuBarDisplayMode, "compact")
        XCTAssertTrue(monitor.isDetailedView)

        controller.completeOnboarding(monitor: monitor)
        XCTAssertFalse(monitor.requiresCollectionIntroduction)
        XCTAssertTrue(CollectionIntroduction.hasAcknowledged(in: defaults))
        XCTAssertFalse(monitor.showOpenAISection)
        XCTAssertFalse(monitor.showGeminiSection)
        XCTAssertFalse(CollectionIntroduction.shouldShowOnboarding(in: defaults))
        XCTAssertTrue(CollectionIntroduction.shouldShowOnboarding(in: defaults, requiredVersion: 2))
    }

    @MainActor
    func testKeyOnboardingPagesRenderSynthetically() throws {
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false,
            requiresCollectionIntroduction: true, keychainOperations: noCredentials {})
        for detailed in [false, true] {
            monitor.isDetailedView = detailed
            for dark in [false, true] {
                for pageIndex in OnboardingController.Page.allCases.map(\.rawValue) {
                    let content = CollectionIntroductionView(monitor: monitor, initialPageIndex: pageIndex)
                        .frame(width: 320)
                        .padding(14)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    try renderSyntheticPreview(content,
                        name: "onboarding-\(pageIndex + 1)-\(detailed ? "all" : "summary")-\(dark ? "dark" : "light")",
                        maximumHeight: 1200)
                }
            }
        }
    }

    @MainActor
    private func renderSyntheticPreview<Content: View>(
        _ content: Content, name: String, maximumHeight: Int
    ) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(name) failed to render")
        XCTAssertEqual(image.width, 696)
        XCTAssertGreaterThan(image.height, 200)
        XCTAssertLessThan(image.height, maximumHeight, "Unbounded first-use content: \(name)")
        if let directory = ProcessInfo.processInfo.environment["AIMETER_PREVIEW_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url.appendingPathComponent("\(name).png"))
        }
    }

    private func noCredentials(onRead: @escaping () -> Void) -> KeychainHelper.Operations {
        .init(update: { _, _ in errSecAuthFailed }, add: { _ in errSecAuthFailed },
              delete: { _ in errSecAuthFailed }, copyMatching: { _ in
                  onRead()
                  return (errSecItemNotFound, nil)
              })
    }
}
