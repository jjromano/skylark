import Testing
import Foundation
import SkylarkCore

// MARK: - Test doubles

/// Capture double returning a preset clip (the VAD trim only cares about the
/// finalized clip, so nothing needs to stream).
private final class FixedClipCapture: AudioCapturing, @unchecked Sendable {
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

/// Endpointer double: reports a canned residency + canned speech regions, and
/// counts scans so a test can prove the short-clip gate never reaches the model.
private actor StubEndpointer: SpeechEndpointer {
    private let regions: [SpeechRegion]?
    private let resident: Bool
    private var scanCount = 0

    init(regions: [SpeechRegion]?, resident: Bool = true) {
        self.regions = regions
        self.resident = resident
    }

    func prepare() async {}
    func available() -> Bool { resident }
    func beginSession() async {}
    func feed(_ frames: [Float]) async -> Bool { false }

    func scanSpeechRegions(_ samples: [Float]) async -> [SpeechRegion]? {
        scanCount += 1
        return regions
    }

    func scans() -> Int { scanCount }
}

/// Records the clip handed to STT, so a test can prove what the transcriber saw.
private actor ClipSpy: Transcriber {
    nonisolated let id: TranscriberID = .stub
    private var lastClip: AudioClip?

    func warmUp() async throws {}

    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        lastClip = clip
        return StubTranscriber.output
    }

    func received() -> AudioClip? { lastClip }
}

private actor SinkInjector: TextInjecting {
    func insert(_ text: String) async throws -> InsertionToken {
        InsertionToken(method: .paste, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { false }
}

// MARK: - Pure decision

/// WS2: the head/tail trim decision. Every ambiguous case must return
/// "untouched" — VAD may shrink pauses, never veto an utterance.
@Suite("VadClipTrimmer decision")
struct VadClipTrimmerTests {
    private let rate: Double = 16_000

    private func s(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }

    private func decide(
        _ regions: [SpeechRegion],
        clipSeconds: Double,
        configuration: VadClipTrimmer.Configuration = .default
    ) -> VadClipTrimmer.Verdict {
        VadClipTrimmer.decide(
            regions: regions,
            sampleCount: s(clipSeconds),
            sampleRate: rate,
            configuration: configuration
        )
    }

    @Test("Speech in the middle: head and tail go, both pads stay")
    func speechInMiddleTrimmed() {
        // 8 s clip, speech from 3 s to 5 s → keep [2.55, 5.25).
        let verdict = decide([SpeechRegion(startSample: s(3), endSample: s(5))], clipSeconds: 8)
        #expect(verdict.keepRange == s(2.55)..<s(5.25))
        #expect(abs(verdict.headTrimmed - 2.55) < 1e-6)
        #expect(abs(verdict.tailTrimmed - 2.75) < 1e-6)
    }

    @Test("Speech everywhere: clip untouched")
    func allSpeechUntouched() {
        let verdict = decide([SpeechRegion(startSample: 0, endSample: s(6))], clipSeconds: 6)
        #expect(verdict.keepRange == nil)
        #expect(verdict.trimmed == 0)
    }

    @Test("VAD found nothing: clip untouched (never trimmed to empty)")
    func noRegionsUntouched() {
        #expect(decide([], clipSeconds: 8).keepRange == nil)
    }

    @Test("Degenerate zero-length regions count as nothing found")
    func degenerateRegionsUntouched() {
        let verdict = decide(
            [SpeechRegion(startSample: s(3), endSample: s(3)),
             SpeechRegion(startSample: s(9), endSample: s(9))],
            clipSeconds: 8
        )
        #expect(verdict.keepRange == nil)
    }

    @Test("Short clip is skipped outright")
    func shortClipSkipped() {
        // 1.5 s clip, speech only in the last 0.2 s — still untouched.
        let verdict = decide([SpeechRegion(startSample: s(1.3), endSample: s(1.5))], clipSeconds: 1.5)
        #expect(verdict.keepRange == nil)
        #expect(!VadClipTrimmer.isWorthScanning(durationSeconds: 1.5))
        #expect(VadClipTrimmer.isWorthScanning(durationSeconds: 2.0))
    }

    @Test("A trim not worth making is not made")
    func tinySavingIgnored() {
        // 4 s clip, speech 0.3 s → 3.9 s: the pads already cover almost all of it,
        // so the 0.2 s saving is below the 0.35 s floor.
        let verdict = decide([SpeechRegion(startSample: s(0.3), endSample: s(3.9))], clipSeconds: 4)
        #expect(verdict.keepRange == nil)
    }

    @Test("Multiple regions: only the outer bounds are used (pauses survive)")
    func innerPausesKept() {
        let verdict = decide(
            [SpeechRegion(startSample: s(4.5), endSample: s(5.0)),
             SpeechRegion(startSample: s(2.0), endSample: s(2.5))],
            clipSeconds: 8
        )
        // Regions arrive unordered; the pause between 2.5 s and 4.5 s stays.
        #expect(verdict.keepRange == s(1.55)..<s(5.25))
    }

    @Test("Regions past the clip end are clamped, never over-read")
    func regionsClamped() {
        let verdict = decide([SpeechRegion(startSample: s(3), endSample: s(99))], clipSeconds: 8)
        #expect(verdict.keepRange == s(2.55)..<s(8))
        #expect(verdict.tailTrimmed == 0)
    }

    @Test("Whisper-mode padding floor widens both pads")
    func paddingFloorWidensPads() {
        // A floor above BOTH defaults (0.45 lead / 0.25 tail) raises both; whisper
        // mode's own 0.2 s padding sits under both and changes nothing.
        #expect(VadClipTrimmer.Configuration.default.withPaddingFloor(0.2)
            == VadClipTrimmer.Configuration.default)
        let config = VadClipTrimmer.Configuration.default.withPaddingFloor(0.5)
        #expect(config.leadPadding == 0.5)
        #expect(config.tailPadding == 0.5)
        let verdict = decide(
            [SpeechRegion(startSample: s(3), endSample: s(5))], clipSeconds: 8, configuration: config
        )
        #expect(verdict.keepRange == s(2.5)..<s(5.5))
    }

    @Test("Empty or rate-less clips are untouched")
    func emptyInputsUntouched() {
        #expect(VadClipTrimmer.decide(regions: [], sampleCount: 0, sampleRate: rate).keepRange == nil)
        #expect(
            VadClipTrimmer.decide(
                regions: [SpeechRegion(startSample: 0, endSample: 10)],
                sampleCount: 100, sampleRate: 0
            ).keepRange == nil
        )
    }

    @Test("Range trim keeps exactly the kept window and recomputes duration")
    func clipRangeTrim() {
        let clip = AudioClip(
            samples: [Float](repeating: 0.1, count: s(8)), sampleRate: rate, duration: 8
        )
        let trimmed = clip.trimmed(toSampleRange: s(2)..<s(5))
        #expect(trimmed.samples.count == s(3))
        #expect(abs(trimmed.duration - 3) < 1e-9)
        // A range covering everything is a no-op (same clip, same identity).
        #expect(clip.trimmed(toSampleRange: 0..<s(8)) == clip)
        #expect(clip.trimmed(toSampleRange: 5..<5) == clip)
    }
}

// MARK: - Orchestrator wiring

/// WS2 at the finalize seam: the trim happens BEFORE STT, for push-to-talk and
/// hands-free alike, and every gate (short clip, cold model, kill switch, VAD
/// silence) leaves the clip exactly as captured.
@Suite("DictationOrchestrator VAD trim (WS2)")
struct VadTrimOrchestratorTests {
    private let rate: Double = 16_000

    private func s(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }

    /// `silence` seconds of zeros, `speech` seconds of alternating ±0.05, then
    /// `silence` again. `rms` is left nil on purpose so the WS1 dead-tail analyzer
    /// sits out and these tests measure the VAD trim alone.
    private func clip(silence: Double, speech: Double) -> AudioClip {
        let head = [Float](repeating: 0, count: s(silence))
        let voice = (0..<s(speech)).map { $0.isMultiple(of: 2) ? Float(0.05) : Float(-0.05) }
        let all = head + voice + head
        return AudioClip(samples: all, sampleRate: rate, duration: Double(all.count) / rate)
    }

    private func orchestrator(
        clip: AudioClip, endpointer: StubEndpointer, transcriber: ClipSpy
    ) -> DictationOrchestrator {
        DictationOrchestrator(
            capture: FixedClipCapture(clip: clip),
            transcriber: transcriber,
            injector: SinkInjector(),
            endpointer: endpointer
        )
    }

    @Test("Quiet head and tail are trimmed before STT (push-to-talk)")
    func trimsBeforeTranscription() async {
        let transcriber = ClipSpy()
        // 2 s silence + 2 s speech + 2 s silence; speech at [2, 4) →
        // keep [1.55, 4.25) = 2.7 s.
        let endpointer = StubEndpointer(regions: [SpeechRegion(startSample: s(2), endSample: s(4))])
        let orchestrator = orchestrator(
            clip: clip(silence: 2, speech: 2), endpointer: endpointer, transcriber: transcriber
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received()?.samples.count == s(2.7))
        #expect(await endpointer.scans() == 1)
    }

    @Test("Hands-free clips get the same trim")
    func handsFreeTrimmed() async {
        let transcriber = ClipSpy()
        let endpointer = StubEndpointer(regions: [SpeechRegion(startSample: s(2), endSample: s(4))])
        let orchestrator = orchestrator(
            clip: clip(silence: 2, speech: 2), endpointer: endpointer, transcriber: transcriber
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.engageHandsFree)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received()?.samples.count == s(2.7))
    }

    @Test("VAD says nothing: clip reaches STT byte-identical")
    func noSpeechLeavesClipWhole() async {
        let transcriber = ClipSpy()
        let original = clip(silence: 2, speech: 2)
        let orchestrator = orchestrator(
            clip: original, endpointer: StubEndpointer(regions: []), transcriber: transcriber
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received() == original)
    }

    @Test("A cold VAD is never loaded on the paste path")
    func coldModelSkipsScan() async {
        let transcriber = ClipSpy()
        let original = clip(silence: 2, speech: 2)
        let endpointer = StubEndpointer(
            regions: [SpeechRegion(startSample: s(2), endSample: s(4))], resident: false
        )
        let orchestrator = orchestrator(
            clip: original, endpointer: endpointer, transcriber: transcriber
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received() == original)
        #expect(await endpointer.scans() == 0)
    }

    @Test("Short clip never reaches the model at all")
    func shortClipNotScanned() async {
        let transcriber = ClipSpy()
        // 1.6 s total — under the 2 s floor.
        let original = clip(silence: 0.3, speech: 1.0)
        let endpointer = StubEndpointer(
            regions: [SpeechRegion(startSample: s(0.3), endSample: s(1.3))]
        )
        let orchestrator = orchestrator(
            clip: original, endpointer: endpointer, transcriber: transcriber
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received() == original)
        #expect(await endpointer.scans() == 0)
    }

    @Test("Kill switch off: no scan, no trim")
    func killSwitchSkipsScan() async {
        let transcriber = ClipSpy()
        let original = clip(silence: 2, speech: 2)
        let endpointer = StubEndpointer(
            regions: [SpeechRegion(startSample: s(2), endSample: s(4))]
        )
        let orchestrator = orchestrator(
            clip: original, endpointer: endpointer, transcriber: transcriber
        )
        await orchestrator.setVadTrimEnabled(false)
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received() == original)
        #expect(await endpointer.scans() == 0)
    }

    @Test("No endpointer wired: finalize behaves exactly as before")
    func noEndpointerUnchanged() async {
        let transcriber = ClipSpy()
        let original = clip(silence: 2, speech: 2)
        let orchestrator = DictationOrchestrator(
            capture: FixedClipCapture(clip: original),
            transcriber: transcriber,
            injector: SinkInjector()
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(await transcriber.received() == original)
    }

    // MARK: - Live scan latency (opt-in)

    /// Measures the REAL Silero scan on the finalize path — the number the
    /// default-ON decision rests on. Needs the downloaded VAD model; off by
    /// default. Enable with:
    ///
    ///     SKYLARK_LIVE_VAD_TRIM=1 make test TESTFLAGS='--filter liveScanLatency'
    ///
    /// Point `SKYLARK_LIVE_VAD_CLIP` at a 16 kHz WAV to scan real speech instead
    /// of the synthetic burst (region counts are only meaningful then; the latency
    /// is identical either way — Silero runs every 256 ms chunk regardless).
    @Test("LIVE Silero clip-scan latency",
          .enabled(if: ProcessInfo.processInfo.environment["SKYLARK_LIVE_VAD_TRIM"] != nil))
    func liveScanLatency() async throws {
        let vad = FluidAudioVAD()
        await vad.prepare()
        guard await vad.available() else {
            print("\n[vad-trim] VAD model not resident — nothing measured.\n")
            return
        }

        let samples: [Float]
        let source: String
        if let path = ProcessInfo.processInfo.environment["SKYLARK_LIVE_VAD_CLIP"],
           let decoded = WavDecoder.decode(url: URL(fileURLWithPath: path)) {
            samples = decoded.samples
            source = "wav"
        } else {
            // 1 s silence, 3 s of amplitude-modulated noise, 1 s silence.
            var generator = SystemRandomNumberGenerator()
            var built = [Float](repeating: 0, count: 16_000)
            for i in 0..<48_000 {
                let envelope = Float(0.35 * (1 + sin(Double(i) / 900.0)) / 2)
                built.append(Float.random(in: -1...1, using: &generator) * envelope)
            }
            built.append(contentsOf: [Float](repeating: 0, count: 16_000))
            samples = built
            source = "synthetic"
        }
        let seconds = Double(samples.count) / 16_000

        // One warm-up scan (first CoreML call pays one-time setup), then measure.
        _ = await vad.scanSpeechRegions(samples)
        var timings: [Double] = []
        var regionCount = 0
        for _ in 0..<5 {
            let started = ContinuousClock.now
            let regions = await vad.scanSpeechRegions(samples)
            let elapsed = started.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            regionCount = regions?.count ?? 0
        }
        let mean = timings.reduce(0, +) / Double(timings.count)
        let verdict = VadClipTrimmer.decide(
            regions: (await vad.scanSpeechRegions(samples)) ?? [],
            sampleCount: samples.count,
            sampleRate: 16_000
        )
        print("""

        ===== LIVE Silero clip-scan latency (\(source), \(String(format: "%.2f", seconds)) s) =====
          scans: \(timings.map { String(format: "%.1f", $0) }.joined(separator: ", ")) ms
          mean: \(String(format: "%.1f", mean)) ms   min: \(String(format: "%.1f", timings.min() ?? 0)) ms
          regions: \(regionCount)  head-trim: \(Int(verdict.headTrimmed * 1000)) ms  \
        tail-trim: \(Int(verdict.tailTrimmed * 1000)) ms

        """)
        // Not an assertion on absolute speed (machine-dependent) — only that the
        // scan is bounded well under a human-perceptible slice of the paste path.
        #expect(mean < 200)
    }
}
