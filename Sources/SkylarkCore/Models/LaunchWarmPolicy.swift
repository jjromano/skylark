import Foundation

public extension STTChoice {
    /// The LOCAL engine a selection actually keeps resident — the only one worth
    /// warming at launch.
    ///
    /// Launch used to warm Parakeet unconditionally, before the persisted choice
    /// had been applied: a user on Whisper or Apple Speech who had deleted the
    /// Parakeet model got an unrequested Hugging Face connection and a ~483 MB
    /// download every time the app started (P2-4).
    ///
    /// A cloud selection still resolves to a local engine because cloud STT runs
    /// behind a `FallbackTranscriber` whose fallback must stay warm; Parakeet is
    /// that fallback unless another local engine is the active one, which is what
    /// the caller passes as `cloudFallback`.
    func warmLocalEngine(cloudFallback: STTChoice = .localParakeet) -> STTChoice {
        switch self {
        case .localParakeet: return .localParakeet
        case .localWhisper: return .localWhisper
        case .localApple: return .localApple
        case .cloud: return cloudFallback.isLocal ? cloudFallback : .localParakeet
        }
    }
}
