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
        HUDMetrics.size(for: model.state, hovering: model.isHovering, style: model.style)
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
        HStack(spacing: isMinimal ? 6 : 8) {
            // Whisper mode: hollow dot (stroke only) as a subtle quiet-speech cue.
            // The minimal style drops the dot — the waveform alone is the cue.
            if !isMinimal {
                Group {
                    if model.isWhisperMode {
                        Circle().strokeBorder(.red, lineWidth: 1.5)
                    } else {
                        Circle().fill(.red)
                    }
                }
                .frame(width: 8, height: 8)
            }
            // Live waveform: newest level enters from the trailing edge. Driven
            // at the levels-stream cadence (~15–20 Hz) with eased height changes.
            HStack(spacing: 1) {
                ForEach(Array(model.waveform.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: 2, height: barHeight(level))
                }
            }
            .frame(height: waveformBand)
            .animation(.easeOut(duration: 0.08), value: model.waveform)
        }
        .padding(.horizontal, isMinimal ? 8 : 10)
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
