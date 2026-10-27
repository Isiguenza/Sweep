import AppKit
import AVFoundation
import SwiftUI

/// Plays `quaxly.mov` once, muted, and holds on its last frame.
struct WelcomeVideo: NSViewRepresentable {
    /// Starts playback when it becomes true, so the clip begins once the card has landed.
    var isPlaying: Bool

    static let aspectRatio: CGFloat = 360.0 / 202.0
    private static let url = Bundle.main.url(forResource: "quaxly", withExtension: "mov")

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        if let url = Self.url {
            let player = AVPlayer(url: url)
            player.isMuted = true
            // Pausing at the end leaves the final frame on screen.
            player.actionAtItemEnd = .pause
            player.preventsDisplaySleepDuringVideoPlayback = false
            view.playerLayer.player = player
        }
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        guard isPlaying, !view.started, let player = view.playerLayer.player else { return }
        view.started = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // No motion: go straight to the resting frame.
            guard let asset = player.currentItem?.asset else { return }
            Task {
                if let duration = try? await asset.load(.duration) {
                    await player.seek(to: duration, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        } else {
            player.play()
        }
    }

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()
        var started = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            // The clip's own sky blue, so nothing flashes before the first frame.
            playerLayer.backgroundColor = NSColor(srgbRed: 0.62, green: 0.84, blue: 0.95, alpha: 1).cgColor
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
