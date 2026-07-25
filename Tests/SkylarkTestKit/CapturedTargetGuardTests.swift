import ApplicationServices
import Foundation
import os
import Testing
import SkylarkCore

// MARK: - Fakes

/// Mutable frontmost-app world the guard reads through, plus a scripted
/// activation outcome. Lock-guarded so the @Sendable closures can share it.
private final class FakeWorkspace: Sendable {
    private let state: OSAllocatedUnfairLock<(frontmost: String?, activations: [String], succeeds: Bool, activationMovesFocus: Bool)>

    init(frontmost: String?, activationSucceeds: Bool, activationMovesFocus: Bool) {
        state = OSAllocatedUnfairLock(
            initialState: (frontmost, [], activationSucceeds, activationMovesFocus)
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

    var activationCount: Int { state.withLock { $0.activations.count } }
}

private func makeGuard(_ workspace: FakeWorkspace, own: String? = "com.jjromano.skylark") -> CapturedTargetGuard {
    CapturedTargetGuard(
        frontmost: workspace.frontmost,
        activate: workspace.activate,
        ownBundleID: own,
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(30)
    )
}

private actor SpyInjector: TextInjecting {
    private(set) var inserted: [String] = []

    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        return InsertionToken(method: .paste, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { false }
    func count() -> Int { inserted.count }
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
        let decision = await makeGuard(workspace).decide(captured: "com.apple.Notes")
        #expect(decision == .proceed)
        #expect(workspace.activationCount == 0)
    }

    @Test("Focus moved but the captured app re-activates → proceed")
    func differentAppReactivated() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: true, activationMovesFocus: true)
        let decision = await makeGuard(workspace).decide(captured: "com.apple.Notes")
        #expect(decision == .reactivated)
        #expect(workspace.activationCount == 1)
    }

    @Test("Focus moved and activation is refused → abort with the current app")
    func differentAppActivationRefused() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: false, activationMovesFocus: false)
        let decision = await makeGuard(workspace).decide(captured: "com.apple.Notes")
        #expect(decision == .abort(current: "com.apple.Safari"))
    }

    /// `activate()` returning true only means the request was accepted; the guard
    /// must verify frontmost-ness and give up on the bounded deadline.
    @Test("Activation accepted but focus never lands → abort after the deadline")
    func activationNeverLandsAborts() async {
        let workspace = FakeWorkspace(frontmost: "com.apple.Safari", activationSucceeds: true, activationMovesFocus: false)
        let decision = await makeGuard(workspace).decide(captured: "com.apple.Notes")
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
        let decision = await makeGuard(workspace).decide(captured: "com.jjromano.skylark")
        #expect(decision == .proceed)
        #expect(workspace.activationCount == 0)
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
        history: (@Sendable (HistoryRecord, AudioClip) -> Void)? = nil
    ) -> DictationOrchestrator {
        DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: injector,
            frontmostBundleID: { captured },
            focusGuard: makeGuard(workspace),
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
