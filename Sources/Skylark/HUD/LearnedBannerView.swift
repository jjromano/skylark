import SkylarkCore
import SwiftUI

/// The compact "Learned "word" [Undo]" capsule shown just below the HUD pill
/// for a few seconds after auto-learn adds a dictionary word. Hosted in its
/// own `HUDBannerPanelController` panel (not merged into the pill's own
/// panel) so its window frame always stays snug to just this capsule — no
/// dead transparent area around it for a stray click to land in and get
/// swallowed instead of reaching the app underneath.
struct LearnedBannerView: View {
    @Bindable var model: HUDModel
    var onUndo: () -> Void

    var body: some View {
        if let banner = model.learnedBanner {
            capsule(for: banner)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.18), value: model.learnedBanner)
        }
    }

    @ViewBuilder
    private func capsule(for banner: LearnedBanner) -> some View {
        HStack(spacing: 8) {
            Text(banner.phase == .learned ? "✨ \(banner.learnedText)" : banner.revertedText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize()

            if banner.phase == .learned {
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            ZStack {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous).fill(.black.opacity(0.30))
            }
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.10)))
        )
        .fixedSize()
        .padding(2)
    }
}
