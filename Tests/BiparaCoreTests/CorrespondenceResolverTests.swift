import Foundation
import Testing
@testable import BiparaCore

@Suite("Correspondence resolution")
struct CorrespondenceResolverTests {
    @Test func occurrenceCountingIsNonoverlappingLeftToRight() {
        #expect(CorrespondenceResolver.occurrenceIndex(of: "can", in: "I can can fruit.", occurrence: 1) == 2)
        #expect(CorrespondenceResolver.occurrenceIndex(of: "can", in: "I can can fruit.", occurrence: 2) == 6)
        #expect(CorrespondenceResolver.occurrenceIndex(of: "can", in: "I can can fruit.", occurrence: 3) == nil)
        // Greedy nonoverlapping counting: "aa" occurs once in "aaa".
        #expect(CorrespondenceResolver.occurrenceIndex(of: "aa", in: "aaa", occurrence: 1) == 0)
        #expect(CorrespondenceResolver.occurrenceIndex(of: "aa", in: "aaa", occurrence: 2) == nil)
        // Case-sensitive and exact: no canonical equivalence.
        #expect(CorrespondenceResolver.occurrenceIndex(of: "CAN", in: "I can can fruit.", occurrence: 1) == nil)
        #expect(CorrespondenceResolver.occurrenceIndex(of: "\u{00E9}", in: "e\u{0301}x", occurrence: 1) == nil)
    }

    @Test func resolveOrderedNonoverlappingMatches() {
        // A06-style discontinuous counterpart: "gave ... back".
        let resolved = CorrespondenceResolver.resolveMatches(
            [(quote: "gave", occurrence: 1), (quote: "back", occurrence: 1)],
            in: "I gave the book back."
        )
        #expect(resolved != nil)
        #expect(resolved?.granularity == .phrase)
        #expect(resolved?.ranges == [
            TextRange(location: 2, length: 4),
            TextRange(location: 16, length: 4),
        ])
    }

    @Test func reverseDirectionUsesTheSameOperation() {
        // A02: reading Chinese, the counterpart is English with repeats.
        let resolved = CorrespondenceResolver.resolveMatches(
            [(quote: "can", occurrence: 2)],
            in: "I can can fruit."
        )
        #expect(resolved?.ranges.first?.location == 6)
    }

    @Test func rejectsUnorderedOverlappingOrMissingMatches() {
        // Quotes reversed relative to counterpart order.
        #expect(CorrespondenceResolver.resolveMatches(
            [(quote: "back", occurrence: 1), (quote: "gave", occurrence: 1)],
            in: "I gave the book back."
        ) == nil)
        // Overlapping spans.
        #expect(CorrespondenceResolver.resolveMatches(
            [(quote: "e the b", occurrence: 1), (quote: "the", occurrence: 1)],
            in: "I gave the book back."
        ) == nil)
        // Absent quote.
        #expect(CorrespondenceResolver.resolveMatches(
            [(quote: "missing", occurrence: 1)],
            in: "I gave the book back."
        ) == nil)
        // Occurrence beyond the available count.
        #expect(CorrespondenceResolver.resolveMatches(
            [(quote: "can", occurrence: 3)],
            in: "I can can fruit."
        ) == nil)
        // Empty and oversized match lists.
        #expect(CorrespondenceResolver.resolveMatches([], in: "abc") == nil)
        let tooMany = (1...9).map { (quote: "a", occurrence: $0) }
        #expect(CorrespondenceResolver.resolveMatches(tooMany, in: String(repeating: "a", count: 12)) == nil)
    }

    @Test func composedBoundaryValidation() {
        // A match whose end would split an emoji sequence is rejected.
        let text = "把 👩🏽\u{200D}💻 装罐"
        #expect(CorrespondenceResolver.resolveMatches(
            [(quote: "👩🏽\u{200D}", occurrence: 1)],
            in: text
        ) == nil)
        let whole = CorrespondenceResolver.resolveMatches(
            [(quote: "👩🏽\u{200D}💻", occurrence: 1)],
            in: text
        )
        #expect(whole != nil)
    }

    @Test func fallbackLabelsUnitGranularity() {
        let units = [
            (UUID(), TextRange(location: 0, length: 10), UnitKind.sentence),
            (UUID(), TextRange(location: 10, length: 5), UnitKind.fragment),
        ]
        let sentenceFallback = CorrespondenceResolver.fallback(
            selection: TextRange(location: 3, length: 2), unitRanges: units
        )
        #expect(sentenceFallback?.granularity == .sentence)
        let fragmentFallback = CorrespondenceResolver.fallback(
            selection: TextRange(location: 12, length: 1), unitRanges: units
        )
        #expect(fragmentFallback?.granularity == .fragment)
        let outside = CorrespondenceResolver.fallback(
            selection: TextRange(location: 15, length: 2), unitRanges: units
        )
        #expect(outside == nil)
    }
}
