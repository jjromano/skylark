import SkylarkCore
import SwiftUI

/// Settings → Dictionary (phase-5a spec §3). Add/edit/delete custom-dictionary
/// entries; upsert-by-phrase semantics live in `DictionaryStore`, inline edits
/// go through `update(id:phrase:misspellings:)` so renaming a phrase doesn't
/// orphan the old row.
struct DictionaryView: View {
    let store: DictionaryStore

    @State private var entries: [DictionaryEntry] = []
    @State private var newPhrase = ""
    @State private var newMisspellings = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictionary").font(.title2.bold())
            Text("Add the correct spelling of a word or name so Skylark prefers it during recognition. Optionally list common misspellings (comma-separated) that should be auto-corrected to it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Word or phrase", text: $newPhrase)
                    .textFieldStyle(.roundedBorder)
                TextField("Common misspellings (comma-separated)", text: $newMisspellings)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { add() }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if entries.isEmpty {
                Text("No entries yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        DictionaryRow(entry: entry, onUpdate: { phrase, misspellings in
                            update(entry, phrase: phrase, misspellings: misspellings)
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
        let misspellings = Self.parseMisspellings(newMisspellings)
        Task {
            _ = try? await store.upsert(DictionaryEntry(
                phrase: phrase, misspellings: misspellings, source: .manual
            ))
            newPhrase = ""
            newMisspellings = ""
            await reload()
        }
    }

    private func update(_ entry: DictionaryEntry, phrase: String, misspellings: [String]) {
        guard let id = entry.id else { return }
        Task {
            try? await store.update(id: id, phrase: phrase, misspellings: misspellings)
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

    /// Split the comma-separated misspellings field, trimming whitespace and
    /// dropping empties.
    static func parseMisspellings(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onUpdate: (String, [String]) -> Void
    let onDelete: () -> Void

    @State private var phrase: String
    @State private var misspellings: String

    init(entry: DictionaryEntry, onUpdate: @escaping (String, [String]) -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _phrase = State(initialValue: entry.phrase)
        _misspellings = State(initialValue: entry.misspellings.joined(separator: ", "))
    }

    var body: some View {
        HStack {
            TextField("Word or phrase", text: $phrase)
                .textFieldStyle(.plain)
                .onSubmit(commit)
            TextField("Common misspellings", text: $misspellings)
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
        onUpdate(trimmedPhrase, DictionaryView.parseMisspellings(misspellings))
    }
}
