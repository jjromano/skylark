import SkylarkCore
import SwiftUI

/// Three permission rows with live status badges. Polls while visible.
struct OnboardingView: View {
    @Bindable var permissions: PermissionsService
    let apiKeyClient: OpenRouterClient
    /// Display name of the configured dictation key (e.g. "Fn (Globe)").
    var hotkeyName: String = "Fn (Globe)"
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Skylark")
                    .font(.title2.bold())
                Text("Grant three permissions so Skylark can hear you, read the focused text field, and watch for your dictation key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    why: "Transcribe your speech. Audio never leaves this Mac in local mode.",
                    grant: permissions.microphone
                ) { permissions.request(.microphone) }

                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    why: "Insert text into the focused field and read the cursor position.",
                    grant: permissions.accessibility
                ) { permissions.request(.accessibility) }

                PermissionRow(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    why: "Detect the \(hotkeyName) key for push-to-talk.",
                    grant: permissions.inputMonitoring
                ) { permissions.request(.inputMonitoring) }
            }

            // How to dictate — the three gestures, using the configured key.
            VStack(alignment: .leading, spacing: 6) {
                Text("How to dictate")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                GestureRow(icon: "hand.tap.fill", text: "Hold \(hotkeyName), speak, release — the text lands where your cursor is.")
                GestureRow(icon: "hand.tap", text: "Double-tap \(hotkeyName) for hands-free; it stops when you go quiet.")
                GestureRow(icon: "escape", text: "Press Esc while recording to cancel.")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))

            if permissions.fnGlobeActionConflict {
                Label(
                    "Your Fn/Globe key has a custom action. Skylark suppresses it while running.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Divider()

            APIKeyCard(client: apiKeyClient)

            Divider()

            if permissions.allGranted {
                HStack {
                    Label("You're set — hold \(hotkeyName) and speak.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Close") { onClose() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Waiting for the remaining permissions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { permissions.startPolling() }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let why: String
    let grant: PermissionsService.Grant
    var onGrant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                badge
                if grant != .granted {
                    Button("Grant", action: onGrant)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var badge: some View {
        let (text, color): (String, Color) = switch grant {
        case .granted: ("Granted", .green)
        case .denied: ("Denied", .red)
        case .notDetermined: ("Not set", .secondary)
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

/// One "how to dictate" gesture line in the onboarding tutorial card.
private struct GestureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
