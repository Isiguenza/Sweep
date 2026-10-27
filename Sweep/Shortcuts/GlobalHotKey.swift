import Carbon.HIToolbox
import Observation

/// System-wide shortcut through Carbon's RegisterEventHotKey: public, permission-free and
/// still the only API for this on macOS.
@Observable
final class ShortcutCenter {
    enum Status: Equatable {
        case active
        case paused
        case off
        case failed(ShortcutIssue)
    }

    private(set) var combo: KeyCombo?
    private(set) var status: Status = .off

    @ObservationIgnored var onPress: (() -> Void)?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var pauseReasons = Set<String>()
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "globalShortcut"
    private static let signature: OSType = 0x5357_5050 // 'SWPP'

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            combo = try? JSONDecoder().decode(KeyCombo?.self, from: data)
        } else {
            combo = .default
        }
    }

    /// Validates, registers and persists. On failure the previous shortcut stays active.
    @discardableResult
    func set(_ newCombo: KeyCombo?) -> ShortcutIssue? {
        if let newCombo, let issue = ShortcutValidator.validate(newCombo) {
            return issue
        }
        let previous = combo
        combo = newCombo
        apply()
        if case .failed(let issue) = status {
            combo = previous
            apply()
            return issue
        }
        defaults.set(try? JSONEncoder().encode(combo), forKey: Self.storageKey)
        return nil
    }

    func activate() {
        installHandlerIfNeeded()
        apply()
    }

    /// Pauses the shortcut (during a session or while recording a new one).
    func pause(_ reason: String) {
        pauseReasons.insert(reason)
        apply()
    }

    func resume(_ reason: String) {
        pauseReasons.remove(reason)
        apply()
    }

    private func apply() {
        unregister()
        guard let combo else {
            status = .off
            return
        }
        guard pauseReasons.isEmpty else {
            status = .paused
            return
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref)
        if result == noErr, let ref {
            hotKey = ref
            status = .active
        } else {
            status = .failed(result == eventHotKeyExistsErr ? .alreadyInUse : .registrationFailed(result))
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    fileprivate func handlePress() {
        guard status == .active else { return }
        onPress?()
    }
}

/// Carbon dispatches hot-key events on the main thread.
nonisolated private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    nonisolated(unsafe) let center = userData
    MainActor.assumeIsolated {
        Unmanaged<ShortcutCenter>.fromOpaque(center).takeUnretainedValue().handlePress()
    }
    return noErr
}
