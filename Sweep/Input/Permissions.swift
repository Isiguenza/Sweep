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

    /// Called on the main thread when a permission requested here is granted.
    @ObservationIgnored var onGranted: ((MissingPermission) -> Void)?
    @ObservationIgnored private let guide = PermissionGuide()
    @ObservationIgnored private var watch: Timer?
    @ObservationIgnored private var watching: MissingPermission?

    /// Opens the pane straight away (no system prompt), with the drag card under it.
    func requestAccessibility() {
        request(.accessibility)
    }

    func requestInputMonitoring() {
        request(.inputMonitoring)
    }

    private func request(_ kind: MissingPermission) {
        open(kind == .accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent")
        guide.show(for: kind)
        startWatching(kind)
    }

    /// Polls until the permission is granted, keeping the drag card next to System Settings.
    private func startWatching(_ kind: MissingPermission) {
        watching = kind
        watch?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func watchTick() {
        guard let kind = watching else { return }
        refresh()
        let granted = kind == .accessibility ? accessibility : inputMonitoring
        guard granted else {
            guide.update()
            return
        }
        watch?.invalidate()
        watch = nil
        watching = nil
        guide.hide()
        onGranted?(kind)
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
