import SkylarkCore
import SwiftUI

/// Minimal settings window. Real settings (modes, engines, dictionary) land in a
/// later pass; for now it hosts the OpenRouter API-key entry so the key can be
/// managed after onboarding.
struct SettingsView: View {
    let client: OpenRouterClient

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.title2.bold())
            }

            APIKeyCard(client: client, showRemove: true)

            Text("Modes, engines, and dictionary settings arrive in a later pass.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }
}
