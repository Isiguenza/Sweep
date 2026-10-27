import Testing
@testable import Sweep

@MainActor
struct CleaningSessionTests {
    @Test func startAppliesEverythingAndUnlockRestoresIt() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration(brightness: 0.3))

        #expect(h.session.isRunning)
        #expect(h.blocker.startedPolicy == BlockingPolicy(blocksKeyboard: true, pointer: .blockAll))
        #expect(h.overlays.isVisible)
        #expect(h.cursor.concealed && h.cursor.frozen)
        #expect(h.brightness.levels[1] == 0.3)
        #expect(h.journal.entry?.brightness == ["BUILTIN": 0.8], "only displays with real brightness control are journaled")
        #expect(h.session.mascotState == .cleaning)

        h.pressChord()
        #expect(h.session.holdStartedAt != nil)
        #expect(h.session.mascotState == .wakingUp)
        h.clock.advance(by: UnlockChord.holdDuration)

        #expect(h.session.phase == .finished(.unlocked))
        #expect(!h.blocker.isRunning)
        #expect(!h.cursor.concealed)
        #expect(h.brightness.levels[1] == 0.8)
        #expect(h.journal.entry == nil)
        #expect(h.overlays.finishedReason == .unlocked)
        #expect(h.session.notice == nil)
        #expect(h.session.mascotState == .finished)
    }

    @Test func releasingBeforeThreeSecondsDoesNotUnlock() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration())
        h.pressChord()
        h.clock.advance(by: UnlockChord.holdDuration - 0.1)
        h.release(KeyCode.rightCommand)
        #expect(h.session.holdStartedAt == nil)
        h.clock.advance(by: 5)
        #expect(h.session.isRunning)
        #expect(h.blocker.isRunning)
    }

    @Test func chordHeldWhenStartingMustBeReleasedFirst() throws {
        let h = SessionHarness()
        h.keyState.pressed = [KeyCode.leftCommand, KeyCode.rightCommand]
        try h.session.start(SessionHarness.configuration())
        h.clock.advance(by: 10)
        #expect(h.session.isRunning)
    }

    @Test func lostKeyUpIsRepairedFromHIDState() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration())
        h.pressChord()
        h.clock.advance(by: 1)
        // Right ⌘ goes up physically but the event is lost.
        h.keyState.pressed.remove(KeyCode.rightCommand)
        h.clock.advance(by: 0.2)
        #expect(h.session.holdStartedAt == nil)
        h.clock.advance(by: 5)
        #expect(h.session.isRunning)
    }

    @Test func rightCommandSurvivesHIDStateThatCannotSeeIt() throws {
        let h = SessionHarness()
        h.keyState.blind = [KeyCode.rightCommand]
        try h.session.start(SessionHarness.configuration())
        h.press(KeyCode.rightCommand)
        h.press(KeyCode.leftCommand)
        h.clock.advance(by: 1)
        #expect(h.session.chordKeysDown == UnlockChord.keyCodes)
        h.clock.advance(by: UnlockChord.holdDuration - 0.9)
        #expect(h.session.phase == .finished(.unlocked))
    }

    @Test func phantomKeyInHIDStateDoesNotBlockUnlocking() throws {
        let h = SessionHarness()
        h.keyState.pressed = [0x4C] // stuck "keypad Enter", as seen on a real MacBook
        try h.session.start(SessionHarness.configuration())
        h.pressChord()
        #expect(h.session.holdStartedAt != nil)
        h.clock.advance(by: UnlockChord.holdDuration)
        #expect(h.session.phase == .finished(.unlocked))
    }

    @Test func blockingRequiresAccessibility() {
        let h = SessionHarness()
        h.permissions.isAccessibilityTrusted = false
        #expect(throws: SessionStartError.accessibilityRequired) {
            try h.session.start(SessionHarness.configuration())
        }
        #expect(h.overlays.presented == nil)
        #expect(!h.blocker.isRunning)
        #expect(!h.session.isRunning)
    }

    @Test func screenOnlyWithoutAccessibilityUsesLocalMonitor() throws {
        let h = SessionHarness()
        h.permissions.isAccessibilityTrusted = false
        try h.session.start(SessionHarness.configuration(keyboard: false, pointer: .passAll))
        #expect(h.localMonitor.isRunning)
        #expect(!h.blocker.isRunning)
        #expect(h.cursor.concealed && !h.cursor.frozen)

        h.keyState.pressed = UnlockChord.keyCodes
        h.localMonitor.send(.key(code: KeyCode.leftCommand, isDown: true, isRepeat: false, time: h.clock.now))
        h.localMonitor.send(.key(code: KeyCode.rightCommand, isDown: true, isRepeat: false, time: h.clock.now))
        h.clock.advance(by: UnlockChord.holdDuration)
        #expect(h.session.phase == .finished(.unlocked))
        #expect(!h.localMonitor.isRunning)
    }

    @Test func keyboardBlockingIsRefusedDuringSecureInput() {
        let h = SessionHarness()
        h.permissions.isSecureInputEnabled = true
        #expect(throws: SessionStartError.secureInputActive) {
            try h.session.start(SessionHarness.configuration())
        }
    }

    @Test func keepingTheMouseNeedsInputMonitoring() throws {
        let h = SessionHarness()
        h.permissions.isInputMonitoringGranted = false
        #expect(throws: SessionStartError.inputMonitoringRequired) {
            try h.session.start(SessionHarness.configuration(pointer: .allowOnlyExternalMice))
        }

        h.permissions.isInputMonitoringGranted = true
        try h.session.start(SessionHarness.configuration(pointer: .allowOnlyExternalMice))
        #expect(h.mouseMonitor.isRunning)
        #expect(!h.cursor.frozen, "the mouse must keep moving the cursor")
        h.session.end(.endedByUser)
        #expect(!h.mouseMonitor.isRunning)
    }

    @Test func failingToStartTheTapRollsEverythingBack() {
        let h = SessionHarness()
        h.blocker.failsToStart = true
        #expect(throws: SessionStartError.inputUnavailable) {
            try h.session.start(SessionHarness.configuration(pointer: .allowOnlyExternalMice, brightness: 0.2))
        }
        #expect(h.overlays.dismissed)
        #expect(h.brightness.levels[1] == 0.8)
        #expect(h.journal.entry == nil)
        #expect(!h.mouseMonitor.isRunning)
        #expect(!h.cursor.concealed)
        #expect(!h.session.isRunning)
    }

    @Test func disabledTapEndsSafelyWithNotice() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration(brightness: 0.1))
        h.blocker.send(.tapDisabled)
        #expect(h.session.phase == .finished(.tapDisabled))
        #expect(h.session.notice != nil)
        #expect(!h.blocker.isRunning)
        #expect(h.brightness.levels[1] == 0.8)
    }

    @Test func revokedAccessibilityEndsTheSession() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration())
        h.permissions.isAccessibilityTrusted = false
        h.clock.advance(by: 1.05)
        #expect(h.session.phase == .finished(.accessibilityRevoked))
    }

    @Test func secureInputMidSessionEndsKeyboardBlocking() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration())
        h.permissions.isSecureInputEnabled = true
        h.clock.advance(by: 1.05)
        #expect(h.session.phase == .finished(.secureInputEnabled))
    }

    @Test func safetyLimitAlwaysEndsTheSession() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration(safetyLimit: 120))
        h.clock.advance(by: 119)
        #expect(h.session.isRunning)
        h.clock.advance(by: 1.1)
        #expect(h.session.phase == .finished(.safetyLimit))
        #expect(!h.blocker.isRunning)
    }

    @Test func endingTwiceIsHarmless() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration())
        h.session.end(.systemInterruption)
        h.session.end(.unlocked)
        #expect(h.session.phase == .finished(.systemInterruption))
        #expect(h.blocker.stopCount == 1)
    }

    @Test func blockedInputBrieflyChangesMascotState() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration())
        h.blocker.send(.blockedInput)
        #expect(h.session.blockedInputCount == 1)
        #expect(h.session.mascotState == .reactingToBlockedInput)
        h.clock.advance(by: 1)
        #expect(h.session.mascotState == .cleaning)
    }

    @Test func nothingSelectedCannotStart() {
        let h = SessionHarness()
        #expect(throws: SessionStartError.nothingSelected) {
            try h.session.start(SessionHarness.configuration(keyboard: false, pointer: .passAll, blackout: nil))
        }
    }

    @Test func aNewSessionCanStartAfterFinishing() throws {
        let h = SessionHarness()
        try h.session.start(SessionHarness.configuration())
        h.session.end(.endedByUser)
        try h.session.start(SessionHarness.configuration())
        #expect(h.session.isRunning)
        #expect(h.blocker.isRunning)
    }
}
