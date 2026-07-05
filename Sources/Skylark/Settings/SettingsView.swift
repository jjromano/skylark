import SwiftUI

/// Placeholder settings window. Real settings land in Phase 2.
struct SettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Settings")
                .font(.title2.bold())
            Text("Modes, engines, dictionary, and the OpenRouter key arrive in Phase 2.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
