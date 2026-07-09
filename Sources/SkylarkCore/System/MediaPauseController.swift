import AppKit
import Foundation
import os

/// A media player Skylark knows how to pause/resume via AppleScript. Only apps
/// that expose the standard `player state`/`play`/`pause` scripting vocabulary
/// belong here — deliberately Music and Spotify only.
public enum MediaApp: CaseIterable, Sendable {
    case music
    case spotify

    /// Bundle identifier used for the running check (never triggers a launch).
    public var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    /// The scripting name used in `tell application "…"`.
    public var scriptName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }
}

/// Pure AppleScript source generation, factored out so it is unit-testable
/// without executing anything. Kept intentionally minimal: one statement per
/// script so a scripting failure in one app can never affect another.
public enum MediaScript {
    /// Boolean script: true iff the (already-running) app is currently playing.
    public static func isPlaying(_ app: MediaApp) -> String {
        "tell application \"\(app.scriptName)\" to player state is playing"
    }

    /// Pause the given app.
    public static func pause(_ app: MediaApp) -> String {
        "tell application \"\(app.scriptName)\" to pause"
    }

    /// Resume playback for the given app.
    public static func play(_ app: MediaApp) -> String {
        "tell application \"\(app.scriptName)\" to play"
    }
}

/// Pauses currently-playing music while the user dictates and resumes exactly
/// what it paused afterwards.
///
/// Concurrency: `NSAppleScript` is main-thread-bound, so this is a `@MainActor`
/// type and its scripting runs on the main actor. The methods are `async` and
/// intended to be invoked fire-and-forget (`Task { await … }`) from the caller
/// so dictation start/stop never awaits them — nothing here is on the audio or
/// paste path. Every failure (no Automation permission, app not scriptable) is a
/// silent no-op; we never launch an app that isn't already running, and never
/// log track or content information.
@MainActor
public final class MediaPauseController {
    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "media")

    /// Apps we paused in `pauseIfPlaying`, to be resumed in `resumeIfPaused`.
    private var paused: Set<MediaApp> = []

    public init() {}

    /// Pause every running media app that is currently playing, remembering which
    /// ones so `resumeIfPaused` can restore exactly those. Never launches an app.
    public func pauseIfPlaying() async {
        for app in MediaApp.allCases {
            // Guard against launching: only script apps already running.
            guard isRunning(app) else { continue }
            guard boolResult(MediaScript.isPlaying(app)) == true else { continue }
            run(MediaScript.pause(app))
            paused.insert(app)
            // Yield between apps so we don't monopolize the main actor.
            await Task.yield()
        }
    }

    /// Resume the apps we paused (and only those), if they are still running.
    /// Clears the remembered set either way.
    public func resumeIfPaused() async {
        let toResume = paused
        paused.removeAll()
        for app in toResume {
            guard isRunning(app) else { continue }
            run(MediaScript.play(app))
            await Task.yield()
        }
    }

    // MARK: - Running check (never launches)

    private func isRunning(_ app: MediaApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    // MARK: - AppleScript execution

    /// Execute a script for its side effect, swallowing any error into a log
    /// line. Returns nothing — callers that need a value use `boolResult`.
    private func run(_ source: String) {
        _ = execute(source)
    }

    /// Execute a script and interpret its result as a boolean, or nil on error.
    private func boolResult(_ source: String) -> Bool? {
        guard let descriptor = execute(source) else { return nil }
        return descriptor.booleanValue
    }

    private func execute(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // Log only the numeric error code — never any track/content info.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            logger.debug("media script skipped (code \(code, privacy: .public))")
            return nil
        }
        return result
    }
}
