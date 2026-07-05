import Testing
import SkylarkCore

/// Pure range-math for in-place replacement. The AX read/write choreography
/// isn't unit-testable headless (no faked AXUIElement), matching the existing
/// `insertViaAX` structure; the load-bearing UTF-16 math is exercised here.
@Suite("TextInjector replacement range math")
struct TextInjectorReplaceTests {
    @Test("ASCII: candidate range is caret minus inserted length")
    func asciiRange() {
        let text = "hello"
        let count = TextInjector.utf16Count(text) // 5
        let range = TextInjector.candidateRange(caretLocation: 12, insertedUTF16Count: count)
        #expect(range?.location == 7)
        #expect(range?.length == 5)
    }

    @Test("Emoji count in UTF-16 code units (surrogate pairs)")
    func emojiUTF16() {
        #expect(TextInjector.utf16Count("😀") == 2)       // one surrogate pair
        #expect(TextInjector.utf16Count("a😀b") == 4)
        #expect(TextInjector.utf16Count("👨‍👩‍👧") == 8)  // ZWJ family
    }

    @Test("Emoji: range length uses UTF-16 units, not character count")
    func emojiRange() {
        let text = "hi😀"                              // 2 + 2 = 4 UTF-16 units
        let count = TextInjector.utf16Count(text)
        #expect(count == 4)
        let range = TextInjector.candidateRange(caretLocation: 10, insertedUTF16Count: count)
        #expect(range?.location == 6)
        #expect(range?.length == 4)
    }

    @Test("Multibyte (non-BMP) accented text counts correctly")
    func multibyte() {
        // Combining vs precomposed: "café" precomposed = 4 units.
        #expect(TextInjector.utf16Count("café") == 4)
    }

    @Test("Underflow (caret before inserted text) yields nil")
    func underflow() {
        #expect(TextInjector.candidateRange(caretLocation: 3, insertedUTF16Count: 5) == nil)
    }

    @Test("Caret exactly at inserted length gives a zero-based range")
    func exactStart() {
        let range = TextInjector.candidateRange(caretLocation: 5, insertedUTF16Count: 5)
        #expect(range?.location == 0)
        #expect(range?.length == 5)
    }
}
