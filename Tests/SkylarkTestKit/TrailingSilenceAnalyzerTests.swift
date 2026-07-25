import Testing
import SkylarkCore

/// Synthetic RMS traces for the WS1 dead-tail detector. Every trace is built at
/// 16 kHz with 0.1 s (1600-sample) callbacks unless a test varies them.
@Suite("TrailingSilenceAnalyzer")
struct TrailingSilenceAnalyzerTests {
    private let sampleRate: Double = 16_000
    private let framesPerValue = 1_600  // 0.1 s per RMS entry

    /// RMS values for `seconds` of the given level.
    private func run(_ level: Float, seconds: Double) -> [Float] {
        [Float](repeating: level, count: Int((seconds / 0.1).rounded()))
    }

    private func trace(_ values: [Float]) -> RMSTrace {
        RMSTrace(values: values, framesPerValue: framesPerValue, sampleRate: sampleRate)
    }

    private func samples(_ seconds: Double) -> Int {
        Int((seconds * sampleRate).rounded())
    }

    // MARK: - Clean speech

    @Test("Clean speech: nothing trimmed, no interruption suspected")
    func cleanSpeech() {
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0.05, seconds: 3.0)))
        #expect(verdict.keepSamples == nil)
        #expect(verdict.trailingSilence == 0)
        #expect(verdict.speechDuration > 2.9)
        #expect(verdict.suspectsInterruption == false)
    }

    @Test("A normal release tail (0.4 s) is below the trim threshold")
    func shortReleaseTailUntouched() {
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0.05, seconds: 2.0) + run(0, seconds: 0.4)))
        #expect(verdict.keepSamples == nil)
        #expect(verdict.suspectsInterruption == false)
    }

    @Test("Room tone above the dead floor is never trimmed (only sub-floor air is)")
    func roomToneTailUntouched() {
        // 4 s of a live-but-quiet mic floor (≈ -60 dBFS): well under the speech
        // floor, still clearly above the dead floor — nothing to trim, and no
        // interruption claimed. This is the false-positive case that matters.
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0.05, seconds: 2.0) + run(0.001, seconds: 4.0)))
        #expect(verdict.keepSamples == nil)
        #expect(verdict.trailingSilence == 0)
        #expect(verdict.suspectsInterruption == false)
    }

    // MARK: - Speech, then the mic goes away

    @Test("Speech then a long dead tail: trimmed to speech + padding, interruption suspected")
    func speechThenSilence() {
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0.05, seconds: 3.0) + run(0, seconds: 8.0)))
        #expect(verdict.suspectsInterruption)
        #expect(abs(verdict.trailingSilence - 8.0) < 0.001)
        // Keeps the 3 s of speech plus the default 0.25 s padding.
        #expect(verdict.keepSamples == samples(3.25))
    }

    @Test("A trim never cuts into speech (padding is kept after the last live frame)")
    func trimKeepsPadding() {
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0.05, seconds: 1.0) + run(0, seconds: 5.0)))
        let keep = verdict.keepSamples ?? 0
        #expect(keep > samples(1.0))  // strictly beyond the last speech sample
        #expect(keep == samples(1.25))
    }

    @Test("Keep-padding floor (VAD speech padding) is respected")
    func paddingFloorRespected() {
        let config = TrailingSilenceAnalyzer.Configuration.default.withPaddingFloor(0.5)
        #expect(config.keepPadding == 0.5)
        let verdict = TrailingSilenceAnalyzer.analyze(
            trace(run(0.05, seconds: 2.0) + run(0, seconds: 5.0)), configuration: config
        )
        #expect(verdict.keepSamples == samples(2.5))
        // A floor BELOW the default never shrinks the padding.
        #expect(TrailingSilenceAnalyzer.Configuration.default.withPaddingFloor(0.1).keepPadding == 0.25)
    }

    @Test("Dead tail with too little speech trims but claims no interruption")
    func tinySpeechNoInterruptionClaim() {
        // 0.2 s blip (< minSpeechForInterruption) then 5 s of dead air.
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0.05, seconds: 0.2) + run(0, seconds: 5.0)))
        #expect(verdict.keepSamples == samples(0.45))
        #expect(verdict.suspectsInterruption == false)
    }

    @Test("A short dead tail inside a long clip trims but doesn't imply interruption")
    func smallTailFractionNoInterruptionClaim() {
        // 1.6 s of dead air after 20 s of speech = 7 % of the clip.
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0.05, seconds: 20.0) + run(0, seconds: 1.6)))
        #expect(verdict.keepSamples == samples(20.25))
        #expect(verdict.suspectsInterruption == false)
    }

    // MARK: - Degenerate traces

    @Test("All-silence trace: nothing to trim, nothing claimed (the silence guard owns it)")
    func allSilence() {
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0, seconds: 10.0)))
        #expect(verdict.keepSamples == nil)
        #expect(verdict.speechDuration == 0)
        #expect(verdict.suspectsInterruption == false)
        #expect(abs(verdict.trailingSilence - 10.0) < 0.001)
    }

    @Test("Empty trace is inconclusive")
    func emptyTrace() {
        #expect(TrailingSilenceAnalyzer.analyze(trace([])) == .inconclusive)
    }

    @Test("Zero sample rate is inconclusive (never divides by zero)")
    func zeroSampleRate() {
        let bad = RMSTrace(values: [0.1, 0.1], framesPerValue: 100, sampleRate: 0)
        #expect(TrailingSilenceAnalyzer.analyze(bad) == .inconclusive)
    }

    @Test("Stalled tap (few samples, no dead tail): the analyzer finds nothing to trim")
    func stalledTapTraceHasNoTail() {
        // The tap simply stopped: 0.8 s of speech and then NO further callbacks,
        // so there are no sub-floor entries to detect. Duration integrity, not the
        // trace, is what catches this variant.
        let verdict = TrailingSilenceAnalyzer.analyze(trace(run(0.05, seconds: 0.8)))
        #expect(verdict.keepSamples == nil)
        #expect(verdict.suspectsInterruption == false)
        let clip = AudioClip(
            samples: [Float](repeating: 0.05, count: samples(0.8)),
            sampleRate: sampleRate,
            duration: 0.8,
            wallDuration: 9.0
        )
        #expect(clip.tapStalled)
        #expect(abs(clip.durationDeficit - 8.2) < 0.001)
    }

    // MARK: - Variable callback sizes

    @Test("Variable callback sizes map onto sample offsets exactly")
    func variableFrameCounts() {
        // 8000 speech samples in three uneven callbacks, then 32000 dead samples.
        let variable = RMSTrace(
            values: [0.05, 0.05, 0.05, 0, 0],
            frameCounts: [4_000, 3_000, 1_000, 16_000, 16_000],
            sampleRate: sampleRate
        )
        #expect(variable.sampleCount == 40_000)
        let verdict = TrailingSilenceAnalyzer.analyze(variable)
        #expect(verdict.keepSamples == 8_000 + samples(0.25))
        #expect(abs(verdict.trailingSilence - 2.0) < 0.001)
        #expect(verdict.suspectsInterruption)
    }

    @Test("Dead air BETWEEN speech is never trimmed (only the trailing run)")
    func interiorSilenceUntouched() {
        let values = run(0.05, seconds: 1.0) + run(0, seconds: 4.0) + run(0.05, seconds: 1.0)
        let verdict = TrailingSilenceAnalyzer.analyze(trace(values))
        #expect(verdict.keepSamples == nil)
        #expect(verdict.trailingSilence == 0)
        #expect(verdict.suspectsInterruption == false)
    }
}
