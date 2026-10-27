import SwiftUI

/// Transient presentation state shared by every overlay window of a session.
@Observable
final class OverlayPresentation {
    var completed = false
    /// Flips once the overlay is in place; the contents then rise in one after another.
    var contentRevealed = false
}

/// Full-screen pure black, with the exit instructions kept small near the bottom edge.
struct BlackoutView: View {
    let session: CleaningSession
    let presentation: OverlayPresentation

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            UnlockStatusView(session: session, presentation: presentation, onDark: true)
                .padding(.bottom, 96)
        }
        .ignoresSafeArea()
        .environment(\.controlActiveState, .key)
    }
}

/// Floating capsule used when no screen is blacked out (or the chosen one disappeared),
/// so a session is never running without visible instructions.
struct SessionHUDView: View {
    let session: CleaningSession
    let presentation: OverlayPresentation

    static let cornerRadius: CGFloat = 34
    /// Transparent margin around the card, for its shadow.
    static let margin: CGFloat = 24

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(blockedSymbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("Cleaning")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.7))
            .entrance(0, revealed: presentation.contentRevealed)

            UnlockStatusView(session: session, presentation: presentation, onDark: true, compact: true)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .padding(.bottom, 30)
        .frame(minWidth: 340)
        .modifier(SiriGlassCard(cornerRadius: Self.cornerRadius, revealed: presentation.contentRevealed))
        .environment(\.colorScheme, .dark)
        // Always draw as the active window, even in the instant focus is elsewhere.
        .environment(\.controlActiveState, .key)
        .fixedSize()
        .padding(Self.margin)
    }

    private var blockedSymbols: [String] {
        guard let policy = session.configuration?.policy else { return [] }
        var symbols: [String] = []
        if policy.blocksKeyboard { symbols.append("keyboard") }
        if policy.pointer != .passAll { symbols.append(policy.pointer == .blockAll ? "rectangle.and.hand.point.up.left" : "hand.raised") }
        return symbols
    }
}

/// Chord, hold progress, completion and the safety countdown.
struct UnlockStatusView: View {
    let session: CleaningSession
    let presentation: OverlayPresentation
    var onDark = true
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHolding: Bool { session.holdStartedAt != nil }
    /// The full-screen overlay is read from arm's length while cleaning, so it draws large.
    private var scale: CGFloat { compact ? 1.3 : 1.7 }

    var body: some View {
        VStack(spacing: compact ? 16 : 22) {
            MascotView(state: session.mascotState, size: compact ? 260 : 220)
                // Room for the little hop without touching what is above.
                .padding(.top, compact ? 22 : 0)
                .entrance(1, revealed: presentation.contentRevealed, pops: true)

            ZStack {
                if presentation.completed {
                    CompletionBurst(scale: scale)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isHolding)) { _ in
                        UnlockChordView(
                            litKeys: session.chordKeysDown,
                            onDark: onDark,
                            scale: scale,
                            countdown: secondsLeft,
                            isCountingDown: isHolding
                        )
                    }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(height: 38 * scale)
            .entrance(2, revealed: presentation.contentRevealed)

            HoldProgressBar(session: session, completed: presentation.completed, thickness: compact ? 5 : 6)
                .frame(width: compact ? 230 : 300)
                .entrance(3, revealed: presentation.contentRevealed)

            VStack(spacing: 6 * scale / 1.7) {
                Text(title)
                    .font(.system(size: (compact ? 16 : 20) * (presentation.completed ? 1.25 : 1), weight: presentation.completed ? .bold : .medium, design: .rounded))
                    .foregroundStyle(presentation.completed ? AnyShapeStyle(Theme.yellow) : AnyShapeStyle(.white.opacity(0.78)))
                    // One title leaves blurred as the next arrives, so they never overlap.
                    .id(title)
                    .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                if presentation.completed {
                    Text("Your Mac is ready to use")
                        .font(.system(size: compact ? 13 : 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace).combined(with: .offset(y: 8)))
                }
            }
            .animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.smooth.delay(0.25), value: presentation.completed)
            .entrance(4, revealed: presentation.contentRevealed)

            if !presentation.completed {
                SafetyCountdown(deadline: session.safetyDeadline, clock: { session.now }, fontSize: compact ? 12.5 : 14)
                    .entrance(5, revealed: presentation.contentRevealed)
                if session.configuration?.policy.pointer.leavesPointerUsable == true {
                    Button("End Now") { session.end(.endedByUser) }
                        .buttonStyle(QuietCapsuleButtonStyle(large: true))
                        .padding(.top, 2)
                        .entrance(6, revealed: presentation.contentRevealed)
                }
            }
        }
        .motion(Theme.Motion.celebrate, value: presentation.completed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("To finish, hold left Command and right Command for \(Int(UnlockChord.holdDuration)) seconds")
    }

    /// Whole seconds still to hold, from real elapsed time.
    private var secondsLeft: Int {
        let duration = UnlockChord.holdDuration
        guard isHolding else { return Int(duration) }
        let remaining = duration * (1 - session.progress(at: session.now))
        return max(Int(remaining.rounded(.up)), 1)
    }

    private var title: String {
        if presentation.completed { return "All done!" }
        if isHolding { return "Keep holding…" }
        return "Hold both ⌘ keys to finish"
    }
}

/// Fill = real elapsed time / hold duration, redrawn every frame only while holding.
/// Releasing animates the bar back to empty.
private struct HoldProgressBar: View {
    let session: CleaningSession
    let completed: Bool
    var thickness: CGFloat = 3

    var body: some View {
        let holding = session.holdStartedAt != nil
        TimelineView(.animation(minimumInterval: nil, paused: !holding)) { _ in
            let progress = completed ? 1 : session.progress(at: session.now)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(completed ? AnyShapeStyle(Theme.yellow) : AnyShapeStyle(LinearGradient(colors: [Theme.blueLight, Theme.blue], startPoint: .leading, endPoint: .trailing)))
                        .frame(width: max(proxy.size.width * progress, progress > 0 ? thickness : 0))
                }
            }
        }
        .frame(height: thickness)
        .motion(Theme.Motion.snappy, value: holding)
        .motion(Theme.Motion.snappy, value: completed)
        .accessibilityHidden(true)
    }
}

private struct SafetyCountdown: View {
    let deadline: TimeInterval?
    let clock: () -> TimeInterval
    var fontSize: CGFloat = 10.5

    var body: some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(Int((deadline - clock()).rounded(.up)), 0)
                Text("Ends on its own in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                    .font(.system(size: fontSize, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
    }
}

/// Low-key outlined capsule for secondary actions on black.
private struct QuietCapsuleButtonStyle: ButtonStyle {
    var large = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 11, weight: .medium))
            .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.55))
            .padding(.horizontal, large ? 18 : 12)
            .frame(height: large ? 34 : 24)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Theme.Motion.snappy, value: hovering)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

/// The "done" moment: the badge pops in with a little twist while its check draws on,
/// two rings ripple out, sparkles burst and a warm glow flashes, all from one keyframe
/// timeline. Under Reduce Motion it simply appears at rest.
private struct CompletionBurst: View {
    let scale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trigger = false

    /// Rest values: what remains on screen once the timeline ends.
    nonisolated struct Values: Sendable {
        var badge: CGFloat = 1
        var tilt: Double = 0
        var draw: CGFloat = 1
        var ring: CGFloat = 1.9
        var ringOpacity: Double = 0
        var burst: CGFloat = 1
        var glow: Double = 0
    }

    var body: some View {
        let diameter = 38 * scale
        Group {
            if reduceMotion {
                CompletionScene(value: Values(), diameter: diameter, scale: scale)
            } else {
                let scale = scale
                Color.clear
                    .keyframeAnimator(initialValue: Values(), trigger: trigger) { _, value in
                        CompletionScene(value: value, diameter: diameter, scale: scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.badge) {
                            MoveKeyframe(0)
                            SpringKeyframe(1.28, duration: 0.32, spring: .bouncy)
                            SpringKeyframe(0.94, duration: 0.18)
                            SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                        }
                        KeyframeTrack(\.tilt) {
                            MoveKeyframe(-40)
                            SpringKeyframe(12, duration: 0.32)
                            SpringKeyframe(0, duration: 0.45, spring: .bouncy)
                        }
                        KeyframeTrack(\.draw) {
                            MoveKeyframe(0)
                            LinearKeyframe(0, duration: 0.2)
                            CubicKeyframe(1, duration: 0.32)
                        }
                        KeyframeTrack(\.ring) {
                            MoveKeyframe(0.7)
                            LinearKeyframe(0.7, duration: 0.08)
                            CubicKeyframe(1.9, duration: 0.7)
                        }
                        KeyframeTrack(\.ringOpacity) {
                            MoveKeyframe(0)
                            LinearKeyframe(0.8, duration: 0.08)
                            CubicKeyframe(0, duration: 0.6)
                        }
                        KeyframeTrack(\.burst) {
                            MoveKeyframe(0)
                            LinearKeyframe(0, duration: 0.1)
                            CubicKeyframe(1, duration: 0.9)
                        }
                        KeyframeTrack(\.glow) {
                            MoveKeyframe(0)
                            CubicKeyframe(1, duration: 0.18)
                            CubicKeyframe(0, duration: 0.9)
                        }
                    }
                    .onAppear { trigger.toggle() }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Done")
    }
}

/// One frame of the completion burst, built from the keyframe values.
nonisolated private struct CompletionScene: View {
    let value: CompletionBurst.Values
    let diameter: CGFloat
    let scale: CGFloat

    @MainActor
    private var particles: [(angle: Double, distance: CGFloat, size: CGFloat, color: Color, sparkle: Bool)] {
        let colors: [Color] = [Theme.yellow, .white, Color(red: 0.55, green: 0.75, blue: 1)]
        return (0..<14).map { index in
            (
                angle: Double(index) / 14 * 2 * .pi + (index.isMultiple(of: 2) ? 0 : 0.18),
                distance: index.isMultiple(of: 3) ? 1.35 : 1.0,
                size: index.isMultiple(of: 2) ? 1.0 : 0.6,
                color: colors[index % colors.count],
                sparkle: index.isMultiple(of: 2)
            )
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.yellow.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: diameter * 1.6))
                .frame(width: diameter * 3.2, height: diameter * 3.2)
                .opacity(value.glow)

            Circle()
                .strokeBorder(Theme.yellow, lineWidth: 3 * scale / 1.7)
                .scaleEffect(value.ring)
                .opacity(value.ringOpacity)
            Circle()
                .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                .scaleEffect(value.ring * 0.78)
                .opacity(value.ringOpacity * 0.7)

            ForEach(particles.indices, id: \.self) { index in
                let particle = particles[index]
                let travel = diameter * (0.55 + 1.35 * particle.distance * value.burst)
                Group {
                    if particle.sparkle {
                        Image(systemName: "sparkle")
                            .font(.system(size: 13 * scale * particle.size, weight: .bold))
                    } else {
                        Circle().frame(width: 6 * scale * particle.size, height: 6 * scale * particle.size)
                    }
                }
                .foregroundStyle(particle.color)
                .rotationEffect(.degrees(Double(value.burst) * 160))
                .scaleEffect(1 - value.burst * 0.55)
                .offset(x: cos(particle.angle) * travel, y: sin(particle.angle) * travel)
                .opacity(value.burst == 0 || value.burst == 1 ? 0 : Double(1 - value.burst) * 1.2)
            }

            ZStack {
                Circle()
                    .fill(Theme.yellow)
                    .shadow(color: Theme.yellow.opacity(0.6), radius: 14 * scale / 1.7)
                CheckmarkShape()
                    .trim(from: 0, to: value.draw)
                    .stroke(.black, style: StrokeStyle(lineWidth: 3.6 * scale, lineCap: .round, lineJoin: .round))
                    .frame(width: diameter * 0.46, height: diameter * 0.46)
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(value.badge)
            .rotationEffect(.degrees(value.tilt))
        }
    }
}

nonisolated private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.85))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.18))
        return path
    }
}

extension View {
    /// Staggered entrance for overlay contents: each element rises a little, sharpens from
    /// a blur and fades in, a beat after the previous one. `pops` adds a springier scale
    /// for the mascot. Under Reduce Motion it is a plain fade.
    func entrance(_ index: Int, revealed: Bool, pops: Bool = false) -> some View {
        modifier(EntranceModifier(index: index, revealed: revealed, pops: pops))
    }
}

private struct EntranceModifier: ViewModifier {
    let index: Int
    let revealed: Bool
    let pops: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moving = revealed || reduceMotion
        content
            .opacity(revealed ? 1 : 0)
            .scaleEffect(moving ? 1 : (pops ? 0.6 : 0.94), anchor: pops ? .bottom : .center)
            .offset(y: moving ? 0 : 14)
            .blur(radius: moving ? 0 : 6)
            .animation(
                reduceMotion
                    ? Theme.Motion.reduced.delay(Double(index) * 0.03)
                    : .spring(duration: pops ? 0.6 : 0.5, bounce: pops ? 0.38 : 0.18).delay(0.04 + Double(index) * 0.055),
                value: revealed
            )
    }
}

/// Siri-style glass card, after the iOS 27 Siri bubble: a mesh gradient (black at the
/// top, 30 % at the bottom) sits behind the contents, and the whole stack becomes clear
/// Liquid Glass. The glass starts tinted fully black, identical to the card the app
/// window morphs into, then clears to its final 5 % tint as the contents rise in.
private struct SiriGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let revealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(mesh)
                .clipShape(shape)
                .animation(reduceMotion ? Theme.Motion.reduced : .smooth(duration: 0.7)) { view in
                    view.glassEffect(.clear.tint(.black.opacity(revealed ? 0.05 : 1)), in: shape)
                }
        } else {
            content.background(
                shape
                    .fill(LinearGradient(colors: [.black, .black.opacity(0.9), .black.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                    .background(.ultraThinMaterial, in: shape)
            )
        }
    }

    @available(macOS 15.0, *)
    private var mesh: some View {
        let midDistance: Float = 0.5
        let row1 = Array(repeating: Color.black, count: 3)
        let row2 = Array(repeating: Color.black.opacity(0.9), count: 3)
        let row3 = Array(repeating: Color.black.opacity(0.3), count: 3)
        // A mesh rather than a linear gradient, for a smoother falloff.
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, midDistance], [0.5, midDistance], [1, midDistance],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: row1 + row2 + row3
        )
    }
}
