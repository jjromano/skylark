import Testing
@testable import SkylarkCore

@Suite("WordCount")
struct WordCountTests {
    @Test("Counts space-separated words")
    func basic() {
        #expect(WordCount.count("hello world") == 2)
    }

    @Test("Empty string is zero words")
    func empty() {
        #expect(WordCount.count("") == 0)
    }

    @Test("Whitespace-only string is zero words")
    func whitespaceOnly() {
        #expect(WordCount.count("   \n\t  ") == 0)
    }

    @Test("A punctuation-only token still counts as one word")
    func punctuationOnlyToken() {
        #expect(WordCount.count("...") == 1)
        #expect(WordCount.count("! ! !") == 3)
    }

    @Test("Multiple spaces and newlines collapse to single separators")
    func multipleSeparatorsCollapse() {
        #expect(WordCount.count("hello   world\n\nfoo\tbar") == 4)
    }

    @Test("Leading and trailing whitespace doesn't add phantom words")
    func leadingTrailingWhitespace() {
        #expect(WordCount.count("  hello world  ") == 2)
    }
}
