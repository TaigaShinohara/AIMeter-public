import AIMeterCore
@testable import AIMeterWidgetUI
import AppKit
import SwiftUI
import WidgetKit
import XCTest

@MainActor
final class WidgetGeometryTests: XCTestCase {
    func testVisibleRowsStayInsideContentWithoutOverlappingAtEveryServiceCount() throws {
        for canvas in WidgetUIFixtures.canvases {
            for count in [0, 1, 2, 3, 6, 7] {
                for showUsage in [false, true] {
                    let snapshot = WidgetUIFixtures.snapshot(count: count, showUsage: showUsage, longText: true)
                    let frames = try measure(snapshot, on: canvas)
                    let expected = visibleServices(in: snapshot, family: canvas.family)
                    let rows = frames.filter { $0.key.hasPrefix("row:") }
                    XCTAssertEqual(Set(rows.keys), Set(expected.map { "row:\($0.id)" }), canvas.label)
                    let bounds = CGRect(origin: .zero, size: canvas.size)
                    for (key, frame) in rows {
                        assertContained(frame, in: bounds, description: "\(canvas.label)/\(key)")
                    }
                    let orderedRows = rows.values.sorted { $0.minY < $1.minY }
                    for (upper, lower) in zip(orderedRows, orderedRows.dropFirst()) {
                        XCTAssertLessThanOrEqual(upper.maxY, lower.minY + 1,
                            "Service rows overlap: \(canvas.label), count \(count), usage \(showUsage)")
                    }
                }
            }
        }
    }

    func testProgressFillUsesTheActualRatioIncludingZeroAndFullWidth() throws {
        for canvas in WidgetUIFixtures.canvases {
            for percent in [0, 1, 15, 16, 35, 36, 99, 100] {
                let snapshot = WidgetUIFixtures.snapshot(count: 1, showUsage: true, percent: percent)
                let id = try XCTUnwrap(snapshot.allServices.first?.id)
                let frames = try measure(snapshot, on: canvas)
                let track = try XCTUnwrap(frames["bar.track:\(id)"], "Missing progress track")
                let fill = try XCTUnwrap(frames["bar.fill:\(id)"], "Missing progress fill measurement")
                XCTAssertGreaterThan(track.width, 0)
                XCTAssertEqual(fill.minX, track.minX, accuracy: 1)
                XCTAssertEqual(fill.width, track.width * CGFloat(percent) / 100, accuracy: 0.75,
                               "Progress misrepresents \(percent)%: \(canvas.label)")
                XCTAssertLessThanOrEqual(fill.width, track.width + 0.75)
                if percent == 0 {
                    XCTAssertEqual(fill.width, 0, accuracy: 0.001, "Zero quota must have no visible fill")
                }
                if percent == 100 {
                    XCTAssertEqual(fill.maxX, track.maxX, accuracy: 0.75)
                }
            }
        }
    }

    func testQuotaKindsSharePrimaryAndBarEdgesWithoutInventingUnknownBars() throws {
        for canvas in WidgetUIFixtures.canvases {
            let snapshot = WidgetUIFixtures.mixedSnapshot(showUsage: true)
            let frames = try measure(snapshot, on: canvas)
            let services = visibleServices(in: snapshot, family: canvas.family)
            let primaryFrames = try services.map { try XCTUnwrap(frames["primary:\($0.id)"]) }
            for (first, next) in zip(primaryFrames, primaryFrames.dropFirst()) {
                XCTAssertEqual(first.maxX, next.maxX, accuracy: 1,
                               "Primary values must share a right edge: \(canvas.label)")
            }
            let tracks = try services.filter(\.isRemainingAvailable).map {
                try XCTUnwrap(frames["bar.track:\($0.id)"])
            }
            for (first, next) in zip(tracks, tracks.dropFirst()) {
                XCTAssertEqual(first.minX, next.minX, accuracy: 1, canvas.label)
                XCTAssertEqual(first.maxX, next.maxX, accuracy: 1, canvas.label)
            }
            for item in services where !item.isRemainingAvailable {
                XCTAssertNil(frames["bar.track:\(item.id)"], "Unavailable quota must not show a track")
                XCTAssertNil(frames["bar.fill:\(item.id)"], "Unavailable quota must not show a fill")
            }
        }
    }

    func testUsageVisibilityAndLongPeriodsKeepTheirOwnAllocatedAreas() throws {
        for canvas in WidgetUIFixtures.canvases {
            for showUsage in [false, true] {
                let snapshot = WidgetUIFixtures.mixedSnapshot(showUsage: showUsage)
                let frames = try measure(snapshot, on: canvas)
                for item in visibleServices(in: snapshot, family: canvas.family) {
                    let usage = frames["usage:\(item.id)"]
                    if showUsage && !item.isQuotaOnly {
                        let usageFrame = try XCTUnwrap(usage, "Usage must remain present: \(item.id)")
                        let period = try XCTUnwrap(frames["period:\(item.id)"])
                        XCTAssertGreaterThan(usageFrame.width, 0)
                        XCTAssertGreaterThan(usageFrame.height, 0)
                        XCTAssertFalse(period.intersects(usageFrame.insetBy(dx: 0.5, dy: 0.5)),
                            "Long period must not displace or overlap usage: \(canvas.label)/\(item.id)")
                    } else {
                        XCTAssertNil(usage, "Usage amounts must respect settings and quota-only semantics")
                    }
                }
            }
        }
    }

    func testLongTextAndFullUnavailableMessagesStayInsideTheirServiceRows() throws {
        for canvas in WidgetUIFixtures.canvases {
            for source in [RemainingQuotaSource.configuredLimit, .unavailable] {
                let snapshot = WidgetUIFixtures.snapshot(
                    count: 7, showUsage: true, percent: 100,
                    source: source, longText: true, updateFailed: true
                )
                let frames = try measure(snapshot, on: canvas)
                for item in visibleServices(in: snapshot, family: canvas.family) {
                    let row = try XCTUnwrap(frames["row:\(item.id)"])
                    for component in ["primary", "period", "usage"] {
                        let frame = try XCTUnwrap(frames["\(component):\(item.id)"])
                        assertContained(frame, in: row,
                            description: "\(canvas.label)/\(source.rawValue)/\(component)")
                    }
                    if source != .unavailable && canvas.family != .systemMedium {
                        let reset = try XCTUnwrap(frames["reset:\(item.id)"])
                        assertContained(reset, in: row, description: "\(canvas.label)/reset")
                        let period = try XCTUnwrap(frames["period:\(item.id)"])
                        XCTAssertGreaterThanOrEqual(reset.minY, period.maxY,
                            "Reset must follow the period without overlapping: \(canvas.label)")
                    } else {
                        XCTAssertNil(frames["reset:\(item.id)"])
                    }
                }
            }
        }
    }

    func testSmallWidgetKeepsTheFullPercentageAndRemainingLabelInsideItsContent() throws {
        let canvas = try XCTUnwrap(WidgetUIFixtures.canvases.first { $0.family == .systemSmall })
        let bounds = CGRect(origin: .zero, size: canvas.size)
        for scheme in [ColorScheme.light, .dark] {
            for source in [RemainingQuotaSource.official, .configuredLimit] {
                for percent in [0, 1, 15, 16, 35, 36, 99, 100] {
                    let snapshot = WidgetUIFixtures.snapshot(
                        count: 7, showUsage: true, percent: percent,
                        source: source, longText: true, updateFailed: true
                    )
                    let item = try XCTUnwrap(snapshot.mostCriticalService)
                    let frames = try measure(snapshot, on: canvas, colorScheme: scheme)
                    let context = "small/\(scheme)/\(source.rawValue)/\(percent)"
                    let row = try XCTUnwrap(frames["row:\(item.id)"])
                    let primary = try XCTUnwrap(frames["primary:\(item.id)"])
                    let value = try XCTUnwrap(frames["primary.percent:\(item.id)"])
                    let remaining = try XCTUnwrap(frames["primary.label:\(item.id)"])
                    let name = try XCTUnwrap(frames["name:\(item.id)"])

                    // The row and primary container can fit even when their
                    // fixed-size text children overflow. Check each child's
                    // natural frame so 約100% or 残り cannot pass by clipping.
                    for (component, frame) in [("name", name), ("value", value), ("remaining", remaining)] {
                        assertContained(frame, in: row, description: "\(context)/\(component)/row")
                        assertContained(frame, in: bounds, description: "\(context)/\(component)/content")
                    }
                    assertContained(value, in: primary, description: "\(context)/value/primary")
                    assertContained(remaining, in: primary, description: "\(context)/remaining/primary")
                    XCTAssertLessThanOrEqual(value.maxX + 4, remaining.minX + 0.5,
                        "The full percentage and 残り must have separate space: \(context)")
                    XCTAssertGreaterThanOrEqual(primary.minY, name.maxY,
                        "The primary value must not overlap the service name: \(context)")
                }
            }
        }
    }

    private func visibleServices(in snapshot: AIMeterWidgetSnapshot, family: WidgetFamily) -> [WidgetServiceItem] {
        guard snapshot.hasData else { return [] }
        switch family {
        case .systemSmall:
            return (snapshot.mostCriticalService ?? snapshot.allServices.first).map { [$0] } ?? []
        case .systemMedium:
            return snapshot.topServices
        default:
            return Array(snapshot.allServices.prefix(6))
        }
    }

    /// Captures preferences from a real NSHostingView in a never-presented
    /// window. No production app, preferences, cache, or collectors are used.
    private func measure(
        _ snapshot: AIMeterWidgetSnapshot,
        on canvas: WidgetUIFixtures.Canvas,
        colorScheme: ColorScheme = .light,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: CGRect] {
        _ = NSApplication.shared
        let capture = FrameCapture()
        let view = AIMeterWidgetContent(snapshot: snapshot, family: canvas.family)
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .onPreferenceChange(WidgetLayoutFramesKey.self) { capture.frames = $0 }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: canvas.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = CGRect(origin: .zero, size: canvas.size)
        host.layoutSubtreeIfNeeded()
        let expectedIDs = visibleServices(in: snapshot, family: canvas.family).map { "row:\($0.id)" }
        let deadline = Date().addingTimeInterval(0.5)
        while (capture.frames["content"] == nil || expectedIDs.contains { capture.frames[$0] == nil }),
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertFalse(window.isVisible, "Geometry tests must not present windows", file: file, line: line)
        XCTAssertNotNil(capture.frames["content"],
                        "Content did not report its actual layout: \(canvas.label)", file: file, line: line)
        return capture.frames
    }

    private func assertContained(
        _ frame: CGRect,
        in bounds: CGRect,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite &&
                      frame.width.isFinite && frame.height.isFinite,
                      "Non-finite geometry: \(description)", file: file, line: line)
        XCTAssertGreaterThan(frame.width, 0, description, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, description, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 1, description, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 1, description, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 1, description, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 1, description, file: file, line: line)
    }
}

@MainActor
private final class FrameCapture {
    var frames: [String: CGRect] = [:]
}
