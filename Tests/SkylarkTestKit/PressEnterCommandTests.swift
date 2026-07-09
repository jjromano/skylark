import Testing
import SkylarkCore

/// Terminal "press enter" / "press return" detection and stripping. Pure and
/// table-driven; no keystroke synthesis is exercised here.
@Suite("PressEnterCommand.strip")
struct PressEnterCommandTests {
    struct Case: Sendable {
        let input: String
        let text: String
        let pressEnter: Bool
        let note: String
    }

    static let cases: [Case] = [
        // Ends-with variants.
        .init(input: "Ship it press enter", text: "Ship it", pressEnter: true, note: "bare terminal enter"),
        .init(input: "Ship it press return", text: "Ship it", pressEnter: true, note: "bare terminal return"),
        .init(input: "Ship it PRESS ENTER", text: "Ship it", pressEnter: true, note: "uppercase"),
        .init(input: "Ship it Press Enter", text: "Ship it", pressEnter: true, note: "title case"),

        // Punctuation the cleanup model may append.
        .init(input: "Ship it. Press enter.", text: "Ship it.", pressEnter: true, note: "own sentence, trailing period"),
        .init(input: "Ship it. Press enter!", text: "Ship it.", pressEnter: true, note: "trailing bang"),
        .init(input: "Ship it. Press enter?", text: "Ship it.", pressEnter: true, note: "trailing question"),
        .init(input: "Ship it, press enter,", text: "Ship it,", pressEnter: true, note: "comma boundary kept"),
        .init(input: "Ship it. Press return.  ", text: "Ship it.", pressEnter: true, note: "trailing whitespace"),

        // Whole utterance is only the command.
        .init(input: "Press enter", text: "", pressEnter: true, note: "command only"),
        .init(input: "press enter.", text: "", pressEnter: true, note: "command only w/ period"),
        .init(input: "Press return!", text: "", pressEnter: true, note: "command only return w/ bang"),

        // Negatives — command must be terminal.
        .init(input: "press enter to continue", text: "press enter to continue", pressEnter: false, note: "mid-text"),
        .init(input: "press enter please", text: "press enter please", pressEnter: false, note: "non-terminal trailing word"),
        .init(input: "how do I express enter", text: "how do I express enter", pressEnter: false, note: "word-boundary: express"),
        .init(input: "just some text", text: "just some text", pressEnter: false, note: "no command"),
        .init(input: "", text: "", pressEnter: false, note: "empty"),
    ]

    @Test("table-driven strip", arguments: cases)
    func strip(_ c: Case) {
        let result = PressEnterCommand.strip(c.input)
        #expect(result.text == c.text, "\(c.note): text")
        #expect(result.pressEnter == c.pressEnter, "\(c.note): pressEnter")
    }
}

/// Script text generation is pure and unit-testable; execution is not (no
/// AppleScript in tests).
@Suite("MediaScript source")
struct MediaScriptTests {
    @Test("isPlaying targets the right app with a boolean query")
    func isPlaying() {
        #expect(MediaScript.isPlaying(.music) == "tell application \"Music\" to player state is playing")
        #expect(MediaScript.isPlaying(.spotify) == "tell application \"Spotify\" to player state is playing")
    }

    @Test("pause / play use the standard scripting verbs")
    func pausePlay() {
        #expect(MediaScript.pause(.music) == "tell application \"Music\" to pause")
        #expect(MediaScript.play(.spotify) == "tell application \"Spotify\" to play")
    }

    @Test("bundle ids are the real ones used for the running check")
    func bundleIDs() {
        #expect(MediaApp.music.bundleID == "com.apple.Music")
        #expect(MediaApp.spotify.bundleID == "com.spotify.client")
    }
}
