import SwiftUI

/// Sweep's stage: a soft blue sky over gentle water, with a lit spot where the character
/// stands. Used in the app window and the welcome card. Without sprites, a bubbles glyph
/// holds the spot.
struct MascotScene: View {
    var state: MascotState = .idle
    var characterSize: CGFloat = 132

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private let bubbles: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.10, 0.62, 46, 0.14), (0.22, 0.24, 18, 0.26), (0.86, 0.18, 58, 0.12),
        (0.90, 0.56, 22, 0.22), (0.74, 0.34, 10, 0.4), (0.30, 0.46, 8, 0.4),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let ground = size.height * 0.74

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.19, green: 0.36, blue: 0.80),
                        Color(red: 0.36, green: 0.60, blue: 0.96),
                        Color(red: 0.62, green: 0.82, blue: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Light behind the character.
                RadialGradient(colors: [.white.opacity(0.42), .clear], center: .center, startRadius: 0, endRadius: characterSize * 1.1)
                    .frame(width: characterSize * 2.4, height: characterSize * 2.4)
                    .position(x: size.width / 2, y: ground - characterSize * 0.45)

                ForEach(bubbles.indices, id: \.self) { index in
                    let bubble = bubbles[index]
                    Circle()
                        .fill(.white.opacity(bubble.opacity))
                        .overlay(Circle().strokeBorder(.white.opacity(0.32), lineWidth: 1))
                        .frame(width: bubble.size, height: bubble.size)
                        .position(x: size.width * bubble.x, y: size.height * bubble.y)
                        .offset(y: appeared || reduceMotion ? 0 : 16)
                        .opacity(appeared ? 1 : 0)
                        .animation(Theme.Motion.smooth.delay(Double(index) * 0.05), value: appeared)
                }

                Wave(baseline: ground / size.height + 0.02, amplitude: 7, frequency: 1.3, phase: 0.6)
                    .fill(.white.opacity(0.14))
                Wave(baseline: ground / size.height + 0.08, amplitude: 5, frequency: 1.8, phase: 2.1)
                    .fill(.white.opacity(0.22))

                // Where the character stands: a soft shadow on the water.
                Ellipse()
                    .fill(Color(red: 0.08, green: 0.2, blue: 0.5).opacity(0.28))
                    .frame(width: characterSize * 0.5, height: characterSize * 0.09)
                    .blur(radius: 4)
                    .position(x: size.width / 2, y: ground + 4)

                // The mascot view's bottom edge is the character's feet.
                character
                    .frame(width: characterSize, height: characterSize, alignment: .bottom)
                    .position(x: size.width / 2, y: ground - characterSize / 2 + 2)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.88, anchor: .bottom)
                    .opacity(appeared ? 1 : 0)
                    .animation(Theme.Motion.celebrate, value: appeared)

                sparkle(size: 20, color: Theme.yellow, x: 0.70, y: 0.20, delay: 0.15)
                sparkle(size: 12, color: .white, x: 0.26, y: 0.40, delay: 0.22)
                sparkle(size: 9, color: Theme.yellow.opacity(0.9), x: 0.80, y: 0.46, delay: 0.3)
            }
            .frame(width: size.width, height: size.height)
        }
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var character: some View {
        if MascotView.hasSprites {
            MascotView(state: state, size: characterSize)
        } else {
            Image(systemName: "bubbles.and.sparkles.fill")
                .font(.system(size: characterSize * 0.42, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: Color(red: 0.1, green: 0.25, blue: 0.6).opacity(0.35), radius: 10, y: 6)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, characterSize * 0.12)
        }
    }

    private func sparkle(size: CGFloat, color: Color, x: CGFloat, y: CGFloat, delay: Double) -> some View {
        GeometryReader { proxy in
            Image(systemName: "sparkle")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
                .position(x: proxy.size.width * x, y: proxy.size.height * y)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.3)
                .opacity(appeared ? 1 : 0)
                .animation(Theme.Motion.celebrate.delay(delay), value: appeared)
        }
    }
}

/// A gentle sine-wave water surface filling to the bottom edge.
nonisolated private struct Wave: Shape {
    var baseline: CGFloat
    var amplitude: CGFloat
    var frequency: CGFloat
    var phase: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y0 = rect.height * baseline
        path.move(to: CGPoint(x: 0, y: y0))
        for x in stride(from: 0, through: rect.width, by: 2) {
            let angle = x / rect.width * .pi * 2 * frequency + phase
            path.addLine(to: CGPoint(x: x, y: y0 + sin(angle) * amplitude))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
