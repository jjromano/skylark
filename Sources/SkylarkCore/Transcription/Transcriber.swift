import Foundation

/// Identifies a concrete transcription engine.
public enum TranscriberID: Sendable, Equatable {
    case parakeet
    case whisperKit
    case speechAnalyzer
    case cloud(String)
    case stub
}

/// Hints passed to a transcriber for a single utterance.
///
/// Kept intentionally small for Phase 0; grows with modes/dictionary in later
/// phases (target-app register, custom-dictionary bias terms, mode prompt).
public struct TranscriptionHint: Sendable, Equatable {
    public var locale: String?

    public init(locale: String? = nil) {
        self.locale = locale
    }

    public static let none = TranscriptionHint()
}

/// Speech-to-text engine. Phase 0 keeps this minimal (no streaming) per spec;
/// `stream(_:hint:)` from ARCHITECTURE §2 lands in Phase 1.
public protocol Transcriber: Sendable {
    var id: TranscriberID { get }

    /// Load and keep the model resident (PRD §6.1 model residency).
    func warmUp() async throws

    /// Batch-transcribe a whole clip.
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String

    /// The engine that produced the MOST RECENT transcription. Defaults to
    /// `id`; wrappers that can fall back (cloud → local) override it so
    /// history rows record the engine that actually ran, not the one selected.
    var lastRunID: TranscriberID { get }
}

public extension Transcriber {
    var lastRunID: TranscriberID { id }
}
