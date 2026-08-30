import Testing
import Foundation
@testable import SkylarkCore

@Suite("Groq credential separation")
struct GroqCredentialSeparationTests {
    @Test("The Groq key lives in its own Keychain item, never the OpenRouter one")
    func accountsAreDistinct() {
        // If these ever collapse to one item, switching speech engines would
        // send the user's OpenRouter key to Groq (and vice versa).
        #expect(KeychainStore.groqAccount != KeychainStore.openRouterAccount)
        #expect(KeychainStore.groqAccount == "groq-api-key")
        #expect(KeychainStore.openRouterAccount == "openrouter-api-key")
    }

    @Test("groqDirect round-trips through UserDefaults serialization")
    func choiceRoundTrips() {
        #expect(STTChoice.groqDirect.serialized == "groqDirect")
        #expect(STTChoice(serialized: "groqDirect") == .groqDirect)
        // Unknown values still fall back to the safe local default rather than
        // silently selecting a cloud engine.
        #expect(STTChoice(serialized: "nonsense") == .localParakeet)
        #expect(STTChoice(serialized: nil) == .localParakeet)
    }

    @Test("groqDirect counts as cloud, so the privacy and warm-fallback rules apply")
    func groqIsCloud() {
        #expect(!STTChoice.groqDirect.isLocal)
        // A cloud selection must keep a local engine warm to fall back to.
        #expect(STTChoice.groqDirect.warmLocalEngine() == .localParakeet)
        #expect(STTChoice.groqDirect.warmLocalEngine(cloudFallback: .localApple) == .localApple)
    }
}
