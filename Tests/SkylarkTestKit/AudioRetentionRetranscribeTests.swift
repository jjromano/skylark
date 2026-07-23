import Testing
import Foundation
import SkylarkCore

/// Opt-in audio retention + retranscribe-from-history (audio retention phase-5a
/// §2, extended): audio-only pruning, in-place retranscription, WAV round-trip,
/// write-failure resilience, and the retention-days default. Real temp dir +
/// in-memory DB throughout; no audio content is ever logged.
@Suite("Audio retention + retranscribe")
struct AudioRetentionRetranscribeTests {
    private func makeHub(retention: Bool, dir: URL) throws -> (hub: HistoryHub, store: HistoryStore) {
        let store = HistoryStore(db: try SkylarkDatabase.inMemory())
        let hub = HistoryHub(store: store, audioDirectory: dir, audioRetentionEnabled: { retention })
        return (hub, store)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeClip() -> AudioClip {
        AudioClip(samples: [0.1, -0.2, 0.3, -0.4, 0.5, -0.6], sampleRate: 16_000, duration: 0.4)
    }

    private func record(_ ts: Date, text: String = "hello world", engine: String = "parakeet") -> HistoryRecord {
        HistoryRecord(timestamp: ts, rawText: text, engine: engine, durationMs: 400, latencyMs: 50)
    }

    // MARK: - Retention-days default

    @Test("Audio retention days default to 7 when unset, otherwise pass through")
    func retentionDaysDefault() {
        #expect(HistoryStore.audioRetentionDays(stored: 0) == 7) // unset → default
        #expect(HistoryStore.audioRetentionDays(stored: 7) == 7)
        #expect(HistoryStore.audioRetentionDays(stored: 30) == 30)
        #expect(HistoryStore.audioRetentionDays(stored: 90) == 90)
    }

    @Test("Retention window round-trips through UserDefaults; audio key is distinct")
    func retentionSettingRoundTrip() {
        // The audio-retention window key must not collide with the whole-row
        // history-retention key (two independent settings).
        #expect(HistoryStore.audioRetentionDefaultsKey != HistoryStore.retentionDefaultsKey)

        let suite = "skylark.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Unset → the getter logic (mirrored in AppController) yields the 7-day
        // default rather than "0 / forever".
        #expect(HistoryStore.audioRetentionDays(
            stored: defaults.integer(forKey: HistoryStore.audioRetentionDefaultsKey)) == 7)
        // Round-trip a chosen window.
        defaults.set(30, forKey: HistoryStore.audioRetentionDefaultsKey)
        #expect(HistoryStore.audioRetentionDays(
            stored: defaults.integer(forKey: HistoryStore.audioRetentionDefaultsKey)) == 30)
    }

    // MARK: - Audio-only pruning

    @Test("pruneAudio deletes aged audio + nulls the column but keeps the rows")
    func pruneAudioKeepsRows() async throws {
        let dir = tempDir()
        let (hub, store) = try makeHub(retention: true, dir: dir)
        let old = Date().addingTimeInterval(-60 * 60 * 24 * 40) // 40 days ago
        let fresh = Date()
        // Match rows by text — a Date round-trips through SQLite with reduced
        // precision, so equality on `timestamp` is unreliable.
        await hub.record(record(old, text: "aged"), clip: makeClip())
        await hub.record(record(fresh, text: "recent"), clip: makeClip())

        let before = try await store.recent(limit: 10)
        let oldPath = try #require(before.first(where: { $0.rawText == "aged" })?.audioPath)
        let freshPath = try #require(before.first(where: { $0.rawText == "recent" })?.audioPath)

        let removed = try await store.pruneAudio(olderThanDays: 30)
        #expect(removed == 1)
        // The aged file is gone and its column nulled; the row itself remains.
        #expect(!FileManager.default.fileExists(atPath: oldPath))
        #expect(FileManager.default.fileExists(atPath: freshPath))
        let after = try await store.recent(limit: 10)
        #expect(after.count == 2) // both text rows survive
        #expect(after.first(where: { $0.rawText == "aged" })?.audioPath == nil)
        #expect(after.first(where: { $0.rawText == "recent" })?.audioPath == freshPath)
    }

    // MARK: - Write-failure resilience

    @Test("A failed audio write never blocks history recording")
    func writeFailureDoesNotBreakRecording() async throws {
        let dir = tempDir()
        // Occupy the audio-directory path with a FILE so createDirectory + the
        // WAV write both fail — the row must still persist, just without audio.
        try Data([0x00]).write(to: dir)
        let (hub, store) = try makeHub(retention: true, dir: dir)

        await hub.record(record(Date()), clip: makeClip())
        let rows = try await store.recent(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.rawText == "hello world")
        #expect(rows.first?.audioPath == nil) // write failed, but recording didn't
    }

    // MARK: - WAV round-trip

    @Test("WavDecoder round-trips samples written by WavEncoder")
    func wavRoundTrip() throws {
        let samples: [Float] = [0.0, 0.25, -0.25, 0.5, -0.5, 0.999, -0.999]
        let data = WavEncoder.encode(samples: samples, sampleRate: 16_000)
        let url = tempDir().appendingPathComponent("clip.wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let clip = try #require(WavDecoder.decode(url: url))
        #expect(clip.sampleRate == 16_000)
        #expect(clip.samples.count == samples.count)
        // PCM16 quantization tolerance (~1/32767).
        for (a, b) in zip(clip.samples, samples) {
            #expect(abs(a - b) < 0.001)
        }
    }

    @Test("WavDecoder returns nil for a missing file")
    func wavDecodeMissing() {
        #expect(WavDecoder.decode(url: tempDir().appendingPathComponent("nope.wav")) == nil)
    }

    // MARK: - Retranscribe

    @Test("Retranscription swaps raw text + engine and clears clean text")
    func retranscribeSwapsText() async throws {
        let dir = tempDir()
        let (hub, store) = try makeHub(retention: true, dir: dir)
        // Seed a row that already has clean text + a cloud cleanup engine, so we
        // can prove both are cleared by the retranscribe.
        var seed = record(Date(), engine: "whisperkit")
        seed.cleanText = "Hello, world."
        seed.cleanupEngine = "some/cloud-model"
        await hub.record(seed, clip: makeClip())

        let row = try #require(try await store.recent(limit: 1).first)
        let id = try #require(row.id)
        let path = try #require(row.audioPath)

        let newText = try await Retranscription.run(
            store: store, id: id, audioPath: path, transcriber: StubTranscriber()
        )
        #expect(newText == StubTranscriber.output)

        let updated = try #require(try await store.fetch(id: id))
        #expect(updated.rawText == StubTranscriber.output)   // raw replaced
        #expect(updated.cleanText == nil)                    // clean cleared
        #expect(updated.cleanupEngine == nil)                // cleanup engine cleared
        #expect(updated.engine == "stub")                    // engine column stamped
        #expect(updated.wordCount == WordCount.count(StubTranscriber.output))
        #expect(updated.audioPath == path)                   // audio kept for replay
    }

    @Test("Retranscription surfaces a missing clip as audioUnavailable")
    func retranscribeMissingAudio() async throws {
        let store = HistoryStore(db: try SkylarkDatabase.inMemory())
        let saved = try await store.append(record(Date()))
        let id = try #require(saved.id)
        await #expect(throws: Retranscription.Failure.audioUnavailable) {
            try await Retranscription.run(
                store: store,
                id: id,
                audioPath: self.tempDir().appendingPathComponent("gone.wav").path,
                transcriber: StubTranscriber()
            )
        }
    }
}
