import Testing
import Synchronization
import SkylarkCore

// MARK: - Test doubles

/// Capture double that returns a preset clip, can push interruption events, and
/// can stream raw frames to the hands-free VAD path. Also reports a canned cap
/// countdown so the HUD warning plumbing can be asserted.
private final class CappedCapture: AudioCapturing, @unchecked Sendable {
    /// Mirrors `AudioCaptureService`: a fresh frame stream per access (a stored
    /// one dies the first time its consuming task is cancelled), plus a small
    /// pending buffer so a test can emit before the consumer has armed.
    private struct FrameDelivery {
        var sink: AsyncStream<[Float]>.Continuation?
        var pending: [[Float]] = []
        /// Bumped on every `frames` access, so a test can wait for the NEXT
        /// consumer to arm before emitting (frames sent in between would go to
        /// the retired session's sink).
        var generation = 0
    }

    let clip: AudioClip
    let levels: AsyncStream<Float>
    let interruptions: AsyncStream<CaptureInterruption>
    private let interruptionCont: AsyncStream<CaptureInterruption>.Continuation
    private let delivery = Mutex(FrameDelivery())
    private let countdown: Double?

    /// Set when `start()` should throw (a wedged input device).
    var startError: (any Error)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var framesWanted: [Bool] = []

    init(clip: AudioClip, countdown: Double? = nil) {
        self.clip = clip
        self.countdown = countdown
        let (levelStream, levelCont) = AsyncStream<Float>.makeStream()
        levelCont.finish()
        levels = levelStream
        let (stream, cont) = AsyncStream<CaptureInterruption>.makeStream(bufferingPolicy: .bufferingNewest(4))
        interruptions = stream
        interruptionCont = cont
    }

    /// Unbounded on purpose: a dropped frame would make the "endpoints one
    /// second after speech stops" assertion below meaningless.
    var frames: AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        delivery.withLock { state in
            state.sink?.finish()
            state.sink = continuation
            state.generation += 1
            for frame in state.pending { continuation.yield(frame) }
            state.pending = []
        }
        return stream
    }

    func prepare() {}

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop() -> AudioClip {
        stopCount += 1
        return clip
    }

    func setFramesWanted(_ wanted: Bool) { framesWanted.append(wanted) }

    func capCountdown() -> Double? { countdown }

    func frameGeneration() -> Int { delivery.withLock { $0.generation } }

    func report(_ interruption: CaptureInterruption) { interruptionCont.yield(interruption) }

    func emit(_ frame: [Float]) {
        delivery.withLock { state in
            if let sink = state.sink { sink.yield(frame) } else { state.pending.append(frame) }
        }
    }
}

/// Endpointer double implementing the documented hands-free rule in the
/// simplest possible way: end the utterance after one second of quiet frames.
/// Counts what it was actually fed, which is how the tests below prove the VAD
/// is not being STARVED (the P1-2a mechanism).
private actor CountingEndpointer: SpeechEndpointer {
    private let sampleRate: Double = 16_000
    private var silentSeconds: Double = 0
    private var heardSpeech = false
    private(set) var framesFed = 0
    private(set) var sessions = 0

    func prepare() async {}
    func available() -> Bool { true }

    func beginSession() async {
        sessions += 1
        silentSeconds = 0
        heardSpeech = false
    }

    func feed(_ frames: [Float]) async -> Bool {
        framesFed += 1
        let seconds = Double(frames.count) / sampleRate
        if frames.contains(where: { abs($0) > 0.01 }) {
            heardSpeech = true
            silentSeconds = 0
        } else if heardSpeech {
            silentSeconds += seconds
        }
        // Epsilon: ten 0.1 s frames sum to 0.999… in binary floating point.
        return silentSeconds >= FluidAudioVAD.minSilenceDuration - 1e-6
    }

    func fed() -> Int { framesFed }
    func sessionCount() -> Int { sessions }
}

private actor CountingTranscriber: Transcriber {
    nonisolated let id: TranscriberID = .stub
    private(set) var clips: [AudioClip] = []

    func warmUp() async throws {}

    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        clips.append(clip)
        return StubTranscriber.output
    }

    func timesCalled() -> Int { clips.count }
}

private actor CountingInjector: TextInjecting {
    private(set) var inserted: [String] = []

    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        return InsertionToken(method: .paste, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { false }

    func count() -> Int { inserted.count }
}

private actor NoteLog {
    private var notes: [String] = []
    func add(_ note: String) { notes.append(note) }
    func all() -> [String] { notes }
}

private actor StateLog {
    private var states: [HUDState] = []
    func add(_ state: HUDState) { states.append(state) }
    func all() -> [HUDState] { states }
}

// MARK: - Tests

/// P1-2 / P1-8: the 120 s recording cap is a designed limit that ENDS the
/// session honestly, a capped clip is never mistaken for a stalled tap, the
/// hands-free VAD is never starved, and a failed capture start says so.
@Suite("Recording cap + capture start failure")
struct CaptureCapTests {
    private let sampleRate: Double = 16_000

    private func samples(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    /// `speech` seconds of alternating ±0.05, optionally stamped as capped and
    /// with a wall duration far past the sample duration (the cap signature).
    private func clip(
        speech: Double,
        wallDuration: Double? = nil,
        capReached: Bool = false
    ) -> AudioClip {
        let voice = (0..<samples(speech)).map { $0.isMultiple(of: 2) ? Float(0.05) : Float(-0.05) }
        return AudioClip(
            samples: voice,
            sampleRate: sampleRate,
            duration: Double(voice.count) / sampleRate,
            wallDuration: wallDuration ?? Double(voice.count) / sampleRate,
            capReached: capReached
        )
    }

    private func settle() async {
        for _ in 0..<80 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Wait until the orchestrator's VAD task has taken a fresh frame stream.
    private func armFrames(_ capture: CappedCapture, after generation: Int) async {
        for _ in 0..<200 {
            if capture.frameGeneration() != generation { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func collectNotes(_ orchestrator: DictationOrchestrator) -> NoteLog {
        let log = NoteLog()
        Task { [log] in
            for await note in orchestrator.statusNotes { await log.add(note) }
        }
        return log
    }

    private let capNote = "Reached the 2-minute recording limit — transcribed what fit"
    private let interruptedNote = "Mic interrupted — text may be incomplete"
    private let captureFailedNote = "Microphone capture failed — check your input device"

    // MARK: - The clip itself (P1-2c)

    @Test("A capped clip is never reported as a stalled tap")
    func cappedClipIsNotStalled() {
        // 120 s of samples for a 253 s hold: true by construction once the buffer
        // pins, and exactly what made a designed limit look like a dying mic.
        let capped = clip(speech: 120, wallDuration: 253, capReached: true)
        #expect(!capped.tapStalled)
        // The same divergence WITHOUT the cap is still a stalled tap.
        #expect(clip(speech: 120, wallDuration: 253).tapStalled)
    }

    @Test("The cap flag survives a trim of the clip")
    func capFlagSurvivesTrim() {
        let capped = clip(speech: 10, wallDuration: 40, capReached: true)
        #expect(capped.trimmed(toSampleCount: samples(4)).capReached)
        #expect(capped.trimmed(toSampleRange: samples(1)..<samples(5)).capReached)
        #expect(!capped.trimmed(toSampleCount: samples(4)).tapStalled)
    }

    @Test("capReached finalizes the utterance, like a failed restart")
    func capReachedFinalizes() {
        #expect(CaptureInterruption.Reason.capReached.finalizesUtterance)
    }

    // MARK: - Finalize at the cap (P1-2b)

    @Test("Hitting the cap ends the session and transcribes what fit")
    func capEndsTheSession() async {
        let capture = CappedCapture(clip: clip(speech: 120, wallDuration: 121, capReached: true))
        let transcriber = CountingTranscriber()
        let injector = CountingInjector()
        let orchestrator = DictationOrchestrator(
            capture: capture, transcriber: transcriber, injector: injector
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.engageHandsFree)
        // What capture raises the moment the preallocated buffer fills.
        capture.report(CaptureInterruption(reason: .capReached, at: 120))
        await settle()
        // Ends exactly as if the user had released the trigger — mic released,
        // text still produced. The v0.12.3 failure was sitting here recording
        // audio that was being dropped on the floor.
        await #expect(orchestrator.phase == .idle)
        #expect(capture.stopCount == 1)
        #expect(await transcriber.timesCalled() == 1)
        #expect(await injector.count() == 1)
    }

    @Test("The cap's notice names the limit, not the microphone")
    func capNoticeIsItsOwn() async {
        let capture = CappedCapture(clip: clip(speech: 120, wallDuration: 253, capReached: true))
        let orchestrator = DictationOrchestrator(
            capture: capture, transcriber: CountingTranscriber(), injector: CountingInjector()
        )
        let notes = collectNotes(orchestrator)
        await orchestrator.handle(.startRecording)
        capture.report(CaptureInterruption(reason: .capReached, at: 120))
        await settle()
        #expect(await notes.all().last == capNote)
        #expect(!(await notes.all().contains(interruptedNote)))
    }

    @Test("A clip stamped at the cap gets the cap notice even without the event")
    func cappedClipNoticeOnPlainStop() async {
        // Deep-link stop / trigger release arriving after the buffer filled.
        let orchestrator = DictationOrchestrator(
            capture: CappedCapture(clip: clip(speech: 120, wallDuration: 253, capReached: true)),
            transcriber: CountingTranscriber(),
            injector: CountingInjector()
        )
        let notes = collectNotes(orchestrator)
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()
        #expect(await notes.all().last == capNote)
    }

    @Test("A genuinely stalled tap still says the microphone was interrupted")
    func stalledTapKeepsItsOwnNotice() async {
        let orchestrator = DictationOrchestrator(
            capture: CappedCapture(clip: clip(speech: 1, wallDuration: 9)),
            transcriber: CountingTranscriber(),
            injector: CountingInjector()
        )
        let notes = collectNotes(orchestrator)
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()
        #expect(await notes.all().last == interruptedNote)
    }

    // MARK: - HUD cap warning (decision 4)

    @Test("The listening pill carries the cap countdown while recording")
    func listeningStateCarriesCountdown() async {
        let capture = CappedCapture(clip: clip(speech: 2), countdown: 12)
        let orchestrator = DictationOrchestrator(
            capture: capture, transcriber: CountingTranscriber(), injector: CountingInjector()
        )
        let states = StateLog()
        Task { [states] in
            for await state in orchestrator.hudStates { await states.add(state) }
        }
        await orchestrator.handle(.startRecording)
        await settle()
        var countdowns: [Double?] = []
        for state in await states.all() {
            if case let .listening(_, _, remaining) = state { countdowns.append(remaining) }
        }
        #expect(!countdowns.isEmpty)
        #expect(countdowns.allSatisfy { $0 == 12 })
    }

    @Test("No countdown until capture says so")
    func noCountdownWithHeadroom() async {
        let orchestrator = DictationOrchestrator(
            capture: CappedCapture(clip: clip(speech: 2)),
            transcriber: CountingTranscriber(),
            injector: CountingInjector()
        )
        let states = StateLog()
        Task { [states] in
            for await state in orchestrator.hudStates { await states.add(state) }
        }
        await orchestrator.handle(.startRecording)
        await settle()
        for state in await states.all() {
            if case let .listening(_, _, remaining) = state { #expect(remaining == nil) }
        }
    }

    // MARK: - Hands-free endpointing (P1-2a / audit U6)

    @Test("Hands-free ends one second after speech stops")
    func handsFreeEndpointsAfterSilence() async {
        let capture = CappedCapture(clip: clip(speech: 3))
        let endpointer = CountingEndpointer()
        let injector = CountingInjector()
        let orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: CountingTranscriber(),
            injector: injector,
            endpointer: endpointer
        )
        await orchestrator.handle(.startRecording)
        let generation = capture.frameGeneration()
        await orchestrator.handle(.engageHandsFree)
        await armFrames(capture, after: generation)
        // 2 s of speech, then quiet. 0.1 s frames, exactly what the tap delivers.
        let speech = (0..<1_600).map { $0.isMultiple(of: 2) ? Float(0.05) : Float(-0.05) }
        let quiet = [Float](repeating: 0, count: 1_600)
        for _ in 0..<20 { capture.emit(speech) }
        for _ in 0..<30 { capture.emit(quiet) }
        await settle()
        await #expect(orchestrator.phase == .idle)
        #expect(await injector.count() == 1)
        // 20 speech frames + exactly 10 quiet ones = the documented ≈1 s. Proves
        // the endpointer is fed continuously and stops being fed the moment it
        // ends the session (the starvation bug fed it nothing at all).
        let fed = await endpointer.fed()
        #expect(fed == 30)
        // Frame delivery is enabled for the session and disabled at finalize.
        #expect(capture.framesWanted == [true, false])
    }

    @Test("A second hands-free session endpoints too (no starved iterator)")
    func handsFreeWorksTwice() async {
        let capture = CappedCapture(clip: clip(speech: 3))
        let endpointer = CountingEndpointer()
        let injector = CountingInjector()
        let orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: CountingTranscriber(),
            injector: injector,
            endpointer: endpointer
        )
        let speech = (0..<1_600).map { $0.isMultiple(of: 2) ? Float(0.05) : Float(-0.05) }
        let quiet = [Float](repeating: 0, count: 1_600)
        for _ in 0..<2 {
            await orchestrator.handle(.startRecording)
            let generation = capture.frameGeneration()
            await orchestrator.handle(.engageHandsFree)
            await armFrames(capture, after: generation)
            for _ in 0..<10 { capture.emit(speech) }
            for _ in 0..<15 { capture.emit(quiet) }
            await settle()
            await #expect(orchestrator.phase == .idle)
        }
        #expect(await injector.count() == 2)
        #expect(await endpointer.sessionCount() == 2)
    }

    // MARK: - Failed capture start (P1-8)

    @Test("A failed capture start surfaces a note and stays idle")
    func failedStartIsReported() async {
        struct DeviceWedged: Error {}
        let capture = CappedCapture(clip: clip(speech: 2))
        capture.startError = DeviceWedged()
        let orchestrator = DictationOrchestrator(
            capture: capture, transcriber: CountingTranscriber(), injector: CountingInjector()
        )
        let notes = collectNotes(orchestrator)
        await orchestrator.handle(.startRecording)
        await settle()
        await #expect(orchestrator.phase == .idle)
        #expect(await notes.all().last == captureFailedNote)
    }

    @Test("The dictation after a failed start still records")
    func startRecoversAfterFailure() async {
        struct DeviceWedged: Error {}
        let capture = CappedCapture(clip: clip(speech: 2))
        capture.startError = DeviceWedged()
        let injector = CountingInjector()
        let orchestrator = DictationOrchestrator(
            capture: capture, transcriber: CountingTranscriber(), injector: injector
        )
        await orchestrator.handle(.startRecording)
        await #expect(orchestrator.phase == .idle)
        capture.startError = nil
        await orchestrator.handle(.startRecording)
        await #expect(orchestrator.phase == .recording)
        await orchestrator.handle(.stopRecording)
        #expect(await injector.count() == 1)
        #expect(capture.startCount == 2)
    }
}
