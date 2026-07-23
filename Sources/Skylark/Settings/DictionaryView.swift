import SkylarkCore
import SwiftUI

/// Settings → Dictionary (phase-5a spec §3). Add/edit/delete custom-dictionary
/// entries; upsert-by-phrase semantics live in `DictionaryStore`, inline edits
/// go through `update(id:phrase:misspellings:)` so renaming a phrase doesn't
/// orphan the old row.
struct DictionaryView: View {
    let store: DictionaryStore
    /// Opt-in for learning words from in-place corrections (nil hides the toggle,
    /// e.g. in previews). Wired to `AppController.learnFromCorrectionsEnabled`.
    var learnFromCorrections: Binding<Bool>? = nil

    @State private var entries: [DictionaryEntry] = []
    @State private var newPhrase = ""
    @State private var newMisspellings = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictionary").font(.title3.bold())
                Text("Add the correct spelling of a word or name so Skylark prefers it during recognition. Optionally list common misspellings (comma-separated) that should be auto-corrected to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let learnFromCorrections {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Learn words from your corrections", isOn: learnFromCorrections)
                    Text("After a dictation, if you fix a word Skylark misheard, the correction is added here automatically. Watching happens on-device via Accessibility and nothing but the corrected word is stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Word or phrase — e.g. Skylark", text: $newPhrase)
                        .textFieldStyle(.roundedBorder)
                    TextField("Common misspellings (comma-separated) — e.g. sky lark, skylock", text: $newMisspellings)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Add") { add() }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if entries.isEmpty {
                Text("No entries yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
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
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
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
            _ = try? await store.delete(id: id)
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

/// One saved entry: a single display line with pencil (edit-in-place) and
/// trash actions. Editing swaps in two stacked fields + confirm/cancel.
private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onUpdate: (String, [String]) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var phrase = ""
    @State private var misspellings = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if isEditing {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Word or phrase", text: $phrase)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit(commit)
                    TextField("Common misspellings (comma-separated)", text: $misspellings)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit(commit)
                }
                Button(action: commit) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Save changes")
                Button {
                    isEditing = false
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else {
                Text(entry.phrase)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if !entry.misspellings.isEmpty {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(entry.misspellings.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if entry.source == .autoCorrection {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles").font(.system(size: 8))
                        Text("Auto")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .help("Learned automatically from a correction you made")
                } else {
                    Text("manual")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.secondary.opacity(0.2)))
                }

                Text(entry.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    phrase = entry.phrase
                    misspellings = entry.misspellings.joined(separator: ", ")
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit entry")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete entry")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func commit() {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else { return }
        onUpdate(trimmedPhrase, DictionaryView.parseMisspellings(misspellings))
        isEditing = false
    }
}
