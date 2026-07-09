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
}
