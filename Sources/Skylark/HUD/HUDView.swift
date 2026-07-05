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
        HUDMetrics.size(for: model.state, hovering: model.isHovering)
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.78))
                    .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.08)))
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
            } else {
                statusDot
            }
        case let .listening(level):
            listeningContent(level: level)
        case .processing:
            processingContent
        }
    }

    // MARK: - Pieces

    private var statusDot: some View {
        Circle()
            .fill(Color.secondary)
            .frame(width: 6, height: 6)
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

    private func listeningContent(level: Float) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            // Placeholder waveform slot — stable layout; Phase 1 drives bars.
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: 2, height: barHeight(i, level: level))
                }
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 12)
    }

    private var processingContent: some View {
        HStack(spacing: 8) {
            Circle().fill(.orange).frame(width: 8, height: 8)
            ProgressView()
                .controlSize(.mini)
                .progressViewStyle(.linear)
                .frame(width: 56)
                .tint(.orange)
        }
        .padding(.horizontal, 12)
    }

    private func barHeight(_ index: Int, level: Float) -> CGFloat {
        // Static reserved bars for Phase 0 (level currently unused in geometry).
        let base: [CGFloat] = [4, 8, 12, 10, 12, 6, 4]
        return base[index % base.count]
    }
}
