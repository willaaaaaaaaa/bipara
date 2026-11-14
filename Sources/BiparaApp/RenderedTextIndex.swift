import AppKit
import BiparaCore

public struct ReadingSelection: Equatable, Sendable {
    public var paragraphID: UUID
    public var unitID: UUID?
    public var side: ReadingSide
    public var range: BiparaCore.TextRange
    public var isSection: Bool
    public init(paragraphID: UUID, unitID: UUID?, side: ReadingSide, range: BiparaCore.TextRange, isSection: Bool = false) {
        self.paragraphID = paragraphID; self.unitID = unitID; self.side = side; self.range = range
        self.isSection = isSection
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

struct MarkdownRenderedRun {
    let run: MarkdownReadingRun
    let span: RenderedSpan
}

struct MarkdownRenderedBlock {
    let block: MarkdownReadingBlock
    let span: RenderedSpan
    let paragraphRange: NSRange
}

struct MarkdownRenderedGroup {
    let span: RenderedSpan
    let spacer: NSRange
}

/// Labels and display separators deliberately have no selectable model span.
struct RenderedTextIndex {
    var strings = ["", ""]
    var paragraphs: [[RenderedSpan]] = [[], []]
    var units: [[RenderedSpan]] = [[], []]
    var blankRanges: [[NSRange]] = [[], []]
    var markdownRuns: [[MarkdownRenderedRun]] = [[], []]
    var markdownBlocks: [[MarkdownRenderedBlock]] = [[], []]
    var markdownGroups: [[MarkdownRenderedGroup]] = [[], []]
    var markdownAlignmentGroups: [[MarkdownRenderedGroup]] = [[], []]
    var generatedSpacers: [[NSRange]] = [[], []]
    private var markdownCounterpartUnits: [Set<UUID>] = [[], []]
    private var markdownRunsByUnit: [[UUID: [MarkdownRenderedRun]]] = [[:], [:]]
    var isMarkdown = false
    let layout: LayoutMode

    init(document: BiparaDocument, layout: LayoutMode, markdown: MarkdownReadingProjection? = nil,
         stackedTables: Set<UUID> = [], columnLabel: String = "Column") {
        self.layout = layout
        if let markdown {
            isMarkdown = true
            for group in markdown.groups {
                var chunks: [[MarkdownReadingBlock]] = []
                for block in group.source {
                    if case .tableCell(let cell) = block.kind,
                       let previous = chunks.last?.last, case .tableCell(let prior) = previous.kind,
                       cell.tableID == prior.tableID {
                        chunks[chunks.count - 1].append(block)
                    } else { chunks.append([block]) }
                }
                let sourceIDs = Set(group.source.map(\.id))
                let matches = group.translation.allSatisfy { sourceIDs.contains($0.id) }
                if layout != .sideBySide || !matches { chunks = [group.source] }
                let starts = markdownGroups.map(\.count)
                for chunk in chunks {
                    let ids = Set(chunk.map(\.id))
                    let translated = layout == .sideBySide && matches ? group.translation.filter { ids.contains($0.id) } : group.translation
                    append(chunk, groupID: group.id, side: .source, column: 0,
                           sourceMode: markdown.isSourceMode, stackedTables: stackedTables, columnLabel: columnLabel)
                    append(translated, groupID: group.id, side: .translation, column: layout == .sideBySide ? 1 : 0,
                           sourceMode: markdown.isSourceMode, stackedTables: stackedTables, columnLabel: columnLabel)
                }
                if layout == .sideBySide {
                    for column in 0...1 {
                        let pieces = Array(markdownGroups[column].dropFirst(starts[column]))
                        markdownAlignmentGroups[column].append(contentsOf: pieces)
                        guard let first = pieces.first, let last = pieces.last else { continue }
                        let hasContent = pieces.contains { $0.span.range.length > 0 }
                        let span = RenderedSpan(paragraphID: group.id, unitID: nil, side: first.span.side,
                                                range: NSRange(location: first.span.range.location,
                                                               length: hasContent ? last.spacer.location - first.span.range.location : 0))
                        markdownGroups[column].replaceSubrange(starts[column]..., with: [.init(span: span, spacer: last.spacer)])
                    }
                }
            }
            return
        }
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
        if isMarkdown { return markdownSelection(column: column, range: range) }
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
        if selection.isSection {
            return markdownGroups[column].first { $0.span.paragraphID == selection.paragraphID && $0.span.side == side && $0.span.range.length > 0 }
                .map { (column, $0.span) }
        }
        let values = selection.unitID == nil ? paragraphs[column] : units[column]
        guard let span = values.first(where: { $0.paragraphID == selection.paragraphID && $0.side == side && $0.unitID == selection.unitID }) else {
            let block = paragraphs[column].first { $0.paragraphID == selection.paragraphID && $0.side == side && $0.range.length > 0 }
            let group = markdownGroups[column].first { $0.span.paragraphID == selection.paragraphID && $0.span.side == side && $0.span.range.length > 0 }?.span
            return (block ?? group).map { (column, $0) }
        }
        return span.range.length > 0 ? (column, span) : nil
    }

    private mutating func append(_ blocks: [MarkdownReadingBlock], groupID: UUID, side: ReadingSide, column: Int,
                                 sourceMode: Bool, stackedTables: Set<UUID>, columnLabel: String) {
        // NSString offsets are accumulated while appending. Repeatedly
        // recounting a whole pane would make large documents quadratic.
        let groupStart = markdownGroups[column].last.map { NSMaxRange($0.spacer) } ?? 0
        var cursor = groupStart
        func makeRange(start: Int) -> NSRange { NSRange(location: start, length: cursor - start) }
        var groupText = ""
        for block in blocks {
            let paragraphStart = cursor
            if !sourceMode {
                var marker = block.marker.map { $0 + "\t" } ?? ""
                if case .tableCell(let cell) = block.kind, stackedTables.contains(cell.tableID) {
                    marker += "\(columnLabel) \(cell.column + 1)  "
                }
                if block.kind == .rule { marker += "────────" }
                groupText += marker
                cursor += marker.utf16.count
            }
            let blockStart = cursor
            var unitSpans: [UUID: NSRange] = [:]
            var unitOrder: [UUID] = []
            for run in block.runs {
                let runStart = cursor
                groupText += run.text
                cursor += run.text.utf16.count
                let range = makeRange(start: runStart)
                guard range.length > 0 else { continue }
                let unitID = run.visibleRange?.length == range.length && !run.style.contains(.code) ? run.unitID : nil
                let span = RenderedSpan(paragraphID: block.id, unitID: unitID, side: side, range: range)
                let renderedRun = MarkdownRenderedRun(run: run, span: span)
                markdownRuns[column].append(renderedRun)
                if let unitID {
                    markdownCounterpartUnits[side == .source ? 0 : 1].insert(unitID)
                    markdownRunsByUnit[column][unitID, default: []].append(renderedRun)
                    if let previous = unitSpans[unitID] { unitSpans[unitID] = NSUnionRange(previous, range) }
                    else { unitSpans[unitID] = range; unitOrder.append(unitID) }
                }
            }
            let span = RenderedSpan(paragraphID: block.id, unitID: nil, side: side, range: makeRange(start: blockStart))
            paragraphs[column].append(span)
            for id in unitOrder {
                if let range = unitSpans[id] {
                    units[column].append(.init(paragraphID: block.id, unitID: id, side: side, range: range))
                }
            }
            if !sourceMode, cursor == paragraphStart || groupText.last?.isNewline != true {
                groupText += "\n"
                cursor += 1
            }
            markdownBlocks[column].append(.init(block: block, span: span, paragraphRange: makeRange(start: paragraphStart)))
        }
        let groupSpan = RenderedSpan(paragraphID: groupID, unitID: nil, side: side, range: makeRange(start: groupStart))
        if sourceMode, !groupText.isEmpty, groupText.last?.isNewline != true {
            // The projection supplies the original delimiters, including
            // adjacent slices within a line. Only the group spacer needs a
            // synthetic separator, which native Copy removes.
            generatedSpacers[column].append(NSRange(location: cursor, length: 1))
            groupText += "\n"
            cursor += 1
        }
        let spacer = NSRange(location: cursor, length: 1)
        groupText += "\n"
        generatedSpacers[column].append(spacer)
        markdownGroups[column].append(.init(span: groupSpan, spacer: spacer))
        strings[column] += groupText
    }

    private func markdownSelection(column: Int, range: NSRange) -> ReadingSelection? {
        let textLength = markdownGroups[column].last.map { NSMaxRange($0.spacer) } ?? 0
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location < textLength, range.length <= textLength - range.location else { return nil }
        let blocks = paragraphs[column]
        let blockIndex = firstIndex(in: blocks) { NSMaxRange($0.range) > range.location }
        guard blocks.indices.contains(blockIndex), NSLocationInRange(range.location, blocks[blockIndex].range) else { return nil }
        let block = blocks[blockIndex]
        let runs = markdownRuns[column]
        let runIndex = firstIndex(in: runs) { NSMaxRange($0.span.range) > range.location }
        let matching = runs[runIndex...].prefix { current in
            current.span.paragraphID == block.paragraphID && current.span.side == block.side &&
            (range.length == 0 ? NSLocationInRange(range.location, current.span.range) : current.span.range.location < NSMaxRange(range))
        }
        let oppositeUnits = markdownCounterpartUnits[block.side == .source ? 1 : 0]
        if let first = matching.first, let id = first.span.unitID, let firstRange = first.run.visibleRange,
           first.span.range.location <= range.location,
           let last = matching.last, NSMaxRange(last.span.range) >= NSMaxRange(range),
           oppositeUnits.contains(id), range.length == 0 ||
            (strings[column] as NSString).rangeOfComposedCharacterSequences(for: range) == range {
            var nextDisplay = first.span.range.location
            var nextLogical = firstRange.location
            let contiguous = matching.allSatisfy { current in
                guard let logical = current.run.visibleRange, current.span.unitID == id,
                      current.span.range.location == nextDisplay, logical.location == nextLogical else { return false }
                nextDisplay = NSMaxRange(current.span.range)
                nextLogical = logical.location + logical.length
                return true
            }
            if contiguous {
                return ReadingSelection(paragraphID: block.paragraphID, unitID: id, side: block.side,
                                        range: .init(location: firstRange.location + range.location - first.span.range.location, length: range.length))
            }
        }
        let group = NSMaxRange(range) > NSMaxRange(block.range)
            ? markdownGroups[column].first { NSLocationInRange(range.location, $0.span.range) }?.span : nil
        let fallback = group ?? block
        return ReadingSelection(paragraphID: fallback.paragraphID, unitID: nil, side: block.side,
                                range: .init(location: range.location - fallback.range.location,
                                             length: min(range.length, NSMaxRange(fallback.range) - range.location)),
                                isSection: group != nil)
    }

    private func firstIndex<Element>(in elements: [Element], where isCandidate: (Element) -> Bool) -> Int {
        var lower = 0
        var upper = elements.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if isCandidate(elements[middle]) { upper = middle }
            else { lower = middle + 1 }
        }
        return lower
    }

    /// Maps logical unit offsets back through display runs, without covering
    /// intervening Markdown syntax or generated display characters.
    func displayRanges(_ selection: ReadingSelection, counterpart: Bool, ranges: [BiparaCore.TextRange]) -> (Int, [NSRange])? {
        guard let (column, span) = span(selection, counterpart: counterpart) else { return nil }
        guard !ranges.isEmpty else { return (column, [span.range]) }
        if !isMarkdown || selection.unitID == nil {
            let translated = ranges.compactMap { range -> NSRange? in
                guard range.isWithin(.init(location: 0, length: span.range.length)) else { return nil }
                return NSRange(location: span.range.location + range.location, length: range.length)
            }
            return translated.isEmpty ? nil : (column, translated)
        }
        guard let unitID = selection.unitID else { return nil }
        let runs = markdownRunsByUnit[column][unitID, default: []].filter { $0.span.side == span.side }
        var results: [NSRange] = []
        for range in ranges {
            guard range.isWellFormed else { return nil }
            let logical = NSRange(location: range.location, length: range.length)
            if range.isEmpty {
                guard let run = runs.first(where: { $0.run.visibleRange.map { range.isWithin($0) } == true }),
                      let unitRange = run.run.visibleRange else { return nil }
                results.append(NSRange(location: run.span.range.location + range.location - unitRange.location, length: 0))
                continue
            }
            var covered = 0
            for run in runs {
                guard let unitRange = run.run.visibleRange else { continue }
                let overlap = NSIntersectionRange(logical, NSRange(location: unitRange.location, length: unitRange.length))
                guard overlap.length > 0 else { continue }
                covered += overlap.length
                results.append(NSRange(location: run.span.range.location + overlap.location - unitRange.location, length: overlap.length))
            }
            guard covered == logical.length else { return nil }
        }
        return results.isEmpty ? nil : (column, results)
    }

    /// Phrase precision may be lost in Source mode or across protected runs.
    /// Keep the logical block highlight while selection mapping stays strict.
    func highlightedRanges(_ selection: ReadingSelection, counterpart: Bool, ranges: [BiparaCore.TextRange]) -> (Int, [NSRange])? {
        if let projected = displayRanges(selection, counterpart: counterpart, ranges: ranges) { return projected }
        var coarse = selection
        coarse.unitID = nil
        guard isMarkdown, let (column, span) = span(coarse, counterpart: counterpart) else { return nil }
        return (column, [span.range])
    }
}
