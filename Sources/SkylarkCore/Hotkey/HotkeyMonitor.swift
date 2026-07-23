import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

// Adapted from Hex (MIT): Clients/KeyEventMonitorClient.swift and
// handy-keys (MIT): src/platform/macos/listener.rs (fn robustness, reconcile).

/// Owns the active `CGEventTap` for the dictation trigger, feeds raw events into
/// a `HotkeyProcessor`, and emits `HotkeyEvent`s. The trigger is configurable
/// via `setBindings`: a primary keyboard binding (fn / right modifier / F13–F19)
/// plus an optional mouse-button binding; both drive the same press-hold /
/// double-tap-lock semantics.
///
/// All state is confined to the main run loop (the tap is added to
/// `CFRunLoopGetMain`, and `start`/`stop`/`setBindings` are `@MainActor`), hence
/// `@unchecked Sendable`.
public final class HotkeyMonitor: @unchecked Sendable {
    private var processor = HotkeyProcessor()
    /// Independent state machine for Voice Command Mode (press-and-hold only, no
    /// double-tap-lock). Fed by the command binding's key events; its output is
    /// translated to `.startCommand`/`.stopCommand` (see `emitCommand`).
    private var commandProcessor = HotkeyProcessor(pressAndHoldOnly: true)

    // MARK: Bindings (main-actor confined)

    private var keyboardBinding: HotkeyBinding = .fn
    private var mouseBinding: HotkeyBinding?
    /// Optional Voice Command Mode trigger (keyboard only). nil = unbound.
    /// Distinct from the dictation trigger; when it collides with the dictation
    /// keyboard binding the dictation binding wins (checked first in `handle`).
    private var commandBinding: HotkeyBinding?

    /// Sticky pressed-state for the keyboard trigger. Only ever updated from the
    /// bound keycode's own event (modifier flagsChanged keyed strictly on its
    /// keycode, or F-key keyDown/keyUp) — never inferred from a flag carried
    /// spuriously by another key.
    private var keyboardPressed = false
    /// Sticky pressed-state for the bound mouse button.
    private var mousePressed = false
    /// Sticky pressed-state for the command trigger key.
    private var commandPressed = false

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

    // MARK: - Configuration (main-thread confined)

    /// Set the active trigger bindings. The tap does not need rebuilding — the
    /// mask already covers key/modifier/mouse up+down unconditionally, so this
    /// only swaps which events are treated as the trigger. Any in-flight press
    /// is released so a live session can't get stuck across a binding change.
    @MainActor
    public func setBindings(keyboard: HotkeyBinding, mouse: HotkeyBinding?) {
        keyboardBinding = keyboard
        mouseBinding = mouse
        if keyboardPressed || mousePressed {
            emit(processor.process(.triggerUp, at: ContinuousClock.now))
        }
        keyboardPressed = false
        mousePressed = false
        logger.info("hotkey bindings set: keyboard=\(keyboard.rawValue, privacy: .public) mouse=\(mouse?.rawValue ?? "none", privacy: .public)")
    }

    /// Set (or clear) the optional Voice Command Mode trigger. Like `setBindings`
    /// the tap needn't rebuild — its mask already covers every relevant event.
    /// Any in-flight command press is released so a live command session can't
    /// get stuck across a binding change.
    @MainActor
    public func setCommandBinding(_ binding: HotkeyBinding?) {
        commandBinding = binding
        if commandPressed {
            emitCommand(commandProcessor.process(.triggerUp, at: ContinuousClock.now))
        }
        commandPressed = false
        logger.info("hotkey command binding set: \(binding?.rawValue ?? "none", privacy: .public)")
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
        // Includes key/mouse up+down and flagsChanged unconditionally so binding
        // changes never require rebuilding the tap.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

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
        // Reset derived state on (re)build. Bindings persist across a rebuild.
        processor = HotkeyProcessor()
        commandProcessor = HotkeyProcessor(pressAndHoldOnly: true)
        keyboardPressed = false
        mousePressed = false
        commandPressed = false
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

    /// After the OS disables and we re-enable the tap, we reconcile the sticky
    /// trigger state from the live `CGEventSource` state. If that flips the
    /// trigger pressed→released (we missed the real key/button-up while
    /// disabled), a live recording would be stuck — so feed a synthetic
    /// triggerUp. Pure decision, unit-tested.
    public static func reconcileNeedsSyntheticUp(wasPressed: Bool, nowPressed: Bool) -> Bool {
        wasPressed && !nowPressed
    }

    /// Legacy name retained for existing callers/tests; delegates to the
    /// binding-agnostic `reconcileNeedsSyntheticUp`.
    public static func reconcileNeedsSyntheticFnUp(wasPressed: Bool, nowPressed: Bool) -> Bool {
        reconcileNeedsSyntheticUp(wasPressed: wasPressed, nowPressed: nowPressed)
    }

    /// The four device-independent modifier bits (shift/control/option/command)
    /// used for exact chord matching. Other flag bits — Fn, numeric-pad and the
    /// function bit that arrow keys carry — are masked off so they can't defeat
    /// the comparison.
    static let chordModifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    /// Exact-match test for a chord keyDown: the event's four modifier bits must
    /// equal the chord's modifier set *exactly* (⌥Space must not fire on
    /// ⌥⇧Space). Pure so the decision is unit-tested without a live tap.
    /// `eventFlagsRawValue` is `CGEventFlags.rawValue`.
    public static func chordModifiersMatch(
        eventFlagsRawValue: UInt64, chord: ChordModifiers
    ) -> Bool {
        (eventFlagsRawValue & chordModifierMask) == chord.cgEventFlagBits
    }

    // MARK: - Binding helpers

    /// CGEventFlags mask for a modifier binding; `nil` for non-modifiers.
    private func flagMask(for binding: HotkeyBinding) -> CGEventFlags? {
        switch binding {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightControl: return .maskControl
        case .functionKey, .chord, .mouseButton: return nil
        }
    }

    // MARK: - Event handling (runs on the main run loop)

    /// Bridges a raw CG event through the processor. Returns nil to swallow the
    /// event (used to suppress the bound key/button from reaching the system).
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable and reconcile after the OS disables the tap. If the reconcile
        // flips the trigger pressed→released while a recording is live, feed a
        // synthetic triggerUp so the session can't get stuck recording forever.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            reconcileTriggerState()
            return Unmanaged.passUnretained(event)
        }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let now = ContinuousClock.now
        let passthrough = Unmanaged.passUnretained(event)
        let kb = keyboardBinding

        switch type {
        case .flagsChanged:
            // Modifier trigger, keyed strictly on its own keycode so left-side
            // counterparts (which set the same flag) never fire it.
            if kb.isModifier, keycode == kb.keyCode, let mask = flagMask(for: kb) {
                let down = event.flags.contains(mask)
                keyboardPressed = down
                emit(processor.process(down ? .triggerDown : .triggerUp, at: now))
                return nil  // swallow the bound modifier
            }
            // Command trigger (modifier). Dictation wins any collision above.
            if let cmd = commandBinding, cmd.isModifier, keycode == cmd.keyCode, let mask = flagMask(for: cmd) {
                let down = event.flags.contains(mask)
                commandPressed = down
                emitCommand(commandProcessor.process(down ? .triggerDown : .triggerUp, at: now))
                return nil  // swallow the bound modifier
            }
            return passthrough

        case .keyDown:
            // Function-key trigger: swallow both down/up; ignore auto-repeat.
            if kb.isFunctionKey, keycode == kb.keyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    keyboardPressed = true
                    emit(processor.process(.triggerDown, at: now))
                }
                return nil  // swallow
            }
            // Chord trigger: keycode must match AND the four modifier bits must
            // match exactly. On an exact match, swallow the down (and any
            // auto-repeat) but only trigger once. A keycode match with the wrong
            // modifiers (e.g. ⌥⇧Space when bound to ⌥Space) is NOT our trigger —
            // it falls through and passes through as an ordinary key.
            if case let .chord(mods, code) = kb, keycode == code,
               Self.chordModifiersMatch(eventFlagsRawValue: event.flags.rawValue, chord: mods) {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    keyboardPressed = true
                    emit(processor.process(.triggerDown, at: now))
                }
                return nil  // swallow (down + auto-repeat)
            }
            // Command trigger (function key). Dictation wins any collision above.
            if let cmd = commandBinding, cmd.isFunctionKey, keycode == cmd.keyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    commandPressed = true
                    emitCommand(commandProcessor.process(.triggerDown, at: now))
                }
                return nil  // swallow
            }
            // Command trigger (chord): exact keycode + modifier match, like above.
            if let cmd = commandBinding, case let .chord(mods, code) = cmd, keycode == code,
               Self.chordModifiersMatch(eventFlagsRawValue: event.flags.rawValue, chord: mods) {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    commandPressed = true
                    emitCommand(commandProcessor.process(.triggerDown, at: now))
                }
                return nil  // swallow (down + auto-repeat)
            }
            // Skip unknown-keycode keyDowns carrying the fn flag (Fn+media keys).
            if event.flags.contains(.maskSecondaryFn), keycode >= 0x80 {
                return passthrough
            }
            let isEscape = (keycode == kVK_Escape)
            emit(processor.process(.otherKeyDown(isEscape: isEscape), at: now))
            // ESC (and a stray key) must cancel an active command session too.
            emitCommand(commandProcessor.process(.otherKeyDown(isEscape: isEscape), at: now))
            return passthrough

        case .keyUp:
            if kb.isFunctionKey, keycode == kb.keyCode {
                keyboardPressed = false
                emit(processor.process(.triggerUp, at: now))
                return nil  // swallow
            }
            // Chord release: the keyUp of the chord's key ends the press even if
            // the modifier was already released (users often let go of ⌥ before
            // Space). Only swallow while a chord-press is actually active — a
            // bare key whose down passed through must keep its keyUp.
            if kb.isChord, keycode == kb.keyCode, keyboardPressed {
                keyboardPressed = false
                emit(processor.process(.triggerUp, at: now))
                return nil  // swallow
            }
            // Command trigger release (function key or chord key).
            if let cmd = commandBinding, cmd.isFunctionKey, keycode == cmd.keyCode {
                commandPressed = false
                emitCommand(commandProcessor.process(.triggerUp, at: now))
                return nil  // swallow
            }
            if let cmd = commandBinding, cmd.isChord, keycode == cmd.keyCode, commandPressed {
                commandPressed = false
                emitCommand(commandProcessor.process(.triggerUp, at: now))
                return nil  // swallow
            }
            return passthrough

        case .otherMouseDown:
            if let mouse = mouseBinding, let button = mouse.mouseButtonNumber,
               Self.mouseButtonNumber(of: event) == button {
                mousePressed = true
                emit(processor.process(.triggerDown, at: now))
                return nil  // swallow the bound mouse button (no discard)
            }
            // A non-bound mouse press feeds the "too-short hold" discard path
            // for whichever session (dictation or command) is active.
            emit(processor.process(.mouseDown, at: now))
            emitCommand(commandProcessor.process(.mouseDown, at: now))
            return passthrough

        case .otherMouseUp:
            if let mouse = mouseBinding, let button = mouse.mouseButtonNumber,
               Self.mouseButtonNumber(of: event) == button {
                mousePressed = false
                emit(processor.process(.triggerUp, at: now))
                return nil  // swallow
            }
            return passthrough

        case .leftMouseDown, .rightMouseDown:
            // Left/right are never bindable; they only cancel too-short holds.
            emit(processor.process(.mouseDown, at: now))
            emitCommand(commandProcessor.process(.mouseDown, at: now))
            return passthrough

        default:
            return passthrough
        }
    }

    private static func mouseButtonNumber(of event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.mouseEventButtonNumber))
    }

    /// Reconcile sticky trigger state against live hardware state after a tap
    /// re-enable, synthesizing a triggerUp for any active binding that flipped
    /// pressed→released while we were disabled.
    private func reconcileTriggerState() {
        let kb = keyboardBinding
        let kbNow: Bool
        if kb.isModifier, let mask = flagMask(for: kb) {
            kbNow = CGEventSource.flagsState(.combinedSessionState).contains(mask)
        } else if (kb.isFunctionKey || kb.isChord), let code = kb.keyCode {
            // Chords reconcile on the physical key state only (same as F-keys);
            // the modifier state is irrelevant to whether the press is still held.
            kbNow = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        } else {
            kbNow = keyboardPressed
        }
        let kbWas = keyboardPressed
        keyboardPressed = kbNow
        if Self.reconcileNeedsSyntheticUp(wasPressed: kbWas, nowPressed: kbNow) {
            emit(processor.process(.triggerUp, at: ContinuousClock.now))
            return
        }

        if let mouse = mouseBinding, let button = mouse.mouseButtonNumber,
           let cgButton = CGMouseButton(rawValue: UInt32(button)) {
            let msNow = CGEventSource.buttonState(.combinedSessionState, button: cgButton)
            let msWas = mousePressed
            mousePressed = msNow
            if Self.reconcileNeedsSyntheticUp(wasPressed: msWas, nowPressed: msNow) {
                emit(processor.process(.triggerUp, at: ContinuousClock.now))
            }
        }

        // Command trigger (keyboard only): reconcile the same way and synthesize
        // a command triggerUp if it flipped pressed→released while disabled.
        if let cmd = commandBinding {
            let cmdNow: Bool
            if cmd.isModifier, let mask = flagMask(for: cmd) {
                cmdNow = CGEventSource.flagsState(.combinedSessionState).contains(mask)
            } else if (cmd.isFunctionKey || cmd.isChord), let code = cmd.keyCode {
                cmdNow = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
            } else {
                cmdNow = commandPressed
            }
            let cmdWas = commandPressed
            commandPressed = cmdNow
            if Self.reconcileNeedsSyntheticUp(wasPressed: cmdWas, nowPressed: cmdNow) {
                emitCommand(commandProcessor.process(.triggerUp, at: ContinuousClock.now))
            }
        }
    }

    private func emit(_ event: HotkeyEvent?) {
        if let event {
            continuation.yield(event)
        }
    }

    /// Translate the command processor's (dictation-flavored) output into the
    /// command-mode events the orchestrator routes as a distinct session. The
    /// command processor is press-and-hold-only, so `.engageHandsFree` never
    /// occurs; `.cancel`/`.discard` share the dictation semantics (drop audio,
    /// nothing inserted) and pass through unchanged.
    private func emitCommand(_ event: HotkeyEvent?) {
        guard let event else { return }
        switch event {
        case .startRecording: continuation.yield(.startCommand)
        case .stopRecording: continuation.yield(.stopCommand)
        case .cancel: continuation.yield(.cancel)
        case .discard: continuation.yield(.discard)
        case .engageHandsFree, .startCommand, .stopCommand: break
        }
    }
}
