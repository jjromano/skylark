import ApplicationServices
import Foundation

/// Shared, main-actor Accessibility primitives for reading a focused text
/// element — the focused element, its secure/subrole status, caret/selection
/// range, character count, and a bounded substring. Both `AXCorrectionFieldReader`
/// (auto-learn re-reads) and `AXFieldContextReader` (context-aware cleanup) build
/// on these, so the raw AX plumbing lives in exactly one place. Never logs field
/// text (privacy rule) — callers get only the values, never a log line.
enum AXTextReader {
    @MainActor
    static func focusedElement() -> AXUIElement? {
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
    static func isSecure(_ element: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success else {
            return false
        }
        return CorrectionTarget.isSecureSubrole(subroleRef as? String)
    }

    @MainActor
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    @MainActor
    static func numberOfCharacters(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
              let count = ref as? Int
        else {
            return nil
        }
        return count
    }

    @MainActor
    static func string(in element: AXUIElement, range: CFRange) -> String? {
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

    static func utf16Count(_ text: String) -> Int { text.utf16.count }
}
