import AppKit
import SwiftUI

/// Keeps one black window per covered display — or a HUD when nothing is covered — in sync
/// with the connected displays for the whole session.
final class OverlayController: OverlayPresenting {
    private let displays: DisplayManager
    private var session: CleaningSession?
    private var configuration: SessionConfiguration?
    private var presentation = OverlayPresentation()
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var hud: NSPanel?
    private var closing: Task<Void, Never>?

    /// Called once every overlay of a finished session has faded out.
    var onDidClose: (() -> Void)?
    /// When set before presenting, the HUD is centred here and kept hidden until
    /// `revealHUD()`, so the app window can morph into it.
    var morphSource: NSRect?
    /// Asked before the HUD of a finished session fades; return true to take over its exit
    /// (the app window morphs back out of it).
    var onHUDWillClose: ((NSRect) -> Bool)?
    private var hudAnchor: NSPoint?

    /// The visible black card inside the HUD panel, in screen coordinates.
    var hudCardFrame: NSRect? {
        hud.map { $0.frame.insetBy(dx: SessionHUDView.margin, dy: SessionHUDView.margin) }
    }

    /// Swaps the landed morph for the real HUD. Both are the same black card in the same
    /// place with the same shadow, so the swap is invisible; then the contents rise in.
    func revealHUD() {
        morphSource = nil
        hud?.alphaValue = 1
        revealContents()
        keepFocus()
    }

    /// Makes Sweep frontmost and a session window key. Liquid Glass draws in its flat,
    /// frosted "inactive" style in windows that are not key, so the session keeps focus.
    func keepFocus() {
        guard session?.isRunning == true, let window = windows.values.first ?? hud else { return }
        if !NSApp.isActive { NSApp.activate() }
        if !window.isKeyWindow { window.makeKey() }
    }

    private func revealContents() {
        let presentation = presentation
        Task {
            // Let the hidden state render once so the entrance has something to animate from.
            try? await Task.sleep(for: .milliseconds(30))
            presentation.contentRevealed = true
        }
    }

    init(displays: DisplayManager) {
        self.displays = displays
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func present(for session: CleaningSession, configuration: SessionConfiguration) {
        closeAll()
        self.session = session
        self.configuration = configuration
        presentation = OverlayPresentation()
        reconcile(animated: true)
        if morphSource == nil { revealContents() }
    }

    /// Called on every display reconfiguration while a session is visible.
    func displaysChanged() {
        guard session?.isRunning == true else { return }
        reconcile(animated: false)
    }

    func finish(reason: SessionEndReason) {
        guard session != nil else { return }
        let succeeded = reason == .unlocked
        if succeeded {
            withMotion(Theme.Motion.celebrate) { presentation.completed = true }
        }
        closing?.cancel()
        closing = Task { [weak self] in
            // A short beat for the confirmation; input is already back by now.
            try? await Task.sleep(for: .milliseconds(succeeded ? 1500 : 150))
            guard !Task.isCancelled else { return }
            self?.fadeOutAndClose()
        }
    }

    func dismiss() {
        closeAll()
    }

    // MARK: Windows

    private func reconcile(animated: Bool) {
        guard let session, let configuration else { return }
        displays.refresh()
        let targets = configuration.blackout?.resolve(in: displays.displays) ?? []
        let targetIDs = Set(targets.map(\.id))

        for (id, window) in windows where !targetIDs.contains(id) || DisplayManager.screen(for: id) == nil {
            window.orderOut(nil)
            windows[id] = nil
        }
        for display in targets {
            guard let screen = DisplayManager.screen(for: display.id) else { continue }
            if let window = windows[display.id] {
                window.setFrame(screen.frame, display: true)
            } else {
                let window = makeBlackoutWindow(for: screen, session: session)
                windows[display.id] = window
                show(window, animated: animated)
            }
        }
        // Keep a key window so the local monitor and VoiceOver have a home.
        keepFocus()

        if windows.isEmpty {
            if hud == nil {
                let panel = makeHUD(session: session)
                hud = panel
                hudAnchor = morphSource.map { NSPoint(x: $0.midX, y: $0.midY) }
                // On screen first, so its size reflects the display's scale before anyone
                // (the window morph) reads its frame.
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                panel.contentView?.layoutSubtreeIfNeeded()
                positionHUD()
                if morphSource == nil {
                    show(panel, animated: animated)
                    keepFocus()
                }
            }
            positionHUD()
        } else if let hud {
            hud.orderOut(nil)
            self.hud = nil
        }
    }

    private func makeBlackoutWindow(for screen: NSScreen, session: CleaningSession) -> NSWindow {
        let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.contentView = NSHostingView(rootView: BlackoutView(session: session, presentation: presentation))
        window.setFrame(screen.frame, display: false)
        return window
    }

    private func makeHUD(session: CleaningSession) -> NSPanel {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let hosting = NSHostingView(rootView: SessionHUDView(session: session, presentation: presentation))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    /// Centred where the app window was when it morphed into the HUD; otherwise at the
    /// top of the main screen.
    private func positionHUD() {
        guard let hud else { return }
        if let size = hud.contentView?.fittingSize { hud.setContentSize(size) }
        let anchorScreen = hudAnchor.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
        guard let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var origin: NSPoint
        if let hudAnchor, anchorScreen != nil {
            origin = NSPoint(x: hudAnchor.x - hud.frame.width / 2, y: hudAnchor.y - hud.frame.height / 2)
        } else {
            origin = NSPoint(x: visible.midX - hud.frame.width / 2, y: visible.maxY - hud.frame.height - 12)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - hud.frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - hud.frame.height)
        hud.setFrameOrigin(origin)
    }

    private func show(_ window: NSWindow, animated: Bool) {
        window.alphaValue = animated ? 0 : 1
        window.orderFrontRegardless()
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func fadeOutAndClose() {
        if windows.isEmpty, let hud, let card = hudCardFrame, onHUDWillClose?(card) == true {
            // The window is morphing out from beneath; just let the card's contents go.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                hud.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    hud.orderOut(nil)
                    self?.forget([hud])
                }
            }
            return
        }
        let all = Array(windows.values) + [hud].compactMap { $0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.38
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for window in all { window.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                for window in all { window.orderOut(nil) }
                self?.forget(all)
            }
        }
    }

    private func forget(_ closed: [NSWindow]) {
        // A new session may have started during the fade; only drop what was closed.
        windows = windows.filter { !closed.contains($0.value) }
        if let hud, closed.contains(hud) { self.hud = nil }
        if windows.isEmpty, hud == nil {
            session = nil
            configuration = nil
            onDidClose?()
        }
    }

    private func closeAll() {
        closing?.cancel()
        closing = nil
        for window in windows.values { window.orderOut(nil) }
        hud?.orderOut(nil)
        windows = [:]
        hud = nil
        hudAnchor = nil
        session = nil
        configuration = nil
    }
}

/// Borderless, above everything (menu bar and Dock included), on every Space.
private final class OverlayWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        configureAsOverlay(self)
        hasShadow = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        configureAsOverlay(self)
        // The card draws its own edge; a window shadow would outline the transparent margin.
        hasShadow = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
private func configureAsOverlay(_ window: NSWindow) {
    window.level = .screenSaver
    // The overlays are always drawn on black, whatever the system appearance.
    window.appearance = NSAppearance(named: .darkAqua)
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.isMovable = false
}
