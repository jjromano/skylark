import Testing
import Foundation
import SkylarkCore

@Suite("CleanupIntensity persistence + defaults")
struct CleanupIntensityTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "cleanup-intensity-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("Defaults to .standard when nothing is persisted")
    func defaultsToStandard() {
        #expect(CleanupIntensity.persisted(in: freshDefaults()) == .standard)
    }

    @Test("Round-trips every case through UserDefaults")
    func roundTrips() {
        let defaults = freshDefaults()
        for intensity in CleanupIntensity.allCases {
            defaults.set(intensity.rawValue, forKey: CleanupIntensity.defaultsKey)
            #expect(CleanupIntensity.persisted(in: defaults) == intensity)
        }
    }

    @Test("An unrecognized stored value falls back to .standard")
    func garbageValueFallsBackToStandard() {
        let defaults = freshDefaults()
        defaults.set("ludicrous", forKey: CleanupIntensity.defaultsKey)
        #expect(CleanupIntensity.persisted(in: defaults) == .standard)
    }

    @Test("CaseIterable exposes exactly light/standard/high, no .none level")
    func exactlyThreeLevels() {
        #expect(CleanupIntensity.allCases == [.light, .standard, .high])
    }

    @Test("CleanupContext defaults intensity to .standard")
    func contextDefault() {
        #expect(CleanupContext().intensity == .standard)
    }
}
