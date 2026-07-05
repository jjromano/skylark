import Carbon.HIToolbox
import Foundation

/// Resolves virtual key codes for characters on the *current* keyboard layout
/// via `UCKeyTranslate` — no Sauce dependency. Used to synthesize Cmd-V
/// correctly on non-QWERTY layouts.
public enum KeyboardLayout {
    /// Returns the key code that produces `character` (lowercased, no modifiers)
    /// on the active layout. Default `fallback` 9 is ANSI 'V'.
    /// on the active layout, or a sensible fallback.
    public static func keyCode(for character: Character, fallback: CGKeyCode = 9) -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return fallback
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data

        let target = String(character).lowercased()

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> CGKeyCode in
            guard let base = raw.baseAddress else { return fallback }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0

            for code in 0..<CGKeyCode(128) {
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(code),
                    UInt16(kUCKeyActionDown),
                    0, // no modifiers
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                if status == noErr, length > 0 {
                    let produced = String(utf16CodeUnits: chars, count: length).lowercased()
                    if produced == target {
                        return code
                    }
                }
            }
            return fallback
        }
    }
}
