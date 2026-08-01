import Testing
import SkylarkCore

/// Pure resolution logic for the R3 per-mode Whisper Mode override:
/// `effective(globalOn:)` is the single seam `DictationOrchestrator.finishRecording`
/// calls once the session's mode is resolved (mode override ?? global toggle).
@Suite("WhisperModeOverride resolution")
struct WhisperModeOverrideTests {
    @Test("followGlobal mirrors whatever the global toggle currently is")
    func followGlobalMirrorsGlobal() {
        #expect(WhisperModeOverride.followGlobal.effective(globalOn: true) == true)
        #expect(WhisperModeOverride.followGlobal.effective(globalOn: false) == false)
    }

    @Test("on always resolves true, regardless of the global toggle")
    func onAlwaysTrue() {
        #expect(WhisperModeOverride.on.effective(globalOn: true) == true)
        #expect(WhisperModeOverride.on.effective(globalOn: false) == true)
    }

    @Test("off always resolves false, regardless of the global toggle")
    func offAlwaysFalse() {
        #expect(WhisperModeOverride.off.effective(globalOn: true) == false)
        #expect(WhisperModeOverride.off.effective(globalOn: false) == false)
    }

    @Test("followGlobal is the default for a mode that doesn't specify an override")
    func defaultIsFollowGlobal() {
        let mode = DictationMode(id: "m", name: "Mode", bundleIDPattern: nil, cleanupTier: .local)
        #expect(mode.whisperModeOverride == .followGlobal)

        let record = ModeRecord(id: "m", name: "Mode", cleanupTier: .local, isDefault: false)
        #expect(record.whisperModeOverride == .followGlobal)
    }
}
