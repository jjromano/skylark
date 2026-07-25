import Foundation

/// One contiguous run of detected speech inside a finalized clip, in SAMPLE
/// offsets (not seconds — the trim works in samples, and a round-trip through
/// `TimeInterval` loses the exact boundary).
///
/// Deliberately *unpadded*: the VAD reports where it heard voice, and
/// `VadClipTrimmer` owns the prefill/hangover pads so one rule (and one set of
/// unit tests) governs how much air survives around speech.
public struct SpeechRegion: Sendable, Equatable {
    public let startSample: Int
    public let endSample: Int

    public init(startSample: Int, endSample: Int) {
        self.startSample = startSample
        self.endSample = endSample
    }
}

/// Pure, synchronous head/tail trim decision for a finalized clip (WS2).
///
/// `TrailingSilenceAnalyzer` (WS1) removes a *dead* tail — no signal at all, the
/// mic-was-stolen case. This removes the *quiet* head and tail a human leaves
/// around an utterance: the beat between pressing the trigger and starting to
/// speak, and the beat between finishing and releasing (in hands-free, the ≈1 s
/// of silence the endpointer waited for by construction). Two wins: fewer samples
/// into STT (latency), and less non-speech for Whisper to hallucinate words out of
/// (Parakeet is already silence-robust, so for it the win is purely latency).
///
/// Padding follows Handy's smoothed-VAD approach — a prefill before onset and a
/// hangover after offset, so a soft first phoneme or a trailing fricative is never
/// clipped (adapted idea, MIT: `cjpais/Handy` `src/vad/smoothed.rs`; no code
/// copied). The tail pad's default matches `TrailingSilenceAnalyzer`'s
/// `keepPadding` and both are floored at the active `WhisperModeTuning
/// .vadSpeechPadding`, so the two trims never disagree about how much air to keep.
///
/// Conservative by construction — every ambiguous case returns "leave it alone":
/// - No regions at all (VAD false negative) → UNTOUCHED. VAD may only shrink
///   pauses; it must never veto an utterance. Whether a clip is worth
///   transcribing stays `SilenceDetector`'s decision.
/// - Clip shorter than `minClipDuration` → UNTOUCHED (nothing worth the scan).
/// - A trim that would save less than `minSavings`, or leave less than
///   `minKeptDuration` of audio → UNTOUCHED.
///
/// O(regions) — the samples themselves are never touched here; the caller does one
/// slice copy if there's something to cut.
public enum VadClipTrimmer {
    public struct Configuration: Sendable, Equatable {
        /// Kept BEFORE the first detected speech sample (Handy-style prefill).
        /// Generous on purpose: clipping the user's first phoneme is the one
        /// failure this feature must never cause.
        public var leadPadding: TimeInterval
        /// Kept AFTER the last detected speech sample (hangover). Matches
        /// `TrailingSilenceAnalyzer.Configuration.keepPadding`.
        public var tailPadding: TimeInterval
        /// Clips shorter than this are never scanned or trimmed.
        public var minClipDuration: TimeInterval
        /// Total (head + tail) saving below which the trim isn't worth making.
        public var minSavings: TimeInterval
        /// Audio that must survive a trim; below it, the clip is left whole (a
        /// backstop against a VAD that found only a blip of a real utterance).
        public var minKeptDuration: TimeInterval

        public init(
            leadPadding: TimeInterval,
            tailPadding: TimeInterval,
            minClipDuration: TimeInterval,
            minSavings: TimeInterval,
            minKeptDuration: TimeInterval
        ) {
            self.leadPadding = leadPadding
            self.tailPadding = tailPadding
            self.minClipDuration = minClipDuration
            self.minSavings = minSavings
            self.minKeptDuration = minKeptDuration
        }

        /// Defaults for 16 kHz capture: a 0.45 s prefill (Handy's smoothing
        /// window — the first-phoneme guarantee), a 0.25 s hangover (WS1's
        /// keep-padding), only for clips ≥ 2 s, and only when ≥ 0.35 s of
        /// non-speech actually goes away.
        public static let `default` = Configuration(
            leadPadding: 0.45,
            tailPadding: 0.25,
            minClipDuration: 2.0,
            minSavings: 0.35,
            minKeptDuration: 0.5
        )

        /// The same configuration with both pads raised to at least `floor` — the
        /// caller passes `WhisperModeTuning.vadSpeechPadding`, so whisper mode's
        /// more generous framing widens what a trim keeps, exactly as it does for
        /// the WS1 dead-tail trim.
        public func withPaddingFloor(_ floor: TimeInterval) -> Configuration {
            var copy = self
            copy.leadPadding = max(leadPadding, floor)
            copy.tailPadding = max(tailPadding, floor)
            return copy
        }
    }

    public struct Verdict: Sendable, Equatable {
        /// Samples to keep; `nil` = leave the clip exactly as captured.
        public let keepRange: Range<Int>?
        /// Non-speech removed from the head.
        public let headTrimmed: TimeInterval
        /// Non-speech removed from the tail.
        public let tailTrimmed: TimeInterval

        public init(keepRange: Range<Int>?, headTrimmed: TimeInterval, tailTrimmed: TimeInterval) {
            self.keepRange = keepRange
            self.headTrimmed = headTrimmed
            self.tailTrimmed = tailTrimmed
        }

        /// Total audio removed.
        public var trimmed: TimeInterval { headTrimmed + tailTrimmed }

        /// Leave the clip alone.
        public static let untouched = Verdict(keepRange: nil, headTrimmed: 0, tailTrimmed: 0)
    }

    // MARK: - Diagnostics kill switch

    /// `UserDefaults` key that force-disables VAD trimming:
    /// `defaults write com.jjromano.skylark vadClipTrimEnabled -bool false`.
    /// There is no Settings control — the trim is on by default because it is
    /// measured cheap and bounded (see `DictationOrchestrator.vadTrim`) — so this
    /// exists only so a suspected trim bug can be ruled out on a real machine
    /// without a rebuild.
    public static let enabledKey = "vadClipTrimEnabled"

    /// Resolve the kill switch; unset (the normal case) means enabled.
    public static func persistedEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Whether a clip is even worth handing to the VAD. Checked by the caller
    /// BEFORE the scan so a short clip costs nothing at all on the paste path.
    public static func isWorthScanning(
        durationSeconds: TimeInterval, configuration: Configuration = .default
    ) -> Bool {
        durationSeconds >= configuration.minClipDuration
    }

    /// Decide what to keep. `regions` are unpadded speech runs in sample offsets,
    /// in any order; `sampleCount` is the clip's length.
    public static func decide(
        regions: [SpeechRegion],
        sampleCount: Int,
        sampleRate: Double,
        configuration: Configuration = .default
    ) -> Verdict {
        guard sampleCount > 0, sampleRate > 0 else { return .untouched }
        guard isWorthScanning(
            durationSeconds: Double(sampleCount) / sampleRate, configuration: configuration
        ) else { return .untouched }

        // Only the outer bounds matter: we trim the head and tail, never the
        // pauses between words (splitting an utterance would change what the
        // transcriber hears mid-sentence, and STT wants continuous audio).
        var firstStart = Int.max
        var lastEnd = 0
        for region in regions {
            let start = max(0, min(region.startSample, sampleCount))
            let end = max(start, min(region.endSample, sampleCount))
            guard end > start else { continue }
            firstStart = min(firstStart, start)
            lastEnd = max(lastEnd, end)
        }
        // No speech found anywhere (or only degenerate regions): a VAD false
        // negative must never shorten — let alone empty — the clip.
        guard firstStart < lastEnd else { return .untouched }

        let lead = Int((configuration.leadPadding * sampleRate).rounded())
        let tail = Int((configuration.tailPadding * sampleRate).rounded())
        let keepStart = max(0, firstStart - max(0, lead))
        let keepEnd = min(sampleCount, lastEnd + max(0, tail))
        guard keepEnd > keepStart else { return .untouched }

        let headSamples = keepStart
        let tailSamples = sampleCount - keepEnd
        let saved = Double(headSamples + tailSamples) / sampleRate
        let kept = Double(keepEnd - keepStart) / sampleRate
        guard saved >= configuration.minSavings, kept >= configuration.minKeptDuration else {
            return .untouched
        }

        return Verdict(
            keepRange: keepStart..<keepEnd,
            headTrimmed: Double(headSamples) / sampleRate,
            tailTrimmed: Double(tailSamples) / sampleRate
        )
    }
}
