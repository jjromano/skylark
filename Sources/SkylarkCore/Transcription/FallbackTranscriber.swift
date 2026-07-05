import Foundation

enum FallbackTranscriberError: Error, Sendable {
    /// The primary engine didn't finish within the cap; caller falls back.
    case primaryTimedOut
}

/// Wraps a `primary` transcriber (e.g. cloud STT) with a `fallback` (local
/// Parakeet), racing the primary against a short cap so a slow/unreachable cloud
/// never blocks dictation (phase-3 spec §4). On the primary throwing or timing
/// out, the fallback runs and a non-blocking notice is emitted for the menu bar.
/// `warmUp()` warms BOTH so the local engine stays resident even when cloud is
/// selected (PRD §6.2).
public struct FallbackTranscriber: Transcriber {
    public let id: TranscriberID

    private let primary: any Transcriber
    private let fallback: any Transcriber
    private let primaryTimeout: Duration
    private let notice: @Sendable (String) -> Void

    public init(
        primary: any Transcriber,
        fallback: any Transcriber,
        primaryTimeout: Duration = .seconds(10),
        notice: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.primaryTimeout = primaryTimeout
        self.notice = notice
        // Report the primary's identity — that's the engine the user selected.
        self.id = primary.id
    }

    public func warmUp() async throws {
        // Warm both; neither failure should block the other. A cloud primary's
        // warmUp is a no-op, and the local fallback must stay resident.
        async let warmedPrimary: Void = Self.warmQuietly(primary)
        async let warmedFallback: Void = Self.warmQuietly(fallback)
        _ = await (warmedPrimary, warmedFallback)
    }

    private static func warmQuietly(_ transcriber: any Transcriber) async {
        try? await transcriber.warmUp()
    }

    public func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        do {
            return try await raceTimeout {
                try await primary.transcribe(clip, hint: hint)
            }
        } catch {
            notice("Cloud transcription unavailable — using local engine")
            return try await fallback.transcribe(clip, hint: hint)
        }
    }

    /// Race `op` against `primaryTimeout`; throws `primaryTimedOut` if the clock
    /// wins. Our own cap so we never wait on URLSession's 60 s upstream timeout.
    private func raceTimeout(_ op: @escaping @Sendable () async throws -> String) async throws -> String {
        let cap = primaryTimeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: cap)
                throw FallbackTranscriberError.primaryTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw FallbackTranscriberError.primaryTimedOut
            }
            return first
        }
    }
}
