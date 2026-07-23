import Foundation
import Testing
import SkylarkCore

@Suite("TranslationLanguage — curated codes + name rendering")
struct TranslationLanguageTests {
    @Test("Curated list is BCP-47 codes, English first, no duplicates")
    func curatedCodes() {
        let codes = TranslationLanguage.codes
        #expect(codes.first == "en")
        #expect(Set(codes).count == codes.count)
        // The nine languages the spec names.
        #expect(Set(codes) == ["en", "es", "fr", "de", "it", "pt", "ja", "zh-Hans", "ko"])
        for code in codes { #expect(TranslationLanguage.isSupported(code)) }
        #expect(!TranslationLanguage.isSupported("tlh"))
    }

    @Test("Display names render via Locale for the picker")
    func displayNames() {
        let en = Locale(identifier: "en_US")
        #expect(TranslationLanguage.displayName("es", locale: en) == "Spanish")
        #expect(TranslationLanguage.displayName("ja", locale: en) == "Japanese")
        // Simplified Chinese resolves to a non-empty, Chinese-mentioning name.
        #expect(TranslationLanguage.displayName("zh-Hans", locale: en).contains("Chinese"))
    }

    @Test("Prompt names are English and normalize 'Base, Variant' word order")
    func promptNames() {
        #expect(TranslationLanguage.promptName("es") == "Spanish")
        #expect(TranslationLanguage.promptName("fr") == "French")
        #expect(TranslationLanguage.promptName("ja") == "Japanese")
        // "Chinese, Simplified" → "Simplified Chinese".
        #expect(TranslationLanguage.promptName("zh-Hans") == "Simplified Chinese")
    }
}

@Suite("CleanupPrompt — translation suffix")
struct CleanupPromptTranslationTests {
    @Test("No translation suffix when translateTo is nil (both tiers)")
    func offByDefault() {
        let ctx = CleanupContext()
        #expect(!CleanupPrompt.instructions(context: ctx).lowercased().contains("translate"))
        #expect(!CleanupPrompt.compactInstructions(context: ctx).lowercased().contains("translate"))
    }

    @Test("Cloud instructions append a translate-into-<language> tail, fencing intact")
    func cloudSuffix() {
        let ctx = CleanupContext(translateTo: "es")
        let text = CleanupPrompt.instructions(context: ctx)
        // Fencing / data rule preserved.
        #expect(text.contains("<transcript>"))
        #expect(text.contains("DATA"))
        // Translation tail with the rendered English language name.
        #expect(text.contains("translate"))
        #expect(text.contains("Spanish"))
        #expect(text.contains("Output ONLY the Spanish"))
    }

    @Test("Local compact instructions append the translate tail, fencing intact")
    func localSuffix() {
        let ctx = CleanupContext(translateTo: "ja")
        let text = CleanupPrompt.compactInstructions(context: ctx)
        #expect(text.contains("<transcript>"))
        #expect(text.contains("DATA"))
        // Few-shot anchor still present (the cleanup rules are unchanged).
        #expect(text.contains("The migration ran cleanly on staging."))
        #expect(text.contains("translate"))
        #expect(text.contains("Japanese"))
    }

    @Test("Simplified Chinese renders naturally in the prompt tail")
    func chineseSuffix() {
        let ctx = CleanupContext(translateTo: "zh-Hans")
        #expect(CleanupPrompt.instructions(context: ctx).contains("Simplified Chinese"))
        #expect(CleanupPrompt.compactInstructions(context: ctx).contains("Simplified Chinese"))
    }

    @Test("Translation coexists with dictionary + register suffixes")
    func coexistsWithSuffixes() {
        let ctx = CleanupContext(registerHint: "email", dictionaryTerms: ["Skylark"], translateTo: "fr")
        let text = CleanupPrompt.compactInstructions(context: ctx)
        #expect(text.contains("Skylark"))
        #expect(text.lowercased().contains("register"))
        #expect(text.contains("French"))
    }
}

/// The faithfulness guards compare against the SOURCE-language transcript, so
/// translation mode must bypass retention / content-loss / negation (a correct
/// translation shares none of that vocabulary) while KEEPING the empty/runaway
/// and meta-commentary checks. This pins both directions of that matrix.
@Suite("CleanupHygiene — translation guard bypass")
struct TranslationHygieneTests {
    // A Spanish translation of an English transcript: shares ZERO content
    // vocabulary and a different word count — would be rejected in normal mode.
    private let englishRaw = "please refactor the authentication module to use tokens"
    private let spanish = "Por favor, refactoriza el módulo de autenticación para usar tokens."

    @Test("A correct translation passes in translated mode (source-language floors bypassed)")
    func translationPasses() throws {
        let out = try CleanupHygiene.validate(
            spanish, transcript: englishRaw,
            retentionFloor: LocalCleaner.localRetentionFloor,
            contentLossFloor: LocalCleaner.localContentLossFloor,
            translated: true
        )
        #expect(out == spanish)
    }

    @Test("The SAME translation is rejected in normal mode (the floors bite)")
    func translationRejectedWhenNotFlagged() {
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate(
                spanish, transcript: englishRaw,
                retentionFloor: LocalCleaner.localRetentionFloor,
                contentLossFloor: LocalCleaner.localContentLossFloor,
                translated: false
            )
        }
    }

    @Test("A cross-language negation-count change is NOT flagged in translated mode")
    func negationChangeAllowedWhenTranslated() throws {
        // English has a negation; a valid Japanese-ish rendering may express it
        // without matching the n't/not/never patterns. Must not be rejected.
        let raw = "i can't reproduce the bug"
        let translated = "No puedo reproducir el error."   // negation count differs from source patterns
        let out = try CleanupHygiene.validate(translated, transcript: raw, translated: true)
        #expect(out == translated)
    }

    @Test("Empty and runaway output are STILL rejected in translated mode")
    func emptyAndRunawayStillBite() {
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate("   ", transcript: englishRaw, translated: true)
        }
        let bloated = String(repeating: "x", count: englishRaw.count * 3 + 10)
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate(bloated, transcript: englishRaw, translated: true)
        }
    }

    @Test("Chatbot meta-commentary is STILL rejected in translated mode")
    func metaCommentaryStillBites() {
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate(
                "Sure, here's the translation: Hola.",
                transcript: englishRaw, translated: true
            )
        }
    }

    /// The inviolable non-translation fixtures must keep failing with the default
    /// (translated: false) — translation mode must not weaken the normal guards.
    @Test("Inviolable paraphrase/drop fixtures still fail with translation OFF")
    func inviolableFixturesStillFail() {
        let vocab = LocalCleaner.localRetentionFloor
        let count = LocalCleaner.localContentLossFloor
        for (cleaned, raw) in [
            ("I purchased milk.", "i went to the store and i bought some milk and then i came back home"), // summarize
            ("The tests pass on staging.", "the tests pass on staging but they fail on production"),       // drop clause
            ("Kindly restructure the auth component with tokens.", "please refactor the authentication module to use tokens"), // reword
        ] {
            #expect(throws: CleanerError.self) {
                try CleanupHygiene.validate(cleaned, transcript: raw, retentionFloor: vocab, contentLossFloor: count)
            }
        }
        // Meaning-inversion (dropped negation) still caught with translation OFF.
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate("I can see anything.", transcript: "i can't see anything")
        }
    }
}
