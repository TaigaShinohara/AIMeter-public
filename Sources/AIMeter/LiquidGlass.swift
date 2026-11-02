import SwiftUI
import AppKit
import AIMeterCore

/// Native glass with no extra layout, painted highlights, or opacity on the effect.
/// Keep the shape's frame/padding at the call site so adopting glass does not resize UI.
struct LiquidGlassSurface<Surface: InsettableShape>: View {
    let shape: Surface
    var tint: Color? = nil
    var isInteractive: Bool = false
    var fallbackFill: Color = Color.primary.opacity(0.04)
    var opaqueFill: Color = Color(nsColor: .controlBackgroundColor)
    // Explicit inputs support synthetic previews; the OS environment values are read-only.
    var reduceTransparency: Bool? = nil
    var contrast: ColorSchemeContrast? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let reduceTransparency = self.reduceTransparency ?? systemReduceTransparency
        let contrast = self.contrast ?? systemContrast

        ZStack {
            if reduceTransparency {
                shape.fill(opaqueFill)
            } else if #available(macOS 26.0, *) {
                shape.fill(Color.clear)
                    .glassEffect(.clear.tint(tint).interactive(isInteractive && isEnabled && !reduceMotion),
                                 in: shape)
                    // Isolate background glass from ancestor containers so it
                    // cannot cover sibling content when the window is inactive.
                    // Keep accessibility outlines outside this local container.
                    .liquidGlassGroup()
            } else {
                shape.fill(fallbackFill)
                shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.55), lineWidth: 0.5)
            }

            if contrast == .increased {
                shape.strokeBorder(Color.primary, lineWidth: 1)
            } else if reduceTransparency {
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.65)
            }
        }
    }
}

/// Batch sibling glass surfaces without merging neighboring cards at rest.
private struct LiquidGlassGrouping: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

extension View {
    func liquidGlassGroup() -> some View { modifier(LiquidGlassGrouping()) }
}

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

// MARK: - Window backdrop beneath the native glass surfaces
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
                // Bring the desktop into the window using AppKit's public material.
                // The cards and controls above this backdrop own the Liquid Glass;
                // a second full-window glass layer would obscure their refraction.
                VisualEffectBlur(
                    material: material,
                    blendingMode: blendingMode,
                    state: .active,
                    isEmphasized: false
                )
                .clipShape(shape)

                if #unavailable(macOS 26.0) {
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
            }

            if colorSchemeContrast == .increased {
                shape.strokeBorder(Color.primary, lineWidth: 1)
            } else if reduceTransparency {
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.65)
            } else if #unavailable(macOS 26.0) {
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

// MARK: - Native Liquid Glass Card
struct FrostedGlassCardBackground: View {
    var cornerRadius: CGFloat = 12
    var accentTint: Color? = nil
    var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LiquidGlassSurface(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            fallbackFill: colorScheme == .dark
                ? Color.white.opacity(isHovered ? 0.085 : 0.06)
                : Color.white.opacity(isHovered ? 0.65 : 0.50)
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
            LiquidGlassSurface(shape: shape,
                               fallbackFill: colorScheme == .dark
                                   ? Color.white.opacity(0.08) : Color.black.opacity(0.045))

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
            LiquidGlassSurface(shape: Capsule(style: .continuous),
                               fallbackFill: colorScheme == .dark
                                   ? Color.white.opacity(0.065) : Color.black.opacity(0.045))
        )
    }
}

// MARK: - System Remaining-Capacity Gauge
struct RemainingQuotaGauge: View {
    let ratio: Double
    @Environment(\.colorScheme) private var colorScheme

    private var clampedRatio: Double { min(max(ratio, 0.0), 1.0) }

    private var barColor: Color {
        if clampedRatio < 0.15 { return .red }
        if clampedRatio < 0.35 { return .orange }
        return Color.primary.opacity(colorScheme == .dark ? 0.72 : 0.62)
    }

    var body: some View {
        Gauge(value: clampedRatio) {
            EmptyView()
        }
        .gaugeStyle(.linearCapacity)
        .controlSize(.small)
        .tint(barColor)
        .accessibilityLabel("残量")
    }
}

// MARK: - System Button Styles
/// Delegate rendering and interaction to Apple's controls, including disabled
/// appearance, keyboard focus, accessibility preferences, and pointer feedback.
struct NativeGlassButtonStyle: PrimitiveButtonStyle {
    var isSelected: Bool = false
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        styledButton(configuration)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func styledButton(_ configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            if isProminent {
                Button(configuration)
                    .buttonStyle(.glassProminent)
            } else {
                Button(configuration)
                    .buttonStyle(.glass(.regular.tint(isSelected ? Color.accentColor : nil)))
            }
        } else if isProminent {
            Button(configuration)
                .buttonStyle(.borderedProminent)
        } else {
            Button(configuration)
                .buttonStyle(.bordered)
                .tint(isSelected ? Color.accentColor : nil)
        }
    }
}

// MARK: - Compact System Toolbar Controls
struct LiquidGlassToolbarIconButton: View {
    let systemName: String
    var isActive: Bool = false
    var isLoading: Bool = false
    var helpText: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 11))
                }
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(NativeGlassButtonStyle(isSelected: isActive))
        .controlSize(.small)
        .disabled(isLoading)
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

struct NativeToolbarControls<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
    }
}
