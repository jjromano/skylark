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
}
