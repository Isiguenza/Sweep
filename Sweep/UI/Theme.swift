import AppKit
import SwiftUI

enum Theme {
    /// Vivid electric blue: Sweep's primary colour.
    static let blue = Color(nsColor: NSColor(name: "SweepBlue") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.18, green: 0.5, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.43, blue: 0.98, alpha: 1)
    })
    /// Lighter end of the blue, for gradients.
    static let blueLight = Color(nsColor: NSColor(name: "SweepBlueLight") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.36, green: 0.68, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.27, green: 0.6, blue: 1.0, alpha: 1)
    })
    /// Tinted surface for selected controls.
    static let blueWash = Color(nsColor: NSColor(name: "SweepBlueWash") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.18, green: 0.5, blue: 1.0, alpha: 0.24)
            : NSColor(srgbRed: 0.08, green: 0.43, blue: 0.98, alpha: 0.13)
    })
    /// Small yellow accent, used sparingly (brand dot, completion).
    static let yellow = Color(red: 0.98, green: 0.79, blue: 0.27)
    /// Yellow for text: deepened on light backgrounds so it stays legible.
    static let yellowText = Color(nsColor: NSColor(name: "SweepYellowText") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.98, green: 0.79, blue: 0.27, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.55, blue: 0.02, alpha: 1)
    })
    static let surface = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.08)

    static let corner: CGFloat = 12

    enum Motion {
        /// Selection and state changes: quick, barely any overshoot.
        static let snappy = Animation.spring(duration: 0.28, bounce: 0.14)
        /// Layout changes (sections appearing, notices).
        static let smooth = Animation.spring(duration: 0.4, bounce: 0.06)
        /// Completion beat: the one moment with a touch more life.
        static let celebrate = Animation.spring(duration: 0.45, bounce: 0.3)
        static let reduced = Animation.easeInOut(duration: 0.18)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension View {
    /// Animates with `animation`, or with a short cross-fade timing under Reduce Motion.
    func motion(_ animation: Animation, value: some Equatable) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? Theme.Motion.reduced : animation, value: value)
    }
}

/// `withAnimation` that respects Reduce Motion.
@MainActor
func withMotion(_ animation: Animation, _ body: () -> Void) {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    withAnimation(reduce ? Theme.Motion.reduced : animation, body)
}

/// Gentle press feedback for custom controls.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Capsule().fill(Theme.blue).opacity(isEnabled ? 1 : 0.35))
            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
            .shadow(color: Theme.blue.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 3)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

/// A keyboard key drawn as a small keycap.
struct Keycap: View {
    let symbol: String
    var caption: String?
    var isLit = false
    var onDark = false
    /// Multiplies every dimension; the blackout overlay draws keycaps large.
    var scale: CGFloat = 1

    var body: some View {
        let corner = (onDark ? 8 : 6) * scale
        VStack(spacing: 1 * scale) {
            Text(symbol)
                .font(.system(size: (onDark ? 15 : 12) * scale, weight: .medium, design: .rounded))
            if let caption {
                Text(caption)
                    .font(.system(size: (onDark ? 8.5 : 7.5) * scale, weight: .semibold))
                    .textCase(.uppercase)
                    .opacity(0.7)
            }
        }
        .foregroundStyle(foreground)
        .frame(minWidth: (onDark ? 40 : 30) * scale, minHeight: (onDark ? 34 : 26) * scale)
        .padding(.horizontal, 4 * scale)
        .modifier(KeycapSurface(shape: RoundedRectangle(cornerRadius: corner, style: .continuous), glass: onDark, isLit: isLit, fill: fill, stroke: stroke, lineWidth: scale > 1 ? 1.5 : 1))
        .scaleEffect(isLit ? 0.95 : 1)
        .motion(Theme.Motion.snappy, value: isLit)
    }

    private var foreground: Color {
        if isLit { return onDark ? .white : Theme.blue }
        return onDark ? .white.opacity(0.62) : .secondary
    }

    private var fill: Color {
        if isLit { return Theme.blue.opacity(onDark ? 0.35 : 0.16) }
        return onDark ? .white.opacity(0.04) : Theme.surface
    }

    private var stroke: Color {
        if isLit { return Theme.blue.opacity(0.9) }
        return onDark ? .white.opacity(0.16) : Theme.hairline
    }
}

/// Liquid Glass keycaps on the cleaning screens (macOS 26+), tinted blue while pressed;
/// a flat surface everywhere else and on earlier systems.
private struct KeycapSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let glass: Bool
    let isLit: Bool
    let fill: Color
    let stroke: Color
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        if glass, #available(macOS 26.0, *) {
            content
                // Pressed: the whole key fills with blue, not just its edge.
                .background(shape.fill(Theme.blue).opacity(isLit ? 1 : 0))
                .glassEffect(.regular.tint(isLit ? Theme.blue : nil), in: shape)
                .overlay(shape.strokeBorder(isLit ? .white.opacity(0.35) : .white.opacity(0.12), lineWidth: lineWidth))
        } else {
            content
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(stroke, lineWidth: lineWidth))
        }
    }
}

/// "⌘ left + ⌘ right" rendered as keycaps. During a session the "+" becomes the seconds
/// left to hold, counting down with a numeric transition.
struct UnlockChordView: View {
    var litKeys: Set<UInt16> = []
    var onDark = false
    var scale: CGFloat = 1
    var countdown: Int?
    var isCountingDown = false

    var body: some View {
        HStack(spacing: (onDark ? 8 : 5) * scale) {
            Keycap(symbol: "⌘", caption: "left", isLit: litKeys.contains(KeyCode.leftCommand), onDark: onDark, scale: scale)
            middle
            Keycap(symbol: "⌘", caption: "right", isLit: litKeys.contains(KeyCode.rightCommand), onDark: onDark, scale: scale)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Left Command plus right Command")
        .accessibilityValue(countdown.map { "\($0) seconds" } ?? "")
    }

    @ViewBuilder
    private var middle: some View {
        if let countdown {
            Text("\(countdown)")
                .font(.system(size: 24 * scale, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(isCountingDown ? 1 : 0.45))
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.32), value: countdown)
                .scaleEffect(isCountingDown ? 1.12 : 1)
                .animation(Theme.Motion.snappy, value: isCountingDown)
                .frame(minWidth: 26 * scale)
        } else {
            Text("+")
                .font(.system(size: (onDark ? 13 : 11) * scale, weight: .medium, design: .rounded))
                .foregroundStyle(onDark ? AnyShapeStyle(.white.opacity(0.35)) : AnyShapeStyle(.tertiary))
        }
    }
}
