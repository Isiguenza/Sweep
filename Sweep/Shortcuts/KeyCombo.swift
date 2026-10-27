import AppKit
import Carbon.HIToolbox

/// A global shortcut: one non-modifier key plus modifiers.
nonisolated struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var command: Bool
    var option: Bool
    var control: Bool
    var shift: Bool
    /// Key label captured from the active layout when recorded ("S", "Ñ", "F5"…).
    var key: String

    static let `default` = KeyCombo(keyCode: UInt16(kVK_ANSI_S), command: true, option: true, control: true, shift: false, key: "S")

    init(keyCode: UInt16, command: Bool, option: Bool, control: Bool, shift: Bool, key: String) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.key = key
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let label = Self.specialKeys[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty else { return nil }
        self.init(
            keyCode: event.keyCode,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift),
            key: label
        )
    }

    var modifierSymbols: [String] {
        [control ? "⌃" : nil, option ? "⌥" : nil, shift ? "⇧" : nil, command ? "⌘" : nil].compactMap { $0 }
    }

    var displayString: String {
        (modifierSymbols + [key]).joined()
    }

    var carbonModifiers: UInt32 {
        var value = 0
        if command { value |= cmdKey }
        if option { value |= optionKey }
        if control { value |= controlKey }
        if shift { value |= shiftKey }
        return UInt32(value)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

nonisolated enum ShortcutIssue: Error, Equatable {
    case needsModifier
    case reservedBySystem
    case alreadyInUse
    case registrationFailed(OSStatus)

    var message: String {
        switch self {
        case .needsModifier: "Include ⌘, ⌥ or ⌃ so it doesn’t clash with your typing."
        case .reservedBySystem: "macOS already uses this shortcut. Try another one."
        case .alreadyInUse: "Another app already uses this shortcut. Try another one."
        case .registrationFailed(let status): "Couldn’t register the shortcut (error \(status))."
        }
    }
}

nonisolated enum ShortcutValidator {
    /// Rejects shortcuts that would fire while typing or that macOS already owns. The unlock
    /// chord is modifier-only, so no valid shortcut can overlap it; shortcuts are also paused
    /// for the whole session.
    static func validate(_ combo: KeyCombo, reserved: (KeyCombo) -> Bool = isReservedBySystem) -> ShortcutIssue? {
        guard combo.command || combo.option || combo.control else { return .needsModifier }
        return reserved(combo) ? .reservedBySystem : nil
    }

    /// Checks the enabled system shortcuts (Spotlight, Mission Control, screenshots…).
    static func isReservedBySystem(_ combo: KeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevant = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return entries.contains { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue,
                  let modifiers = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return false }
            return code == Int(combo.keyCode) && modifiers & relevant == combo.carbonModifiers
        }
    }
}
