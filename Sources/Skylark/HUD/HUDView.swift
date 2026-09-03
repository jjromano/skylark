import SkylarkCore
import SwiftUI

/// The floating pill. Fixed heights per state (no layout jumps); ~120 ms
/// transitions. Phase 1 wires real levels into the waveform slot.
struct HUDView: View {
    @Bindable var model: HUDModel
    var onToggleRecord: () -> Void
    var onCancel: () -> Void
    var onOpenSettings: () -> Void

    private var size: CGSize {
        HUDMetrics.size(for: model.state, hovering: model.isHovering, style: model.style, note: model.note != nil)
    }

    /// The note to render in place of the state content, if one is pending and
    /// this state lets it through (never while the mic is open).
    private var visibleNote: String? {
        guard let note = model.note, HUDMetrics.showsNote(in: model.state) else { return nil }
        return note
    }

    private var isMinimal: Bool { model.style == .minimal }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .background(
                ZStack {
                    // Frosted translucency: a blur of whatever's behind the HUD
                    // plus a light dark tint (was a near-opaque black fill).
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                    Capsule(style: .continuous).fill(.black.opacity(0.30))
                }
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.10)))
            )
            .animation(.easeInOut(duration: 0.12), value: model.state)
            .animation(.easeInOut(duration: 0.12), value: model.isHovering)
            .animation(.easeInOut(duration: 0.12), value: model.note)
            .onHover { hovering in
                // Don't collapse the expanded controls while recording.
                if !model.isRecording { model.isHovering = hovering }
            }
            .contextMenu {
                if model.isRecording {
                    Button("Cancel") { onCancel() }
                }
            }
            .padding(2)
    }

    @ViewBuilder
    private var content: some View {
        if let note = visibleNote {
            noteContent(note)
        } else {
            stateContent
        }
    }

    /// Status note inside the fixed `HUDMetrics.noteSize` box: two lines at
    /// most, tail-truncated. The frame never follows the text.
    private func noteContent(_ note: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .clipped()
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle:
            if model.isHovering {
                expandedControls
            } else if model.isPreparing {
                // Only surfaces while the speech model is still loading; a steady
                // idle HUD is just the minimal black pill (no dot).
                statusDot
            } else {
                Color.clear
            }
        case .listening:
            listeningContent
        case .commandListening:
            commandListeningContent
        case .processing:
            processingContent
        }
    }

    // MARK: - Pieces

    private var statusDot: some View {
        // Shown only while the speech model is preparing (pulsing orange). Once
        // ready the idle HUD drops the dot entirely for a minimal black pill.
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .opacity(0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: model.isPreparing)
    }

    private var expandedControls: some View {
        HStack(spacing: 10) {
            Text("Raw")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            Spacer(minLength: 0)

            Button(action: onToggleRecord) {
                Circle().fill(.red).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help("Start hands-free dictation")

            Button(action: onOpenSettings) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Open Settings")
        }
        .padding(.horizontal, 12)
    }

    private var listeningContent: some View {
        Group {
            if model.hasPreview {
                // Prototype live preview: waveform row on top, interim text below.
                VStack(spacing: 5) {
                    listeningRow
                    previewText
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else {
                listeningRow
                    .padding(.horizontal, isMinimal ? 8 : 10)
            }
        }
    }

    private var listeningRow: some View {
        HStack(spacing: isMinimal ? 6 : 8) {
            // Whisper mode: hollow dot (stroke only) as a subtle quiet-speech cue.
            // The minimal style drops the dot — the waveform alone is the cue.
            // Approaching the recording cap the dot goes amber, borrowing the
            // processing pill's colour rather than inventing one.
            if !isMinimal {
                Group {
                    if model.isWhisperMode {
                        Circle().strokeBorder(recordTint, lineWidth: 1.5)
                    } else {
                        Circle().fill(recordTint)
                    }
                }
                .frame(width: 8, height: 8)
            }
            // Live waveform: newest level enters from the trailing edge. Driven
            // at the levels-stream cadence (~20 Hz) with eased height changes.
            HStack(spacing: 1) {
                ForEach(Array(model.waveform.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: 2, height: barHeight(level))
                }
            }
            .frame(height: waveformBand)
            .animation(.easeOut(duration: 0.08), value: model.waveform)
            capCountdown
        }
    }

    /// Listening dot colour: red normally, amber inside the cap warning window.
    private var recordTint: Color {
        model.capSecondsRemaining == nil ? .red : .orange
    }

    /// Subtle countdown to the 2-minute recording cap. Absent (zero-width) until
    /// the last stretch, so the ordinary pill is untouched.
    @ViewBuilder
    private var capCountdown: some View {
        if let seconds = model.capSecondsRemaining {
            Text("\(seconds)s")
                .font(.system(size: isMinimal ? 9 : 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.orange.opacity(0.95))
                .help("Recording stops at the 2-minute limit")
                .transition(.opacity)
        }
    }

    /// Interim transcription (confirmed brighter, volatile dimmer). Tail region;
    /// truncated to keep the pill to two lines. Display-only — never the paste.
    @ViewBuilder
    private var previewText: some View {
        let preview = model.preview ?? .empty
        (Text(preview.confirmed.isEmpty ? "" : preview.confirmed + " ")
            .foregroundStyle(.white.opacity(0.9))
            + Text(preview.volatile)
            .foregroundStyle(.white.opacity(0.5)))
            .font(.system(size: 11))
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Voice Command Mode listening pill: a distinct blue tint + a "Command"
    /// label so it never reads as ordinary dictation. Same waveform mechanics.
    private var commandListeningContent: some View {
        HStack(spacing: isMinimal ? 6 : 8) {
            if !isMinimal {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.blue)
                Text("Command")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.blue.opacity(0.95))
            }
            HStack(spacing: 1) {
                ForEach(Array(model.waveform.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.blue.opacity(0.65))
                        .frame(width: 2, height: barHeight(level))
                }
            }
            .frame(height: waveformBand)
            .animation(.easeOut(duration: 0.08), value: model.waveform)
        }
        .padding(.horizontal, isMinimal ? 8 : 10)
    }

    private var processingContent: some View {
        HStack(spacing: 8) {
            if !isMinimal {
                Circle().fill(.orange).frame(width: 8, height: 8)
            }
            ProgressView()
                .controlSize(.mini)
                .progressViewStyle(.linear)
                .frame(width: isMinimal ? 48 : 56)
                .tint(.orange)
        }
        .padding(.horizontal, isMinimal ? 10 : 12)
    }

    private var waveformBand: CGFloat { isMinimal ? 12 : 16 }

    private func barHeight(_ level: Float) -> CGFloat {
        // Map RMS (roughly 0…0.3 for speech) into the band. A steeper curve
        // (×3.4 on the sqrt) pushes normal speech well up the band so motion is
        // clearly visible rather than hugging the baseline. Clamped to the band.
        let minH: CGFloat = 2
        let maxH: CGFloat = waveformBand
        let normalized = min(1, CGFloat(level.squareRoot()) * 3.4)
        return minH + (maxH - minH) * normalized
    }
}
