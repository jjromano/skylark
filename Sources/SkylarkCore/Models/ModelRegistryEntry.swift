import Foundation

/// One selectable model (PRD §7). Persisted by `RegistryStore`; consumed by the
/// quick-switcher and the OpenRouter clients.
public struct ModelRegistryEntry: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case stt
        case cleanup
    }

    /// OpenRouter slug, e.g. "meta-llama/llama-3.1-8b-instruct".
    public let slug: String
    public let label: String
    /// Provider to pin via `provider.order` (soft pin, fallbacks allowed).
    public let providerPin: String?
    public let kind: Kind
    public let sort: Int

    public var id: String { slug }

    public init(slug: String, label: String, providerPin: String?, kind: Kind, sort: Int) {
        self.slug = slug
        self.label = label
        self.providerPin = providerPin
        self.kind = kind
        self.sort = sort
    }

    /// Seed registry (verified live on OpenRouter, 2026-07). Order = UI order.
    public static let seed: [ModelRegistryEntry] = [
        // Cleanup (Tier 2) — Groq-pinned for speed; 8B is the default.
        .init(slug: "meta-llama/llama-3.1-8b-instruct", label: "Llama 3.1 8B (Groq)", providerPin: "groq", kind: .cleanup, sort: 0),
        .init(slug: "openai/gpt-oss-20b", label: "GPT-OSS 20B (Groq)", providerPin: "groq", kind: .cleanup, sort: 1),
        .init(slug: "meta-llama/llama-3.3-70b-instruct", label: "Llama 3.3 70B (Groq)", providerPin: "groq", kind: .cleanup, sort: 2),
        // Groq deprecates llama-3.1-8b-instant / llama-3.3-70b-versatile on
        // 2026-08-16; gpt-oss-120b is Groq's recommended replacement (~500 t/s,
        // Cerebras/others as soft-pin fallbacks).
        .init(slug: "openai/gpt-oss-120b", label: "GPT-OSS 120B (Groq)", providerPin: "groq", kind: .cleanup, sort: 3),
        // Cloud STT — Groq is whisper-large-v3-turbo's sole provider (no pin needed).
        .init(slug: "openai/whisper-large-v3-turbo", label: "Groq Fast Whisper", providerPin: nil, kind: .stt, sort: 0),
        .init(slug: "openai/gpt-4o-transcribe", label: "GPT-4o Transcribe", providerPin: nil, kind: .stt, sort: 1),
        .init(slug: "openai/gpt-4o-mini-transcribe", label: "GPT-4o Mini Transcribe", providerPin: nil, kind: .stt, sort: 2),
        // 2026 transcription entrants — each has a single OpenRouter provider
        // (Deepgram / Azure / Mistral respectively), so no pin needed.
        .init(slug: "deepgram/nova-3", label: "Deepgram Nova-3", providerPin: nil, kind: .stt, sort: 3),
        .init(slug: "microsoft/mai-transcribe-1.5", label: "MAI Transcribe 1.5", providerPin: nil, kind: .stt, sort: 4),
        .init(slug: "mistralai/voxtral-mini-transcribe", label: "Voxtral Mini Transcribe", providerPin: nil, kind: .stt, sort: 5),
    ]
}
