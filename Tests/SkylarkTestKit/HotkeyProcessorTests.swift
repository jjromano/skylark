import Testing
import SkylarkCore

@Suite("HotkeyProcessor")
struct HotkeyProcessorTests {
    /// Base instant + advance helper so tests fully control the clock.
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }

    @Test("PTT happy path: hold ≥300ms then release → start, stop")
    func pttHappyPath() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.isRecording)
        #expect(p.process(.triggerUp, at: at(400)) == .stopRecording)
        #expect(!p.isRecording)
    }

    @Test("Short tap is discarded, not stopped")
    func shortTapDiscards() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(100)) == .discard)
        #expect(!p.isRecording)
    }

    @Test("Double-tap locks hands-free; next trigger down stops it")
    func doubleTapLockAndUnlock() {
        var p = HotkeyProcessor()
        // First quick tap (discarded, but records release time).
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(80)) == .discard)
        // Second quick tap within the double-tap window → lock; emits
        // .engageHandsFree so the orchestrator arms VAD endpointing.
        #expect(p.process(.triggerDown, at: at(150)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(220)) == .engageHandsFree)
        #expect(p.state == .doubleTapLock)
        #expect(p.isRecording)
        // Next trigger press stops the locked session.
        #expect(p.process(.triggerDown, at: at(2000)) == .stopRecording)
        #expect(p.state == .idle)
    }

    @Test("Two separated quick taps do NOT lock")
    func separatedTapsDoNotLock() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(80)) == .discard)
        // Second tap far outside the double-tap window.
        #expect(p.process(.triggerDown, at: at(1000)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(1080)) == .discard)
        #expect(p.state == .idle)
    }

    @Test("Chord interruption cancels and stays dirty until full release")
    func chordInterruptionDirtyCancel() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        // Non-trigger key while holding → cancel + dirty.
        #expect(p.process(.otherKeyDown(isEscape: false), at: at(120)) == .cancel)
        #expect(!p.isRecording)
        // Further input ignored until the trigger fully releases.
        #expect(p.process(.otherKeyDown(isEscape: false), at: at(130)) == nil)
        #expect(p.process(.triggerDown, at: at(140)) == nil)
        #expect(p.process(.triggerUp, at: at(200)) == nil) // clears dirty
        // Now a fresh session works again.
        #expect(p.process(.triggerDown, at: at(300)) == .startRecording)
    }

    @Test("ESC cancels an active hold")
    func escCancels() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.otherKeyDown(isEscape: true), at: at(500)) == .cancel)
        #expect(!p.isRecording)
    }

    @Test("ESC cancels a locked hands-free session")
    func escCancelsLock() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(80)) == .discard)
        #expect(p.process(.triggerDown, at: at(150)) == .startRecording)
        #expect(p.process(.triggerUp, at: at(220)) == .engageHandsFree) // locked
        #expect(p.state == .doubleTapLock)
        #expect(p.process(.otherKeyDown(isEscape: true), at: at(400)) == .cancel)
        #expect(p.state == .idle)
    }

    @Test("Mouse click within min-hold window discards")
    func mouseClickDiscards() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.mouseDown, at: at(100)) == .discard)
        #expect(!p.isRecording)
    }

    @Test("Mouse click after min-hold window is ignored (keeps recording)")
    func mouseClickIgnoredAfterThreshold() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.mouseDown, at: at(500)) == nil)
        #expect(p.isRecording)
        #expect(p.process(.triggerUp, at: at(700)) == .stopRecording)
    }

    @Test("Stray trigger up in idle does nothing")
    func strayTriggerUpIdle() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerUp, at: at(0)) == nil)
        #expect(p.state == .idle)
    }

    // MARK: - Interchangeable triggers (keyboard + mouse)

    // The processor is source-agnostic: the monitor maps both the bound key and
    // the bound mouse button to .triggerDown/.triggerUp. These tests assert the
    // "either trigger continues/stops the same session" contract.

    @Test("A second trigger press during a hold keeps the same session")
    func secondTriggerDuringHoldKeepsSession() {
        var p = HotkeyProcessor()
        // e.g. keyboard trigger starts the hold…
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        // …then the mouse trigger goes down too — no new session, no discard.
        #expect(p.process(.triggerDown, at: at(100)) == nil)
        #expect(p.isRecording)
        // First release ends the hold (≥ min-hold → stop).
        #expect(p.process(.triggerUp, at: at(500)) == .stopRecording)
        #expect(!p.isRecording)
    }

    @Test("Bound mouse trigger does NOT discard a too-short hold")
    func boundMouseTriggerDoesNotDiscard() {
        // The bound mouse button is routed to .triggerDown (not .mouseDown), so
        // pressing it inside the min-hold window must NOT discard the session —
        // unlike a stray, non-bound mouse click (see mouseClickDiscards).
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        #expect(p.process(.triggerDown, at: at(100)) == nil) // bound mouse down
        #expect(p.isRecording)
        #expect(p.process(.triggerUp, at: at(400)) == .stopRecording)
    }

    @Test("Either trigger can stop a hold started by the other")
    func eitherTriggerStopsHold() {
        var p = HotkeyProcessor()
        #expect(p.process(.triggerDown, at: at(0)) == .startRecording)
        // The other trigger's release (first up) ends the session.
        #expect(p.process(.triggerUp, at: at(600)) == .stopRecording)
        #expect(p.state == .idle)
        // A trailing release from the still-held trigger is a no-op in idle.
        #expect(p.process(.triggerUp, at: at(650)) == nil)
    }
}

@Suite("HotkeyProcessor refused-start lock release")
struct HotkeyProcessorRefusedStartTests {
    @Test("exitDoubleTapLock releases only a hands-free lock")
    func exitReleasesOnlyLock() {
        var p = HotkeyProcessor()
        let t0 = ContinuousClock.now
        // Idle: nothing to release.
        let idleRelease = p.exitDoubleTapLock()
        #expect(!idleRelease)
        // Held key: must NOT be disturbed (a real session is recording).
        _ = p.process(.triggerDown, at: t0)
        let heldRelease = p.exitDoubleTapLock()
        #expect(!heldRelease)
        #expect(p.state == .pressAndHold(start: t0))
        // Form the lock via a quick double tap, then release it.
        _ = p.process(.triggerUp, at: t0.advanced(by: .milliseconds(50)))
        _ = p.process(.triggerDown, at: t0.advanced(by: .milliseconds(120)))
        _ = p.process(.triggerUp, at: t0.advanced(by: .milliseconds(170)))
        #expect(p.state == .doubleTapLock)
        let lockedRelease = p.exitDoubleTapLock()
        #expect(lockedRelease)
        #expect(p.state == .idle)
        // After release, the next press starts a fresh session (not a stop).
        #expect(p.process(.triggerDown, at: t0.advanced(by: .seconds(1))) == .startRecording)
    }
}
