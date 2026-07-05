import SkylarkCore
import SwiftUI

/// Reusable OpenRouter API-key entry card (onboarding step 4 + settings). Saves
/// to the Keychain and validates via the shared client, showing the result
/// inline. Optional: local mode needs no key. The key is never logged, never
/// written to UserDefaults, and never included in error text.
struct APIKeyCard: View {
    let client: OpenRouterClient
    var showRemove: Bool = false

    @State private var key = ""
    @State private var status: String?
    @State private var isError = false
    @State private var validating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter API key")
                .font(.headline)
            Text("Optional — enables cloud STT and cloud cleanup. Local mode needs no key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                SecureField("sk-or-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Save", action: save)
                    .disabled(key.isEmpty || validating)
                if showRemove {
                    Button("Remove key", action: remove)
                }
            }

            if validating {
                ProgressView().controlSize(.small)
            } else if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
            }
        }
    }

    private func save() {
        let entered = key
        validating = true
        status = nil
        Task {
            do {
                try KeychainStore().set(entered)
                let info = try await client.validateKey()
                status = Self.describe(info)
                isError = false
            } catch {
                status = Self.friendly(error)
                isError = true
            }
            validating = false
            key = "" // never keep the key in view state
        }
    }

    private func remove() {
        try? KeychainStore().delete()
        status = "Key removed."
        isError = false
        key = ""
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
