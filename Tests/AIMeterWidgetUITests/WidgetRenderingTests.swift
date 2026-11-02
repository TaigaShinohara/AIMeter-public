import AIMeterCore
@testable import AIMeterWidgetUI
import AppKit
import SwiftUI
import WidgetKit
import XCTest

@MainActor
final class WidgetRenderingTests: XCTestCase {
    /// Also runs against the extracted, unchanged baseline views. This export
    /// deliberately makes no geometry assertion about the old layout.
    func testExportComparisonImages() throws {
        guard let directory = ProcessInfo.processInfo.environment["AIMETER_WIDGET_PREVIEW_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("Set AIMETER_WIDGET_PREVIEW_DIR to export synthetic comparison images")
        }
        for canvas in WidgetUIFixtures.canvases {
            let scenes: [(String, AIMeterWidgetSnapshot)] = [
                ("standard-usage-off", WidgetUIFixtures.snapshot(count: 7, showUsage: false)),
                ("mixed-usage-on", WidgetUIFixtures.mixedSnapshot(showUsage: true)),
                ("long-failure", WidgetUIFixtures.snapshot(count: 7, showUsage: true, percent: 100,
                    source: .configuredLimit, longText: true, updateFailed: true)),
                ("unavailable", WidgetUIFixtures.snapshot(count: 7, showUsage: true, source: .unavailable)),
                ("quota-only", WidgetUIFixtures.snapshot(count: 7, showUsage: true, quotaOnly: true, longText: true)),
                ("empty", WidgetUIFixtures.snapshot(count: 0, showUsage: false, hasData: false))
            ]
            for scheme in [ColorScheme.light, .dark] {
                for (name, snapshot) in scenes {
                    let image = try render(snapshot, on: canvas, colorScheme: scheme)
                    try writePreviewIfRequested(image,
                        name: "\(canvas.label)-comparison-\(name)-\(scheme == .dark ? "dark" : "light")")
                }
            }
        }
    }

    func testAllSupportedFamiliesFitEveryServiceCountWithUsageOnAndOff() throws {
        for canvas in WidgetUIFixtures.canvases {
            for count in [0, 1, 2, 3, 6, 7] {
                for showUsage in [false, true] {
                    let snapshot = WidgetUIFixtures.snapshot(count: count, showUsage: showUsage)
                    try assertRendersAndFits(
                        snapshot, on: canvas,
                        name: "count-\(count)-usage-\(showUsage)"
                    )
                }
            }
        }
    }

    func testPercentageAndWarningBoundariesFitForOfficialAndConfiguredQuota() throws {
        for canvas in WidgetUIFixtures.canvases {
            for source in [RemainingQuotaSource.official, .configuredLimit] {
                for percent in [0, 1, 15, 16, 35, 36, 99, 100] {
                    try assertRendersAndFits(
                        WidgetUIFixtures.snapshot(
                            count: canvas.visibleServiceLimit, showUsage: true,
                            percent: percent, source: source
                        ),
                        on: canvas, name: "\(source.rawValue)-\(percent)"
                    )
                }
            }
        }
    }

    func testUnavailableAndQuotaOnlyRowsFitWithUsageOnAndOff() throws {
        for canvas in WidgetUIFixtures.canvases {
            for source in [RemainingQuotaSource.official, .unavailable] {
                for quotaOnly in [false, true] {
                    for showUsage in [false, true] {
                        try assertRendersAndFits(
                            WidgetUIFixtures.snapshot(
                                count: canvas.visibleServiceLimit, showUsage: showUsage,
                                source: source, quotaOnly: quotaOnly
                            ),
                            on: canvas,
                            name: "\(source.rawValue)-quota-only-\(quotaOnly)-usage-\(showUsage)"
                        )
                    }
                }
            }
        }
    }

    func testLongTextAndUpdateFailureFitWithoutDroppingServiceRows() throws {
        for canvas in WidgetUIFixtures.canvases {
            for source in [RemainingQuotaSource.configuredLimit, .unavailable] {
                for showUsage in [false, true] {
                    try assertRendersAndFits(
                        WidgetUIFixtures.snapshot(
                            count: 7, showUsage: showUsage, percent: 100,
                            source: source, longText: true, updateFailed: true
                        ),
                        on: canvas,
                        name: "long-\(source.rawValue)-failure-usage-\(showUsage)"
                    )
                }
            }
        }
    }

    func testEmptyInitialAndDisabledStatesFitIncludingUpdateFailure() throws {
        for canvas in WidgetUIFixtures.canvases {
            for hasData in [false, true] {
                for updateFailed in [false, true] {
                    try assertRendersAndFits(
                        WidgetUIFixtures.snapshot(
                            count: 0, showUsage: true,
                            updateFailed: updateFailed, hasData: hasData
                        ),
                        on: canvas,
                        name: "empty-has-data-\(hasData)-failure-\(updateFailed)"
                    )
                }
            }
        }
    }

    func testTheSameContentRendersInLightAndDarkAppearance() throws {
        for canvas in WidgetUIFixtures.canvases {
            for scheme in [ColorScheme.light, .dark] {
                try assertRendersAndFits(
                    WidgetUIFixtures.snapshot(count: 7, showUsage: true, longText: true),
                    on: canvas, name: "appearance-\(scheme == .dark ? "dark" : "light")",
                    colorScheme: scheme
                )
            }
        }
    }

    /// Uses the production content view, not a test reconstruction of its rows.
    /// NSHostingView checks finite intrinsic geometry and ImageRenderer checks
    /// the actual requested raster size. Actual row overflow is checked by the
    /// preference-based WidgetGeometryTests; a GeometryReader's intrinsic size
    /// alone cannot prove that its descendants fit. OS backgrounds, margins,
    /// tint, and registration require the separate WidgetKit preview.
    private func assertRendersAndFits(
        _ snapshot: AIMeterWidgetSnapshot,
        on canvas: WidgetUIFixtures.Canvas,
        name: String,
        colorScheme: ColorScheme = .light,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fittingView = NSHostingView(rootView: content(snapshot, on: canvas, colorScheme: colorScheme)
            .frame(width: canvas.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true))
        fittingView.layoutSubtreeIfNeeded()
        let fittingSize = fittingView.fittingSize
        let context = "\(canvas.label)/\(name)"
        XCTAssertTrue(fittingSize.width.isFinite && fittingSize.height.isFinite,
                      "Non-finite fitting size: \(context)", file: file, line: line)
        XCTAssertGreaterThan(fittingSize.height, 0,
                             "Content has no fitting height: \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(fittingSize.width, canvas.width + 1,
                                 "Content exceeds available width: \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(fittingSize.height, canvas.height + 1,
                                 "Content exceeds available height: \(context), \(fittingSize)",
                                 file: file, line: line)

        let image = try render(snapshot, on: canvas, colorScheme: colorScheme, file: file, line: line)
        XCTAssertEqual(image.width, Int(canvas.width * 2), context, file: file, line: line)
        XCTAssertEqual(image.height, Int(canvas.height * 2), context, file: file, line: line)
        try writePreviewIfRequested(image, name: "\(canvas.label)-\(name)")
    }

    private func content(
        _ snapshot: AIMeterWidgetSnapshot,
        on canvas: WidgetUIFixtures.Canvas,
        colorScheme: ColorScheme
    ) -> some View {
        AIMeterWidgetContent(snapshot: snapshot, family: canvas.family)
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
    }

    private func render(
        _ snapshot: AIMeterWidgetSnapshot,
        on canvas: WidgetUIFixtures.Canvas,
        colorScheme: ColorScheme,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGImage {
        let renderView = content(snapshot, on: canvas, colorScheme: colorScheme)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .background(colorScheme == .dark ? Color.black : Color.white)
        let renderer = ImageRenderer(content: renderView)
        renderer.proposedSize = ProposedViewSize(canvas.size)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage, "No rendered image: \(canvas.label)", file: file, line: line)
    }

    private func writePreviewIfRequested(_ image: CGImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AIMETER_WIDGET_PREVIEW_DIR"],
              !directory.isEmpty else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let representation = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
