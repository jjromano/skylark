import AppKit
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

    private let frontmost: FrontmostReader
    private let activate: Activator
    /// Our own bundle ID. A dictation started while Skylark itself was frontmost
    /// (HUD click) has no meaningful target, so the guard stands down.
    private let ownBundleID: String?
    private let pollInterval: Duration
    private let timeout: Duration

    public init(
        frontmost: @escaping FrontmostReader,
        activate: @escaping Activator,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        pollInterval: Duration = .milliseconds(15),
        timeout: Duration = .milliseconds(300)
    ) {
        self.frontmost = frontmost
        self.activate = activate
        self.ownBundleID = ownBundleID
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// Evaluate the guard for the app captured at record start.
    ///
    /// Fast path (captured app still frontmost): one frontmost read, no awaits
    /// that can suspend on anything but the actor. Only the wrong-app case pays
    /// for activation + a bounded poll (`timeout`, default 300 ms).
    public func decide(captured: String?) async -> CapturedTargetDecision {
        guard let captured, captured != ownBundleID else { return .proceed }
        let current = frontmost()
        if current == captured { return .proceed }
        guard await activate(captured) else { return .abort(current: current) }
        // Activation is asynchronous in the window server; verify rather than
        // trust it (OpenWhispr polls the same way).
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            if frontmost() == captured { return .reactivated }
        }
        return .abort(current: frontmost())
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
}
