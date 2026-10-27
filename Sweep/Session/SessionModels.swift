import CoreGraphics
import Foundation

struct SessionConfiguration: Equatable {
    var policy: BlockingPolicy
    /// Displays covered in black; nil means no blackout.
    var blackout: ScreenTarget?
    /// Physical brightness to apply to these displays, restored at the end.
    var brightness: BrightnessRequest?
    var safetyLimit: TimeInterval

    struct BrightnessRequest: Equatable {
        var level: Float
        var displays: [DisplayInfo]
    }

    var hasWork: Bool {
        policy.blocksAnything || blackout != nil
    }
}

nonisolated enum SessionEndReason: Equatable, Sendable {
    case unlocked
    case endedByUser
    case safetyLimit
    case tapDisabled
    case accessibilityRevoked
    case secureInputEnabled
    case systemInterruption

    /// Endings worth explaining afterwards in the panel.
    var notice: String? {
        switch self {
        case .unlocked, .endedByUser:
            nil
        case .safetyLimit:
            "The cleaning ended when it reached the safety limit."
        case .tapDisabled:
            "macOS turned off the input filter, so the cleaning ended to be safe."
        case .accessibilityRevoked:
            "Accessibility permission was removed during the cleaning."
        case .secureInputEnabled:
            "Another app turned on secure input, so the keyboard could no longer be locked."
        case .systemInterruption:
            "The cleaning ended because your Mac locked or went to sleep."
        }
    }
}

nonisolated enum SessionStartError: Error, Equatable {
    case nothingSelected
    case accessibilityRequired
    case inputMonitoringRequired
    case secureInputActive
    case inputUnavailable
    case mouseMonitorUnavailable

    var message: String {
        switch self {
        case .nothingSelected: "Choose what to lock or turn on the black screen."
        case .accessibilityRequired: "Sweep needs Accessibility to lock devices."
        case .inputMonitoringRequired: "To keep the mouse working, Sweep needs Input Monitoring."
        case .secureInputActive: "A password field is active. Close it so the keyboard can be locked."
        case .inputUnavailable: "macOS didn’t allow the input filter. Check the Accessibility permission."
        case .mouseMonitorUnavailable: "Couldn’t read the external mouse. Lock both, or try again."
        }
    }
}
