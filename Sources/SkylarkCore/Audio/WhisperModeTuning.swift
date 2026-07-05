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
