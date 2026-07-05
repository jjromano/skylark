import Foundation

// Adapted from Hex (MIT): HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift
// Specialised for a modifier-only Fn chord (no key component). Time is injected
// as an explicit `ContinuousClock.Instant` so tests fully control the clock.

/// Discrete inputs the processor understands. The `HotkeyMonitor` derives these
/// from raw `CGEvent`s; tests feed them directly.
public enum HotkeyInput: Sendable, Equatable {
    /// The Fn (Globe) key went down.
    case fnDown
    /// The Fn (Globe) key went up.
    case fnUp
    /// A non-Fn key went down. `isEscape` marks the Escape key.
    case otherKeyDown(isEscape: Bool)
    /// A mouse button went down.
    case mouseDown
}

/// Pure push-to-talk / double-tap-lock state machine for the Fn chord.
///
/// - `idle`: waiting.
/// - `pressAndHold`: Fn held, recording; releasing ≥ `minimumHold` stops+pastes,
///   shorter is discarded (stray taps must not paste).
/// - `doubleTapLock`: hands-free; two quick taps lock recording until the next
///   Fn press stops it.
public struct HotkeyProcessor: Sendable {
    // MARK: Tunables

    /// Max gap between two releases to count as a double-tap.
    public static let doubleTapWindow: Duration = .milliseconds(300)
    /// Minimum press duration for a hold to be treated as real dictation.
    public static let minimumHold: Duration = .milliseconds(300)

    // MARK: State

    public enum State: Sendable, Equatable {
        case idle
        case pressAndHold(start: ContinuousClock.Instant)
        case doubleTapLock
    }

    public private(set) var state: State = .idle

    /// Instant of the most recent Fn release, for double-tap detection.
    private var lastReleaseAt: ContinuousClock.Instant?

    /// When true, ignore all input until Fn is fully released (chord/ESC/dirty).
    private var isDirty = false

    public init() {}

    /// True while a recording session is active (hold or locked).
    public var isRecording: Bool {
        switch state {
        case .idle: return false
        case .pressAndHold, .doubleTapLock: return true
        }
    }

    // MARK: - Processing

    /// Feed one input at `now`; returns an event to act on, or `nil` for none.
    public mutating func process(_ input: HotkeyInput, at now: ContinuousClock.Instant) -> HotkeyEvent? {
        // ESC always cancels an active session.
        if case .otherKeyDown(isEscape: true) = input, state != .idle {
            isDirty = true
            resetToIdle()
            return .cancel
        }

        // While dirty, swallow everything until Fn is fully released.
        if isDirty {
            if input == .fnUp {
                isDirty = false
            }
            return nil
        }

        switch input {
        case .fnDown:
            return handleFnDown(at: now)
        case .fnUp:
            return handleFnUp(at: now)
        case .otherKeyDown:
            return handleOtherKeyDown()
        case .mouseDown:
            return handleMouseDown(at: now)
        }
    }

    // MARK: - Handlers

    private mutating func handleFnDown(at now: ContinuousClock.Instant) -> HotkeyEvent? {
        switch state {
        case .idle:
            state = .pressAndHold(start: now)
            return .startRecording
        case .pressAndHold:
            return nil
        case .doubleTapLock:
            // Pressing Fn again ends a locked session.
            resetToIdle()
            return .stopRecording
        }
    }

    private mutating func handleFnUp(at now: ContinuousClock.Instant) -> HotkeyEvent? {
        guard case let .pressAndHold(start) = state else {
            return nil
        }

        // Double-tap: this release is close to the previous one → lock hands-free.
        if let last = lastReleaseAt, last.duration(to: now) < Self.doubleTapWindow {
            state = .doubleTapLock
            lastReleaseAt = nil
            return nil
        }

        let elapsed = start.duration(to: now)
        lastReleaseAt = now
        state = .idle

        if elapsed < Self.minimumHold {
            // Too short to be real dictation; drop the audio (but keep the
            // release time so a following quick tap can form a double-tap).
            return .discard
        }
        return .stopRecording
    }

    private mutating func handleOtherKeyDown() -> HotkeyEvent? {
        // (ESC handled above.) A different key during an active session means the
        // user meant Fn+key, not dictation: cancel and go dirty until full release.
        switch state {
        case .idle:
            return nil
        case .pressAndHold:
            isDirty = true
            resetToIdle()
            return .cancel
        case .doubleTapLock:
            // Locked hands-free session: ignore stray keys (only ESC/Fn stop it).
            return nil
        }
    }

    private mutating func handleMouseDown(at now: ContinuousClock.Instant) -> HotkeyEvent? {
        guard case let .pressAndHold(start) = state else {
            return nil
        }
        // Only discard clicks inside the min-hold window (Fn+click conflicts);
        // after that, let the recording continue.
        if start.duration(to: now) < Self.minimumHold {
            isDirty = true
            resetToIdle()
            return .discard
        }
        return nil
    }

    private mutating func resetToIdle() {
        state = .idle
        lastReleaseAt = nil
    }
}
