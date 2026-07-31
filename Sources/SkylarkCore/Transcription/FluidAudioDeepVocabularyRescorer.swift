import Foundation
import FluidAudio
import os

/// Deep-vocabulary rescoring backed by FluidAudio's Parakeet CTC-110M keyword
/// spotter + constrained-CTC `VocabularyRescorer` (PRD §8 deep matching, default on).
///
/// Adapted from FluidAudio's own `SlidingWindowAsrManager.applyVocabularyRescoring`
/// wiring (Apache-2.0) — the documented `transcribe(_:customVocabulary:)` overload
/// does not exist in 0.15.5, so we drive the manual path:
///   `CtcKeywordSpotter.spotKeywordsWithLogProbs` →
///   `VocabularyRescorer.create` / `.ctcTokenRescore` over the TDT `tokenTimings`.
///
/// Memory policy: the CTC model + tokenizer load lazily on first rescore and
/// unload when the feature is switched off (`unload()`) AND after ~5 min idle
/// (the injected `IdleTimer`). Nothing is resident while the feature is off.
public actor FluidAudioDeepVocabularyRescorer: DeepVocabularyRescoring {

    private let modelDirectory: URL
    private let dictionary: any DictionaryProviding
    private let progress: @Sendable (ModelPreparationState) -> Void
    private let idleTimer: IdleTimer

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "deepvocab")

    /// Loaded acoustic state (nil while unloaded). The tokenizer is cached so
    /// per-utterance term tokenisation doesn't re-parse `tokenizer.json`.
    private struct Loaded {
        let models: CtcModels
        let spotter: CtcKeywordSpotter
        let tokenizer: CtcTokenizer
    }
    private var loaded: Loaded?

    /// Rescorer + vocabulary rebuilt only when the dictionary changes (the
    /// rescorer bakes in the term set / BK-tree), so steady-state cost is just
    /// the CTC acoustic pass.
    private struct VocabCache {
        let signature: Int
        let vocabulary: CustomVocabularyContext
        let rescorer: VocabularyRescorer
    }
    private var vocabCache: VocabCache?

    /// - Parameters:
    ///   - modelDirectory: leaf folder for the CTC repo (default: shared path).
    ///   - dictionary: read-side dictionary source (terms loaded off the paste path).
    ///   - idleTimeout: unload the model after this much inactivity.
    ///   - progress: model-preparation callback (Models pane / menu bar).
    public init(
        modelDirectory: URL = ModelPaths.ctcModelDir,
        dictionary: any DictionaryProviding,
        idleTimeout: Duration = .seconds(300),
        progress: @escaping @Sendable (ModelPreparationState) -> Void = { _ in }
    ) {
        self.modelDirectory = modelDirectory
        self.dictionary = dictionary
        self.idleTimer = IdleTimer(timeout: idleTimeout)
        self.progress = progress
    }

    // MARK: - Model lifecycle

    /// Whether the CTC helper model is present on disk.
    public nonisolated var isModelDownloaded: Bool {
        CtcModels.modelsExist(at: modelDirectory)
    }

    /// Download the CTC-110M helper model to disk if absent. Used by the Models
    /// pane / first opt-in. Idempotent; reports progress via `progress`. Does NOT
    /// load the model into memory — that happens lazily on the first rescore
    /// (`ensureLoaded`), so enabling-but-never-dictating keeps nothing resident.
    public func prepareModel() async throws {
        progress(.checking)
        if !CtcModels.modelsExist(at: modelDirectory) {
            // `ModelHub` resolves the repo folderName against the parent of the
            // leaf we target, so download into the parent directory.
            let parent = modelDirectory.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let report = progress
            try await ModelHub.download(
                CtcModelVariant.ctc110m.repo,
                to: parent,
                progressHandler: { p in
                    switch p.phase {
                    case .listing: report(.checking)
                    case .downloading: report(.downloading(progress: p.fractionCompleted))
                    case .compiling: report(.loading)
                    }
                }
            )
        }
        guard CtcModels.modelsExist(at: modelDirectory) else { throw DeepVocabError.modelNotDownloaded }
        progress(.ready)
        logger.info("deep-vocabulary CTC model downloaded")
    }

    /// Drop the loaded model, tokenizer, and cached rescorer. Called when the
    /// feature is switched off and by the idle timer. Never resident afterwards.
    public func unload() async {
        loaded = nil
        vocabCache = nil
        await idleTimer.cancel()
    }

    private func ensureLoaded() async throws -> Loaded {
        if let loaded { return loaded }
        guard CtcModels.modelsExist(at: modelDirectory) else {
            throw DeepVocabError.modelNotDownloaded
        }
        let models = try await CtcModels.load(from: modelDirectory, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: modelDirectory)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let state = Loaded(models: models, spotter: spotter, tokenizer: tokenizer)
        loaded = state
        return state
    }

    // MARK: - Rescoring

    public func rescore(rawText: String, samples: [Float], timings: [TranscriptTiming]) async -> String? {
        guard !rawText.isEmpty, !timings.isEmpty, !samples.isEmpty else { return nil }

        // Load the dictionary and reduce it to acoustic terms (off the paste path).
        let entries = (try? await dictionary.entries()) ?? []
        let terms = DeepVocabularyMapping.terms(from: entries)
        guard !terms.isEmpty else { return nil }

        do {
            let state = try await ensureLoaded()
            let cache = try await vocabCache(for: terms, state: state)

            // Second acoustic pass: CTC log-probs over the same audio.
            let spot = try await state.spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: cache.vocabulary,
                minScore: nil
            )
            guard !spot.logProbs.isEmpty else { return nil }

            let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: cache.vocabulary.terms.count)
            let output = cache.rescorer.ctcTokenRescore(
                transcript: rawText,
                tokenTimings: timings.map {
                    TokenTiming(
                        token: $0.token, tokenId: $0.tokenID,
                        startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence
                    )
                },
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: sizeConfig.cbw,
                marginSeconds: 0.5,
                minSimilarity: max(sizeConfig.minSimilarity, cache.vocabulary.minSimilarity)
            )

            // Keep the model warm for a follow-up utterance, then unload on idle.
            await idleTimer.touch { [weak self] in await self?.unload() }

            return output.wasModified ? output.text : nil
        } catch {
            // Optional stage: any failure leaves the un-rescored text in place.
            logger.notice("deep-vocabulary rescore skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Build (or reuse) the tokenised vocabulary + rescorer for `terms`. Rebuilt
    /// only when the term set changes (the rescorer bakes in the term set).
    private func vocabCache(for terms: [VocabularyTerm], state: Loaded) async throws -> VocabCache {
        let signature = Self.signature(of: terms)
        if let vocabCache, vocabCache.signature == signature { return vocabCache }

        let vocabTerms: [CustomVocabularyTerm] = terms.compactMap { term in
            let ids = state.tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                aliases: term.aliases.isEmpty ? nil : term.aliases,
                ctcTokenIds: ids
            )
        }
        let vocabulary = CustomVocabularyContext(terms: vocabTerms)
        // Spotter-anchored acoustic rescue OFF (FluidAudio #702/#724): that pass
        // bypasses the string-similarity gate and, with the flat context-biasing
        // boost, replaced unrelated words with dictionary terms on ~every
        // utterance ("The meeting starts" → "CLAUDE.md" at similarity 0.06 —
        // the v0.12.x corruption). A user dictionary is exactly the short-vocab
        // KWS case FluidAudio documents rescue as net-harmful for. The floors
        // are defense-in-depth should rescue ever be switched back on.
        let config = VocabularyRescorer.Config(
            spotterRescueMinSimilarity: 0.30,
            spotterRescueMultiWordMinSimilarity: 0.50,
            spotterRescueEnabled: false
        )
        let rescorer = try await VocabularyRescorer.create(
            spotter: state.spotter, vocabulary: vocabulary, config: config, ctcModelDirectory: modelDirectory
        )
        let cache = VocabCache(signature: signature, vocabulary: vocabulary, rescorer: rescorer)
        vocabCache = cache
        return cache
    }

    private static func signature(of terms: [VocabularyTerm]) -> Int {
        var hasher = Hasher()
        for term in terms {
            hasher.combine(term.text)
            hasher.combine(term.aliases)
        }
        return hasher.finalize()
    }
}

private enum DeepVocabError: Error {
    case modelNotDownloaded
}
