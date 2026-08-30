import Foundation

/// Per-dictation stage timings (milliseconds), measured Fn-up → text inserted.
/// Logged at info level (no transcript content) and surfaced in the menu bar as
/// a rolling "Last: N ms" line. See ARCHITECTURE §8 latency budget.
public struct DictationLatency: Sendable, Equatable {
    /// Capture close + clip finalization.
    public let captureCloseMs: Double
    /// Model decode (warm, ANE). For a cloud STT engine this is the whole
    /// network round trip, which is why it can dominate the budget.
    public let transcribeMs: Double
    /// Cleanup generation on the PASTE path only (the wait the user actually
    /// sees). `0` when cleanup was skipped, ran detached after an AX insert, or
    /// was served by the deterministic short-transcript path.
    ///
    /// Split out at 0.17.0: before that this time was folded into `injectMs`,
    /// so a diagnostics export could not tell a slow transcription from a slow
    /// cleanup, and a cleanup that burned its whole timeout and returned raw
    /// looked exactly like a slow paste.
    public let cleanupMs: Double
    /// Text insertion (AX or paste) alone, with cleanup excluded.
    public let injectMs: Double
    /// End-to-end Fn-up → inserted.
    public let totalMs: Double

    public init(
        captureCloseMs: Double,
        transcribeMs: Double,
        cleanupMs: Double = 0,
        injectMs: Double,
        totalMs: Double
    ) {
        self.captureCloseMs = captureCloseMs
        self.transcribeMs = transcribeMs
        self.cleanupMs = cleanupMs
        self.injectMs = injectMs
        self.totalMs = totalMs
    }
}
