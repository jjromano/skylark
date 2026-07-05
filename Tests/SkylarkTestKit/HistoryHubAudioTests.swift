import Testing
import Foundation
import SkylarkCore

/// Audio retention (phase-5a spec §2): `HistoryHub` writes a WAV only when
/// retention is on, deletes files alongside their row/purge, and sweeps
/// orphaned files at launch. All against a real temp directory + in-memory DB.
@Suite("HistoryHub audio retention (write/delete/orphan-sweep)")
struct HistoryHubAudioTests {
    private func makeHub(retention: Bool) throws -> (hub: HistoryHub, store: HistoryStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = HistoryStore(db: try SkylarkDatabase.inMemory())
        let hub = HistoryHub(store: store, audioDirectory: dir, audioRetentionEnabled: { retention })
        return (hub, store, dir)
    }

    private func makeClip() -> AudioClip {
        AudioClip(samples: [0.1, -0.2, 0.3, -0.4, 0.5], sampleRate: 16_000, duration: 0.3)
    }

    private func makeRecord(timestamp: Date = Date()) -> HistoryRecord {
        HistoryRecord(timestamp: timestamp, rawText: "hello", engine: "stub", durationMs: 300, latencyMs: 50)
    }

    @Test("Retention ON writes a WAV file and stores its path")
    func retentionOnWritesAudio() async throws {
        let (hub, store, dir) = try makeHub(retention: true)
        await hub.record(makeRecord(), clip: makeClip())

        let rows = try await store.recent(limit: 10)
        #expect(rows.count == 1)
        let path = try #require(rows.first?.audioPath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.hasPrefix(dir.path))
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        #expect(size > 44) // bigger than just the WAV header
    }

    @Test("Retention OFF never touches disk")
    func retentionOffDropsAudio() async throws {
        let (hub, store, dir) = try makeHub(retention: false)
        await hub.record(makeRecord(), clip: makeClip())

        let rows = try await store.recent(limit: 10)
        #expect(rows.first?.audioPath == nil)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test("deleteEntry removes the row and its audio file")
    func deleteEntryRemovesAudio() async throws {
        let (hub, store, _) = try makeHub(retention: true)
        await hub.record(makeRecord(), clip: makeClip())
        let row = try #require(try await store.recent(limit: 1).first)
        let id = try #require(row.id)
        let path = try #require(row.audioPath)

        let deleted = await hub.deleteEntry(id: id)
        #expect(deleted)
        #expect(!FileManager.default.fileExists(atPath: path))
        let remaining = try await store.recent(limit: 10)
        #expect(remaining.isEmpty)
    }

    @Test("purgeAll removes every row and every audio file")
    func purgeAllRemovesEverything() async throws {
        let (hub, store, dir) = try makeHub(retention: true)
        for i in 0..<3 {
            await hub.record(makeRecord(timestamp: Date(timeIntervalSince1970: Double(i))), clip: makeClip())
        }
        await hub.purgeAll()

        let remaining = try await store.recent(limit: 10)
        #expect(remaining.isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test("deleteAllAudio clears files and audio_path but keeps the rows")
    func deleteAllAudioKeepsRows() async throws {
        let (hub, store, dir) = try makeHub(retention: true)
        await hub.record(makeRecord(), clip: makeClip())
        await hub.deleteAllAudio()

        let rows = try await store.recent(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.audioPath == nil)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test("sweepOrphans removes files with no matching row, keeps the rest")
    func sweepOrphansRemovesUnreferencedFiles() async throws {
        let (hub, store, dir) = try makeHub(retention: true)
        await hub.record(makeRecord(), clip: makeClip())
        let rows = try await store.recent(limit: 10)
        let keptPath = try #require(rows.first?.audioPath)

        // Simulate an orphan left behind by a crash between write and insert.
        let orphan = dir.appendingPathComponent("orphan.wav")
        try Data([0x00]).write(to: orphan)

        let removed = await hub.sweepOrphans()
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: keptPath))
    }

    @Test("sweepOrphans is a no-op when nothing is orphaned")
    func sweepOrphansNoOpWhenClean() async throws {
        let (hub, store, _) = try makeHub(retention: true)
        await hub.record(makeRecord(), clip: makeClip())
        _ = try await store.recent(limit: 10)

        let removed = await hub.sweepOrphans()
        #expect(removed == 0)
    }
}
