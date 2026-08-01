import AppKit
import Testing
import SkylarkCore

/// Honest insertion outcomes: posted ≠ landed (P1-9), and a command-mode
/// replacement with an unverifiable anchor never pastes (P1-5).
@Suite("Injection outcomes")
struct InjectionOutcomeTests {
    // MARK: - P1-9: posted vs read

    /// Posting Cmd-V is not evidence. Until the target reads the pasteboard the
    /// token must report uncertainty, so press-Return gating and history don't
    /// record a paste that never landed.
    @Test("A merely-posted paste is uncertain")
    func postedIsUncertain() {
        let token = InsertionToken(method: .paste, text: "hello", landing: .posted)
        #expect(token.pasteUncertain)
    }

    @Test("A read-confirmed paste is certain")
    func readConfirmedIsCertain() {
        let token = InsertionToken(method: .paste, text: "hello", landing: .readConfirmed)
        #expect(!token.pasteUncertain)
    }

    @Test("A keystroke that never went out is uncertain (text left on clipboard)")
    func notPostedIsUncertain() {
        let token = InsertionToken(method: .paste, text: "hello", landing: .notPosted)
        #expect(token.pasteUncertain)
    }

    @Test("An AX write verified by read-back is certain")
    func axVerifiedIsCertain() {
        let token = InsertionToken(method: .ax(AXUIElementCreateSystemWide()), text: "hello", landing: .axVerified)
        #expect(!token.pasteUncertain)
    }

    /// The legacy Bool initializer (test doubles, orchestrator fakes) keeps its
    /// old meaning exactly.
    @Test("Bool initializer maps to the equivalent landing")
    func boolInitMapping() {
        #expect(InsertionToken(method: .paste, text: "t", pasteUncertain: false).landing == .readConfirmed)
        #expect(InsertionToken(method: .paste, text: "t", pasteUncertain: true).landing == .notPosted)
        #expect(InsertionToken(method: .ax(AXUIElementCreateSystemWide()), text: "t", pasteUncertain: false).landing == .axVerified)
        #expect(InsertionToken(method: .paste, text: "t", pasteUncertain: true).pasteUncertain)
    }

    /// A token with no read signal (AX path, or any hand-built token) resolves
    /// immediately to what it already knows — awaiting it can never hang.
    @Test("confirmedLanding on a signal-less token returns its own landing")
    func confirmedLandingWithoutSignal() async {
        let posted = InsertionToken(method: .paste, text: "t", landing: .posted)
        #expect(await posted.confirmedLanding() == .posted)
        let ax = InsertionToken(method: .ax(AXUIElementCreateSystemWide()), text: "t", landing: .axVerified)
        #expect(await ax.confirmedLanding() == .axVerified)
    }

    // MARK: - P1-5: stale-anchor abort

    /// A selection with no AX anchor cannot be verified against the live one, so
    /// the paste fallback is refused rather than typing over whatever happens to
    /// be selected now. Headless-safe: the guard returns before any AX or
    /// clipboard work.
    @Test("Command replace with no anchor aborts instead of pasting")
    @MainActor
    func unanchoredSelectionAborts() async {
        let injector = TextInjector(executor: FailingPasteExecutor())
        let selection = CommandSelection(text: "the user's paragraph")
        #expect(await injector.replaceSelectionOutcome(selection, with: "rewritten") == .anchorStale)
        #expect(await injector.replaceSelection(selection, with: "rewritten") == false)
    }

    /// Injectors that only implement the Bool variant still work; they just
    /// can't tell the caller WHICH failure it was.
    @Test("Default outcome bridge maps Bool to replaced/failed")
    func defaultOutcomeBridge() async {
        let ok = BoolOnlyInjector(result: true)
        #expect(await ok.replaceSelectionOutcome(CommandSelection(text: "a"), with: "b") == .replaced)
        let bad = BoolOnlyInjector(result: false)
        #expect(await bad.replaceSelectionOutcome(CommandSelection(text: "a"), with: "b") == .failed)
    }
}

/// Never synthesizes a paste — asserts the abort happens before any keystroke.
private struct FailingPasteExecutor: PasteExecutor {
    @MainActor func synthesizePaste() async -> Bool {
        Issue.record("paste synthesized despite an unverifiable selection anchor")
        return false
    }
}

private struct BoolOnlyInjector: TextInjecting {
    let result: Bool
    func insert(_ text: String) async throws -> InsertionToken {
        InsertionToken(method: .paste, text: text, landing: .readConfirmed)
    }
    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { false }
    func replaceSelection(_ selection: CommandSelection, with text: String) async -> Bool { result }
}
