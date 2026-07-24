import Testing
import SkylarkCore

@Suite("SpokenNumbers — cardinals")
struct SpokenNumbersCardinalTests {
    @Test("Tens + units combine into one figure")
    func tensUnits() {
        #expect(SpokenNumbers.format("twenty three") == "23")
        #expect(SpokenNumbers.format("forty two") == "42")
        #expect(SpokenNumbers.format("ninety nine") == "99")
    }

    @Test("Teens and bare tens convert (above the small-number carve-out)")
    func teensAndTens() {
        #expect(SpokenNumbers.format("seventeen") == "17")
        #expect(SpokenNumbers.format("eleven") == "11")
        #expect(SpokenNumbers.format("twenty") == "20")
        #expect(SpokenNumbers.format("ninety") == "90")
    }

    @Test("Hundreds, with and without a tolerated 'and'")
    func hundreds() {
        #expect(SpokenNumbers.format("one hundred") == "100")
        #expect(SpokenNumbers.format("one hundred and five") == "105")
        #expect(SpokenNumbers.format("one hundred five") == "105")
        #expect(SpokenNumbers.format("two hundred thirty four") == "234")
        #expect(SpokenNumbers.format("one hundred and one") == "101")
    }

    @Test("Thousands and larger scales")
    func scales() {
        #expect(SpokenNumbers.format("three thousand five hundred") == "3500")
        #expect(SpokenNumbers.format("twenty three thousand four hundred fifty six") == "23456")
        #expect(SpokenNumbers.format("two million") == "2000000")
        #expect(SpokenNumbers.format("one billion") == "1000000000")
        #expect(SpokenNumbers.format("one thousand two hundred thirty four") == "1234")
    }
}

@Suite("SpokenNumbers — decimals")
struct SpokenNumbersDecimalTests {
    @Test("Digits after 'point' are read individually")
    func decimals() {
        #expect(SpokenNumbers.format("ninety nine point nine") == "99.9")
        #expect(SpokenNumbers.format("three point one four") == "3.14")
        #expect(SpokenNumbers.format("zero point five") == "0.5")
        #expect(SpokenNumbers.format("twenty three point five") == "23.5")
    }

    @Test("A small number with a decimal still converts (decimal overrides carve-out)")
    func smallDecimalConverts() {
        #expect(SpokenNumbers.format("five point two") == "5.2")
    }

    @Test("A dangling 'point' with no digit is left as prose")
    func danglingPoint() {
        #expect(SpokenNumbers.format("I scored one point") == "I scored one point")
        #expect(SpokenNumbers.format("make a point here") == "make a point here")
    }
}

@Suite("SpokenNumbers — percent")
struct SpokenNumbersPercentTests {
    @Test("Percent attaches to the preceding number as %")
    func percent() {
        #expect(SpokenNumbers.format("three percent") == "3%")
        #expect(SpokenNumbers.format("one hundred percent") == "100%")
        #expect(SpokenNumbers.format("ninety nine point nine percent") == "99.9%")
    }
}

@Suite("SpokenNumbers — currency")
struct SpokenNumbersCurrencyTests {
    @Test("Dollars introduce a $ prefix")
    func dollars() {
        #expect(SpokenNumbers.format("twenty dollars") == "$20")
        #expect(SpokenNumbers.format("one dollar") == "$1")
    }

    @Test("Dollars and cents, cents zero-padded to two digits")
    func dollarsAndCents() {
        #expect(SpokenNumbers.format("one dollar and ninety nine cents") == "$1.99")
        #expect(SpokenNumbers.format("five dollars and five cents") == "$5.05")
        #expect(SpokenNumbers.format("twenty dollars and fifty cents") == "$20.50")
    }

    @Test("'and' between dollars and cents is optional")
    func dollarsCentsNoAnd() {
        #expect(SpokenNumbers.format("twenty dollars fifty cents") == "$20.50")
    }

    /// DOCUMENTED CHOICE: standalone cents (no preceding dollar amount) are NOT
    /// promoted to a currency figure. The number still formats per the normal
    /// cardinal/carve-out rules and the word "cents" is preserved. So a large
    /// number formats ("fifty cents" → "50 cents") while a small one stays prose
    /// ("five cents" → "five cents"). This avoids guessing "$0.50".
    @Test("Standalone cents are left as a plain number + word")
    func standaloneCents() {
        #expect(SpokenNumbers.format("fifty cents") == "50 cents")
        #expect(SpokenNumbers.format("five cents") == "five cents")
    }
}

@Suite("SpokenNumbers — small-number prose carve-out")
struct SpokenNumbersCarveOutTests {
    @Test("A standalone one…ten stays a word in prose")
    func smallStays() {
        #expect(SpokenNumbers.format("I have three apples") == "I have three apples")
        #expect(SpokenNumbers.format("ten") == "ten")
        #expect(SpokenNumbers.format("one") == "one")
        #expect(SpokenNumbers.format("zero") == "zero")
        #expect(SpokenNumbers.format("two apples and three oranges") == "two apples and three oranges")
    }

    @Test("A small number that is part of a larger structure still converts")
    func smallInStructureConverts() {
        #expect(SpokenNumbers.format("twenty three") == "23")       // multi-word
        #expect(SpokenNumbers.format("three percent") == "3%")      // percent
        #expect(SpokenNumbers.format("three dollars") == "$3")      // currency
        #expect(SpokenNumbers.format("three point five") == "3.5")  // decimal
        #expect(SpokenNumbers.format("five hundred") == "500")      // scaled
    }

    @Test("Several standalone small numbers in a row all stay words")
    func multipleSmallStay() {
        #expect(SpokenNumbers.format("one two three") == "one two three")
    }
}

@Suite("SpokenNumbers — idempotency & passthrough")
struct SpokenNumbersIdempotencyTests {
    private func idempotent(_ input: String) -> Bool {
        let once = SpokenNumbers.format(input)
        return SpokenNumbers.format(once) == once
    }

    @Test("Already-digit text passes through unchanged")
    func digitsUnchanged() {
        #expect(SpokenNumbers.format("23") == "23")
        #expect(SpokenNumbers.format("$1.99") == "$1.99")
        #expect(SpokenNumbers.format("99.9%") == "99.9%")
        #expect(SpokenNumbers.format("105") == "105")
    }

    @Test("format(format(x)) == format(x) across representative inputs")
    func doubleFormatStable() {
        for input in [
            "twenty three",
            "one hundred and five",
            "ninety nine point nine percent",
            "one dollar and ninety nine cents",
            "fifty cents",
            "I have three apples",
            "The uptime was ninety nine point nine percent last month",
        ] {
            #expect(idempotent(input), "not idempotent: \(input)")
        }
    }

    @Test("Text with no numbers is returned verbatim")
    func noNumberPassthrough() {
        #expect(SpokenNumbers.format("hello world") == "hello world")
        #expect(SpokenNumbers.format("the third item on the list") == "the third item on the list")
        #expect(SpokenNumbers.format("") == "")
    }
}

@Suite("SpokenNumbers — surrounding text, mixed sentences, edge cases")
struct SpokenNumbersMixedTests {
    @Test("Punctuation, spacing, and non-number capitalization are preserved")
    func preservesSurroundings() {
        #expect(SpokenNumbers.format("We shipped twenty three tickets.") == "We shipped 23 tickets.")
        #expect(SpokenNumbers.format("The uptime was ninety nine point nine percent last month.")
            == "The uptime was 99.9% last month.")
        #expect(SpokenNumbers.format("It cost one dollar and ninety nine cents, total.")
            == "It cost $1.99, total.")
    }

    @Test("A capitalized number word at sentence start still converts")
    func sentenceStart() {
        #expect(SpokenNumbers.format("Twenty three people came.") == "23 people came.")
    }

    @Test("A hyphen between number words is treated as a connector")
    func hyphenConnector() {
        #expect(SpokenNumbers.format("twenty-three") == "23")
    }

    @Test("A comma between numbers breaks the run (both parse separately)")
    func commaBreaksRun() {
        #expect(SpokenNumbers.format("twenty, thirty") == "20, 30")
    }

    @Test("Prose 'and' not connecting two numbers is preserved")
    func proseAndPreserved() {
        #expect(SpokenNumbers.format("twenty and I left") == "20 and I left")
        #expect(SpokenNumbers.format("black and white") == "black and white")
    }

    @Test("Out-of-scope forms (ordinals, times) are left unchanged")
    func outOfScope() {
        #expect(SpokenNumbers.format("the third quarter") == "the third quarter")
    }
}
