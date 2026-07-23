import AppKit
import SkylarkCore
import SwiftUI

/// A second borderless, non-activating panel that shows the learned-word
/// banner just below the main HUD pill (`HUDPanelController`).
///
/// Deliberately a *separate* panel rather than growing the pill's own panel:
/// the pill's sizing/positioning code (`HUDMetrics`, `HUDPanelController`) is
/// driven by hardcoded per-state sizes that must stay in lockstep with
/// `HUDView`'s fixed-width layout — the banner's width varies with the
/// learned word(s), which that scheme can't express without either fighting
/// `NSHostingController`'s automatic content-size tracking or hand-rolling
/// text measurement. A dedicated panel, sized purely by its own
/// `.preferredContentSize`, sidesteps that entirely, keeps the pill's proven
/// sizing untouched, and — because its window frame is always snug to just
/// the banner capsule — there's no dead transparent area for a stray click
/// to land in and get swallowed instead of reaching the app underneath.
@MainActor
final class HUDBannerPanelController {
    /// Gap between the bottom of the pill panel and the top of the banner.
    static let gap: CGFloat = 6

    private let panel: NSPanel
    private let hosting: NSHostingController<LearnedBannerView>
    private let model: HUDModel
    private let pillPanel: HUDPanelController

    init(model: HUDModel, pillPanel: HUDPanelController, onUndo: @escaping () -> Void) {
        self.model = model
        self.pillPanel = pillPanel

        let view = LearnedBannerView(model: model, onUndo: onUndo)
        hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.fullSizeContentView, .borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Re-anchor whenever this panel's own content resizes (banner text
        // changes width) or the pill panel moves/resizes (screen change,
        // hover expand/collapse) — cheap no-ops while no banner is showing.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reanchor),
            name: NSWindow.didResizeNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reanchor),
            name: NSWindow.didResizeNotification, object: pillPanel.window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reanchor),
            name: NSWindow.didMoveNotification, object: pillPanel.window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reanchor),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        model.onLearnedBannerChange = { [weak self] in self?.refresh() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reanchor() {
        guard model.learnedBanner != nil else { return }
        reposition()
    }

    private func refresh() {
        guard model.learnedBanner != nil else {
            panel.orderOut(nil)
            return
        }
        reposition()
        panel.orderFrontRegardless()
    }

    /// Center under the pill panel's current frame, with a small gap below it.
    private func reposition() {
        let pillFrame = pillPanel.window.frame
        let size = panel.frame.size
        let x = pillFrame.midX - size.width / 2
        let y = pillFrame.minY - Self.gap - size.height
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}
