import AppKit
import SwiftUI

/// Observe each host window without changing its activation, level, or open/closed state.
struct CharacterVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> CharacterVisibilityView {
        let view = CharacterVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: CharacterVisibilityView, context: Context) {
        view.onChange = onChange
        view.updateVisibility()
    }

    static func dismantleNSView(_ view: CharacterVisibilityView, coordinator: ()) {
        view.stopObserving()
    }
}

final class CharacterVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastVisibility: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.updateVisibility()
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.publish(false)
            })
        }
        updateVisibility()
    }

    func updateVisibility() {
        publish(window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
    }

    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        publish(false)
    }

    private func publish(_ visible: Bool) {
        guard lastVisibility != visible else { return }
        lastVisibility = visible
        // Window attachment also happens during SwiftUI updates; publish on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastVisibility == visible else { return }
            self.onChange?(visible)
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
