import Foundation

/// Placeholder engine that exercises the pipeline end-to-end without any model.
/// Sleeps briefly to mimic decode latency, then returns fixed text.
public struct StubTranscriber: Transcriber {
    public let id: TranscriberID = .stub

    /// Fixed output — never contains real transcript content (privacy invariant).
    public static let output = "Skylark stub: end-to-end pipeline works."

    public init() {}

    public func warmUp() async throws {
        // Nothing to load.
    }

    public func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        try await Task.sleep(for: .milliseconds(50))
        return Self.output
    }
}
