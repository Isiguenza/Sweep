import CoreGraphics
import Foundation
import Observation

protocol OverlayPresenting: AnyObject {
    func present(for session: CleaningSession, configuration: SessionConfiguration)
    /// Input is already restored when this is called; overlays may show a short confirmation.
    func finish(reason: SessionEndReason)
    /// Removes overlays at once, for a session that failed to start.
    func dismiss()
}

struct SessionDependencies {
    var blocker: InputBlocking
    /// Used for screen-only sessions when Accessibility is not granted.
    var localMonitor: InputBlocking
    var mouseMonitor: MouseActivityMonitoring
    var overlays: OverlayPresenting
    var brightness: BrightnessControlling
    var cursor: CursorControlling
    var keyState: KeyStateReading
    var permissions: PermissionChecking
    var journal: SessionJournaling
    var clock: SessionClock
}

/// Owns one cleaning session from start to finish and guarantees that every exit path
/// restores input, cursor and brightness.
@Observable
final class CleaningSession {
    enum Phase: Equatable {
        case idle
        case running
        case finished(SessionEndReason)
    }

    private(set) var phase: Phase = .idle
    private(set) var configuration: SessionConfiguration?
    private(set) var holdStartedAt: TimeInterval?
    private(set) var chordKeysDown: Set<UInt16> = []
    private(set) var safetyDeadline: TimeInterval?
    private(set) var mascotState: MascotState = .idle
    /// Increments when blocked input is swallowed, for gentle on-screen feedback.
    private(set) var blockedInputCount = 0
    /// Abnormal ending to explain the next time the panel opens.
    var notice: String?

    @ObservationIgnored var onRunningChange: ((Bool) -> Void)?

    @ObservationIgnored private let deps: SessionDependencies
    @ObservationIgnored private var detector = UnlockDetector()
    @ObservationIgnored private var activeBlocker: InputBlocking?
    @ObservationIgnored private var usesMouseMonitor = false
    @ObservationIgnored private var originalBrightness: [CGDirectDisplayID: Float] = [:]
    @ObservationIgnored private var keyStateTrusted = false
    @ObservationIgnored private var unlockTimer: ScheduledTask?
    @ObservationIgnored private var watchdog: ScheduledTask?
    @ObservationIgnored private var mascotTimer: ScheduledTask?
    @ObservationIgnored private var watchdogTicks = 0

    static let watchdogInterval: TimeInterval = 0.1

    init(dependencies: SessionDependencies) {
        deps = dependencies
    }

    var isRunning: Bool { phase == .running }
    var now: TimeInterval { deps.clock.now }

    func progress(at time: TimeInterval) -> Double {
        detector.progress(at: time)
    }

    // MARK: Start

    func start(_ config: SessionConfiguration) throws(SessionStartError) {
        guard !isRunning else { return }
        guard config.hasWork else { throw .nothingSelected }

        let policy = config.policy
        let trusted = deps.permissions.isAccessibilityTrusted
        if policy.blocksAnything, !trusted { throw .accessibilityRequired }
        if policy.blocksKeyboard, deps.permissions.isSecureInputEnabled { throw .secureInputActive }
        if policy.pointer.needsMouseAttribution, !deps.permissions.isInputMonitoringGranted { throw .inputMonitoringRequired }

        // Each step is undone by `teardown()` if a later one fails.
        do {
            if policy.pointer.needsMouseAttribution {
                try deps.mouseMonitor.start()
                usesMouseMonitor = true
            }
        } catch {
            throw error == .notPermitted ? .inputMonitoringRequired : .mouseMonitorUnavailable
        }

        configuration = config
        applyBrightness(config.brightness)
        deps.overlays.present(for: self, configuration: config)

        // With Accessibility, a pass-through global tap watches the chord even in
        // screen-only sessions; without it, Sweep's own frontmost overlay listens.
        let blocker = trusted ? deps.blocker : deps.localMonitor
        do {
            try blocker.start(policy: policy) { [weak self] signal in self?.handle(signal) }
        } catch {
            teardown()
            deps.overlays.dismiss()
            configuration = nil
            throw .inputUnavailable
        }
        activeBlocker = blocker

        if config.blackout != nil || policy.pointer == .blockAll {
            deps.cursor.conceal(freezingPosition: policy.pointer == .blockAll)
        }

        detector = UnlockDetector(initiallyPressed: deps.keyState.snapshot().pressed)
        keyStateTrusted = false
        holdStartedAt = nil
        chordKeysDown = []
        blockedInputCount = 0
        notice = nil
        safetyDeadline = now + config.safetyLimit
        watchdogTicks = 0
        watchdog = deps.clock.repeating(every: Self.watchdogInterval) { [weak self] in self?.watchdogTick() }
        phase = .running
        mascotState = .cleaning
        onRunningChange?(true)
    }

    // MARK: End

    func end(_ reason: SessionEndReason) {
        guard isRunning else { return }
        teardown()
        phase = .finished(reason)
        holdStartedAt = nil
        chordKeysDown = []
        safetyDeadline = nil
        notice = reason.notice
        setMascot(.finished, revertTo: .idle, after: 1.2)
        deps.overlays.finish(reason: reason)
        onRunningChange?(false)
    }

    /// Restores everything the session changed. Safe to call repeatedly.
    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        unlockTimer?.cancel()
        unlockTimer = nil
        activeBlocker?.stop()
        activeBlocker = nil
        if usesMouseMonitor {
            deps.mouseMonitor.stop()
            usesMouseMonitor = false
        }
        deps.cursor.restore()
        restoreBrightness()
    }

    // MARK: Input

    private func handle(_ signal: InputSignal) {
        guard isRunning else { return }
        switch signal {
        case let .key(code, isDown, isRepeat, time):
            if isDown, !keyStateTrusted, deps.keyState.isPressed(code) {
                // The HID key state agrees with a real event, so it can be trusted to
                // repair missed key-ups from now on.
                keyStateTrusted = true
            }
            apply(detector.keyChanged(code, isDown: isDown, isRepeat: isRepeat, at: time))
        case .blockedInput:
            blockedInputCount += 1
            if holdStartedAt == nil {
                setMascot(.reactingToBlockedInput, revertTo: .cleaning, after: 0.8)
            }
        case .tapDisabled:
            end(.tapDisabled)
        }
    }

    private func apply(_ change: UnlockDetector.Change) {
        chordKeysDown = detector.chordKeysDown
        switch change {
        case .none:
            break
        case .began:
            holdStartedAt = detector.holdStartedAt
            scheduleUnlockCheck()
            setMascot(.wakingUp)
        case .cancelled:
            holdStartedAt = nil
            unlockTimer?.cancel()
            unlockTimer = nil
            setMascot(.cleaning)
        case .completed:
            end(.unlocked)
        }
    }

    private func scheduleUnlockCheck() {
        unlockTimer?.cancel()
        guard let deadline = detector.deadline else { return }
        unlockTimer = deps.clock.schedule(after: deadline - now) { [weak self] in
            guard let self else { return }
            apply(detector.evaluate(at: now))
        }
    }

    private func watchdogTick() {
        guard isRunning, let configuration else { return }
        watchdogTicks += 1

        if let safetyDeadline, now >= safetyDeadline {
            end(.safetyLimit)
            return
        }
        // Permission and secure-input checks are cheaper at ~1 Hz.
        if watchdogTicks % 10 == 0 {
            if activeBlocker === deps.blocker, !deps.permissions.isAccessibilityTrusted {
                end(.accessibilityRevoked)
                return
            }
            if configuration.policy.blocksKeyboard, deps.permissions.isSecureInputEnabled {
                end(.secureInputEnabled)
                return
            }
        }
        if keyStateTrusted {
            apply(detector.reconcile(with: deps.keyState.snapshot(), at: now))
        } else {
            apply(detector.evaluate(at: now))
        }
    }

    // MARK: Brightness

    private func applyBrightness(_ request: SessionConfiguration.BrightnessRequest?) {
        originalBrightness = [:]
        guard let request else { return }
        var journal: [String: Float] = [:]
        for display in request.displays {
            guard let original = deps.brightness.brightness(of: display.id) else { continue }
            originalBrightness[display.id] = original
            journal[display.uuid] = original
        }
        // Journal first, so a crash right after changing the backlight can still be undone.
        if !journal.isEmpty { deps.journal.begin(originalBrightness: journal) }
        for id in originalBrightness.keys {
            deps.brightness.setBrightness(request.level, of: id)
        }
    }

    private func restoreBrightness() {
        for (id, value) in originalBrightness {
            deps.brightness.setBrightness(value, of: id)
        }
        if !originalBrightness.isEmpty { deps.journal.clear() }
        originalBrightness = [:]
    }

    // MARK: Mascot

    private func setMascot(_ state: MascotState, revertTo next: MascotState? = nil, after delay: TimeInterval = 0) {
        mascotTimer?.cancel()
        mascotTimer = nil
        mascotState = state
        guard let next else { return }
        mascotTimer = deps.clock.schedule(after: delay) { [weak self] in
            self?.mascotState = next
        }
    }
}
