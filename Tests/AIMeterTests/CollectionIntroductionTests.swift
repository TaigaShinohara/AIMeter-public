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
    func testPageMapEnforcesOneClaimPerPageAndThreeSteps() {
        for worry in OnboardingWorryChoice.allCases {
            for trial in OnboardingDisplayTrialChoice.allCases {
                let pages = OnboardingController.buildPages(worry: worry, trial: trial)
                XCTAssertEqual(pages.count, 14)

                // Exactly 3 step pages
                let steps = pages.filter { $0.role == .step }
                XCTAssertEqual(steps.count, 3)
                XCTAssertEqual(steps.map(\.heading), [
                    "1. 使うAIを選ぶ",
                    "2. メニューバーを見る",
                    "3. 要点と全期間を切り替える"
                ])

                for page in pages {
                    XCTAssertFalse(page.heading.isEmpty)
                    XCTAssertFalse(page.heading.contains("\n"), "Heading must be a single line: \(page.heading)")
                    XCTAssertFalse(page.visualCenterpiece.isEmpty)
                    XCTAssertFalse(page.heroAnimationMeaning.isEmpty)
                    XCTAssertLessThanOrEqual(page.ambientElementCount, 2, "Ambient animation max 2 elements")

                    // Forbidden absolute guarantee words
                    for forbidden in ["必ず", "絶対に", "誰でも"] {
                        XCTAssertFalse(page.heading.contains(forbidden))
                        XCTAssertFalse(page.supplement.contains(forbidden))
                    }
                }

                // Serious privacy page has 0 ambient animations
                let privacyPage = pages.first { $0.pageID == .value(.localPrivacy) }
                XCTAssertEqual(privacyPage?.ambientElementCount, 0)

                // Question and Result are on separate pages; question pages have no Next button
                let worryIndex = try! XCTUnwrap(pages.firstIndex { $0.pageID == .worrySelection })
                XCTAssertFalse(pages[worryIndex].showsNextButton)
                XCTAssertEqual(pages[worryIndex + 1].pageID, .worryMatch)
                XCTAssertEqual(pages[worryIndex + 1].role, .match)
                XCTAssertTrue(pages[worryIndex + 1].showsNextButton)

                let trialIndex = try! XCTUnwrap(pages.firstIndex { $0.pageID == .trialInteraction })
                XCTAssertFalse(pages[trialIndex].showsNextButton)
                XCTAssertEqual(pages[trialIndex + 1].pageID, .trialResult)
                XCTAssertEqual(pages[trialIndex + 1].role, .match)
                XCTAssertTrue(pages[trialIndex + 1].showsNextButton)
            }
        }
    }

    @MainActor
    func testWorrySelectionAndTrialChoiceReorderValuesAndConfigureInitialSettings() {
        var haptics: [OnboardingReactionLevel] = []
        let recorder = MockHapticPerformer { haptics.append($0) }
        let monitor = UsageMonitor(
            defaults: defaults,
            startMonitoring: false,
            requiresCollectionIntroduction: true,
            keychainOperations: noCredentials {}
        )
        let controller = OnboardingController(
            initialPageIndex: 1,
            autoAdvanceDelayNanoseconds: 0,
            hapticPerformer: recorder
        )

        // Select multiToolCheck on page #2 -> auto-advances to #3 (worryMatch)
        controller.selectWorry(.multiToolCheck, applyTo: monitor)
        XCTAssertEqual(controller.currentPage.pageID, .worryMatch)
        XCTAssertEqual(monitor.menuBarDisplayMode, "compact")
        XCTAssertEqual(haptics.last, .medium)
        XCTAssertNotNil(controller.latestPraise)

        // Value pages after worryMatch now start with .unifiedView
        let valueIDs = controller.pages.compactMap { page -> OnboardingValueTopic? in
            if case .value(let topic) = page.pageID { return topic }
            return nil
        }
        XCTAssertEqual(valueIDs, [.unifiedView, .proactiveAlert, .localPrivacy])

        // Go back to re-select privacyConcern
        controller.goBack()
        XCTAssertEqual(controller.currentPage.pageID, .worrySelection)
        XCTAssertNil(controller.latestPraise, "Back navigation must not emit praise")

        controller.selectWorry(.privacyConcern, applyTo: monitor)
        XCTAssertEqual(controller.currentPage.pageID, .worryMatch)
        XCTAssertFalse(monitor.showUsageAmounts)
        let privacyFirstIDs = controller.pages.compactMap { page -> OnboardingValueTopic? in
            if case .value(let topic) = page.pageID { return topic }
            return nil
        }
        XCTAssertEqual(privacyFirstIDs, [.localPrivacy, .proactiveAlert, .unifiedView])

        // Jump to trial interaction page (#11, index 10) and select detailed view
        while controller.currentPage.pageID != .trialInteraction {
            controller.goNext()
        }
        controller.selectTrialChoice(.detailed, applyTo: monitor)
        XCTAssertEqual(controller.currentPage.pageID, .trialResult)
        XCTAssertTrue(monitor.isDetailedView)
        XCTAssertEqual(haptics.last, .large, "Trial result celebration triggers large reaction")

        // Skip to connection page (#14) and complete onboarding
        controller.skipToConnection()
        XCTAssertEqual(controller.currentPage.pageID, .connection)
        XCTAssertNil(controller.latestPraise, "Skip must not emit praise")
        XCTAssertTrue(monitor.requiresCollectionIntroduction, "Skip must not start collection without explicit start")

        controller.completeOnboarding(monitor: monitor)
        XCTAssertFalse(monitor.requiresCollectionIntroduction)
        XCTAssertFalse(CollectionIntroduction.shouldShowOnboarding(in: defaults))
        XCTAssertTrue(CollectionIntroduction.shouldShowOnboarding(in: defaults, requiredVersion: 2))
    }

    @MainActor
    func testPraiseNeverRepeatsConsecutivelyAndWindowDotsSlideEveryPage() {
        let controller = OnboardingController(autoAdvanceDelayNanoseconds: 0, hapticPerformer: MockHapticPerformer { _ in })

        for level in [OnboardingReactionLevel.small, .medium, .large] {
            var previous: String?
            for _ in 0..<6 {
                let current = controller.triggerReaction(level)
                XCTAssertNotNil(current)
                XCTAssertNotEqual(current, previous, "Praise for \(level) must not repeat consecutively")
                previous = current
            }
        }

        // Verify Window Dots across all 14 pages
        let total = controller.pages.count
        var previousActiveIndex: Int?
        for pageIndex in 0..<total {
            let model = OnboardingWindowDotsModel(currentPage: pageIndex, totalPages: total)
            XCTAssertEqual(model.dots.count, 5, "At most 5 dots visible")
            let expectedStart = min(max(0, pageIndex - 2), total - 5)
            XCTAssertEqual(model.windowStart, expectedStart)

            let currentDots = model.dots.filter { $0.scale == .current }
            XCTAssertEqual(currentDots.count, 1)
            XCTAssertEqual(currentDots.first?.pageIndex, pageIndex)
            if let prev = previousActiveIndex {
                XCTAssertEqual(currentDots.first!.pageIndex - prev, 1, "Active dot advances by 1 every page")
            }
            previousActiveIndex = currentDots.first?.pageIndex

            if expectedStart > 0 {
                XCTAssertEqual(model.dots.first?.scale, .edgeMore)
            }
            if expectedStart + 5 < total {
                XCTAssertEqual(model.dots.last?.scale, .edgeMore)
            }
            XCTAssertEqual(model.dots.allSatisfy(\.isCompletedFinal), pageIndex == total - 1)
        }
    }

    @MainActor
    func testKeyOnboardingPagesRenderSynthetically() throws {
        let monitor = UsageMonitor(
            defaults: defaults,
            startMonitoring: false,
            requiresCollectionIntroduction: true,
            keychainOperations: noCredentials {}
        )
        for pageIndex in 0..<14 {
            let content = CollectionIntroductionView(monitor: monitor, initialPageIndex: pageIndex)
                .frame(width: 320)
                .padding(14)
                .background(Color(nsColor: .windowBackgroundColor))
            try renderSyntheticPreview(content, name: String(format: "onboarding-page-%02d", pageIndex + 1), maximumHeight: 1600)
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

private struct MockHapticPerformer: OnboardingHapticPerforming {
    let handler: (OnboardingReactionLevel) -> Void
    func perform(level: OnboardingReactionLevel) {
        handler(level)
    }
}
