import Foundation

/// The per-callback RMS values recorded alongside a capture, in capture order.
///
/// RMS is already computed on the audio thread for the HUD waveform
/// (`AudioCaptureService.handleTap`), so the trace costs one `Float` + one `Int`
/// append into preallocated storage per callback — no allocation, no locks, and
/// nothing new on the audio path. `frameCounts[i]` is how many 16 kHz samples
/// `values[i]` summarizes, so a trace maps back onto sample offsets exactly even
/// when callback sizes vary (they do, across a device/route change).
public struct RMSTrace: Sendable, Equatable {
    /// Per-callback RMS (linear, full-scale = 1.0).
    public let values: [Float]
    /// Samples covered by each entry of `values` (same count, same order).
    public let frameCounts: [Int]
    public let sampleRate: Double

    public init(values: [Float], frameCounts: [Int], sampleRate: Double) {
        self.values = values
        self.frameCounts = frameCounts
        self.sampleRate = sampleRate
    }

    /// Uniform-callback convenience (tests, and taps with a fixed frame count).
    public init(values: [Float], framesPerValue: Int, sampleRate: Double) {
        self.init(
            values: values,
            frameCounts: [Int](repeating: framesPerValue, count: values.count),
            sampleRate: sampleRate
        )
    }

    public var isEmpty: Bool { values.isEmpty }

    /// Total samples the trace accounts for.
    public var sampleCount: Int {
        frameCounts.prefix(values.count).reduce(0, +)
    }
}

/// Pure, synchronous dead-tail detector for a finalized clip (WS1).
///
/// The failure it exists for: the mic (or our event tap) is seized mid-hold by
/// another app or an OS Fn action, the user keeps holding the trigger, and
/// capture keeps appending *nothing* — so the clip is "speech, then a long
/// sub-floor tail" and the transcriber drops everything after the first seconds.
/// Trimming that tail before STT restores the words we did capture, and the
/// same verdict tells the orchestrator to warn that the utterance may be
/// incomplete.
///
/// Deliberately conservative in two ways:
/// - `deadFloor` is *digital-silence* low (≈ -66 dBFS). What we're detecting is
///   NO SIGNAL — a seized input delivers exact zeros — not "quiet". A live built-in
///   mic in a silent room floors out around -60 dBFS, comfortably above, so an
///   ordinary pause or a slow release is never trimmed and never warned about.
/// - A trim always keeps `keepPadding` of the tail (floored at the active VAD
///   speech padding), so a soft word ending can't be clipped.
///
/// O(n) over the trace (thousands of Floats), allocation-free, and off the audio
/// thread — it runs on the orchestrator actor at finalize time.
public enum TrailingSilenceAnalyzer {
    public struct Configuration: Sendable, Equatable {
        /// RMS at or below which a callback counts as dead air (≈ -66 dBFS) —
        /// "no signal", not "quiet" (see the type doc).
        public var deadFloor: Float
        /// RMS above which a callback counts as speech energy (≈ -40 dBFS).
        public var speechFloor: Float
        /// Tail kept after the last live callback when trimming.
        public var keepPadding: TimeInterval
        /// Shortest dead tail worth trimming at all.
        public var minTrimmableTail: TimeInterval
        /// Dead tail from which an interruption is suspected.
        public var minInterruptionTail: TimeInterval
        /// Fraction of the clip the dead tail must occupy to suspect an
        /// interruption (guards a short clip with a long deliberate pause).
        public var minInterruptionTailFraction: Double
        /// Speech energy required before a dead tail is read as an interruption
        /// (an all-silent clip is the silence guard's business, not ours).
        public var minSpeechForInterruption: TimeInterval

        public init(
            deadFloor: Float,
            speechFloor: Float,
            keepPadding: TimeInterval,
            minTrimmableTail: TimeInterval,
            minInterruptionTail: TimeInterval,
            minInterruptionTailFraction: Double,
            minSpeechForInterruption: TimeInterval
        ) {
            self.deadFloor = deadFloor
            self.speechFloor = speechFloor
            self.keepPadding = keepPadding
            self.minTrimmableTail = minTrimmableTail
            self.minInterruptionTail = minInterruptionTail
            self.minInterruptionTailFraction = minInterruptionTailFraction
            self.minSpeechForInterruption = minSpeechForInterruption
        }

        /// Defaults tuned for 16 kHz capture: trim only ≥ 0.75 s of dead air
        /// (keeping 0.25 s of it), and only call it an interruption when at least
        /// 0.4 s of real speech is followed by ≥ 1.5 s of dead air that is ≥ 40 %
        /// of the clip. Every threshold biases toward "say nothing": a missed
        /// interruption costs a note, a false one nags a user whose mic was fine.
        public static let `default` = Configuration(
            deadFloor: 0.0005,
            speechFloor: 0.01,
            keepPadding: 0.25,
            minTrimmableTail: 0.75,
            minInterruptionTail: 1.5,
            minInterruptionTailFraction: 0.4,
            minSpeechForInterruption: 0.4
        )

        /// The same configuration with `keepPadding` raised to at least `floor`
        /// — the caller passes `WhisperModeTuning.vadSpeechPadding` so a trim
        /// never keeps less tail than the VAD path would.
        public func withPaddingFloor(_ floor: TimeInterval) -> Configuration {
            var copy = self
            copy.keepPadding = max(keepPadding, floor)
            return copy
        }
    }

    public struct Verdict: Sendable, Equatable {
        /// Samples to keep from the start of the clip; `nil` = keep it all.
        public var keepSamples: Int?
        /// Length of the trailing sub-`deadFloor` run.
        public var trailingSilence: TimeInterval
        /// Total time whose RMS cleared `speechFloor`.
        public var speechDuration: TimeInterval
        /// "Energy early, long dead tail" — the mic likely went away mid-hold.
        public var suspectsInterruption: Bool

        public init(
            keepSamples: Int?,
            trailingSilence: TimeInterval,
            speechDuration: TimeInterval,
            suspectsInterruption: Bool
        ) {
            self.keepSamples = keepSamples
            self.trailingSilence = trailingSilence
            self.speechDuration = speechDuration
            self.suspectsInterruption = suspectsInterruption
        }

        /// Nothing to say (no trace, or nothing to trim).
        public static let inconclusive = Verdict(
            keepSamples: nil, trailingSilence: 0, speechDuration: 0, suspectsInterruption: false
        )
    }

    /// Judge `trace`. Never trims into speech, never flags an all-silent clip.
    public static func analyze(
        _ trace: RMSTrace, configuration: Configuration = .default
    ) -> Verdict {
        let count = min(trace.values.count, trace.frameCounts.count)
        guard count > 0, trace.sampleRate > 0 else { return .inconclusive }

        // One pass: total samples, sample offset just past the last live
        // callback, and how much of the clip carried speech energy.
        var totalSamples = 0
        var lastLiveEnd = 0
        var speechSamples = 0
        for i in 0..<count {
            let frames = max(0, trace.frameCounts[i])
            totalSamples += frames
            let rms = trace.values[i]
            if rms > configuration.deadFloor { lastLiveEnd = totalSamples }
            if rms > configuration.speechFloor { speechSamples += frames }
        }
        guard totalSamples > 0 else { return .inconclusive }

        let trailingSamples = totalSamples - lastLiveEnd
        let trailingSilence = Double(trailingSamples) / trace.sampleRate
        let speechDuration = Double(speechSamples) / trace.sampleRate

        // Nothing above the floor anywhere: an entirely dead capture. Leave it
        // whole — `SilenceDetector` decides whether it's worth transcribing.
        guard lastLiveEnd > 0 else {
            return Verdict(
                keepSamples: nil,
                trailingSilence: Double(totalSamples) / trace.sampleRate,
                speechDuration: 0,
                suspectsInterruption: false
            )
        }

        let padding = Int((configuration.keepPadding * trace.sampleRate).rounded())
        let keepEnd = min(totalSamples, lastLiveEnd + max(0, padding))
        let shouldTrim = trailingSilence >= configuration.minTrimmableTail && keepEnd < totalSamples

        let tailFraction = Double(trailingSamples) / Double(totalSamples)
        let suspects = speechDuration >= configuration.minSpeechForInterruption
            && trailingSilence >= configuration.minInterruptionTail
            && tailFraction >= configuration.minInterruptionTailFraction

        return Verdict(
            keepSamples: shouldTrim ? keepEnd : nil,
            trailingSilence: trailingSilence,
            speechDuration: speechDuration,
            suspectsInterruption: suspects
        )
    }
}
