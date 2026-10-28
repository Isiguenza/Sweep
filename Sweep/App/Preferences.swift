import Foundation
import Observation

/// User choices, persisted as soon as they change.
@Observable
final class Preferences {
    var blockKeyboard: Bool { didSet { save(blockKeyboard, .blockKeyboard) } }
    var blockTrackpad: Bool { didSet { save(blockTrackpad, .blockTrackpad) } }
    var blockMouse: Bool { didSet { save(blockMouse, .blockMouse) } }
    var blackout: Bool { didSet { save(blackout, .blackout) } }
    var screenTarget: ScreenTarget { didSet { saveCodable(screenTarget, .screenTarget) } }
    var adjustsBrightness: Bool { didSet { save(adjustsBrightness, .adjustsBrightness) } }
    var brightness: Double { didSet { save(brightness, .brightness) } }
    var safetyLimitMinutes: Int { didSet { save(safetyLimitMinutes, .safetyLimit) } }
    /// Set once the user dismisses the welcome card; it never shows again after that.
    var hasSeenWelcome: Bool { didSet { save(hasSeenWelcome, .hasSeenWelcome) } }
    var showInMenuBar: Bool {
        didSet {
            save(showInMenuBar, .showInMenuBar)
            onShowInMenuBarChange?(showInMenuBar)
        }
    }

    @ObservationIgnored var onShowInMenuBarChange: ((Bool) -> Void)?

    static let safetyLimitChoices = [2, 5, 10, 15]

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key: String {
        case blockKeyboard, blockTrackpad, blockMouse, blackout, screenTarget, adjustsBrightness, brightness, safetyLimit, showInMenuBar, hasSeenWelcome
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.blockKeyboard.rawValue: true,
            Key.blockTrackpad.rawValue: true,
            Key.blockMouse.rawValue: false,
            Key.blackout.rawValue: true,
            Key.adjustsBrightness.rawValue: false,
            Key.brightness.rawValue: 0.5,
            Key.safetyLimit.rawValue: 5,
            Key.showInMenuBar.rawValue: true,
        ])
        blockKeyboard = defaults.bool(forKey: Key.blockKeyboard.rawValue)
        blockTrackpad = defaults.bool(forKey: Key.blockTrackpad.rawValue)
        blockMouse = defaults.bool(forKey: Key.blockMouse.rawValue)
        blackout = defaults.bool(forKey: Key.blackout.rawValue)
        adjustsBrightness = defaults.bool(forKey: Key.adjustsBrightness.rawValue)
        brightness = defaults.double(forKey: Key.brightness.rawValue)
        showInMenuBar = defaults.bool(forKey: Key.showInMenuBar.rawValue)
        hasSeenWelcome = defaults.bool(forKey: Key.hasSeenWelcome.rawValue)
        let limit = defaults.integer(forKey: Key.safetyLimit.rawValue)
        safetyLimitMinutes = Self.safetyLimitChoices.contains(limit) ? limit : 5
        screenTarget = defaults.data(forKey: Key.screenTarget.rawValue)
            .flatMap { try? JSONDecoder().decode(ScreenTarget.self, from: $0) } ?? .all
    }

    private func save(_ value: some Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private func saveCodable(_ value: some Encodable, _ key: Key) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key.rawValue)
    }
}
