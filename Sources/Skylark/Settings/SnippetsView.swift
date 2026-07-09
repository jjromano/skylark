import SkylarkCore
import SwiftUI

/// Settings → Snippets: say a trigger phrase on its own ("my email address")
/// and Skylark inserts the saved replacement verbatim instead of the
/// transcript. Whole-utterance match, case/punctuation-insensitive.
struct SnippetsView: View {
    let store: SnippetStore

    @State private var snippets: [SnippetRecord] = []
    @State private var newTrigger = ""
    @State private var newReplacement = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Snippets")
                    .font(.title3.bold())
                Text("Say the trigger phrase by itself and Skylark types the saved text instead — emails, links, prompts you use all the time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Trigger — e.g. my email address", text: $newTrigger)
                        .textFieldStyle(.roundedBorder)
                    TextField("Replacement — e.g. jj@example.com", text: $newReplacement, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Add") { add() }
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                        || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if snippets.isEmpty {
                Text("No snippets yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snippets.enumerated()), id: \.element.id) { index, snippet in
                        SnippetRow(snippet: snippet) { trigger, replacement in
                            save(snippet, trigger: trigger, replacement: replacement)
                        } onDelete: {
                            delete(snippet)
                        }
                        if index < snippets.count - 1 { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        snippets = (try? await store.all()) ?? []
    }

    private func add() {
        let trigger = newTrigger
        let replacement = newReplacement
        Task {
            do {
                _ = try await store.add(trigger: trigger, replacement: replacement)
                newTrigger = ""
                newReplacement = ""
                errorText = nil
            } catch SnippetStoreError.duplicateTrigger {
                errorText = "A snippet with that trigger already exists."
            } catch {
                errorText = "Couldn't save the snippet."
            }
            await reload()
        }
    }

    private func save(_ snippet: SnippetRecord, trigger: String, replacement: String) {
        guard let id = snippet.id else { return }
        Task {
            try? await store.update(id: id, trigger: trigger, replacement: replacement)
            await reload()
        }
    }

    private func delete(_ snippet: SnippetRecord) {
        guard let id = snippet.id else { return }
        Task {
            try? await store.delete(id: id)
            await reload()
        }
    }
}

private struct SnippetRow: View {
    let snippet: SnippetRecord
    var onSave: (String, String) -> Void
    var onDelete: () -> Void

    @State private var trigger = ""
    @State private var replacement = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TextField("Trigger", text: $trigger)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 160, alignment: .leading)
                .focused($focused)
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField("Replacement", text: $replacement, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...3)
                .focused($focused)
            Spacer(minLength: 4)
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete snippet")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            trigger = snippet.trigger
            replacement = snippet.replacement
        }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            let t = trigger.trimmingCharacters(in: .whitespaces)
            let r = replacement.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !r.isEmpty, t != snippet.trigger || r != snippet.replacement {
                onSave(t, r)
            }
        }
    }
}
