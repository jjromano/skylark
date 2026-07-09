import AppKit
import SkylarkCore
import SwiftUI

/// Superwhisper-style shortcut recorder: click the capsule, press the key or
/// combination you want, and it's captured automatically.
///
/// Capture semantics (via `HotkeyCapture`):
/// - A non-modifier keyDown captures immediately — with any held ⌘/⌥/⌃(/⇧)
///   as a chord (e.g. ⌥Space), or bare for F13–F19.
/// - Pressing and RELEASING only modifiers captures the modifier itself
///   (Fn, right ⌘/⌥/⌃) — release is the commit so chords stay reachable.
/// - Esc cancels recording (it's reserved for cancelling dictations).
/// - Invalid keys (bare letters, F1–F12, left modifiers) show a hint and
///   keep recording.
///
/// While recording, the global hotkey tap is paused (`pauseHotkeyMonitoring`)
/// so the current binding can be re-captured and stray presses can't start a
/// dictation; all recorded events are swallowed by returning nil from the
/// local monitor.
struct ShortcutRecorderRow: View {
    @Bindable var controller: AppController

    @State private var isRecording = false
    @State private var hint: String?
    /// Last modifier keycode seen while its flag was held (commit-on-release).
    @State private var pendingModifierKeyCode: Int?
    @State private var eventMonitor: Any?

    var body: some View {
        LabeledContent("Keyboard") {
            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    Text(isRecording ? "Press your shortcut…" : controller.hotkeyKeyboard.displayName)
                        .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                        .foregroundStyle(isRecording ? .secondary : .primary)
                    if isRecording {
                        Image(systemName: "record.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(isRecording ? 0.9 : 0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press a key or combination — Esc cancels" : "Click, then press the shortcut you want")
        }
        // Stop recording if the pane is switched away or the window closes.
        .onDisappear { stopRecording() }
        if let hint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        hint = nil
        pendingModifierKeyCode = nil
        controller.pauseHotkeyMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil // swallow everything while recording
        }
    }

    private func stopRecording() {
        guard isRecording || eventMonitor != nil else { return }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        isRecording = false
        pendingModifierKeyCode = nil
        controller.resumeHotkeyMonitoring()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { // Esc cancels recording
                stopRecording()
                return
            }
            apply(HotkeyCapture.fromKeyDown(
                keyCode: Int(event.keyCode),
                modifierFlagsRawValue: event.modifierFlags.rawValue
            ))
        case .flagsChanged:
            let active = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if !active.isEmpty {
                // A modifier went down (or is still held) — remember the key,
                // commit only when everything is released so chords like
                // ⌥Space can still be completed with a keyDown.
                pendingModifierKeyCode = Int(event.keyCode)
            } else if let keyCode = pendingModifierKeyCode {
                pendingModifierKeyCode = nil
                apply(HotkeyCapture.fromFlagsChanged(keyCode: keyCode))
            }
        default:
            break
        }
    }

    private func apply(_ result: Result<HotkeyBinding, HotkeyCapture.CaptureError>) {
        switch result {
        case let .success(binding):
            stopRecording()
            controller.setHotkeyKeyboard(binding)
            hint = nil
        case let .failure(error):
            switch error {
            case .needsModifier:
                hint = "Add a modifier — plain keys would fire while typing (try ⌥, ⌘, or ⌃ + key)."
            case .leftModifierUnsupported:
                hint = "Use the RIGHT-side modifier alone, or combine this one with a key."
            case let .unsupportedKey(reason):
                hint = reason
            }
        }
    }
}
