import AppKit
import XCTest
@testable import AIMeter

final class NativeWindowLayoutTests: XCTestCase {
    @MainActor
    func testDesktopWindowRecognitionSupportsSavedSceneAndBothTitles() {
        _ = NSApplication.shared
        let window = NonPresentingWindow(contentRect: NSRect(x: 80, y: 80, width: 348, height: 500),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("desktop-widget")
        window.title = "Different title supplied by the scene"
        XCTAssertTrue(isDesktopWidgetWindow(window))

        window.identifier = nil
        window.title = "AI Meter Widget"
        XCTAssertTrue(isDesktopWidgetWindow(window), "Previously opened windows must still be restorable")
        window.title = "AIMeter"
        XCTAssertTrue(isDesktopWidgetWindow(window))

        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.title = "AIMeter 設定"
        XCTAssertFalse(isDesktopWidgetWindow(window), "Closing the meter must not close settings")
        window.title = "一般"
        XCTAssertFalse(isDesktopWidgetWindow(window))
    }

    @MainActor
    func testPinConfigurationPreservesNativeWindowChromeAndContentGeometry() throws {
        _ = NSApplication.shared
        let window = NonPresentingWindow(contentRect: NSRect(x: 110, y: 130, width: 348, height: 520),
                                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                         backing: .buffered, defer: false)
        window.title = "AIMeter"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "NativeChromeRegression")
        window.toolbar = toolbar
        window.contentView?.layoutSubtreeIfNeeded()

        let frame = window.frame
        let contentLayoutRect = window.contentLayoutRect
        let styleMask = window.styleMask
        let background = try XCTUnwrap(window.backgroundColor)
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        XCTAssertEqual(buttons.count, 3)
        let buttonStates = buttons.map { (button: $0, hidden: $0.isHidden, enabled: $0.isEnabled, frame: $0.frame) }

        for (pinned, draggable) in [(true, true), (false, true), (false, false)] {
            DesktopWidgetWindowAccessor.configure(window: window, allowBackgroundDrag: draggable, isPinned: pinned)

            XCTAssertEqual(window.level, pinned ? .floating : .normal)
            XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
            XCTAssertEqual(window.isMovableByWindowBackground, draggable)
            XCTAssertEqual(window.styleMask, styleMask, "Pin changes must not add full-size content or replace native chrome")
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(window.contentLayoutRect, contentLayoutRect)
            XCTAssertTrue(window.backgroundColor?.isEqual(background) == true)
            XCTAssertTrue(window.isOpaque)
            XCTAssertEqual(window.titleVisibility, .visible)
            XCTAssertFalse(window.titlebarAppearsTransparent)
            XCTAssertEqual(window.titlebarSeparatorStyle, .line)
            XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
            XCTAssertTrue(window.toolbar === toolbar)
            for state in buttonStates {
                XCTAssertEqual(state.button.isHidden, state.hidden)
                XCTAssertEqual(state.button.isEnabled, state.enabled)
                XCTAssertEqual(state.button.frame, state.frame)
            }
        }
        XCTAssertEqual(window.autosaveRequests, Array(repeating: "AIMeterDesktopWidgetFrame", count: 3))
        XCTAssertEqual(window.presentationRequests, 1)
        XCTAssertFalse(window.isVisible, "This regression test must not present a real window")
    }
}

/// Keep the product's frame-persistence and activation calls observable without
/// writing a saved frame into the test runner's defaults or presenting test UI.
@MainActor
private final class NonPresentingWindow: NSWindow {
    var autosaveRequests: [String] = []
    var presentationRequests = 0

    override func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool {
        autosaveRequests.append(name)
        return true
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        presentationRequests += 1
    }
}
