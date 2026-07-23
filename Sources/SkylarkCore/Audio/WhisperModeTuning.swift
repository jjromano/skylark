import Accelerate
import Foundation

/// Every knob Whisper Mode (quiet-speech) turns, gathered in one place so the
/// capture tap, the VAD endpointer, and the clip-skip guard all read a single
/// coherent config (phase-4 spec §5). Whisper Mode boosts a near-silent signal
/// so it survives normalization, transcription, and the silence guard.
public struct WhisperModeTuning: Sendable, Equatable {
    /// Linear capture-gain multiplier applied post-conversion in the tap
    /// (vectorized, clamped to [-1, 1]).
    public var captureGain: Float
    /// Peak-amplitude floor below which a clip is treated as silence — lowered
    /// in whisper mode so genuinely quiet speech isn't dropped by the guard.
    public var silenceFloor: Float
    /// VAD padding around detected speech; lengthened in whisper mode so soft
    /// onsets/tails aren't clipped (the primary detection threshold lives in
    /// `VadConfig`, not `VadSegmentationConfig`, so we move what's exposed).
    public var vadSpeechPadding: TimeInterval
    /// VAD minimum speech duration; lowered in whisper mode to accept short,
    /// quiet utterances.
    public var vadMinSpeechDuration: TimeInterval

    public init(
        captureGain: Float,
        silenceFloor: Float,
        vadSpeechPadding: TimeInterval,
        vadMinSpeechDuration: TimeInterval
    ) {
        self.captureGain = captureGain
        self.silenceFloor = silenceFloor
        self.vadSpeechPadding = vadSpeechPadding
        self.vadMinSpeechDuration = vadMinSpeechDuration
    }

    /// Normal (whisper mode off): unity gain, the engines' standard silence
    /// floor, and FluidAudio's default VAD padding/min-speech.
    public static let normal = WhisperModeTuning(
        captureGain: 1.0,
        silenceFloor: 1e-4,
        vadSpeechPadding: 0.1,
        vadMinSpeechDuration: 0.15
    )

    /// Whisper mode on: ×4 gain, a 10× lower silence floor, and more generous
    /// VAD framing so quiet speech is captured and endpointed sensitively.
    public static let whisper = WhisperModeTuning(
        captureGain: 4.0,
        silenceFloor: 1e-5,
        vadSpeechPadding: 0.2,
        vadMinSpeechDuration: 0.08
    )

    /// Pick the tuning for the current global whisper-mode state.
    public static func forWhisperMode(_ on: Bool) -> WhisperModeTuning {
        on ? .whisper : .normal
    }

    // MARK: - Gain (vectorized, allocation-free)

    /// Multiply `count` samples at `buffer` by `gain` in place and clamp to
    /// [-1, 1], using vDSP. Allocation-free and safe to call on the audio render
    /// thread. A gain of exactly 1 still clamps (cheap; keeps behaviour uniform).
    public static func applyGain(_ buffer: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
        guard count > 0 else { return }
        var g = gain
        if gain != 1.0 {
            vDSP_vsmul(buffer, 1, &g, buffer, 1, vDSP_Length(count))
        }
        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(buffer, 1, &lo, &hi, buffer, 1, vDSP_Length(count))
    }
}

/// Post-capture peak normalization for Whisper Mode (quiet-speech). The
/// render-thread tap applies only a fixed ×4 gain (dumb + allocation-free); that
/// under-boosts a very quiet whisper and clips a normal voice left in whisper
/// mode. This pure pass — run AFTER capture closes, off the audio thread, only
/// when whisper mode is on — measures the finalized clip's peak and scales it up
/// toward a target so the transcriber sees a healthy signal.
///
/// It runs AFTER any VAD endpointing decision: hands-free VAD saw the tap-gained
/// signal, and this pass only changes amplitude fed to the transcriber — it never
/// re-runs endpointing, so ordering is safe (phase-5 spec §5). Clipped audio
/// can't be recovered by scaling, so a clip the tap already drove into the ±1.0
/// clamp is left untouched (and the clip count reported at debug, never content).
public enum WhisperClipNormalizer {
    /// Peak amplitude (linear) a below-target whisper clip is scaled up to.
    public static let targetPeak: Float = 0.25
    /// Cap on the normalization gain applied on TOP of the tap's fixed gain, so a
    /// near-dead clip isn't amplified into pure hiss.
    public static let maxGain: Float = 8.0
    /// A sample at/above this magnitude counts as clipped (the tap clamps to ±1).
    public static let clipLevel: Float = 0.999
    /// Fraction of clipped samples at/above which the clip is left untouched.
    public static let clipFraction: Float = 0.01
    /// Clips shorter than this many samples are left untouched — too short to
    /// judge, and boosting a stray click helps nothing. 0.1 s at 16 kHz.
    public static let minSamples = 1_600

    public struct Result: Equatable, Sendable {
        /// Normalized samples — identical to the input when `appliedGain == 1`.
        public var samples: [Float]
        /// Linear gain actually applied (1.0 = left untouched).
        public var appliedGain: Float
        /// Count of input samples at/above `clipLevel` (for debug logging only).
        public var clippedSampleCount: Int
        /// True when normalization was skipped because the input was clipped.
        public var leftClipped: Bool
    }

    /// Normalize `samples` in the whisper-mode sense: boost a below-target peak up
    /// to `targetPeak` (capped at `maxGain`), leaving already-loud, clipped,
    /// empty, or too-short clips untouched. Pure and allocation-frugal: one vDSP
    /// peak pass, and a vDSP scale only when a boost is warranted. Scaling can
    /// never introduce clipping — the resulting peak is `min(targetPeak,
    /// peak·maxGain) ≤ 0.25`.
    public static func normalize(_ samples: [Float]) -> Result {
        let n = samples.count
        guard n >= minSamples else {
            return Result(samples: samples, appliedGain: 1, clippedSampleCount: 0, leftClipped: false)
        }
        var peak: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(ptr.count))
        }
        // Clipping is only possible once the peak reached the clamp level; only
        // then pay for the O(n) count pass.
        var clipped = 0
        if peak >= clipLevel {
            for s in samples where s.magnitude >= clipLevel { clipped += 1 }
            if Float(clipped) >= clipFraction * Float(n) {
                return Result(samples: samples, appliedGain: 1, clippedSampleCount: clipped, leftClipped: true)
            }
        }
        // Silent or already at/above target: nothing to boost.
        guard peak > 0, peak < targetPeak else {
            return Result(samples: samples, appliedGain: 1, clippedSampleCount: clipped, leftClipped: false)
        }
        let gain = min(targetPeak / peak, maxGain)
        var out = samples
        var g = gain
        out.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_vsmul(base, 1, &g, base, 1, vDSP_Length(ptr.count))
        }
        return Result(samples: out, appliedGain: gain, clippedSampleCount: clipped, leftClipped: false)
    }
}

/// Pure clip-skip guard shared by every local engine: a clip too short or too
/// quiet is skipped without ever loading or touching a model (privacy +
/// latency: returns "" rather than throwing). The silence floor is tunable so
/// whisper mode can accept quieter speech.
public enum ClipGuard {
    /// Whether a clip is too short or too quiet to bother transcribing.
    public static func shouldSkip(
        _ clip: AudioClip,
        minDuration: TimeInterval,
        silenceFloor: Float
    ) -> Bool {
        if clip.samples.isEmpty { return true }
        if clip.duration < minDuration { return true }
        var peak: Float = 0
        clip.samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(ptr.count))
        }
        return peak < silenceFloor
    }
}
