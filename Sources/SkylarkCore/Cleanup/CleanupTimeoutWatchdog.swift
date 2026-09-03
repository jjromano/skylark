import Foundation

/// Watches paste-path cleanup outcomes and speaks up when cleanup is timing out
/// often enough that the wait is costing the user real time for nothing.
///
/// The failure this exists to prevent, observed in the field: on a machine
/// where the cleanup model needed longer than the pre-paste bound, every second
/// dictation into a pasting app waited the full bound and pasted the RAW text
/// anyway — the worst of both worlds, and completely invisible. The per-
/// dictation "Cleanup didn't finish in time" note is easy to miss and says
/// nothing about the pattern, so the cause never got addressed.
///
/// The advice is deliberately about the MODEL, not a timeout setting: the
/// pre-paste wait is a fixed internal bound (nothing is on screen yet, so it
/// cannot be stretched to taste), and the user's cleanup timeout governs only
/// the detached path, which never records here. Telling them to raise a setting
/// that has no effect on this path would be worse than silence.
///
/// This deliberately RECOMMENDS rather than acts: the right answer depends on
/// what the user wants, a faster model or no wait at all.
///
/// Pure and deterministic — no I/O, no clock, no shared state — so the trigger
/// rule is unit-testable. The caller owns when to show the recommendation.
public struct CleanupTimeoutWatchdog: Sendable, Equatable {
    /// One paste-path cleanup attempt's outcome. The DETACHED path never
    /// records here: its cleanup happens after the text is already on screen,
    /// so a slow one costs the user nothing.
    public enum Outcome: Sendable, Equatable {
        case completed
        case timedOut
    }

    /// How many recent attempts the rate is judged over.
    public static let windowSize = 10
    /// Minimum attempts before any recommendation — two timeouts in a row on a
    /// fresh install is not yet a pattern.
    public static let minimumAttempts = 5
    /// Timeout share at or above which the setting is judged to be wrong.
    public static let triggerRate = 0.5

    private var window: [Outcome] = []
    /// Set once a recommendation has been surfaced, so the user is told once
    /// and not on every subsequent dictation. Cleared by `reset()`.
    private var recommended = false

    public init() {}

    /// Record one paste-path cleanup outcome.
    public mutating func record(_ outcome: Outcome) {
        window.append(outcome)
        if window.count > Self.windowSize {
            window.removeFirst(window.count - Self.windowSize)
        }
    }

    /// Forget the history and re-arm the recommendation. Call when the user
    /// changes the cleanup timeout, tier, or model: the old window describes a
    /// configuration that no longer exists, and keeping it would either suppress
    /// a warning that is still deserved or repeat one that was just acted on.
    public mutating func reset() {
        window.removeAll()
        recommended = false
    }

    /// Timeouts in the current window.
    public var timeoutCount: Int {
        window.filter { $0 == .timedOut }.count
    }

    public var attemptCount: Int { window.count }

    /// Whether the current window justifies a recommendation. Independent of
    /// whether one has already been shown, so callers and tests can ask about
    /// the data without consuming the one-shot.
    public var isTimingOutPersistently: Bool {
        guard window.count >= Self.minimumAttempts else { return false }
        return Double(timeoutCount) / Double(window.count) >= Self.triggerRate
    }

    /// Returns a user-facing recommendation the FIRST time the window justifies
    /// one, then nil until `reset()`. `nil` means say nothing.
    ///
    /// `bound` is the pre-paste wait budget, i.e. what each timed-out dictation
    /// cost for no benefit; naming it is what makes the message actionable
    /// rather than another vague "cleanup was slow" note.
    public mutating func recommendationIfNeeded(bound: Duration) -> String? {
        guard !recommended, isTimingOutPersistently else { return nil }
        recommended = true
        return Self.message(timeouts: timeoutCount, attempts: attemptCount, bound: bound)
    }

    /// The recommendation text for the PASTE path. Names the pattern, the cost,
    /// and the two ways out — never transcript content. There is no detached
    /// variant because the detached path never records an outcome here: its
    /// cleanup lands after the text is on screen, so a slow one costs nothing.
    static func message(timeouts: Int, attempts: Int, bound: Duration) -> String {
        "Cleanup couldn't finish within \(boundLabel(bound)) on \(timeouts) of your last "
            + "\(attempts) dictations into apps that paste, so raw text was kept. "
            + "Pick a faster cleanup model, or set cleanup to Raw for those apps."
    }

    /// A human label for the bound. Sub-second bounds print as "0.6 s", not the
    /// "1s" a whole-second rounding would have produced.
    static func boundLabel(_ bound: Duration) -> String {
        let ms = Double(bound.components.seconds) * 1000
            + Double(bound.components.attoseconds) / 1e15
        let seconds = ms / 1000
        if seconds >= 1, seconds.rounded() == seconds {
            return "\(Int(seconds)) s"
        }
        return String(format: "%.1f s", seconds)
    }
}
