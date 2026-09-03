import SkylarkCore

/// Static catalog of model blurbs + accuracy/latency (or quality/speed) scores
/// shown in the Models pane. Purely descriptive — no behavior. Scores are on a
/// 1–5 scale in half-point steps and rendered as dots by `ScoreDots`.
enum ModelInfo {
    struct Entry {
        let description: String
        /// Left-hand score (Accuracy for STT, Quality for cleanup). Nil when a
        /// model isn't scored (e.g. VAD, which doesn't transcribe).
        let primaryScore: Double?
        let primaryLabel: String
        /// Right-hand score (Latency for STT, Speed for cleanup).
        let secondaryScore: Double?
        let secondaryLabel: String
        /// Estimated monthly OpenRouter cost at ~5 hrs/month of dictation
        /// (~10 min/day); nil for on-device/free models.
        let costPerMonth: String?

        init(
            _ description: String,
            primary: Double? = nil, primaryLabel: String = "Accuracy",
            secondary: Double? = nil, secondaryLabel: String = "Latency",
            costPerMonth: String? = nil
        ) {
            self.description = description
            self.primaryScore = primary
            self.primaryLabel = primaryLabel
            self.secondaryScore = secondary
            self.secondaryLabel = secondaryLabel
            self.costPerMonth = costPerMonth
        }
    }

    // MARK: On-device (by `AppController.ManagedModel`)

    static let onDevice: [AppController.ManagedModel: Entry] = [
        .parakeet: Entry(
            "NVIDIA Parakeet on the Apple Neural Engine. Fast, English-first dictation (25 languages). Skylark's default.",
            primary: 4.5, secondary: 5
        ),
        .whisper: Entry(
            "OpenAI Whisper tuned for Apple Silicon via WhisperKit. Top accuracy across 99 languages; a little slower than Parakeet.",
            primary: 5, secondary: 3.5
        ),
        .vad: Entry(
            "Voice-activity detection for hands-free (double-tap-lock) dictation — detects when you stop speaking. Not a transcriber."
        ),
        .deepVocab: Entry(
            "Parakeet CTC 110M helper for deep vocabulary matching — a second on-device acoustic pass that recognizes your dictionary's names and terms as spoken. Downloaded only when you enable the feature (Settings → Dictionary). Not a transcriber."
        ),
    ]

    // MARK: Cleanup · on device (hardcoded — not a `ManagedModel` or registry slug)

    /// macOS Apple Intelligence (Foundation Models), used for local cleanup.
    /// Not downloadable and not in the model registry, so it's a standalone
    /// entry rather than a dictionary keyed by model/slug.
    static let appleIntelligence = Entry(
        "macOS Apple Intelligence (Foundation Models) — on-device, private, free, no download. Used when cleanup tier is Local. Needs Apple Intelligence enabled in System Settings.",
        // Stars track the measured comparison below (17/29 at ~1.2 s), so this
        // row and the table cannot disagree on the same screen.
        primary: 3.5, primaryLabel: "Quality", secondary: 3, secondaryLabel: "Speed"
    )

    /// Downloadable Qwen3 GGUF models run locally through llama.cpp (keyed by
    /// `LocalCleanupModel.id`) — an alternative to Apple Intelligence that works
    /// on machines without Apple Intelligence enabled, or when you'd rather not
    /// use it.
    static let qwenLocal: [String: Entry] = [
        "qwen3-1.7b": Entry(
            "Qwen3 1.7B, quantized (Q4_K_M) — small and fast, runs fully offline through llama.cpp. Fastest local option; a little less accurate than Apple Intelligence.",
            primary: 3, primaryLabel: "Quality", secondary: 4.5, secondaryLabel: "Speed"
        ),
        "qwen3-4b-instruct": Entry(
            "Qwen3 4B Instruct, quantized (Q4_K_M) — the most accurate local cleanup, and faster than Apple Intelligence, at the cost of a 2.5 GB download and ~3 GB of memory while loaded.",
            primary: 4.5, primaryLabel: "Quality", secondary: 4, secondaryLabel: "Speed"
        ),
    ]

    /// Measured comparison of the three local cleanup tiers on Skylark's
    /// 29-case cleanup test set, for the small table in the Models pane.
    /// Measured 2026-08-31 / 2026-09-02 on an M3 MacBook Air (Apple
    /// Intelligence) and an M4 Mac mini (Qwen3 1.7B / Qwen3 4B Instruct).
    /// Re-measure and update these rows in one place when the corpus or
    /// models change; download sizes come from `LocalCleanupModel` itself
    /// rather than being restated here.
    enum LocalCleanupComparison {
        struct Row {
            let name: String
            let exactMatches: Int
            let avgLatencySeconds: Double
            /// nil for Apple Intelligence, which ships with macOS.
            let downloadBytes: Int64?
            let residentMemoryGB: Double
        }

        static let corpusSize = 29

        static let rows: [Row] = [
            Row(name: "Apple Intelligence", exactMatches: 17, avgLatencySeconds: 1.2, downloadBytes: nil, residentMemoryGB: 0),
            Row(name: "Qwen3 1.7B", exactMatches: 14, avgLatencySeconds: 0.3, downloadBytes: LocalCleanupModel.qwen3_1_7B.downloadBytes, residentMemoryGB: 1.5),
            Row(name: "Qwen3 4B Instruct", exactMatches: 25, avgLatencySeconds: 0.5, downloadBytes: LocalCleanupModel.qwen3_4BInstruct.downloadBytes, residentMemoryGB: 3),
        ]
    }

    // MARK: Speech · on device (system-managed, not a downloadable `ManagedModel` dir)

    /// macOS 26 Apple Speech (SpeechAnalyzer/SpeechTranscriber). The speech asset
    /// is downloaded and managed by macOS (no fixed size, no delete here); native
    /// punctuation and capitalization come built in.
    static let appleSpeech = Entry(
        "macOS on-device speech recognition (SpeechAnalyzer). Private, offline, with native punctuation and capitalization. The language asset is downloaded and managed by macOS — no fixed size, and it's removed in System Settings, not here.",
        primary: 4, secondary: 4.5
    )

    // MARK: Cloud (by registry slug)

    static let cloudSTT: [String: Entry] = [
        "openai/whisper-large-v3-turbo": Entry(
            "Whisper large-v3-turbo through OpenRouter, which routes each request to Groq or DeepInfra by price — accurate, but speed varies by seconds. For consistently fast Groq speed, pick Groq direct with a Groq key.",
            primary: 4.5, secondary: 4.5, costPerMonth: "≈ $0.20/mo"
        ),
        "openai/gpt-4o-transcribe": Entry(
            "OpenAI's flagship transcription — best-in-class accuracy, robust to noise and accents.",
            primary: 5, secondary: 4, costPerMonth: "≈ $1.80/mo"
        ),
        "openai/gpt-4o-mini-transcribe": Entry(
            "Lighter, cheaper GPT-4o transcription — nearly as accurate, faster and cheaper.",
            primary: 4.5, secondary: 4.5, costPerMonth: "≈ $0.90/mo"
        ),
        "deepgram/nova-3": Entry(
            "Deepgram's flagship ASR — strong accuracy on real-world speech, very fast batch turnaround ($0.0043/min).",
            primary: 4.5, secondary: 4.5, costPerMonth: "≈ $1.30/mo"
        ),
        "microsoft/mai-transcribe-1.5": Entry(
            "Microsoft's 2026 transcription model — current independent accuracy leader, fast batch; served via Azure ($0.36/hr).",
            primary: 5, secondary: 4.5, costPerMonth: "≈ $1.80/mo"
        ),
        "mistralai/voxtral-mini-transcribe": Entry(
            "Mistral's dedicated transcription model — accuracy near the leaders at a budget price ($0.003/min).",
            primary: 4.5, secondary: 4.5, costPerMonth: "≈ $0.90/mo"
        ),
    ]

    static let cloudCleanup: [String: Entry] = [
        "meta-llama/llama-3.1-8b-instruct": Entry(
            "Cheapest cleanup: punctuation, capitalization, filler removal. No longer Groq-served, so speed varies by provider.",
            primary: 3.5, primaryLabel: "Quality", secondary: 3.5, secondaryLabel: "Speed",
            costPerMonth: "< $0.01/mo"
        ),
        "openai/gpt-oss-20b": Entry(
            "Balanced open model on Groq — better phrasing fixes than 8B and still fast. The recommended default.",
            primary: 4, primaryLabel: "Quality", secondary: 4.5, secondaryLabel: "Speed",
            costPerMonth: "≈ $0.03/mo"
        ),
        "openai/gpt-oss-120b": Entry(
            "Big open model on Groq (~500 tok/s) — smartest cleanup option; Groq's successor to Llama 3.3 70B.",
            primary: 4.5, primaryLabel: "Quality", secondary: 4, secondaryLabel: "Speed",
            costPerMonth: "≈ $0.02/mo"
        ),
    ]
}
