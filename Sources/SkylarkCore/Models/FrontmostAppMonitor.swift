import AppKit
import Foundation
import os

/// Tracks the frontmost application's bundle ID so the orchestrator can resolve
/// the app-aware mode at dictation start (fn-down), not at paste time
/// (ARCHITECTURE §5). The current value is exposed through a lock-guarded
/// snapshot readable from any actor.
@MainActor
public final class FrontmostAppMonitor {
    private let current = OSAllocatedUnfairLock<String?>(initialState: nil)
    private var observer: NSObjectProtocol?

    public init() {}

    /// Begin observing activation changes and seed the initial frontmost app.
    public func start() {
        current.withLock { $0 = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [current] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            current.withLock { $0 = bundleID }
        }
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    /// The last-known frontmost bundle ID, readable from any isolation domain.
    public nonisolated var currentBundleID: String? {
        current.withLock { $0 }
    }

    /// A `Sendable` snapshot closure the orchestrator captures the value through.
    public nonisolated var snapshot: @Sendable () -> String? {
        { [current] in current.withLock { $0 } }
    }
}
