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

    public let method: Method
    /// The exact text inserted, including any smart-spacing separator prefix —
    /// this is what sits on screen, so the in-place replace matches against it.
    public let text: String
    /// The smart-spacing separator (`""` or `" "`) prepended at insertion, kept
    /// so an in-place cleanup replace re-applies the same prefix.
    public let leadingSeparator: String
    /// True when the paste path could not confirm insertion; text was left on
    /// the clipboard as the user's fallback and NOT restored.
    public let pasteUncertain: Bool

    public init(method: Method, text: String, leadingSeparator: String = "", pasteUncertain: Bool) {
        self.method = method
        self.text = text
        self.leadingSeparator = leadingSeparator
        self.pasteUncertain = pasteUncertain
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

    /// Public initializer (no AX anchor) — used by tests and any caller that
    /// only carries the selection text; replacement then uses the paste path.
    public init(text: String) {
        self.text = text
        self.element = nil
        self.range = nil
    }

    init(text: String, element: AXUIElement, range: CFRange) {
        self.text = text
        self.element = element
        self.range = range
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
    /// falls back to a clipboard-preserving paste over the live selection when
    /// AX can't confirm. Returns true when the replacement landed. On false the
    /// caller surfaces a failure and leaves the selection as-is.
    func replaceSelection(_ selection: CommandSelection, with text: String) async -> Bool
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
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
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

    public init(executor: PasteExecutor = CmdVPasteExecutor()) {
        self.executor = executor
    }

    /// Synthesize a Return keyDown/keyUp to the same destination the paste path
    /// posts to (`.cghidEventTap`), for the spoken "press enter" command. No
    /// clipboard involvement.
    ///
    /// Call this only *after* `insert` has returned: on the paste path `insert`
    /// awaits the post-paste settle grace before returning, and on the AX path the
    /// write is synchronous, so by the time this runs the injected text has
    /// already landed and the Return keystroke arrives after it in the target app.
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
        if let element = Self.insertViaAX(toInsert) {
            rememberInsertion(text: toInsert, pid: targetPid)
            return InsertionToken(method: .ax(element), text: toInsert, leadingSeparator: separator, pasteUncertain: false)
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
        guard let element = Self.insertViaAX(toInsert) else {
            logger.debug("direct AX insert unconfirmed; caller will wait-for-clean")
            return nil
        }
        rememberInsertion(text: toInsert, pid: targetPid)
        return InsertionToken(method: .ax(element), text: toInsert, leadingSeparator: separator, pasteUncertain: false)
    }

    /// In-place replacement of the just-inserted range (ARCHITECTURE §3).
    /// AX-inserted text is rewritten precisely; paste-inserted text is
    /// unsupported here (the orchestrator waits-for-clean before pasting).
    public func replace(_ token: InsertionToken, with text: String) async throws {
        switch token.method {
        case .paste:
            throw InjectionError.replaceUnsupported
        case let .ax(element):
            // Any failed precondition aborts silently — the raw text stands.
            // Re-apply the smart-spacing separator so the cleaned text keeps the
            // leading space the raw insertion had.
            _ = Self.performAXReplace(element: element, original: token.text, replacement: token.leadingSeparator + text)
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
        return CommandSelection(text: text, element: element, range: range)
    }

    /// Replace a read selection with `text`. Prefers a verified AX write over the
    /// exact selected range; on any failure (focus moved, field drops the write,
    /// or no AX handle) falls back to a clipboard-preserving paste, which Cmd-V's
    /// over the live selection to replace it. Returns true when text landed.
    public func replaceSelection(_ selection: CommandSelection, with text: String) async -> Bool {
        if let element = selection.element, let range = selection.range,
           Self.axReplaceSelection(element: element, range: range, original: selection.text, replacement: text) {
            return true
        }
        // Paste fallback: Cmd-V replaces the current selection in place.
        let token = await performClipboardPaste(text, pasteboard: .general, executor: executor)
        return !token.pasteUncertain
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
    /// element only when the inserted text is verifiably present at the caret;
    /// nil otherwise so the caller falls back to the clipboard paste.
    ///
    /// Chrome, Electron, and some web fields answer `AXUIElementSetAttributeValue`
    /// with `.success` yet never apply the write, so a bare success is not
    /// trustworthy. We re-use the same range read the in-place replace relies on:
    /// a field that can't read our text back at the expected range is treated as
    /// not-landed (paste instead).
    static func insertViaAX(_ text: String) -> AXUIElement? {
        guard let focused = focusedEditableElement() else { return nil }
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            return nil
        }
        guard axInsertLanded(element: focused, insertedText: text) else { return nil }
        return focused
    }

    /// True when `insertedText` is verifiably present at the caret after an AX
    /// set. The caret sits collapsed at the end of the inserted run, so the run
    /// occupies `[caret - len, len]`; we read that range back and compare. Any
    /// unreadable attribute (field doesn't support the range read) → false, so
    /// the caller pastes instead. Empty text needs no verification.
    static func axInsertLanded(element: AXUIElement, insertedText: String) -> Bool {
        let len = utf16Count(insertedText)
        guard len > 0 else { return true }
        guard let caret = selectedRange(element),
              let range = candidateRange(caretLocation: caret.location, insertedUTF16Count: len),
              let readBack = string(in: element, range: range)
        else {
            return false
        }
        return readBack == insertedText
    }

    // MARK: - In-place replacement (AX)

    /// Precisely replaces the `original` run ending at the caret with
    /// `replacement`. Returns true when the replacement was applied; false (no
    /// mutation) on any mismatch — focus moved, caret math impossible, or the
    /// text at the computed range isn't what we inserted.
    static func performAXReplace(element: AXUIElement, original: String, replacement: String) -> Bool {
        // 1) Focus must still be the token's element (user hasn't clicked away).
        guard let focused = focusedEditableElement(), CFEqual(focused, element) else { return false }

        // 2) Read the caret (selected range); expected collapsed at the end of
        //    the inserted text. AX ranges are UTF-16 code units.
        guard let caret = selectedRange(element) else { return false }
        guard let candidate = candidateRange(caretLocation: caret.location, insertedUTF16Count: utf16Count(original)) else {
            return false
        }

        // 3) Verify the candidate range actually holds our inserted text.
        guard let atRange = string(in: element, range: candidate), atRange == original else { return false }

        // 4) Select the range, replace it, restore a collapsed caret at the end.
        guard setSelectedRange(element, candidate) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
            return false
        }
        let newCaret = CFRange(location: candidate.location + utf16Count(replacement), length: 0)
        _ = setSelectedRange(element, newCaret)
        return true
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

    /// snapshot → write → poll changeCount → paste → grace → restore.
    /// Exposed for unit tests with an injected `PasteExecutor` and short delays.
    @MainActor
    func performClipboardPaste(
        _ text: String,
        pasteboard: NSPasteboard,
        executor: PasteExecutor,
        pollInterval: Duration = .milliseconds(5),
        pollCap: Duration = .milliseconds(150),
        restoreGrace: Duration = .milliseconds(500)
    ) async -> InsertionToken {
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        var target = pasteboard.changeCount
        if target == before { target = before + 1 }

        await waitForCommit(pasteboard: pasteboard, target: target, interval: pollInterval, cap: pollCap)

        let pasted = await executor.synthesizePaste()

        if pasted {
            try? await Task.sleep(for: restoreGrace)
            snapshot.restore(to: pasteboard)
            return InsertionToken(method: .paste, text: text, pasteUncertain: false)
        } else {
            // Leave the text on the clipboard as the user's fallback (do NOT restore).
            logger.notice("paste could not be synthesized; text left on clipboard as fallback")
            return InsertionToken(method: .paste, text: text, pasteUncertain: true)
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
