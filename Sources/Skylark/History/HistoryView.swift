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
    /// Engines offered by the Re-transcribe control (local always; cloud when a
    /// key exists). Empty hides the control entirely.
    var retranscribeEngines: [RetranscribeEngine] = []
    /// Re-transcribes a retained clip with a fresh engine and replaces the row's
    /// raw text + engine; returns the new text. Injected by `AppController`.
    var retranscribe: ((Int64, String, RetranscribeEngine) async throws -> String)?

    @State private var query = ""
    @State private var records: [HistoryRecord] = []
    @State private var modeNames: [String: String] = [:]
    @State private var selectedID: Int64?
    @State private var confirmClearAll = false
    // Pin both columns visible: a plain NavigationSplitView can initialize
    // collapsed to just the sidebar (the .searchable field), which read as a
    // window "stuck" at a search box with no list or detail.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selected: HistoryRecord? {
        records.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                    retranscribeEngines: retranscribeEngines,
                    retranscribe: retranscribe,
                    onSaved: { await reload() },
                    onDelete: {
                        if let id = selected.id { await hub.deleteEntry(id: id) }
                        await reload()
                        selectedID = nil
                    }
                )
                // Parent-applied identity: forces the detail view (and its
                // @State editedText seed) to re-initialize when the selected
                // record changes. Applying .id INSIDE the detail view only
                // resets its body subtree, leaving editedText stuck on the
                // first-viewed record.
                .id(selected.id)
            } else {
                ContentUnavailableView("No entry selected", systemImage: "clock")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 420)
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
    let retranscribeEngines: [RetranscribeEngine]
    let retranscribe: ((Int64, String, RetranscribeEngine) async throws -> String)?
    let onSaved: () async -> Void
    let onDelete: () async -> Void

    @State private var editedText: String
    @State private var candidates: [DictionaryCandidate] = []
    @State private var player: AVAudioPlayer?
    @State private var confirmDelete = false
    @State private var retranscribeSelection: RetranscribeEngine?
    @State private var retranscribeStatus: RetranscribeStatus = .idle

    private enum RetranscribeStatus: Equatable {
        case idle
        case running
        case failed(String)
    }

    init(
        store: HistoryStore,
        dictionaryStore: DictionaryStore?,
        record: HistoryRecord,
        modeName: String?,
        retranscribeEngines: [RetranscribeEngine],
        retranscribe: ((Int64, String, RetranscribeEngine) async throws -> String)?,
        onSaved: @escaping () async -> Void,
        onDelete: @escaping () async -> Void
    ) {
        self.store = store
        self.dictionaryStore = dictionaryStore
        self.record = record
        self.modeName = modeName
        self.retranscribeEngines = retranscribeEngines
        self.retranscribe = retranscribe
        self.onSaved = onSaved
        self.onDelete = onDelete
        _editedText = State(initialValue: record.cleanText ?? record.rawText)
        _retranscribeSelection = State(initialValue: retranscribeEngines.first)
    }

    /// The Re-transcribe control is available only for entries with retained
    /// audio and at least one engine offered.
    private var canRetranscribe: Bool {
        record.audioPath != nil && retranscribe != nil && !retranscribeEngines.isEmpty
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

                if canRetranscribe {
                    Divider()
                    retranscribeControls
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
        // Stop any in-flight playback when the selection changes (the parent
        // re-creates this view via `.id`, tearing down `player`) or the window
        // closes.
        .onDisappear { player?.stop() }
        // A re-transcribe replaces this row's raw text in place — the row id is
        // unchanged, so the parent's `.id(selected.id)` doesn't re-init us. Re-seed
        // the editable field (and drop any stale candidates) when the raw text
        // actually changes. A normal edit-save only changes clean text, so this
        // never clobbers an in-progress edit.
        .onChange(of: record.rawText) { _, newRaw in
            editedText = record.cleanText ?? newRaw
            candidates = []
        }
    }

    // MARK: - Re-transcribe

    private var retranscribeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Re-transcribe").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Picker("Engine", selection: $retranscribeSelection) {
                    ForEach(retranscribeEngines) { engine in
                        Text(engine.label).tag(Optional(engine))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)

                Button("Go") { runRetranscribe() }
                    .disabled(retranscribeSelection == nil || retranscribeStatus == .running)

                if retranscribeStatus == .running {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if case let .failed(message) = retranscribeStatus {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Runs the chosen engine on this entry's saved audio and replaces its text (no re-formatting, no re-insert). Cloud engines upload the audio; local engines never leave this Mac.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func runRetranscribe() {
        guard let id = record.id,
              let path = record.audioPath,
              let engine = retranscribeSelection,
              let retranscribe
        else { return }
        // Playback and re-transcribe would race on the same file — stop first.
        player?.stop()
        retranscribeStatus = .running
        Task {
            do {
                _ = try await retranscribe(id, path, engine)
                retranscribeStatus = .idle
                // Reload so the parent hands this view the replaced record.
                await onSaved()
            } catch {
                retranscribeStatus = .failed(Self.retranscribeMessage(error))
            }
        }
    }

    private static func retranscribeMessage(_ error: Error) -> String {
        if case Retranscription.Failure.audioUnavailable = error {
            return "The saved audio is missing or unreadable."
        }
        // Engine/network errors carry content-free descriptions (see privacy
        // audit §2) — safe to surface.
        return "Re-transcribe failed: \(error.localizedDescription)"
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
                Text("Cleanup").foregroundStyle(.secondary)
                // Which engine actually produced the clean text — surfaces
                // silent fallbacks ("local" while a cloud model is selected).
                Text(record.cleanupEngine ?? (record.cleanText == nil ? "none (raw kept)" : "—"))
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
    /// persisting anything. With "Learn corrections automatically" on
    /// (Settings → History), the confirm step is skipped and every candidate
    /// is learned immediately.
    private func proposeCandidates() {
        let pairs = CorrectionDiff.pairs(raw: record.rawText, edited: editedText)
        guard !pairs.isEmpty else {
            Task { await applySave() }
            return
        }
        candidates = pairs.map { DictionaryCandidate(from: $0.from, to: $0.to) }
        if UserDefaults.standard.bool(forKey: AppController.dictionaryAutoLearnKey) {
            Task { await applySave() }
        }
    }

    /// Step 2: persist the edited text and upsert every accepted candidate pair
    /// as an auto-correction dictionary entry.
    private func applySave() async {
        guard let id = record.id else { return }
        for candidate in candidates where candidate.accepted {
            // candidate.from was misspelled as candidate.to in the edited text,
            // so the correct phrase is `to` and the misspelling to learn is `from`.
            _ = try? await dictionaryStore?.upsert(
                DictionaryEntry(phrase: candidate.to, misspellings: [candidate.from], source: .autoCorrection)
            )
        }
        try? await store.updateEditedText(id: id, new: editedText)
        candidates = []
        await onSaved()
    }
}
