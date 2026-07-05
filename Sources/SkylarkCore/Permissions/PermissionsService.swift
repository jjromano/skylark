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

    public init() {}

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
        microphone = Self.microphoneGrant()
        accessibility = Self.accessibilityGrant()
        inputMonitoring = Self.inputMonitoringGrant()
        fnGlobeActionConflict = Self.readFnGlobeConflict()
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
