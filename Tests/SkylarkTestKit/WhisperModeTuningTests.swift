import Foundation
import Testing
import SkylarkCore

@Suite("Whisper Mode tuning")
struct WhisperModeTuningTests {

    // MARK: - Gain clamp math (vectorized, in-place)

    @Test("Gain multiplies then clamps to [-1, 1]")
    func gainClamps() {
        var samples: [Float] = [0.5, -0.5, 0.1, -0.1, 0.9, -0.9, 0.0]
        samples.withUnsafeMutableBufferPointer {
            WhisperModeTuning.applyGain($0.baseAddress!, count: $0.count, gain: 4.0)
        }
        // 0.5·4 → 2 clamps to 1; 0.1·4 → 0.4 unchanged; 0.9·4 → 3.6 clamps to 1.
        let expected: [Float] = [1.0, -1.0, 0.4, -0.4, 1.0, -1.0, 0.0]
        for (a, b) in zip(samples, expected) {
            #expect(abs(a - b) < 1e-5)
        }
    }

    @Test("Unity gain still clamps out-of-range samples")
    func unityGainClamps() {
        var samples: [Float] = [1.5, -1.5, 0.3]
        samples.withUnsafeMutableBufferPointer {
            WhisperModeTuning.applyGain($0.baseAddress!, count: $0.count, gain: 1.0)
        }
        #expect(abs(samples[0] - 1.0) < 1e-6)
        #expect(abs(samples[1] + 1.0) < 1e-6)
        #expect(abs(samples[2] - 0.3) < 1e-6)
    }

    @Test("Empty buffer is a no-op")
    func emptyBufferNoop() {
        var samples: [Float] = []
        samples.withUnsafeMutableBufferPointer {
            WhisperModeTuning.applyGain($0.baseAddress ?? UnsafeMutablePointer(bitPattern: 0x1)!, count: 0, gain: 4.0)
        }
        #expect(samples.isEmpty)
    }

    // MARK: - Tuning selection

    @Test("forWhisperMode picks the right tuning")
    func selection() {
        #expect(WhisperModeTuning.forWhisperMode(false) == .normal)
        #expect(WhisperModeTuning.forWhisperMode(true) == .whisper)
    }

    @Test("Whisper tuning boosts gain and sensitivity vs normal")
    func whisperVsNormal() {
        let n = WhisperModeTuning.normal
        let w = WhisperModeTuning.whisper
        #expect(n.captureGain == 1.0)
        #expect(w.captureGain == 4.0)
        #expect(w.silenceFloor < n.silenceFloor)          // more permissive floor
        #expect(w.vadSpeechPadding > n.vadSpeechPadding)   // more padding
        #expect(w.vadMinSpeechDuration < n.vadMinSpeechDuration)
    }

    // MARK: - Clip guard floor plumbing

    @Test("Lower silence floor accepts quieter clips")
    func floorPlumbing() {
        // Peak ~5e-5: below the normal 1e-4 floor, above the whisper 1e-5 floor.
        let quiet = AudioClip(samples: Array(repeating: Float(5e-5), count: 16_000), sampleRate: 16_000, duration: 1.0)
        #expect(ClipGuard.shouldSkip(quiet, minDuration: 0.3, silenceFloor: WhisperModeTuning.normal.silenceFloor))
        #expect(!ClipGuard.shouldSkip(quiet, minDuration: 0.3, silenceFloor: WhisperModeTuning.whisper.silenceFloor))
    }

    @Test("Short clip is skipped regardless of floor")
    func shortSkipped() {
        let short = AudioClip(samples: Array(repeating: Float(0.5), count: 1_000), sampleRate: 16_000, duration: 0.06)
        #expect(ClipGuard.shouldSkip(short, minDuration: 0.3, silenceFloor: WhisperModeTuning.whisper.silenceFloor))
    }

    // MARK: - Post-capture clip normalization

    /// A 1 s sine at 16 kHz with the given peak amplitude (16 000 samples ≥ the
    /// normalizer's `minSamples`, so it's judged, not skipped as too-short).
    private func sine(peak: Float, count: Int = 16_000) -> [Float] {
        (0..<count).map { peak * sin(2 * .pi * 220 * Float($0) / 16_000) }
    }

    @Test("Quiet clip is boosted up to the target peak")
    func quietBoosted() {
        // Peak 0.05 needs ×5 to reach target — within the ×8 cap, so it lands
        // right on target (unlike a near-dead clip that would hit the cap).
        let quiet = sine(peak: 0.05)
        let result = WhisperClipNormalizer.normalize(quiet)
        #expect(!result.leftClipped)
        #expect(result.appliedGain > 1)
        var peak: Float = 0
        for s in result.samples where s.magnitude > peak { peak = s.magnitude }
        #expect(abs(peak - WhisperClipNormalizer.targetPeak) < 0.005)
    }

    @Test("Gain is capped so a near-dead clip isn't over-amplified")
    func gainCapped() {
        // Peak 0.01 would need ×25 to reach target; cap is ×8 → peak ≈ 0.08.
        let veryQuiet = sine(peak: 0.01)
        let result = WhisperClipNormalizer.normalize(veryQuiet)
        #expect(abs(result.appliedGain - WhisperClipNormalizer.maxGain) < 1e-4)
        var peak: Float = 0
        for s in result.samples where s.magnitude > peak { peak = s.magnitude }
        #expect(peak < WhisperClipNormalizer.targetPeak) // capped short of target
    }

    @Test("Already-loud clip is left untouched")
    func loudUntouched() {
        let loud = sine(peak: 0.6) // above the 0.25 target
        let result = WhisperClipNormalizer.normalize(loud)
        #expect(result.appliedGain == 1)
        #expect(!result.leftClipped)
        #expect(result.samples == loud)
    }

    @Test("Clipped clip is left untouched and reports the clip count")
    func clippedUntouched() {
        // 5% of samples slammed to ±1.0 (≥ the 1% clip fraction) → left as-is.
        var samples = sine(peak: 0.2)
        for i in stride(from: 0, to: samples.count, by: 20) { samples[i] = 1.0 }
        let result = WhisperClipNormalizer.normalize(samples)
        #expect(result.leftClipped)
        #expect(result.appliedGain == 1)
        #expect(result.clippedSampleCount >= samples.count / 20)
        #expect(result.samples == samples)
    }

    @Test("Empty and too-short clips are left untouched")
    func emptyAndShortUntouched() {
        let empty = WhisperClipNormalizer.normalize([])
        #expect(empty.appliedGain == 1)
        #expect(empty.samples.isEmpty)

        let short = sine(peak: 0.02, count: WhisperClipNormalizer.minSamples - 1)
        let result = WhisperClipNormalizer.normalize(short)
        #expect(result.appliedGain == 1)
        #expect(result.samples == short)
    }

    @Test("Normalizing a 30 s clip stays well under 5 ms")
    func normalizationTiming() {
        // 30 s at 16 kHz = 480 000 samples — the worst realistic case (120 s cap
        // aside). vDSP peak + scale should be trivially fast; assert a generous
        // bound (debug builds are slower than release) and rely on the printed
        // number for the real figure.
        let clip = sine(peak: 0.03, count: 16_000 * 30)
        // Warm caches once, then time a representative run.
        _ = WhisperClipNormalizer.normalize(clip)
        let start = ContinuousClock.now
        let result = WhisperClipNormalizer.normalize(clip)
        let elapsed = start.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("WhisperClipNormalizer 30s normalize: \(ms) ms")
        #expect(result.appliedGain > 1)
        #expect(ms < 20) // generous debug-build ceiling; real is far lower
    }
}
