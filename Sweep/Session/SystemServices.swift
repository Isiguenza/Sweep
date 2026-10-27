import AppKit
import CoreGraphics
import IOKit.graphics

// Small system-facing services the session depends on, each behind a protocol so the
// session lifecycle can be tested without touching real input, cursor or brightness.

/// What the HID system says is physically down, and which keys that answer can be trusted for.
struct KeySnapshot: Equatable {
    var pressed: Set<UInt16>
    var authoritative: Set<UInt16>
}

protocol KeyStateReading {
    /// Physical key state, upstream of any event tap.
    func snapshot() -> KeySnapshot
    func isPressed(_ key: UInt16) -> Bool
}

/// `CGEventSource.keyState` does not report every modifier reliably (right ⌘ in
/// particular), so modifiers are read from the side-specific bits of the flags state and
/// are only authoritative when those bits are present.
struct HIDKeyStateReader: KeyStateReading {
    private static let regularKeys = Set<UInt16>(0..<128).subtracting(KeyCode.modifierKeys)

    func snapshot() -> KeySnapshot {
        var pressed = Self.regularKeys.filter { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
        var authoritative = Self.regularKeys
        if let modifiers = KeyCode.modifiersDown(flags: CGEventSource.flagsState(.hidSystemState).rawValue) {
            pressed.formUnion(modifiers)
            authoritative.formUnion(KeyCode.modifierKeys.subtracting([KeyCode.capsLock, KeyCode.function]))
        }
        return KeySnapshot(pressed: pressed, authoritative: authoritative)
    }

    func isPressed(_ key: UInt16) -> Bool {
        guard KeyCode.modifierKeys.contains(key) else {
            return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))
        }
        return KeyCode.modifiersDown(flags: CGEventSource.flagsState(.hidSystemState).rawValue)?.contains(key) ?? false
    }
}

protocol CursorControlling: AnyObject {
    func conceal(freezingPosition: Bool)
    func restore()
}

final class SystemCursor: CursorControlling {
    private var hidden = false
    private var frozen = false

    func conceal(freezingPosition: Bool) {
        if !hidden {
            NSCursor.hide()
            hidden = true
        }
        // Dropping move events in a tap does not stop the cursor itself from moving.
        if freezingPosition, !frozen {
            CGAssociateMouseAndMouseCursorPosition(0)
            frozen = true
        }
    }

    func restore() {
        if frozen {
            CGAssociateMouseAndMouseCursorPosition(1)
            frozen = false
        }
        if hidden {
            NSCursor.unhide()
            hidden = false
        }
    }
}

/// Real backlight control. Only displays exposed through IOKit's public IODisplay API
/// support it (mostly Intel Macs); Apple silicon panels and DDC monitors do not.
protocol BrightnessControlling {
    func brightness(of display: CGDirectDisplayID) -> Float?
    @discardableResult func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool
}

struct IODisplayBrightness: BrightnessControlling {
    func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let service = service(for: display) else { return nil }
        defer { IOObjectRelease(service) }
        var value: Float = 0
        let status = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value)
        return status == kIOReturnSuccess ? value : nil
    }

    func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool {
        guard let service = service(for: display) else { return false }
        defer { IOObjectRelease(service) }
        return IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, min(max(value, 0), 1)) == kIOReturnSuccess
    }

    private func service(for display: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as NSDictionary
            let vendor = (info["DisplayVendorID"] as? NSNumber)?.uint32Value
            let product = (info["DisplayProductID"] as? NSNumber)?.uint32Value
            if vendor == CGDisplayVendorNumber(display), product == CGDisplayModelNumber(display) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }
}

/// Persists what must be undone if Sweep dies mid-session (input taps die with the
/// process; a changed backlight does not).
protocol SessionJournaling {
    func begin(originalBrightness: [String: Float])
    func pending() -> SessionJournal.Entry?
    func clear()
}

struct SessionJournal: SessionJournaling {
    struct Entry: Codable, Equatable {
        var startedAt: Date
        /// Original brightness keyed by display UUID.
        var brightness: [String: Float]
    }

    private let defaults: UserDefaults
    private let key = "activeSessionJournal"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func begin(originalBrightness: [String: Float]) {
        let entry = Entry(startedAt: .now, brightness: originalBrightness)
        defaults.set(try? JSONEncoder().encode(entry), forKey: key)
    }

    func pending() -> Entry? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

final class ScheduledTask {
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

protocol SessionClock {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask
    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask
}

struct LiveClock: SessionClock {
    var now: TimeInterval { MonotonicTime.now() }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(delay, 0)))
            guard !Task.isCancelled else { return }
            action()
        }
        return ScheduledTask { task.cancel() }
    }

    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return ScheduledTask { timer.invalidate() }
    }
}
