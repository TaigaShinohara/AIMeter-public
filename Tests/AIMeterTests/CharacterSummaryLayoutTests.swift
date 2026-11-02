import XCTest
import SwiftUI
import AppKit
import AIMeterCore
@testable import AIMeter

final class CharacterSummaryLayoutTests: XCTestCase {
    @MainActor
    func testSummaryWrapsLongNamesAndRendersAcrossAppearanceSettings() throws {
        let samples: [(String, UsageHighlight)] = [
            ("official-low", .init(tone: .urgent, title: "残りわずか", message: "Codexの週次枠、残り12%だよ。")),
            ("estimated-low", .init(tone: .attention, title: "少なくなってきたよ",
                                    message: "Claudeの月次枠、設定上限の目安は残り28%だよ。")),
            ("previous", .init(tone: .urgent, title: "残りわずか", message: "前回はCodexの5時間枠、残り12%だったよ。",
                               detail: "更新できなかったので、右上の更新で確認してね。残量が未取得の枠もあるよ。")),
            ("unknown", .init(tone: .checking, title: "まだ分からない枠があるよ",
                              message: "残量を確認できない枠があるよ。全枠表示で見てね。")),
            ("calm", .init(tone: .calm, title: "ひとこと", message: "確認できた枠は、どれも残り35%以上だよ。")),
            ("loading", .init(tone: .checking, title: "確認中", message: "最初のデータを確認しているよ。")),
            ("disabled", .init(tone: .calm, title: "はじめよう", message: "設定で、表示するサービスを選ぼう。")),
            ("long-name", .init(tone: .urgent, title: "残りわずか",
                                message: "個人用の長い名前を付けたカスタムAIサービスの週次枠、設定上限の目安は残り12%だよ。"))
        ]
        let appearances: [(String, Bool, ColorSchemeContrast)] = [
            ("standard", false, .standard),
            ("reduced-transparency", true, .standard),
            ("increased-contrast", false, .increased),
            ("accessible", true, .increased)
        ]
        for dark in [false, true] {
            for (appearance, reduceTransparency, contrast) in appearances {
                for (name, highlight) in samples {
                    let content = CharacterSummaryContent(highlight: highlight, reduceTransparency: reduceTransparency,
                                                          contrast: contrast,
                                                          colorScheme: dark ? .dark : .light)
                        .frame(width: 320)
                        .padding(14)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.cgImage, "\(name) failed to render")
                    XCTAssertEqual(image.width, 696)
                    XCTAssertGreaterThan(image.height, 130)
                    XCTAssertLessThan(image.height, 600, "Unbounded banner: \(name)")
                    // Optional local, synthetic-only visual evidence; never reads personal usage.
                    if let directory = ProcessInfo.processInfo.environment["AIMETER_PREVIEW_DIR"] {
                        let url = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: url.appendingPathComponent("\(name)-\(dark ? "dark" : "light")-\(appearance).png"))
                    }
                }
            }
        }
    }

    @MainActor
    func testWholeCardFitsWithOneAndFiveProvidersWithoutReservingEmptyScrollSpace() throws {
        let suite = "AIMeter-Character-Layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "didAutoSeedLocalProvidersV2")
        defaults.set(true, forKey: "didMigrateHonestCostsV3")
        let monitor = UsageMonitor(defaults: defaults, startMonitoring: false)
        monitor.autoShowWidgetOnLaunch = false
        monitor.showGeminiSection = false
        monitor.openaiEnabledPeriodsCSV = "5h,7d,30d"
        monitor.openaiServerPct = .init(fiveHours: 88, weekly: 40, monthly: 10)
        monitor.recordUsageUpdate()
        for isMenu in [true, false] {
            monitor.customSubscriptions = []
            monitor.isDetailedView = false
            let compact = NSHostingView(rootView: AIMeterCardView(monitor: monitor, isMenuBar: isMenu))
            let compactSize = compact.fittingSize
            XCTAssertEqual(compactSize.width, 348, accuracy: 1)
            XCTAssertLessThan(compactSize.height, 480, "Single provider must not reserve all scroll space")

            monitor.customSubscriptions = (0..<4).map { index in
                var config = CustomSubscriptionConfig.cursorPreset()
                config.id = "preview-\(index)"
                config.name = "カスタムサービス \(index + 1)"
                config.enabledPeriodRawValues = LimitPeriod.allCases.map(\.rawValue)
                return config
            }
            monitor.isDetailedView = true
            let full = NSHostingView(rootView: AIMeterCardView(monitor: monitor, isMenuBar: isMenu))
            let fullSize = full.fittingSize
            XCTAssertEqual(fullSize.width, 348, accuracy: 1)
            XCTAssertLessThan(fullSize.height, isMenu ? 650 : 730, "Full-period rows must be bounded")
            XCTAssertGreaterThan(fullSize.height, compactSize.height)
        }
    }
}
