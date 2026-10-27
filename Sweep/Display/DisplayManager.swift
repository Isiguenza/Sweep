import AppKit
import CoreGraphics
import Observation

nonisolated struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    /// Stable across reboots and reconnections; used for persistence.
    let uuid: String
    let name: String
    let isBuiltIn: Bool
}

nonisolated enum ScreenTarget: Codable, Hashable, Sendable {
    case all
    case display(uuid: String)

    func resolve(in displays: [DisplayInfo]) -> [DisplayInfo] {
        switch self {
        case .all: displays
        case .display(let uuid): displays.filter { $0.uuid == uuid }
        }
    }
}

/// Connected displays with human-friendly names, refreshed on any reconfiguration.
@Observable
final class DisplayManager {
    private(set) var displays: [DisplayInfo] = []

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onChange?()
            }
        }
    }

    func refresh() {
        let next = Self.makeDisplays(from: NSScreen.screens)
        if next != displays { displays = next }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    static func makeDisplays(from screens: [NSScreen]) -> [DisplayInfo] {
        let raw = screens.compactMap { screen -> (CGDirectDisplayID, String, Bool)? in
            guard let id = screen.displayID else { return nil }
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            return (id, isBuiltIn ? "Built-in Display" : screen.localizedName, isBuiltIn)
        }
        let names = disambiguated(raw.map(\.1))
        return zip(raw, names).map { entry, name in
            DisplayInfo(id: entry.0, uuid: uuid(for: entry.0), name: name, isBuiltIn: entry.2)
        }
        .sorted { ($0.isBuiltIn ? 0 : 1, $0.name) < ($1.isBuiltIn ? 0 : 1, $1.name) }
    }

    /// Two identical monitors become "DELL U2723QE" and "DELL U2723QE 2".
    static func disambiguated(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let count = seen[name, default: 0] + 1
            seen[name] = count
            return count == 1 ? name : "\(name) \(count)"
        }
    }

    private static func uuid(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return String(id) }
        return string as String
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
