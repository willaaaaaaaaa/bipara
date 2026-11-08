import AppKit
import BiparaCore

public struct ReadingSelection: Equatable, Sendable {
    public var paragraphID: UUID
    public var unitID: UUID?
    public var side: ReadingSide
    public var range: BiparaCore.TextRange
    public init(paragraphID: UUID, unitID: UUID?, side: ReadingSide, range: BiparaCore.TextRange) {
        self.paragraphID = paragraphID; self.unitID = unitID; self.side = side; self.range = range
    }
}

public struct ReadingPresentation: Equatable, Sendable {
    public var selection: ReadingSelection?
    public var pinned: ReadingSelection?
    public var hover: ReadingSelection?
    public var phraseRanges: [BiparaCore.TextRange] = []
    public var pinnedPhraseRanges: [BiparaCore.TextRange] = []
    public var anchors: [LayoutMode: ReadingAnchor] = [:]
    public var selectionGeneration = 0
    public var analyzing = false
    public var revealGeneration = 0
    public init() {}
    var candidate: ReadingSelection? { selection ?? hover }
    var canPin: Bool { candidate != nil && candidate != pinned }
    var displayedPhraseRanges: [BiparaCore.TextRange] { pinned == nil ? phraseRanges : pinnedPhraseRanges }
}

struct RenderedSpan {
    let paragraphID: UUID
    let unitID: UUID?
    let side: ReadingSide
    let range: NSRange
}

/// Labels and display separators deliberately have no selectable model span.
struct RenderedTextIndex {
    var strings = ["", ""]
    var paragraphs: [[RenderedSpan]] = [[], []]
    var units: [[RenderedSpan]] = [[], []]
    var blankRanges: [[NSRange]] = [[], []]
    let layout: LayoutMode

    init(document: BiparaDocument, layout: LayoutMode) {
        self.layout = layout
        let translations = Dictionary(uniqueKeysWithValues: document.translations.map { ($0.unitID, $0.text) })
        let byID = Dictionary(uniqueKeysWithValues: document.units.map { ($0.id, $0) })
        for paragraph in document.paragraphs {
            let plan = SourcePlan(source:document.source,paragraphs:[paragraph],units:paragraph.unitIDs.compactMap{byID[$0]})
            let source = document.source.substring(utf16: paragraph.sourceRange) ?? ""
            let blank=source.isEmpty || source.isWhitespaceOnly
            if layout == .paragraphs,blank {
                for side:ReadingSide in [.source,.translation] {
                    paragraphs[0].append(.init(paragraphID:paragraph.id,unitID:nil,side:side,range:NSRange(location:strings[0].utf16.count,length:0)))
                }
                continue
            }
            let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations,
                                                       targetLanguage: document.jobSnapshot?.targetLanguage ?? .zh)
            let sourceStart = strings[0].utf16.count
            strings[0] += source
            paragraphs[0].append(.init(paragraphID: paragraph.id, unitID: nil, side: .source,
                                       range: NSRange(location: sourceStart, length: source.utf16.count)))
            for id in paragraph.unitIDs {
                guard let unit = byID[id] else { continue }
                units[0].append(.init(paragraphID: paragraph.id, unitID: id, side: .source,
                                     range: NSRange(location: sourceStart + unit.textRange.location - paragraph.sourceRange.location,
                                                    length: unit.textRange.length)))
            }
            let column = layout == .sideBySide ? 1 : 0
            if column == 0 {
                strings[0] += "\n"
            }
            let targetStart = strings[column].utf16.count
            let target = assembly?.text ?? ""
            strings[column] += target
            paragraphs[column].append(.init(paragraphID: paragraph.id, unitID: nil, side: .translation,
                                            range: NSRange(location: targetStart, length: target.utf16.count)))
            for unit in assembly?.unitRanges ?? [] {
                units[column].append(.init(paragraphID: paragraph.id, unitID: unit.unitID, side: .translation,
                                           range: NSRange(location: targetStart + unit.range.location, length: unit.range.length)))
            }
            // An empty target still needs a layout line for column alignment.
            // It deliberately has no selectable document span.
            if column == 1, target.isEmpty, !blank { strings[column] += "\n" }
            if column == 1 {
                let separator=document.source.substring(utf16:paragraph.separatorRange) ?? ""
                strings[0] += separator;strings[1] += separator
                if blank {
                    blankRanges[0].append(NSRange(location:sourceStart,length:source.utf16.count+separator.utf16.count))
                    blankRanges[1].append(NSRange(location:targetStart,length:target.utf16.count+separator.utf16.count))
                }
            } else { strings[0] += "\n" }
        }
    }

    func selection(column: Int, range: NSRange) -> ReadingSelection? {
        guard range.location != NSNotFound, range.location < strings[column].utf16.count else { return nil }
        if let span = units[column].first(where: { NSLocationInRange(range.location, $0.range) && NSMaxRange(range) <= NSMaxRange($0.range) }) {
            let otherSide: ReadingSide = span.side == .source ? .translation : .source
            let otherColumn = layout == .sideBySide && otherSide == .translation ? 1 : 0
            guard units[otherColumn].contains(where: { $0.unitID == span.unitID && $0.side == otherSide }) else {
                guard let paragraph = paragraphs[column].first(where: { $0.paragraphID == span.paragraphID && $0.side == span.side }) else { return nil }
                return .init(paragraphID: span.paragraphID, unitID: nil, side: span.side,
                             range: .init(location: range.location - paragraph.range.location, length: range.length))
            }
            return .init(paragraphID: span.paragraphID, unitID: span.unitID, side: span.side,
                         range: .init(location: range.location - span.range.location, length: range.length))
        }
        guard let span = paragraphs[column].first(where: { NSLocationInRange(range.location, $0.range) }) else { return nil }
        return .init(paragraphID: span.paragraphID, unitID: nil, side: span.side,
                     range: .init(location: max(0, range.location - span.range.location), length: range.length))
    }

    func span(_ selection: ReadingSelection, counterpart: Bool) -> (Int, RenderedSpan)? {
        let side: ReadingSide = counterpart ? (selection.side == .source ? .translation : .source) : selection.side
        let column = layout == .sideBySide && side == .translation ? 1 : 0
        let values = selection.unitID == nil ? paragraphs[column] : units[column]
        guard let span = values.first(where: { $0.paragraphID == selection.paragraphID && $0.side == side && $0.unitID == selection.unitID }) else {
            return paragraphs[column].first(where: { $0.paragraphID == selection.paragraphID && $0.side == side && $0.range.length > 0 }).map { (column, $0) }
        }
        return span.range.length > 0 ? (column, span) : nil
    }
}
