import Testing
@testable import Sweep

struct UnlockDetectorTests {
    private let left = KeyCode.leftCommand
    private let right = KeyCode.rightCommand
    private let space: UInt16 = 0x31

    @Test func completesAfterThreeContinuousSeconds() {
        var detector = UnlockDetector(duration: 3)
        #expect(detector.keyChanged(left, isDown: true, at: 10) == .none)
        #expect(detector.keyChanged(right, isDown: true, at: 10.2) == .began)
        #expect(detector.holdStartedAt == 10.2)
        #expect(detector.evaluate(at: 13.19) == .none)
        #expect(detector.evaluate(at: 13.2) == .completed)
        #expect(detector.phase == .completed)
    }

    @Test func progressFollowsRealElapsedTime() {
        var detector = UnlockDetector(duration: 3)
        _ = detector.keyChanged(left, isDown: true, at: 0)
        _ = detector.keyChanged(right, isDown: true, at: 0)
        #expect(detector.progress(at: 0) == 0)
        #expect(abs(detector.progress(at: 1.5) - 0.5) < 0.0001)
        #expect(detector.progress(at: 10) == 1)
    }

    @Test func releasingEarlyCancelsAndResetsProgress() {
        var detector = UnlockDetector(duration: 3)
        _ = detector.keyChanged(left, isDown: true, at: 0)
        _ = detector.keyChanged(right, isDown: true, at: 0)
        #expect(detector.keyChanged(right, isDown: false, at: 2.9) == .cancelled)
        #expect(detector.progress(at: 2.9) == 0)
        #expect(detector.evaluate(at: 5) == .none)

        // A new hold starts from zero.
        #expect(detector.keyChanged(right, isDown: true, at: 6) == .began)
        #expect(detector.evaluate(at: 8.9) == .none)
        #expect(detector.evaluate(at: 9) == .completed)
    }

    @Test func anyOtherKeyInvalidatesTheChord() {
        var detector = UnlockDetector(duration: 3)
        _ = detector.keyChanged(space, isDown: true, at: 0)
        _ = detector.keyChanged(left, isDown: true, at: 0)
        #expect(detector.keyChanged(right, isDown: true, at: 0) == .none, "a cloth pressing the space bar must not count")

        #expect(detector.keyChanged(space, isDown: false, at: 1) == .began)
        #expect(detector.keyChanged(space, isDown: true, at: 2) == .cancelled)
        #expect(detector.evaluate(at: 10) == .none)
    }

    @Test func autoRepeatNeverRestartsTheHold() {
        var detector = UnlockDetector(duration: 3)
        _ = detector.keyChanged(left, isDown: true, at: 0)
        _ = detector.keyChanged(right, isDown: true, at: 0)
        #expect(detector.keyChanged(right, isDown: true, isRepeat: true, at: 1) == .none)
        #expect(detector.holdStartedAt == 0)
        #expect(detector.evaluate(at: 3) == .completed)
    }

    @Test func keysHeldAtStartMustBeReleasedFirst() {
        var detector = UnlockDetector(duration: 3, initiallyPressed: [left, right])
        #expect(detector.phase == .awaitingRelease)
        #expect(detector.evaluate(at: 10) == .none)

        _ = detector.keyChanged(left, isDown: false, at: 1)
        #expect(detector.phase == .awaitingRelease)
        _ = detector.keyChanged(right, isDown: false, at: 1)
        #expect(detector.phase == .ready)

        _ = detector.keyChanged(left, isDown: true, at: 2)
        #expect(detector.keyChanged(right, isDown: true, at: 2) == .began)
    }

    @Test func reconcileRepairsALostKeyUp() {
        var detector = UnlockDetector(duration: 3)
        _ = detector.keyChanged(left, isDown: true, at: 0)
        _ = detector.keyChanged(right, isDown: true, at: 0)
        // The key-up event never arrived, but the HID state says right ⌘ is up.
        #expect(detector.reconcile(with: KeySnapshot(pressed: [left], authoritative: [left, right]), at: 1) == .cancelled)
        #expect(detector.evaluate(at: 5) == .none)
    }

    @Test func reconcileStillCompletesAnUnchangedHold() {
        var detector = UnlockDetector(duration: 3)
        _ = detector.keyChanged(left, isDown: true, at: 0)
        _ = detector.keyChanged(right, isDown: true, at: 0)
        #expect(detector.reconcile(with: KeySnapshot(pressed: [left, right], authoritative: [left, right]), at: 3.05) == .completed)
    }

    @Test func reconcileNeverDropsKeysItCannotSee() {
        var detector = UnlockDetector(duration: 3)
        _ = detector.keyChanged(right, isDown: true, at: 0)
        _ = detector.keyChanged(left, isDown: true, at: 0.5)
        // Regression: the HID state reported left ⌘ but not right ⌘, which used to cancel the hold.
        let snapshot = KeySnapshot(pressed: [left], authoritative: Set(0..<128).subtracting([right]))
        #expect(detector.reconcile(with: snapshot, at: 1) == .none)
        #expect(detector.chordKeysDown == [left, right])
        #expect(detector.reconcile(with: snapshot, at: 3.5) == .completed)
    }

    @Test func sideSpecificModifierFlags() {
        // ⌘ generic flag + both device bits.
        #expect(KeyCode.modifiersDown(flags: 0x0010_0018) == [left, right])
        #expect(KeyCode.modifiersDown(flags: 0x0010_0010) == [right])
        #expect(KeyCode.modifiersDown(flags: 0) == [])
        // Generic ⌘ without device bits: sides unknown.
        #expect(KeyCode.modifiersDown(flags: 0x0010_0000) == nil)
    }

    @Test func phantomKeysNeverBlockTheChord() {
        let keypadEnter: UInt16 = 0x4C
        // Reported down at start and on every poll, but never by a real event.
        var detector = UnlockDetector(duration: 3, initiallyPressed: [keypadEnter])
        #expect(detector.phase == .ready)
        let snapshot = KeySnapshot(pressed: [keypadEnter, left, right], authoritative: Set(0..<128))
        _ = detector.keyChanged(left, isDown: true, at: 0)
        #expect(detector.keyChanged(right, isDown: true, at: 0) == .began)
        #expect(detector.reconcile(with: snapshot, at: 1) == .none)
        #expect(detector.reconcile(with: snapshot, at: 3) == .completed)
    }

    @Test func defaultHoldIsThreeSeconds() {
        #expect(UnlockChord.holdDuration == 3)
    }

    @Test func capsLockIsIgnored() {
        var detector = UnlockDetector(duration: 3, initiallyPressed: [KeyCode.capsLock])
        #expect(detector.phase == .ready)
        _ = detector.keyChanged(KeyCode.capsLock, isDown: true, at: 0)
        _ = detector.keyChanged(left, isDown: true, at: 0)
        #expect(detector.keyChanged(right, isDown: true, at: 0) == .began)
    }

    @Test func completionIsFinal() {
        var detector = UnlockDetector(duration: 3)
        _ = detector.keyChanged(left, isDown: true, at: 0)
        _ = detector.keyChanged(right, isDown: true, at: 0)
        _ = detector.evaluate(at: 3)
        #expect(detector.keyChanged(right, isDown: false, at: 3.1) == .none)
        #expect(detector.phase == .completed)
    }

    @Test func modifierSidesAreToldApart() {
        let leftOnly: UInt64 = 0x0010_0108 // ⌘ + left-command device bit
        #expect(KeyCode.isModifierDown(keyCode: KeyCode.leftCommand, flags: leftOnly) == true)
        #expect(KeyCode.isModifierDown(keyCode: KeyCode.rightCommand, flags: leftOnly) == false)
        #expect(KeyCode.isModifierDown(keyCode: 0x00, flags: leftOnly) == nil)
    }
}
