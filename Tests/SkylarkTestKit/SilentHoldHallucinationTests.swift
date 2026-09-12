import Foundation
import Testing
@testable import SkylarkCore

// 2026-09-08 human pass: holding Fn in silence pasted "Yeah." on 2 of 2
// attempts. Room noise cleared the peak-based silence gate, the VAD found no
// speech but may not veto a clip (it misses real whispers), and Parakeet
// invented a word. The VAD now overrules only a lone filler-word transcript.

private struct NoiseCapture: AudioCapturing {
    let clip: AudioClip
    var levels: AsyncStream<Float> {
        let made = AsyncStream<Float>.makeStream(of: Float.self)
        made.continuation.finish()
        return made.stream
    }

    func prepare() {}
    func start() throws {}
    func stop() -> AudioClip { clip }
}

private struct FixedTranscriber: Transcriber {
    let id: TranscriberID = .stub
    let text: String
    func warmUp() async throws {}
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String { text }
}

private actor RegionEndpointer: SpeechEndpointer {
    private let regions: [SpeechRegion]?
    private let resident: Bool
    init(regions: [SpeechRegion]?, resident: Bool = true) {
        self.regions = regions
        self.resident = resident
    }

    func prepare() async {}
    func available() -> Bool { resident }
    func beginSession() async {}
    func feed(_ frames: [Float]) async -> Bool { false }
    func scanSpeechRegions(_ samples: [Float]) async -> [SpeechRegion]? { regions }
}

private actor RecordingInjector: TextInjecting {
    private(set) var inserted: [String] = []
    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        return InsertionToken(method: .paste, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { false }
    func all() -> [String] { inserted }
}

/// One second of low room noise: loud enough to clear `SilenceDetector`'s
/// peak floor, so only the new check can stop it.
private func roomNoise() -> AudioClip {
    var generator = SystemRandomNumberGenerator()
    let samples = (0..<16_000).map { _ in Float.random(in: -1...1, using: &generator) * 0.02 }
    return AudioClip(samples: samples, sampleRate: 16_000, duration: 1)
}

private func firstNote(_ orchestrator: DictationOrchestrator) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        group.addTask {
            for await note in orchestrator.statusNotes { return note }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(300))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@Suite("Silent hold: a lone filler word from noise is discarded")
struct SilentHoldHallucinationTests {
    private func run(
        transcript: String, endpointer: (any SpeechEndpointer)?
    ) async -> (inserted: [String], note: String?) {
        let clip = roomNoise()
        #expect(!SilenceDetector.isSilent(clip)) // the gate this case slips past
        let injector = RecordingInjector()
        let orchestrator = DictationOrchestrator(
            capture: NoiseCapture(clip: clip),
            transcriber: FixedTranscriber(text: transcript),
            injector: injector,
            endpointer: endpointer
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        return (await injector.all(), await firstNote(orchestrator))
    }

    @Test("'Yeah.' with no VAD speech is dropped and says No speech detected")
    func fillerWithoutSpeechDropped() async {
        for filler in ["Yeah.", "yeah", "Mm-hmm.", "Thank you.", "Hmm?"] {
            let result = await run(transcript: filler, endpointer: RegionEndpointer(regions: []))
            #expect(result.inserted.isEmpty, "\(filler) was pasted")
            #expect(result.note == "No speech detected")
        }
    }

    @Test("A filler word the VAD heard as speech is kept")
    func fillerWithSpeechKept() async {
        let speech = [SpeechRegion(startSample: 2_000, endSample: 9_000)]
        let result = await run(transcript: "Yeah.", endpointer: RegionEndpointer(regions: speech))
        #expect(result.inserted == ["Yeah."])
    }

    @Test("Real words are never vetoed by the VAD (it misses whispers)")
    func realWordsKept() async {
        let result = await run(transcript: "Please send me the report tomorrow.", endpointer: RegionEndpointer(regions: []))
        #expect(result.inserted == ["Please send me the report tomorrow."])
    }

    @Test("No VAD verdict means keep the text")
    func noVerdictKeeps() async {
        for endpointer in [nil, RegionEndpointer(regions: nil), RegionEndpointer(regions: [], resident: false)] as [(any SpeechEndpointer)?] {
            let result = await run(transcript: "Yeah.", endpointer: endpointer)
            #expect(result.inserted == ["Yeah."])
        }
    }

    /// The same check against the REAL Silero model on synthetic room noise
    /// with key-click transients, so "the VAD finds nothing in a silent hold"
    /// is measured rather than assumed. Needs the downloaded VAD model:
    ///
    ///     SKYLARK_LIVE_VAD_TRIM=1 make test TESTFLAGS='--filter liveSilentHold'
    @Test("LIVE: real VAD drops a filler word invented from room noise",
          .enabled(if: ProcessInfo.processInfo.environment["SKYLARK_LIVE_VAD_TRIM"] != nil))
    func liveSilentHold() async {
        let vad = FluidAudioVAD()
        await vad.prepare()
        guard await vad.available() else {
            print("\n[silent-hold] VAD model not resident, nothing measured.\n")
            return
        }
        var generator = SystemRandomNumberGenerator()
        for peak: Float in [0.006, 0.012, 0.025] {
            var samples = [Float](repeating: 0, count: 48_000)
            var level: Float = 0
            for i in samples.indices {
                level = 0.98 * level + Float.random(in: -1...1, using: &generator) * 0.2
                samples[i] = level
            }
            let top = samples.map(abs).max() ?? 1
            samples = samples.map { $0 / top * peak }
            for start in [2_400, 46_400] { // Fn down, Fn up
                for k in 0..<160 { samples[start + k] += Float(exp(-Double(k) / 25)) * 0.15 * (k % 2 == 0 ? 1 : -1) }
            }
            let clip = AudioClip(samples: samples, sampleRate: 16_000, duration: 3)
            let injector = RecordingInjector()
            let orchestrator = DictationOrchestrator(
                capture: NoiseCapture(clip: clip),
                transcriber: FixedTranscriber(text: "Yeah."),
                injector: injector,
                endpointer: vad
            )
            await orchestrator.handle(.startRecording)
            await orchestrator.handle(.stopRecording)
            let pasted = await injector.all()
            print("[silent-hold] noise peak \(peak): silence gate says silent=\(SilenceDetector.isSilent(clip)), pasted=\(pasted)")
            #expect(pasted.isEmpty)
        }
    }
}
