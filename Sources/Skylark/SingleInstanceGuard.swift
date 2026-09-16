import AppKit
import Foundation
import SkylarkCore
import os

/// Enforces "newest launch wins" when more than one copy of Skylark is
/// running under the same bundle identifier.
///
/// LaunchServices refuses to start a second copy of the *same* app bundle
/// path, so a second running instance only exists when someone deliberately
/// opened a different build (e.g. `dist/Skylark.app` from `make run` while an
/// installed copy elsewhere is already running). Two live instances means two
/// global hotkey event taps and two HUD pills fighting over the same input,
/// which is strictly worse than picking one — so the newest launch quits the
/// older ones and keeps running.
@MainActor
enum SingleInstanceGuard {
    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "single-instance")

    /// Finds other running copies of this app, asks `SingleInstancePolicy`
    /// which are older than this launch, and quits them. Waits up to
    /// `timeout` for each to terminate cleanly (so its
    /// `applicationWillTerminate` cleanup runs) before force-terminating any
    /// stragglers.
    static func replaceOlderInstances(timeout: Duration = .seconds(5)) async {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let current = NSRunningApplication.current
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)

        let currentInstance = SingleInstancePolicy.Instance(
            pid: current.processIdentifier, launchDate: current.launchDate)
        let others = running.map {
            SingleInstancePolicy.Instance(pid: $0.processIdentifier, launchDate: $0.launchDate)
        }

        let pidsToReplace = SingleInstancePolicy.instancesToReplace(
            others: others, current: currentInstance)
        guard !pidsToReplace.isEmpty else { return }

        let targets = running.filter { pidsToReplace.contains($0.processIdentifier) }
        logger.notice("replacing \(targets.count, privacy: .public) older instance(s): pids \(pidsToReplace, privacy: .public)")

        for target in targets {
            target.terminate()
        }

        let deadline = ContinuousClock.now + timeout
        while targets.contains(where: { !$0.isTerminated }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let stragglers = targets.filter { !$0.isTerminated }
        if !stragglers.isEmpty {
            logger.notice("force-terminating \(stragglers.count, privacy: .public) straggler instance(s)")
            for straggler in stragglers {
                straggler.forceTerminate()
            }
        }
    }
}
