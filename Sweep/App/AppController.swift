import AppKit
import Observation
import SwiftUI

/// Composition root: owns the models, the menu bar item, the panel and the global shortcut.
@Observable
final class AppController {
    let preferences = Preferences()
    let permissions = PermissionCenter()
    let displays = DisplayManager()
    let devices = PointingDeviceCatalog()
    let shortcuts = ShortcutCenter()
    let session: CleaningSession

    private(set) var startError: SessionStartError?

    @ObservationIgnored private let overlays: OverlayController
    @ObservationIgnored private let brightness: BrightnessControlling = IODisplayBrightness()
    @ObservationIgnored private let journal = SessionJournal()
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var popover: NSPopover?
    @ObservationIgnored private var permissionPoll: Timer?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    /// Shows the app window; set by the app delegate.
    @ObservationIgnored var onShowWindow: (() -> Void)?
    /// The app window, set by the app delegate once created.
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// The window was turned into the session card and must come back when it ends.
    @ObservationIgnored private var windowHiddenForSession: (image: NSImage?, frame: NSRect)?
    @ObservationIgnored private var restoringWindow = false

    func isWindowVisible() -> Bool { mainWindow?.isVisible == true }
    @ObservationIgnored private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let overlays = OverlayController(displays: displays)
        let mouseLog = MouseActivityLog()
        self.overlays = overlays
        session = CleaningSession(dependencies: SessionDependencies(
            blocker: EventTapInputBlocker(mouseActivity: mouseLog),
            localMonitor: LocalInputMonitor(),
            mouseMonitor: HIDMouseActivityMonitor(log: mouseLog),
            overlays: overlays,
            brightness: brightness,
            cursor: SystemCursor(),
            keyState: HIDKeyStateReader(),
            permissions: permissions,
            journal: journal,
            clock: LiveClock()
        ))
        displays.onChange = { [weak overlays] in overlays?.displaysChanged() }
        overlays.onDidClose = { [weak self] in self?.returnFocusIfIdle() }
        overlays.onHUDWillClose = { [weak self] card in self?.morphBackToWindow(from: card) ?? false }
    }

    func launch() {
        recoverFromInterruptedSession()
        devices.startObserving()
        installPopover()
        updateMenuBarPresence()
        preferences.onShowInMenuBarChange = { [weak self] _ in self?.updateMenuBarPresence() }
        observeSystemInterruptions()

        permissions.onGranted = { [weak self] _ in self?.returnAfterPermissionGranted() }
        session.onRunningChange = { [weak self] running in self?.sessionRunningChanged(running) }
        shortcuts.onPress = { [weak self] in self?.togglePanel() }
        shortcuts.activate()
    }

    func terminate() {
        session.end(.endedByUser)
    }

    // MARK: Derived state for the panel

    var pointerPolicy: PointerPolicy {
        PointerPolicy.make(
            blockTrackpad: preferences.blockTrackpad,
            blockMouse: preferences.blockMouse,
            hasExternalMouse: !devices.mice.isEmpty,
            hasTrackpad: !devices.trackpads.isEmpty
        )
    }

    var blockingPolicy: BlockingPolicy {
        BlockingPolicy(blocksKeyboard: preferences.blockKeyboard, pointer: pointerPolicy)
    }

    var blackoutDisplays: [DisplayInfo] {
        guard preferences.blackout else { return [] }
        return preferences.screenTarget.resolve(in: displays.displays)
    }

    /// Displays among the blacked-out ones whose backlight a public API can change.
    var brightnessCapableDisplays: [DisplayInfo] {
        blackoutDisplays.filter { brightness.brightness(of: $0.id) != nil }
    }

    var missingPermission: MissingPermission? {
        let policy = blockingPolicy
        if policy.blocksAnything, !permissions.accessibility { return .accessibility }
        if policy.pointer.needsMouseAttribution, !permissions.inputMonitoring { return .inputMonitoring }
        return nil
    }

    var canStart: Bool {
        blockingPolicy.blocksAnything || (preferences.blackout && !blackoutDisplays.isEmpty)
    }

    func makeConfiguration() -> SessionConfiguration {
        let capable = preferences.adjustsBrightness ? brightnessCapableDisplays : []
        return SessionConfiguration(
            policy: blockingPolicy,
            blackout: preferences.blackout ? preferences.screenTarget : nil,
            brightness: capable.isEmpty ? nil : .init(level: Float(preferences.brightness), displays: capable),
            safetyLimit: TimeInterval(preferences.safetyLimitMinutes * 60)
        )
    }

    // MARK: Actions

    func startSession() {
        permissions.refresh()
        startError = nil
        // Sweep must be frontmost so it can hide and pin the cursor.
        NSApp.activate()
        let configuration = makeConfiguration()
        // Without a blackout, the app window turns into the small black session card.
        let window = configuration.blackout == nil && isWindowVisible() ? mainWindow : nil
        let snapshot = window.flatMap(WindowMorph.snapshot(of:))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let window, snapshot != nil, !reduceMotion {
            overlays.morphSource = window.frame
        }
        do {
            try session.start(configuration)
            popover?.performClose(nil)
        } catch {
            overlays.morphSource = nil
            withMotion(Theme.Motion.smooth) { startError = error }
            return
        }
        guard let window else { return }
        windowHiddenForSession = (snapshot, window.frame)
        if let snapshot, let card = overlays.hudCardFrame, overlays.morphSource != nil {
            let from = window.frame
            window.orderOut(nil)
            WindowMorph.run(image: snapshot, from: from, to: card, toBlack: true, cardCornerRadius: SessionHUDView.cornerRadius) { [weak self] morph in
                self?.overlays.revealHUD()
                // The HUD starts as the same solid black card, so the morph can go quickly;
                // the HUD's own glass then clears.
                morph.finish(fadeDuration: 0.1)
            }
        } else {
            window.orderOut(nil)
        }
    }

    /// The finished session card grows back into the app window.
    private func morphBackToWindow(from card: NSRect) -> Bool {
        guard let hidden = windowHiddenForSession, let window = mainWindow else { return false }
        windowHiddenForSession = nil
        restoringWindow = true
        let show = { [weak self] in
            window.setFrame(hidden.frame, display: false)
            window.alphaValue = 1
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            self?.restoringWindow = false
        }
        guard let image = hidden.image, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            show()
            return false
        }
        WindowMorph.run(image: image, from: card, to: hidden.frame, toBlack: false, cardCornerRadius: SessionHUDView.cornerRadius) { morph in
            show()
            morph.finish(fadeDuration: 0.12)
        }
        return true
    }

    func dismissNotice() {
        withMotion(Theme.Motion.smooth) {
            session.notice = nil
            startError = nil
        }
    }

    func togglePanel() {
        guard !session.isRunning else { return }
        guard statusItem != nil else {
            onShowWindow?()
            return
        }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem?.button, let popover else {
            onShowWindow?()
            return
        }
        NSApp.activate()
        permissions.refresh()
        displays.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func openSettings() {
        popover?.performClose(nil)
        onOpenSettings?()
    }

    // MARK: Menu bar

    /// Menu bar mode is an agent app (no Dock icon). Without the menu bar item Sweep becomes
    /// a regular app, so the Dock icon and window remain a way back in.
    private func updateMenuBarPresence() {
        if preferences.showInMenuBar {
            if statusItem == nil { installStatusItem() }
            NSApp.setActivationPolicy(.accessory)
        } else {
            popover?.performClose(nil)
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            NSApp.setActivationPolicy(.regular)
        }
        if isWindowVisible() { NSApp.activate() }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusImage(running: session.isRunning)
        statusTarget.onClick = { [weak self] in self?.statusItemClicked() }
        item.button?.target = statusTarget
        item.button?.action = #selector(ActionTarget.invoke)
        item.button?.setAccessibilityLabel("Sweep")
        statusItem = item
    }

    private func installPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: PanelView(controller: self))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.delegate = popoverDelegate
        self.popover = popover
        popoverDelegate.onShow = { [weak self] in self?.startPermissionPolling() }
        popoverDelegate.onClose = { [weak self] in self?.stopPermissionPolling() }
    }

    @ObservationIgnored private let popoverDelegate = PopoverDelegate()
    @ObservationIgnored private let statusTarget = ActionTarget()

    private func statusItemClicked() {
        if session.isRunning {
            session.end(.endedByUser)
        } else {
            togglePanel()
        }
    }

    private func statusImage(running: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: running ? "lock.fill" : "bubbles.and.sparkles", accessibilityDescription: "Sweep")
        image?.isTemplate = true
        return image
    }

    private func sessionRunningChanged(_ running: Bool) {
        statusItem?.button?.image = statusImage(running: running)
        if running {
            shortcuts.pause("session")
        } else {
            shortcuts.resume("session")
            // An unexpected ending is explained right away rather than on the next open.
            if session.notice != nil { showPanel() }
        }
    }

    /// Sweep took focus to pin the cursor; once the overlays are gone, hand it back to the
    /// app the user was in.
    private func returnFocusIfIdle() {
        guard !session.isRunning, popover?.isShown != true, !isWindowVisible(), !restoringWindow else { return }
        NSApp.hide(nil)
    }

    // MARK: Permissions

    func startPermissionPolling() {
        permissions.refresh()
        permissionPoll?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissions.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPoll = timer
    }

    /// Brings Sweep back from System Settings once the user has granted access.
    private func returnAfterPermissionGranted() {
        guard !session.isRunning else { return }
        if let mainWindow, mainWindow.isVisible {
            NSApp.activate()
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            showPanel()
        }
    }

    func stopPermissionPolling() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    // MARK: Recovery

    private func observeSystemInterruptions() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ]
        systemObservers = names.map { center, name in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.end(.systemInterruption) }
            }
            return (center, token)
        }

        // Cleaning mode keeps focus: if another app or window takes it (a click with a
        // still-usable mouse), Sweep takes it straight back.
        let focusLost: [Notification.Name] = [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification]
        for name in focusLost {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session.isRunning else { return }
                    // Next turn of the run loop, once AppKit has finished the switch.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.overlays.keepFocus() }
                    }
                }
            }
            systemObservers.append((NotificationCenter.default, token))
        }
    }

    /// Input filters die with the process, but a changed backlight does not.
    private func recoverFromInterruptedSession() {
        guard let entry = journal.pending() else { return }
        for display in displays.displays {
            if let value = entry.brightness[display.uuid] {
                brightness.setBrightness(value, of: display.id)
            }
        }
        journal.clear()
        session.notice = "Sweep quit during a cleaning. The original brightness was restored."
    }
}

enum MissingPermission {
    case accessibility, inputMonitoring
}

/// Objective-C target for AppKit controls, forwarding to a closure.
private final class ActionTarget: NSObject {
    var onClick: (() -> Void)?

    @objc func invoke() { onClick?() }
}

private final class PopoverDelegate: NSObject, NSPopoverDelegate {
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?

    func popoverDidShow(_ notification: Notification) { onShow?() }
    func popoverDidClose(_ notification: Notification) { onClose?() }
}
