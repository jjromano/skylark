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
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        #expect(p.isRecording)
        #expect(p.process(.fnUp, at: at(400)) == .stopRecording)
        #expect(!p.isRecording)
    }

    @Test("Short tap is discarded, not stopped")
    func shortTapDiscards() {
        var p = HotkeyProcessor()
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        #expect(p.process(.fnUp, at: at(100)) == .discard)
        #expect(!p.isRecording)
    }

    @Test("Double-tap locks hands-free; next Fn down stops it")
    func doubleTapLockAndUnlock() {
        var p = HotkeyProcessor()
        // First quick tap (discarded, but records release time).
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        #expect(p.process(.fnUp, at: at(80)) == .discard)
        // Second quick tap within the double-tap window → lock (no extra output).
        #expect(p.process(.fnDown, at: at(150)) == .startRecording)
        #expect(p.process(.fnUp, at: at(220)) == nil)
        #expect(p.state == .doubleTapLock)
        #expect(p.isRecording)
        // Next Fn press stops the locked session.
        #expect(p.process(.fnDown, at: at(2000)) == .stopRecording)
        #expect(p.state == .idle)
    }

    @Test("Two separated quick taps do NOT lock")
    func separatedTapsDoNotLock() {
        var p = HotkeyProcessor()
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        #expect(p.process(.fnUp, at: at(80)) == .discard)
        // Second tap far outside the double-tap window.
        #expect(p.process(.fnDown, at: at(1000)) == .startRecording)
        #expect(p.process(.fnUp, at: at(1080)) == .discard)
        #expect(p.state == .idle)
    }

    @Test("Chord interruption cancels and stays dirty until full release")
    func chordInterruptionDirtyCancel() {
        var p = HotkeyProcessor()
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        // Non-Fn key while holding → cancel + dirty.
        #expect(p.process(.otherKeyDown(isEscape: false), at: at(120)) == .cancel)
        #expect(!p.isRecording)
        // Further input ignored until Fn fully releases.
        #expect(p.process(.otherKeyDown(isEscape: false), at: at(130)) == nil)
        #expect(p.process(.fnDown, at: at(140)) == nil)
        #expect(p.process(.fnUp, at: at(200)) == nil) // clears dirty
        // Now a fresh session works again.
        #expect(p.process(.fnDown, at: at(300)) == .startRecording)
    }

    @Test("ESC cancels an active hold")
    func escCancels() {
        var p = HotkeyProcessor()
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        #expect(p.process(.otherKeyDown(isEscape: true), at: at(500)) == .cancel)
        #expect(!p.isRecording)
    }

    @Test("ESC cancels a locked hands-free session")
    func escCancelsLock() {
        var p = HotkeyProcessor()
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        #expect(p.process(.fnUp, at: at(80)) == .discard)
        #expect(p.process(.fnDown, at: at(150)) == .startRecording)
        #expect(p.process(.fnUp, at: at(220)) == nil) // locked
        #expect(p.state == .doubleTapLock)
        #expect(p.process(.otherKeyDown(isEscape: true), at: at(400)) == .cancel)
        #expect(p.state == .idle)
    }

    @Test("Mouse click within min-hold window discards")
    func mouseClickDiscards() {
        var p = HotkeyProcessor()
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        #expect(p.process(.mouseDown, at: at(100)) == .discard)
        #expect(!p.isRecording)
    }

    @Test("Mouse click after min-hold window is ignored (keeps recording)")
    func mouseClickIgnoredAfterThreshold() {
        var p = HotkeyProcessor()
        #expect(p.process(.fnDown, at: at(0)) == .startRecording)
        #expect(p.process(.mouseDown, at: at(500)) == nil)
        #expect(p.isRecording)
        #expect(p.process(.fnUp, at: at(700)) == .stopRecording)
    }

    @Test("Stray Fn up in idle does nothing")
    func strayFnUpIdle() {
        var p = HotkeyProcessor()
        #expect(p.process(.fnUp, at: at(0)) == nil)
        #expect(p.state == .idle)
    }
}
