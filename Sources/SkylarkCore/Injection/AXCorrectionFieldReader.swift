import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// AX implementation of `CorrectionFieldReading`: builds a `CorrectionWatch` for
/// a just-settled AX insertion and re-reads that region on demand. All AX work
/// runs on the main actor. Never logs field text (privacy rule) — only the
/// pass/fail of the read.
public final class AXCorrectionFieldReader: CorrectionFieldReading, @unchecked Sendable {
    /// Extra UTF-16 units read past `finalText`, so a correction that *lengthens*
    /// the text is still captured. Trailing field text pulled in by the slack
    /// diffs out as harmless inserts (never a single-token substitution).
    private static let slack = 40

    public init() {}

    // MARK: - Watch construction (settle time)

    /// Build a watch for a settled AX insertion, or nil when it must not be
    /// watched: non-AX token, focus already moved, secure field, excluded app,
    /// or an unreadable caret. Runs at settle time, milliseconds after the
    /// insert/replace, so the caret still sits at the end of `finalText`.
    @MainActor
    public func makeWatch(token: InsertionToken, finalText: String, bundleID: String?) -> CorrectionWatch? {
        guard case let .ax(element) = token.method else { return nil }
        guard !finalText.isEmpty else { return nil }
        guard !CorrectionTarget.isExcludedApp(bundleID) else { return nil }
        // Focus must still be the token's element.
        guard let focused = Self.focusedElement(), CFEqual(focused, element) else { return nil }
        guard !Self.isSecure(element) else { return nil }
        guard let caret = Self.selectedRange(element) else { return nil }
        let anchor = caret.location - Self.utf16Count(finalText)
        guard anchor >= 0 else { return nil }
        return CorrectionWatch(token: token, finalText: finalText, anchorLocation: anchor)
    }

    // MARK: - Readback (poll time)

    public func readback(_ watch: CorrectionWatch) async -> CorrectionReadback {
        await MainActor.run { Self.read(watch) }
    }

    @MainActor
    private static func read(_ watch: CorrectionWatch) -> CorrectionReadback {
        guard case let .ax(element) = watch.token.method else { return .invalid }
        // Focus must still be the same element, and it must not have become secure.
        guard let focused = focusedElement(), CFEqual(focused, element) else { return .invalid }
        guard !isSecure(element) else { return .invalid }
        guard let valueLength = numberOfCharacters(element) else { return .invalid }

        let start = watch.anchorLocation
        guard start >= 0, start <= valueLength else { return .invalid }
        let want = utf16Count(watch.finalText) + slack
        let length = min(want, valueLength - start)
        guard length >= 0 else { return .invalid }
        guard let text = string(in: element, range: CFRange(location: start, length: length)) else {
            return .invalid
        }
        return .text(text)
    }

    // MARK: - AX helpers (main actor)

    @MainActor
    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef
        else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    @MainActor
    private static func isSecure(_ element: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success else {
            return false
        }
        return CorrectionTarget.isSecureSubrole(subroleRef as? String)
    }

    @MainActor
    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    @MainActor
    private static func numberOfCharacters(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
              let count = ref as? Int
        else {
            return nil
        }
        return count
    }

    @MainActor
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

    private static func utf16Count(_ text: String) -> Int { text.utf16.count }
}
