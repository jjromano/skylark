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
        // Cleanup (Tier 2) — gpt-oss-20b is the default (best evaluated
        // quality-at-speed; Groq-pinned, endpoint confirmed live 2026-07-31).
        .init(slug: "openai/gpt-oss-20b", label: "GPT-OSS 20B (Groq)", providerPin: "groq", kind: .cleanup, sort: 0),
        // Groq retires the llama-3.1-8b-instant backend on 2026-08-16, which
        // would strand a groq pin — un-pinned 2026-07-31 so OpenRouter routes
        // it (DeepInfra/Novita/Cloudflare still serve it), slower but alive.
        // llama-3.3-70b was retired from the seed 2026-07-22 (syncSeed removes
        // it from installs); gpt-oss-120b is the big-model replacement.
        .init(slug: "meta-llama/llama-3.1-8b-instruct", label: "Llama 3.1 8B", providerPin: nil, kind: .cleanup, sort: 1),
        .init(slug: "openai/gpt-oss-120b", label: "GPT-OSS 120B (Groq)", providerPin: "groq", kind: .cleanup, sort: 2),
        // Cloud STT. NOTE: `providerPin` is inert for every row here —
        // OpenRouter does NOT apply per-request routing controls (`order`,
        // `only`, `allow_fallbacks`, `sort`) on /api/v1/audio/transcriptions,
        // and the response does not say which provider served the request.
        //
        // whisper-large-v3-turbo in particular is no longer Groq-only: OpenRouter
        // load-balances it across Groq and DeepInfra by price, which are far
        // apart on speed. That is why cloud STT latency varies by seconds with no
        // relation to clip length, and why the old "Groq Fast Whisper" label was
        // a promise the transport cannot keep. Pinning a fast provider requires
        // calling that provider directly, not through OpenRouter.
        .init(slug: "openai/whisper-large-v3-turbo", label: "Whisper large-v3-turbo", providerPin: nil, kind: .stt, sort: 0),
        .init(slug: "openai/gpt-4o-transcribe", label: "GPT-4o Transcribe", providerPin: nil, kind: .stt, sort: 1),
        .init(slug: "openai/gpt-4o-mini-transcribe", label: "GPT-4o Mini Transcribe", providerPin: nil, kind: .stt, sort: 2),
        // 2026 transcription entrants — each has a single OpenRouter provider
        // (Deepgram / Azure / Mistral respectively), so no pin needed.
        .init(slug: "deepgram/nova-3", label: "Deepgram Nova-3", providerPin: nil, kind: .stt, sort: 3),
        .init(slug: "microsoft/mai-transcribe-1.5", label: "MAI Transcribe 1.5", providerPin: nil, kind: .stt, sort: 4),
        .init(slug: "mistralai/voxtral-mini-transcribe", label: "Voxtral Mini Transcribe", providerPin: nil, kind: .stt, sort: 5),
    ]

    /// Labels a seed slug shipped in a PAST seed, keyed by slug, other than its
    /// current `seed` label. Sourced from `git log -p` on this file.
    ///
    /// `RegistryStore.syncSeed()` uses this to adopt (mark `seeded`) a row that
    /// predates the `seeded` column (added later, `DEFAULT 0`): such a row is
    /// otherwise indistinguishable from a genuine user-created row and never
    /// gets refreshed, so a real install can be stuck showing "Groq Fast
    /// Whisper" for `openai/whisper-large-v3-turbo` forever even though 0.19.0
    /// renamed it (see the seed comment above — that slug is no longer
    /// Groq-only, so the old label promised speed the transport can't keep).
    public static let legacyLabels: [String: [String]] = [
        "openai/whisper-large-v3-turbo": ["Groq Fast Whisper"],
        "meta-llama/llama-3.1-8b-instruct": ["Llama 3.1 8B (Groq)"],
    ]
}
