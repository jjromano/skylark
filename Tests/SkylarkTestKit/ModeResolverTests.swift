import Testing
import SkylarkCore

@Suite("ModeResolver globs")
struct ModeResolverTests {
    private func mode(_ id: String, _ pattern: String?, tier: CleanupTier = .local, isDefault: Bool = false) -> DictationMode {
        DictationMode(id: id, name: id, bundleIDPattern: pattern, cleanupTier: tier, isDefault: isDefault)
    }

    @Test("Exact match beats a wildcard match")
    func exactBeatsWildcard() {
        let modes = [
            mode("default", nil, tier: .raw, isDefault: true),
            mode("ms", "com.microsoft.*"),
            mode("word", "com.microsoft.word", tier: .cloud(slug: "x")),
        ]
        let resolved = ModeResolver.resolve(bundleID: "com.microsoft.word", modes: modes)
        #expect(resolved.id == "word")
    }

    @Test("Longer literal prefix wins among wildcard matches")
    func longerPrefixWins() {
        let modes = [
            mode("default", nil, isDefault: true),
            mode("broad", "com.*"),
            mode("narrow", "com.microsoft.*"),
        ]
        let resolved = ModeResolver.resolve(bundleID: "com.microsoft.excel", modes: modes)
        #expect(resolved.id == "narrow")
    }

    @Test("No match falls back to the default mode")
    func fallbackToDefault() {
        let modes = [
            mode("default", nil, tier: .raw, isDefault: true),
            mode("mail", "com.apple.mail"),
        ]
        let resolved = ModeResolver.resolve(bundleID: "com.acme.notes", modes: modes)
        #expect(resolved.id == "default")
    }

    @Test("Nil bundle ID falls back to default")
    func nilBundleID() {
        let modes = [mode("default", nil, isDefault: true), mode("mail", "com.apple.mail")]
        #expect(ModeResolver.resolve(bundleID: nil, modes: modes).id == "default")
    }

    @Test("Trailing wildcard matches the prefix")
    func trailingWildcard() {
        let modes = [mode("default", nil, isDefault: true), mode("apple", "com.apple.*")]
        #expect(ModeResolver.resolve(bundleID: "com.apple.mail", modes: modes).id == "apple")
        #expect(ModeResolver.resolve(bundleID: "com.apple", modes: modes).id == "default")
    }

    @Test("Middle wildcard matches around a gap")
    func middleWildcard() {
        let modes = [mode("default", nil, isDefault: true), mode("mid", "com.*.mail")]
        #expect(ModeResolver.resolve(bundleID: "com.apple.mail", modes: modes).id == "mid")
        #expect(ModeResolver.resolve(bundleID: "com.apple.notes", modes: modes).id == "default")
    }

    @Test("Empty modes returns the raw fallback (total function)")
    func emptyModes() {
        let resolved = ModeResolver.resolve(bundleID: "com.apple.mail", modes: [])
        #expect(resolved.cleanupTier == .raw)
    }
}
