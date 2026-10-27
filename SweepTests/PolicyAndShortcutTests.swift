import Carbon.HIToolbox
import Foundation
import Testing
@testable import Sweep

struct PointerPolicyTests {
    @Test(arguments: [
        (true, true, true, true, PointerPolicy.blockAll),
        (false, false, true, true, .passAll),
        (true, false, true, true, .allowOnlyExternalMice),
        (true, false, false, true, .blockAll),
        (false, true, true, true, .blockOnlyExternalMice),
        (false, true, false, true, .passAll),
        (false, true, true, false, .blockAll),
    ])
    func policyMatrix(blockTrackpad: Bool, blockMouse: Bool, hasMouse: Bool, hasTrackpad: Bool, expected: PointerPolicy) {
        #expect(PointerPolicy.make(blockTrackpad: blockTrackpad, blockMouse: blockMouse, hasExternalMouse: hasMouse, hasTrackpad: hasTrackpad) == expected)
    }

    @Test func recentMouseReportAttributesTheEvent() {
        #expect(PointerAttribution.verdict(eventTime: 10, lastMouseActivity: 9.99, now: 10, allowsGrace: false) == .externalMouse)
        #expect(PointerAttribution.verdict(eventTime: 10, lastMouseActivity: 10.004, now: 10.005, allowsGrace: true) == .externalMouse)
    }

    @Test func staleOrMissingActivityIsNotTheMouse() {
        #expect(PointerAttribution.verdict(eventTime: 10, lastMouseActivity: 9.9, now: 10, allowsGrace: false) == .other)
        #expect(PointerAttribution.verdict(eventTime: 10, lastMouseActivity: nil, now: 10, allowsGrace: false) == .other)
    }

    @Test func discreteEventsWaitOnlyWithinTheGraceWindow() {
        #expect(PointerAttribution.verdict(eventTime: 10, lastMouseActivity: nil, now: 10.005, allowsGrace: true) == .undetermined)
        #expect(PointerAttribution.verdict(eventTime: 10, lastMouseActivity: nil, now: 10.02, allowsGrace: true) == .other)
    }

    @Test func gesturesAreNeverTreatedAsMouseInput() {
        #expect(PointerAttribution.shouldBlock(policy: .allowOnlyExternalMice, isGesture: true, verdict: .externalMouse))
        #expect(!PointerAttribution.shouldBlock(policy: .allowOnlyExternalMice, isGesture: false, verdict: .externalMouse))
        #expect(PointerAttribution.shouldBlock(policy: .allowOnlyExternalMice, isGesture: false, verdict: .other))
        #expect(!PointerAttribution.shouldBlock(policy: .blockOnlyExternalMice, isGesture: true, verdict: .other))
        #expect(PointerAttribution.shouldBlock(policy: .blockOnlyExternalMice, isGesture: false, verdict: .externalMouse))
    }
}

struct ShortcutTests {
    private func combo(command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) -> KeyCombo {
        KeyCombo(keyCode: UInt16(kVK_ANSI_S), command: command, option: option, control: control, shift: shift, key: "S")
    }

    @Test func requiresARealModifier() {
        #expect(ShortcutValidator.validate(combo(), reserved: { _ in false }) == .needsModifier)
        #expect(ShortcutValidator.validate(combo(shift: true), reserved: { _ in false }) == .needsModifier)
        #expect(ShortcutValidator.validate(combo(command: true), reserved: { _ in false }) == nil)
    }

    @Test func rejectsSystemShortcuts() {
        #expect(ShortcutValidator.validate(combo(command: true), reserved: { _ in true }) == .reservedBySystem)
    }

    @Test func defaultShortcutIsValidAndReadable() {
        #expect(KeyCombo.default.displayString == "⌃⌥⌘S")
        #expect(ShortcutValidator.validate(.default, reserved: { _ in false }) == nil)
        #expect(KeyCombo.default.carbonModifiers == UInt32(cmdKey | optionKey | controlKey))
    }

    @Test func comboRoundTripsThroughStorage() throws {
        let data = try JSONEncoder().encode(KeyCombo.default)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == .default)
    }
}

struct DisplayTests {
    @Test func identicalMonitorsGetDistinctNames() {
        #expect(DisplayManager.disambiguated(["Built-in Display", "DELL", "DELL"]) == ["Built-in Display", "DELL", "DELL 2"])
    }

    @Test func targetResolvesOnlyConnectedDisplays() {
        let displays = [SessionHarness.builtIn, SessionHarness.external]
        #expect(ScreenTarget.all.resolve(in: displays) == displays)
        #expect(ScreenTarget.display(uuid: "EXT").resolve(in: displays) == [SessionHarness.external])
        #expect(ScreenTarget.display(uuid: "GONE").resolve(in: displays).isEmpty)
    }
}
