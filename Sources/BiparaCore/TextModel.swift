import Foundation

/// A half-open UTF-16 range `[location, location + length)` into a source
/// string, per the native text-range contract. Addition is checked; callers
/// must validate against the exact current string before use.
public struct TextRange: Equatable, Sendable, Codable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    /// Checked `location + length`; nil on overflow.
    public var end: Int? {
        location.addingReportingOverflow(length).overflow ? nil : location + length
    }

    /// Contract range shape: nonnegative location and length with checked
    /// addition. Negative, reversed, or overflowing ranges are invalid
    /// everywhere and must be rejected before any substring operation.
    public var isWellFormed: Bool {
        guard location >= 0, length >= 0 else { return false }
        return !location.addingReportingOverflow(length).overflow
    }

    public var isEmpty: Bool { length == 0 }

    /// True when this range lies entirely within `[0, other.end)`.
    /// Both ranges must be well-formed.
    public func isWithin(_ other: TextRange) -> Bool {
        guard isWellFormed, other.isWellFormed,
              let selfEnd = end, let otherEnd = other.end else { return false }
        return location >= other.location && selfEnd <= otherEnd
    }

    public func offset(by delta: Int) -> TextRange? {
        let newLocation = location.addingReportingOverflow(delta)
        guard !newLocation.overflow, newLocation.partialValue >= 0 else { return nil }
        return TextRange(location: newLocation.partialValue, length: length)
    }

    /// Decoded-range form used by the document codec.
    public var asObject: [String: Int] { ["location": location, "length": length] }

    public static func fromObject(_ value: [String: Int]) -> TextRange? {
        guard let location = value["location"], let length = value["length"],
              location >= 0, length >= 0 else { return nil }
        return TextRange(location: location, length: length)
    }
}

/// Text identity and range resolution over exact code units.
///
/// Swift `String ==` and default Foundation search use canonical
/// equivalence; they must not decide source revision changes, draft
/// equality, reconstruction, or quote matching. Everything here compares
/// UTF-8/UTF-16 code units exactly and searches literally.
public enum TextIdentity {
    /// Exact UTF-8 code-unit equality (not canonical equivalence).
    public static func equal(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// Literal, case-sensitive first occurrence of `needle` at or after
    /// UTF-16 offset `fromUTF16`, in UTF-16 offsets.
    public static func literalSearch(of needle: String, in haystack: String, fromUTF16: Int = 0) -> Int? {
        guard let start = haystack.utf16Index(at: fromUTF16) else { return nil }
        let rest = haystack[start...]
        guard let found = rest.range(of: needle, options: [.literal]) else { return nil }
        guard let utf16Lower = found.lowerBound.samePosition(in: haystack.utf16) else { return nil }
        return haystack.utf16.distance(from: haystack.utf16.startIndex, to: utf16Lower)
    }

    public static func utf8Length(_ s: String) -> Int {
        s.utf8.count
    }
}

extension String {
    /// UTF-16 index for an offset, nil unless it lies on a composed
    /// character boundary (no split surrogates or partial graphemes).
    public func utf16Index(at offset: Int) -> String.Index? {
        guard offset >= 0, offset <= utf16.count else { return nil }
        let viewIndex = utf16.index(utf16.startIndex, offsetBy: offset)
        return viewIndex.samePosition(in: self)
    }

    /// True when both UTF-16 boundaries resolve to composed characters.
    /// Ill-formed ranges (negative/reversed/overflowing) are invalid here
    /// before any index arithmetic. `Range(NSRange, in:)` does not enforce
    /// composed boundaries on this toolchain, so they are validated through
    /// the UTF-16 view explicitly.
    public func hasValidRange(_ range: TextRange) -> Bool {
        guard range.isWellFormed, let end = range.end,
              range.location <= utf16.count, end <= utf16.count else { return false }
        return utf16Index(at: range.location) != nil && utf16Index(at: end) != nil
    }

    /// Substring for a validated UTF-16 range; nil on any ill-formed or
    /// invalid-boundary range. Never constructs a reversed slice.
    public func substring(utf16 range: TextRange) -> String? {
        guard range.isWellFormed, let end = range.end,
              let start = utf16Index(at: range.location),
              let stop = utf16Index(at: end) else { return nil }
        guard start <= stop else { return nil }
        return String(self[start..<stop])
    }

    /// Leading and trailing contract-whitespace split off a string.
    /// Returns (leading, core, trailing).
    public func trimmingWhitespaceSplit() -> (leading: String, core: String, trailing: String) {
        let scalars = Array(unicodeScalars)
        var start = 0
        while start < scalars.count, scalars[start].isContractWhitespace { start += 1 }
        var end = scalars.count
        while end > start, scalars[end - 1].isContractWhitespace { end -= 1 }
        let core = String(String.UnicodeScalarView(scalars[start..<end]))
        let leading = String(String.UnicodeScalarView(scalars[0..<start]))
        let trailing = String(String.UnicodeScalarView(scalars[end...]))
        return (leading, core, trailing)
    }

    public var isWhitespaceOnly: Bool {
        !isEmpty && unicodeScalars.allSatisfy { $0.isContractWhitespace }
    }

    /// True when the string equals its contract-trimmed core: the outer
    /// boundary rule the Python worker enforces on unit and translation
    /// text (`value == value.strip()`).
    public var isContractTrimmed: Bool {
        let (_, core, _) = trimmingWhitespaceSplit()
        return TextIdentity.equal(core, self)
    }
}

extension Unicode.Scalar {
    /// Whitespace under the shared Swift/Python trim contract: the Unicode
    /// White_Space property plus U+001C–U+001F, matching Python's
    /// `str.isspace()`-based `strip()`. Foundation's `.whitespacesAndNewlines`
    /// and `Character.isWhitespace` both miss those four separators.
    public var isContractWhitespace: Bool {
        properties.isWhitespace || (value >= 0x1C && value <= 0x1F)
    }
}

/// Translation direction. `auto` resolves once per job and persists.
public enum Direction: String, Sendable, Codable, CaseIterable {
    case auto
    case zhToEn = "zh_to_en"
    case enToZh = "en_to_zh"

    public var resolved: Bool { self != .auto }
}

/// ISO-style language codes used on the wire (`en` / `zh`).
public enum Language: String, Sendable, Codable {
    case en
    case zh
}

public enum UnitKind: String, Sendable, Codable {
    case sentence
    case fragment
    case markdownInline = "markdown_inline"
    case markdownFragment = "markdown_fragment"

    public var isMarkdown: Bool { self == .markdownInline || self == .markdownFragment }
}

public enum ContentFormat: String, CaseIterable, Sendable, Codable {
    case auto
    case markdown
    case plainText = "plain_text"
}

public enum MarkdownReadingMode: String, CaseIterable, Sendable, Codable {
    case rendered
    case source
}

public enum LayoutMode: String, Sendable, Codable {
    case sideBySide = "side_by_side"
    case paragraphs
}

public enum ReadingSide: String, Sendable, Codable {
    case source
    case translation
}

/// Typed Core errors mapped to user-facing categories by the app layer.
public enum CoreError: Error, Equatable, Sendable {
    case inputTooLarge(actualBytes: Int, maxBytes: Int)
    case unsupportedInput(String)
    case invalidDocument(String)
    case rangeViolation(String)
}
