import Testing
import SkylarkCore

/// Hands-free silence tolerance (Settings → General "Hands-free stops
/// after"). `FluidAudioVAD.clampedSilenceSeconds` is the single source of
/// truth both `AppController` (persistence/init) and this test use, so a
/// corrupted or out-of-range UserDefaults value can never desync the stored
/// setting from what the VAD actor will actually run with.
@Suite("FluidAudioVAD hands-free silence tolerance")
struct SpeechEndpointerTests {
    @Test("Allowed values pass through unchanged")
    func allowedValuesPassThrough() {
        #expect(FluidAudioVAD.clampedSilenceSeconds(1) == 1)
        #expect(FluidAudioVAD.clampedSilenceSeconds(2) == 2)
        #expect(FluidAudioVAD.clampedSilenceSeconds(3) == 3)
    }

    @Test("Out-of-range values fall back to the 2 s default")
    func outOfRangeFallsBackToDefault() {
        #expect(FluidAudioVAD.clampedSilenceSeconds(0) == 2)
        #expect(FluidAudioVAD.clampedSilenceSeconds(-1) == 2)
        #expect(FluidAudioVAD.clampedSilenceSeconds(4) == 2)
        #expect(FluidAudioVAD.clampedSilenceSeconds(999) == 2)
    }

    @Test("Default constant matches the fallback value")
    func defaultConstantMatchesFallback() {
        #expect(Int(FluidAudioVAD.minSilenceDuration) == 2)
        #expect(FluidAudioVAD.allowedSilenceSeconds == [1, 2, 3])
    }
}
