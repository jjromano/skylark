import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

// Adapted from Hex (MIT): Clients/KeyEventMonitorClient.swift and
// handy-keys (MIT): src/platform/macos/listener.rs (fn robustness, reconcile).

/// Owns the active `CGEventTap` for the Fn chord, feeds raw events into a
/// `HotkeyProcessor`, and emits `HotkeyEvent`s. All state is confined to the
/// main run loop (the tap is added to `CFRunLoopGetMain`), hence
/// `@unchecked Sendable`.
public final class HotkeyMonitor: @unchecked Sendable {
    private var processor = HotkeyProcessor()
    /// Sticky Fn state — only ever updated from the Fn keycode's flagsChanged,
    /// never inferred from `.maskSecondaryFn` on other keycodes (they carry it
    /// spuriously on arrows/F-keys).
    private var isFnPressed = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTask: Task<Void, Never>?
    private var tapIsBuilt = false

    private let continuation: AsyncStream<HotkeyEvent>.Continuation
    /// Stream of high-level recording events for the orchestrator.
    public let events: AsyncStream<HotkeyEvent>

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "hotkey")

    public init() {
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Lifecycle (main-thread confined)

    /// Begin watching. Builds the tap when Accessibility is granted; a 1 s
    /// watchdog rebuilds on re-grant and tears down on revocation.
    @MainActor
    public func start() {
        guard watchdogTask == nil else { return }
        reconcilePermissionState()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.reconcilePermissionState()
            }
        }
    }

    @MainActor
    public func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        teardownTap()
    }

    @MainActor
    private func reconcilePermissionState() {
        let trusted = Self.accessibilityTrusted()
        if trusted, !tapIsBuilt {
            buildTap()
        } else if !trusted, tapIsBuilt {
            logger.notice("accessibility revoked; tearing down hotkey tap")
            teardownTap()
        }
    }

    private static func accessibilityTrusted() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt (referencing the bridged
        // global var directly trips Swift 6 concurrency checking).
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
    }

    @MainActor
    private func buildTap() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: cgEvent)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            logger.error("failed to create event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        tapIsBuilt = true
        // Reset derived state on (re)build.
        processor = HotkeyProcessor()
        isFnPressed = false
        logger.info("hotkey tap active")
    }

    @MainActor
    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        tapIsBuilt = false
    }

    // MARK: - Event handling (runs on the main run loop)

    /// Bridges a raw CG event through the processor. Returns nil to swallow the
    /// event (used to suppress the system Globe action on bare Fn).
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable and reconcile after the OS disables the tap.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            isFnPressed = flags.contains(.maskSecondaryFn)
            return Unmanaged.passUnretained(event)
        }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let now = ContinuousClock.now
        let passthrough = Unmanaged.passUnretained(event)

        switch type {
        case .flagsChanged:
            if keycode == kVK_Function {
                let fnDown = event.flags.contains(.maskSecondaryFn)
                isFnPressed = fnDown
                emit(processor.process(fnDown ? .fnDown : .fnUp, at: now))
                // Swallow bare-Fn to suppress the system Globe action.
                return nil
            }
            return passthrough

        case .keyDown:
            // Skip unknown-keycode keyDowns carrying the fn flag (Fn+media keys).
            if event.flags.contains(.maskSecondaryFn), keycode >= 0x80 {
                return passthrough
            }
            let isEscape = (keycode == kVK_Escape)
            emit(processor.process(.otherKeyDown(isEscape: isEscape), at: now))
            return passthrough

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            emit(processor.process(.mouseDown, at: now))
            return passthrough

        default:
            return passthrough
        }
    }

    private func emit(_ event: HotkeyEvent?) {
        if let event {
            continuation.yield(event)
        }
    }
}
