import SkylarkCore
import SwiftUI

/// Groq API-key entry card. A SEPARATE card (and a separate Keychain item) from
/// `APIKeyCard`'s OpenRouter key: they are credentials for two different
/// services, and sharing one field would silently send a user's OpenRouter key
/// to Groq the first time they switched speech engines.
///
/// The key is never logged, never written to UserDefaults, and never included in
/// error text.
struct GroqKeyCard: View {
    var showRemove: Bool = false
    /// Fired after the stored key changes, so the speech engine can rebuild if
    /// it degraded to local while no key existed.
    var onKeyChange: (() -> Void)?

    @State private var key = ""
    @State private var status: String?
    @State private var isError = false
    @State private var validating = false
    @State private var storedSince: Date?
    @State private var isReplacing = false

    private var store: KeychainStore { KeychainStore(account: KeychainStore.groqAccount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Groq API key")
                .font(.headline)
            Text("Optional — enables the direct Groq speech engine, which reaches one known fast provider instead of OpenRouter's price-balanced routing. Local mode needs no key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let storedSince, !isReplacing {
                storedView(since: storedSince)
            } else {
                entryView
            }

            if validating {
                ProgressView().controlSize(.small)
            } else if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
            }
        }
        .task { refreshStored() }
    }

    private func storedView(since: Date) -> some View {
        HStack(spacing: 10) {
            Label {
                Text("Key stored — added \(since.formatted(date: .abbreviated, time: .omitted))")
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .font(.callout)
            Spacer(minLength: 8)
            Button("Replace…") { isReplacing = true; status = nil }
            if showRemove {
                Button("Remove key", role: .destructive, action: remove)
            }
        }
    }

    private var entryView: some View {
        HStack {
            SecureField("gsk_…", text: $key)
                .textFieldStyle(.roundedBorder)
            Button("Save", action: save)
                .disabled(key.isEmpty || validating)
            if storedSince != nil {
                Button("Cancel") { isReplacing = false; key = ""; status = nil }
            }
        }
    }

    private func refreshStored() {
        storedSince = store.exists() ? (store.createdAt() ?? Date()) : nil
    }

    private func save() {
        let entered = key
        validating = true
        status = nil
        Task {
            do {
                try store.set(entered)
                // Publish before validating, so the validation uses the key just
                // saved rather than whatever was cached before it.
                APIKeyCache.groq.publish(entered)
                let client = GroqSpeechClient(keyProvider: { APIKeyCache.groq.current() })
                try await client.validateKey()
                status = "Key OK."
                isError = false
            } catch {
                status = Self.friendly(error)
                isError = true
            }
            validating = false
            key = "" // never keep the key in view state
            isReplacing = false
            refreshStored()
            onKeyChange?()
        }
    }

    private func remove() {
        try? store.delete()
        APIKeyCache.groq.publish(nil)
        status = "Key removed."
        isError = false
        key = ""
        isReplacing = false
        refreshStored()
        onKeyChange?()
    }

    /// Human-readable, key-free error text.
    private static func friendly(_ error: Error) -> String {
        switch error {
        case GroqError.noKey: return "No key entered."
        case GroqError.timeout: return "Timed out reaching Groq."
        case GroqError.http(401, _), GroqError.http(403, _): return "Invalid key."
        case GroqError.http(429, _): return "Rate limited — try again shortly."
        case is GroqError: return "Couldn't validate the key."
        default: return "Couldn't save the key."
        }
    }
}
