import Foundation

/// Pure interpretation of a raw key event into a `HotkeyBinding`, for the
/// Settings "press your shortcut to record it" recorder. No CoreGraphics /
/// AppKit dependency: the app layer extracts the keycode and modifier flags
/// from an `NSEvent` and passes them here.
///
/// Typical Settings-layer wiring (with an `NSEvent` in hand):
/// ```swift
/// switch event.type {
/// case .keyDown:
///     let result = HotkeyCapture.fromKeyDown(
///         keyCode: Int(event.keyCode),
///         modifierFlagsRawValue: event.modifierFlags.rawValue)
/// case .flagsChanged:
///     // fires on a lone modifier press; keyCode identifies which physical key
///     let result = HotkeyCapture.fromFlagsChanged(keyCode: Int(event.keyCode))
/// default: break
/// }
/// ```
/// `modifierFlagsRawValue` is exactly `NSEvent.ModifierFlags.rawValue` (which
/// shares CoreGraphics' device-independent flag bit layout).
public enum HotkeyCapture {
    /// Why a captured event can't become a binding. All cases carry a
    /// UI-presentable meaning; `unsupportedKey` carries a human-readable reason.
    public enum CaptureError: Error, Equatable, Sendable {
        /// A bare, non-function key was pressed — the user must add a modifier.
        case needsModifier
        /// A lone left-hand ⌘/⌥/⌃ or either ⇧ was pressed; only right-hand
        /// modifiers (and Fn) are bindable on their own.
        case leftModifierUnsupported
        /// The key can never be a trigger (Esc, F1–F12, etc.). The associated
        /// string is a short, user-facing reason.
        case unsupportedKey(String)
    }

    // MARK: - flagsChanged (lone modifier press)

    /// Interpret a `flagsChanged` event, which fires when a modifier key is
    /// pressed or released on its own. `keyCode` is the physical modifier key.
    /// Right-hand ⌘/⌥/⌃ and Fn map to their dedicated bindings; left-hand
    /// modifiers and both shifts are rejected (`leftModifierUnsupported`).
    public static func fromFlagsChanged(keyCode: Int) -> Result<HotkeyBinding, CaptureError> {
        switch keyCode {
        case 63: return .success(.fn)             // kVK_Function (Globe)
        case 54: return .success(.rightCommand)   // kVK_RightCommand
        case 61: return .success(.rightOption)    // kVK_RightOption
        case 62: return .success(.rightControl)   // kVK_RightControl
        case 55,   // kVK_Command (left)
             58,   // kVK_Option (left)
             59,   // kVK_Control (left)
             56,   // kVK_Shift (left)
             60:   // kVK_RightShift
            return .failure(.leftModifierUnsupported)
        default:
            // CapsLock and anything else that arrives via flagsChanged.
            return .failure(.unsupportedKey("That key can't be a trigger"))
        }
    }

    // MARK: - keyDown (chord / function key / rejections)

    /// Interpret a `keyDown` event.
    ///
    /// - A key held with ≥1 of ⌘/⌥/⌃ (Shift alone does *not* count — Shift+key
    ///   is ordinary typing) → `.chord`, whose modifier set includes Shift when
    ///   present (e.g. ⌘⇧K).
    /// - A bare F13–F19 → `.functionKey`. F1–F12 are rejected (they collide with
    ///   system media keys) with a reason pointing at F13+.
    /// - Bare Escape → rejected ("Esc cancels recordings").
    /// - Any other bare key (Return/Space/letter/digit, or a Shift-only chord)
    ///   → `.needsModifier`.
    public static func fromKeyDown(
        keyCode: Int,
        modifierFlagsRawValue: UInt
    ) -> Result<HotkeyBinding, CaptureError> {
        let mods = ChordModifiers(deviceIndependentFlags: modifierFlagsRawValue)
        // Shift does not by itself make a chord; only ⌘/⌥/⌃ do.
        let hasChordModifier =
            mods.contains(.command) || mods.contains(.option) || mods.contains(.control)

        // Escape is never bindable, with or without modifiers.
        if keyCode == 53 {
            return .failure(.unsupportedKey("Esc cancels recordings"))
        }

        if hasChordModifier {
            return .success(.chord(modifiers: mods, keyCode: keyCode))
        }

        // No ⌘/⌥/⌃ held below this point (Shift may be).
        if HotkeyBinding.isFunctionKeyCode(keyCode) {
            return .success(.functionKey(keyCode))
        }
        if Self.functionKeyF1toF12.contains(keyCode) {
            return .failure(.unsupportedKey("F1–F12 are reserved by macOS; use F13–F19"))
        }

        // Bare key (or Shift+key, which is just typing) → needs a real modifier.
        return .failure(.needsModifier)
    }

    /// Hardware keycodes for F1–F12, which collide with system media keys and
    /// are therefore rejected as bare triggers.
    private static let functionKeyF1toF12: Set<Int> =
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
}
