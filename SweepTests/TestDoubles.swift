import CoreGraphics
import Foundation
@testable import Sweep

/// Simulated time: scheduled work only runs when the test advances the clock.
final class ManualClock: SessionClock {
    private(set) var now: TimeInterval = 1_000

    private struct Entry {
        let id: Int
        var due: TimeInterval
        let interval: TimeInterval?
        let action: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var nextID = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        add(due: now + max(delay, 0), interval: nil, action)
    }

    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        add(due: now + interval, interval: interval, action)
    }

    func advance(by delta: TimeInterval) {
        let target = now + delta
        while let index = entries.indices.filter({ entries[$0].due <= target }).min(by: { entries[$0].due < entries[$1].due }) {
            let entry = entries[index]
            now = max(now, entry.due)
            if let interval = entry.interval {
                entries[index].due += interval
            } else {
                entries.remove(at: index)
            }
            entry.action()
        }
        now = target
    }

    private func add(due: TimeInterval, interval: TimeInterval?, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        nextID += 1
        let id = nextID
        entries.append(Entry(id: id, due: due, interval: interval, action: action))
        return ScheduledTask { [weak self] in self?.entries.removeAll { $0.id == id } }
    }
}

final class FakeBlocker: InputBlocking {
    var failsToStart = false
    private(set) var startedPolicy: BlockingPolicy?
    private(set) var isRunning = false
    private(set) var stopCount = 0
    private var onSignal: (@MainActor (InputSignal) -> Void)?

    func start(policy: BlockingPolicy, onSignal: @escaping @MainActor (InputSignal) -> Void) throws(InputBlockerError) {
        if failsToStart { throw .tapUnavailable }
        startedPolicy = policy
        isRunning = true
        self.onSignal = onSignal
    }

    func stop() {
        if isRunning { stopCount += 1 }
        isRunning = false
        onSignal = nil
    }

    func send(_ signal: InputSignal) {
        onSignal?(signal)
    }
}

final class FakeMouseMonitor: MouseActivityMonitoring {
    var error: MouseMonitorError?
    private(set) var isRunning = false

    func start() throws(MouseMonitorError) {
        if let error { throw error }
        isRunning = true
    }

    func stop() { isRunning = false }
}

final class FakeOverlays: OverlayPresenting {
    private(set) var presented: SessionConfiguration?
    private(set) var finishedReason: SessionEndReason?
    private(set) var dismissed = false
    var isVisible: Bool { presented != nil && finishedReason == nil && !dismissed }

    func present(for session: CleaningSession, configuration: SessionConfiguration) {
        presented = configuration
        finishedReason = nil
        dismissed = false
    }

    func finish(reason: SessionEndReason) { finishedReason = reason }
    func dismiss() { dismissed = true }
}

final class FakeBrightness: BrightnessControlling {
    var levels: [CGDirectDisplayID: Float]
    init(levels: [CGDirectDisplayID: Float]) { self.levels = levels }

    func brightness(of display: CGDirectDisplayID) -> Float? { levels[display] }

    func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool {
        guard levels[display] != nil else { return false }
        levels[display] = value
        return true
    }
}

final class FakeCursor: CursorControlling {
    private(set) var concealed = false
    private(set) var frozen = false

    func conceal(freezingPosition: Bool) {
        concealed = true
        frozen = freezingPosition
    }

    func restore() {
        concealed = false
        frozen = false
    }
}

final class FakeKeyState: KeyStateReading {
    var pressed: Set<UInt16> = []
    /// Keys the simulated HID state cannot see (like right ⌘ through `keyState`).
    var blind: Set<UInt16> = []

    func snapshot() -> KeySnapshot {
        let authoritative = Set<UInt16>(0..<128).subtracting(blind)
        return KeySnapshot(pressed: pressed.intersection(authoritative), authoritative: authoritative)
    }

    func isPressed(_ key: UInt16) -> Bool { !blind.contains(key) && pressed.contains(key) }
}

final class FakePermissions: PermissionChecking {
    var isAccessibilityTrusted = true
    var isInputMonitoringGranted = true
    var isSecureInputEnabled = false
}

final class FakeJournal: SessionJournaling {
    private(set) var entry: SessionJournal.Entry?
    func begin(originalBrightness: [String: Float]) { entry = .init(startedAt: .now, brightness: originalBrightness) }
    func pending() -> SessionJournal.Entry? { entry }
    func clear() { entry = nil }
}

/// A session wired to simulated dependencies only.
struct SessionHarness {
    let clock = ManualClock()
    let blocker = FakeBlocker()
    let localMonitor = FakeBlocker()
    let mouseMonitor = FakeMouseMonitor()
    let overlays = FakeOverlays()
    let brightness = FakeBrightness(levels: [1: 0.8])
    let cursor = FakeCursor()
    let keyState = FakeKeyState()
    let permissions = FakePermissions()
    let journal = FakeJournal()
    let session: CleaningSession

    static let builtIn = DisplayInfo(id: 1, uuid: "BUILTIN", name: "Built-in Display", isBuiltIn: true)
    static let external = DisplayInfo(id: 2, uuid: "EXT", name: "XG27VQ", isBuiltIn: false)

    init() {
        session = CleaningSession(dependencies: SessionDependencies(
            blocker: blocker,
            localMonitor: localMonitor,
            mouseMonitor: mouseMonitor,
            overlays: overlays,
            brightness: brightness,
            cursor: cursor,
            keyState: keyState,
            permissions: permissions,
            journal: journal,
            clock: clock
        ))
    }

    static func configuration(
        keyboard: Bool = true,
        pointer: PointerPolicy = .blockAll,
        blackout: ScreenTarget? = .all,
        brightness: Float? = nil,
        safetyLimit: TimeInterval = 300
    ) -> SessionConfiguration {
        SessionConfiguration(
            policy: BlockingPolicy(blocksKeyboard: keyboard, pointer: pointer),
            blackout: blackout,
            brightness: brightness.map { .init(level: $0, displays: [builtIn, external]) },
            safetyLimit: safetyLimit
        )
    }

    /// Simulates a physical key transition: the HID state changes and the tap reports it.
    func press(_ key: UInt16) {
        keyState.pressed.insert(key)
        blocker.send(.key(code: key, isDown: true, isRepeat: false, time: clock.now))
    }

    func release(_ key: UInt16) {
        keyState.pressed.remove(key)
        blocker.send(.key(code: key, isDown: false, isRepeat: false, time: clock.now))
    }

    func pressChord() {
        press(KeyCode.leftCommand)
        press(KeyCode.rightCommand)
    }
}
