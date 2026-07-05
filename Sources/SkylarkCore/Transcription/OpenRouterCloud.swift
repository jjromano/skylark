import Foundation

/// Cloud STT via OpenRouter (ARCHITECTURE §2, §6). Encodes the clip to WAV,
/// base64s it through `OpenRouterClient.transcribe`. `warmUp()` is a no-op —
/// there's no local model residency to manage. Reuses
/// `FluidAudioParakeet.shouldSkip` for the same too-short/silent clip guard
/// every engine applies, so cloud STT never spends a network round-trip (or
/// money) on a clip local engines would've skipped.
public struct OpenRouterCloud: Transcriber {
    public let id: TranscriberID

    private let client: OpenRouterClient
    private let entry: ModelRegistryEntry
    private let language: String?

    public init(client: OpenRouterClient, entry: ModelRegistryEntry, language: String? = "en") {
        self.client = client
        self.entry = entry
        self.language = language
        self.id = .cloud(entry.slug)
    }

    public func warmUp() async throws {
        // No local model to load/keep resident.
    }

    public func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        if FluidAudioParakeet.shouldSkip(clip) { return "" }

        let wav = WavEncoder.encode(samples: clip.samples, sampleRate: clip.sampleRate)
        let response = try await client.transcribe(
            audio: wav,
            format: "wav",
            model: entry.slug,
            language: hint.locale ?? language
        )
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
