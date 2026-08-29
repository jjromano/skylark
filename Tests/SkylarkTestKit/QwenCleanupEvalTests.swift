import Testing
import Foundation
import SkylarkCore

/// LIVE Qwen/llama.cpp cleanup eval over the canonical corpus — the WS4
/// counterpart of `CleanupCorpusTests.liveOnDeviceEval` (which drives the real
/// Apple on-device model). Off by default (needs a downloaded GGUF); enable
/// with:
///
///     SKYLARK_LIVE_QWEN_EVAL=1 make test
///
/// Model selection defaults to the fast tier and can be overridden:
///
///     SKYLARK_QWEN_MODEL=qwen3-4b-instruct SKYLARK_LIVE_QWEN_EVAL=1 make test
///
/// Prints the same MATCH/DIFF report shape as the Apple eval, PLUS per-item
/// latency (`LlamaRunner.Result` already measures this; the Apple backend
/// doesn't expose it, so that harness never had it) and a summary match rate,
/// so the two reports are directly comparable.
@Suite("Qwen cleanup corpus eval", .serialized)
struct QwenCleanupEvalTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["SKYLARK_LIVE_QWEN_EVAL"] != nil
    }

    private static var modelID: String {
        ProcessInfo.processInfo.environment["SKYLARK_QWEN_MODEL"] ?? "qwen3-1.7b"
    }

    /// Known-good exact-match rates (out of `CleanupCorpus.examples.count`),
    /// keyed by `SKYLARK_QWEN_MODEL` id, from the 2026-07 Qwen/llama.cpp eval
    /// (see `cleanup-eval-and-open-items` memory). These are FLOORS the live
    /// eval must clear, not targets — raise one deliberately when a genuine
    /// quality improvement lifts the bar, never to silence a regression.
    ///
    /// The corpus grew from 17 to 29 examples at v0.16.0 (pausePunctuation +
    /// spokenPunctuation categories). These counts (15/17, 7/17) were measured
    /// against the OLD 17-example corpus and have NOT been re-based against
    /// the new 29 — they stay as-is (out of the now-larger `examples.count`)
    /// until measured fresh on the Air; do not edit them to "fix" the ratio.
    private static let baselines: [String: Int] = [
        "qwen3-4b-instruct": 15,
        "qwen3-1.7b": 7,
    ]

    @Test("LIVE Qwen on-device cleanup eval over the corpus", .enabled(if: Self.enabled))
    func liveQwenEval() async throws {
        guard let model = LocalCleanupModel.model(id: Self.modelID) else {
            Issue.record("Unknown SKYLARK_QWEN_MODEL id: \(Self.modelID)")
            return
        }
        guard model.isInstalled else {
            Issue.record("\(model.displayName) isn't downloaded — run the Settings download or SKYLARK_QWEN_MODEL another id.")
            return
        }

        // Always unload before returning: llama.cpp's Metal backend asserts in a
        // static destructor if the process exits with a context still alive
        // (see `LlamaRunner.unload()`), exactly like `LlamaLiveSmokeTests`.
        let backend = QwenCleanupBackend(model: model)
        let instructions = CleanupPrompt.compactInstructions(context: CleanupContext(intensity: .standard))
        await backend.preload(instructions: instructions)

        let cleaner = LocalCleaner(backend: backend)
        let ctx = CleanupContext(intensity: .standard)
        var matches = 0
        var totalSeconds: Double = 0
        var report = "\n===== QWEN local cleanup eval (\(model.displayName), standard intensity) =====\n"
        for ex in CleanupCorpus.examples {
            let start = ContinuousClock.now
            let got: String
            do { got = try await cleaner.clean(ex.raw, context: ctx) }
            catch { got = "<threw: \(error)>" }
            let elapsedSeconds = LlamaRunner.seconds(ContinuousClock.now - start)
            let ms = Int(elapsedSeconds * 1000)
            totalSeconds += elapsedSeconds
            let ok = got == ex.expected
            if ok { matches += 1 }
            report += """
            [\(ok ? "MATCH" : "DIFF ")] \(ex.category) (\(ms) ms)
              raw: \(ex.raw)
              exp: \(ex.expected)
              got: \(got)

            """
        }
        let count = CleanupCorpus.examples.count
        let avgMs = count > 0 ? Int((totalSeconds / Double(count)) * 1000) : 0
        report += "----- \(matches)/\(count) exact matches — avg \(avgMs) ms/cleanup -----\n"
        print(report)

        await backend.unload()

        if let baseline = Self.baselines[Self.modelID] {
            #expect(
                matches >= baseline,
                "Qwen (\(model.displayName)) cleanup eval regressed: \(matches)/\(count) exact matches, floor is \(baseline)/\(count). Full report:\n\(report)"
            )
        } else {
            Issue.record("No known baseline for SKYLARK_QWEN_MODEL id '\(Self.modelID)' — add one to QwenCleanupEvalTests.baselines before trusting this eval's pass/fail.")
        }
    }
}
