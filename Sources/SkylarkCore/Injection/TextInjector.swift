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

/// Inserts text at the cursor (ARCHITECTURE §2).
public protocol TextInjecting: Sendable {
    func insert(_ text: String) async throws -> InsertionToken
    func replace(_ token: InsertionToken, with text: String) async throws
    /// Whether the focused element supports precise AX insertion right now. The
    /// orchestrator probes this at paste time to pick the cleanup strategy
    /// (in-place replace vs. wait-for-clean).
    func canInsertDirectly() async -> Bool
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

    /// The focused element only if it supports the parameterized range read that
    /// verify/replace require (`kAXStringForRange`). This distinguishes native
    /// text views (which do) from web/Electron fields (which don't).
    static func focusedInPlaceElement() -> AXUIElement? {
        guard let focused = focusedEditableElement() else { return nil }
        var namesRef: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(focused, &namesRef) == .success,
              let names = namesRef as? [String],
              names.contains(kAXStringForRangeParameterizedAttribute as String)
        else {
            return nil
        }
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
