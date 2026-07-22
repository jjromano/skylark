import Foundation

/// A parsed `skylark://` deep link (automation from Raycast/Shortcuts/terminal).
/// Pure route-parsing, unit-testable in isolation — the app layer (AppDelegate/
/// AppController) just switches on the result.
public enum DeepLink: Sendable, Equatable {
    /// `skylark://record/start` — begin a hands-free session, exactly like the
    /// HUD record button (`startRecording` + `engageHandsFree`).
    case recordStart
    /// `skylark://record/stop`
    case recordStop
    /// `skylark://record/toggle` — same behavior as the HUD record button.
    case recordToggle
    /// `skylark://record/cancel`
    case recordCancel
    /// `skylark://settings` — open the Settings window.
    case settings

    /// Parse a `skylark://` URL into a route. Returns nil for any other scheme,
    /// an unrecognized host/path, or extra path segments — unknown routes are
    /// logged (no content) and otherwise ignored by the caller.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "skylark" else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch (host, segments) {
        case ("record", ["start"]): return .recordStart
        case ("record", ["stop"]): return .recordStop
        case ("record", ["toggle"]): return .recordToggle
        case ("record", ["cancel"]): return .recordCancel
        case ("settings", []): return .settings
        default: return nil
        }
    }
}
