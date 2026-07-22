import Foundation

/// Detects a push-to-talk clip the mic effectively heard nothing on, so the
/// orchestrator can skip transcription/insertion entirely instead of pasting
/// whatever a model hallucinates from silence. Hands-free (VAD-endpointed)
/// clips are speech by construction and never go through this check (see
/// `DictationOrchestrator.finishRecording`).
public enum SilenceDetector {
    /// Peak amplitude (linear, full-scale = 1.0) below which a clip reads as
    /// silent — conservative, ≈ -48 dBFS. Real quiet speech (even a -40 dBFS
    /// test tone) must clear this floor, so when in doubt this leans toward
    /// "not silent" (transcribe).
    public static let peakThreshold: Float = 0.004

    /// Threshold when Whisper Mode is on: the tap already applies ×4 capture
    /// gain and the user is deliberately near-silent, so only an essentially
    /// dead signal should read as silence (boosted whispering clears this by
    /// an order of magnitude). Pushed to the orchestrator by
    /// `applyWhisperTuning` alongside the engines' clip-skip floors.
    public static let whisperPeakThreshold: Float = 0.0005

    /// Clips shorter than this are too short to judge — a short blip could
    /// still be real, clipped speech. False-negative bias: transcribe it.
    public static let minJudgeableDuration: TimeInterval = 0.4

    /// True when the clip is long enough to judge AND its peak amplitude never
    /// clears `threshold`. A single O(n) pass over `clip.samples` tracks
    /// min/max and derives peak-to-peak amplitude from them — robust to a
    /// constant DC offset (a mic resting at a nonzero level isn't speech),
    /// unlike a naive max-absolute-value peak.
    public static func isSilent(_ clip: AudioClip, threshold: Float = peakThreshold) -> Bool {
        guard clip.duration >= minJudgeableDuration, !clip.samples.isEmpty else { return false }
        var minValue: Float = .greatestFiniteMagnitude
        var maxValue: Float = -.greatestFiniteMagnitude
        for sample in clip.samples {
            if sample < minValue { minValue = sample }
            if sample > maxValue { maxValue = sample }
        }
        let peak = (maxValue - minValue) / 2
        return peak < threshold
    }
}
