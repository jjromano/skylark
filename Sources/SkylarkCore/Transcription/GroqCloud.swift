import Foundation

/// Cloud STT straight to Groq, bypassing OpenRouter's provider lottery.
///
/// Same contract as `OpenRouterCloud` — encode the clip, one request, return the
/// text — but it uploads WAV bytes in a multipart body rather than base64 inside
/// JSON, and it reaches a single known provider.
///
/// On the WAV-vs-FLAC question: Groq accepts and recommends FLAC, and Skylark
/// already captures the 16 kHz mono it wants. Measured on this machine, though,
/// FLAC over a speech-shaped 3.2 s clip came out at 105 KB against 102 KB of raw
/// WAV, while costing 8-15 ms of encode ON the paste path. Multipart alone
/// already removes the 33% base64 inflation (137 KB → 102 KB) for free, so WAV
/// it is until a measurement on real dictation audio says otherwise.
public struct GroqCloud: Transcriber {
    public let id: TranscriberID

    private let client: GroqSpeechClient
    private let model: String
    private let language: String?

    /// Groq's model id for the fast Whisper. Not an OpenRouter slug — the
    /// direct API takes bare model names.
    public static let defaultModel = "whisper-large-v3-turbo"

    public init(
        client: GroqSpeechClient,
        model: String = GroqCloud.defaultModel,
        language: String? = "en"
    ) {
        self.client = client
        self.model = model
        self.language = language
        self.id = .cloud("groq/\(model)")
    }

    public func warmUp() async throws {
        // Nothing resident to load.
    }

    public func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        // Same too-short/silent guard every other engine applies, so a clip the
        // local engines would skip never costs a round trip or money.
        if FluidAudioParakeet.shouldSkip(clip) { return "" }

        let wav = WavEncoder.encode(samples: clip.samples, sampleRate: clip.sampleRate)
        let response = try await client.transcribe(
            audio: wav,
            filename: "audio.wav",
            contentType: "audio/wav",
            model: model,
            language: hint.locale ?? language
        )
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
