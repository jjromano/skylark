import Testing
import Foundation
import SkylarkCore

/// Regression coverage built on the canonical `CleanupCorpus`.
@Suite("Cleanup corpus")
struct CleanupCorpusTests {
    /// Known-good exact-match rate (out of `CleanupCorpus.examples.count`) for
    /// the real Apple on-device model, from the 2026-07-24 eval (see
    /// `cleanup-eval-and-open-items` memory). This is a FLOOR the live eval
    /// must clear, not a target — raise it deliberately when a genuine
    /// quality improvement lifts the bar, never to silence a regression.
    private static let appleIntelligenceBaseline = 13

    // MARK: - Model-free gate (runs on every change)

    /// Every canonical `expected` cleanup MUST survive the faithfulness guards at
    /// BOTH the cloud (0.34, no content-loss floor) and the strict local
    /// (0.55 / 0.60) floors. A guard that starts rejecting a legitimate cleanup
    /// makes the pipeline silently keep RAW instead — the exact failure behind
    /// the "A ten G"/"$1.99 stayed spelled out" regression. This needs no model,
    /// so it gates every commit.
    @Test("Every expected cleanup passes hygiene at both cloud and local floors")
    func expectedOutputsAreNeverRejected() throws {
        for ex in CleanupCorpus.examples {
            #expect(throws: Never.self, "cloud floor rejected [\(ex.category)] \(ex.expected.debugDescription)") {
                try CleanupHygiene.validate(ex.expected, transcript: ex.raw)
            }
            #expect(throws: Never.self, "local floor rejected [\(ex.category)] \(ex.expected.debugDescription)") {
                try CleanupHygiene.validate(
                    ex.expected, transcript: ex.raw,
                    retentionFloor: 0.55, contentLossFloor: 0.60)
            }
        }
    }

    // MARK: - Live on-device eval (opt-in)

    /// Drives the REAL Apple on-device model over the whole corpus and prints a
    /// per-example report (MATCH / DIFF vs the expected standard cleanup). Greedy
    /// decoding is deterministic, so the report is stable version-to-version —
    /// eyeball it (or diff it) before a release to catch a cleanup-quality
    /// regression the model-free gate can't see. Off by default (needs Apple
    /// Intelligence); enable with:
    ///
    ///     SKYLARK_LIVE_CLEANUP_EVAL=1 make test
    @Test("LIVE on-device cleanup eval over the corpus",
          .enabled(if: ProcessInfo.processInfo.environment["SKYLARK_LIVE_CLEANUP_EVAL"] != nil))
    func liveOnDeviceEval() async throws {
        let cleaner = LocalCleaner()
        let ctx = CleanupContext(intensity: .standard)
        var matches = 0
        var report = "\n===== LOCAL on-device cleanup eval (standard intensity) =====\n"
        for ex in CleanupCorpus.examples {
            let got: String
            do { got = try await cleaner.clean(ex.raw, context: ctx) }
            catch { got = "<threw: \(error)>" }
            let ok = got == ex.expected
            if ok { matches += 1 }
            report += """
            [\(ok ? "MATCH" : "DIFF ")] \(ex.category)
              raw: \(ex.raw)
              exp: \(ex.expected)
              got: \(got)

            """
        }
        let count = CleanupCorpus.examples.count
        report += "----- \(matches)/\(count) exact matches -----\n"
        print(report)

        #expect(
            matches >= Self.appleIntelligenceBaseline,
            "Apple Intelligence cleanup eval regressed: \(matches)/\(count) exact matches, floor is \(Self.appleIntelligenceBaseline)/\(count). Full report:\n\(report)"
        )
    }
}
