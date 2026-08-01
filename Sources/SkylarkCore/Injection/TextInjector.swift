import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

// Adapted from Hex (MIT): Clients/PasteboardClient.swift (AX insertion, Cmd-V,
// changeCount polling). Injection order is deliberately inverted vs Hex
// (AX-first) per ARCHITECTURE §3.

/// How text was inserted — Phase 2 uses this for in-place replacement.
public struct InsertionToken: @unchecked Sendable, Equatable {
    public enum Method: @unchecked Sendable {
        case ax(AXUIElement)
        case paste
    }

    /// How far the insertion actually got. Posting Cmd-V is NOT evidence that
    /// anything landed (P1-9): the events go to the HID tap and a target that
    /// ignores them leaves the caret empty while we happily record success —
    /// and the restore ceiling then takes the transcript back off the clipboard,
    /// so the only copy outside History is gone. `.posted` is the honest state
    /// at the moment `insert` returns; `confirmedLanding()` upgrades it to
    /// `.readConfirmed` once the target reads our pasteboard promise.
    public enum PasteLanding: Sendable, Equatable {
        /// AX write, verified by read-back. No clipboard involved.
        case axVerified
        /// Cmd-V posted AND the target read the pasteboard: the text landed.
        case readConfirmed
        /// Cmd-V posted, no target read (yet). May never have landed.
        case posted
        /// The keystroke could not be synthesized; text left on the clipboard
        /// as the user's manual fallback (deliberately NOT restored).
        case notPosted
    }

    public let method: Method
    /// The exact text inserted, including any smart-spacing separator prefix —
    /// this is what sits on screen, so the in-place replace matches against it.
    public let text: String
    /// The smart-spacing separator (`""` or `" "`) prepended at insertion, kept
    /// so an in-place cleanup replace re-applies the same prefix.
    public let leadingSeparator: String
    /// What we actually know about the insertion at the time this token was made.
    public let landing: PasteLanding
    /// The AX range the inserted run occupied at insertion time (AX path only).
    /// The in-place cleanup replace anchors here instead of re-deriving the
    /// range from the LIVE caret, which would follow the user's cursor onto an
    /// older identical phrase (audit U3).
    let axRange: CFRange?
    /// Resolves the paste landing asynchronously (nil for AX/synthetic tokens).
    let landingSignal: PasteLandingSignal?

    /// True when the insertion is not known to have landed; for the `.notPosted`
    /// case the text was left on the clipboard as the user's fallback.
    /// Conservative by construction: a merely-posted paste counts as uncertain.
    public var pasteUncertain: Bool { landing == .posted || landing == .notPosted }

    public init(method: Method, text: String, leadingSeparator: String = "", pasteUncertain: Bool) {
        self.method = method
        self.text = text
        self.leadingSeparator = leadingSeparator
        // Source-compatible mapping for callers/test doubles that only know the
        // Bool: certain + AX = verified write, certain + paste = the target read
        // it, uncertain = the keystroke never went out.
        switch (method, pasteUncertain) {
        case (_, true): landing = .notPosted
        case (.ax, false): landing = .axVerified
        case (.paste, false): landing = .readConfirmed
        }
        axRange = nil
        landingSignal = nil
    }

    /// Honest form: state exactly what is known about the insertion.
    public init(method: Method, text: String, leadingSeparator: String = "", landing: PasteLanding) {
        self.init(method: method, text: text, leadingSeparator: leadingSeparator, landing: landing, axRange: nil, landingSignal: nil)
    }

    /// Full form (module-internal: `axRange`/`landingSignal` are implementation
    /// detail). No defaults on the last two, so a 4-argument call unambiguously
    /// resolves to the public initializer above.
    init(
        method: Method,
        text: String,
        leadingSeparator: String = "",
        landing: PasteLanding,
        axRange: CFRange?,
        landingSignal: PasteLandingSignal?
    ) {
        self.method = method
        self.text = text
        self.leadingSeparator = leadingSeparator
        self.landing = landing
        self.axRange = axRange
        self.landingSignal = landingSignal
    }

    /// The landing once the evidence is in: awaits the target's pasteboard read
    /// (resolved on read, on the restore ceiling, or on teardown — never hangs).
    /// Off the latency path by design: `insert` returns before this resolves, so
    /// only callers that need the truth (history, command-mode replace) pay for
    /// it. Immediate callers (press-Return) must NOT await it.
    public func confirmedLanding() async -> PasteLanding {
        guard let landingSignal else { return landing }
        return await landingSignal.value()
    }

    public static func == (lhs: InsertionToken, rhs: InsertionToken) -> Bool {
        guard lhs.text == rhs.text, lhs.leadingSeparator == rhs.leadingSeparator, lhs.pasteUncertain == rhs.pasteUncertain else { return false }
        switch (lhs.method, rhs.method) {
        case (.paste, .paste): return true
        case let (.ax(a), .ax(b)): return CFEqual(a, b)
        default: return false
        }
    }
}

/// A snapshot of the current AX selection for Voice Command Mode. Carries the
/// selected `text` (the DATA a spoken instruction rewrites) plus the AX handle
/// needed to replace exactly that range verifiably. When the AX handle is nil
/// the caller falls back to a clipboard paste over the live selection.
public struct CommandSelection: @unchecked Sendable, Equatable {
    /// The currently selected text.
    public let text: String
    /// AX element + range for verified in-place replacement (nil in tests or
    /// when the selection was captured without a replaceable handle).
    let element: AXUIElement?
    let range: CFRange?
    /// Who owned the selection when it was captured. Part of the anchor: a paste
    /// fallback is only safe while the same app in the same field still holds the
    /// same selected range (P1-5).
    let bundleID: String?
    let pid: pid_t

    /// Public initializer (no AX anchor) — used by tests and any caller that
    /// only carries the selection text. Without an anchor there is nothing to
    /// verify against, so replacement refuses rather than pasting blind.
    public init(text: String) {
        self.text = text
        self.element = nil
        self.range = nil
        self.bundleID = nil
        self.pid = 0
    }

    init(text: String, element: AXUIElement, range: CFRange, bundleID: String?, pid: pid_t) {
        self.text = text
        self.element = element
        self.range = range
        self.bundleID = bundleID
        self.pid = pid
    }

    public static func == (lhs: CommandSelection, rhs: CommandSelection) -> Bool {
        guard lhs.text == rhs.text else { return false }
        switch (lhs.element, rhs.element) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b) && lhs.range?.location == rhs.range?.location && lhs.range?.length == rhs.range?.length
        default: return false
        }
    }
}

/// Why a Voice Command Mode replacement did or didn't happen. `replaceSelection`
/// flattens this to a Bool for existing callers; the distinction exists because
/// "the anchor moved" needs a DIFFERENT user-visible note from "the write
/// failed" — in the stale case the command result was deliberately not applied
/// anywhere, and the user must be told which of their text is untouched.
public enum SelectionReplaceOutcome: Sendable, Equatable {
    /// The captured selection was replaced (AX-verified, or pasted over the
    /// still-matching selection).
    case replaced
    /// The captured selection is no longer what's selected (focus, field, range
    /// or text changed). Nothing was written. Suggested note:
    /// "Selection changed — command result not applied".
    case anchorStale
    /// The anchor still matched but the write itself didn't land.
    case failed
}

/// Inserts text at the cursor (ARCHITECTURE §2).
public protocol TextInjecting: Sendable {
    func insert(_ text: String) async throws -> InsertionToken
    func replace(_ token: InsertionToken, with text: String) async throws
    /// Read the current AX selection (Voice Command Mode). Returns the selected
    /// text plus a handle for verified replacement, or nil when there is no
    /// readable selection — the caller then treats it as "no selection" and
    /// inserts the command result at the cursor instead.
    func readSelection() async -> CommandSelection?
    /// Replace a previously-read selection with `text`, verified by read-back;
    /// falls back to a clipboard-preserving paste ONLY while the captured
    /// selection is provably still the live one. Returns true when the
    /// replacement landed. On false the caller surfaces a failure and leaves the
    /// selection as-is.
    func replaceSelection(_ selection: CommandSelection, with text: String) async -> Bool
    /// As `replaceSelection`, but says WHY it failed so the caller can tell the
    /// user the difference between "your selection moved, nothing was applied"
    /// and "the write failed".
    func replaceSelectionOutcome(_ selection: CommandSelection, with text: String) async -> SelectionReplaceOutcome
    /// Whether the focused element supports precise AX insertion right now. The
    /// orchestrator probes this at paste time to pick the cleanup strategy
    /// (in-place replace vs. wait-for-clean).
    func canInsertDirectly() async -> Bool
    /// ATTEMPT an AX-verified in-place insert: returns a replaceable token when
    /// the write actually landed (read-back verified), or nil — having inserted
    /// NOTHING — when it didn't. The orchestrator routes its cleanup strategy
    /// on this real outcome, because capability probes lie: Chrome claims
    /// writable selection attributes but silently drops AX writes.
    func insertDirect(_ text: String) async throws -> InsertionToken?
    /// Synthesize a Return keystroke (spoken "press enter" command). Call only
    /// after `insert` has returned so the keystroke lands after the text.
    func pressReturn() async
}

public extension TextInjecting {
    /// Default no-op so test doubles and simple injectors need not implement it.
    func pressReturn() async {}

    /// Default preserves the legacy probe-then-insert behavior for test doubles
    /// and simple injectors: probe says yes → full insert; else nil.
    func insertDirect(_ text: String) async throws -> InsertionToken? {
        if await canInsertDirectly() {
            return try await insert(text)
        }
        return nil
    }

    /// Default: no readable selection (simple doubles report "nothing selected",
    /// so command mode inserts at the cursor).
    func readSelection() async -> CommandSelection? { nil }

    /// Default: replacement unsupported for simple doubles.
    func replaceSelection(_ selection: CommandSelection, with text: String) async -> Bool { false }

    /// Default: defer to the Bool variant (doubles that only implement that one
    /// keep working; they just can't distinguish stale from failed).
    func replaceSelectionOutcome(_ selection: CommandSelection, with text: String) async -> SelectionReplaceOutcome {
        await replaceSelection(selection, with: text) ? .replaced : .failed
    }
}

/// Posts a real Cmd-V (or an injected substitute in tests).
public protocol PasteExecutor: Sendable {
    /// Returns true if the paste keystroke was successfully synthesized/posted.
    @MainActor func synthesizePaste() async -> Bool
}

/// Live Cmd-V executor: explicit Cmd down, layout-resolved V down/up, Cmd up.
public struct CmdVPasteExecutor: PasteExecutor {
    public init() {}

    @MainActor
    public func synthesizePaste() async -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKey = KeyboardLayout.keyCode(for: "v")
        let cmdKey: CGKeyCode = 55
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else {
            return false
        }
        // Set flags EXPLICITLY on every event so a modifier still physically held
        // at paste time (e.g. a hotkey key) can't merge in and corrupt the chord
        // into ⌘⇧V etc. cmdUp clears to no modifiers.
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []
        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }
}

public enum InjectionError: Error, Sendable {
    /// In-place replacement isn't available for paste-inserted text; the
    /// orchestrator handles paste targets with wait-for-clean instead.
    case replaceUnsupported
    /// An AX in-place replace didn't land (range no longer matched / the app
    /// dropped the write) — raw text still stands, so the caller must not record
    /// the clean text as applied.
    case replaceFailed
}

/// AX-first text injection with a clipboard-preserving paste fallback.
@MainActor
public final class TextInjector: TextInjecting {
    private let executor: PasteExecutor
    private let signposter = OSSignposter(subsystem: "com.jjromano.skylark", category: "injection")
    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "injection")

    // Smart-spacing memory for targets we can't read back (Chrome/Electron):
    // the pid of the last field we inserted into and whether that insertion
    // ended on whitespace. Lets consecutive dictations into the same web field
    // get a separating space even though we can't inspect its contents.
    private var lastInsertPid: pid_t = 0
    private var lastInsertEndedWithWhitespace = true

    /// The most recent paste's clipboard-restore coordinator, kept alive until it
    /// restores (it also owns the pasteboard data provider, which the pasteboard
    /// item only references weakly). Flushed at the start of the next paste.
    private var pendingRestore: PasteRestoreCoordinator?

    public init(executor: PasteExecutor = CmdVPasteExecutor()) {
        self.executor = executor
    }

    /// Synthesize a Return keyDown/keyUp to the same destination the paste path
    /// posts to (`.cghidEventTap`), for the spoken "press enter" command. No
    /// clipboard involvement.
    ///
    /// Call this only *after* `insert` has returned. On the AX path the write is
    /// synchronous, so the text is already in the field. On the paste path
    /// `insert` returns as soon as the Cmd-V events are POSTED — it does not wait
    /// for the target to consume them (that would put the read-signal ceiling on
    /// the dictation latency path). Ordering still holds: both the chord and this
    /// Return go to `.cghidEventTap`, so the target dequeues them in order. What
    /// does NOT hold is that the paste landed at all — if the target ignored the
    /// Cmd-V, this Return submits an empty field. Callers that must not do that
    /// gate on `InsertionToken.confirmedLanding()` first (P1-9).
    /// Posting two CGEvents is fast and non-blocking; it stays off the audio path
    /// because the app layer invokes it on the injection path, never per audio frame.
    ///
    /// Protocol witness — the orchestrator only sees `TextInjecting`, so this
    /// must exist explicitly (the sync Bool variant below can't witness an
    /// async Void requirement, and the default no-op would otherwise win).
    public func pressReturn() async {
        _ = synthesizeReturn()
    }

    /// - Returns: true when both events were synthesized and posted.
    @discardableResult
    public func synthesizeReturn() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let returnKey: CGKeyCode = 36 // kVK_Return
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        else {
            logger.notice("press-return: could not synthesize Return event")
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    public func insert(_ text: String) async throws -> InsertionToken {
        let state = signposter.beginInterval("insert")
        defer { signposter.endInterval("insert", state) }

        Self.logInjectTarget(logger)

        // Smart spacing: prepend a separator so back-to-back dictations don't run
        // together ("one two three" then "four" → "…three four", not "…threefour").
        // Prefers the real character before the caret; for fields we can't read
        // (Chrome/Electron) it falls back to remembering our own last insertion.
        let targetPid = Self.focusedPid()
        let separator = leadingSeparator(targetPid: targetPid)
        let toInsert = separator + text

        // 1) AX-first: real success/failure signal, clipboard untouched. The
        //    write is verified by read-back — Chrome/Electron fields report
        //    `.success` but silently drop the insert, so a bare success is not
        //    trusted (see `insertViaAX`).
        if let landed = Self.insertViaAX(toInsert) {
            rememberInsertion(text: toInsert, pid: targetPid)
            return InsertionToken(
                method: .ax(landed.element),
                text: toInsert,
                leadingSeparator: separator,
                landing: .axVerified,
                axRange: landed.range,
                landingSignal: nil
            )
        }
        // 2) Clipboard-preserving paste fallback (AX unavailable or unconfirmed).
        logger.debug("AX insert unconfirmed; using clipboard paste fallback")
        let token = await performClipboardPaste(toInsert, pasteboard: .general, executor: executor)
        rememberInsertion(text: toInsert, pid: targetPid)
        return token
    }

    /// AX-only insert attempt (protocol `insertDirect`): the verified AX write
    /// or nothing — never the paste fallback. A nil return means NOTHING was
    /// inserted (Chrome-style fields drop the write, which the read-back
    /// verification catches), so the caller can safely wait-for-clean and
    /// paste the final text instead.
    public func insertDirect(_ text: String) async -> InsertionToken? {
        let targetPid = Self.focusedPid()
        let separator = leadingSeparator(targetPid: targetPid)
        let toInsert = separator + text
        Self.logInjectTarget(logger)
        guard let landed = Self.insertViaAX(toInsert) else {
            logger.debug("direct AX insert unconfirmed; caller will wait-for-clean")
            return nil
        }
        rememberInsertion(text: toInsert, pid: targetPid)
        return InsertionToken(
            method: .ax(landed.element),
            text: toInsert,
            leadingSeparator: separator,
            landing: .axVerified,
            axRange: landed.range,
            landingSignal: nil
        )
    }

    /// In-place replacement of the just-inserted range (ARCHITECTURE §3).
    /// AX-inserted text is rewritten precisely; paste-inserted text is
    /// unsupported here (the orchestrator waits-for-clean before pasting).
    public func replace(_ token: InsertionToken, with text: String) async throws {
        switch token.method {
        case .paste:
            throw InjectionError.replaceUnsupported
        case let .ax(element):
            // Re-apply the smart-spacing separator so the cleaned text keeps the
            // leading space the raw insertion had. A false result means the range
            // no longer matched (focus moved, or the app dropped the AX write) —
            // THROW so the caller keeps the "raw kept" note instead of recording
            // the clean text as if it landed (it didn't; raw is still on screen).
            let landed = Self.performAXReplace(
                element: element,
                original: token.text,
                replacement: token.leadingSeparator + text,
                anchor: token.axRange
            )
            if !landed { throw InjectionError.replaceFailed }
        }
    }

    // MARK: - Voice Command Mode selection (read + replace)

    /// Read the current AX selection. Returns non-nil only when there is actual
    /// selected text with a readable range; a bare caret (no selection) or an
    /// unreadable field yields nil so the orchestrator inserts at the cursor.
    public func readSelection() async -> CommandSelection? {
        guard let element = Self.focusedEditableElement() else { return nil }
        guard let range = Self.selectedRange(element), range.length > 0 else { return nil }
        guard let text = Self.string(in: element, range: range), !text.isEmpty else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return CommandSelection(
            text: text,
            element: element,
            range: range,
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            pid: pid
        )
    }

    /// Replace a read selection with `text`. Prefers a verified AX write over the
    /// exact selected range; when that write can't be confirmed it falls back to
    /// a clipboard-preserving Cmd-V — but ONLY while the captured anchor is still
    /// live.
    ///
    /// P1-5: the command runs an LLM between read and write, so seconds pass. A
    /// Cmd-V there types over whatever is selected NOW, which after a click or a
    /// Cmd-A elsewhere is unrelated content the user never asked to rewrite — a
    /// silent destructive edit with no undo affordance we control. Aborting loses
    /// only the command result (still reproducible); pasting loses the user's
    /// document text. So: bundle + pid + element + range + selected text must all
    /// still match, or nothing is written.
    public func replaceSelection(_ selection: CommandSelection, with text: String) async -> Bool {
        await replaceSelectionOutcome(selection, with: text) == .replaced
    }

    public func replaceSelectionOutcome(_ selection: CommandSelection, with text: String) async -> SelectionReplaceOutcome {
        guard let element = selection.element, let range = selection.range else {
            // No anchor was ever captured (hand-built selection): there is
            // nothing to verify against, so a paste would be exactly the blind
            // overwrite this guard exists to prevent.
            logger.notice("command replace aborted: selection carries no AX anchor")
            return .anchorStale
        }
        if Self.axReplaceSelection(element: element, range: range, original: selection.text, replacement: text) {
            return .replaced
        }
        // The AX write was refused or silently dropped (Chrome/Electron), OR the
        // anchor is stale. Only the first justifies pasting over the live
        // selection — distinguish before touching the clipboard.
        guard Self.anchorIsLive(selection) else {
            logger.notice("command replace aborted: selection anchor is stale")
            return .anchorStale
        }
        let token = await performClipboardPaste(text, pasteboard: .general, executor: executor)
        // Honest confirmation (P1-9): a posted Cmd-V the target ignored must not
        // be reported as a landed rewrite. Off the latency path — the command
        // result is already on screen if it landed at all.
        return await token.confirmedLanding() == .readConfirmed ? .replaced : .failed
    }

    /// True when everything the captured selection was anchored to still holds:
    /// same frontmost app, same owning process, same focused element, the same
    /// selected range, and the same text selected. Anything less — or anything
    /// unverifiable — and a Cmd-V would land somewhere the user didn't select.
    ///
    /// The text check reads `kAXSelectedText` first and only then the
    /// parameterized range read: Chrome/Electron fields expose the former but
    /// not the latter, and they are precisely the targets that depend on the
    /// paste fallback, so verifying them via the range read alone would abort
    /// every command-mode rewrite there.
    static func anchorIsLive(_ selection: CommandSelection) -> Bool {
        guard let element = selection.element, let range = selection.range else { return false }
        if let bundleID = selection.bundleID,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID { return false }
        guard let focused = focusedEditableElement(), CFEqual(focused, element) else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        guard selection.pid == 0 || pid == selection.pid else { return false }
        // An unreadable live range is tolerated (some web fields don't publish
        // it); a range that reads back DIFFERENT is a moved selection.
        if let live = selectedRange(element), live.location != range.location || live.length != range.length {
            return false
        }
        guard let live = selectedText(element) ?? string(in: element, range: range) else { return false }
        return live == selection.text
    }

    /// Re-select `range` and overwrite it with `replacement`, verified by
    /// read-back. Returns false (no mutation trusted) if focus moved, the range
    /// no longer holds `original`, or the write didn't land — the caller then
    /// uses the paste fallback.
    static func axReplaceSelection(element: AXUIElement, range: CFRange, original: String, replacement: String) -> Bool {
        guard let focused = focusedEditableElement(), CFEqual(focused, element) else { return false }
        guard let atRange = string(in: element, range: range), atRange == original else { return false }
        guard setSelectedRange(element, range) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
            return false
        }
        // Verify the replacement is actually present at the range we wrote.
        let writtenRange = CFRange(location: range.location, length: utf16Count(replacement))
        guard let readBack = string(in: element, range: writtenRange), readBack == replacement else { return false }
        // Collapse the caret at the end of the replacement.
        _ = setSelectedRange(element, CFRange(location: range.location + utf16Count(replacement), length: 0))
        return true
    }

    /// Whether the focused element supports precise AX insertion **and** the
    /// in-place replace that the "paste raw now, clean later" strategy depends
    /// on. Chrome/Electron fields pass the basic editable probe but can't be
    /// replaced in place (their AX write is silently dropped and the range read
    /// they'd need isn't supported), so this returns false for them and the
    /// orchestrator routes them through the wait-for-clean paste path — which
    /// pastes the already-cleaned (punctuated) text once instead of losing it.
    public func canInsertDirectly() async -> Bool {
        Self.focusedInPlaceElement() != nil
    }

    /// The focused element only if it supports BOTH the parameterized range read
    /// that verify/replace require (`kAXStringForRange`) AND writable selection
    /// attributes. Readability alone is not enough: Terminal exposes its text
    /// for reading but rejects AX writes, so an insert there lands via the
    /// paste fallback and the later in-place replace is impossible — the
    /// orchestrator must treat such targets as paste targets (wait-for-clean)
    /// or the cleaned text is silently dropped.
    static func focusedInPlaceElement() -> AXUIElement? {
        guard let focused = focusedEditableElement() else { return nil }
        var namesRef: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(focused, &namesRef) == .success,
              let names = namesRef as? [String],
              names.contains(kAXStringForRangeParameterizedAttribute as String)
        else {
            return nil
        }
        var selectedTextSettable = DarwinBoolean(false)
        var rangeSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
        AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &rangeSettable)
        guard selectedTextSettable.boolValue, rangeSettable.boolValue else { return nil }
        return focused
    }

    // MARK: - Smart spacing

    /// What sits immediately before the caret in the focused field.
    private enum PrecedingContext {
        case startOfField
        case character(Character)
        /// The field can't be read (Chrome/Electron web fields).
        case unreadable
    }

    /// The separator to prepend before inserting: `" "` when the caret follows a
    /// non-whitespace character, else `""`. For unreadable fields it uses the
    /// remembered tail of our last insertion into the same app.
    private func leadingSeparator(targetPid: pid_t) -> String {
        switch Self.precedingContext() {
        case .startOfField:
            return ""
        case let .character(ch):
            return ch.isWhitespace ? "" : " "
        case .unreadable:
            if targetPid == lastInsertPid, !lastInsertEndedWithWhitespace { return " " }
            return ""
        }
    }

    /// Read the character before the caret in the focused editable element.
    private static func precedingContext() -> PrecedingContext {
        guard let element = focusedEditableElement(),
              let caret = selectedRange(element)
        else {
            return .unreadable
        }
        guard caret.location > 0 else { return .startOfField }
        guard let s = string(in: element, range: CFRange(location: caret.location - 1, length: 1)),
              let ch = s.last
        else {
            return .unreadable
        }
        return .character(ch)
    }

    /// Remember where and how the last insertion ended, for the unreadable-field
    /// spacing fallback.
    private func rememberInsertion(text: String, pid: pid_t) {
        lastInsertPid = pid
        lastInsertEndedWithWhitespace = text.last?.isWhitespace ?? true
    }

    /// The pid owning the current AX focused element (frontmost app as fallback).
    private static func focusedPid() -> pid_t {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef
        else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        }
        var pid: pid_t = 0
        AXUIElementGetPid(focusedRef as! AXUIElement, &pid)
        return pid
    }

    // MARK: - Diagnostics

    /// Log where an injection is about to land — frontmost app bundle id, the
    /// AX focused element's role, and its owning pid. Never logs any text
    /// content (privacy rule); role/bundle/pid only. Debug level so it's off the
    /// persisted log by default but visible in `log stream`.
    private static func logInjectTarget(_ logger: Logger) {
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef
        else {
            logger.debug("inject target: frontmost=\(frontBundle, privacy: .public) focused=<none>")
            return
        }
        let focused = focusedRef as! AXUIElement
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "?"
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        let editable = focusedEditableElement() != nil
        logger.debug("inject target: frontmost=\(frontBundle, privacy: .public) focusedRole=\(role, privacy: .public) focusedPid=\(pid, privacy: .public) axEditable=\(editable, privacy: .public)")
    }

    // MARK: - AX path

    /// The focused element if it answers `kAXValue`/`kAXSelectedText` reads
    /// (i.e. supports direct AX insertion); nil otherwise.
    static func focusedEditableElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef
        else {
            return nil
        }
        // AXUIElementCopyAttributeValue yields an AXUIElement for this attribute.
        let focused = focusedRef as! AXUIElement

        var probe: CFTypeRef?
        let supportsValue = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &probe) == .success
        let supportsSelected = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &probe) == .success
        guard supportsValue || supportsSelected else { return nil }
        return focused
    }

    /// Attempts AX insertion and confirms it by read-back. Returns the focused
    /// element AND the range the text landed in (the anchor a later in-place
    /// replace uses, audit U3) only when the inserted text is verifiably present
    /// at the caret; nil otherwise so the caller falls back to the clipboard paste.
    ///
    /// Chrome, Electron, and some web fields answer `AXUIElementSetAttributeValue`
    /// with `.success` yet never apply the write, so a bare success is not
    /// trustworthy. We re-use the same range read the in-place replace relies on:
    /// a field that can't read our text back at the expected range is treated as
    /// not-landed (paste instead).
    static func insertViaAX(_ text: String) -> (element: AXUIElement, range: CFRange?)? {
        guard let focused = focusedEditableElement() else { return nil }
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            return nil
        }
        guard case let .landed(range) = axInsertLanded(element: focused, insertedText: text) else { return nil }
        return (focused, range)
    }

    /// Whether an AX write is verifiably on screen, and where it went.
    enum AXInsertOutcome: Equatable {
        /// Verified present. `range` is the run's anchor, nil only for an empty
        /// insert (nothing to anchor).
        case landed(range: CFRange?)
        /// Not verifiably present — the caller must paste instead.
        case notLanded

        static func == (lhs: AXInsertOutcome, rhs: AXInsertOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.notLanded, .notLanded): return true
            case let (.landed(a), .landed(b)):
                return a?.location == b?.location && a?.length == b?.length
            default: return false
            }
        }
    }

    /// The range `insertedText` verifiably occupies after an AX set, or nil when
    /// it isn't there. The caret sits collapsed at the end of the inserted run,
    /// so the run occupies `[caret - len, len]`; we read that range back and
    /// compare. Any unreadable attribute (field doesn't support the range read)
    /// → nil, so the caller pastes instead.
    ///
    /// The range is RETURNED (not just validated) because the later in-place
    /// cleanup replace must anchor to where the text actually went, not to
    /// wherever the caret has wandered by then (audit U3). Empty text needs no
    /// verification and has no anchor.
    static func axInsertLanded(element: AXUIElement, insertedText: String) -> AXInsertOutcome {
        let len = utf16Count(insertedText)
        guard len > 0 else { return .landed(range: nil) }
        guard let caret = selectedRange(element),
              let range = candidateRange(caretLocation: caret.location, insertedUTF16Count: len),
              let readBack = string(in: element, range: range),
              readBack == insertedText
        else {
            return .notLanded
        }
        return .landed(range: range)
    }

    // MARK: - In-place replacement (AX)

    /// Precisely replaces the `original` run — the one recorded in `anchor` at
    /// insertion time — with `replacement`. Returns true when the replacement was
    /// applied; false (no mutation) on any mismatch: focus moved, caret math
    /// impossible, or the text at the range isn't what we inserted.
    ///
    /// U3 (audit): deriving the range from the LIVE caret is what made this
    /// rewritable-anywhere. If the user parked the caret at the end of an EARLIER
    /// identical phrase in the same field during the cleanup window, the derived
    /// range landed on that older copy and the content check passed — cleanup
    /// then rewrote text the user never dictated. Anchoring to the range the
    /// insert actually verified removes the caret from the decision entirely; the
    /// caret-derived path survives only for tokens that carry no anchor (test
    /// doubles and any caller that built a token by hand).
    static func performAXReplace(element: AXUIElement, original: String, replacement: String, anchor: CFRange?) -> Bool {
        // 1) Focus must still be the token's element (user hasn't clicked away).
        guard let focused = focusedEditableElement(), CFEqual(focused, element) else { return false }

        // 2) Where our text went. Recorded anchor when we have one; otherwise the
        //    caret (expected collapsed at the end of the inserted text). AX ranges
        //    are UTF-16 code units.
        let liveCaret = selectedRange(element)
        let candidate: CFRange
        if let anchor {
            candidate = anchor
        } else {
            guard let liveCaret,
                  let derived = candidateRange(caretLocation: liveCaret.location, insertedUTF16Count: utf16Count(original))
            else {
                return false
            }
            candidate = derived
        }

        // 3) Verify the candidate range actually holds our inserted text.
        guard let atRange = string(in: element, range: candidate), atRange == original else { return false }

        // 4) Select the range and replace it.
        guard setSelectedRange(element, candidate) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
            return false
        }
        // 5) Put the caret back where the USER had it, shifted by the length
        //    change. Anchoring (step 2) means the replace no longer has to happen
        //    at the caret, so blindly collapsing at the end of the replacement
        //    would now yank a caret the user had moved on — e.g. dictate, keep
        //    typing further down, cleanup lands a second later and steals the
        //    cursor mid-word. Without a readable caret, fall back to the old
        //    end-of-replacement behaviour.
        let target = liveCaret.map {
            caretAfterReplace(
                caret: $0,
                anchor: candidate,
                originalUTF16Count: utf16Count(original),
                replacementUTF16Count: utf16Count(replacement)
            )
        } ?? CFRange(location: candidate.location + utf16Count(replacement), length: 0)
        _ = setSelectedRange(element, target)
        return true
    }

    /// Where the caret belongs after an anchored replace.
    ///
    /// - Caret at or after the end of the replaced run: shift by the length
    ///   delta (the classic "caret sat at the end of the dictation" case lands
    ///   collapsed at the end of the replacement, exactly as before).
    /// - Caret entirely before the run: unchanged — those offsets didn't move.
    /// - Caret overlapping the run (the user selected part of what we rewrote):
    ///   collapse at the end of the replacement; the text it referred to is gone.
    public nonisolated static func caretAfterReplace(
        caret: CFRange,
        anchor: CFRange,
        originalUTF16Count: Int,
        replacementUTF16Count: Int
    ) -> CFRange {
        let runEnd = anchor.location + originalUTF16Count
        if caret.location >= runEnd {
            let delta = replacementUTF16Count - originalUTF16Count
            return CFRange(location: max(0, caret.location + delta), length: caret.length)
        }
        if caret.location + caret.length <= anchor.location { return caret }
        return CFRange(location: anchor.location + replacementUTF16Count, length: 0)
    }

    // MARK: - Range math (pure, unit-tested)

    /// Number of UTF-16 code units — the unit AX text ranges use.
    public nonisolated static func utf16Count(_ text: String) -> Int { text.utf16.count }

    /// The range the inserted text occupies, given the caret sits at its end.
    /// nil when the math underflows (caret before the inserted text).
    public nonisolated static func candidateRange(caretLocation: Int, insertedUTF16Count: Int) -> CFRange? {
        let start = caretLocation - insertedUTF16Count
        guard start >= 0, insertedUTF16Count >= 0 else { return nil }
        return CFRange(location: start, length: insertedUTF16Count)
    }

    // MARK: - AX getters/setters

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The live selected text, via the plain (non-parameterized) attribute that
    /// even web fields support. Empty selection reads as nil.
    private static func selectedText(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref) == .success,
              let text = ref as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func string(in element: AXUIElement, range: CFRange) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &ref
        ) == .success else { return nil }
        return ref as? String
    }

    private static func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    // MARK: - Paste path (testable choreography)

    /// snapshot → write promise → poll changeCount → paste → restore when the
    /// target READS (or the fallback ceiling fires).
    /// Exposed for unit tests with an injected `PasteExecutor` and short delays.
    @MainActor
    func performClipboardPaste(
        _ text: String,
        pasteboard: NSPasteboard,
        executor: PasteExecutor,
        pollInterval: Duration = .milliseconds(5),
        pollCap: Duration = .milliseconds(150),
        readGrace: Duration = .milliseconds(100),
        fallbackRestore: Duration = .milliseconds(500)
    ) async -> InsertionToken {
        // A previous paste's restore may still be pending (two dictations inside
        // the fallback window). Flush it BEFORE snapshotting, or this snapshot
        // captures the PREVIOUS transcript as "the user's clipboard" and hands it
        // back at the end.
        pendingRestore?.supersede()
        pendingRestore = nil

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let restore = PasteRestoreCoordinator(
            snapshot: snapshot,
            pasteboard: pasteboard,
            readGrace: readGrace,
            fallback: fallbackRestore,
            logger: logger
        )

        let before = pasteboard.changeCount
        pasteboard.clearContents()
        // The transcript is a PROMISE (lazy data provider) plus an eager transient
        // marker so clipboard managers (Maccy/Paste/Alfred…) can skip it without
        // reading — a read is our "the target pasted" signal.
        pasteboard.writeObjects([restore.makeItem(text: text)])
        var target = pasteboard.changeCount
        if target == before { target = before + 1 }

        await waitForCommit(pasteboard: pasteboard, target: target, interval: pollInterval, cap: pollCap)
        // The value the restore must still see. Recorded after the commit wait so
        // it is the count OUR write settled on; anything else at restore time is
        // somebody else's clipboard now (P1-1). A foreign write landing inside
        // the few ms of the commit wait would be adopted as ours — unavoidable
        // and vanishingly rare next to the 120-500 ms window this closes.
        restore.recordWrite(changeCount: pasteboard.changeCount)

        let pasted = await executor.synthesizePaste()

        if pasted {
            // Arm AFTER the keystroke: only reads that follow Cmd-V are the target
            // consuming our text. Everything from here is off the injection path —
            // the text is on screen the instant Cmd-V posts.
            restore.arm()
            pendingRestore = restore
            // `.posted`, NOT landed (P1-9): the events are merely in the HID
            // queue. The pasteboard read that proves the target took them is tens
            // of ms away, so the token carries the signal instead of this call
            // waiting for it — awaiting here would put the restore ceiling on the
            // dictation latency path.
            return InsertionToken(
                method: .paste,
                text: text,
                landing: .posted,
                axRange: nil,
                landingSignal: restore.landingSignal
            )
        } else {
            // Leave the text on the clipboard as the user's fallback (do NOT
            // restore) — but as REAL data, not a promise: nothing keeps the
            // provider alive for a manual Cmd-V minutes later, and a broken
            // promise pastes nothing.
            logger.notice("paste could not be synthesized; text left on clipboard as fallback")
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: PasteRestoreCoordinator.transientType)
            pasteboard.writeObjects([item])
            return InsertionToken(method: .paste, text: text, landing: .notPosted)
        }
    }

    @MainActor
    private func waitForCommit(
        pasteboard: NSPasteboard,
        target: Int,
        interval: Duration,
        cap: Duration
    ) async {
        guard target > pasteboard.changeCount else { return }
        let deadline = ContinuousClock.now + cap
        while ContinuousClock.now < deadline {
            if pasteboard.changeCount >= target { return }
            try? await Task.sleep(for: interval)
        }
    }
}
