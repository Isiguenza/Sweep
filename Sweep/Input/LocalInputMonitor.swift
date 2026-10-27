import AppKit

/// Screen-only sessions without Accessibility: listens to keys delivered to Sweep's own
/// (frontmost) overlay so the unlock chord still works. It cannot block anything.
final class LocalInputMonitor: InputBlocking {
    private var monitor: Any?

    func start(policy: BlockingPolicy, onSignal: @escaping @MainActor (InputSignal) -> Void) throws(InputBlockerError) {
        precondition(!policy.blocksAnything, "LocalInputMonitor cannot block input")
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let time = MonotonicTime.now()
            switch event.type {
            case .keyDown, .keyUp:
                onSignal(.key(code: event.keyCode, isDown: event.type == .keyDown, isRepeat: event.isARepeat, time: time))
            case .flagsChanged:
                if let isDown = KeyCode.isModifierDown(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) {
                    onSignal(.key(code: event.keyCode, isDown: isDown, isRepeat: false, time: time))
                }
            default:
                break
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
