import SwiftUI
import AIMeterCore

struct CharacterSummaryView: View {
    let highlight: UsageHighlight
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CharacterSummaryContent(highlight: highlight, reduceTransparency: reduceTransparency,
                                contrast: contrast, colorScheme: colorScheme, motionEnabled: !reduceMotion)
    }
}

/// Explicit appearance inputs keep rendering deterministic without changing OS preferences.
struct CharacterSummaryContent: View {
    let highlight: UsageHighlight
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast
    let colorScheme: ColorScheme
    var motionEnabled: Bool = false

    private var accent: Color {
        switch highlight.tone {
        case .urgent: return .red
        case .attention: return .orange
        case .checking: return .secondary
        case .calm: return .teal
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                LiquidBallView(contrast: contrast, colorScheme: colorScheme,
                               reduceTransparency: reduceTransparency, motionEnabled: motionEnabled)
                    .frame(width: 48, height: 54)

                Text("リボ")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
            }
            .padding(.top, 7)
            .help("LiquidBall（リボ）")
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    if highlight.tone == .urgent || highlight.tone == .attention {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    Text(highlight.title)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(contrast == .increased ? Color.primary : accent)

                Text(highlight.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)

                if let detail = highlight.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background {
                SpeechBubbleShape()
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                SpeechBubbleShape()
                    .strokeBorder(contrast == .increased ? Color.primary : accent.opacity(0.22),
                                  lineWidth: contrast == .increased ? 1.5 : 0.75)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LiquidBall、リボ。\(highlight.title)。\(highlight.message)\(highlight.detail ?? "")")
        .accessibilityIdentifier("character-summary")
    }
}

/// Only the character updates each frame; the message and layout remain still.
private struct LiquidBallView: View {
    let contrast: ColorSchemeContrast
    let colorScheme: ColorScheme
    let reduceTransparency: Bool
    let motionEnabled: Bool
    @State private var isWindowVisible = false
    @State private var startedAt = Date()

    var body: some View {
        ZStack {
            if motionEnabled && isWindowVisible {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    LiquidBallArtwork(contrast: contrast, colorScheme: colorScheme,
                                      reduceTransparency: reduceTransparency,
                                      isInteractive: motionEnabled,
                                      motion: .at(context.date.timeIntervalSince(startedAt)))
                }
            } else {
                LiquidBallArtwork(contrast: contrast, colorScheme: colorScheme,
                                  reduceTransparency: reduceTransparency, motion: .rest)
            }
        }
        .background {
            if motionEnabled {
                CharacterVisibilityReader { visible in
                    if visible && !isWindowVisible { startedAt = Date() }
                    isWindowVisible = visible
                }
            }
        }
        .onChange(of: motionEnabled) { _, enabled in
            if enabled { startedAt = Date() }
        }
        .onDisappear { isWindowVisible = false }
    }
}

/// Time-derived motion is reproducible for previews and independent of usage refreshes.
struct CharacterMotionFrame: Equatable {
    let offsetY: CGFloat
    let eyeScale: CGFloat
    let shadowScale: CGFloat
    let shadowOpacity: Double

    static let rest = CharacterMotionFrame(offsetY: 0, eyeScale: 1, shadowScale: 1, shadowOpacity: 0.08)

    static func at(_ elapsed: TimeInterval) -> CharacterMotionFrame {
        guard elapsed.isFinite, elapsed >= 0 else { return .rest }
        let offset = -2 * sin(elapsed.truncatingRemainder(dividingBy: 4.8) / 4.8 * 2 * .pi)
        let blinkTime = elapsed.truncatingRemainder(dividingBy: 5.6) - 3.6
        let closure: Double
        switch blinkTime {
        case 0..<0.06: closure = smoothstep(blinkTime / 0.06)
        case 0.06..<0.10: closure = 1
        case 0.10..<0.20: closure = 1 - smoothstep((blinkTime - 0.10) / 0.10)
        default: closure = 0
        }
        return .init(offsetY: offset, eyeScale: 1 - closure * 0.875,
                     shadowScale: 1 + offset * 0.03, shadowOpacity: 0.08 + offset * 0.008)
    }

    private static func smoothstep(_ value: Double) -> Double { value * value * (3 - 2 * value) }
}

private struct SpeechBubbleShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: inset, dy: inset)
        var path = Path(roundedRect: body, cornerRadius: 12)
        path.move(to: CGPoint(x: body.minX + 0.5, y: body.minY + 20))
        path.addLine(to: CGPoint(x: body.minX - 6, y: body.minY + 25))
        path.addLine(to: CGPoint(x: body.minX + 0.5, y: body.minY + 30))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> SpeechBubbleShape { .init(inset: inset + amount) }
}
