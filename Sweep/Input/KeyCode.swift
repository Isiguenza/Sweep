import CoreGraphics

/// Virtual key codes and modifier masks needed to follow individual keys.
nonisolated enum KeyCode {
    static let leftCommand: UInt16 = 0x37
    static let rightCommand: UInt16 = 0x36
    static let capsLock: UInt16 = 0x39
    static let function: UInt16 = 0x3F

    /// Caps Lock toggles instead of being held, so it never counts as "another key".
    static let ignoredForChord: Set<UInt16> = [capsLock]

    /// Device-dependent flag bits (NX_DEVICE…KEYMASK in IOLLEvent.h). They are the only
    /// way to tell left and right modifiers apart in a flags-changed event.
    private static let deviceModifierMasks: [UInt16: UInt64] = [
        0x3B: 0x0000_0001, // left control
        0x38: 0x0000_0002, // left shift
        0x3C: 0x0000_0004, // right shift
        0x37: 0x0000_0008, // left command
        0x36: 0x0000_0010, // right command
        0x3A: 0x0000_0020, // left option
        0x3D: 0x0000_0040, // right option
        0x3E: 0x0000_2000, // right control
    ]

    /// Key codes of every modifier key, including Caps Lock and fn.
    static let modifierKeys: Set<UInt16> = Set(0x36...0x3F)

    /// Which side-specific modifiers are down according to a flags word, or nil when the
    /// flags carry no reliable device-dependent bits (then sides cannot be told apart).
    /// fn and Caps Lock are left out: their flags also mean other things.
    static func modifiersDown(flags: UInt64) -> Set<UInt16>? {
        let groups: [(generic: CGEventFlags, keys: [UInt16])] = [
            (.maskCommand, [0x37, 0x36]),
            (.maskShift, [0x38, 0x3C]),
            (.maskControl, [0x3B, 0x3E]),
            (.maskAlternate, [0x3A, 0x3D]),
        ]
        var down = Set<UInt16>()
        for group in groups {
            let sides = group.keys.filter { flags & deviceModifierMasks[$0]! != 0 }
            let generic = flags & group.generic.rawValue != 0
            guard generic == !sides.isEmpty else { return nil }
            down.formUnion(sides)
        }
        return down
    }

    /// Whether the modifier whose key code produced a flags-changed event is now down.
    /// Returns nil for key codes that are not modifiers.
    static func isModifierDown(keyCode: UInt16, flags: UInt64) -> Bool? {
        if let mask = deviceModifierMasks[keyCode] { return flags & mask != 0 }
        switch keyCode {
        case function: return flags & CGEventFlags.maskSecondaryFn.rawValue != 0
        case capsLock: return flags & CGEventFlags.maskAlphaShift.rawValue != 0
        default: return nil
        }
    }
}
