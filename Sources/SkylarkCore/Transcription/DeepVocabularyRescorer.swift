import Foundation

/// A dictionary term reduced to what an acoustic vocabulary rescorer needs: the
/// correct spelling and its known misspellings (used as acoustic aliases). A
/// Skylark-native shape so the pipeline and its tests stay free of FluidAudio
/// types; the concrete engine maps this to its own vocabulary term at the edge.
public struct VocabularyTerm: Sendable, Equatable {
    public let text: String
    public let aliases: [String]

    public init(text: String, aliases: [String] = []) {
        self.text = text
        self.aliases = aliases
    }
}

/// Pure mapping from stored dictionary entries to acoustic vocabulary terms.
/// `phrase` → `text` (the correct spelling to recognise), `misspellings` →
/// `aliases` (alternate pronunciations the rescorer may match against). Kept
/// pure and dependency-free so it's unit-testable without loading a model.
public enum DeepVocabularyMapping {
    public static func terms(from entries: [DictionaryEntry]) -> [VocabularyTerm] {
        entries.compactMap { entry in
            let phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { return nil }
            let aliases = entry.misspellings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return VocabularyTerm(text: phrase, aliases: aliases)
        }
    }
}

/// The optional deep-vocabulary rescoring stage (PRD §8, default on).
/// Runs a second on-device acoustic pass against the user's dictionary so names
/// and terms are recognised as spoken rather than only fixed afterward.
///
/// Invariants the orchestrator relies on:
/// - Never throws. Any failure (model missing, empty vocabulary, no detection)
///   returns `nil` so the caller keeps the un-rescored text (optional stage).
/// - Called only off the paste path, in the detached post-insert flow, and only
///   for Parakeet utterances (it needs TDT `timings`).
public protocol DeepVocabularyRescoring: Sendable {
    /// Rescore `rawText` using the utterance audio + TDT token timings.
    /// - Returns: the changed text when the dictionary won a replacement, or
    ///   `nil` to keep `rawText` (no change, empty vocabulary, or any failure).
    func rescore(rawText: String, samples: [Float], timings: [TranscriptTiming]) async -> String?
}

/// Fires `onFire` once, `timeout` after the most recent `touch()`. Each `touch`
/// restarts the countdown; `cancel()` stops it. The sleep is injected so the
/// idle-unload policy can be driven deterministically in tests (real callers use
/// the default `Task.sleep`). Used to unload the CTC model after idle.
public actor IdleTimer {
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    public init(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.timeout = timeout
        self.sleep = sleep
    }

    /// (Re)start the countdown. When it elapses without another `touch`, `onFire`
    /// runs. A fresh `touch` cancels any pending fire first.
    public func touch(onFire: @escaping @Sendable () async -> Void) {
        task?.cancel()
        let timeout = timeout
        let sleep = sleep
        task = Task { [weak self] in
            do { try await sleep(timeout) } catch { return }
            if Task.isCancelled { return }
            await onFire()
            await self?.clearTask()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func clearTask() {
        task = nil
    }
}
