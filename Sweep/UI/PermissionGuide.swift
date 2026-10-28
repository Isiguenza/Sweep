import AppKit
import SwiftUI

/// A small floating card pinned under System Settings while the user grants a privacy
/// permission. It holds Sweep's icon, which can be dragged straight into the list.
final class PermissionGuide {
    private var panel: NSPanel?
    private var kind: MissingPermission?
    /// Set when the user closes the card, so it does not reappear for this request.
    private var dismissed = false

    private static let settingsBundleID = "com.apple.systempreferences"
    private static let size = NSSize(width: 420, height: 84)
    private static let gap: CGFloat = 12

    func show(for kind: MissingPermission) {
        self.kind = kind
        dismissed = false
        let hosting = NSHostingView(rootView: PermissionGuideView(kind: kind) { [weak self] in
            self?.dismissed = true
            self?.hide()
        })
        if let panel {
            panel.contentView = hosting
        } else {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: true)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = hosting
            self.panel = panel
        }
        update()
    }

    /// Follows the System Settings window; shows the card only while Settings is frontmost.
    func update() {
        guard let panel, !dismissed else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID,
              let settings = Self.settingsWindowFrame() else {
            panel.orderOut(nil)
            return
        }
        var origin = NSPoint(x: settings.midX - Self.size.width / 2, y: settings.minY - Self.size.height - Self.gap)
        // No room below Settings: sit inside its bottom edge instead.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) }),
           origin.y < screen.visibleFrame.minY {
            origin.y = settings.minY + Self.gap
        }
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The main System Settings window in Cocoa coordinates. Window bounds (unlike titles)
    /// need no Screen Recording permission.
    private static func settingsWindowFrame() -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let frames = list.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
        guard let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // CGWindow bounds are top-left based on the primary display.
        return NSRect(x: largest.minX, y: primaryHeight - largest.maxY, width: largest.width, height: largest.height)
    }
}

private struct PermissionGuideView: View {
    let kind: MissingPermission
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            AppDragChip()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("Drag Sweep into the list above")
                    .font(.system(size: 13, weight: .semibold))
                Text("Then turn it on to allow \(kind == .accessibility ? "Accessibility" : "Input Monitoring").")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.blue)
                .phaseAnimator(reduceMotion ? [0] : [0, -5, 0]) { arrow, offset in
                    arrow.offset(y: offset)
                } animation: { _ in .easeInOut(duration: 0.45) }
                .accessibilityHidden(true)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.surface))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Sweep's icon as a drag source carrying the app bundle's file URL, which the privacy
/// lists in System Settings accept as a drop.
private struct AppDragChip: NSViewRepresentable {
    func makeNSView(context: Context) -> AppDragView { AppDragView() }
    func updateNSView(_ nsView: AppDragView, context: Context) {}
}

private final class AppDragView: NSView, NSDraggingSource {
    private let url = Bundle.main.bundleURL
    private lazy var icon = NSWorkspace.shared.icon(forFile: url.path)

    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 56) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Sweep app icon, drag into the list")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
