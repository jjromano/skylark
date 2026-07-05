import SkylarkCore
import SwiftUI

/// Settings → Dictionary (phase-5a spec §3). Add/edit/delete custom-dictionary
/// entries; upsert-by-phrase semantics live in `DictionaryStore`, inline edits
/// go through `update(id:phrase:replacement:)` so renaming a phrase doesn't
/// orphan the old row.
struct DictionaryView: View {
    let store: DictionaryStore

    @State private var entries: [DictionaryEntry] = []
    @State private var newPhrase = ""
    @State private var newReplacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictionary").font(.title2.bold())
            Text("Entries without a replacement bias recognition toward that spelling. Entries with a replacement rewrite the transcript directly.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Phrase", text: $newPhrase)
                    .textFieldStyle(.roundedBorder)
                TextField("Replacement (optional)", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { add() }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if entries.isEmpty {
                Text("No entries yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        DictionaryRow(entry: entry, onUpdate: { phrase, replacement in
                            update(entry, phrase: phrase, replacement: replacement)
                        }, onDelete: {
                            delete(entry)
                        })
                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        entries = ((try? await store.entries()) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    private func add() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            _ = try? await store.upsert(DictionaryEntry(
                phrase: phrase, replacement: replacement.isEmpty ? nil : replacement, source: .manual
            ))
            newPhrase = ""
            newReplacement = ""
            await reload()
        }
    }

    private func update(_ entry: DictionaryEntry, phrase: String, replacement: String?) {
        guard let id = entry.id else { return }
        Task {
            try? await store.update(id: id, phrase: phrase, replacement: replacement)
            await reload()
        }
    }

    private func delete(_ entry: DictionaryEntry) {
        guard let id = entry.id else { return }
        Task {
            try? await store.delete(id: id)
            await reload()
        }
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onUpdate: (String, String?) -> Void
    let onDelete: () -> Void

    @State private var phrase: String
    @State private var replacement: String

    init(entry: DictionaryEntry, onUpdate: @escaping (String, String?) -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _phrase = State(initialValue: entry.phrase)
        _replacement = State(initialValue: entry.replacement ?? "")
    }

    var body: some View {
        HStack {
            TextField("Phrase", text: $phrase)
                .textFieldStyle(.plain)
                .onSubmit(commit)
            TextField("Replacement", text: $replacement)
                .textFieldStyle(.plain)
                .onSubmit(commit)

            Text(entry.source == .manual ? "manual" : "auto")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.secondary.opacity(0.2)))

            Text(entry.createdAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func commit() {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else { return }
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        onUpdate(trimmedPhrase, trimmedReplacement.isEmpty ? nil : trimmedReplacement)
    }
}
