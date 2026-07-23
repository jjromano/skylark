import ApplicationServices
import Foundation

/// Reads the on-screen text around the caret for context-aware cleanup. Faked in
/// tests so the orchestrator wiring stays pure; the live conformer reads via AX.
public protocol FieldContextReading: Sendable {
    /// Read up to `precedingLimit` UTF-16 units before the caret and
    /// `followingLimit` after it from the focused text element. Returns nil when
    /// there's no usable/allowed context: no focused element, an unreadable
    /// caret, a secure field, an excluded (password-manager) app, or an empty
    /// field. Never throws; degrades to nil. `bundleID` is the frontmost app so
    /// the same password-manager exclusion the correction watcher uses applies.
    func readFieldContext(bundleID: String?, precedingLimit: Int, followingLimit: Int) async -> FieldContext?
}

/// AX implementation of `FieldContextReading`: reads the focused element's text
/// around the caret via the shared `AXTextReader` primitives and the same
/// `CorrectionTarget` privacy guards (secure-field subrole + password-manager
/// bundle exclusions) the correction watcher uses. All AX work runs on the main
/// actor. Never logs field text (privacy rule) — only pass/fail could ever be
/// logged, and it logs nothing.
public final class AXFieldContextReader: FieldContextReading, @unchecked Sendable {
    public init() {}

    public func readFieldContext(bundleID: String?, precedingLimit: Int, followingLimit: Int) async -> FieldContext? {
        await MainActor.run { Self.read(bundleID: bundleID, precedingLimit: precedingLimit, followingLimit: followingLimit) }
    }

    @MainActor
    private static func read(bundleID: String?, precedingLimit: Int, followingLimit: Int) -> FieldContext? {
        // Same privacy guards as the correction watcher: never read secure fields
        // or password-manager apps.
        guard !CorrectionTarget.isExcludedApp(bundleID) else { return nil }
        guard let element = AXTextReader.focusedElement() else { return nil }
        guard !AXTextReader.isSecure(element) else { return nil }
        guard let caret = AXTextReader.selectedRange(element),
              let total = AXTextReader.numberOfCharacters(element)
        else { return nil }

        // Caret/selection start bounds the preceding read; the selection END
        // bounds the following read (a dictation replaces any selection, so the
        // text after the selection is what follows the insertion).
        let caretStart = caret.location
        let caretEnd = caret.location + max(0, caret.length)
        guard caretStart >= 0, caretStart <= total, caretEnd <= total else { return nil }

        // Preceding: [max(0, caretStart - precedingLimit), caretStart).
        var preceding = ""
        let precedingStart = max(0, caretStart - precedingLimit)
        let precedingLength = caretStart - precedingStart
        if precedingLength > 0,
           let text = AXTextReader.string(in: element, range: CFRange(location: precedingStart, length: precedingLength)) {
            preceding = text
        }

        // Following: [caretEnd, min(total, caretEnd + followingLimit)).
        var following = ""
        let followingLength = min(followingLimit, total - caretEnd)
        if followingLength > 0,
           let text = AXTextReader.string(in: element, range: CFRange(location: caretEnd, length: followingLength)) {
            following = text
        }

        let context = FieldContext(preceding: preceding, following: following)
        return context.isEmpty ? nil : context
    }
}
