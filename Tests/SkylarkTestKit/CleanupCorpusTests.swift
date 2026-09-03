import Testing
import Foundation
import SkylarkCore

/// Regression coverage built on the canonical `CleanupCorpus`.
@Suite("Cleanup corpus")
struct CleanupCorpusTests {
    /// Known-good exact-match rate (out of `CleanupCorpus.examples.count`) for
    /// the real Apple on-device model. This is a FLOOR the live eval must
    /// clear, not a target — raise it deliberately when a genuine quality
    /// improvement lifts the bar, never to silence a regression.
    ///
    /// Measured 17/29 on 2026-09-02 on an M3 Air, macOS 26.2, Apple
    /// Intelligence available. Floor set to 16, one case of slack, consistent
    /// with how the Qwen floors in `QwenCleanupEvalTests` were set. The
    /// corpus also gained two `spokenAddress/*` examples this sprint (another
    /// agent is adding them to `CleanupCorpus.swift`); the floor is an
    /// absolute count out of `examples.count`, not a ratio, so those
    /// additions cannot lower a real score below it.
    private static let appleIntelligenceBaseline = 16

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
        var unavailableReason: String?
        var report = "\n===== LOCAL on-device cleanup eval (standard intensity) =====\n"
        for ex in CleanupCorpus.examples {
            let got: String
            do { got = try await cleaner.clean(ex.raw, context: ctx) }
            catch {
                if case let CleanerError.unavailable(reason) = error {
                    unavailableReason = reason
                }
                got = "<threw: \(error)>"
            }
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

        // An unavailable model is an ENVIRONMENT state, not a cleanup
        // regression, and the two must not produce the same verdict.
        // Asserting the floor unconditionally reported "regressed: 0/29" on
        // every Mac with Apple Intelligence switched off, which reads as a
        // code defect and sends the reader hunting a prompt change that never
        // happened. Say what is actually true, and do not pretend it ran.
        if matches == 0, let reason = unavailableReason {
            print("[cleanup-eval] NOT RUN — the on-device model is unavailable here: \(reason).")
            print("[cleanup-eval] This is not a quality result. Enable Apple Intelligence and")
            print("[cleanup-eval] re-run for a real score against the \(Self.appleIntelligenceBaseline)/\(count) floor.")
            return
        }

        #expect(
            matches >= Self.appleIntelligenceBaseline,
            "Apple Intelligence cleanup eval regressed: \(matches)/\(count) exact matches, floor is \(Self.appleIntelligenceBaseline)/\(count). Full report:\n\(report)"
        )
    }
}
