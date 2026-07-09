import Foundation
import os

/// Detached sink between the `DictationOrchestrator` and `HistoryStore`. The
/// orchestrator emits a `HistoryRecord` at dictation completion (raw text +
/// latency + the just-captured clip) and, when a later cleanup replace
/// succeeds, an update carrying the clean text. The two are correlated by
/// `timestamp` (the orchestrator stamps a unique `Date` per dictation), so
/// overlapping late cleanups don't cross wires.
/// All work happens off the paste path; every failure is silent.
///
/// Audio retention (phase-5a spec §2, default OFF): when
/// `audioRetentionEnabled()` reads true at record time, the clip is encoded to
/// a 16 kHz mono WAV under `audioDirectory` and the path is stored on the row.
/// When OFF, the clip is never touched — it's simply dropped after this actor
/// hop returns.
public actor HistoryHub {
    private let store: HistoryStore
    private let audioDirectory: URL
    private let audioRetentionEnabled: @Sendable () -> Bool
    /// timestamp → persisted row id, for correlating a later clean-text update.
    private var ids: [Date: Int64] = [:]
    private let maxTracked = 128

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "history")

    public init(
        store: HistoryStore,
        audioDirectory: URL = ModelPaths.audioDirectory,
        audioRetentionEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.store = store
        // Resolve once so every path this actor ever writes or compares (stored
        // `audio_path` values and `contentsOfDirectory` results alike) shares the
        // same canonical form — `/var` vs `/private/var` symlink resolution can
        // otherwise make `contentsOfDirectory` return a differently-prefixed path
        // than the one that was written, which would make `sweepOrphans` think
        // every real file is an orphan.
        self.audioDirectory = audioDirectory.resolvingSymlinksInPath()
        self.audioRetentionEnabled = audioRetentionEnabled
    }

    /// Persist a completed dictation, remembering its id for a later update.
    /// When audio retention is on, `clip` is written to disk first and the row
    /// carries its path; when off, `clip` is dropped untouched. `word_count` is
    /// always (re)computed here from `cleanText ?? rawText`, ignoring whatever
    /// the caller stamped on the record, so it can never drift from the text
    /// actually stored. `appBundleID`/`appName` default to nil for callers
    /// (e.g. tests, headless recording) that don't have frontmost-app info.
    public func record(
        _ record: HistoryRecord,
        clip: AudioClip?,
        appBundleID: String? = nil,
        appName: String? = nil
    ) async {
        var toSave = record
        toSave.wordCount = WordCount.count(record.cleanText ?? record.rawText)
        toSave.appBundleID = appBundleID
        toSave.appName = appName
        if audioRetentionEnabled(), let clip, !clip.samples.isEmpty {
            toSave.audioPath = writeAudio(clip)
        }
        guard let saved = try? await store.append(toSave), let id = saved.id else { return }
        ids[record.timestamp] = id
        if ids.count > maxTracked, let oldest = ids.keys.min() {
            ids.removeValue(forKey: oldest)
        }
    }

    /// Update the clean text of a previously-recorded dictation (matched by
    /// timestamp). No-op if the record wasn't tracked or carries no clean text.
    /// `HistoryStore.updateEditedText` recomputes `word_count` from the new
    /// text, so the row's count always reflects whichever text is now final.
    public func updateClean(_ record: HistoryRecord) async {
        guard let clean = record.cleanText, let id = ids[record.timestamp] else { return }
        try? await store.updateEditedText(id: id, new: clean, cleanupEngine: record.cleanupEngine)
    }

    /// Fire-and-forget append sink for the orchestrator (`historyRecord`).
    /// `appInfo` is called once per dictation to stamp the frontmost app on
    /// the row; it defaults to "unknown" (nil, nil) so the existing call site
    /// (`historyHub?.recordSink()`) keeps compiling — the app layer wires a
    /// real provider (e.g. from `FrontmostAppMonitor`) when it adopts this.
    public nonisolated func recordSink(
        appInfo: @escaping @Sendable () -> (bundleID: String?, name: String?) = { (nil, nil) }
    ) -> @Sendable (HistoryRecord, AudioClip) -> Void {
        { record, clip in
            let info = appInfo()
            Task { await self.record(record, clip: clip, appBundleID: info.bundleID, appName: info.name) }
        }
    }

    /// Fire-and-forget clean-text update sink (`historyUpdate`).
    public nonisolated func updateSink() -> @Sendable (HistoryRecord) -> Void {
        { record in Task { await self.updateClean(record) } }
    }

    // MARK: - Row deletion / purge (History window)

    /// Delete one history row, removing its retained audio file first (if any).
    @discardableResult
    public func deleteEntry(id: Int64) async -> Bool {
        if let row = try? await store.fetch(id: id), let path = row.audioPath {
            deleteAudioFile(atPath: path)
        }
        return (try? await store.delete(id: id)) ?? false
    }

    /// Delete every history row and every retained audio file.
    public func purgeAll() async {
        if let paths = try? await store.allAudioPaths() {
            for path in paths { deleteAudioFile(atPath: path) }
        }
        try? await store.purgeAll()
    }

    /// Delete every retained audio file but keep the text rows (the toggle's
    /// "Delete all stored audio" button).
    public func deleteAllAudio() async {
        if let paths = try? await store.allAudioPaths() {
            for path in paths { deleteAudioFile(atPath: path) }
        }
        try? await store.clearAllAudioPaths()
    }

    /// On launch: delete any file under `audioDirectory` with no matching
    /// `audio_path` row (e.g. left behind by a crash between write and insert).
    /// Detached; returns the count removed for a single log line — never logs
    /// filenames (they're UUIDs, but the directory itself is audio content).
    @discardableResult
    public func sweepOrphans() async -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        // Compare canonical (symlink-resolved) paths on both sides: directory
        // enumeration resolves `/var` → `/private/var`-style symlinks in its
        // returned URLs regardless of how `audioDirectory` was spelled, so a
        // literal-string comparison against the stored `audio_path` would flag
        // every real file as an orphan.
        let known = Set(((try? await store.allAudioPaths()) ?? []).map(Self.canonicalPath))
        var removed = 0
        for file in files where !known.contains(Self.canonicalPath(file.path)) {
            try? fm.removeItem(at: file)
            removed += 1
        }
        if removed > 0 {
            logger.notice("removed \(removed, privacy: .public) orphaned audio file(s)")
        }
        return removed
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - WAV encoding

    private func writeAudio(_ clip: AudioClip) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let url = audioDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let data = WavEncoder.encode(samples: clip.samples, sampleRate: clip.sampleRate)
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            logger.error("audio write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func deleteAudioFile(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
