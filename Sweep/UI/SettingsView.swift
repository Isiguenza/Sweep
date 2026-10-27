import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: AppController

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var preferences = controller.preferences

        Form {
            Section("Quick Access") {
                LabeledContent("Shortcut to open Sweep") {
                    ShortcutRecorder(shortcuts: controller.shortcuts)
                }
                Toggle("Show in menu bar", isOn: $preferences.showInMenuBar)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("Combination") {
                    UnlockChordView()
                }
                Picker("Safety limit", selection: $preferences.safetyLimitMinutes) {
                    ForEach(Preferences.safetyLimitChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
            } header: {
                Text("Ending a cleaning")
            } footer: {
                Text("Hold both ⌘ keys for \(Int(UnlockChord.holdDuration)) seconds without pressing anything else. Let go early and the progress resets. A cleaning also ends at the safety limit or when you close the lid. The lock button stays blocked while you clean.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Block the keyboard, trackpad and mouse.",
                    granted: controller.permissions.accessibility,
                    action: controller.permissions.requestAccessibility
                )
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Only to keep the mouse working while you clean the trackpad.",
                    granted: controller.permissions.inputMonitoring,
                    action: controller.permissions.requestInputMonitoring
                )
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { controller.permissions.refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            controller.permissions.refresh()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn’t change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(Theme.blue)
            } else {
                Button("Allow…", action: action)
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels, ⌫ clears.
struct ShortcutRecorder: View {
    let shortcuts: ShortcutCenter

    @State private var recording = false
    @State private var issue: ShortcutIssue?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Text(fieldText)
                        .font(.system(size: 12.5, weight: recording ? .regular : .medium, design: .rounded))
                        .tracking(recording ? 0 : 1.5)
                        .foregroundStyle(recording ? AnyShapeStyle(Theme.blue) : shortcuts.combo == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(minWidth: 112, minHeight: 26)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(recording ? Theme.blueWash : Theme.surface))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(recording ? Theme.blue : Theme.hairline, lineWidth: recording ? 1.5 : 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(pressedScale: 0.98))
                .motion(Theme.Motion.snappy, value: recording)
                .accessibilityLabel(shortcuts.combo.map { "Shortcut \($0.displayString). Click to change" } ?? "Record shortcut")

                if shortcuts.combo != nil, !recording {
                    Button {
                        issue = shortcuts.set(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove shortcut")
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else if recording {
                Text("Esc to cancel · ⌫ to remove")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var fieldText: String {
        if recording { return "Press a shortcut…" }
        return shortcuts.combo?.displayString ?? "No shortcut"
    }

    private var message: String? {
        if let issue { return issue.message }
        if case .failed(let failure) = shortcuts.status { return failure.message }
        return nil
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        issue = nil
        recording = true
        shortcuts.pause("recording")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stopRecording()
            case kVK_Delete where event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty:
                stopRecording()
                issue = shortcuts.set(nil)
            default:
                guard let combo = KeyCombo(event: event) else { return nil }
                if let problem = ShortcutValidator.validate(combo) {
                    // Keep listening so the user can try again right away.
                    issue = problem
                    return nil
                }
                stopRecording()
                issue = shortcuts.set(combo)
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            shortcuts.resume("recording")
        }
    }
}
