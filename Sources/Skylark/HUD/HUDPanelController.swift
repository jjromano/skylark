import AppKit
import SkylarkCore
import SwiftUI

// NSPanel recipe adapted from Hex (MIT): Views/InvisibleWindow.swift, but sized
// to content (not screen-sized) per the Phase 0 HUD spec.

/// A borderless, non-activating floating panel that hosts the HUD pill,
/// sized to its SwiftUI content and clamped just below the notch / menu bar.
@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private let hosting: NSHostingController<HUDView>
    private let model: HUDModel

    init(model: HUDModel, controller: AppController) {
        self.model = model

        let view = HUDView(
            model: model,
            onToggleRecord: { [weak controller] in controller?.toggleHandsFree() },
            onCancel: { [weak controller] in controller?.cancelRecording() },
            onOpenSettings: { [weak controller] in controller?.showSettings() }
        )
        hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 12),
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelResized),
            name: NSWindow.didResizeNotification,
            object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var canBecomeKey: Bool { false }

    /// Exposed read-only so `HUDBannerPanelController` can anchor its own
    /// panel just below this one and stay in sync with its position/size
    /// (screen changes, hover expand/collapse) without this controller
    /// needing to know the banner panel exists.
    var window: NSWindow { panel }

    func show() {
        refreshLayout()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Re-fit the panel to its content, re-clamp its position, and apply the
    /// style-driven visibility (hidden style / hidden idle pill order out).
    func refreshLayout() {
        let visible = HUDMetrics.isVisible(
            state: model.state,
            hovering: model.isHovering,
            style: model.style,
            showIdlePill: model.showIdlePill,
            isPreparing: model.isPreparing
        )
        guard visible else {
            panel.orderOut(nil)
            return
        }
        let size = HUDMetrics.size(for: model.state, hovering: model.isHovering, style: model.style)
        // +4 accounts for the 2pt padding around the pill in HUDView.
        panel.setContentSize(CGSize(width: size.width + 4, height: size.height + 4))
        reposition()
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        reposition()
    }

    @objc private func panelResized() {
        reposition()
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2

        let topInset = screen.safeAreaInsets.top
        let y: CGFloat
        if topInset > 0 {
            // Just below the notch.
            y = screen.frame.maxY - topInset - size.height - HUDMetrics.topGap
        } else {
            // Just below the menu bar.
            y = screen.visibleFrame.maxY - size.height - HUDMetrics.topGap
        }
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}
