import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hidsystem

// Adapted from Hex (MIT): PermissionClient/PermissionClient+Live.swift and
// Clients/KeyEventMonitorClient.swift (trust checks / deep links).

/// Observable TCC-permission state for onboarding and the hotkey watchdog.
@Observable
@MainActor
public final class PermissionsService {
    public enum Grant: Sendable, Equatable {
        case granted
        case denied
        case notDetermined
    }

    public enum Kind: Sendable, CaseIterable {
        case microphone
        case accessibility
        case inputMonitoring
    }

    /// One poll's worth of grant state. Published on `changes` whenever it differs
    /// from the previous poll, so consumers see EDGES (revocation, re-grant)
    /// instead of having to poll a second time themselves.
    public struct Snapshot: Sendable, Equatable {
        public var microphone: Grant
        public var accessibility: Grant
        public var inputMonitoring: Grant
        public var fnGlobeActionConflict: Bool

        public init(
            microphone: Grant,
            accessibility: Grant,
            inputMonitoring: Grant,
            fnGlobeActionConflict: Bool = false
        ) {
            self.microphone = microphone
            self.accessibility = accessibility
            self.inputMonitoring = inputMonitoring
            self.fnGlobeActionConflict = fnGlobeActionConflict
        }
    }

    public private(set) var microphone: Grant = .notDetermined
    public private(set) var accessibility: Grant = .notDetermined
    public private(set) var inputMonitoring: Grant = .notDetermined

    /// True iff `AppleFnUsageType` is set to a nonzero (non-default) action, so
    /// the user has bound the Globe key — we suppress it while running. Purely
    /// informational for onboarding.
    public private(set) var fnGlobeActionConflict: Bool = false

    /// Value of `kAXTrustedCheckOptionPrompt` as a literal — referencing the
    /// bridged global var directly trips Swift 6 concurrency checking.
    private static let axPromptKey = "AXTrustedCheckOptionPrompt"

    private var pollTask: Task<Void, Never>?

    /// Reads live TCC state. Injected so the change stream is testable without
    /// flipping real system grants (there is no API to do that).
    private let readSnapshot: @MainActor @Sendable () -> Snapshot
    private var lastSnapshot: Snapshot?

    private let changeContinuation: AsyncStream<Snapshot>.Continuation
    /// Grant snapshots, emitted on every CHANGE for the app's lifetime. A grant
    /// can be revoked at any moment — the hotkey tap simply dies when Accessibility
    /// goes — so consumers must keep listening, not stop at first-all-granted.
    public nonisolated let changes: AsyncStream<Snapshot>

    public init(reader: (@MainActor @Sendable () -> Snapshot)? = nil) {
        readSnapshot = reader ?? { PermissionsService.systemSnapshot() }
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(8))
        changes = stream
        changeContinuation = continuation
    }

    deinit {
        changeContinuation.finish()
    }

    public var allGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }

    public func grant(for kind: Kind) -> Grant {
        switch kind {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }

    // MARK: - Refresh

    public func refresh() {
        let snapshot = readSnapshot()
        microphone = snapshot.microphone
        accessibility = snapshot.accessibility
        inputMonitoring = snapshot.inputMonitoring
        fnGlobeActionConflict = snapshot.fnGlobeActionConflict
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        changeContinuation.yield(snapshot)
    }

    private static func systemSnapshot() -> Snapshot {
        Snapshot(
            microphone: microphoneGrant(),
            accessibility: accessibilityGrant(),
            inputMonitoring: inputMonitoringGrant(),
            fnGlobeActionConflict: readFnGlobeConflict()
        )
    }

    private static func microphoneGrant() -> Grant {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func accessibilityGrant() -> Grant {
        let trusted = AXIsProcessTrustedWithOptions([axPromptKey: false] as CFDictionary)
        return trusted ? .granted : .denied
    }

    private static func inputMonitoringGrant() -> Grant {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    private static func readFnGlobeConflict() -> Bool {
        // AppleFnUsageType in com.apple.HIToolbox: 0 = default (no custom action).
        guard let value = CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString,
            "com.apple.HIToolbox" as CFString
        ) else {
            return false
        }
        if let number = value as? Int {
            return number != 0
        }
        return false
    }

    // MARK: - Requests

    public func request(_ kind: Kind) {
        switch kind {
        case .microphone:
            Task { @MainActor in
                _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        cont.resume(returning: granted)
                    }
                }
                self.refresh()
            }
        case .accessibility:
            // Trigger the system prompt exactly once, then open the pane —
            // the prompt alone is insufficient on modern macOS.
            _ = AXIsProcessTrustedWithOptions([Self.axPromptKey: true] as CFDictionary)
            openSettings(for: .accessibility)
        case .inputMonitoring:
            if !CGPreflightListenEventAccess() {
                _ = CGRequestListenEventAccess()
            }
            openSettings(for: .inputMonitoring)
        }
    }

    // MARK: - Deep links

    public func openSettings(for kind: Kind) {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Polling

    public func startPolling(interval: Duration = .milliseconds(500)) {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
