import Testing
import Foundation
import SkylarkCore

// MARK: - Test doubles

/// Configurable transcriber: returns text (optionally after a delay), throws, or
/// hangs; records whether it was warmed and transcribed.
private actor FakeTranscriber: Transcriber {
    enum Behaviour: Sendable {
        case text(String)
        case delayThenText(Duration, String)
        case fail
    }

    nonisolated let id: TranscriberID
    private let behaviour: Behaviour
    private(set) var warmed = false
    private(set) var transcribeCount = 0

    init(id: TranscriberID, behaviour: Behaviour) {
        self.id = id
        self.behaviour = behaviour
    }

    func warmUp() async throws { warmed = true }

    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        transcribeCount += 1
        switch behaviour {
        case let .text(value):
            return value
        case let .delayThenText(delay, value):
            try await Task.sleep(for: delay)
            return value
        case .fail:
            throw ParakeetError.notReady
        }
    }

    func wasWarmed() -> Bool { warmed }
    func timesTranscribed() -> Int { transcribeCount }
}

private struct FailingTranscriber: Transcriber {
    let id: TranscriberID = .cloud("failing")
    func warmUp() async throws {}
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        throw ParakeetError.notReady
    }
}

/// Sendable notice collector.
private final class NoticeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
}

@Suite("FallbackTranscriber")
struct FallbackTranscriberTests {
    private let clip = AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)

    @Test("Primary OK: returns primary text, no fallback, no notice")
    func primaryOK() async throws {
        let spy = NoticeSpy()
        let primary = FakeTranscriber(id: .cloud("groq"), behaviour: .text("CLOUD"))
        let fallback = FakeTranscriber(id: .parakeet, behaviour: .text("LOCAL"))
        let transcriber = FallbackTranscriber(primary: primary, fallback: fallback) { spy.record($0) }

        let result = try await transcriber.transcribe(clip, hint: .none)
        #expect(result == "CLOUD")
        #expect(await fallback.timesTranscribed() == 0)
        #expect(spy.count == 0)
        // Reports the primary's identity.
        #expect(transcriber.id == .cloud("groq"))
    }

    @Test("Primary throws: falls back to local, emits a notice")
    func primaryThrows() async throws {
        let spy = NoticeSpy()
        let fallback = FakeTranscriber(id: .parakeet, behaviour: .text("LOCAL"))
        let transcriber = FallbackTranscriber(primary: FailingTranscriber(), fallback: fallback) { spy.record($0) }

        let result = try await transcriber.transcribe(clip, hint: .none)
        #expect(result == "LOCAL")
        #expect(await fallback.timesTranscribed() == 1)
        #expect(spy.count == 1)
    }

    @Test("Primary times out: falls back before the primary would finish")
    func primaryTimesOut() async throws {
        let spy = NoticeSpy()
        let primary = FakeTranscriber(id: .cloud("slow"), behaviour: .delayThenText(.seconds(5), "CLOUD"))
        let fallback = FakeTranscriber(id: .parakeet, behaviour: .text("LOCAL"))
        let transcriber = FallbackTranscriber(
            primary: primary, fallback: fallback, primaryTimeout: .milliseconds(40)
        ) { spy.record($0) }

        let result = try await transcriber.transcribe(clip, hint: .none)
        #expect(result == "LOCAL")
        #expect(spy.count == 1)
    }

    @Test("warmUp warms both engines (local stays resident)")
    func warmsBoth() async throws {
        let primary = FakeTranscriber(id: .cloud("groq"), behaviour: .text("CLOUD"))
        let fallback = FakeTranscriber(id: .parakeet, behaviour: .text("LOCAL"))
        let transcriber = FallbackTranscriber(primary: primary, fallback: fallback)

        try await transcriber.warmUp()
        #expect(await primary.wasWarmed())
        #expect(await fallback.wasWarmed())
    }
}
