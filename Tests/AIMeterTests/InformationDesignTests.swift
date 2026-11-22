import AppKit
import SwiftUI
import XCTest
import Security
import AIMeterCore
@testable import AIMeter

final class InformationDesignTests: XCTestCase {
    func testHelpSearchFindsRecoveryAndReturnsAllQuestionsForWhitespace() {
        XCTAssertEqual(HelpQuestions.matching(" \n ").count, HelpQuestions.items.count)
        XCTAssertEqual(Set(HelpQuestions.items.map(\.id)).count, HelpQuestions.items.count)
        XCTAssertTrue(HelpQuestions.matching("検索に一致しない合成文字列").isEmpty)
        XCTAssertTrue(HelpQuestions.matching("未取得").contains { $0.id == "remaining" })
        XCTAssertTrue(HelpQuestions.matching("Keychain").contains { $0.id == "stop" })
        #if AIMETER_APP_STORE
        XCTAssertTrue(HelpQuestions.matching("再選択").contains { $0.id == "not-detected" })
        #else
        XCTAssertTrue(HelpQuestions.matching("実体のパス").contains { $0.id == "not-detected" })
        #endif
    }

    /// Opt-in offscreen captures use isolated defaults and never start a collector.
    @MainActor
    func testSettingsAndMeterSyntheticPreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["AIMETER_PREVIEW_DIR"] else { return }
        let suite = "AIMeter-Information-Design-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false,
            requiresCollectionIntroduction: false,
            keychainOperations: .init(update: { _, _ in errSecAuthFailed }, add: { _ in errSecAuthFailed },
                delete: { _ in errSecAuthFailed }, copyMatching: { _ in (errSecItemNotFound, nil) }))
        monitor.autoShowWidgetOnLaunch = false
        monitor.showOpenAISection = true
        monitor.showGeminiSection = true
        monitor.applyLocalSnapshot(.init(openaiUsedTokens: 25, openaiCostUSD: 0,
                                        geminiUsedTokens: 0, geminiCostUSD: 0))
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
            for page in OnboardingController.Page.allCases {
                try capture(CollectionIntroductionView(monitor: monitor, initialPageIndex: page.rawValue)
                    .padding(14).frame(maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.colorScheme, scheme),
                    size: NSSize(width: 348, height: 300),
                    appearance: appearance,
                    to: url.appendingPathComponent("onboarding-native-\(page.rawValue + 1)-\(suffix).png"))
            }
            for tab in SettingsTab.allCases {
                try capture(SettingsView(monitor: monitor, initialTab: tab).environment(\.colorScheme, scheme),
                    size: NSSize(width: 1000, height: 760),
                    appearance: appearance,
                    to: url.appendingPathComponent("settings-\(tab.rawValue)-\(suffix).png"))
            }
            for amounts in [false, true] {
                monitor.showUsageAmounts = amounts
                try capture(AIMeterCardView(monitor: monitor, isMenuBar: true).environment(\.colorScheme, scheme),
                    size: NSSize(width: 348, height: 720),
                    appearance: appearance,
                    to: url.appendingPathComponent("meter-\(amounts ? "amounts" : "percent")-\(suffix).png"))
            }
        }
    }

    @MainActor
    private func capture<Content: View>(_ content: Content, size: NSSize,
                                        appearance: NSAppearance.Name, to url: URL) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        host.appearance = window.appearance
        host.sizingOptions = []
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
