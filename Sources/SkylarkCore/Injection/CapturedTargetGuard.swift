import AppKit
import ApplicationServices
import Foundation

// Adapted from OpenWhispr (MIT): remember the app that was frontmost when
// recording started and make sure it is frontmost again before injecting, rather
// than pasting the transcript into whatever happens to be in front when the text
// is ready (a Cmd-Tab, a Slack notification, or a stolen focus mid-dictation
// otherwise dumps the user's words into the wrong app).

/// What the injection boundary should do about the app captured at record start.
public enum CapturedTargetDecision: Sendable, Equatable {
    /// The captured app is frontmost, or there is nothing to compare against
    /// (no capture, or the capture is Skylark itself). Inject now — this is the
    /// hot path and costs exactly one `NSWorkspace` frontmost read.
    case proceed
    /// Focus had moved; the captured app was re-activated and is frontmost again.
    case reactivated
    /// Focus had moved and could not be restored — do NOT inject. Carries the
    /// bundle ID that holds focus instead (diagnostics only).
    case abort(current: String?)
    /// The captured APP is frontmost but a different WINDOW of it holds focus
    /// (a second TextEdit document, a second Mail compose) — do NOT inject. We
    /// deliberately don't raise the captured window: yanking a window forward
    /// under the user is more surprising than not pasting, and the transcript is
    /// still kept in History.
    case abortWrongWindow
}

/// Identity of the window that held focus inside the captured app.
///
/// Bundle identity alone cannot tell two documents of the same app apart, which
/// is exactly where a stray paste — or worse, a synthesized Return — does
/// damage. Compared by window-server id when one is available (authoritative),
/// by `AXUIElement` identity otherwise (`CFEqual` is how the Accessibility API
/// defines element equality, and repeat reads of the same window answer equal).
public struct CapturedWindow: @unchecked Sendable, Equatable {
    /// Owning process. A relaunched app gets a new pid, so a pid change alone
    /// already means the captured window is gone.
    public let pid: pid_t
    /// The focused window element. Only ever compared here — every AX *message*
    /// to it stays on the main actor (hence `@unchecked Sendable`, matching
    /// `InsertionToken`).
    let element: AXUIElement
    /// Window-server id, when the lookup is available on this OS.
    let windowNumber: CGWindowID?

    public init(pid: pid_t, element: AXUIElement, windowNumber: CGWindowID? = nil) {
        self.pid = pid
        self.element = element
        self.windowNumber = windowNumber
    }

    public static func == (lhs: CapturedWindow, rhs: CapturedWindow) -> Bool {
        guard lhs.pid == rhs.pid else { return false }
        if let a = lhs.windowNumber, let b = rhs.windowNumber { return a == b }
        return CFEqual(lhs.element, rhs.element)
    }
}

/// What the user was dictating INTO, snapshotted at record start: the app, plus
/// the specific window when the app exposes one. A nil `window` means "window
/// identity unavailable" (no AX handle, app has no windows, or the read hadn't
/// landed yet) and the guard then behaves exactly as it did bundle-only —
/// never stricter, never more permissive.
public struct CapturedTarget: Sendable, Equatable {
    public let bundleID: String?
    public let window: CapturedWindow?

    public init(bundleID: String?, window: CapturedWindow? = nil) {
        self.bundleID = bundleID
        self.window = window
    }
}

/// Decides `CapturedTargetDecision` from injected closures, so the policy is
/// unit-testable without a window server: `frontmost` is a cheap NSWorkspace
/// read (never AX), `activate` asks the captured app to come forward.
public struct CapturedTargetGuard: Sendable {
    /// Bundle ID of the frontmost app right now.
    public typealias FrontmostReader = @Sendable () -> String?
    /// Ask the app with this bundle ID to activate. Returns false when it isn't
    /// running or refused the request; true only means "request accepted" — the
    /// guard still verifies frontmost-ness by polling.
    public typealias Activator = @Sendable (String) async -> Bool
    /// Focused-window identity of the app with this bundle ID, or nil when it
    /// isn't frontmost, exposes no window, or AX can't answer. One AX read.
    public typealias FocusedWindowReader = @Sendable (String) async -> CapturedWindow?

    private let frontmost: FrontmostReader
    private let activate: Activator
    private let focusedWindow: FocusedWindowReader?
    /// Our own bundle ID. A dictation started while Skylark itself was frontmost
    /// (HUD click) has no meaningful target, so the guard stands down.
    private let ownBundleID: String?
    private let pollInterval: Duration
    private let timeout: Duration

    public init(
        frontmost: @escaping FrontmostReader,
        activate: @escaping Activator,
        focusedWindow: FocusedWindowReader? = nil,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        pollInterval: Duration = .milliseconds(15),
        timeout: Duration = .milliseconds(300)
    ) {
        self.frontmost = frontmost
        self.activate = activate
        self.focusedWindow = focusedWindow
        self.ownBundleID = ownBundleID
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// Snapshot the dictation target at record start: the bundle ID plus, when
    /// the app exposes one, the focused window. The window read is an AX round
    /// trip, so callers run this OFF the record-start path (the orchestrator
    /// kicks it off in a detached task, exactly like the field-context read).
    public func captureTarget(bundleID: String?) async -> CapturedTarget {
        guard let bundleID, bundleID != ownBundleID, let focusedWindow else {
            return CapturedTarget(bundleID: bundleID)
        }
        return CapturedTarget(bundleID: bundleID, window: await focusedWindow(bundleID))
    }

    /// Evaluate the guard for the target captured at record start.
    ///
    /// Fast path (captured app still frontmost): one frontmost read plus — only
    /// when a window was captured — one AX focused-window read. Only the
    /// wrong-app case pays for activation + a bounded poll (`timeout`, default
    /// 300 ms).
    ///
    /// Call this immediately before EVERY write: a verdict taken before a
    /// cleanup stage (which can take seconds on a cold local model) says nothing
    /// about where a keystroke is about to land.
    public func decide(captured: CapturedTarget?) async -> CapturedTargetDecision {
        guard let bundleID = captured?.bundleID, bundleID != ownBundleID else { return .proceed }
        let current = frontmost()
        if current == bundleID {
            return await windowDecision(bundleID: bundleID, captured: captured?.window)
        }
        guard await activate(bundleID) else { return .abort(current: current) }
        // Activation is asynchronous in the window server; verify rather than
        // trust it (OpenWhispr polls the same way).
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            // Re-activation restores the app's key window — which is the window
            // that was focused at capture time — so the cross-app path keeps its
            // existing semantics and does not re-check window identity here.
            if frontmost() == bundleID { return .reactivated }
        }
        return .abort(current: frontmost())
    }

    /// The captured app is frontmost — is it still the same WINDOW of it?
    ///
    /// Degrades to `.proceed` (today's bundle-only verdict) whenever either side
    /// of the comparison is missing: no captured window, no reader wired, or the
    /// app won't answer the AX read. An unavailable window identity must never
    /// turn a perfectly good paste into a false abort.
    private func windowDecision(bundleID: String, captured: CapturedWindow?) async -> CapturedTargetDecision {
        guard let captured, let focusedWindow else { return .proceed }
        guard let current = await focusedWindow(bundleID) else { return .proceed }
        return captured == current ? .proceed : .abortWrongWindow
    }

    /// Live frontmost read — one NSWorkspace query, no AX, no window server round
    /// trip we have to wait on. This is the entire cost of the guard on the happy
    /// path, which is why the paste path can afford it.
    public static let liveFrontmost: FrontmostReader = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Live activator: asks the running app with that bundle ID to come forward.
    /// Main-actor hop keeps all AppKit work on the main thread.
    public static let liveActivator: Activator = { bundleID in
        await MainActor.run {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                return false
            }
            return app.activate()
        }
    }

    /// Live focused-window read: one AX round trip to the frontmost app,
    /// bounded by a short AX messaging timeout so a wedged app can never stall
    /// the paste path. Returns nil (→ bundle-only verdict) when the app isn't
    /// the expected one, has no focused window, or doesn't answer.
    public static let liveFocusedWindow: FocusedWindowReader = { bundleID in
        await MainActor.run { FocusedWindowProbe.read(expecting: bundleID) }
    }
}

/// Reads the focused window of the frontmost app. All AX messaging on the main
/// actor, mirroring `AXTextReader`.
@MainActor
enum FocusedWindowProbe {
    /// Cap on the AX round trip. The guard sits on the fn-up→paste path, so a
    /// non-responsive target must degrade (nil → bundle-only) fast rather than
    /// hold the default 6 s AX timeout.
    private static let messagingTimeout: Float = 0.2

    /// `_AXUIElementGetWindow` is the only way to get a window-server id for an
    /// AX element. It is SPI, so it is resolved at runtime and simply absent
    /// (nil → fall back to `CFEqual` element identity) if it ever goes away —
    /// never a link-time or launch-time dependency.
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowIDFunction: WindowIDFunction? = {
        // -2 == RTLD_DEFAULT (not exported to Swift): search every loaded image.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    static func read(expecting bundleID: String) -> CapturedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else {
            return nil
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let window = focusedRef as! AXUIElement
        return CapturedWindow(pid: pid, element: window, windowNumber: windowNumber(of: window))
    }

    private static func windowNumber(of window: AXUIElement) -> CGWindowID? {
        guard let windowIDFunction else { return nil }
        var identifier: CGWindowID = 0
        guard windowIDFunction(window, &identifier) == .success else { return nil }
        return identifier
    }
}
