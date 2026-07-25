import Foundation

/// One recorded utterance. Capture converts to 16 kHz mono Float32 once at the
/// tap (confirmed native rate for FluidAudio ASR + VAD and WhisperKit).
///
/// Beyond the audio it carries the capture-integrity metadata the finalize
/// decision needs (WS1): how long the capture actually lasted in wall time, the
/// per-callback RMS trace, and any interruption observed while recording. All
/// three default to "unknown" so synthesized clips (tests, WAV decode, bench)
/// are unaffected.
public struct AudioClip: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Duration derived from the SAMPLE COUNT — what the transcriber will hear.
    public let duration: TimeInterval
    /// Wall-clock time the capture actually spanned, when known. Divergence from
    /// `duration` is the stalled-tap signature (see `tapStalled`).
    public let wallDuration: TimeInterval?
    /// Per-callback RMS recorded during capture (nil for synthesized clips).
    public let rms: RMSTrace?
    /// First disruption observed while capturing, if any.
    public let interruption: CaptureInterruption?

    public init(
        samples: [Float],
        sampleRate: Double,
        duration: TimeInterval,
        wallDuration: TimeInterval? = nil,
        rms: RMSTrace? = nil,
        interruption: CaptureInterruption? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
        self.wallDuration = wallDuration
        self.rms = rms
        self.interruption = interruption
    }

    /// An empty clip (nothing captured).
    public static let empty = AudioClip(samples: [], sampleRate: 16_000, duration: 0)

    public var isEmpty: Bool { samples.isEmpty }

    // MARK: - Duration integrity (stalled-tap variant)

    /// Wall time below which the sample/wall comparison isn't worth making.
    public static let stalledTapMinWall: TimeInterval = 1.0
    /// Fraction of wall time the sample-derived duration must reach.
    public static let stalledTapSampleRatio: Double = 0.6

    /// True when far fewer samples arrived than the hold lasted: the input tap
    /// stopped delivering mid-capture (mic seized by another app, coreaudiod
    /// hiccup). This is the interruption variant with NO silent tail to detect —
    /// the samples simply stop — so it can only be caught here.
    public var tapStalled: Bool {
        guard let wallDuration, wallDuration >= Self.stalledTapMinWall else { return false }
        return duration < wallDuration * Self.stalledTapSampleRatio
    }

    /// How far the sample-derived duration fell short of wall time (0 when
    /// unknown or ahead).
    public var durationDeficit: TimeInterval {
        guard let wallDuration else { return 0 }
        return max(0, wallDuration - duration)
    }

    // MARK: - Derivation

    /// Copy carrying `newSamples`, with `duration` recomputed from the count and
    /// the capture metadata preserved. The RMS trace is dropped when the length
    /// changes — it describes the captured clip, not a trimmed one.
    public func replacingSamples(_ newSamples: [Float]) -> AudioClip {
        AudioClip(
            samples: newSamples,
            sampleRate: sampleRate,
            duration: sampleRate > 0 ? Double(newSamples.count) / sampleRate : duration,
            wallDuration: wallDuration,
            rms: newSamples.count == samples.count ? rms : nil,
            interruption: interruption
        )
    }

    /// Copy keeping only the first `count` samples (no-op when `count` covers the
    /// whole clip). The single trim primitive the finalize path uses.
    public func trimmed(toSampleCount count: Int) -> AudioClip {
        guard count >= 0, count < samples.count else { return self }
        return replacingSamples(Array(samples[0..<count]))
    }

    /// Copy keeping only `range` (no-op when `range` covers the whole clip or
    /// falls outside it). The head-and-tail counterpart of
    /// `trimmed(toSampleCount:)`, used by the VAD trim (WS2); one slice copy.
    public func trimmed(toSampleRange range: Range<Int>) -> AudioClip {
        let lower = max(0, range.lowerBound)
        let upper = min(samples.count, range.upperBound)
        guard lower < upper, lower > 0 || upper < samples.count else { return self }
        return replacingSamples(Array(samples[lower..<upper]))
    }
}
