import ApplicationServices
import Foundation
import os
import Testing
import SkylarkCore

// MARK: - Fakes

/// A fake window identity. `AXUIElementCreateApplication` yields real, CFEqual-
/// comparable elements without a window server, so the element-identity path is
/// exercised for real; `windowNumber` covers the window-server-id path.
private func fakeWindow(pid: pid_t = 501, number: CGWindowID?) -> CapturedWindow {
    CapturedWindow(pid: pid, element: AXUIElementCreateApplication(pid), windowNumber: number)
}

/// Distinct element for the same pid (the system-wide element is never equal to
/// an application element), so the CFEqual fallback can be tested with no
/// window-server ids in play.
private func fakeWindowWithoutNumber(pid: pid_t = 501, distinct: Bool = false) -> CapturedWindow {
    CapturedWindow(
        pid: pid,
        element: distinct ? AXUIElementCreateSystemWide() : AXUIElementCreateApplication(pid),
        windowNumber: nil
    )
}

/// Mutable frontmost-app world the guard reads through, plus a scripted
/// activation outcome and the focused window of that app. Lock-guarded so the
/// @Sendable closures can share it.
private final class FakeWorkspace: Sendable {
    private let state: OSAllocatedUnfairLock<(
        frontmost: String?,
        activations: [String],
        succeeds: Bool,
        activationMovesFocus: Bool,
        window: CapturedWindow?,
        windowReads: Int
    )>

    init(
        frontmost: String?,
        activationSucceeds: Bool,
        activationMovesFocus: Bool,
        window: CapturedWindow? = nil
    ) {
        state = OSAllocatedUnfairLock(
            initialState: (frontmost, [], activationSucceeds, activationMovesFocus, window, 0)
        )
    }

    var frontmost: CapturedTargetGuard.FrontmostReader {
        { [state] in state.withLock { $0.frontmost } }
    }

    var activate: CapturedTargetGuard.Activator {
        { [state] bundleID in
            state.withLock {
                $0.activations.append(bundleID)
                guard $0.succeeds else { return false }
                // A successful activation is what actually moves focus; when
                // `activationMovesFocus` is false the request is accepted but the
                // app never comes forward (guard must time out and abort).
                if $0.activationMovesFocus { $0.frontmost = bundleID }
                return true
            }
        }
    }

    /// Stands in for the live AX read: answers only when the asked-for app is
    /// actually frontmost, exactly like `FocusedWindowProbe`.
    var focusedWindow: CapturedTargetGuard.FocusedWindowReader {
        { [state] bundleID in
            state.withLock {
                $0.windowReads += 1
                guard $0.frontmost == bundleID else { return nil }
                return $0.window
            }
        }
    }

    /// The user moved to another window of the same app.
    func switchWindow(to window: CapturedWindow?) {
        state.withLock { $0.window = window }
    }

    func switchApp(to bundleID: String?, window: CapturedWindow? = nil) {
        state.withLock {
            $0.frontmost = bundleID
            $0.window = window
        }
    }

    var activationCount: Int { state.withLock { $0.activations.count } }
    var windowReadCount: Int { state.withLock { $0.windowReads } }
}

private func makeGuard(
    _ workspace: FakeWorkspace,
    own: String? = "com.jjromano.skylark",
    windowAware: Bool = false
) -> CapturedTargetGuard {
    CapturedTargetGuard(
        frontmost: workspace.frontmost,
        activate: workspace.activate,
        focusedWindow: windowAware ? workspace.focusedWindow : nil,
        ownBundleID: own,
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(30)
    )
}

/// Cleaner double that steals focus WHILE it runs — the whole point of the
/// re-validation: a verdict taken before cleanup says nothing about where the
/// text is about to land seconds later.
private struct FocusStealingCleaner: Cleaner {
    let tier: CleanupTier = .local
    let steal: @Sendable () -> Void

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        steal()
        return "CLEANED"
    }
}

private func modes(defaultTier: CleanupTier) -> InMemoryModeProvider {
    InMemoryModeProvider(modes: [
        DictationMode(id: "d", name: "Default", bundleIDPattern: nil, cleanupTier: defaultTier, isDefault: true),
    ])
}

private actor SpyInjector: TextInjecting {
    private(set) var inserted: [String] = []
    private(set) var returns = 0
    /// Fired from inside `insert`, to simulate focus moving between the text
    /// landing and the synthesized Return.
    private let onInsert: (@Sendable () -> Void)?

    init(onInsert: (@Sendable () -> Void)? = nil) {
        self.onInsert = onInsert
    }

    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        onInsert?()
        return InsertionToken(method: .paste, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { false }
    func pressReturn() async { returns += 1 }
    func count() -> Int { inserted.count }
    func returnCount() -> Int { returns }
}

/// Transcriber double with a fixed transcript (the pipeline's "press enter"
/// command needs a specific one). Never real transcript content.
private struct FixedTranscriber: Transcriber {
    let id: TranscriberID = .stub
    let text: String

    func warmUp() async throws {}
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String { text }
}

private final class FakeCapture: AudioCapturing, @unchecked Sendable {
    let clip: AudioClip
    let levels: AsyncStream<Float>

    init(clip: AudioClip) {
        self.clip = clip
        let (stream, cont) = AsyncStream<Float>.makeStream()
        cont.finish()
        levels = stream
    }

    func prepare() {}
    func start() throws {}
    func stop() -> AudioClip { clip }
}

// MARK: - Guard policy

@Suite("Captured-target focus guard")
struct CapturedTargetGuardTests {
    @Test("Captured app still frontmost → proceed without activating anything")
    func sameAppProceeds() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Notes", activationSucceeds: true, activationMovesFocus: true)
        let decision = await makeGuard(workspace).decide(captured: CapturedTarget(bundleID: "com.apple.Notes"))
        #expect(decision == .proceed)
        #expect(workspace.activationCount == 0)
    }

    @Test("Focus moved but the captured app re-activates → proceed")
    func differentAppReactivated() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: true, activationMovesFocus: true)
        let decision = await makeGuard(workspace).decide(captured: CapturedTarget(bundleID: "com.apple.Notes"))
        #expect(decision == .reactivated)
        #expect(workspace.activationCount == 1)
    }

    @Test("Focus moved and activation is refused → abort with the current app")
    func differentAppActivationRefused() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: false, activationMovesFocus: false)
        let decision = await makeGuard(workspace).decide(captured: CapturedTarget(bundleID: "com.apple.Notes"))
        #expect(decision == .abort(current: "com.apple.Safari"))
    }

    /// `activate()` returning true only means the request was accepted; the guard
    /// must verify frontmost-ness and give up on the bounded deadline.
    @Test("Activation accepted but focus never lands → abort after the deadline")
    func activationNeverLandsAborts() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: true, activationMovesFocus: false)
        let decision = await makeGuard(workspace).decide(captured: CapturedTarget(bundleID: "com.apple.Notes"))
        #expect(decision == .abort(current: "com.apple.Safari"))
    }

    @Test("No captured target (headless/unknown) → proceed, no reads acted on")
    func noCaptureProceeds() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: false, activationMovesFocus: false)
        let decision = await makeGuard(workspace).decide(captured: nil)
        #expect(decision == .proceed)
        #expect(workspace.activationCount == 0)
    }

    /// Dictation started while Skylark itself was frontmost (HUD click) has no
    /// meaningful target app — the guard stands down instead of "re-activating"
    /// Skylark and pasting into its own window.
    @Test("Captured app is Skylark itself → guard stands down")
    func ownAppProceeds() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: false, activationMovesFocus: false)
        let decision = await makeGuard(workspace).decide(captured: CapturedTarget(bundleID: "com.jjromano.skylark"))
        #expect(decision == .proceed)
        #expect(workspace.activationCount == 0)
    }
}

// MARK: - Window identity (P0-4 / audit C1)

@Suite("Focus guard window identity")
struct CapturedTargetWindowTests {
    private let notes = "com.apple.TextEdit"

    private func target(_ window: CapturedWindow?) -> CapturedTarget {
        CapturedTarget(bundleID: notes, window: window)
    }

    @Test("Same app, same window → proceed")
    func sameWindowProceeds() async {
        let window = fakeWindow(number: 42)
        let workspace = FakeWorkspace(
            frontmost: notes, activationSucceeds: true, activationMovesFocus: true, window: window
        )
        let decision = await makeGuard(workspace, windowAware: true).decide(captured: target(window))
        #expect(decision == .proceed)
    }

    /// The shipped defect: two documents of the SAME app, dictation (and a
    /// synthesized Return) landing in the wrong one with no guard line at all.
    @Test("Same app, different window (window id) → abort, no re-activation attempted")
    func differentWindowNumberAborts() async {
        let captured = fakeWindow(number: 42)
        let workspace = FakeWorkspace(
            frontmost: notes, activationSucceeds: true, activationMovesFocus: true, window: captured
        )
        workspace.switchWindow(to: fakeWindow(number: 43))
        let decision = await makeGuard(workspace, windowAware: true).decide(captured: target(captured))
        #expect(decision == .abortWrongWindow)
        #expect(workspace.activationCount == 0)
    }

    /// No window-server id available (older OS / SPI gone): element identity
    /// still separates the two windows.
    @Test("Same app, different window (element identity only) → abort")
    func differentWindowElementAborts() async {
        let captured = fakeWindowWithoutNumber()
        let workspace = FakeWorkspace(
            frontmost: notes, activationSucceeds: true, activationMovesFocus: true, window: captured
        )
        workspace.switchWindow(to: fakeWindowWithoutNumber(distinct: true))
        let decision = await makeGuard(workspace, windowAware: true).decide(captured: target(captured))
        #expect(decision == .abortWrongWindow)
    }

    /// A relaunched app is not the window the user dictated into.
    @Test("Same bundle, different pid → abort")
    func differentPidAborts() async {
        let captured = fakeWindow(pid: 100, number: 42)
        let workspace = FakeWorkspace(
            frontmost: notes, activationSucceeds: true, activationMovesFocus: true, window: captured
        )
        workspace.switchWindow(to: fakeWindow(pid: 200, number: 42))
        let decision = await makeGuard(workspace, windowAware: true).decide(captured: target(captured))
        #expect(decision == .abortWrongWindow)
    }

    /// No false positives: an app that exposes no focused window (or won't answer
    /// AX) degrades to the bundle-only verdict rather than blocking a good paste.
    @Test("App exposes no window now → bundle-only verdict (proceed)")
    func unreadableWindowProceeds() async {
        let captured = fakeWindow(number: 42)
        let workspace = FakeWorkspace(
            frontmost: notes, activationSucceeds: true, activationMovesFocus: true, window: captured
        )
        workspace.switchWindow(to: nil)
        let decision = await makeGuard(workspace, windowAware: true).decide(captured: target(captured))
        #expect(decision == .proceed)
    }

    @Test("Nothing captured at record start → no window read, proceed")
    func noCapturedWindowProceeds() async {
        let workspace = FakeWorkspace(
            frontmost: notes, activationSucceeds: true, activationMovesFocus: true, window: fakeWindow(number: 42)
        )
        let decision = await makeGuard(workspace, windowAware: true).decide(captured: target(nil))
        #expect(decision == .proceed)
        #expect(workspace.windowReadCount == 0)
    }

    /// Cross-app behaviour is unchanged by window identity: the captured app is
    /// re-activated and injection proceeds (its key window comes back with it).
    @Test("Different app with a captured window → re-activate, as before")
    func crossAppKeepsReactivateSemantics() async {
        let captured = fakeWindow(number: 42)
        let workspace = FakeWorkspace(
            frontmost: "com.apple.Safari", activationSucceeds: true, activationMovesFocus: true, window: nil
        )
        let decision = await makeGuard(workspace, windowAware: true).decide(captured: target(captured))
        #expect(decision == .reactivated)
        #expect(workspace.activationCount == 1)
    }

    @Test("captureTarget snapshots the focused window; own app and nil capture read nothing")
    func captureTargetSnapshots() async {
        let window = fakeWindow(number: 42)
        let workspace = FakeWorkspace(
            frontmost: notes, activationSucceeds: true, activationMovesFocus: true, window: window
        )
        let guardWithWindows = makeGuard(workspace, windowAware: true)
        #expect(await guardWithWindows.captureTarget(bundleID: notes).window == window)
        #expect(await guardWithWindows.captureTarget(bundleID: "com.jjromano.skylark").window == nil)
        #expect(await guardWithWindows.captureTarget(bundleID: nil).bundleID == nil)
        // No reader wired (or no AX): bundle-only capture, exactly as before.
        #expect(await makeGuard(workspace).captureTarget(bundleID: notes).window == nil)
    }
}

// MARK: - Orchestrator wiring

@Suite("Focus guard at the injection boundary")
struct FocusGuardInjectionTests {
    private func makeClip() -> AudioClip {
        AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)
    }

    private func makeOrchestrator(
        injector: SpyInjector,
        captured: String,
        workspace: FakeWorkspace,
        windowAware: Bool = false,
        transcriber: (any Transcriber)? = nil,
        cleaner: (any Cleaner)? = nil,
        history: (@Sendable (HistoryRecord, AudioClip) -> Void)? = nil
    ) -> DictationOrchestrator {
        DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: transcriber ?? StubTranscriber(),
            injector: injector,
            cleaners: cleaner.map { CleanerRegistry(local: $0) } ?? CleanerRegistry(),
            modeProvider: modes(defaultTier: cleaner == nil ? .raw : .local),
            frontmostBundleID: { captured },
            focusGuard: makeGuard(workspace, windowAware: windowAware),
            historyRecord: history
        )
    }

    @Test("Same app: the transcript is injected as usual")
    func sameAppInjects() async {
        let spy = SpyInjector()
        let workspace = FakeWorkspace(frontmost: "com.apple.Notes", activationSucceeds: true, activationMovesFocus: true)
        let orchestrator = makeOrchestrator(injector: spy, captured: "com.apple.Notes", workspace: workspace)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
        #expect(workspace.activationCount == 0)
    }

    @Test("Focus moved, app re-activated: still injected")
    func reactivatedInjects() async {
        let spy = SpyInjector()
        let workspace = FakeWorkspace(frontmost: "com.apple.Notes", activationSucceeds: true, activationMovesFocus: true)
        let orchestrator = makeOrchestrator(injector: spy, captured: "com.apple.Notes", workspace: workspace)

        await orchestrator.handle(.startRecording)
        // The user Cmd-Tabs away mid-dictation.
        _ = await workspace.activate("com.apple.Safari")
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
    }

    /// The load-bearing case: nothing is typed into the wrong app, the user is
    /// told, and the transcript still reaches history (nothing is lost) —
    /// mirroring how the replace-failure path reports a degrade.
    @Test("Focus moved and unrecoverable: nothing injected, note surfaced, history kept")
    func abortNotesAndKeepsHistory() async {
        let spy = SpyInjector()
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: false, activationMovesFocus: false)
        let recorded = OSAllocatedUnfairLock(initialState: [String]())
        let orchestrator = makeOrchestrator(
            injector: spy,
            captured: "com.apple.Notes",
            workspace: workspace,
            history: { record, _ in recorded.withLock { $0.append(record.rawText) } }
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        await #expect(spy.count() == 0)
        await #expect(orchestrator.phase == .idle)
        #expect(recorded.withLock { $0.count } == 1)
        let note = await firstNote(orchestrator)
        #expect(note?.contains("Focus moved") == true)
    }

    /// Let the record-start window read (detached, one AX round trip) land before
    /// the test moves focus. In production it completes within a millisecond of
    /// fn-down, long before a human can switch windows.
    private func settleCapture() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    /// The load-bearing same-app case (P0-4): the user moved to a second window
    /// of the SAME app mid-dictation. Nothing may be typed into it.
    @Test("Same app, different window at paste time: nothing injected, note surfaced, history kept")
    func wrongWindowAborts() async {
        let spy = SpyInjector()
        let captured = fakeWindow(number: 42)
        let workspace = FakeWorkspace(
            frontmost: "com.apple.TextEdit", activationSucceeds: true, activationMovesFocus: true, window: captured
        )
        let recorded = OSAllocatedUnfairLock(initialState: [String]())
        let orchestrator = makeOrchestrator(
            injector: spy,
            captured: "com.apple.TextEdit",
            workspace: workspace,
            windowAware: true,
            history: { record, _ in recorded.withLock { $0.append(record.rawText) } }
        )

        await orchestrator.handle(.startRecording)
        await settleCapture()
        // The user clicks the app's OTHER document window mid-dictation.
        workspace.switchWindow(to: fakeWindow(number: 43))
        await orchestrator.handle(.stopRecording)

        await #expect(spy.count() == 0)
        await #expect(orchestrator.phase == .idle)
        #expect(recorded.withLock { $0.count } == 1)
        let note = await firstNote(orchestrator)
        #expect(note?.contains("another window") == true)
    }

    @Test("Same app, same window: injected as usual")
    func sameWindowInjects() async {
        let spy = SpyInjector()
        let captured = fakeWindow(number: 42)
        let workspace = FakeWorkspace(
            frontmost: "com.apple.TextEdit", activationSucceeds: true, activationMovesFocus: true, window: captured
        )
        let orchestrator = makeOrchestrator(
            injector: spy, captured: "com.apple.TextEdit", workspace: workspace, windowAware: true
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
    }

    /// Staleness (audit C1, half 2): the guard passed BEFORE cleanup, focus moved
    /// WHILE cleanup ran (seconds, on a cold local model). The write must be
    /// re-validated, not gated on the pre-cleanup verdict.
    @Test("Focus stolen during cleanup: the re-check refuses the write")
    func focusStolenDuringCleanupAborts() async {
        let spy = SpyInjector()
        let workspace = FakeWorkspace(
            frontmost: "com.apple.Notes", activationSucceeds: false, activationMovesFocus: false
        )
        let cleaner = FocusStealingCleaner { workspace.switchApp(to: "com.apple.Safari") }
        let orchestrator = makeOrchestrator(
            injector: spy, captured: "com.apple.Notes", workspace: workspace, cleaner: cleaner
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        await #expect(spy.count() == 0)
        let note = await firstNote(orchestrator)
        #expect(note?.contains("Focus moved") == true)
    }

    /// Same, but within one app: cleanup runs, the user switches document window,
    /// and the cleaned text must not land in the new one.
    @Test("Window changed during cleanup: the re-check refuses the write")
    func windowChangedDuringCleanupAborts() async {
        let spy = SpyInjector()
        let captured = fakeWindow(number: 42)
        let workspace = FakeWorkspace(
            frontmost: "com.apple.TextEdit", activationSucceeds: true, activationMovesFocus: true, window: captured
        )
        let cleaner = FocusStealingCleaner { workspace.switchWindow(to: fakeWindow(number: 43)) }
        let orchestrator = makeOrchestrator(
            injector: spy,
            captured: "com.apple.TextEdit",
            workspace: workspace,
            windowAware: true,
            cleaner: cleaner
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        await #expect(spy.count() == 0)
    }

    /// The Return is synthesized after the text lands, so it needs its OWN check:
    /// a stray Return in the wrong window sends a message.
    @Test("Focus moves between the text landing and the Return: no Return")
    func returnRevalidatesAfterInsert() async {
        let workspace = FakeWorkspace(
            frontmost: "com.apple.TextEdit", activationSucceeds: true, activationMovesFocus: true,
            window: fakeWindow(number: 42)
        )
        // Focus jumps to the app's other window the instant the text lands.
        let spy = SpyInjector { workspace.switchWindow(to: fakeWindow(number: 43)) }
        let orchestrator = makeOrchestrator(
            injector: spy,
            captured: "com.apple.TextEdit",
            workspace: workspace,
            windowAware: true,
            transcriber: FixedTranscriber(text: "Ship it press enter")
        )
        await orchestrator.setPressEnterEnabled(true)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        await #expect(spy.count() == 1)      // the text landed in the right window
        await #expect(spy.returnCount() == 0) // the Return did not follow it out
    }

    @Test("Press enter with focus intact: text lands and the Return follows")
    func returnFiresWhenFocusHeld() async {
        let spy = SpyInjector()
        let workspace = FakeWorkspace(
            frontmost: "com.apple.TextEdit", activationSucceeds: true, activationMovesFocus: true,
            window: fakeWindow(number: 42)
        )
        let orchestrator = makeOrchestrator(
            injector: spy,
            captured: "com.apple.TextEdit",
            workspace: workspace,
            windowAware: true,
            transcriber: FixedTranscriber(text: "Ship it press enter")
        )
        await orchestrator.setPressEnterEnabled(true)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        await #expect(spy.count() == 1)
        await #expect(spy.returnCount() == 1)
    }

    /// Await the first status note, or nil after `timeout` (notes buffer
    /// newest-4, so a note yielded during the dictation is already waiting).
    private func firstNote(_ orchestrator: DictationOrchestrator, timeout: Duration = .milliseconds(300)) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await note in orchestrator.statusNotes { return note }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
