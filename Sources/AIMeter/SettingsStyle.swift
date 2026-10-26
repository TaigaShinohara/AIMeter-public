import SwiftUI
import AppKit

/// Settings share the main panel's surfaces while keeping native input controls.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .toggleStyle(.switch)
        .textFieldStyle(.roundedBorder)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FrostedGlassCardBackground(cornerRadius: 12))
    }
}

struct SettingsLabeledContent<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        LabeledContent(title) {
            content.labeledContentStyle(.automatic)
        }
        .labeledContentStyle(SettingsLabeledContentStyle())
    }
}

struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
    }
}

struct SettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .frame(width: 152, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            configuration.content
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Only changes the settings window's surface; widget level, Spaces and frame
/// persistence belong to DesktopWidgetWindowAccessor and are deliberately separate.
struct SettingsWindowAccessor: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SettingsWindowAccessor.configure(window) }
        }
    }

    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ nsView: WindowView, context: Context) {
        if let window = nsView.window { Self.configure(window) }
    }

    private static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}
