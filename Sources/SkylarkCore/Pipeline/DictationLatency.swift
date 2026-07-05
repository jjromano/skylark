import Foundation

/// Per-dictation stage timings (milliseconds), measured Fn-up → text inserted.
/// Logged at info level (no transcript content) and surfaced in the menu bar as
/// a rolling "Last: N ms" line. See ARCHITECTURE §8 latency budget.
public struct DictationLatency: Sendable, Equatable {
    /// Capture close + clip finalization.
    public let captureCloseMs: Double
    /// Model decode (warm, ANE).
    public let transcribeMs: Double
    /// Text insertion (AX or paste).
    public let injectMs: Double
    /// End-to-end Fn-up → inserted.
    public let totalMs: Double

    public init(captureCloseMs: Double, transcribeMs: Double, injectMs: Double, totalMs: Double) {
        self.captureCloseMs = captureCloseMs
        self.transcribeMs = transcribeMs
        self.injectMs = injectMs
        self.totalMs = totalMs
    }
}
