import Testing
import Darwin
import SkylarkCore

@Suite("FluidAudioParakeet clip guards")
struct FluidAudioParakeetTests {
    private func clip(_ samples: [Float], duration: Double) -> AudioClip {
        AudioClip(samples: samples, sampleRate: 16_000, duration: duration)
    }

    @Test("Empty clip is skipped")
    func emptySkipped() {
        #expect(FluidAudioParakeet.shouldSkip(.empty))
    }

    @Test("Too-short clip is skipped")
    func shortSkipped() {
        // 0.1 s of loud tone — below the 0.3 s floor.
        let samples = Array(repeating: Float(0.5), count: 1_600)
        #expect(FluidAudioParakeet.shouldSkip(clip(samples, duration: 0.1)))
    }

    @Test("Silent clip is skipped even when long enough")
    func silentSkipped() {
        // 1 s of near-zero samples.
        let samples = Array(repeating: Float(1e-6), count: 16_000)
        #expect(FluidAudioParakeet.shouldSkip(clip(samples, duration: 1.0)))
    }

    @Test("Long, audible clip is not skipped")
    func audibleNotSkipped() {
        let samples = (0..<16_000).map { Float(sin(Double($0) * 0.1)) * 0.4 }
        #expect(!FluidAudioParakeet.shouldSkip(clip(samples, duration: 1.0)))
    }

    @Test("transcribe returns empty for a guarded clip without loading a model")
    func guardedTranscribeReturnsEmpty() async throws {
        // No warmUp() called → if the guard didn't short-circuit, this would
        // throw notReady. A short clip must return "" instead.
        let engine = FluidAudioParakeet()
        let short = clip(Array(repeating: Float(0.5), count: 1_000), duration: 0.06)
        let text = try await engine.transcribe(short, hint: .none)
        #expect(text.isEmpty)
    }
}
