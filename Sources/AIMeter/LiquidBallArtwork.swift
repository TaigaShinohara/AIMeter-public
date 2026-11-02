import SwiftUI

/// LiquidBall (リボ): a clear droplet with two eyes. Its color never encodes usage.
struct LiquidBallArtwork: View {
    let contrast: ColorSchemeContrast
    let colorScheme: ColorScheme
    let reduceTransparency: Bool
    var isInteractive: Bool = false
    var motion: CharacterMotionFrame = .rest

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(motion.shadowOpacity))
                .frame(width: 30, height: 5)
                .scaleEffect(x: motion.shadowScale, y: 1)
                .blur(radius: 2)
                .offset(y: 25)

            ZStack {
                shell
                    .frame(width: 46, height: 46)
                    // Surface tension: a barely perceptible flex, driven by the existing float.
                    .scaleEffect(x: 1 - motion.offsetY * 0.006,
                                 y: 1 + motion.offsetY * 0.006)

                HStack(spacing: 7) {
                    Capsule().frame(width: 4, height: 8)
                    Capsule().frame(width: 4, height: 8)
                }
                .foregroundStyle(isDark ? Color.white : Color(red: 0.08, green: 0.20, blue: 0.24))
                .shadow(color: isDark ? .black.opacity(0.25) : .white.opacity(0.7), radius: 1, y: 0.5)
                .scaleEffect(x: 1, y: motion.eyeScale)
                .offset(x: 2, y: 1)
            }
            .offset(y: motion.offsetY)
        }
    }

    private var shell: some View {
        ZStack {
            glassBase

            if contrast == .increased || reduceTransparency {
                Circle()
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.4),
                                  lineWidth: contrast == .increased ? 1.5 : 0.8)
            }
        }
    }

    @ViewBuilder
    private var glassBase: some View {
        if reduceTransparency {
            Circle().fill(Color(nsColor: .controlBackgroundColor))
        } else if #available(macOS 26.0, *) {
            // Clear is the most translucent native variant. No fill, tint, or painted
            // highlights cover the system's refraction and specular rim. Keep the
            // effect at full view opacity; Glass exposes no optical-strength slider.
            Circle()
                .fill(Color.clear)
                .glassEffect(.clear.tint(nil).interactive(isInteractive), in: Circle())
                // The eyes are a sibling of the shell. Isolate its native glass
                // from ancestor containers so it cannot cover them when inactive.
                .liquidGlassGroup()
                .contentShape(Circle())
        } else {
            // Compatibility only: native Liquid Glass requires macOS 26.
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(isDark ? 0.12 : 0.24),
                                               .white.opacity(0.025), .white.opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75)
                }
        }
    }
}
