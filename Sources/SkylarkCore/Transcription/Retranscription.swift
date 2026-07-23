import Foundation

/// The testable core of History → Re-transcribe (opt-in audio retention,
/// phase-5a spec §2): load a retained clip, run a chosen `Transcriber`, and
/// replace the row's raw text + engine column (clearing clean text — no
/// re-cleanup, no re-injection). The caller owns the transcriber's lifecycle
/// (build a *separate* engine so the live dictation engine's warm state is
/// untouched, then release it after); this helper only warms + runs + persists.
public enum Retranscription {
    public enum Failure: Error, Equatable {
        /// The retained WAV was missing or unreadable.
        case audioUnavailable
    }

    /// Decode `audioPath`, run `transcriber` over it, and overwrite row `id`'s
    /// transcription via `HistoryStore.replaceTranscription`. Returns the new
    /// raw text. `warmUp()` is called first (a no-op for an already-warm or
    /// cloud engine). Off any latency path.
    @discardableResult
    public static func run(
        store: HistoryStore,
        id: Int64,
        audioPath: String,
        transcriber: any Transcriber,
        hint: TranscriptionHint = .none
    ) async throws -> String {
        guard let clip = WavDecoder.decode(url: URL(fileURLWithPath: audioPath)) else {
            throw Failure.audioUnavailable
        }
        try await transcriber.warmUp()
        let text = try await transcriber.transcribe(clip, hint: hint)
        try await store.replaceTranscription(id: id, rawText: text, engine: transcriber.lastRunID.historyColumn)
        return text
    }
}
