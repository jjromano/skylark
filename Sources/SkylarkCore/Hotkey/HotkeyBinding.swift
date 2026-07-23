import Foundation

/// The four "real" chord modifiers (Fn/CapsLock are deliberately excluded — Fn
/// is its own binding, CapsLock is not a usable trigger). An `OptionSet` so a
/// chord can carry any combination; `command` alone, `⌘⇧`, etc.
///
/// Bit layout is Skylark-internal (not the CoreGraphics/Carbon flag positions);
/// `HotkeyMonitor` maps these to `CGEventFlags` bits when matching events.
public struct ChordModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ChordModifiers(rawValue: 1 << 0)
    public static let option = ChordModifiers(rawValue: 1 << 1)
    public static let control = ChordModifiers(rawValue: 1 << 2)
    public static let shift = ChordModifiers(rawValue: 1 << 3)

    /// Tokens in canonical persistence order (cmd, opt, ctrl, shift), joined by
    /// "+". Empty when no modifiers are set — a chord rawValue must never emit
    /// this empty form (see `HotkeyBinding.rawValue`).
    var canonicalRawTokens: String {
        var tokens: [String] = []
        if contains(.command) { tokens.append("cmd") }
        if contains(.option) { tokens.append("opt") }
        if contains(.control) { tokens.append("ctrl") }
        if contains(.shift) { tokens.append("shift") }
        return tokens.joined(separator: "+")
    }

    /// Parse the "+"-joined token group from a chord rawValue. Returns nil for
    /// an empty group, an unknown token, or (thus) a modifier-less chord — a
    /// chord must carry ≥1 modifier.
    init?(rawTokens: Substring) {
        guard !rawTokens.isEmpty else { return nil }
        var mods = ChordModifiers()
        for token in rawTokens.split(separator: "+", omittingEmptySubsequences: false) {
            switch token {
            case "cmd": mods.insert(.command)
            case "opt": mods.insert(.option)
            case "ctrl": mods.insert(.control)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        guard !mods.isEmpty else { return nil }
        self = mods
    }

    /// The CoreGraphics/NSEvent device-independent flag bits for these
    /// modifiers (shift 1<<17, control 1<<18, option 1<<19, command 1<<20).
    /// `HotkeyMonitor` compares against a masked `CGEventFlags.rawValue`.
    var cgEventFlagBits: UInt64 {
        var bits: UInt64 = 0
        if contains(.shift) { bits |= 1 << 17 }
        if contains(.control) { bits |= 1 << 18 }
        if contains(.option) { bits |= 1 << 19 }
        if contains(.command) { bits |= 1 << 20 }
        return bits
    }

    /// Build from an `NSEvent.ModifierFlags.rawValue` (identical bit layout to
    /// `CGEventFlags`). Only the four chord bits are read; capsLock/fn/numeric
    /// pad bits are ignored. The Settings recorder calls this indirectly via
    /// `HotkeyCapture`.
    public init(deviceIndependentFlags raw: UInt) {
        var mods = ChordModifiers()
        if raw & (1 << 17) != 0 { mods.insert(.shift) }
        if raw & (1 << 18) != 0 { mods.insert(.control) }
        if raw & (1 << 19) != 0 { mods.insert(.option) }
        if raw & (1 << 20) != 0 { mods.insert(.command) }
        self = mods
    }

    /// macOS-style symbols in canonical menu order ⌃⌥⇧⌘.
    var displaySymbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A user-configurable dictation trigger. A binding is either a keyboard key
/// (a right-side modifier, the Fn/Globe key, or one of F13–F19), a modifier
/// chord (≥1 of ⌘⌥⌃⇧ plus a key, e.g. ⌥Space), or a mouse button. Two bindings
/// can be active at once (one keyboard + one mouse); both drive the same
/// press-hold / double-tap-lock semantics.
///
/// Foundation-only on purpose: this is a plain value type so it persists as a
/// stable string (`rawValue`) in UserDefaults and is trivially testable. The
/// mapping from a modifier binding to a `CGEventFlags` mask lives in
/// `HotkeyMonitor`, the only consumer that needs CoreGraphics.
public enum HotkeyBinding: Sendable, Equatable, Hashable {
    /// The Fn (Globe) key — the default trigger (keycode 63).
    case fn
    /// Right ⌘ (keycode 54). Right-side only: a left modifier would fire on
    /// every ordinary shortcut.
    case rightCommand
    /// Right ⌥ (keycode 61).
    case rightOption
    /// Right ⌃ (keycode 62).
    case rightControl
    /// A function key F13–F19, identified by its hardware keycode.
    case functionKey(Int)
    /// A modifier chord: ≥1 of ⌘⌥⌃⇧ held while a key is pressed (e.g. ⌥Space).
    /// Detected via keyDown/keyUp with an exact match on the four modifier bits.
    case chord(modifiers: ChordModifiers, keyCode: Int)
    /// A mouse button, identified by its CGEvent button number (2 = middle).
    case mouseButton(Int)

    // MARK: - UserDefaults key names (persistence lives in the app layer)

    /// UserDefaults key the app layer should use for the keyboard binding.
    public static let defaultsKeyKeyboard = "hotkey.keyboard"
    /// UserDefaults key the app layer should use for the optional mouse binding.
    public static let defaultsKeyMouse = "hotkey.mouse"
    /// UserDefaults key for the optional Voice Command Mode keyboard binding
    /// (default UNBOUND — the user enables it in Settings → General).
    public static let defaultsKeyCommand = "hotkey.command"

    // MARK: - Function-key table

    /// Bindable function keys: (hardware keycode, stable rawValue, display label).
    /// Order is F13…F19 as they appear on Apple extended keyboards.
    private static let functionKeys: [(code: Int, raw: String, label: String)] = [
        (105, "f13", "F13"),
        (107, "f14", "F14"),
        (113, "f15", "F15"),
        (106, "f16", "F16"),
        (64, "f17", "F17"),
        (79, "f18", "F18"),
        (80, "f19", "F19"),
    ]

    // MARK: - Derived properties

    /// True if `code` is one of the bindable F13–F19 hardware keycodes.
    static func isFunctionKeyCode(_ code: Int) -> Bool {
        functionKeys.contains { $0.code == code }
    }

    /// Hardware keycode for keyboard bindings; `nil` for mouse bindings.
    public var keyCode: Int? {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case let .functionKey(code): return code
        case let .chord(_, keyCode): return keyCode
        case .mouseButton: return nil
        }
    }

    /// CGEvent button number for mouse bindings; `nil` otherwise.
    public var mouseButtonNumber: Int? {
        if case let .mouseButton(n) = self { return n }
        return nil
    }

    /// True for bindings detected via `flagsChanged` (fn + right modifiers).
    public var isModifier: Bool {
        switch self {
        case .fn, .rightCommand, .rightOption, .rightControl: return true
        case .functionKey, .chord, .mouseButton: return false
        }
    }

    /// True for F13–F19 bindings (detected via keyDown/keyUp).
    public var isFunctionKey: Bool {
        if case .functionKey = self { return true }
        return false
    }

    /// True for modifier-chord bindings (detected via keyDown/keyUp with an
    /// exact modifier match).
    public var isChord: Bool {
        if case .chord = self { return true }
        return false
    }

    /// The modifier set for a chord binding; `nil` otherwise.
    public var chordModifiers: ChordModifiers? {
        if case let .chord(mods, _) = self { return mods }
        return nil
    }

    /// True for mouse-button bindings.
    public var isMouse: Bool { mouseButtonNumber != nil }

    /// Human-readable label for the Settings picker.
    public var displayName: String {
        switch self {
        case .fn: return "Fn (Globe)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        case let .functionKey(code):
            return Self.functionKeys.first { $0.code == code }?.label ?? "F?"
        case let .chord(mods, keyCode):
            return mods.displaySymbols + Self.keyName(forKeyCode: keyCode)
        case let .mouseButton(n):
            switch n {
            case 2: return "Middle mouse button"
            default: return "Mouse button \(n + 1)"
            }
        }
    }

    // MARK: - Key-name table (ANSI display labels for chord key components)

    /// Human-readable label for a hardware keycode, for chord display names.
    /// Uses a static ANSI-layout table (a keycode→character map for the parts
    /// of a chord we render). `KeyboardLayout` only maps character→keycode via
    /// `UCKeyTranslate`, so it is not reusable for this reverse, layout-stable
    /// display lookup. Falls back to "Key <n>" for anything unmapped.
    static func keyName(forKeyCode code: Int) -> String {
        if let named = keyNameTable[code] { return named }
        if let fk = functionKeys.first(where: { $0.code == code }) { return fk.label }
        return "Key \(code)"
    }

    /// ANSI keycode → display label. Letters/digits/punctuation come from the
    /// standard ANSI layout; named keys and arrows use macOS glyphs.
    private static let keyNameTable: [Int: String] = [
        // Letters (ANSI virtual keycodes)
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        // Digit row
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9",
        26: "7", 28: "8", 29: "0",
        // Punctuation
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".", 50: "`",
        // Whitespace / editing
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        // Arrows
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // F1–F12 (rejected by capture, but labelled if ever displayed)
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    // MARK: - Picker options

    /// All keyboard bindings offered in Settings, in display order.
    public static let keyboardOptions: [HotkeyBinding] =
        [.fn, .rightCommand, .rightOption, .rightControl]
        + functionKeys.map { .functionKey($0.code) }

    /// All mouse bindings offered in Settings, in display order.
    public static let mouseOptions: [HotkeyBinding] =
        [.mouseButton(2), .mouseButton(3), .mouseButton(4)]
}

// MARK: - Stable string rawValue for persistence

extension HotkeyBinding: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "fn": self = .fn
        case "rightCommand": self = .rightCommand
        case "rightOption": self = .rightOption
        case "rightControl": self = .rightControl
        default:
            if let fk = Self.functionKeys.first(where: { $0.raw == rawValue }) {
                self = .functionKey(fk.code)
            } else if rawValue.hasPrefix("chord:") {
                // Grammar: "chord:<mods>:<keycode>", mods "+"-joined in canonical
                // order cmd,opt,ctrl,shift with ≥1 modifier (e.g. "chord:cmd+opt:49").
                let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 3,
                      let mods = ChordModifiers(rawTokens: parts[1]),
                      let code = Int(parts[2]) else {
                    return nil
                }
                self = .chord(modifiers: mods, keyCode: code)
            } else if rawValue.hasPrefix("mouse"),
                      let n = Int(rawValue.dropFirst("mouse".count)) {
                self = .mouseButton(n)
            } else {
                return nil
            }
        }
    }

    public var rawValue: String {
        switch self {
        case .fn: return "fn"
        case .rightCommand: return "rightCommand"
        case .rightOption: return "rightOption"
        case .rightControl: return "rightControl"
        case let .functionKey(code):
            return Self.functionKeys.first { $0.code == code }?.raw ?? "f\(code)"
        case let .chord(mods, keyCode):
            return "chord:\(mods.canonicalRawTokens):\(keyCode)"
        case let .mouseButton(n):
            return "mouse\(n)"
        }
    }
}

// MARK: - Codable via the stable rawValue string

extension HotkeyBinding: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let binding = HotkeyBinding(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown HotkeyBinding rawValue \(raw)")
        }
        self = binding
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
