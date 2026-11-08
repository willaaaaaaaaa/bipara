import Testing
@testable import BiparaCore

@Suite("Text ranges and exact identity")
struct TextModelTests {
    @Test func checkedRangeArithmetic() {
        let range = TextRange(location: 2, length: 3)
        #expect(range.end == 5)
        #expect(range.isWithin(TextRange(location: 0, length: 10)))
        #expect(!range.isWithin(TextRange(location: 3, length: 10)))
        #expect(TextRange(location: Int.max, length: 1).end == nil)
        #expect(range.offset(by: -2) == TextRange(location: 0, length: 3))
        #expect(range.offset(by: -3) == nil)
    }

    @Test func utf8ExactEqualityRejectsCanonicalEquivalence() {
        // "é" precomposed (U+00E9) vs decomposed (e + U+0301): canonically
        // equal, different code units — must count as different text.
        let precomposed = "\u{00E9}clair"
        let decomposed = "e\u{0301}clair"
        #expect(precomposed == decomposed)          // Swift canonical equality
        #expect(!TextIdentity.equal(precomposed, decomposed))  // exact identity
        #expect(TextIdentity.equal(precomposed, "\u{00E9}clair"))
    }

    @Test func utf16RangeValidationOnComposedBoundaries() {
        let text = "a👩🏽‍💻b" // emoji with skin tone + ZWJ sequence
        // UTF-16 length: a(1) + 👩🏽‍💻(7: 👩(2)+🏽(2)+ZWJ(1)+💻(2)) + b(1) = 9
        #expect(text.utf16.count == 9)
        #expect(text.hasValidRange(TextRange(location: 0, length: 1)))
        #expect(text.hasValidRange(TextRange(location: 1, length: 7)))  // whole emoji
        #expect(!text.hasValidRange(TextRange(location: 1, length: 3))) // splits the sequence
        #expect(!text.hasValidRange(TextRange(location: 1, length: 1))) // high surrogate alone
        #expect(text.hasValidRange(TextRange(location: 8, length: 1)))
        #expect(!text.hasValidRange(TextRange(location: 0, length: 10)))
        #expect(text.substring(utf16: TextRange(location: 1, length: 7)) == "👩🏽‍💻")
        #expect(text.substring(utf16: TextRange(location: 1, length: 3)) == nil)
    }

    @Test func utf16IndexRequiresComposedBoundary() {
        let text = "a👩🏽‍💻b"
        #expect(text.utf16Index(at: 0) != nil)
        #expect(text.utf16Index(at: 1) != nil)
        #expect(text.utf16Index(at: 2) == nil)  // inside the emoji sequence
        #expect(text.utf16Index(at: 9) != nil)  // end
        #expect(text.utf16Index(at: 10) == nil)
    }

    @Test func literalSearchIsExactAndOffset() {
        let text = "I can can fruit."
        #expect(TextIdentity.literalSearch(of: "can", in: text) == 2)
        #expect(TextIdentity.literalSearch(of: "can", in: text, fromUTF16: 3) == 6)
        #expect(TextIdentity.literalSearch(of: "CAN", in: text) == nil)
        // Decomposed vs precomposed must not match literally either way.
        #expect(TextIdentity.literalSearch(of: "\u{00E9}", in: "e\u{0301}x") == nil)
        #expect(TextIdentity.literalSearch(of: "e\u{0301}", in: "\u{00E9}x") == nil)
        #expect(TextIdentity.literalSearch(of: "e\u{0301}", in: "e\u{0301}x") == 0)
    }

    @Test func whitespaceSplitPreservesBoundaries() {
        let (leading, core, trailing) = "  \t你好 world \n ".trimmingWhitespaceSplit()
        #expect(leading == "  \t")
        #expect(core == "你好 world")
        #expect(trailing == " \n ")
        let (l2, c2, t2) = "plain".trimmingWhitespaceSplit()
        #expect(l2 == "" && c2 == "plain" && t2 == "")
        let (l3, c3, t3) = "   ".trimmingWhitespaceSplit()
        #expect(l3 == "   " && c3 == "" && t3 == "")
    }

    @Test func whitespaceOnlyDetection() {
        #expect("  \t\n".isWhitespaceOnly)
        #expect(!" a ".isWhitespaceOnly)
        #expect(!"".isWhitespaceOnly)
    }

    @Test func supplementaryPlaneRangesSurviveRoundTrip() {
        // Supplementary CJK ideograph (U+2A6A5), 4 UTF-8 bytes / 2 UTF-16 units.
        let text = "𪚥字"
        #expect(text.utf16.count == 3)
        #expect(TextIdentity.utf8Length(text) == 7)
        #expect(text.hasValidRange(TextRange(location: 0, length: 2)))
        #expect(text.substring(utf16: TextRange(location: 0, length: 2)) == "𪚥")
    }
}

@Suite("Contract whitespace alignment")
struct ContractWhitespaceTests {
    @Test func fileSeparatorControlsCountAsContractWhitespace() {
        // U+001C–U+001F are trimmable under Python's str.strip(); Swift's
        // Unicode White_Space property misses them, so the shared contract
        // predicate must include them.
        let trailing = "abc\u{1C}"
        let (leading, core, trail) = trailing.trimmingWhitespaceSplit()
        #expect(leading == "" && core == "abc" && trail == "\u{1C}")
        #expect(trailing.isContractTrimmed == false)
        #expect(" \u{1D} ".isWhitespaceOnly)
        #expect("\u{1E}x\u{1F}".trimmingWhitespaceSplit().core == "x")
    }

    @Test func plainWhitespaceStillTrims() {
        let (_, core, _) = "\u{00A0}值\u{2028}".trimmingWhitespaceSplit()
        #expect(core == "值")
    }

    @Test func contractTrimmedMatchesPythonStripRule() {
        #expect("hello".isContractTrimmed)
        #expect(!" hello ".isContractTrimmed)
        #expect(!"hello\u{1F}".isContractTrimmed)
        #expect("窗\u{1C}户".isContractTrimmed)
        #expect("窗\u{1C}".isContractTrimmed == false)
    }
}
