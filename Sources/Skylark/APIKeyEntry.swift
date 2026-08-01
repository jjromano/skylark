import SkylarkCore
import SwiftUI

/// Reusable OpenRouter API-key entry card (onboarding step 4 + settings). Saves
/// to the Keychain and validates via the shared client, showing the result
/// inline. Optional: local mode needs no key. The key is never logged, never
/// written to UserDefaults, and never included in error text.
struct APIKeyCard: View {
    let client: OpenRouterClient
    var showRemove: Bool = false
    /// Fired after the stored key changes (saved or removed) so the app can
    /// rebuild anything that was configured for cloud but degraded while no
    /// key existed (e.g. the speech engine).
    var onKeyChange: (() -> Void)?

    @State private var key = ""
    @State private var status: String?
    @State private var isError = false
    @State private var validating = false
    /// Non-nil when a key is stored (its added date); drives the "stored" view.
    @State private var storedSince: Date?
    /// True while the user is entering a replacement for an already-stored key.
    @State private var isReplacing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter API key")
                .font(.headline)
            Text("Optional — enables cloud STT and cloud cleanup. Local mode needs no key.")
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
            SecureField("sk-or-…", text: $key)
                .textFieldStyle(.roundedBorder)
            Button("Save", action: save)
                .disabled(key.isEmpty || validating)
            if storedSince != nil {
                Button("Cancel") { isReplacing = false; key = ""; status = nil }
            }
        }
    }

    private func refreshStored() {
        let store = KeychainStore()
        storedSince = store.exists() ? (store.createdAt() ?? Date()) : nil
    }

    private func save() {
        let entered = key
        validating = true
        status = nil
        Task {
            do {
                try KeychainStore().set(entered)
                // Publish to the in-memory cache the client reads from, so this
                // validation (and the next request) uses the key just saved
                // rather than whatever was cached before it.
                APIKeyCache.shared.publish(entered)
                let info = try await client.validateKey()
                status = Self.describe(info)
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
        try? KeychainStore().delete()
        APIKeyCache.shared.publish(nil)
        status = "Key removed."
        isError = false
        key = ""
        isReplacing = false
        refreshStored()
        onKeyChange?()
    }

    private static func describe(_ info: KeyInfo) -> String {
        if let remaining = info.limitRemaining {
            return String(format: "Key OK — $%.2f remaining", remaining)
        }
        if let label = info.label, !label.isEmpty {
            return "Key OK — \(label)"
        }
        return "Key OK."
    }

    /// Human-readable, key-free error text.
    private static func friendly(_ error: Error) -> String {
        switch error {
        case OpenRouterError.invalidKey: return "Invalid key."
        case OpenRouterError.rateLimited: return "Rate limited — try again shortly."
        case OpenRouterError.timeout: return "Timed out reaching OpenRouter."
        case is OpenRouterError: return "Couldn't validate the key."
        default: return "Couldn't save the key."
        }
    }
}
