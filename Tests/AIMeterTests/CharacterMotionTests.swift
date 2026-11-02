import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import AIMeter

final class CharacterMotionTests: XCTestCase {
    func testMotionStaysSubtleAndBlinksReturnToOpenEyes() {
        for frame in 0...3600 {
            let motion = CharacterMotionFrame.at(Double(frame) / 60)
            XCTAssertTrue((-2...2).contains(motion.offsetY))
            XCTAssertTrue((0.125...1).contains(motion.eyeScale))
            XCTAssertTrue((0.94...1.06).contains(motion.shadowScale))
            XCTAssertTrue((0.064...0.096).contains(motion.shadowOpacity))
        }
        XCTAssertEqual(CharacterMotionFrame.at(0), .rest)
        XCTAssertEqual(CharacterMotionFrame.at(.nan), .rest)
        XCTAssertEqual(CharacterMotionFrame.at(-1), .rest)
        for onset in [3.6, 9.2] {
            XCTAssertEqual(CharacterMotionFrame.at(onset - 0.01).eyeScale, 1)
            XCTAssertEqual(CharacterMotionFrame.at(onset + 0.08).eyeScale, 0.125, accuracy: 0.001)
            XCTAssertEqual(CharacterMotionFrame.at(onset + 0.21).eyeScale, 1)
        }
        XCTAssertEqual(CharacterMotionFrame.at(1.2).offsetY, -2, accuracy: 0.001)
        XCTAssertEqual(CharacterMotionFrame.at(3.6).offsetY, 2, accuracy: 0.001)
        XCTAssertEqual(CharacterMotionFrame.at(4.8 - 0.001).offsetY,
                       CharacterMotionFrame.at(4.8 + 0.001).offsetY, accuracy: 0.01)
    }

    @MainActor
    func testMotionFramesKeepFixedBoundsAndExportOptionalSyntheticPreview() throws {
        let directory = ProcessInfo.processInfo.environment["AIMETER_PREVIEW_DIR"]
        let destination: CGImageDestination?
        if let directory {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("character-motion.gif") as CFURL,
                                                          UTType.gif.identifier as CFString, 360, nil)
            XCTAssertNotNil(destination)
            if let destination {
                CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            }
        } else {
            destination = nil
        }
        let times = destination == nil ? [0, 1.2, 3.6, 3.68, 3.81, 4.8] : (0..<360).map { Double($0) / 30 }
        for time in times {
            let content = LiquidBallArtwork(contrast: .standard, colorScheme: .light,
                                            reduceTransparency: false, motion: .at(time))
                .frame(width: 48, height: 54)
                .padding(12)
                .background(Color.white)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 216)
            XCTAssertEqual(image.height, 234)
            if let destination {
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30.0]] as CFDictionary)
            }
        }
        if let destination { XCTAssertTrue(CGImageDestinationFinalize(destination)) }
    }

    @MainActor
    func testVisibilityTracksOnlyItsHostAndCleansUpOnDetach() async {
        // Synthetic window flags: no windows are shown and no OS preferences are changed.
        let first = VisibilityTestWindow()
        let second = VisibilityTestWindow()
        let view = CharacterVisibilityView()
        var observations: [Bool] = []
        view.onChange = { observations.append($0) }
        first.contentView = view
        await drainMainQueue()
        XCTAssertEqual(observations.last, true)

        // Being inactive/non-key is deliberately not part of the visibility predicate.
        XCTAssertFalse(first.isKeyWindow)
        first.testMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: first)
        await drainMainQueue()
        XCTAssertEqual(observations.last, false)

        first.testMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: first)
        await drainMainQueue()
        XCTAssertEqual(observations.last, true)

        first.testOccluded = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: first)
        await drainMainQueue()
        XCTAssertEqual(observations.last, false)

        second.contentView = view
        await drainMainQueue()
        XCTAssertEqual(observations.last, true)
        let count = observations.count
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: first)
        await drainMainQueue()
        XCTAssertEqual(observations.count, count, "Old host must no longer notify")

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: second)
        await drainMainQueue()
        XCTAssertEqual(observations.last, false)
        view.removeFromSuperview()
        await drainMainQueue()
        let detachedCount = observations.count
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: second)
        await drainMainQueue()
        XCTAssertEqual(observations.count, detachedCount)
    }

    @MainActor
    func testAnimationKeepsItsVisibilityProbeAcrossStartupAndReduceMotionChanges() async throws {
        let window = VisibilityTestWindow()
        var content = CharacterSummaryContent(highlight: .init(tone: .calm, title: "ひとこと", message: "確認しているよ。"),
                                              reduceTransparency: false, contrast: .standard, colorScheme: .light,
                                              motionEnabled: true)
        let host = NSHostingView(rootView: content)
        host.frame = .init(x: 0, y: 0, width: 320, height: 120)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let initialProbe = try XCTUnwrap(visibilityProbe(in: host))
        // Include the first blink, so static -> timeline cannot keep resetting the view.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(visibilityProbe(in: host) === initialProbe)

        content.motionEnabled = false
        host.rootView = content
        host.layoutSubtreeIfNeeded()
        await drainMainQueue()
        XCTAssertNil(visibilityProbe(in: host), "Reduced motion must remove the animation visibility observer")
        content.motionEnabled = true
        host.rootView = content
        host.layoutSubtreeIfNeeded()
        await drainMainQueue()
        XCTAssertNotNil(visibilityProbe(in: host))
        window.contentView = nil
    }

    @MainActor
    private func visibilityProbe(in view: NSView) -> CharacterVisibilityView? {
        if let probe = view as? CharacterVisibilityView { return probe }
        return view.subviews.lazy.compactMap { self.visibilityProbe(in: $0) }.first
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class VisibilityTestWindow: NSWindow {
    var testMiniaturized = false
    var testOccluded = false
    override var isVisible: Bool { true }
    override var isMiniaturized: Bool { testMiniaturized }
    override var occlusionState: NSWindow.OcclusionState { testOccluded ? [] : .visible }

    init() {
        super.init(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
}
