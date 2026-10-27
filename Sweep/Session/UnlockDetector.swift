import Foundation

/// The physical chord that ends a session: left ⌘ and right ⌘, and nothing else.
///
/// Both keys sit on opposite sides of the space bar, so a cloth sweeping across the
/// keyboard almost always presses neighbours (space, ⌥) too, which invalidates the chord.
nonisolated enum UnlockChord {
    static let keyCodes: Set<UInt16> = [KeyCode.leftCommand, KeyCode.rightCommand]
    static let holdDuration: TimeInterval = 3
}

/// Pure state machine that decides when the unlock chord has been held long enough.
///
/// Time is always passed in, so the detector never reads a clock: the caller feeds the
/// timestamp at which each key event was observed, and asks for evaluation at "now".
/// Progress animations derive from `holdStartedAt`; they never drive the decision.
nonisolated struct UnlockDetector: Sendable {
    enum Phase: Equatable, Sendable {
        /// Keys were already down when the session began; wait until everything is released
        /// so a chord that happened to be held at start cannot count.
        case awaitingRelease
        case ready
        case holding(since: TimeInterval)
        case completed
    }

    enum Change: Equatable, Sendable {
        case none, began, cancelled, completed
    }

    let chord: Set<UInt16>
    let duration: TimeInterval
    private(set) var phase: Phase
    private(set) var pressed: Set<UInt16>

    init(
        chord: Set<UInt16> = UnlockChord.keyCodes,
        duration: TimeInterval = UnlockChord.holdDuration,
        initiallyPressed: Set<UInt16> = []
    ) {
        self.chord = chord
        self.duration = duration
        // Only the chord matters at start: some Macs report phantom keys as permanently down
        // in the HID state (keypad Enter on a MacBook, for one), which must never block unlocking.
        self.pressed = initiallyPressed.intersection(chord)
        self.phase = pressed.isEmpty ? .ready : .awaitingRelease
    }

    var holdStartedAt: TimeInterval? {
        if case .holding(let since) = phase { since } else { nil }
    }

    var deadline: TimeInterval? {
        holdStartedAt.map { $0 + duration }
    }

    var chordKeysDown: Set<UInt16> {
        pressed.intersection(chord)
    }

    func progress(at time: TimeInterval) -> Double {
        switch phase {
        case .completed: 1
        case .holding(let since): min(max((time - since) / duration, 0), 1)
        default: 0
        }
    }

    /// Feeds one key transition. Auto-repeat only confirms that a key is down; it never
    /// restarts a hold.
    mutating func keyChanged(_ key: UInt16, isDown: Bool, isRepeat: Bool = false, at time: TimeInterval) -> Change {
        guard phase != .completed, !KeyCode.ignoredForChord.contains(key) else { return .none }
        if isDown || isRepeat {
            pressed.insert(key)
        } else {
            pressed.remove(key)
        }
        return update(at: time)
    }

    /// Repairs lost key-up events (focus changes, a briefly disabled tap, secure input…)
    /// from the physical state. It only ever removes keys: the HID state can report
    /// phantom keys as down, so a key counts as pressed only after a real event said so.
    mutating func reconcile(with snapshot: KeySnapshot, at time: TimeInterval) -> Change {
        guard phase != .completed else { return .none }
        let released = pressed.intersection(snapshot.authoritative).subtracting(snapshot.pressed)
        guard !released.isEmpty else { return evaluate(at: time) }
        pressed.subtract(released)
        return update(at: time)
    }

    /// Completes the hold once real elapsed time reaches `duration`.
    mutating func evaluate(at time: TimeInterval) -> Change {
        guard case .holding(let since) = phase, time - since >= duration else { return .none }
        phase = .completed
        return .completed
    }

    private mutating func update(at time: TimeInterval) -> Change {
        let chordHeld = chord.isSubset(of: pressed)
        let othersHeld = !pressed.subtracting(chord).isEmpty

        switch phase {
        case .completed:
            return .none
        case .awaitingRelease:
            if pressed.isEmpty { phase = .ready }
            return .none
        case .ready:
            guard chordHeld, !othersHeld else { return .none }
            phase = .holding(since: time)
            return .began
        case .holding:
            guard chordHeld, !othersHeld else {
                phase = .ready
                return .cancelled
            }
            return evaluate(at: time)
        }
    }
}
