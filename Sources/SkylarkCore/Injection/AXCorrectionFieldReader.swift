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
        guard let focused = AXTextReader.focusedElement(), CFEqual(focused, element) else { return nil }
        guard !AXTextReader.isSecure(element) else { return nil }
        guard let caret = AXTextReader.selectedRange(element) else { return nil }
        let anchor = caret.location - AXTextReader.utf16Count(finalText)
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
        guard let focused = AXTextReader.focusedElement(), CFEqual(focused, element) else { return .invalid }
        guard !AXTextReader.isSecure(element) else { return .invalid }
        guard let valueLength = AXTextReader.numberOfCharacters(element) else { return .invalid }

        let start = watch.anchorLocation
        guard start >= 0, start <= valueLength else { return .invalid }
        let want = AXTextReader.utf16Count(watch.finalText) + slack
        let length = min(want, valueLength - start)
        guard length >= 0 else { return .invalid }
        guard let text = AXTextReader.string(in: element, range: CFRange(location: start, length: length)) else {
            return .invalid
        }
        return .text(text)
    }
}
