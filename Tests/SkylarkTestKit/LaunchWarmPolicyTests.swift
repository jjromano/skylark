import Testing
import Foundation
import SkylarkCore

/// Which engine launch is allowed to warm. Launch used to warm Parakeet
/// unconditionally, before the persisted engine choice had been applied: a user
/// on Whisper or Apple Speech who had deleted Parakeet got an unrequested
/// Hugging Face connection and a ~483 MB download every time the app started.
@Suite("Launch warm policy")
struct LaunchWarmPolicyTests {
    @Test("A local selection warms exactly itself — no other engine")
    func localSelectionWarmsItself() {
        #expect(STTChoice.localParakeet.warmLocalEngine() == .localParakeet)
        #expect(STTChoice.localWhisper.warmLocalEngine() == .localWhisper)
        #expect(STTChoice.localApple.warmLocalEngine() == .localApple)
    }

    @Test("Whisper/Apple selections never warm Parakeet (the 483 MB download bug)")
    func neverWarmsParakeetForOtherEngines() {
        for choice: STTChoice in [.localWhisper, .localApple] {
            #expect(choice.warmLocalEngine() != .localParakeet)
        }
    }

    @Test("Fresh install (Parakeet selected) warms exactly as before")
    @MainActor
    func defaultCaseUnchanged() {
        // Nothing persisted → `.localParakeet`, which warms Parakeet — the launch
        // behavior the fix had to preserve.
        let defaults = UserDefaults(suiteName: "launch-warm-test-\(UUID().uuidString)")!
        let restored = ModelSelection(defaults: defaults).sttChoice
        #expect(restored == .localParakeet)
        #expect(restored.warmLocalEngine() == .localParakeet)
    }

    @Test("A cloud selection warms the local engine backing its fallback")
    func cloudWarmsItsFallback() {
        let cloud = STTChoice.cloud(slug: "openai/whisper-large-v3-turbo")
        // Default fallback (fresh install) is Parakeet — unchanged behavior.
        #expect(cloud.warmLocalEngine() == .localParakeet)
        // …and it follows whichever local engine is the active fallback.
        #expect(cloud.warmLocalEngine(cloudFallback: .localApple) == .localApple)
        // A nonsensical (non-local) fallback can't be warmed: fall back to Parakeet.
        #expect(cloud.warmLocalEngine(cloudFallback: .cloud(slug: "x/y")) == .localParakeet)
    }
}
