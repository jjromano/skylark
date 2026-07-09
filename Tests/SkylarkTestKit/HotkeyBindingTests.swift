import Testing
import Foundation
import SkylarkCore

@Suite("HotkeyBinding")
struct HotkeyBindingTests {
    @Test("rawValue round-trips for every picker option")
    func rawValueRoundTrip() {
        for binding in HotkeyBinding.keyboardOptions + HotkeyBinding.mouseOptions {
            #expect(HotkeyBinding(rawValue: binding.rawValue) == binding)
        }
    }

    @Test("Stable rawValue strings match the persistence contract")
    func stableRawValues() {
        #expect(HotkeyBinding.fn.rawValue == "fn")
        #expect(HotkeyBinding.rightCommand.rawValue == "rightCommand")
        #expect(HotkeyBinding.rightOption.rawValue == "rightOption")
        #expect(HotkeyBinding.rightControl.rawValue == "rightControl")
        #expect(HotkeyBinding.functionKey(105).rawValue == "f13")
        #expect(HotkeyBinding.functionKey(80).rawValue == "f19")
        #expect(HotkeyBinding.mouseButton(2).rawValue == "mouse2")
        #expect(HotkeyBinding.mouseButton(4).rawValue == "mouse4")
    }

    @Test("Unknown rawValue fails to parse")
    func unknownRawValue() {
        #expect(HotkeyBinding(rawValue: "leftCommand") == nil)
        #expect(HotkeyBinding(rawValue: "") == nil)
        #expect(HotkeyBinding(rawValue: "mouseX") == nil)
    }

    @Test("Keycodes match the spec")
    func keycodes() {
        #expect(HotkeyBinding.fn.keyCode == 63)
        #expect(HotkeyBinding.rightCommand.keyCode == 54)
        #expect(HotkeyBinding.rightOption.keyCode == 61)
        #expect(HotkeyBinding.rightControl.keyCode == 62)
        #expect(HotkeyBinding.functionKey(105).keyCode == 105)
        #expect(HotkeyBinding.mouseButton(2).keyCode == nil)
    }

    @Test("Classification flags are exclusive and correct")
    func classification() {
        #expect(HotkeyBinding.fn.isModifier)
        #expect(HotkeyBinding.rightCommand.isModifier)
        #expect(!HotkeyBinding.fn.isFunctionKey)
        #expect(!HotkeyBinding.fn.isMouse)

        #expect(HotkeyBinding.functionKey(105).isFunctionKey)
        #expect(!HotkeyBinding.functionKey(105).isModifier)
        #expect(!HotkeyBinding.functionKey(105).isMouse)

        #expect(HotkeyBinding.mouseButton(2).isMouse)
        #expect(HotkeyBinding.mouseButton(2).mouseButtonNumber == 2)
        #expect(!HotkeyBinding.mouseButton(2).isModifier)
        #expect(!HotkeyBinding.mouseButton(2).isFunctionKey)
    }

    @Test("Display names are populated for all options")
    func displayNames() {
        for binding in HotkeyBinding.keyboardOptions + HotkeyBinding.mouseOptions {
            #expect(!binding.displayName.isEmpty)
            #expect(binding.displayName != "F?")
        }
        #expect(HotkeyBinding.fn.displayName == "Fn (Globe)")
        #expect(HotkeyBinding.mouseButton(2).displayName == "Middle mouse button")
    }

    @Test("Codable encodes as the bare rawValue string")
    func codableRoundTrip() throws {
        let binding = HotkeyBinding.functionKey(113)
        let data = try JSONEncoder().encode(binding)
        #expect(String(decoding: data, as: UTF8.self) == "\"f15\"")
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        #expect(decoded == binding)
    }

    // MARK: - Chord rawValue

    @Test("Chord rawValue is canonical and round-trips")
    func chordRawValueRoundTrip() {
        let single = HotkeyBinding.chord(modifiers: .option, keyCode: 49)
        #expect(single.rawValue == "chord:opt:49")
        #expect(HotkeyBinding(rawValue: "chord:opt:49") == single)

        let combo = HotkeyBinding.chord(modifiers: [.command, .shift], keyCode: 40)
        #expect(combo.rawValue == "chord:cmd+shift:40")
        #expect(HotkeyBinding(rawValue: combo.rawValue) == combo)
    }

    @Test("Chord modifier tokens serialize in canonical cmd,opt,ctrl,shift order")
    func chordCanonicalOrdering() {
        let all = HotkeyBinding.chord(
            modifiers: [.shift, .control, .option, .command], keyCode: 3)
        #expect(all.rawValue == "chord:cmd+opt+ctrl+shift:3")
        // Any insertion order yields the same canonical rawValue.
        let reordered = HotkeyBinding.chord(
            modifiers: [.command, .control, .shift, .option], keyCode: 3)
        #expect(reordered.rawValue == all.rawValue)
    }

    @Test("Non-canonical chord token order still parses to the same binding")
    func chordParseAnyOrder() {
        let expected = HotkeyBinding.chord(modifiers: [.command, .option], keyCode: 49)
        #expect(HotkeyBinding(rawValue: "chord:opt+cmd:49") == expected)
    }

    @Test("Modifier-less or malformed chord rawValues are rejected")
    func chordRejectsMalformed() {
        #expect(HotkeyBinding(rawValue: "chord::49") == nil)   // empty modifier group
        #expect(HotkeyBinding(rawValue: "chord:49") == nil)    // missing group entirely
        #expect(HotkeyBinding(rawValue: "chord:cmd:") == nil)  // missing keycode
        #expect(HotkeyBinding(rawValue: "chord:cmd:abc") == nil) // non-numeric keycode
        #expect(HotkeyBinding(rawValue: "chord:cmd+bad:49") == nil) // unknown token
        #expect(HotkeyBinding(rawValue: "chord:cmd") == nil)   // no keycode section
    }

    @Test("Chord Codable round-trips via the string rawValue")
    func chordCodableRoundTrip() throws {
        let binding = HotkeyBinding.chord(modifiers: [.command, .shift], keyCode: 40)
        let data = try JSONEncoder().encode(binding)
        #expect(String(decoding: data, as: UTF8.self) == "\"chord:cmd+shift:40\"")
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: data) == binding)
    }

    // MARK: - Chord displayName

    @Test("Chord displayName renders symbols in ⌃⌥⇧⌘ order plus the key name")
    func chordDisplayNames() {
        #expect(HotkeyBinding.chord(modifiers: .option, keyCode: 49).displayName == "⌥Space")
        #expect(HotkeyBinding.chord(modifiers: [.command, .shift], keyCode: 40).displayName == "⇧⌘K")
        #expect(HotkeyBinding.chord(
            modifiers: [.control, .option, .shift, .command], keyCode: 36).displayName
            == "⌃⌥⇧⌘Return")
        #expect(HotkeyBinding.chord(modifiers: .control, keyCode: 48).displayName == "⌃Tab")
    }

    @Test("Chord displayName falls back for an unmapped keycode")
    func chordDisplayNameFallback() {
        #expect(HotkeyBinding.chord(modifiers: .command, keyCode: 999).displayName == "⌘Key 999")
    }

    @Test("Chord classification flags")
    func chordClassification() {
        let chord = HotkeyBinding.chord(modifiers: .option, keyCode: 49)
        #expect(chord.isChord)
        #expect(!chord.isModifier)
        #expect(!chord.isFunctionKey)
        #expect(!chord.isMouse)
        #expect(chord.keyCode == 49)
        #expect(chord.chordModifiers == .option)
    }
}

// MARK: - HotkeyCapture

@Suite("HotkeyCapture")
struct HotkeyCaptureTests {
    // NSEvent.ModifierFlags device-independent bits (== CGEventFlags layout).
    private static let shift: UInt = 1 << 17
    private static let control: UInt = 1 << 18
    private static let option: UInt = 1 << 19
    private static let command: UInt = 1 << 20
    private static let capsLock: UInt = 1 << 16

    @Test("flagsChanged maps right-hand modifiers and Fn to their bindings")
    func flagsChangedRightModifiers() {
        #expect(HotkeyCapture.fromFlagsChanged(keyCode: 63) == .success(.fn))
        #expect(HotkeyCapture.fromFlagsChanged(keyCode: 54) == .success(.rightCommand))
        #expect(HotkeyCapture.fromFlagsChanged(keyCode: 61) == .success(.rightOption))
        #expect(HotkeyCapture.fromFlagsChanged(keyCode: 62) == .success(.rightControl))
    }

    @Test("flagsChanged rejects lone left modifiers and both shifts")
    func flagsChangedLeftModifiers() {
        for code in [55, 58, 59, 56, 60] {
            #expect(HotkeyCapture.fromFlagsChanged(keyCode: code)
                == .failure(.leftModifierUnsupported))
        }
    }

    @Test("flagsChanged rejects other modifier keys (e.g. Caps Lock)")
    func flagsChangedCapsLock() {
        if case .failure(.unsupportedKey) = HotkeyCapture.fromFlagsChanged(keyCode: 57) {
        } else {
            Issue.record("expected unsupportedKey for Caps Lock")
        }
    }

    @Test("keyDown with ⌥ + Space becomes ⌥Space chord")
    func keyDownOptionSpace() {
        let result = HotkeyCapture.fromKeyDown(keyCode: 49, modifierFlagsRawValue: Self.option)
        #expect(result == .success(.chord(modifiers: .option, keyCode: 49)))
    }

    @Test("keyDown with ⌘⇧K includes shift in the chord modifiers")
    func keyDownCommandShiftK() {
        let result = HotkeyCapture.fromKeyDown(
            keyCode: 40, modifierFlagsRawValue: Self.command | Self.shift)
        #expect(result == .success(.chord(modifiers: [.command, .shift], keyCode: 40)))
    }

    @Test("keyDown ignores Caps Lock bit when forming a chord")
    func keyDownIgnoresCapsLock() {
        let result = HotkeyCapture.fromKeyDown(
            keyCode: 49, modifierFlagsRawValue: Self.option | Self.capsLock)
        #expect(result == .success(.chord(modifiers: .option, keyCode: 49)))
    }

    @Test("keyDown with Shift alone is not a chord — needs a real modifier")
    func keyDownShiftOnlyRejected() {
        let result = HotkeyCapture.fromKeyDown(keyCode: 40, modifierFlagsRawValue: Self.shift)
        #expect(result == .failure(.needsModifier))
    }

    @Test("keyDown of a bare letter needs a modifier")
    func keyDownBareLetter() {
        #expect(HotkeyCapture.fromKeyDown(keyCode: 40, modifierFlagsRawValue: 0)
            == .failure(.needsModifier))
        #expect(HotkeyCapture.fromKeyDown(keyCode: 49, modifierFlagsRawValue: 0)
            == .failure(.needsModifier))
    }

    @Test("Bare Escape is rejected with an explanatory reason")
    func keyDownEscapeRejected() {
        if case let .failure(.unsupportedKey(reason)) =
            HotkeyCapture.fromKeyDown(keyCode: 53, modifierFlagsRawValue: 0) {
            #expect(reason.contains("Esc"))
        } else {
            Issue.record("expected unsupportedKey for Escape")
        }
    }

    @Test("Escape is rejected even with a modifier held")
    func keyDownEscapeWithModifierRejected() {
        if case .failure(.unsupportedKey) =
            HotkeyCapture.fromKeyDown(keyCode: 53, modifierFlagsRawValue: Self.command) {
        } else {
            Issue.record("expected unsupportedKey for ⌘Esc")
        }
    }

    @Test("Bare F13 is accepted as a function-key binding")
    func keyDownF13Accepted() {
        #expect(HotkeyCapture.fromKeyDown(keyCode: 105, modifierFlagsRawValue: 0)
            == .success(.functionKey(105)))
    }

    @Test("Bare F5 is rejected with a reason suggesting F13+")
    func keyDownF5Rejected() {
        if case let .failure(.unsupportedKey(reason)) =
            HotkeyCapture.fromKeyDown(keyCode: 96, modifierFlagsRawValue: 0) {
            #expect(reason.contains("F13"))
        } else {
            Issue.record("expected unsupportedKey for F5")
        }
    }
}
