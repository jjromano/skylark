import AVFoundation
import SkylarkCore
import SwiftUI

/// The "History…" menu-bar window (phase-5a spec §1): searchable list, a
/// detail pane, and the edit → auto-learn loop that closes the PRD's
/// auto-add-to-dictionary requirement. Deletion (row or full purge) routes
/// through `HistoryHub` so retained audio files are cleaned up alongside the
/// text row.
struct HistoryView: View {
    let store: HistoryStore
    let hub: HistoryHub
    let modeStore: ModeStore?
    let dictionaryStore: DictionaryStore?

    @State private var query = ""
    @State private var records: [HistoryRecord] = []
    @State private var modeNames: [String: String] = [:]
    @State private var selectedID: Int64?
    @State private var confirmClearAll = false

    private var selected: HistoryRecord? {
        records.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(records, selection: $selectedID) { record in
                HistoryRow(record: record)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search history")
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .toolbar {
                ToolbarItem {
                    Button("Clear History…", role: .destructive) { confirmClearAll = true }
                }
            }
            .confirmationDialog(
                "Delete all history?",
                isPresented: $confirmClearAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    Task {
                        await hub.purgeAll()
                        await reload()
                        selectedID = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every history entry and any retained audio. This can't be undone.")
            }
        } detail: {
            if let selected {
                HistoryDetailView(
                    store: store,
                    dictionaryStore: dictionaryStore,
                    record: selected,
                    modeName: selected.modeID.flatMap { modeNames[$0] },
                    onSaved: { await reload() },
                    onDelete: {
                        if let id = selected.id { await hub.deleteEntry(id: id) }
                        await reload()
                        selectedID = nil
                    }
                )
            } else {
                ContentUnavailableView("No entry selected", systemImage: "clock")
            }
        }
        .task { await loadModeNames() }
        .task(id: query) { await reload() }
    }

    private func reload() async {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            records = (try? await store.recent(limit: 200)) ?? []
        } else {
            records = (try? await store.search(text: query, limit: 200)) ?? []
        }
        if let selectedID, !records.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    private func loadModeNames() async {
        guard let modeStore else { return }
        let modes = (try? await modeStore.all()) ?? []
        modeNames = Dictionary(uniqueKeysWithValues: modes.map { ($0.id, $0.name) })
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let record: HistoryRecord

    private var preview: String {
        let text = record.cleanText ?? record.rawText
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(record.timestamp, style: .date)
                Text(record.timestamp, style: .time)
                Spacer()
                Text(record.engine)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.2)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(preview.isEmpty ? "(empty)" : preview)
                .font(.system(size: 13))
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Auto-learn candidate (shared by the detail view + its chip row)

/// One toggleable "add to dictionary" candidate proposed by `CorrectionDiff`
/// off an edited history entry (phase-5a spec §1). Default ON per spec.
private struct DictionaryCandidate: Identifiable {
    let id = UUID()
    let from: String
    let to: String
    var accepted = true
}

// MARK: - Detail

private struct HistoryDetailView: View {
    let store: HistoryStore
    let dictionaryStore: DictionaryStore?
    let record: HistoryRecord
    let modeName: String?
    let onSaved: () async -> Void
    let onDelete: () async -> Void

    @State private var editedText: String
    @State private var candidates: [DictionaryCandidate] = []
    @State private var player: AVAudioPlayer?
    @State private var confirmDelete = false

    init(
        store: HistoryStore,
        dictionaryStore: DictionaryStore?,
        record: HistoryRecord,
        modeName: String?,
        onSaved: @escaping () async -> Void,
        onDelete: @escaping () async -> Void
    ) {
        self.store = store
        self.dictionaryStore = dictionaryStore
        self.record = record
        self.modeName = modeName
        self.onSaved = onSaved
        self.onDelete = onDelete
        _editedText = State(initialValue: record.cleanText ?? record.rawText)
    }

    private var finalText: String { record.cleanText ?? record.rawText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(record.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.headline)
                    Spacer()
                    Button("Copy") { copyFinalText() }
                    if record.audioPath != nil {
                        Button { play() } label: {
                            Label("Play", systemImage: "play.circle")
                        }
                    }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }

                metadataGrid

                Divider()

                Text("Raw").font(.caption).foregroundStyle(.secondary)
                Text(record.rawText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)

                if record.cleanText != nil {
                    Divider()
                    Text("Clean").font(.caption).foregroundStyle(.secondary)
                    Text(record.cleanText ?? "")
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }

                Divider()

                Text("Final text (editable)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $editedText)
                    .font(.system(size: 13))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))

                if !candidates.isEmpty {
                    candidateChips
                }

                HStack {
                    if candidates.isEmpty {
                        Button("Save") { proposeCandidates() }
                            .disabled(editedText == finalText)
                    } else {
                        Button("Confirm & Save") { Task { await applySave() } }
                        Button("Cancel") { candidates = [] }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await onDelete() } }
            Button("Cancel", role: .cancel) {}
        }
        .id(record.id)
    }

    private var metadataGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Mode").foregroundStyle(.secondary)
                Text(modeName ?? record.modeID ?? "—")
            }
            GridRow {
                Text("Engine").foregroundStyle(.secondary)
                Text(record.engine)
            }
            GridRow {
                Text("Duration").foregroundStyle(.secondary)
                Text("\(record.durationMs) ms")
            }
            GridRow {
                Text("Latency").foregroundStyle(.secondary)
                Text("\(record.latencyMs) ms")
            }
        }
        .font(.caption)
    }

    private var candidateChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add to dictionary?").font(.caption).foregroundStyle(.secondary)
            ForEach($candidates) { $candidate in
                Toggle(isOn: $candidate.accepted) {
                    Text("\(candidate.from) → \(candidate.to)").font(.system(size: 12, design: .monospaced))
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }

    private func copyFinalText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(finalText, forType: .string)
    }

    private func play() {
        guard let path = record.audioPath else { return }
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player = newPlayer
            newPlayer.play()
        } catch {
            // Playback failure is non-fatal — no file, or an unreadable one.
        }
    }

    /// Step 1 of the auto-learn loop: compute candidate dictionary pairs from
    /// raw→edited and show them as toggleable chips (default ON) before
    /// persisting anything.
    private func proposeCandidates() {
        let pairs = CorrectionDiff.pairs(raw: record.rawText, edited: editedText)
        guard !pairs.isEmpty else {
            Task { await applySave() }
            return
        }
        candidates = pairs.map { DictionaryCandidate(from: $0.from, to: $0.to) }
    }

    /// Step 2: persist the edited text and upsert every accepted candidate pair
    /// as an auto-correction dictionary entry.
    private func applySave() async {
        guard let id = record.id else { return }
        for candidate in candidates where candidate.accepted {
            _ = try? await dictionaryStore?.upsert(
                DictionaryEntry(phrase: candidate.from, replacement: candidate.to, source: .autoCorrection)
            )
        }
        try? await store.updateEditedText(id: id, new: editedText)
        candidates = []
        await onSaved()
    }
}
