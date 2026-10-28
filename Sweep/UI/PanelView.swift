import SwiftUI

/// Where the setup UI is shown: the menu bar popover or the app window.
enum PanelStyle {
    case popover, window

    /// The popover is clear glass, so a blue wash over a blue wallpaper loses its text.
    /// Selections there are solid blue with white text instead.
    var solidSelection: Bool { self == .popover }
}

extension EnvironmentValues {
    @Entry var panelStyle: PanelStyle = .window
}

/// Choose what to block and which screens to black out, then start.
struct PanelView: View {
    let controller: AppController
    var style: PanelStyle = .popover

    private var preferences: Preferences { controller.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let notice = controller.session.notice {
                NoticeBanner(text: notice) { controller.dismissNotice() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            DeviceSection(controller: controller)
            ScreenSection(controller: controller)

            if let missing = controller.missingPermission {
                PermissionCard(kind: missing, permissions: controller.permissions)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            footer

            if style == .window {
                WindowOptions(controller: controller)
            }
        }
        .padding(style == .window ? 28 : 18)
        .padding(.top, style == .window ? 14 : 0)
        .frame(width: style == .window ? 420 : 332)
        .environment(\.panelStyle, style)
        .motion(Theme.Motion.smooth, value: controller.missingPermission)
        .motion(Theme.Motion.smooth, value: controller.session.notice)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if style == .window {
                // The stage pane carries the brand; this side is about the task.
                Text("Set up your cleaning")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("Sweep")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Circle()
                        .fill(Theme.yellow)
                        .frame(width: 5, height: 5)
                }
                MascotView(state: controller.session.mascotState, size: 40)
            }
            Spacer()
            Menu {
                Button("Settings…") { controller.openSettings() }
                Divider()
                Button("Quit Sweep") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("To finish, hold")
                UnlockChordView()
                Text("\(Int(UnlockChord.holdDuration)) s")
                Spacer(minLength: 0)
                EmergencyInfoButton(minutes: preferences.safetyLimitMinutes)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            Button("Start Cleaning") { controller.startSession() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canStart || controller.missingPermission != nil)

            if let error = controller.startError {
                Label(error.message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motion(Theme.Motion.smooth, value: controller.startError)
    }
}

// MARK: Window options

private struct WindowOptions: View {
    let controller: AppController

    var body: some View {
        @Bindable var preferences = controller.preferences

        VStack(spacing: 0) {
            Divider().padding(.bottom, 14)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show in menu bar")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(shortcutHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("Show in menu bar", isOn: $preferences.showInMenuBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var shortcutHint: String {
        let place = controller.preferences.showInMenuBar ? "Open it from the menu bar" : "No menu bar icon; it stays in the Dock"
        guard let combo = controller.shortcuts.combo else { return place }
        return "\(place) or with \(combo.displayString)"
    }
}

// MARK: Devices

private struct DeviceSection: View {
    let controller: AppController

    var body: some View {
        @Bindable var preferences = controller.preferences
        let hasMouse = !controller.devices.mice.isEmpty
        let hasTrackpad = !controller.devices.trackpads.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Lock")
            HStack(spacing: 8) {
                DeviceTile(title: "Keyboard", symbol: "keyboard", filledSymbol: "keyboard.fill", detail: nil, isOn: $preferences.blockKeyboard)
                DeviceTile(
                    title: "Trackpad",
                    symbol: "rectangle.and.hand.point.up.left",
                    filledSymbol: "rectangle.and.hand.point.up.left.filled",
                    detail: hasTrackpad ? nil : "Not found",
                    isOn: $preferences.blockTrackpad
                )
                DeviceTile(
                    title: "Mouse",
                    symbol: "computermouse",
                    filledSymbol: "computermouse.fill",
                    detail: hasMouse ? nil : "Not connected",
                    isOn: $preferences.blockMouse
                )
            }

            if let caption = splitCaption {
                Label(caption, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motion(Theme.Motion.smooth, value: splitCaption)
    }

    private var splitCaption: String? {
        switch controller.pointerPolicy {
        case .allowOnlyExternalMice:
            "The mouse keeps working. The trackpad won’t click, scroll or gesture, but it can still move the pointer. The split is approximate."
        case .blockOnlyExternalMice:
            "The trackpad keeps working. The split is approximate if you use both at once."
        default:
            nil
        }
    }
}

private struct DeviceTile: View {
    let title: String
    let symbol: String
    let filledSymbol: String
    let detail: String?
    @Binding var isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelStyle) private var panelStyle

    private var solid: Bool { isOn && panelStyle.solidSelection }

    var body: some View {
        Button {
            withMotion(Theme.Motion.snappy) { isOn.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: isOn ? filledSymbol : symbol)
                        .font(.system(size: 15, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(height: 18)
                    Spacer(minLength: 0)
                    if isOn {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .padding(.top, 2)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail ?? (isOn ? "Locked" : "Active"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(solid ? AnyShapeStyle(.white.opacity(0.8)) : isOn ? AnyShapeStyle(Theme.blue.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .contentTransition(.opacity)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(solid ? AnyShapeStyle(.white) : isOn ? AnyShapeStyle(Theme.blue) : AnyShapeStyle(.primary))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(solid ? Theme.blue : isOn ? Theme.blueWash : Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(solid ? .white.opacity(0.18) : isOn ? Theme.blue.opacity(0.65) : Theme.hairline, lineWidth: isOn ? 1.25 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Lock \(title.lowercased())")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: Screens

private struct ScreenSection: View {
    let controller: AppController

    var body: some View {
        @Bindable var preferences = controller.preferences
        let displays = controller.displays.displays

        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Screen")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Black screen")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("To spot dust and smudges")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("Black screen", isOn: $preferences.blackout.animation(Theme.Motion.smooth))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if preferences.blackout {
                    VStack(alignment: .leading, spacing: 12) {
                        if displays.count > 1 {
                            ScreenList(displays: displays, target: $preferences.screenTarget)
                        }
                        BrightnessRow(controller: controller)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .onChange(of: displays) { _, now in
            // A remembered display that is gone falls back to all screens.
            if case .display(let uuid) = preferences.screenTarget, !now.contains(where: { $0.uuid == uuid }) {
                preferences.screenTarget = .all
            }
        }
    }
}

private struct ScreenList: View {
    let displays: [DisplayInfo]
    @Binding var target: ScreenTarget

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelStyle) private var panelStyle

    var body: some View {
        VStack(spacing: 2) {
            row("All displays", symbol: "display.2", value: .all)
            ForEach(displays) { display in
                row(display.name, symbol: display.isBuiltIn ? "laptopcomputer" : "display", value: .display(uuid: display.uuid))
            }
        }
    }

    private func row(_ title: String, symbol: String, value: ScreenTarget) -> some View {
        let selected = target == value
        let solid = selected && panelStyle.solidSelection
        return Button {
            withMotion(Theme.Motion.snappy) { target = value }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(solid ? AnyShapeStyle(.white) : selected ? AnyShapeStyle(Theme.blue) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(solid ? .white : Theme.blue)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .foregroundStyle(solid ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(solid ? Theme.blue : selected ? Theme.blueWash : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressableStyle(pressedScale: 0.98))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BrightnessRow: View {
    let controller: AppController

    var body: some View {
        @Bindable var preferences = controller.preferences

        if controller.brightnessCapableDisplays.isEmpty {
            Label("This display’s brightness can only be changed by the system. Set it before you start.", systemImage: "sun.max")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Adjust brightness", isOn: $preferences.adjustsBrightness.animation(Theme.Motion.smooth))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
                if preferences.adjustsBrightness {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min")
                        Slider(value: $preferences.brightness, in: 0.05...1)
                            .controlSize(.small)
                        Image(systemName: "sun.max")
                    }
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    Text("Changes the real brightness and restores it afterwards.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: Pieces

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct PermissionCard: View {
    let kind: MissingPermission
    let permissions: PermissionCenter

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { request() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.blueWash))
    }

    private var title: String {
        switch kind {
        case .accessibility: "Allow Accessibility"
        case .inputMonitoring: "Allow Input Monitoring"
        }
    }

    private var detail: String {
        switch kind {
        case .accessibility: "Needed to lock the keyboard and trackpad system-wide. Sweep never records what you type."
        case .inputMonitoring: "Only to tell your mouse apart from the trackpad and keep it working."
        }
    }

    private func request() {
        switch kind {
        case .accessibility: permissions.requestAccessibility()
        case .inputMonitoring: permissions.requestInputMonitoring()
        }
    }
}

private struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.yellow)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.yellow.opacity(0.14)))
    }
}

private struct EmergencyInfoButton: View {
    let minutes: Int
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .accessibilityLabel("Emergency exits")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("If something goes wrong")
                    .font(.system(size: 12, weight: .semibold))
                Text("A cleaning ends on its own after \(minutes) min, or when you close the lid. The lock button is blocked too while you clean.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 250)
        }
    }
}
