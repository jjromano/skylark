import ApplicationServices
import Testing
import Foundation
import SkylarkCore

// MARK: - Test doubles

private final class HistoryFakeCapture: AudioCapturing, @unchecked Sendable {
    let clip: AudioClip
    let levels: AsyncStream<Float>

    init(clip: AudioClip) {
        self.clip = clip
        let (stream, cont) = AsyncStream<Float>.makeStream()
        cont.finish()
        levels = stream
    }

    func prepare() {}
    func start() throws {}
    func stop() -> AudioClip { clip }
}

private actor HistorySpyInjector: TextInjecting {
    private let direct: Bool
    init(direct: Bool) { self.direct = direct }

    func insert(_ text: String) async throws -> InsertionToken {
        let method: InsertionToken.Method = direct ? .ax(AXUIElementCreateSystemWide()) : .paste
        return InsertionToken(method: method, text: text, pasteUncertain: false)
    }
    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { direct }
}

private struct HistorySpyCleaner: Cleaner {
    let tier: CleanupTier
    let output: String
    func clean(_ transcript: String, context: CleanupContext) async throws -> String { output }
}

/// Thread-safe collector for the two history sinks.
private final class HistorySink: @unchecked Sendable {
    private let lock = NSLock()
    private var appended: [HistoryRecord] = []
    private var updated: [HistoryRecord] = []

    func record(_ record: HistoryRecord) { lock.lock(); appended.append(record); lock.unlock() }
    func update(_ record: HistoryRecord) { lock.lock(); updated.append(record); lock.unlock() }

    var appendedRecords: [HistoryRecord] { lock.lock(); defer { lock.unlock() }; return appended }
    var updatedRecords: [HistoryRecord] { lock.lock(); defer { lock.unlock() }; return updated }
}

@Suite("DictationOrchestrator history sink")
struct HistorySinkTests {
    private func makeClip() -> AudioClip {
        AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.5)
    }

    private func modes(tier: CleanupTier) -> InMemoryModeProvider {
        InMemoryModeProvider(modes: [
            DictationMode(id: "d", name: "Default", bundleIDPattern: nil, cleanupTier: tier, isDefault: true),
        ])
    }

    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("Completed dictation appends a HistoryRecord with raw text, engine, latency")
    func appendsOnCompletion() async {
        let sink = HistorySink()
        let orchestrator = DictationOrchestrator(
            capture: HistoryFakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: HistorySpyInjector(direct: true),
            modeProvider: modes(tier: .raw),
            historyRecord: { record, _ in sink.record(record) },
            historyUpdate: { sink.update($0) }
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()

        let records = sink.appendedRecords
        #expect(records.count == 1)
        let record = records.first
        #expect(record?.rawText == StubTranscriber.output)
        #expect(record?.engine == "stub")
        #expect(record?.modeID == "d")
        #expect(record?.durationMs == 500)
        #expect(record?.cleanText == nil) // raw tier
        #expect((record?.latencyMs ?? -1) >= 0)
    }

    @Test("AX cleanup replace emits a clean-text update for the same dictation")
    func updatesCleanTextAfterReplace() async {
        let sink = HistorySink()
        let cleaner = HistorySpyCleaner(tier: .local, output: "CLEANED")
        let orchestrator = DictationOrchestrator(
            capture: HistoryFakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: HistorySpyInjector(direct: true),
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(tier: .local),
            historyRecord: { record, _ in sink.record(record) },
            historyUpdate: { sink.update($0) }
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()

        let appended = sink.appendedRecords
        let updated = sink.updatedRecords
        #expect(appended.count == 1)
        #expect(updated.count == 1)
        #expect(updated.first?.cleanText == "CLEANED")
        // Correlates by timestamp with the appended row.
        #expect(updated.first?.timestamp == appended.first?.timestamp)
    }

    @Test("Paste wait-for-clean records the clean text inline (no separate update)")
    func pasteRecordsCleanInline() async {
        let sink = HistorySink()
        let cleaner = HistorySpyCleaner(tier: .local, output: "CLEANED")
        let orchestrator = DictationOrchestrator(
            capture: HistoryFakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: HistorySpyInjector(direct: false),
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(tier: .local),
            historyRecord: { record, _ in sink.record(record) },
            historyUpdate: { sink.update($0) }
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()

        #expect(sink.appendedRecords.first?.cleanText == "CLEANED")
        #expect(sink.updatedRecords.isEmpty)
    }
}
