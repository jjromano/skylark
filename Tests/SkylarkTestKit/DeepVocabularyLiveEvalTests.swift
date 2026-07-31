import Foundation
import Testing
import SkylarkCore

/// Live deep-vocabulary rescorer eval (P0-1 diagnosis). Drives the REAL
/// Parakeet TDT + CTC-110M models over a WAV on disk with the dictionary that
/// reproduced the corruption, and prints raw vs rescored text so the matcher's
/// behavior is observable outside the app. Debug builds also emit FluidAudio's
/// VocabularyRescorer candidate log.
///
/// Off by default (needs models on disk + a clip). Run with:
///   SKYLARK_LIVE_DEEPVOCAB_EVAL=1 SKYLARK_DEEPVOCAB_CLIP=/path/to/clip.wav \
///     make test TESTFLAGS='--filter liveDeepVocabRescore'
@Suite("Deep-vocabulary live rescorer eval")
struct DeepVocabularyLiveEvalTests {

    private struct StubDictionary: DictionaryProviding {
        let stored: [DictionaryEntry]
        func entries() async throws -> [DictionaryEntry] { stored }
    }

    @Test("liveDeepVocabRescore: rescore the eval clip against the QA dictionary")
    func liveDeepVocabRescore() async throws {
        guard ProcessInfo.processInfo.environment["SKYLARK_LIVE_DEEPVOCAB_EVAL"] == "1" else {
            return
        }
        let clipPath = ProcessInfo.processInfo.environment["SKYLARK_DEEPVOCAB_CLIP"] ?? ""
        guard let clip = WavDecoder.decode(url: URL(fileURLWithPath: clipPath)) else {
            Issue.record("SKYLARK_DEEPVOCAB_CLIP missing or unreadable: \(clipPath)")
            return
        }

        let engine = FluidAudioParakeet()
        try await engine.warmUp()
        let raw = try await engine.transcribe(clip, hint: .none)
        let timings = await engine.lastTokenTimings()
        print("EVAL raw: \(raw)")
        print("EVAL timings: \(timings?.count ?? -1) tokens")
        guard let timings, !raw.isEmpty else {
            Issue.record("no transcription/timings from Parakeet")
            return
        }

        // The dictionary state from the live corruption repro (history row 1424).
        let dictionary = StubDictionary(stored: [
            DictionaryEntry(phrase: "CLAUDE.md", misspellings: ["CLOD.md", "Cloud.md"], source: .manual),
            DictionaryEntry(phrase: "Claude", misspellings: ["clod"], source: .manual),
        ])

        let rescorer = FluidAudioDeepVocabularyRescorer(dictionary: dictionary)
        let rescored = await rescorer.rescore(rawText: raw, samples: clip.samples, timings: timings)
        print("EVAL rescored: \(rescored ?? "<nil — kept raw>")")
    }
}
