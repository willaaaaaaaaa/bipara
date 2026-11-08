import Foundation

/// Granularity of a resolved correspondence.
public enum CorrespondenceGranularity: String, Sendable, Codable, Equatable {
    case phrase
    case sentence
    case fragment
    case paragraph
}

/// A validated model alignment result resolved against current text.
public struct ResolvedAlignment: Equatable, Sendable {
    public var ranges: [TextRange]
    public var granularity: CorrespondenceGranularity

    public init(ranges: [TextRange], granularity: CorrespondenceGranularity) {
        self.ranges = ranges
        self.granularity = granularity
    }
}

/// Literal quote resolution against exact code units.
///
/// Mirrors the Python worker's validation semantics: exact case-sensitive
/// occurrence counting (nonoverlapping, left-to-right), ordered
/// nonoverlapping matches, and composed-character boundary checks before
/// mapping to native UTF-16 ranges.
public enum CorrespondenceResolver {
    /// Index of the `occurrence`-th nonoverlapping literal run of `quote`,
    /// or nil when fewer exist.
    ///
    /// Counting scans raw UTF-16 code units, mirroring Python's code-point
    /// `str.find` semantics: a continuation position that falls inside a
    /// composed character sequence must not end the search, because a later
    /// occurrence may still resolve to a span with valid grapheme
    /// boundaries. Composed-boundary verification happens once, on the
    /// final resolved span, in `resolveMatches`.
    public static func occurrenceIndex(of quote: String, in text: String, occurrence: Int) -> Int? {
        guard occurrence >= 1, !quote.isEmpty else { return nil }
        let haystack = Array(text.utf16)
        let needle = Array(quote.utf16)
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let lastStart = haystack.count - needle.count
        var count = 0
        var searchFrom = 0
        while searchFrom <= lastStart {
            if haystack[searchFrom] == needle[0] {
                var matched = true
                var offset = 1
                while offset < needle.count {
                    if haystack[searchFrom + offset] != needle[offset] {
                        matched = false
                        break
                    }
                    offset += 1
                }
                if matched {
                    count += 1
                    if count == occurrence { return searchFrom }
                    searchFrom += needle.count
                    continue
                }
            }
            searchFrom += 1
        }
        return nil
    }

    /// Resolve validated matches (quote, occurrence) into ordered,
    /// nonoverlapping UTF-16 ranges within `counterpart`. Nil when any
    /// match fails literal existence, ordering, overlap, or composed
    /// boundary checks.
    public static func resolveMatches(
        _ matches: [(quote: String, occurrence: Int)],
        in counterpart: String
    ) -> ResolvedAlignment? {
        guard !matches.isEmpty, matches.count <= WorkerContract.maxMatches else { return nil }
        var cursor = 0
        var ranges: [TextRange] = []
        for match in matches {
            guard let start = occurrenceIndex(of: match.quote, in: counterpart, occurrence: match.occurrence),
                  start >= cursor else { return nil }
            let length = match.quote.utf16.count
            let range = TextRange(location: start, length: length)
            guard counterpart.hasValidRange(range) else { return nil }
            ranges.append(range)
            cursor = start + length
        }
        return ResolvedAlignment(ranges: ranges, granularity: .phrase)
    }

    /// The unit-level fallback correspondence for a selection fully inside
    /// one planned unit, with an honest granularity label. Paragraph-level
    /// fallback (cross-unit selections) is an app-layer decision and is
    /// not produced here.
    public static func fallback(
        selection: TextRange,
        unitRanges: [(unitID: UUID, sourceRange: TextRange, kind: UnitKind)]
    ) -> (range: TextRange, granularity: CorrespondenceGranularity)? {
        for unit in unitRanges where selection.isWithin(unit.sourceRange) {
            return (unit.sourceRange, unit.kind == .sentence ? .sentence : .fragment)
        }
        return nil
    }
}
