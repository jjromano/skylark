import Foundation
import Testing
import SkylarkCore

@Suite("SilenceDetector")
struct SilenceDetectorTests {
    private let sampleRate: Double = 16_000

    private func clip(samples: [Float]) -> AudioClip {
        AudioClip(samples: samples, sampleRate: sampleRate, duration: Double(samples.count) / sampleRate)
    }

    private func sineWave(seconds: Double, amplitude: Float, frequency: Double = 220) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    @Test("Pure silence (all zero samples) is silent")
    func pureSilence() {
        let samples = [Float](repeating: 0, count: Int(0.5 * sampleRate))
        #expect(SilenceDetector.isSilent(clip(samples: samples)))
    }

    @Test("-40 dBFS sine tone passes as not silent")
    func quietSineToneNotSilent() {
        // -40 dBFS linear amplitude ≈ 0.01, comfortably above the -48 dBFS
        // (0.004) threshold — quiet-but-real speech must transcribe.
        let amplitude: Float = 0.01
        let samples = sineWave(seconds: 0.6, amplitude: amplitude)
        #expect(!SilenceDetector.isSilent(clip(samples: samples)))
    }

    @Test("A 0.2s blip is too short to judge — treated as not silent (transcribe)")
    func tooShortBlipNotSilent() {
        let samples = [Float](repeating: 0, count: Int(0.2 * sampleRate))
        #expect(!SilenceDetector.isSilent(clip(samples: samples)))
    }

    @Test("A DC offset with no variation doesn't fool the peak check")
    func dcOffsetDoesNotFoolPeakCheck() {
        // Every sample resting at a fixed nonzero level (no AC content at
        // all) — a naive max-absolute-value peak would read this as loud;
        // peak-to-peak amplitude correctly reads it as silent.
        let samples = [Float](repeating: 0.5, count: Int(0.5 * sampleRate))
        #expect(SilenceDetector.isSilent(clip(samples: samples)))
    }

    @Test("Loud real speech-level amplitude is not silent")
    func loudSpeechNotSilent() {
        let samples = sineWave(seconds: 0.5, amplitude: 0.3)
        #expect(!SilenceDetector.isSilent(clip(samples: samples)))
    }

    @Test("A clip right at the judgeable-duration boundary is judged")
    func boundaryDurationIsJudged() {
        let samples = [Float](repeating: 0, count: Int(0.4 * sampleRate))
        #expect(SilenceDetector.isSilent(clip(samples: samples)))
    }

    @Test("Empty clip is not classified as silent (guarded elsewhere as empty)")
    func emptyClipNotSilent() {
        #expect(!SilenceDetector.isSilent(.empty))
    }

    @Test("A sample just below the peak threshold is silent")
    func justBelowThresholdIsSilent() {
        let samples = sineWave(seconds: 0.5, amplitude: SilenceDetector.peakThreshold - 0.0005)
        #expect(SilenceDetector.isSilent(clip(samples: samples)))
    }

    @Test("A sample just above the peak threshold is not silent")
    func justAboveThresholdIsNotSilent() {
        let samples = sineWave(seconds: 0.5, amplitude: SilenceDetector.peakThreshold + 0.0005)
        #expect(!SilenceDetector.isSilent(clip(samples: samples)))
    }
}
