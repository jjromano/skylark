import Testing
import SkylarkCore

// MARK: - Test doubles

/// Capture double that returns a preset clip and can push interruption events
/// (the real service raises them from its `AVAudioEngineConfigurationChange`
/// observer).
private final class InterruptibleCapture: AudioCapturing, @unchecked Sendable {
    let clip: AudioClip
    let levels: AsyncStream<Float>
    let interruptions: AsyncStream<CaptureInterruption>
    private let interruptionCont: AsyncStream<CaptureInterruption>.Continuation

    init(clip: AudioClip) {
        self.clip = clip
        let (levelStream, levelCont) = AsyncStream<Float>.makeStream()
        levelCont.finish()
        levels = levelStream
        let (stream, cont) = AsyncStream<CaptureInterruption>.makeStream(bufferingPolicy: .bufferingNewest(4))
        interruptions = stream
        interruptionCont = cont
    }

    func prepare() {}
    func start() throws {}
    func stop() -> AudioClip { clip }

    func report(_ interruption: CaptureInterruption) {
        interruptionCont.yield(interruption)
    }
}

/// Records the clip handed to STT, so a test can prove the trim happened BEFORE
/// transcription (and that a clean clip reaches it untouched).
private actor ClipCapturingTranscriber: Transcriber {
    nonisolated let id: TranscriberID = .stub
    private(set) var lastClip: AudioClip?
    private(set) var callCount = 0

    func warmUp() async throws {}

    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        lastClip = clip
        callCount += 1
        return StubTranscriber.output
    }

    func received() -> AudioClip? { lastClip }
    func timesCalled() -> Int { callCount }
}

private actor RecordingInjector: TextInjecting {
    private(set) var inserted: [String] = []

    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        return InsertionToken(method: .paste, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { false }

    func count() -> Int { inserted.count }
}

// MARK: - Tests

/// WS1: every interruption signal — a stalled hotkey tap, an engine
/// configuration change, wall-clock/sample divergence, and a dead trailing tail
/// — converges on ONE finalize decision in the orchestrator.
@Suite("DictationOrchestrator interruption finalize (WS1)")
struct CaptureInterruptionTests {
    private let sampleRate: Double = 16_000
    private let framesPerValue = 1_600  // 0.1 s callbacks

    private func samples(_ seconds: Double) -> Int {
        Int((seconds * sampleRate).rounded())
    }

    /// A clip whose samples AND rms trace describe `speech` seconds of speech
    /// followed by `dead` seconds of sub-floor air (the mic-stolen signature).
    private func clip(
        speech: Double,
        dead: Double,
        // `Double`, not `TimeInterval`: this target can't import Foundation
        // alongside Testing (see Package.swift's cross-import note).
        wallDuration: Double? = nil,
        interruption: CaptureInterruption? = nil
    ) -> AudioClip {
        // Alternating ±0.05 — a DC-constant level has zero peak-to-peak and
        // `SilenceDetector` (rightly) reads that as silence.
        let speechSamples = (0..<samples(speech)).map { $0.isMultiple(of: 2) ? Float(0.05) : Float(-0.05) }
        let deadSamples = [Float](repeating: 0, count: samples(dead))
        let all = speechSamples + deadSamples
        let values = [Float](repeating: 0.05, count: Int((speech / 0.1).rounded()))
            + [Float](repeating: 0, count: Int((dead / 0.1).rounded()))
        return AudioClip(
            samples: all,
            sampleRate: sampleRate,
            duration: Double(all.count) / sampleRate,
            wallDuration: wallDuration ?? Double(all.count) / sampleRate,
            rms: RMSTrace(values: values, framesPerValue: framesPerValue, sampleRate: sampleRate),
            interruption: interruption
        )
    }

    /// Await the first status note, or nil after `timeout`.
    private func firstNote(
        _ orchestrator: DictationOrchestrator, timeout: Duration = .milliseconds(300)
    ) async -> String? {
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

    private func settle() async {
        for _ in 0..<60 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private let interruptedNote = "Mic interrupted — text may be incomplete"

    // MARK: - Dead-tail trim

    @Test("Speech-then-silence push-to-talk clip is trimmed before STT")
    func deadTailTrimmedBeforeTranscription() async {
        let transcriber = ClipCapturingTranscriber()
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 3.0, dead: 8.0)),
            transcriber: transcriber,
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        let seen = await transcriber.received()
        #expect(seen != nil)
        // 3 s of speech + the 0.25 s keep-padding; the 8 s tail is gone.
        #expect(seen?.samples.count == samples(3.25))
    }

    @Test("Speech-then-silence surfaces the incomplete-text note")
    func deadTailSurfacesNote() async {
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 3.0, dead: 8.0)),
            transcriber: ClipCapturingTranscriber(),
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await firstNote(orchestrator) == interruptedNote)
    }

    @Test("Hands-free clips get the same trim + note (not just push-to-talk)")
    func handsFreeAlsoTrimmed() async {
        let transcriber = ClipCapturingTranscriber()
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 2.0, dead: 6.0)),
            transcriber: transcriber,
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.engageHandsFree)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received()?.samples.count == samples(2.25))
        #expect(await firstNote(orchestrator) == interruptedNote)
    }

    @Test("Text still lands after an interruption (a note is added, nothing is dropped)")
    func interruptedClipStillInserts() async {
        let injector = RecordingInjector()
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 3.0, dead: 8.0)),
            transcriber: ClipCapturingTranscriber(),
            injector: injector
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await injector.count() == 1)
        await #expect(orchestrator.phase == .idle)
    }

    // MARK: - Clean path

    @Test("Clean clip: reaches STT byte-identical, with no note")
    func cleanClipUntouched() async {
        let transcriber = ClipCapturingTranscriber()
        let original = clip(speech: 3.0, dead: 0)
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: original),
            transcriber: transcriber,
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received() == original)
        #expect(await firstNote(orchestrator, timeout: .milliseconds(120)) == nil)
    }

    @Test("A short release tail is left alone (no trim, no note)")
    func shortTailUntouched() async {
        let transcriber = ClipCapturingTranscriber()
        let original = clip(speech: 2.0, dead: 0.4)
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: original),
            transcriber: transcriber,
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received()?.samples.count == original.samples.count)
        #expect(await firstNote(orchestrator, timeout: .milliseconds(120)) == nil)
    }

    // MARK: - Duration integrity (stalled tap: no silent tail to find)

    @Test("Stalled tap (wall-clock ≫ samples) is treated as an interruption")
    func stalledTapNoted() async {
        let injector = RecordingInjector()
        // 1 s of samples for a 9 s hold: the tap stopped delivering, and there is
        // no zeros tail for the analyzer to see.
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 1.0, dead: 0, wallDuration: 9.0)),
            transcriber: ClipCapturingTranscriber(),
            injector: injector
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        // Finalized with what we have — the transcript still lands.
        #expect(await injector.count() == 1)
        #expect(await firstNote(orchestrator) == interruptedNote)
    }

    @Test("Sample duration tracking wall time is not an interruption")
    func healthyDurationNoNote() async {
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 2.0, dead: 0, wallDuration: 2.1)),
            transcriber: ClipCapturingTranscriber(),
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await firstNote(orchestrator, timeout: .milliseconds(120)) == nil)
    }

    // MARK: - Hotkey tap stall

    @Test("captureInterrupted records the marker but keeps recording (no premature clip)")
    func hotkeyStallKeepsRecording() async {
        let injector = RecordingInjector()
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 2.0, dead: 0)),
            transcriber: ClipCapturingTranscriber(),
            injector: injector
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.captureInterrupted)
        // A bare tap-timeout also fires on a benign main-loop stall while the user
        // is still holding, so it must NOT finalize (that would clip them). It
        // keeps recording; the Fn-up finalize trims any tail a real steal left.
        await #expect(orchestrator.phase == .recording)
        #expect(await injector.count() == 0)
    }

    @Test("The release after an interruption finalizes exactly once, with the note")
    func releaseAfterInterruptionFinalizesOnce() async {
        let injector = RecordingInjector()
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 2.0, dead: 0)),
            transcriber: ClipCapturingTranscriber(),
            injector: injector
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.captureInterrupted)   // marker; keeps recording
        await orchestrator.handle(.stopRecording)         // the real key-up finalizes
        #expect(await injector.count() == 1)              // inserted exactly once
        #expect(await firstNote(orchestrator) == interruptedNote)  // still flagged
    }

    @Test("captureInterrupted while idle does nothing")
    func interruptionWhileIdleIgnored() async {
        let injector = RecordingInjector()
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: clip(speech: 2.0, dead: 0)),
            transcriber: ClipCapturingTranscriber(),
            injector: injector
        )
        await orchestrator.handle(.captureInterrupted)
        await #expect(orchestrator.phase == .idle)
        #expect(await injector.count() == 0)
    }

    // MARK: - Engine configuration change

    @Test("A failed engine restart finalizes the utterance")
    func restartFailedFinalizes() async {
        let capture = InterruptibleCapture(clip: clip(speech: 2.0, dead: 0))
        let injector = RecordingInjector()
        let orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: ClipCapturingTranscriber(),
            injector: injector
        )
        await orchestrator.handle(.startRecording)
        capture.report(CaptureInterruption(reason: .restartFailed, at: 2.0))
        await settle()
        await #expect(orchestrator.phase == .idle)
        #expect(await injector.count() == 1)
    }

    @Test("A recovered configuration change keeps recording (marker only)")
    func configurationChangeKeepsRecording() async {
        let capture = InterruptibleCapture(clip: clip(speech: 2.0, dead: 0))
        let injector = RecordingInjector()
        let orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: ClipCapturingTranscriber(),
            injector: injector
        )
        await orchestrator.handle(.startRecording)
        capture.report(CaptureInterruption(reason: .configurationChange, at: 1.0))
        await settle()
        // The restart preserved the recording — the session must NOT be cut short.
        await #expect(orchestrator.phase == .recording)
        #expect(await injector.count() == 0)
        await orchestrator.handle(.stopRecording)
        #expect(await injector.count() == 1)
    }

    @Test("A clip stamped with a configuration change surfaces the note")
    func clipMarkerSurfacesNote() async {
        let marked = clip(
            speech: 2.0, dead: 0,
            interruption: CaptureInterruption(reason: .configurationChange, at: 1.0)
        )
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: marked),
            transcriber: ClipCapturingTranscriber(),
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await firstNote(orchestrator) == interruptedNote)
    }

    // MARK: - Interaction with the silence guard

    @Test("An interrupted all-dead clip reports the interruption, not 'No speech detected'")
    func interruptedSilentClipPrefersInterruptionNote() async {
        let transcriber = ClipCapturingTranscriber()
        let dead = AudioClip(
            samples: [Float](repeating: 0, count: samples(6.0)),
            sampleRate: sampleRate,
            duration: 6.0,
            wallDuration: 6.0,
            rms: RMSTrace(
                values: [Float](repeating: 0, count: 60),
                framesPerValue: framesPerValue,
                sampleRate: sampleRate
            ),
            interruption: CaptureInterruption(reason: .restartFailed, at: 0.2)
        )
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: dead),
            transcriber: transcriber,
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        // Still short-circuited before STT (nothing to hear), but the note tells
        // the user WHY rather than blaming their microphone technique.
        #expect(await transcriber.timesCalled() == 0)
        #expect(await firstNote(orchestrator) == interruptedNote)
    }

    @Test("An uninterrupted silent clip still says 'No speech detected'")
    func plainSilentClipKeepsItsNote() async {
        let dead = AudioClip(
            samples: [Float](repeating: 0, count: samples(1.0)),
            sampleRate: sampleRate,
            duration: 1.0,
            wallDuration: 1.0
        )
        let orchestrator = DictationOrchestrator(
            capture: InterruptibleCapture(clip: dead),
            transcriber: ClipCapturingTranscriber(),
            injector: RecordingInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await firstNote(orchestrator) == "No speech detected")
    }
}
