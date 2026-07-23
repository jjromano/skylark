import Foundation
import NaturalLanguage
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// One local-model cleanup generation, abstracted so the logic (prompt assembly,
/// token budgeting, output hygiene, the unavailable path) is unit-testable
/// without Apple Intelligence. The live conformer talks to Apple
/// `FoundationModels`; tests supply a fake.
public protocol LocalCleanupBackend: Sendable {
    /// nil when the model can run here; otherwise a human-readable reason the app
    /// can surface (e.g. "Apple Intelligence is not enabled").
    func unavailability() async -> String?
    /// Run one cleanup generation with a fresh session and a plain-string response.
    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String
    /// Warm the next session so a subsequent request is low-latency. Called off
    /// the paste path after each use.
    func prewarm(instructions: String) async
}

/// Tier 1 cleaner — Apple on-device Foundation Models (ARCHITECTURE §0).
///
/// Availability is a supported runtime state, not an error: this build box
/// reports `appleIntelligenceNotEnabled`, so the pipeline must fall back to raw
/// text rather than crash. Generation is structured behind `LocalCleanupBackend`
/// so prompt/hygiene/unavailable paths are testable without real generation.
public struct LocalCleaner: Cleaner {
    public let tier: CleanupTier = .local

    private let backend: any LocalCleanupBackend

    /// Rough token estimate — 4 chars/token (ARCHITECTURE §1 heuristic).
    static let charsPerToken = 4
    /// Above this many estimated transcript tokens, clean in sentence-window
    /// chunks instead of one generation. Set high enough that an ordinary
    /// single dictation utterance (up to ~130 words) is cleaned in ONE
    /// generation: the on-device model punctuates a whole unpunctuated run into
    /// real sentences perfectly well, whereas chunking an unpunctuated run cuts
    /// it at arbitrary word boundaries — which made the model reformat fragments
    /// as bogus lists and produced mid-sentence capitals at the window seams
    /// (the v0.2.1 "stray capital" bug). Chunking is retained only as a safety
    /// valve for genuinely huge dictation, where a single generation would risk
    /// the response-token cap; the seam join (`joinChunks`) repairs continuation
    /// capitalization for that path. The model's 4096-token context makes a
    /// 200-token input + its output trivially safe in one shot.
    public static let chunkTokenThreshold = 200
    /// Hard cap on requested response tokens regardless of input size.
    static let responseTokenCap = 1024
    /// Floor so very short transcripts still get room to breathe.
    static let responseTokenFloor = 64

    /// Local-tier faithfulness floors handed to `CleanupHygiene.validate`.
    /// Stricter than the cloud defaults because the ~3B on-device model
    /// paraphrases/summarizes more; see `CleanupHygiene` for what each guards.
    /// A chunk (or short transcript) failing these keeps its RAW text rather
    /// than the model's rewrite — faithful by construction.
    public static let localRetentionFloor = 0.55
    public static let localContentLossFloor = 0.60

    /// Testing seam — inject a fake backend (real generation isn't runnable on
    /// the CLT-only box).
    public init(backend: any LocalCleanupBackend) {
        self.backend = backend
    }

    public init() {
        self.backend = Self.makeDefaultBackend()
    }

    /// The default on-device backend for this build: the live Apple
    /// `FoundationModels` conformer where available, else an unavailable stub.
    /// Exposed so other on-device consumers (e.g. Voice Command Mode's local
    /// runner) can build the same backend without reaching into internals.
    public static func makeDefaultBackend() -> any LocalCleanupBackend {
        #if canImport(FoundationModels)
        return FoundationModelBackend()
        #else
        return UnavailableBackend(reason: "on-device model framework unavailable in this build")
        #endif
    }

    public func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        if let reason = await backend.unavailability() {
            throw CleanerError.unavailable(reason: reason)
        }

        // Local tier uses the compact, few-shot prompt (cloud keeps the fuller
        // `instructions`); both share the same session-prewarm pattern.
        let instructions = CleanupPrompt.compactInstructions(context: context)
        // Translation mode bypasses the source-language faithfulness guards (a
        // correct translation shares no source vocabulary); empty/runaway and
        // meta-commentary checks still apply.
        let translated = context.translateTo != nil
        let estimatedTokens = Self.estimatedTokens(transcript)

        // Short transcript → single generation (today's behavior). No chunking
        // overhead below the threshold.
        guard estimatedTokens > Self.chunkTokenThreshold else {
            let maxTokens = Self.maximumResponseTokens(forTranscriptTokens: estimatedTokens)
            let raw = try await backend.generate(
                instructions: instructions,
                userMessage: CleanupPrompt.userMessage(transcript: transcript),
                maximumResponseTokens: maxTokens
            )
            // Prewarm the next session off the paste path (this whole call
            // already runs detached from the HUD state), then apply hygiene
            // with the strict local floors — a failure keeps the RAW transcript.
            await backend.prewarm(instructions: instructions)
            return try CleanupHygiene.validate(
                raw,
                transcript: transcript,
                retentionFloor: Self.localRetentionFloor,
                contentLossFloor: Self.localContentLossFloor,
                fieldContext: context.fieldContext,
                translated: translated
            )
        }

        // Longer transcript → sentence-window chunking. Each chunk is cleaned in
        // its own generation and validated independently; a chunk that fails
        // validation (or whose generation errors) keeps its RAW text so the
        // whole transcript never fails. Arbitrarily long transcripts now
        // succeed (no more too-long bail-out).
        let chunks = Self.sentenceChunks(transcript, maxTokens: Self.chunkTokenThreshold)
        var parts: [String] = []
        parts.reserveCapacity(chunks.count)
        for chunk in chunks {
            let maxTokens = Self.maximumResponseTokens(forTranscriptTokens: Self.estimatedTokens(chunk))
            do {
                let raw = try await backend.generate(
                    instructions: instructions,
                    userMessage: CleanupPrompt.userMessage(transcript: chunk),
                    maximumResponseTokens: maxTokens
                )
                parts.append(try CleanupHygiene.validate(
                    raw,
                    transcript: chunk,
                    retentionFloor: Self.localRetentionFloor,
                    contentLossFloor: Self.localContentLossFloor,
                    fieldContext: context.fieldContext,
                    translated: translated
                ))
            } catch {
                parts.append(chunk) // keep this chunk's raw text; never fail the whole
            }
        }
        await backend.prewarm(instructions: instructions)
        return Self.joinChunks(parts)
    }

    /// Reassemble cleaned chunks. Each chunk was cleaned in isolation, so the
    /// model capitalized its first word even when the chunk merely *continues*
    /// the previous chunk's sentence (window seams fall mid-thought for
    /// unpunctuated dictation). Join with a space, but when the accumulated text
    /// does NOT already end a sentence (no terminal `.`/`!`/`?`/`:`/newline),
    /// lowercase the continuation chunk's first word so the seam reads as one
    /// sentence — unless that word is "I"/"I'…" or looks like a proper noun
    /// (all-caps acronym, or a longer capitalized word we leave alone rather
    /// than risk down-casing a name). Newlines the model produced inside a chunk
    /// (list formatting, "new paragraph") are preserved.
    public static func joinChunks(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            guard !result.isEmpty else { result = p; continue }
            let endsSentence = result.last.map { ".!?:\n".contains($0) } ?? true
            result += " " + (endsSentence ? p : lowercasedContinuation(p))
        }
        return result
    }

    /// Lowercase the first letter of a continuation chunk unless it's a word we
    /// must not down-case: "I"/"I'm"/"I'll"…, or an all-caps token (acronym).
    private static func lowercasedContinuation(_ chunk: String) -> String {
        let firstWord = chunk.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? chunk
        if firstWord == "I" || firstWord.hasPrefix("I'") || firstWord.hasPrefix("I\u{2019}") { return chunk }
        // All-caps acronym (e.g. "API", "SQL") — leave it.
        let letters = firstWord.filter { $0.isLetter }
        if letters.count >= 2, letters == letters.uppercased() { return chunk }
        return chunk.prefix(1).lowercased() + chunk.dropFirst()
    }

    // MARK: - Pure helpers (unit-tested)

    public static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / charsPerToken)
    }

    /// Split `text` into chunks of at most `maxTokens` estimated tokens, cutting
    /// only on sentence boundaries (`NLTokenizer(unit: .sentence)`). Adjacent
    /// sentences are packed greedily into one chunk until the next would exceed
    /// the budget. A single sentence longer than the budget (common for raw
    /// dictation, which often arrives unpunctuated as one long "sentence") is
    /// broken into word windows so chunks stay bounded and arbitrarily long
    /// input still succeeds. Pure and deterministic for unit testing.
    public static func sentenceChunks(_ text: String, maxTokens: Int) -> [String] {
        let sentences = splitSentences(text)
        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            if estimatedTokens(s) > maxTokens {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: wordWindows(s, maxTokens: maxTokens))
                continue
            }
            let candidate = current.isEmpty ? s : current + " " + s
            if estimatedTokens(candidate) > maxTokens {
                if !current.isEmpty { chunks.append(current) }
                current = s
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    /// Sentence-tokenize with `NaturalLanguage` (no new dependency). Falls back
    /// to the whole string when tokenization yields nothing.
    private static func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(String(text[range]))
            return true
        }
        return result.isEmpty ? [text] : result
    }

    /// Break an over-long sentence into whitespace-delimited windows each at or
    /// below `maxTokens`. A single word longer than the budget still forms its
    /// own window (never dropped).
    private static func wordWindows(_ sentence: String, maxTokens: Int) -> [String] {
        let words = sentence.split { $0.isWhitespace }.map(String.init)
        var windows: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if !current.isEmpty, estimatedTokens(candidate) > maxTokens {
                windows.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    /// ~2× transcript tokens, clamped to [floor, cap].
    public static func maximumResponseTokens(forTranscriptTokens transcriptTokens: Int) -> Int {
        min(responseTokenCap, max(responseTokenFloor, transcriptTokens * 2))
    }

    /// Trim surrounding whitespace and a single layer of wrapping quotes.
    /// Delegates to the shared `CleanupHygiene` so local and cloud tiers share
    /// one implementation.
    public static func sanitize(_ output: String) -> String {
        CleanupHygiene.sanitize(output)
    }
}

#if canImport(FoundationModels)
public extension LocalCleaner {
    /// Cleanup decoding options. Greedy (deterministic) sampling is Apple's
    /// recommended mode for strict instruction following on the on-device
    /// model — it stops the ~3B model from creatively rewording the transcript,
    /// which temperature sampling encouraged. A pure value factory so the choice
    /// is unit-testable without live generation (Apple Intelligence is off on
    /// the build box); building `GenerationOptions` needs no model.
    static func cleanupOptions(maximumResponseTokens: Int) -> GenerationOptions {
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
    }
}
#endif

/// Backend used when `FoundationModels` can't be imported at all.
struct UnavailableBackend: LocalCleanupBackend {
    let reason: String
    func unavailability() async -> String? { reason }
    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        throw CleanerError.unavailable(reason: reason)
    }
    func prewarm(instructions: String) async {}
}

#if canImport(FoundationModels)
/// Live Apple Foundation Models backend. Holds one prewarmed session for the
/// common (repeat-context) case; a session that has already responded is never
/// reused (fresh 4096-token context, no accumulation).
actor FoundationModelBackend: LocalCleanupBackend {
    private var prewarmed: (instructions: String, session: LanguageModelSession)?

    func unavailability() async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return Self.describe(reason)
        @unknown default:
            return "the on-device model is unavailable"
        }
    }

    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        let session: LanguageModelSession
        if let prewarmed, prewarmed.instructions == instructions {
            session = prewarmed.session
            self.prewarmed = nil
        } else {
            session = LanguageModelSession(instructions: { instructions })
        }
        let response = try await session.respond(
            to: userMessage,
            options: LocalCleaner.cleanupOptions(maximumResponseTokens: maximumResponseTokens)
        )
        return response.content
    }

    func prewarm(instructions: String) async {
        let session = LanguageModelSession(instructions: { instructions })
        session.prewarm()
        prewarmed = (instructions, session)
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled"
        case .deviceNotEligible:
            return "this device does not support Apple Intelligence"
        case .modelNotReady:
            return "the on-device model is still preparing"
        @unknown default:
            return "the on-device model is unavailable"
        }
    }
}
#endif
