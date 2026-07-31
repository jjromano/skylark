import Testing
import SkylarkCore

// The full reconcile path lives inside HotkeyMonitor.handle, which needs real
// CGEvents (not unit-testable headless). The load-bearing DECISION — whether to
// synthesize a triggerUp after the tap is re-enabled — is extracted into a pure
// static helper and tested here.
@Suite("HotkeyMonitor reconcile decision")
struct HotkeyMonitorLogicTests {
    @Test("Trigger was pressed and is now released → synthesize triggerUp")
    func pressedToReleased() {
        #expect(HotkeyMonitor.reconcileNeedsSyntheticUp(wasPressed: true, nowPressed: false))
    }

    @Test("Still pressed → no synthetic triggerUp")
    func stillPressed() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticUp(wasPressed: true, nowPressed: true))
    }

    @Test("Was already released → no synthetic triggerUp")
    func alreadyReleased() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticUp(wasPressed: false, nowPressed: false))
    }

    @Test("Newly pressed → no synthetic triggerUp")
    func newlyPressed() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticUp(wasPressed: false, nowPressed: true))
    }

    @Test("Legacy Fn-named helper delegates to the generalized decision")
    func legacyAliasMatches() {
        #expect(HotkeyMonitor.reconcileNeedsSyntheticFnUp(wasPressed: true, nowPressed: false))
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticFnUp(wasPressed: true, nowPressed: true))
    }
}

// A modifier trigger (esp. Fn/globe) must count as still held if EITHER the
// device flag OR the physical key reports down: the secondary-Fn flag reads 0
// unreliably in combinedSessionState while the key is physically held, and
// trusting it alone would synthesize a false triggerUp that clips an in-progress
// hold. This is the pure policy behind HotkeyMonitor.liveTriggerHeld.
@Suite("HotkeyMonitor modifier still-held policy")
struct HotkeyMonitorModifierHeldTests {
    @Test("Flag up but physical key still down → still held (Fn-flag misread guard)")
    func keyDownFlagUp() {
        #expect(HotkeyMonitor.modifierStillHeld(flagDown: false, keyDown: true))
    }

    @Test("Flag down but key read up → still held")
    func flagDownKeyUp() {
        #expect(HotkeyMonitor.modifierStillHeld(flagDown: true, keyDown: false))
    }

    @Test("Both report down → still held")
    func bothDown() {
        #expect(HotkeyMonitor.modifierStillHeld(flagDown: true, keyDown: true))
    }

    @Test("Both report up → genuinely released")
    func bothUp() {
        #expect(!HotkeyMonitor.modifierStillHeld(flagDown: false, keyDown: false))
    }
}

// U1 regression. A tap stall used to reset the trigger state machines while the
// orchestrator kept recording: the user's REAL key-up then returned nil, no
// `.stopRecording` was ever emitted, and the mic stayed open with the HUD stuck
// on a live recording dot until quit. Only a FINALIZING interruption may reset.
@Suite("HotkeyMonitor interruption trigger-state policy")
struct HotkeyInterruptionResetPolicyTests {
    @Test("A benign tap stall must NOT reset the trigger state machines")
    func stallKeepsTriggerState() {
        #expect(!HotkeyMonitor.interruptionResetsTriggerState(.triggerTapStalled))
        #expect(!HotkeyMonitor.interruptionResetsTriggerState(.configurationChange))
    }

    @Test("A finalizing interruption resets them (the session is already over)")
    func finalizingResetsTriggerState() {
        #expect(HotkeyMonitor.interruptionResetsTriggerState(.permissionLost))
        #expect(HotkeyMonitor.interruptionResetsTriggerState(.restartFailed))
    }

    @Test("After a non-finalizing stall, the real trigger release still stops the session")
    func releaseAfterStallStillStops() {
        var processor = HotkeyProcessor()
        let start = ContinuousClock.now
        #expect(processor.process(.triggerDown, at: start) == .startRecording)

        // What the monitor does at a `.triggerTapStalled` boundary: emit the
        // marker, keep the state machine exactly as it was.
        #expect(!HotkeyMonitor.interruptionResetsTriggerState(.triggerTapStalled))
        #expect(processor.isRecording)

        let release = start.advanced(by: .milliseconds(900))
        #expect(processor.process(.triggerUp, at: release) == .stopRecording)
        #expect(!processor.isRecording)
    }

    @Test("A reset processor swallows the release — the bug this policy prevents")
    func resetProcessorSwallowsTheRelease() {
        var processor = HotkeyProcessor()
        let start = ContinuousClock.now
        _ = processor.process(.triggerDown, at: start)
        processor = HotkeyProcessor()  // the old unconditional reset
        #expect(processor.process(.triggerUp, at: start.advanced(by: .milliseconds(900))) == nil)
    }
}

// The chord keyDown decision — does the event's modifier state EXACTLY match the
// bound chord — is the load-bearing bit of HotkeyMonitor.handle for chords. It is
// factored into a pure static so it's testable without a live CGEventTap.
@Suite("HotkeyMonitor chord matching")
struct HotkeyMonitorChordMatchTests {
    // CGEventFlags device-independent bits.
    private static let shift: UInt64 = 1 << 17
    private static let control: UInt64 = 1 << 18
    private static let option: UInt64 = 1 << 19
    private static let command: UInt64 = 1 << 20
    // Bits arrow keys carry that must be masked off before comparison.
    private static let numericPad: UInt64 = 1 << 21
    private static let function: UInt64 = 1 << 23
    private static let secondaryFn: UInt64 = 1 << 23

    @Test("Exact single-modifier match fires (⌥ present, nothing else)")
    func exactSingleModifier() {
        #expect(HotkeyMonitor.chordModifiersMatch(
            eventFlagsRawValue: Self.option, chord: .option))
    }

    @Test("Extra modifier bit defeats the match (⌥⇧ ≠ ⌥)")
    func extraModifierNoMatch() {
        #expect(!HotkeyMonitor.chordModifiersMatch(
            eventFlagsRawValue: Self.option | Self.shift, chord: .option))
    }

    @Test("Missing modifier bit defeats the match (⌥ ≠ ⌥⇧)")
    func missingModifierNoMatch() {
        #expect(!HotkeyMonitor.chordModifiersMatch(
            eventFlagsRawValue: Self.option, chord: [.option, .shift]))
    }

    @Test("Multi-modifier exact match fires (⌘⇧ present)")
    func exactMultiModifier() {
        #expect(HotkeyMonitor.chordModifiersMatch(
            eventFlagsRawValue: Self.command | Self.shift, chord: [.command, .shift]))
    }

    @Test("Non-modifier bits (numeric-pad / function) are masked off")
    func ignoresNonModifierBits() {
        // An ⌥+Arrow event carries numericPad|function alongside ⌥; those bits
        // must not defeat a ⌥ chord match.
        #expect(HotkeyMonitor.chordModifiersMatch(
            eventFlagsRawValue: Self.option | Self.numericPad | Self.function,
            chord: .option))
    }

    @Test("Fn bit alongside the modifier is ignored")
    func ignoresFnBit() {
        #expect(HotkeyMonitor.chordModifiersMatch(
            eventFlagsRawValue: Self.command | Self.secondaryFn, chord: .command))
    }

    @Test("No modifiers held never matches a chord requiring one")
    func noModifiersNoMatch() {
        #expect(!HotkeyMonitor.chordModifiersMatch(eventFlagsRawValue: 0, chord: .option))
    }
}
