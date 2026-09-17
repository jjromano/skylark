import ApplicationServices
import Foundation
import os

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
/// actor. Never logs field text (privacy rule): only the read's outcome.
///
/// Electron apps (Claude desktop, Slack, VS Code…) publish no Accessibility tree
/// until a client sets `AXManualAccessibility` on the application, so the focused
/// text field is invisible and every read came back empty. When a read finds no
/// readable field, the reader asks the frontmost app to turn its tree on and
/// retries briefly. Apps that don't implement the attribute reject the set and
/// are left alone. All of this runs detached while the user speaks.
public final class AXFieldContextReader: FieldContextReading, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "injection")
    /// Waits between retries after enabling an Electron app's tree, which it
    /// builds asynchronously. Total ~0.5 s, well inside a typical utterance.
    private static let retryDelays: [Duration] = [.milliseconds(80), .milliseconds(150), .milliseconds(250)]

    enum ReadResult {
        case context(FieldContext)
        /// A readable field with nothing around the caret.
        case empty
        /// Privacy guard: excluded app or secure field. Never retried.
        case blocked
        /// No focused element, or it exposes no caret/text.
        case unreadable
    }

    public init() {}

    public func readFieldContext(bundleID: String?, precedingLimit: Int, followingLimit: Int) async -> FieldContext? {
        let read = { @MainActor in Self.read(bundleID: bundleID, precedingLimit: precedingLimit, followingLimit: followingLimit) }
        var result = await read()
        var enabledTree = false
        if case .unreadable = result, await MainActor.run(body: { Self.enableManualAccessibility() }) {
            enabledTree = true
            for delay in Self.retryDelays {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { break }
                result = await read()
                if case .unreadable = result { continue }
                break
            }
        }
        let outcome: String
        switch result {
        case .context: outcome = "ok"
        case .empty: outcome = "empty"
        case .blocked: outcome = "blocked"
        case .unreadable: outcome = "unreadable"
        }
        Self.logger.info("field context read: \(outcome, privacy: .public), app: \(bundleID ?? "unknown", privacy: .public), enabled-app-ax: \(enabledTree, privacy: .public)")
        if case .context(let context) = result { return context }
        return nil
    }

    /// Ask the frontmost app to build its Accessibility tree (Electron's
    /// `AXManualAccessibility`). True only when the app accepted the attribute.
    @MainActor
    private static func enableManualAccessibility() -> Bool {
        guard let app = AXTextReader.focusedApplication() else { return false }
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    @MainActor
    private static func read(bundleID: String?, precedingLimit: Int, followingLimit: Int) -> ReadResult {
        // Same privacy guards as the correction watcher: never read secure fields
        // or password-manager apps.
        guard !CorrectionTarget.isExcludedApp(bundleID) else { return .blocked }
        guard let element = AXTextReader.focusedElement() else { return .unreadable }
        guard !AXTextReader.isSecure(element) else { return .blocked }
        guard let caret = AXTextReader.selectedRange(element),
              let total = AXTextReader.numberOfCharacters(element)
        else { return .unreadable }

        // Caret/selection start bounds the preceding read; the selection END
        // bounds the following read (a dictation replaces any selection, so the
        // text after the selection is what follows the insertion).
        let caretStart = caret.location
        let caretEnd = caret.location + max(0, caret.length)
        guard caretStart >= 0, caretStart <= total, caretEnd <= total else { return .unreadable }

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
        return context.isEmpty ? .empty : .context(context)
    }
}
