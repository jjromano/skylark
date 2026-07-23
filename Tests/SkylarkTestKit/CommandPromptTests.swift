import Testing
import SkylarkCore

@Suite("CommandPrompt assembly")
struct CommandPromptTests {
    @Test("With a selection: the selection is fenced as data in the user message")
    func selectionFenced() {
        let user = CommandPrompt.userMessage(
            instruction: "make this shorter and friendlier",
            selection: "We regret to inform you that your request has been denied."
        )
        #expect(user.contains("<selection>"))
        #expect(user.contains("</selection>"))
        #expect(user.contains("We regret to inform you"))
        #expect(user.contains("Instruction: make this shorter and friendlier"))
    }

    @Test("With a selection: the system prompt treats the selection as data, not instructions")
    func selectionSystemPromptIsDataNotInstructions() {
        let system = CommandPrompt.systemPrompt(hasSelection: true)
        #expect(system.contains("DATA"))
        // The unclear/cannot-apply rule → echo the original selection unchanged.
        let lower = system.lowercased()
        #expect(lower.contains("unclear") || lower.contains("cannot be applied"))
        #expect(lower.contains("unchanged"))
        // Output-only discipline (no commentary).
        #expect(system.contains("ONLY"))
    }

    @Test("No selection: no fence, and the system prompt is the generate variant")
    func noSelectionVariant() {
        let user = CommandPrompt.userMessage(instruction: "write a polite decline", selection: nil)
        #expect(!user.contains("<selection>"))
        #expect(user.contains("Instruction: write a polite decline"))

        let system = CommandPrompt.systemPrompt(hasSelection: false)
        #expect(system.lowercased().contains("generate"))
        #expect(system.contains("ONLY"))
    }

    @Test("Empty selection string is treated as no selection")
    func emptySelectionIsNoSelection() {
        let user = CommandPrompt.userMessage(instruction: "do the thing", selection: "")
        #expect(!user.contains("<selection>"))
    }

    @Test("Response-token budget ≈ 2× selection + 512 floor")
    func tokenBudget() {
        // No selection → the 512 floor still gives room to generate.
        #expect(CommandPrompt.maxResponseTokens(selection: nil) == 512)
        #expect(CommandPrompt.maxResponseTokens(selection: "") == 512)
        // ~40 chars ≈ 10 tokens → 2×10 + 512 = 532.
        let forty = String(repeating: "a", count: 40)
        #expect(CommandPrompt.maxResponseTokens(selection: forty) == 532)
    }
}
