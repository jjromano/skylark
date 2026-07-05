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
    public let text: String
    /// True when the paste path could not confirm insertion; text was left on
    /// the clipboard as the user's fallback and NOT restored.
    public let pasteUncertain: Bool

    public init(method: Method, text: String, pasteUncertain: Bool) {
        self.method = method
        self.text = text
        self.pasteUncertain = pasteUncertain
    }

    public static func == (lhs: InsertionToken, rhs: InsertionToken) -> Bool {
        guard lhs.text == rhs.text, lhs.pasteUncertain == rhs.pasteUncertain else { return false }
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
    case replaceNotImplemented
}

/// AX-first text injection with a clipboard-preserving paste fallback.
@MainActor
public final class TextInjector: TextInjecting {
    private let executor: PasteExecutor
    private let signposter = OSSignposter(subsystem: "com.jjromano.skylark", category: "injection")
    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "injection")

    public init(executor: PasteExecutor = CmdVPasteExecutor()) {
        self.executor = executor
    }

    public func insert(_ text: String) async throws -> InsertionToken {
        let state = signposter.beginInterval("insert")
        defer { signposter.endInterval("insert", state) }

        // 1) AX-first: real success/failure signal, clipboard untouched.
        if let element = Self.insertViaAX(text) {
            return InsertionToken(method: .ax(element), text: text, pasteUncertain: false)
        }
        // 2) Clipboard-preserving paste fallback.
        return await performClipboardPaste(text, pasteboard: .general, executor: executor)
    }

    public func replace(_ token: InsertionToken, with text: String) async throws {
        // In-place replacement lands in Phase 2 (ARCHITECTURE §3).
        throw InjectionError.replaceNotImplemented
    }

    // MARK: - AX path

    /// Attempts AX insertion; returns the focused element on success, else nil.
    static func insertViaAX(_ text: String) -> AXUIElement? {
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

        let result = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return result == .success ? focused : nil
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
