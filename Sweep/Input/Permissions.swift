import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit.hid
import Observation

protocol PermissionChecking: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    var isInputMonitoringGranted: Bool { get }
    /// A password field (or similar) has enabled Secure Event Input: keyboard events then
    /// bypass every event tap, so the keyboard can be neither blocked nor watched.
    var isSecureInputEnabled: Bool { get }
}

/// Accessibility: required for any blocking (active event tap).
/// Input Monitoring: required only to tell an external mouse from the trackpad.
@Observable
final class PermissionCenter: PermissionChecking {
    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    var isInputMonitoringGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    func refresh() {
        let ax = isAccessibilityTrusted
        let im = isInputMonitoringGranted
        if ax != accessibility { accessibility = ax }
        if im != inputMonitoring { inputMonitoring = im }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("Privacy_Accessibility")
        }
    }

    func requestInputMonitoring() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            open("Privacy_ListenEvent")
        }
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
