import CoreGraphics
import Foundation

/// Session-level CGEvent tap running on its own thread, so filtering never waits on the UI.
///
/// Needs Accessibility: an active (filtering) tap is refused without it.
final class EventTapInputBlocker: InputBlocking {
    private let mouseActivity: MouseActivityLog
    private var running: TapThread?

    init(mouseActivity: MouseActivityLog) {
        self.mouseActivity = mouseActivity
    }

    func start(policy: BlockingPolicy, onSignal: @escaping @MainActor (InputSignal) -> Void) throws(InputBlockerError) {
        stop()
        let context = TapContext(policy: policy, mouseActivity: mouseActivity) { signal in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onSignal(signal) }
            }
        }
        let retained = Unmanaged.passRetained(context)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask.max,
            callback: eventTapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            throw .tapUnavailable
        }
        context.port = port
        running = TapThread(port: port, context: retained)
    }

    func stop() {
        running?.stop()
        running = nil
    }
}

/// Owns the tap's run loop thread. The context is released by the thread itself after its
/// run loop exits, so no callback can outlive it.
nonisolated private final class TapThread: @unchecked Sendable {
    private let port: CFMachPort
    private var runLoop: CFRunLoop?

    init(port: CFMachPort, context: Unmanaged<TapContext>) {
        self.port = port
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let port = self.port
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            let loop: CFRunLoop = CFRunLoopGetCurrent()
            runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
            context.release()
        }
        thread.name = "Sweep.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func stop() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }
}

nonisolated private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
    return context.shouldDrop(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Mutable state touched only from the tap thread.
nonisolated private final class TapContext: @unchecked Sendable {
    let policy: BlockingPolicy
    let mouseActivity: MouseActivityLog
    let emit: @Sendable (InputSignal) -> Void
    var port: CFMachPort?

    /// This runs on the tap thread: nothing here may touch AppKit (creating an NSEvent
    /// aborts the process off the main thread).
    private static let systemDefinedType: UInt32 = 14

    private var lastBlockedSignal: TimeInterval = 0
    private var buttonsPassedOnDown: [Int64: Bool] = [:]
    private var reportedDisable = false

    init(policy: BlockingPolicy, mouseActivity: MouseActivityLog, emit: @escaping @Sendable (InputSignal) -> Void) {
        self.policy = policy
        self.mouseActivity = mouseActivity
        self.emit = emit
    }

    func shouldDrop(type: CGEventType, event: CGEvent) -> Bool {
        let now = MonotonicTime.now()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if !reportedDisable {
                reportedDisable = true
                emit(.tapDisabled)
            }
            return false

        case .keyDown, .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            emit(.key(code: code, isDown: type == .keyDown, isRepeat: isRepeat, time: now))
            return dropKeyboard(at: now)

        case .flagsChanged:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if let isDown = KeyCode.isModifierDown(keyCode: code, flags: event.flags.rawValue) {
                emit(.key(code: code, isDown: isDown, isRepeat: false, time: now))
            }
            return dropKeyboard(at: now)

        default:
            break
        }

        // NX_SYSDEFINED: media, brightness and the lock (Touch ID / power) key. All of them
        // go while the keyboard is blocked. Holding power to force a shutdown is handled in
        // hardware and always works.
        if type.rawValue == Self.systemDefinedType {
            return dropKeyboard(at: now)
        }

        guard let kind = PointerEventKind(type: type, event: event) else { return false }
        let drop = shouldDropPointer(kind, event: event, at: now)
        if drop { noteBlocked(at: now) }
        return drop
    }

    private func dropKeyboard(at now: TimeInterval) -> Bool {
        guard policy.blocksKeyboard else { return false }
        noteBlocked(at: now)
        return true
    }

    private func shouldDropPointer(_ kind: PointerEventKind, event: CGEvent, at time: TimeInterval) -> Bool {
        switch policy.pointer {
        case .passAll: return false
        case .blockAll: return true
        case .allowOnlyExternalMice, .blockOnlyExternalMice: break
        }

        // A button release always follows the decision taken for its press, so apps never
        // see an unmatched mouse-down or mouse-up.
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if kind == .buttonUp, let passed = buttonsPassedOnDown.removeValue(forKey: button) {
            return !passed
        }

        let verdict = kind == .gesture ? .other : attribute(at: time, allowsGrace: kind.waitsForAttribution)
        let drop = PointerAttribution.shouldBlock(policy: policy.pointer, isGesture: kind == .gesture, verdict: verdict)
        if kind == .buttonDown { buttonsPassedOnDown[button] = !drop }
        return drop
    }

    /// Discrete events may arrive before their HID report; wait briefly for it. Continuous
    /// motion never waits, so a stream of blocked trackpad events cannot build up lag.
    private func attribute(at eventTime: TimeInterval, allowsGrace: Bool) -> PointerAttribution.Verdict {
        while true {
            let verdict = PointerAttribution.verdict(
                eventTime: eventTime,
                lastMouseActivity: mouseActivity.lastActivity,
                now: MonotonicTime.now(),
                allowsGrace: allowsGrace
            )
            guard verdict == .undetermined else { return verdict }
            usleep(500)
        }
    }

    private func noteBlocked(at now: TimeInterval) {
        guard now - lastBlockedSignal > 0.3 else { return }
        lastBlockedSignal = now
        emit(.blockedInput)
    }
}

nonisolated private enum PointerEventKind {
    case motion, buttonDown, buttonUp, discreteScroll, continuousScroll, gesture

    init?(type: CGEventType, event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .tabletPointer, .tabletProximity:
            self = .motion
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            self = .buttonDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            self = .buttonUp
        case .scrollWheel:
            self = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ? .continuousScroll : .discreteScroll
        default:
            // NSEvent gesture types (rotate, begin/end gesture, gesture, magnify, swipe,
            // smart magnify, quick look, pressure, direct touch, change mode).
            guard Self.gestureTypes.contains(type.rawValue) else { return nil }
            self = .gesture
        }
    }

    var waitsForAttribution: Bool {
        self == .buttonDown || self == .discreteScroll
    }

    private static let gestureTypes: Set<UInt32> = [18, 19, 20, 29, 30, 31, 32, 33, 34, 37, 38]
}
