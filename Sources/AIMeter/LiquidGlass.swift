import SwiftUI
import AppKit
import AIMeterCore

// MARK: - Native Visual Effect View (Dynamic Wallpaper & Behind-Window Blur)
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var isEmphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = isEmphasized
    }
}

// MARK: - Provider Semantic Accent & Icon Helpers (Calm macOS System Palette)
func providerAccentColor(for identifier: String) -> Color {
    let lower = identifier.lowercased()
    if lower.contains("openai") || lower.contains("gpt") || lower.contains("codex") {
        return .teal
    } else if lower.contains("gemini") || lower.contains("gem") {
        return .blue
    } else if lower.contains("claude") || lower.contains("cld") {
        return .orange
    } else if lower.contains("cursor") || lower.contains("cur") {
        return .cyan
    } else if lower.contains("windsurf") || lower.contains("wind") {
        return .mint
    } else if lower.contains("copilot") || lower.contains("cop") {
        return .indigo
    } else if lower.contains("grok") {
        return .purple
    } else {
        return .accentColor
    }
}

func providerIconName(for titleOrId: String, fallback: String = "cpu") -> String {
    let lower = titleOrId.lowercased()
    if lower.contains("openai") || lower.contains("gpt") || lower.contains("codex") {
        return "brain.head.profile"
    } else if lower.contains("gemini") {
        return "sparkle"
    } else if lower.contains("claude") {
        return "bubble.left.and.bubble.right.fill"
    } else if lower.contains("cursor") {
        return "terminal.fill"
    } else if lower.contains("windsurf") {
        return "wind"
    } else if lower.contains("copilot") {
        return "chevron.left.forwardslash.chevron.right"
    } else if lower.contains("grok") {
        return "sparkles"
    }
    return fallback
}

// MARK: - Liquid Glass Window & Popover Background (macOS Tahoe Default App Harmony)
struct LiquidGlassBackground: View {
    var cornerRadius: CGFloat = 18
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                // Native macOS behind-window vibrancy and neutral surface sheen.
                VisualEffectBlur(
                    material: material,
                    blendingMode: blendingMode,
                    state: .active,
                    isEmphasized: false
                )
                .clipShape(shape)

                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark
                                    ? Color.white.opacity(0.055)
                                    : Color.white.opacity(0.42),
                                colorScheme == .dark
                                    ? Color.white.opacity(0.015)
                                    : Color.white.opacity(0.18)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            if colorSchemeContrast == .increased {
                shape.strokeBorder(Color.primary, lineWidth: 1)
            } else if reduceTransparency {
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.65)
            } else {
                // Subtle hairline specular rim.
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: colorScheme == .dark ? Color.white.opacity(0.32) : Color.white.opacity(0.75), location: 0.0),
                                .init(color: colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.35), location: 0.5),
                                .init(color: colorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.45), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
            }
        }
    }
}

// MARK: - Layered Frosted Glass Card (macOS Control Center Module Tile Style)
struct FrostedGlassCardBackground: View {
    var cornerRadius: CGFloat = 12
    var accentTint: Color? = nil
    var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                // Neutral translucent module surface (matches Control Center sub-tiles).
                shape
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(isHovered ? 0.085 : 0.06)
                            : Color.white.opacity(isHovered ? 0.65 : 0.50)
                    )
            }

            if colorSchemeContrast == .increased {
                shape.strokeBorder(Color.primary, lineWidth: 1)
            } else if reduceTransparency {
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            } else {
                // Subtle top specular highlight.
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark
                                    ? Color.white.opacity(isHovered ? 0.24 : 0.15)
                                    : Color.white.opacity(isHovered ? 0.80 : 0.62),
                                colorScheme == .dark
                                    ? Color.white.opacity(isHovered ? 0.08 : 0.04)
                                    : Color.white.opacity(isHovered ? 0.30 : 0.20)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.03),
            radius: 3,
            x: 0,
            y: 1
        )
    }
}

// MARK: - Liquid Glass Icon Orb (Clean macOS System Settings / Control Center Icon Badge)
struct LiquidGlassIconOrb: View {
    let systemName: String
    var accent: Color = .accentColor
    var size: CGFloat = 22
    var iconSize: CGFloat = 11.5
    var serviceID: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        if let serviceID, ServiceIdentity(serviceID: serviceID) != nil {
            ServiceIcon(serviceID: serviceID, fallbackSystemName: systemName, size: size, tint: accent)
        } else {
            systemIcon
        }
    }

    private var systemIcon: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)

        return ZStack {
            shape
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.045)
                )

            shape
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.16 : 0.55),
                    lineWidth: 0.5
                )

            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Liquid Glass Capsule Badge (Subtle Native Pill)
struct LiquidGlassBadge: View {
    let text: String
    var icon: String? = nil
    var tint: Color? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .font(.caption2.weight(.medium).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(
            Capsule(style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.065)
                        : Color.black.opacity(0.045)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(colorScheme == .dark ? 0.12 : 0.45),
                            lineWidth: 0.5
                        )
                )
        )
    }
}

// MARK: - Liquid Glass Progress Bar (Refined macOS Control Center / Battery Gauge)
struct LiquidGlassProgressBar: View {
    let ratio: Double
    var accent: Color = .accentColor
    var height: CGFloat = 6.0
    @Environment(\.colorScheme) private var colorScheme

    private var clampedRatio: Double {
        min(max(ratio, 0.0), 1.0)
    }

    private var barColor: Color {
        if clampedRatio < 0.15 {
            return .red
        } else if clampedRatio < 0.35 {
            return .orange
        } else {
            return Color.primary.opacity(colorScheme == .dark ? 0.72 : 0.62)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let fullWidth = max(0, geo.size.width)
            let fillWidth = max(height, fullWidth * CGFloat(clampedRatio))

            ZStack(alignment: .leading) {
                // 1. Subtle recessed glass track
                Capsule(style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.10)
                            : Color.black.opacity(0.08)
                    )

                // 2. Smooth glass fill with subtle top sheen
                if clampedRatio > 0.005 {
                    ZStack(alignment: .top) {
                        Capsule(style: .continuous)
                            .fill(barColor)

                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.25 : 0.35),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: height * 0.5)
                    }
                    .frame(width: min(fullWidth, fillWidth), height: height)
                    .animation(.easeOut(duration: 0.25), value: clampedRatio)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Glass Capsule Button Style (Native macOS 26 Glass Button Harmony)
struct GlassCapsuleButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var isProminent: Bool = false
    var cornerRadius: CGFloat = 7
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        GlassCapsuleButtonBody(
            configuration: configuration,
            isSelected: isSelected,
            isProminent: isProminent,
            cornerRadius: cornerRadius,
            colorScheme: colorScheme
        )
    }

    private struct GlassCapsuleButtonBody: View {
        let configuration: Configuration
        let isSelected: Bool
        let isProminent: Bool
        let cornerRadius: CGFloat
        let colorScheme: ColorScheme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var colorSchemeContrast
        @State private var isHovered: Bool = false

        var body: some View {
            let shape = Capsule(style: .continuous)
            let isPressed = isEnabled && configuration.isPressed
            let isHovering = isEnabled && isHovered

            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .foregroundStyle(
                    isProminent
                        ? Color.white
                        : (isSelected ? Color.accentColor : Color.primary)
                )
                .background(
                    ZStack {
                        if isProminent {
                            shape
                                .fill(Color.accentColor.opacity(isPressed ? 0.85 : (isHovering ? 0.95 : 0.90)))
                        } else {
                            shape
                                .fill(
                                    isSelected
                                        ? Color.accentColor.opacity(isPressed ? 0.22 : 0.15)
                                        : (colorScheme == .dark
                                            ? Color.white.opacity(isPressed ? 0.16 : (isHovering ? 0.12 : 0.08))
                                            : Color.black.opacity(isPressed ? 0.10 : (isHovering ? 0.07 : 0.045)))
                                )
                        }

                        if colorSchemeContrast == .increased {
                            shape.strokeBorder(isProminent ? Color.white : Color.primary, lineWidth: 1)
                        } else {
                            shape
                                .strokeBorder(
                                    Color.white.opacity(
                                        isProminent
                                            ? 0.35
                                            : (colorScheme == .dark ? (isHovering ? 0.24 : 0.14) : 0.55)
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                    }
                )
                .overlay {
                    if isEnabled && isFocused {
                        shape
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-3)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(isPressed ? 0.98 : 1.0)
                .animation(isEnabled ? .easeOut(duration: 0.12) : nil, value: isPressed)
                .onHover { hovering in
                    self.isHovered = isEnabled && hovering
                }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled {
                        self.isHovered = false
                    }
                }
        }
    }
}

// MARK: - Interactive Liquid Glass Toolbar Icon Button (Finder / Safari Unified Toolbar Style)
struct LiquidGlassToolbarIconButton: View {
    let systemName: String
    var isActive: Bool = false
    var isLoading: Bool = false
    var helpText: String = ""
    let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(isHovered ? 0.20 : 0.14)
                            : (isHovered
                                ? (colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.06))
                                : Color.clear)
                    )

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? Color.accentColor : (isHovered ? Color.primary : Color.secondary))
                }
            }
            .frame(width: 26, height: 22)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(isLoading)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Liquid Glass Floating Pill Toolbar Container (macOS Tahoe Native Toolbar Pill)
struct LiquidGlassToolbarPill<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 26.0, *) {
            HStack(spacing: 1) {
                content
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            HStack(spacing: 1) {
                content
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.65))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(colorScheme == .dark ? 0.18 : 0.65),
                                lineWidth: 0.5
                            )
                    )
            )
        }
    }
}
