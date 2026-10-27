import AppKit
import QuartzCore

/// Morphs between the app window and the black session card.
///
/// A transparent full-screen window hosts a snapshot of the app in a layer that springs
/// from one rectangle to the other (Core Animation springs, so it runs at the display's
/// refresh rate), rounding its corners while black washes over it. The morph window sits
/// just below the HUD so the HUD's contents can fade in on top as it lands.
@MainActor
final class WindowMorph {
    static let windowCornerRadius: CGFloat = 16

    private let window: NSWindow
    private let shadowLayer = CALayer()
    private let clipLayer = CALayer()
    private let imageLayer = CALayer()
    private let blackLayer = CALayer()
    private static var retained: [ObjectIdentifier: WindowMorph] = [:]

    /// Captures a window as it looks now, title bar included.
    static func snapshot(of window: NSWindow) -> NSImage? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// `toBlack` true: app → card. False: card → app. `completion` runs when the shape has
    /// landed; call `finish()` on the returned morph to remove it (after cross-fading).
    @discardableResult
    static func run(
        image: NSImage,
        from: NSRect,
        to: NSRect,
        toBlack: Bool,
        cardCornerRadius: CGFloat,
        completion: @escaping @MainActor (WindowMorph) -> Void
    ) -> WindowMorph {
        let morph = WindowMorph(image: image, from: from, to: to, toBlack: toBlack, cardCornerRadius: cardCornerRadius, completion: completion)
        retained[ObjectIdentifier(morph)] = morph
        return morph
    }

    private init(
        image: NSImage,
        from: NSRect,
        to: NSRect,
        toBlack: Bool,
        cardCornerRadius: CGFloat,
        completion: @escaping @MainActor (WindowMorph) -> Void
    ) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: to.midX, y: to.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host

        let origin = screen.frame.origin
        let start = from.offsetBy(dx: -origin.x, dy: -origin.y)
        let end = to.offsetBy(dx: -origin.x, dy: -origin.y)
        let startCorner = toBlack ? Self.windowCornerRadius : cardCornerRadius
        let endCorner = toBlack ? cardCornerRadius : Self.windowCornerRadius

        shadowLayer.shadowColor = NSColor.black.cgColor
        // Matches the HUD card's own shadow, so handing over to it is seamless.
        shadowLayer.shadowOpacity = 0.35
        shadowLayer.shadowRadius = 18
        shadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        shadowLayer.backgroundColor = NSColor.black.cgColor
        clipLayer.masksToBounds = true
        // Same hairline as the HUD card.
        clipLayer.borderWidth = 1
        clipLayer.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        clipLayer.cornerCurve = .continuous
        shadowLayer.cornerCurve = .continuous
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspectFill
        blackLayer.backgroundColor = NSColor.black.cgColor

        host.layer?.addSublayer(shadowLayer)
        shadowLayer.addSublayer(clipLayer)
        clipLayer.addSublayer(imageLayer)
        clipLayer.addSublayer(blackLayer)

        // Final (model) values first, without implicit animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.place(shadowLayer, in: end)
        for layer in [clipLayer, imageLayer, blackLayer] { Self.place(layer, inside: end.size) }
        shadowLayer.cornerRadius = endCorner
        clipLayer.cornerRadius = endCorner
        blackLayer.opacity = toBlack ? 1 : 0
        CATransaction.commit()

        window.orderFrontRegardless()

        // One spring drives every geometric property so the layers move as one.
        let duration: TimeInterval = 0.58
        let spring = CASpringAnimation(perceptualDuration: duration, bounce: 0.16)

        // Hand over when the shape has visibly landed. The spring's full settling time is
        // much longer (sub-pixel wobble), and waiting for it left the card empty.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self else { return }
            completion(self)
        }

        CATransaction.begin()
        Self.animate(shadowLayer, "position", from: CGPoint(x: start.midX, y: start.midY), to: CGPoint(x: end.midX, y: end.midY), spring: spring)
        for layer in [shadowLayer, clipLayer, imageLayer, blackLayer] {
            Self.animate(layer, "bounds.size", from: start.size, to: end.size, spring: spring)
        }
        for layer in [clipLayer, imageLayer, blackLayer] {
            Self.animate(layer, "position", from: CGPoint(x: start.width / 2, y: start.height / 2), to: CGPoint(x: end.width / 2, y: end.height / 2), spring: spring)
        }
        for layer in [shadowLayer, clipLayer] {
            let corner = CABasicAnimation(keyPath: "cornerRadius")
            corner.fromValue = startCorner
            corner.toValue = endCorner
            corner.duration = duration * 0.6
            corner.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(corner, forKey: "corner")
        }
        // Black covers the snapshot early on the way in and clears late on the way out,
        // hiding it while its proportions change.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = toBlack ? [0, 1, 1] : [1, 1, 0]
        fade.keyTimes = toBlack ? [0, 0.32, 1] : [0, 0.55, 1]
        fade.duration = duration
        blackLayer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Fades the morph away and releases it.
    func finish(fadeDuration: TimeInterval = 0.18) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            window.animator().alphaValue = 0
        } completionHandler: { [self] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                Self.retained[ObjectIdentifier(self)] = nil
            }
        }
    }

    private static func place(_ layer: CALayer, in rect: CGRect) {
        layer.bounds = CGRect(origin: .zero, size: rect.size)
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func place(_ layer: CALayer, inside size: CGSize) {
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private static func animate(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, spring: CASpringAnimation) {
        let animation = spring.copy() as! CASpringAnimation
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        animation.duration = spring.settlingDuration
        layer.add(animation, forKey: keyPath)
    }
}
