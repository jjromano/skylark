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

    // MARK: Bounded recovery
    //
    // Both recovery loops below used to be UNBOUNDED, which is how a revoked
    // Accessibility grant took a machine down: macOS re-disabled the tap the
    // instant we re-enabled it, forever, once per second, while the pipeline sat
    // in a phantom recording state. Every retry path here is bounded and clears
    // itself when the Accessibility trust bit flips, so recovery stays automatic.

    /// Consecutive `.tapDisabledByTimeout` callbacks with no genuine tap event in
    /// between. Any real event resets it — a tap that is delivering is healthy.
    private var consecutiveTimeoutDisables = 0
    private static let maxConsecutiveTimeoutDisables = 5
    /// Consecutive `CGEvent.tapCreate` failures from `buildTap`.
    private var consecutiveTapCreateFailures = 0
    private static let maxTapCreateFailures = 10
    /// Set when a bounded retry budget is spent: the 1 s watchdog stops rebuilding
    /// until the Accessibility trust bit flips (which clears it).
    private var tapExhausted = false
    /// Previous Accessibility trust reading, so the watchdog sees the EDGE.
    /// nil until the first reconcile.
    private var lastTrusted: Bool?

    static let tapUnrecoverableNote =
        "Hotkey monitoring keeps failing — the dictation hotkey is off. "
        + "Toggle Accessibility for Skylark in System Settings to restart it."
    static let tapCreateFailedNote =
        "Skylark can't monitor the dictation hotkey — check Accessibility and "
        + "Input Monitoring in System Settings."

    private let continuation: AsyncStream<HotkeyEvent>.Continuation
    /// Stream of high-level recording events for the orchestrator.
    public let events: AsyncStream<HotkeyEvent>

    private let noteContinuation: AsyncStream<String>.Continuation
    /// User-visible notes about the hotkey itself (the tap dying is invisible to
    /// the pipeline, so it cannot ride the orchestrator's note stream). The app
    /// layer forwards these to the menu bar.
    public nonisolated let notes: AsyncStream<String>

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "hotkey")

    public init() {
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = stream
        self.continuation = continuation
        let (noteStream, noteCont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4))
        notes = noteStream
        noteContinuation = noteCont
    }

    deinit {
        continuation.finish()
        noteContinuation.finish()
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
        if trusted != lastTrusted {
            // The trust bit moved: any retry budget spent under the old state is
            // stale, so toggling Accessibility is always a full reset for the user.
            lastTrusted = trusted
            tapExhausted = false
            consecutiveTapCreateFailures = 0
            consecutiveTimeoutDisables = 0
        }
        if trusted, !tapIsBuilt {
            guard !tapExhausted else { return }
            buildTap()
        } else if !trusted, tapIsBuilt {
            // U8: revocation used to tear the tap down in silence, leaving a live
            // session recording into a trigger that can never be released. Finalize
            // it first; the app layer names Accessibility to the user off the
            // PermissionsService change stream.
            logger.error("accessibility revoked; tearing down hotkey tap — the dictation hotkey is off")
            emitInterruptionIfRecording(reason: .permissionLost, source: "accessibility revoked")
            teardownTap()
        } else if trusted, tapIsBuilt, let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            // The tap was silently disabled (sleep/wake, or a stall) WITHOUT a
            // .tapDisabled callback ever arriving — the hotkey is dead with no
            // recovery. The 1 s watchdog catches it and re-enables. (Hex polls
            // tapIsEnabled the same way.)
            logger.notice("hotkey tap found disabled by watchdog; re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            // Same disruption class as a `.tapDisabledByTimeout` callback, only
            // detected a second later because no callback ever arrived: if a
            // session is live, finalize it at this boundary (WS1).
            emitInterruptionIfRecording(reason: .triggerTapStalled, source: "watchdog found tap dead")
            reconcileTriggerState()
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
            // The 1 s watchdog calls this forever; without a bound a permanently
            // unsatisfiable tap (Input Monitoring denied, TCC mid-flight) spins
            // and logs once a second for the process lifetime with nothing said
            // to the user.
            consecutiveTapCreateFailures += 1
            if consecutiveTapCreateFailures >= Self.maxTapCreateFailures {
                tapExhausted = true
                logger.error("failed to create event tap \(Self.maxTapCreateFailures, privacy: .public)×; no more attempts until the Accessibility grant changes")
                noteContinuation.yield(Self.tapCreateFailedNote)
            } else {
                logger.notice("failed to create event tap (attempt \(self.consecutiveTapCreateFailures, privacy: .public)/\(Self.maxTapCreateFailures, privacy: .public))")
            }
            return
        }
        consecutiveTapCreateFailures = 0

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        tapIsBuilt = true
        // Reset derived state on (re)build. Bindings persist across a rebuild.
        // The recovery budgets reset too: a fresh tap has failed nothing yet.
        consecutiveTimeoutDisables = 0
        tapExhausted = false
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
            // The two reasons are NOT equivalent (WS1):
            // - `byUserInput`: someone called tapEnable(false) — benign, just
            //   re-enable and reconcile.
            // - `byTimeout`: OUR run loop didn't service the tap in time. That
            //   stall is the same event that accompanies a mic/focus steal
            //   (another dictation app grabbing the Fn key, an OS Fn action), and
            //   everything captured after it is silence. It is ALSO what a revoked
            //   Accessibility grant looks like from here — hence the trust check.
            if type == .tapDisabledByTimeout {
                handleTapDisabledByTimeout()
            } else {
                logger.notice("event tap disabled (userInput); re-enabling + reconciling trigger state")
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                reconcileTriggerState()
            }
            return Unmanaged.passUnretained(event)
        }

        // A genuine event proves the tap is alive and delivering: the bounded
        // re-enable budget is spent only on BACK-TO-BACK disables.
        consecutiveTimeoutDisables = 0

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

    /// `.tapDisabledByTimeout` handling. Re-enabling used to be unconditional and
    /// unbounded, which is the whole 60 s "disabled → re-enable → disabled" loop:
    /// with Accessibility revoked macOS disables the tap again immediately, and
    /// nothing in the loop ever consulted the trust bit or gave up.
    ///
    /// Runs on the main run loop (the tap source is on `CFRunLoopGetMain`), so the
    /// `@MainActor` teardown is reachable via `assumeIsolated`.
    private func handleTapDisabledByTimeout() {
        guard Self.accessibilityTrusted() else {
            logger.error("event tap disabled: accessibility revoked")
            emitInterruptionIfRecording(reason: .permissionLost, source: "accessibility revoked")
            MainActor.assumeIsolated { teardownTap() }
            return
        }

        consecutiveTimeoutDisables += 1
        guard consecutiveTimeoutDisables < Self.maxConsecutiveTimeoutDisables else {
            // Trusted, yet the OS keeps killing the tap with no event in between.
            // Re-enabling again only reproduces the loop, so stop and tell the user
            // how to restart it. Same remedy as a revocation, hence the same
            // finalizing reason.
            logger.error("event tap disabled by timeout \(Self.maxConsecutiveTimeoutDisables, privacy: .public)× with no event in between; giving up until the Accessibility grant changes")
            emitInterruptionIfRecording(reason: .permissionLost, source: "hotkey tap unrecoverable")
            MainActor.assumeIsolated {
                tapExhausted = true
                teardownTap()
            }
            noteContinuation.yield(Self.tapUnrecoverableNote)
            return
        }

        logger.notice("event tap disabled (timeout, \(self.consecutiveTimeoutDisables, privacy: .public)/\(Self.maxConsecutiveTimeoutDisables, privacy: .public)); re-enabling + reconciling trigger state")
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        emitInterruptionIfRecording(reason: .triggerTapStalled, source: "tap timeout")
        reconcileTriggerState()
    }

    /// Reconcile sticky trigger state against live hardware state after a tap
    /// re-enable, synthesizing a triggerUp for any active binding that flipped
    /// pressed→released while we were disabled.
    private func reconcileTriggerState() {
        let kb = keyboardBinding
        let kbNow = liveTriggerHeld(for: kb, fallback: keyboardPressed)
        let kbWas = keyboardPressed
        keyboardPressed = kbNow
        if Self.reconcileNeedsSyntheticUp(wasPressed: kbWas, nowPressed: kbNow) {
            logger.notice("reconcile: synthetic triggerUp for keyboard \(kb.rawValue, privacy: .public) (was held, now reads released)")
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
            let cmdNow = liveTriggerHeld(for: cmd, fallback: commandPressed)
            let cmdWas = commandPressed
            commandPressed = cmdNow
            if Self.reconcileNeedsSyntheticUp(wasPressed: cmdWas, nowPressed: cmdNow) {
                logger.notice("reconcile: synthetic triggerUp for command \(cmd.rawValue, privacy: .public) (was held, now reads released)")
                emitCommand(commandProcessor.process(.triggerUp, at: ContinuousClock.now))
            }
        }
    }

    /// Whether the bound keyboard trigger is *still physically held*, queried from
    /// live hardware state after a tap re-enable.
    ///
    /// For a MODIFIER trigger the device flag is OR'd with the physical key state:
    /// the secondary-Fn (globe) flag is unreliable in `combinedSessionState` — it
    /// frequently reads 0 while the key is physically held — so trusting the flag
    /// alone lets a misread synthesize a false triggerUp that clips an in-progress
    /// press-and-hold (the reported "sentence gets cut off mid-hold" bug). Treating
    /// the key as released only when BOTH the flag and the key report up biases
    /// toward "still held": a wrongly-missed release merely leaves recording on
    /// (recoverable by releasing), whereas a wrong release silently truncates the
    /// user's utterance. Function-keys/chords reconcile on physical key state only
    /// (as before); anything without a keycode falls back to the sticky flag.
    private func liveTriggerHeld(for binding: HotkeyBinding, fallback: Bool) -> Bool {
        if binding.isModifier, let mask = flagMask(for: binding) {
            let flagDown = CGEventSource.flagsState(.combinedSessionState).contains(mask)
            let keyDown = binding.keyCode.map {
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
            } ?? false
            let held = Self.modifierStillHeld(flagDown: flagDown, keyDown: keyDown)
            logger.debug("reconcile read \(binding.rawValue, privacy: .public): flag=\(flagDown, privacy: .public) key=\(keyDown, privacy: .public) → held=\(held, privacy: .public)")
            return held
        }
        if (binding.isFunctionKey || binding.isChord), let code = binding.keyCode {
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
        return fallback
    }

    /// A modifier trigger counts as still held if EITHER the device flag or the
    /// physical key reports down — the flag/key-reconcile policy that keeps an
    /// unreliable Fn-flag read from clipping an active hold. Pure so it's unit-
    /// tested without a live event source.
    public static func modifierStillHeld(flagDown: Bool, keyDown: Bool) -> Bool {
        flagDown || keyDown
    }

    /// Whether an interruption at this boundary may reset the trigger state
    /// machines. ONLY a finalizing reason may: after a non-finalizing marker the
    /// orchestrator is still recording, so a reset here would make the user's real
    /// key-up return nil and the session could never be stopped. Pure so the
    /// invariant is unit-tested without a live tap.
    public static func interruptionResetsTriggerState(_ reason: CaptureInterruption.Reason) -> Bool {
        reason.finalizesUtterance
    }

    /// Raise a capture-interruption event when a dictation or command session is
    /// actually live. No session = nothing to finalize, so the stall is silent
    /// (an idle tap stall is routine after sleep/wake).
    ///
    /// Emitted BEFORE `reconcileTriggerState()` so that, for a FINALIZING reason,
    /// the synthetic `triggerUp` a reconcile may follow with lands on an
    /// already-idle pipeline and is a no-op.
    ///
    /// The processors are reset ONLY for a finalizing reason. That asymmetry is
    /// load-bearing: `.triggerTapStalled` leaves the orchestrator recording, so
    /// resetting the state machines here would make the user's real key-up return
    /// nil from `handleTriggerUp` — no `.stopRecording` would ever be emitted, and
    /// the mic would stay open with the HUD stuck listening until quit.
    private func emitInterruptionIfRecording(reason: CaptureInterruption.Reason, source: String) {
        guard processor.isRecording || commandProcessor.isRecording else { return }
        guard Self.interruptionResetsTriggerState(reason) else {
            logger.notice("interruption mid-session (\(source, privacy: .public)); recording continues — the trigger release still ends it")
            continuation.yield(.captureInterrupted)
            return
        }
        logger.notice("interruption mid-session (\(source, privacy: .public)); finalizing the utterance at this boundary")
        continuation.yield(.permissionLost)
        // Keep the state machines in step with the pipeline: the session IS being
        // finalized, so nothing is live here either. Without this, a LOCKED
        // hands-free session would swallow the user's next press as its "stop"
        // (they'd have to press twice to dictate again). Sticky pressed-state is
        // left alone — a still-held trigger's release lands on an idle processor
        // and does nothing, and the next press starts cleanly.
        processor = HotkeyProcessor()
        commandProcessor = HotkeyProcessor(pressAndHoldOnly: true)
    }

    private func emit(_ event: HotkeyEvent?) {
        if let event {
            continuation.yield(event)
        }
        // A hands-free lock formed from a start the orchestrator refused
        // (previous dictation still processing) guards a session that never
        // began — left in place it eats the next press as a phantom "stop".
        // The refusal signal can land before or after the lock forms, so this
        // TTL check covers the lock-after-refusal ordering; noteStartRefused
        // covers refusal-after-lock.
        if processor.state == .doubleTapLock,
           let refused = startRefusedAt,
           refused.duration(to: ContinuousClock.now) < Self.startRefusalTTL {
            startRefusedAt = nil
            if processor.exitDoubleTapLock() {
                logger.notice("hands-free lock released: its start was refused (still processing)")
            }
        }
    }

    /// The pipeline refused a `.startRecording` (a session was still
    /// processing). Remember it briefly so a double-tap lock formed from that
    /// refused start is released instead of eating the next press.
    static let startRefusalTTL: Duration = .milliseconds(1500)
    private var startRefusedAt: ContinuousClock.Instant?

    /// The pipeline ended a hands-free session on its own (VAD endpoint, the
    /// 120 s cap, cancel) — release the double-tap lock so the next press
    /// starts a fresh session instead of being eaten as a phantom stop.
    /// Idempotent: a tap-ended session has already released it.
    @MainActor
    public func noteHandsFreeSessionEnded() {
        if processor.exitDoubleTapLock() {
            logger.notice("hands-free lock released: session ended by the pipeline")
        }
    }

    @MainActor
    public func noteStartRefused() {
        startRefusedAt = ContinuousClock.now
        if processor.exitDoubleTapLock() {
            startRefusedAt = nil
            logger.notice("hands-free lock released: its start was refused (still processing)")
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
        case .engageHandsFree, .startCommand, .stopCommand, .captureInterrupted, .permissionLost: break
        }
    }
}
