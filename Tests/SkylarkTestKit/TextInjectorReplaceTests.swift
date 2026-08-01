import CoreFoundation
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

    // MARK: - Caret preservation across an anchored replace (audit U3)

    /// The classic case — caret sat collapsed at the end of the dictation —
    /// still lands collapsed at the end of the cleaned text.
    @Test("Caret at the end of the run follows the replacement")
    func caretAtEndFollows() {
        let caret = TextInjector.caretAfterReplace(
            caret: CFRange(location: 20, length: 0),      // end of a 10-unit run at 10
            anchor: CFRange(location: 10, length: 10),
            originalUTF16Count: 10,
            replacementUTF16Count: 14
        )
        #expect(caret.location == 24)
        #expect(caret.length == 0)
    }

    /// Anchoring means cleanup can land while the user has typed on elsewhere.
    /// Their caret must move with the text, not jump to our edit.
    @Test("Caret typing further down shifts by the length delta")
    func caretAfterRunShifts() {
        let shorter = TextInjector.caretAfterReplace(
            caret: CFRange(location: 200, length: 0),
            anchor: CFRange(location: 10, length: 10),
            originalUTF16Count: 10,
            replacementUTF16Count: 7
        )
        #expect(shorter.location == 197)
        #expect(shorter.length == 0)
    }

    @Test("Caret before the run is untouched")
    func caretBeforeRunUnchanged() {
        let caret = TextInjector.caretAfterReplace(
            caret: CFRange(location: 3, length: 2),
            anchor: CFRange(location: 10, length: 10),
            originalUTF16Count: 10,
            replacementUTF16Count: 4
        )
        #expect(caret.location == 3)
        #expect(caret.length == 2)
    }

    /// A selection overlapping the rewritten run refers to text that no longer
    /// exists; collapse at the end of the replacement rather than leave a
    /// selection spanning half of the new text.
    @Test("Selection overlapping the run collapses at the replacement end")
    func caretOverlappingCollapses() {
        let caret = TextInjector.caretAfterReplace(
            caret: CFRange(location: 12, length: 30),
            anchor: CFRange(location: 10, length: 10),
            originalUTF16Count: 10,
            replacementUTF16Count: 6
        )
        #expect(caret.location == 16)
        #expect(caret.length == 0)
    }
}
