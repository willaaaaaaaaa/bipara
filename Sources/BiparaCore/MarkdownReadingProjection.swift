import Foundation

/// A complete snapshot of the text and logical positions available to the native reader.
public struct MarkdownReadingProjection: Equatable, Sendable {
    public let groups: [MarkdownReadingGroup]
    public let isSourceMode: Bool

    public init(groups: [MarkdownReadingGroup], isSourceMode: Bool = false) {
        self.groups = groups
        self.isSourceMode = isSourceMode
    }
}

public struct MarkdownReadingGroup: Equatable, Sendable {
    public let id: UUID
    public let source: [MarkdownReadingBlock]
    public let translation: [MarkdownReadingBlock]

    public init(id: UUID, source: [MarkdownReadingBlock], translation: [MarkdownReadingBlock]) {
        self.id = id
        self.source = source
        self.translation = translation
    }
}

public enum MarkdownReadingBlockKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
    case code
    case rule
    case literal
    case tableCell(MarkdownReadingCell)
}

public struct MarkdownReadingCell: Equatable, Sendable {
    public enum Alignment: String, Sendable {
        case leading, center, trailing
    }

    public let tableID: UUID
    public let row: Int
    public let column: Int
    public let columnCount: Int
    public let alignment: Alignment
    public let header: Bool

    public init(tableID: UUID, row: Int, column: Int, columnCount: Int, alignment: Alignment = .leading, header: Bool = false) {
        self.tableID = tableID
        self.row = row
        self.column = column
        self.columnCount = columnCount
        self.alignment = alignment
        self.header = header
    }
}

public struct MarkdownReadingBlock: Equatable, Sendable {
    public let id: UUID
    public let kind: MarkdownReadingBlockKind
    public let runs: [MarkdownReadingRun]
    public let listDepth: Int
    public let quoteDepth: Int
    public let marker: String?

    public init(id: UUID, kind: MarkdownReadingBlockKind = .paragraph, runs: [MarkdownReadingRun], listDepth: Int = 0, quoteDepth: Int = 0, marker: String? = nil) {
        self.id = id
        self.kind = kind
        self.runs = runs
        self.listDepth = listDepth
        self.quoteDepth = quoteDepth
        self.marker = marker
    }
}

public struct MarkdownReadingRun: Equatable, Sendable {
    public struct Style: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let strikethrough = Style(rawValue: 1 << 2)
        public static let code = Style(rawValue: 1 << 3)
    }

    public let text: String
    public let style: Style
    public let destination: String?
    public let linkTargetBlockID: UUID?
    public let unitID: UUID?
    /// The exact UTF-16 extent of this run in the unit's frozen visible text.
    public let visibleRange: TextRange?

    public init(_ text: String, style: Style = [], destination: String? = nil, linkTargetBlockID: UUID? = nil, unitID: UUID? = nil, visibleRange: TextRange? = nil) {
        self.text = text
        self.style = style
        self.destination = destination
        self.linkTargetBlockID = linkTargetBlockID
        self.unitID = unitID
        self.visibleRange = visibleRange
    }
}
