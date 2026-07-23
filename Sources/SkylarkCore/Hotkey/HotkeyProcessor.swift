import Foundation

// Adapted from Hex (MIT): HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift
// Specialised for a modifier-only Fn chord (no key component). Time is injected
// as an explicit `ContinuousClock.Instant` so tests fully control the clock.

/// Discrete inputs the processor understands. The `HotkeyMonitor` derives these
/// from raw `CGEvent`s; tests feed them directly.
///
/// The trigger inputs are physical-source agnostic: whichever key or mouse
/// button is bound (see `HotkeyBinding`), the monitor maps its press/release to
/// `.triggerDown`/`.triggerUp`. If both a keyboard and a mouse trigger are
/// bound, they are interchangeable — a session started by one is continued and
/// stopped by either (the first release ends a hold).
public enum HotkeyInput: Sendable, Equatable {
    /// The bound dictation trigger (key or mouse button) went down.
    case triggerDown
    /// The bound dictation trigger went up.
    case triggerUp
    /// A non-trigger key went down. `isEscape` marks the Escape key.
    case otherKeyDown(isEscape: Bool)
    /// A non-trigger mouse button went down.
    case mouseDown
}

/// Pure push-to-talk / double-tap-lock state machine for the dictation trigger.
///
/// - `idle`: waiting.
/// - `pressAndHold`: trigger held, recording; releasing ≥ `minimumHold`
///   stops+pastes, shorter is discarded (stray taps must not paste).
/// - `doubleTapLock`: hands-free; two quick taps lock recording until the next
///   trigger press stops it.
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

    /// Instant of the most recent trigger release, for double-tap detection.
    private var lastReleaseAt: ContinuousClock.Instant?

    /// When true, ignore all input until the trigger is fully released
    /// (chord/ESC/dirty).
    private var isDirty = false

    /// Press-and-hold-only mode (Voice Command Mode): the double-tap-lock
    /// hands-free path is disabled, so two quick taps never lock — command mode
    /// is strictly hold-to-speak. `.engageHandsFree` is never emitted. Everything
    /// else (min-hold discard, ESC/chord cancel, dirty tracking) is identical.
    private let pressAndHoldOnly: Bool

    public init(pressAndHoldOnly: Bool = false) {
        self.pressAndHoldOnly = pressAndHoldOnly
    }

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

        // While dirty, swallow everything until the trigger is fully released.
        if isDirty {
            if input == .triggerUp {
                isDirty = false
            }
            return nil
        }

        switch input {
        case .triggerDown:
            return handleTriggerDown(at: now)
        case .triggerUp:
            return handleTriggerUp(at: now)
        case .otherKeyDown:
            return handleOtherKeyDown()
        case .mouseDown:
            return handleMouseDown(at: now)
        }
    }

    // MARK: - Handlers

    private mutating func handleTriggerDown(at now: ContinuousClock.Instant) -> HotkeyEvent? {
        switch state {
        case .idle:
            state = .pressAndHold(start: now)
            return .startRecording
        case .pressAndHold:
            // Already holding — a second interchangeable trigger pressing down
            // does not disturb the session.
            return nil
        case .doubleTapLock:
            // Pressing the trigger again ends a locked session.
            resetToIdle()
            return .stopRecording
        }
    }

    private mutating func handleTriggerUp(at now: ContinuousClock.Instant) -> HotkeyEvent? {
        guard case let .pressAndHold(start) = state else {
            return nil
        }

        // Double-tap: this release is close to the previous one → lock hands-free.
        // Signal the orchestrator so it arms VAD endpointing (no key to release).
        // Suppressed in press-and-hold-only mode (command mode never locks).
        if !pressAndHoldOnly, let last = lastReleaseAt, last.duration(to: now) < Self.doubleTapWindow {
            state = .doubleTapLock
            lastReleaseAt = nil
            return .engageHandsFree
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
        // user meant trigger+key, not dictation: cancel and go dirty until full
        // release. (The monitor never routes the bound key here.)
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
        // Only discard clicks inside the min-hold window (trigger+click
        // conflicts); after that, let the recording continue. The monitor never
        // routes the bound mouse button here — it maps to trigger events.
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
