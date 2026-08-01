import Testing
import SkylarkCore

/// Audit U7: "partial VAD detection silently deletes quiet leading or trailing
/// speech". It could — whatever the model missed beyond the 0.45 s / 0.25 s pads
/// was cut. The audible guard makes the clip's own energy the second witness:
/// head/tail audio above a fraction of the utterance's peak survives however the
/// VAD scored it, and the guard can only ever KEEP MORE.
@Suite("VadClipTrimmer audible guard (U7)")
struct VadAudibleGuardTests {
    private let rate: Double = 16_000

    private func s(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }

    /// Tone-ish samples at `amplitude` over `range`, silence elsewhere.
    private func signal(seconds: Double, spans: [(Range<Int>, Float)]) -> [Float] {
        var samples = [Float](repeating: 0, count: s(seconds))
        for (range, amplitude) in spans {
            for i in range.clamped(to: 0..<samples.count) {
                samples[i] = i.isMultiple(of: 2) ? amplitude : -amplitude
            }
        }
        return samples
    }

    private func decide(
        _ regions: [SpeechRegion], samples: [Float]
    ) -> VadClipTrimmer.Verdict {
        VadClipTrimmer.decide(
            regions: regions,
            sampleCount: samples.count,
            sampleRate: rate,
            samples: samples
        )
    }

    @Test("A quiet leading word the VAD missed is not deleted")
    func quietOnsetSurvives() {
        // 8 s clip. Real speech: a quiet word at [1.6, 2.0) then loud speech at
        // [3.0, 5.0). The VAD only scored the loud part — the exact U7 shape.
        let samples = signal(seconds: 8, spans: [
            (s(1.6)..<s(2.0), 0.04),
            (s(3.0)..<s(5.0), 0.4),
        ])
        let verdict = decide([SpeechRegion(startSample: s(3), endSample: s(5))], samples: samples)
        let keep = try? #require(verdict.keepRange)
        // Without the guard this would keep from 2.55 s and eat the whole word.
        #expect((keep?.lowerBound ?? .max) <= s(1.6))
        // Still a worthwhile trim: the 1.1 s of true head silence is gone.
        #expect(verdict.headTrimmed > 0.8)
    }

    @Test("A quiet trailing word the VAD missed is not deleted")
    func quietTailSurvives() {
        let samples = signal(seconds: 8, spans: [
            (s(2.0)..<s(4.0), 0.4),
            (s(4.3)..<s(4.7), 0.04),
        ])
        let verdict = decide([SpeechRegion(startSample: s(2), endSample: s(4))], samples: samples)
        let keep = try? #require(verdict.keepRange)
        #expect((keep?.upperBound ?? 0) >= s(4.7))
        #expect(verdict.tailTrimmed > 2.5)
    }

    @Test("True silence is still trimmed (the guard costs nothing when it should)")
    func silentHeadAndTailStillTrimmed() {
        let samples = signal(seconds: 8, spans: [(s(3.0)..<s(5.0), 0.4)])
        let verdict = decide([SpeechRegion(startSample: s(3), endSample: s(5))], samples: samples)
        // Byte-identical to the pre-guard verdict: pads only.
        #expect(verdict.keepRange == s(2.55)..<s(5.25))
    }

    @Test("Room tone well below the speech peak does not block the trim")
    func lowLevelNoiseDoesNotBlockTrimming() {
        // Continuous noise at 1 % of the speech peak across the whole clip.
        var samples = signal(seconds: 8, spans: [(0..<s(8), 0.004)])
        for i in s(3)..<s(5) { samples[i] = i.isMultiple(of: 2) ? 0.4 : -0.4 }
        let verdict = decide([SpeechRegion(startSample: s(3), endSample: s(5))], samples: samples)
        #expect(verdict.keepRange == s(2.55)..<s(5.25))
    }

    @Test("A room too loud to judge is left whole rather than cut wrong")
    func loudRoomLeavesClipUntouched() {
        // Noise at 30 % of the speech peak everywhere: the guard can't tell
        // speech from room, so it keeps everything and the trim falls away.
        var samples = signal(seconds: 8, spans: [(0..<s(8), 0.12)])
        for i in s(3)..<s(5) { samples[i] = i.isMultiple(of: 2) ? 0.4 : -0.4 }
        #expect(decide([SpeechRegion(startSample: s(3), endSample: s(5))], samples: samples)
            .keepRange == nil)
    }

    @Test("The guard never shortens what the VAD-only decision kept")
    func guardOnlyEverKeepsMore() {
        let samples = signal(seconds: 8, spans: [
            (s(1.6)..<s(2.0), 0.04),
            (s(3.0)..<s(5.0), 0.4),
        ])
        let regions = [SpeechRegion(startSample: s(3), endSample: s(5))]
        let plain = VadClipTrimmer.decide(regions: regions, sampleCount: samples.count, sampleRate: rate)
        let guarded = decide(regions, samples: samples)
        let plainKeep = plain.keepRange ?? 0..<samples.count
        let guardedKeep = guarded.keepRange ?? 0..<samples.count
        #expect(guardedKeep.lowerBound <= plainKeep.lowerBound)
        #expect(guardedKeep.upperBound >= plainKeep.upperBound)
    }

    @Test("VAD found nothing: still untouched, guard or no guard")
    func noRegionsStillUntouched() {
        let samples = signal(seconds: 8, spans: [(s(3)..<s(5), 0.4)])
        #expect(decide([], samples: samples).keepRange == nil)
    }

    @Test("A sample array that doesn't match the clip is ignored, not trusted")
    func mismatchedSamplesIgnored() {
        // Defensive: a caller passing the wrong buffer must not move the cut.
        let verdict = VadClipTrimmer.decide(
            regions: [SpeechRegion(startSample: s(3), endSample: s(5))],
            sampleCount: s(8),
            sampleRate: rate,
            samples: [Float](repeating: 0.5, count: s(2))
        )
        #expect(verdict.keepRange == s(2.55)..<s(5.25))
    }
}
