import Foundation

/// Detached sink between the `DictationOrchestrator` and `HistoryStore`. The
/// orchestrator emits a `HistoryRecord` at dictation completion (raw text +
/// latency) and, when a later cleanup replace succeeds, an update carrying the
/// clean text. The two are correlated by `timestamp` (the orchestrator stamps a
/// unique `Date` per dictation), so overlapping late cleanups don't cross wires.
/// All work happens off the paste path; every failure is silent.
public actor HistoryHub {
    private let store: HistoryStore
    /// timestamp → persisted row id, for correlating a later clean-text update.
    private var ids: [Date: Int64] = [:]
    private let maxTracked = 128

    public init(store: HistoryStore) {
        self.store = store
    }

    /// Persist a completed dictation, remembering its id for a later update.
    public func record(_ record: HistoryRecord) async {
        guard let saved = try? await store.append(record), let id = saved.id else { return }
        ids[record.timestamp] = id
        if ids.count > maxTracked, let oldest = ids.keys.min() {
            ids.removeValue(forKey: oldest)
        }
    }

    /// Update the clean text of a previously-recorded dictation (matched by
    /// timestamp). No-op if the record wasn't tracked or carries no clean text.
    public func updateClean(_ record: HistoryRecord) async {
        guard let clean = record.cleanText, let id = ids[record.timestamp] else { return }
        try? await store.updateEditedText(id: id, new: clean)
    }

    /// Fire-and-forget append sink for the orchestrator (`historyRecord`).
    public nonisolated func recordSink() -> @Sendable (HistoryRecord) -> Void {
        { record in Task { await self.record(record) } }
    }

    /// Fire-and-forget clean-text update sink (`historyUpdate`).
    public nonisolated func updateSink() -> @Sendable (HistoryRecord) -> Void {
        { record in Task { await self.updateClean(record) } }
    }
}
