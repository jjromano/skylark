import Testing
import SkylarkCore

/// The read-signaled clipboard-restore state machine (WS3). The AppKit half
/// (data provider callback, pasteboard writes) isn't unit-testable headless, so
/// the decision logic it drives is exercised directly here.
@Suite("Paste restore decider")
struct PasteRestoreDeciderTests {
    /// The normal fast path: paste posted, target reads, grace elapses, restore.
    @Test("First read starts the grace; grace elapsing restores")
    func firstReadRestoresAfterGrace() {
        var decider = PasteRestoreDecider()
        #expect(decider.handle(.armed) == .ignore)
        #expect(decider.handle(.pasteboardRead) == .startReadGrace)
        #expect(decider.handle(.readGraceElapsed) == .restore)
        #expect(decider.phase == .restored)
    }

    /// Electron/Chromium targets read the pasteboard more than once — the second
    /// read must not schedule a second grace, and restore still happens ONCE.
    @Test("Double read inside the grace restores exactly once")
    func doubleReadRestoresOnce() {
        var decider = PasteRestoreDecider()
        _ = decider.handle(.armed)
        #expect(decider.handle(.pasteboardRead) == .startReadGrace)
        #expect(decider.handle(.pasteboardRead) == .ignore)
        #expect(decider.handle(.pasteboardRead) == .ignore)
        #expect(decider.handle(.readGraceElapsed) == .restore)
        // Any later signal is inert: no second restore, no re-arming.
        #expect(decider.handle(.pasteboardRead) == .ignore)
        #expect(decider.handle(.readGraceElapsed) == .ignore)
        #expect(decider.handle(.fallbackElapsed) == .ignore)
    }

    /// A target that never reads (focus died, app ignored the paste) still gets
    /// the user's clipboard back — the old 500 ms timer as a ceiling.
    @Test("No read at all: the fallback ceiling restores")
    func fallbackRestoresWhenNoRead() {
        var decider = PasteRestoreDecider()
        _ = decider.handle(.armed)
        #expect(decider.handle(.fallbackElapsed) == .restore)
        #expect(decider.phase == .restored)
    }

    /// A read arriving BEFORE Cmd-V is a clipboard manager reacting to our write,
    /// not the paste. Honouring it would restore early and make the target paste
    /// the user's OLD clipboard — the exact bug the timer had.
    @Test("Read before arming is ignored (clipboard manager, not the target)")
    func preArmReadIgnored() {
        var decider = PasteRestoreDecider()
        #expect(decider.handle(.pasteboardRead) == .ignore)
        #expect(decider.phase == .unarmed)
        // Arming still works, and a post-arm read is honoured normally.
        #expect(decider.handle(.armed) == .ignore)
        #expect(decider.handle(.pasteboardRead) == .startReadGrace)
    }

    /// The fallback firing while the grace is still running restores rather than
    /// waiting: a clipboard that never comes back is worse than a slightly early
    /// restore.
    @Test("Fallback during the read grace still restores once")
    func fallbackDuringGrace() {
        var decider = PasteRestoreDecider()
        _ = decider.handle(.armed)
        _ = decider.handle(.pasteboardRead)
        #expect(decider.handle(.fallbackElapsed) == .restore)
        #expect(decider.handle(.readGraceElapsed) == .ignore)
    }

    /// A second dictation inside the fallback window flushes the pending restore
    /// first, so the new snapshot can't capture the previous transcript.
    @Test("Supersede restores immediately from every live phase")
    func supersedeRestores() {
        var unarmed = PasteRestoreDecider()
        #expect(unarmed.handle(.superseded) == .restore)

        var armed = PasteRestoreDecider()
        _ = armed.handle(.armed)
        #expect(armed.handle(.superseded) == .restore)

        var waiting = PasteRestoreDecider()
        _ = waiting.handle(.armed)
        _ = waiting.handle(.pasteboardRead)
        #expect(waiting.handle(.superseded) == .restore)

        // Already restored → inert (never a double restore).
        var done = PasteRestoreDecider()
        _ = done.handle(.armed)
        _ = done.handle(.fallbackElapsed)
        #expect(done.handle(.superseded) == .ignore)
    }
}
