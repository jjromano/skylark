import Foundation
import Testing
import SkylarkCore

/// Per-mode custom cleanup instruction (schema v6) — PRD Appendix A's
/// "user-defined custom mode prompts UI", the last open v1-backlog item.
///
/// The load-bearing property is that a mode WITHOUT an instruction produces a
/// byte-identical prompt to the pre-v6 build, so adding the feature cannot move
/// the cleanup eval baselines (13/17 Apple, 15/17 Qwen 4B as of the 17-example
/// corpus; the corpus grew to 29 at v0.16.0, floors pending re-base on the Air).
@Suite("Custom mode prompt")
struct CustomModePromptTests {

    // MARK: - Sanitizing

    @Test("Empty and whitespace-only instructions read back as nil")
    func emptyIsNil() {
        #expect(DictationMode.sanitizeCustomPrompt(nil) == nil)
        #expect(DictationMode.sanitizeCustomPrompt("") == nil)
        #expect(DictationMode.sanitizeCustomPrompt("   \n\t  ") == nil)
    }

    @Test("Surrounding whitespace is trimmed")
    func trims() {
        #expect(DictationMode.sanitizeCustomPrompt("  keep it terse \n") == "keep it terse")
    }

    @Test("Over-long instructions are clamped to the limit, not rejected")
    func clampsToLimit() {
        let long = String(repeating: "a", count: DictationMode.customPromptLimit + 250)
        let sanitized = DictationMode.sanitizeCustomPrompt(long)
        #expect(sanitized?.count == DictationMode.customPromptLimit)
    }

    @Test("A prompt exactly at the limit is untouched")
    func exactLimitUntouched() {
        let exact = String(repeating: "b", count: DictationMode.customPromptLimit)
        #expect(DictationMode.sanitizeCustomPrompt(exact) == exact)
    }

    // MARK: - Prompt construction

    @Test("No instruction leaves both prompts byte-identical to the plain build")
    func absentInstructionChangesNothing() {
        let plain = CleanupContext(registerHint: "email")
        let explicitlyEmpty = CleanupContext(registerHint: "email", customInstruction: "   ")

        #expect(CleanupPrompt.instructions(context: plain)
            == CleanupPrompt.instructions(context: explicitlyEmpty))
        #expect(CleanupPrompt.compactInstructions(context: plain)
            == CleanupPrompt.compactInstructions(context: explicitlyEmpty))
        #expect(!CleanupPrompt.instructions(context: plain).contains("<mode_instruction>"))
    }

    @Test("The instruction is fenced and present in the cloud prompt")
    func cloudPromptCarriesInstruction() {
        let context = CleanupContext(customInstruction: "keep bullet points on separate lines")
        let prompt = CleanupPrompt.instructions(context: context)

        #expect(prompt.contains("<mode_instruction>"))
        #expect(prompt.contains("</mode_instruction>"))
        #expect(prompt.contains("keep bullet points on separate lines"))
        // The precedence rule must travel with it, or the fence is decoration.
        #expect(prompt.contains("NEVER overrides the rules above"))
    }

    @Test("The instruction is fenced and present in the local prompt")
    func localPromptCarriesInstruction() {
        let context = CleanupContext(customInstruction: "use British spelling")
        let prompt = CleanupPrompt.compactInstructions(context: context)

        #expect(prompt.contains("<mode_instruction>"))
        #expect(prompt.contains("use British spelling"))
    }

    @Test("The prompt builder clamps an over-long instruction too")
    func promptClampsOverLongInstruction() {
        let long = String(repeating: "c", count: DictationMode.customPromptLimit + 100)
        let prompt = CleanupPrompt.instructions(context: CleanupContext(customInstruction: long))

        #expect(!prompt.contains(long))
        #expect(prompt.contains(String(repeating: "c", count: DictationMode.customPromptLimit)))
    }

    // MARK: - Context plumbing

    @Test("Both context copy helpers carry the instruction through")
    func copyHelpersPreserveInstruction() {
        let context = CleanupContext(
            dictionaryTerms: ["Skylark", "Parakeet"],
            customInstruction: "no exclamation marks"
        )

        #expect(context.withDictionaryTerms(["Skylark"]).customInstruction == "no exclamation marks")
        #expect(context.withFieldContext(nil).customInstruction == "no exclamation marks")
    }

    // MARK: - Model plumbing

    @Test("Mode -> record -> mode round-trips the instruction")
    func adapterRoundTrip() {
        let mode = DictationMode(
            id: "m1",
            name: "Mail",
            bundleIDPattern: "com.apple.mail",
            cleanupTier: .local,
            customPrompt: "sign off with 'Thanks, JJ'"
        )

        let record = ModeProviderAdapter.toRecord(mode)
        #expect(record.customPrompt == "sign off with 'Thanks, JJ'")

        let back = ModeProviderAdapter.toDictationMode(record)
        #expect(back.customPrompt == "sign off with 'Thanks, JJ'")
        #expect(back.sanitizedCustomPrompt == "sign off with 'Thanks, JJ'")
    }

    @Test("A mode with no instruction resolves to nil, not an empty string")
    func absentRoundTripsAsNil() {
        let mode = DictationMode(id: "m2", name: "Plain", bundleIDPattern: nil, cleanupTier: .local)
        #expect(mode.sanitizedCustomPrompt == nil)
        #expect(ModeProviderAdapter.toRecord(mode).customPrompt == nil)
    }

    @Test("ModeRecord sanitizes at construction, so a padded write cannot reach the DB")
    func recordSanitizesOnInit() {
        let record = ModeRecord(
            id: "m3",
            name: "Padded",
            cleanupTier: .local,
            customPrompt: "  spaced out  ",
            isDefault: false
        )
        #expect(record.customPrompt == "spaced out")
    }
}
