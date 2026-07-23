import Foundation

/// Interim transcription shown in the HUD while the user is still speaking
/// (prototype "live preview", behind a default-off setting). Display-only: this
/// text is NEVER pasted — the final paste always comes from the batch decode of
/// the full clip. `confirmed` is high-confidence, stable text; `volatile` is the
/// latest in-flight tail that may still change.
public struct TranscriptPreview: Sendable, Equatable {
    public let confirmed: String
    public let volatile: String

    public init(confirmed: String = "", volatile: String = "") {
        self.confirmed = confirmed
        self.volatile = volatile
    }

    public static let empty = TranscriptPreview()

    public var isEmpty: Bool { confirmed.isEmpty && volatile.isEmpty }

    /// Confirmed text followed by the volatile tail, single-spaced.
    public var displayText: String {
        [confirmed, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// A live interim-transcription session over streamed audio frames. Created per
/// recording, torn down the moment recording ends. Preview-only: the text it
/// emits is HUD-display bound and never reaches the paste path.
public protocol LivePreviewSession: Sendable {
    /// Feed one frame of 16 kHz mono Float32 samples (as delivered by capture).
    /// Cheap and non-blocking; buffering/decoding happens on the session's own
    /// executor.
    func feed(_ frame: [Float]) async

    /// Interim preview updates (accumulated confirmed + latest volatile).
    var updates: AsyncStream<TranscriptPreview> { get }

    /// Stop the session and release its resources. Idempotent. Does NOT return a
    /// transcript — the batch path owns the final text.
    func finish() async
}

/// Creates a `LivePreviewSession` on demand. Returns nil when preview can't run
/// right now (e.g. the model isn't resident yet); the orchestrator then simply
/// skips preview for that recording — the batch path is unaffected either way.
public protocol LivePreviewProviding: Sendable {
    func makeSession() async -> (any LivePreviewSession)?
}
