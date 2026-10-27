import Foundation
import os

nonisolated enum MonotonicTime {
    /// Seconds on a monotonic clock that is safe to read from any thread.
    static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

nonisolated struct BlockingPolicy: Equatable, Sendable {
    var blocksKeyboard: Bool
    var pointer: PointerPolicy

    var blocksAnything: Bool {
        blocksKeyboard || pointer != .passAll
    }
}

nonisolated enum InputSignal: Equatable, Sendable {
    case key(code: UInt16, isDown: Bool, isRepeat: Bool, time: TimeInterval)
    /// Something was swallowed. Throttled; meant for gentle on-screen feedback.
    case blockedInput
    /// macOS disabled the event tap. Input is no longer filtered reliably.
    case tapDisabled
}

nonisolated enum InputBlockerError: Error, Equatable {
    case tapUnavailable
}

/// Filters input system-wide for the duration of a session and reports key transitions so
/// the unlock chord is detected even while the keyboard is blocked.
protocol InputBlocking: AnyObject {
    func start(policy: BlockingPolicy, onSignal: @escaping @MainActor (InputSignal) -> Void) throws(InputBlockerError)
    func stop()
}

/// Timestamp of the latest HID report from an external mouse. Written on the HID thread,
/// read on the event-tap thread.
nonisolated final class MouseActivityLog: Sendable {
    private let last = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    var lastActivity: TimeInterval? {
        last.withLock { $0 }
    }

    func record(_ time: TimeInterval) {
        last.withLock { $0 = time }
    }

    func reset() {
        last.withLock { $0 = nil }
    }
}
