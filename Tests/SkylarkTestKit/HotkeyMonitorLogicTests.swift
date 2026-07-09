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
