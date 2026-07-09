import Foundation

/// A user-configurable dictation trigger. A binding is either a keyboard key
/// (a right-side modifier, the Fn/Globe key, or one of F13–F19) or a mouse
/// button. Two bindings can be active at once (one keyboard + one mouse); both
/// drive the same press-hold / double-tap-lock semantics.
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
    /// A mouse button, identified by its CGEvent button number (2 = middle).
    case mouseButton(Int)

    // MARK: - UserDefaults key names (persistence lives in the app layer)

    /// UserDefaults key the app layer should use for the keyboard binding.
    public static let defaultsKeyKeyboard = "hotkey.keyboard"
    /// UserDefaults key the app layer should use for the optional mouse binding.
    public static let defaultsKeyMouse = "hotkey.mouse"

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

    /// Hardware keycode for keyboard bindings; `nil` for mouse bindings.
    public var keyCode: Int? {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case let .functionKey(code): return code
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
        case .functionKey, .mouseButton: return false
        }
    }

    /// True for F13–F19 bindings (detected via keyDown/keyUp).
    public var isFunctionKey: Bool {
        if case .functionKey = self { return true }
        return false
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
        case let .mouseButton(n):
            switch n {
            case 2: return "Middle mouse button"
            default: return "Mouse button \(n + 1)"
            }
        }
    }

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
