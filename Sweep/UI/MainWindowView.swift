import SwiftUI

/// The app window: the character's stage on the left, setup on the right. Until the user
/// dismisses it once, the welcome card appears in front of it.
struct MainWindowView: View {
    let controller: AppController
    @State private var showsWelcome: Bool

    init(controller: AppController) {
        self.controller = controller
        _showsWelcome = State(initialValue: !controller.preferences.hasSeenWelcome)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                StagePane(controller: controller)
                    .frame(width: 320)
                PanelView(controller: controller, style: .window)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            if showsWelcome {
                WelcomeOverlay(onDismiss: dismissWelcome)
                    .transition(.asymmetric(
                        insertion: .identity, // the overlay animates its own entrance
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
            }
        }
        .frame(minHeight: 620)
        .background(.background)
        // Run under the transparent title bar so the stage and the dimming reach the top edge.
        .ignoresSafeArea()
        .task {
            // Reflect permissions granted in System Settings while the window is open.
            while !Task.isCancelled {
                controller.permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func dismissWelcome() {
        withMotion(Theme.Motion.smooth) { showsWelcome = false }
        controller.preferences.hasSeenWelcome = true
    }
}

/// Left pane: brand, the character on its stage, and a one-line status.
private struct StagePane: View {
    let controller: AppController

    var body: some View {
        ZStack(alignment: .top) {
            MascotScene(state: controller.session.mascotState, characterSize: 200)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Sweep")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Circle()
                        .fill(Theme.yellow)
                        .frame(width: 8, height: 8)
                }
                Text("Clean your Mac without pressing anything by accident.")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 56)

            VStack {
                Spacer()
                CreditLine()
                    .padding(.bottom, 22)
            }
        }
        .clipped()
    }
}

/// "© 2026 Sweep · by @creativebolsita", the handle linking to X.
private struct CreditLine: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text("© \(Calendar.current.component(.year, from: .now).formatted(.number.grouping(.never))) Sweep · by")
                .foregroundStyle(.white.opacity(0.7))
            Link("@creativebolsita", destination: URL(string: "https://x.com/creativebolsita")!)
                .foregroundStyle(.white)
                .underline(hovering)
                .onHover { hovering = $0 }
                .help("Open @creativebolsita on X")
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Capsule().fill(Color(red: 0.12, green: 0.27, blue: 0.62).opacity(0.35)))
    }
}

/// Welcome modal shown in front of the window when the app opens: the backdrop dims,
/// the card springs up into place, its contents follow in a short stagger, and the clip
/// starts once the card has landed.
private struct WelcomeOverlay: View {
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var videoPlaying = false

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.42 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .animation(.easeOut(duration: 0.3), value: appeared)

            card
                .scaleEffect(appeared || reduceMotion ? 1 : 0.86, anchor: .bottom)
                .offset(y: appeared || reduceMotion ? 0 : 46)
                .blur(radius: appeared || reduceMotion ? 0 : 12)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? Theme.Motion.reduced : .spring(duration: 0.62, bounce: 0.34), value: appeared)
        }
        .onAppear {
            appeared = true
            videoPlaying = true
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            WelcomeVideo(isPlaying: videoPlaying)
                .aspectRatio(WelcomeVideo.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .padding(14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Hey there 👋")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.yellowText)
                    .modifier(StaggeredReveal(index: 0, active: appeared))
                Text("Welcome to Sweep")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .modifier(StaggeredReveal(index: 1, active: appeared))
                Text("Lock the keyboard, trackpad or mouse and turn the screen black to clean your Mac without pressing anything by accident.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(StaggeredReveal(index: 2, active: appeared))
                Text("To finish, hold both ⌘ keys for \(Int(UnlockChord.holdDuration)) seconds.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .modifier(StaggeredReveal(index: 3, active: appeared))

                Button(action: onDismiss) {
                    HStack(spacing: 8) {
                        Text("Get Started")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(InvertedCapsuleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 20)
                .modifier(StaggeredReveal(index: 4, active: appeared))
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.hairline))
        .overlay(alignment: .topLeading) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(pressedScale: 0.9))
            .keyboardShortcut(.cancelAction)
            .padding(24)
            .accessibilityLabel("Close")
        }
    }
}

/// Lines of the welcome card rise into place one after another.
private struct StaggeredReveal: ViewModifier {
    let index: Int
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: active || reduceMotion ? 0 : 12)
            .animation(
                reduceMotion ? Theme.Motion.reduced : .spring(duration: 0.5, bounce: 0.2).delay(0.16 + Double(index) * 0.05),
                value: active
            )
    }
}

/// High-contrast capsule: dark on light appearance, white on dark.
private struct InvertedCapsuleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 26)
            .frame(height: 42)
            .background(Capsule().fill(.primary))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}
