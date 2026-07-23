import Testing
import SkylarkCore

/// Voice Command Mode uses a dedicated `HotkeyProcessor(pressAndHoldOnly: true)`
/// so it is strictly hold-to-speak: no double-tap-lock, ESC/chord still cancel.
/// These assert the command trigger's semantics differ from dictation exactly
/// where they should and match everywhere else.
@Suite("Command mode hotkey")
struct CommandModeHotkeyTests {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }

    // MARK: - Press-and-hold-only processor (command trigger)

    @Test("Command trigger: hold ≥300ms then release → start, stop")
    func commandPressAndHold() {
        var p = HotkeyProcessor(pressAndHoldOnly: true)
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.isRecording)
        #expect(p.process(.triggerUp, at: at(400)) == .stopRecording)
        #expect(!p.isRecording)
    }

    @Test("Command trigger: short tap is discarded, never a command")
    func commandShortTapDiscards() {
        var p = HotkeyProcessor(pressAndHoldOnly: true)
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(100)) == .discard)
        #expect(!p.isRecording)
    }

    @Test("Command trigger NEVER double-tap-locks (unlike dictation)")
    func commandNeverLocks() {
        var p = HotkeyProcessor(pressAndHoldOnly: true)
        // Two quick taps that WOULD lock a dictation processor…
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(80)) == .discard)
        #expect(p.process(.triggerDown, at: at(150)) == .startRecording)
        // …stay a plain (too-short) hold: discard, NOT .engageHandsFree.
        #expect(p.process(.triggerUp, at: at(220)) == .discard)
        #expect(p.state == .idle)
        #expect(!p.isRecording)
    }

    @Test("Command trigger: contrast — a dictation processor DOES lock on the same input")
    func dictationLocksOnSameInput() {
        var p = HotkeyProcessor() // dictation (double-tap enabled)
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(80)) == .discard)
        #expect(p.process(.triggerDown, at: at(150)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(220)) == .engageHandsFree)
        #expect(p.state == .doubleTapLock)
    }

    @Test("Command trigger: ESC cancels an active hold")
    func commandEscCancels() {
        var p = HotkeyProcessor(pressAndHoldOnly: true)
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.otherKeyDown(isEscape: true), at: at(500)) == .cancel)
        #expect(!p.isRecording)
    }

    @Test("Command trigger: a stray key cancels and stays dirty until release")
    func commandStrayKeyCancels() {
        var p = HotkeyProcessor(pressAndHoldOnly: true)
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.otherKeyDown(isEscape: false), at: at(120)) == .cancel)
        #expect(p.process(.triggerUp, at: at(200)) == nil) // clears dirty
        #expect(p.process(.triggerDown, at: at(300)) == .startRecording)
    }

    // MARK: - Persistence

    @Test("Command binding persists under its own defaults key and round-trips")
    func commandBindingRoundTrips() {
        // The command slot is a distinct UserDefaults key from dictation.
        #expect(HotkeyBinding.defaultsKeyCommand == "hotkey.command")
        #expect(HotkeyBinding.defaultsKeyCommand != HotkeyBinding.defaultsKeyKeyboard)
        #expect(HotkeyBinding.defaultsKeyCommand != HotkeyBinding.defaultsKeyMouse)

        // A chord binding (the recommended command trigger) round-trips through
        // the stable rawValue string used for persistence.
        for binding in [
            HotkeyBinding.chord(modifiers: [.command, .shift], keyCode: 49),
            .functionKey(105),
            .rightOption,
        ] {
            let restored = HotkeyBinding(rawValue: binding.rawValue)
            #expect(restored == binding)
        }
    }
}
