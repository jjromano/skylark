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
    ]

    // MARK: Cleanup · on device (hardcoded — not a `ManagedModel` or registry slug)

    /// macOS Apple Intelligence (Foundation Models), used for local cleanup.
    /// Not downloadable and not in the model registry, so it's a standalone
    /// entry rather than a dictionary keyed by model/slug.
    static let appleIntelligence = Entry(
        "macOS Apple Intelligence (Foundation Models) — on-device, private, free. Used when cleanup tier is Local. Needs Apple Intelligence enabled in System Settings.",
        primary: 4, primaryLabel: "Quality", secondary: 3.5, secondaryLabel: "Speed"
    )

    // MARK: Cloud (by registry slug)

    static let cloudSTT: [String: Entry] = [
        "openai/whisper-large-v3-turbo": Entry(
            "Whisper large-v3-turbo served on Groq — cloud-grade accuracy, very fast.",
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
            "Fast, cheap cleanup: punctuation, capitalization, filler removal. Good default.",
            primary: 3.5, primaryLabel: "Quality", secondary: 5, secondaryLabel: "Speed",
            costPerMonth: "< $0.01/mo"
        ),
        "openai/gpt-oss-20b": Entry(
            "Balanced open model — better phrasing fixes than 8B, still quick on Groq.",
            primary: 4, primaryLabel: "Quality", secondary: 4.5, secondaryLabel: "Speed",
            costPerMonth: "≈ $0.03/mo"
        ),
        "meta-llama/llama-3.3-70b-instruct": Entry(
            "Highest-quality cleanup here — best grammar and formatting, slightly slower.",
            primary: 4.5, primaryLabel: "Quality", secondary: 4, secondaryLabel: "Speed",
            costPerMonth: "≈ $0.08/mo"
        ),
        "openai/gpt-oss-120b": Entry(
            "Big open model on Groq (~500 tok/s) — smartest cleanup option; Groq's successor to Llama 3.3 70B.",
            primary: 4.5, primaryLabel: "Quality", secondary: 4, secondaryLabel: "Speed",
            costPerMonth: "≈ $0.02/mo"
        ),
    ]
}
