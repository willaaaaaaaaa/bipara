import AppKit
import BiparaCore

public struct ReadingPresentation: Equatable, Sendable {
    public var anchors: [LayoutMode: ReadingAnchor] = [:]
    public var readerAnchor: ReadingAnchor?
    public init() {}
}

struct RenderedSpan {
    let paragraphID: UUID
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
    var blankRanges: [[NSRange]] = [[], []]
    var markdownRuns: [[MarkdownRenderedRun]] = [[], []]
    var markdownBlocks: [[MarkdownRenderedBlock]] = [[], []]
    var markdownGroups: [[MarkdownRenderedGroup]] = [[], []]
    var markdownAlignmentGroups: [[MarkdownRenderedGroup]] = [[], []]
    var generatedSpacers: [[NSRange]] = [[], []]
    var isMarkdown = false

    init(document: BiparaDocument, layout: LayoutMode, markdown: MarkdownReadingProjection? = nil,
         stackedTables: Set<UUID> = [], columnLabel: String = "Column", translationOnly: Bool = false) {
        if let markdown {
            isMarkdown = true
            if translationOnly && !markdown.showsTranslationReaderContent { return }
            for group in markdown.groups {
                if translationOnly {
                    if !group.translation.isEmpty {
                        append(group.translation, groupID: group.id, side: .translation, column: 0,
                               sourceMode: markdown.isSourceMode, stackedTables: stackedTables, columnLabel: columnLabel)
                    }
                    continue
                }
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
                        let span = RenderedSpan(paragraphID: group.id, side: first.span.side,
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
            if translationOnly {
                guard !blank, let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations,
                    targetLanguage: document.jobSnapshot?.targetLanguage ?? .zh), !assembly.text.isEmpty else { continue }
                if !strings[0].isEmpty { strings[0] += "\n" }
                let start = strings[0].utf16.count
                strings[0] += assembly.text
                paragraphs[0].append(.init(paragraphID: paragraph.id, side: .translation,
                                           range: NSRange(location: start, length: assembly.text.utf16.count)))
                continue
            }
            if layout == .paragraphs,blank {
                for side:ReadingSide in [.source,.translation] {
                    paragraphs[0].append(.init(paragraphID:paragraph.id,side:side,range:NSRange(location:strings[0].utf16.count,length:0)))
                }
                continue
            }
            let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations,
                                                       targetLanguage: document.jobSnapshot?.targetLanguage ?? .zh)
            let sourceStart = strings[0].utf16.count
            strings[0] += source
            paragraphs[0].append(.init(paragraphID: paragraph.id, side: .source,
                                       range: NSRange(location: sourceStart, length: source.utf16.count)))
            let column = layout == .sideBySide ? 1 : 0
            if column == 0 {
                strings[0] += "\n"
            }
            let targetStart = strings[column].utf16.count
            let target = assembly?.text ?? ""
            strings[column] += target
            paragraphs[column].append(.init(paragraphID: paragraph.id, side: .translation,
                                            range: NSRange(location: targetStart, length: target.utf16.count)))
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

    func targetAnchor(nearest anchor: ReadingAnchor, in document: BiparaDocument) -> ReadingAnchor? {
        let ready = Set(paragraphs[0].filter { $0.range.length > 0 }.map(\.paragraphID))
        guard !ready.isEmpty else { return nil }
        let ordered = document.paragraphs.map(\.id)
        let incoming = ordered.firstIndex(of: anchor.paragraphID) ?? 0
        let nearest = ordered.indices.filter { ready.contains(ordered[$0]) }.min { abs($0 - incoming) < abs($1 - incoming) }
        guard let nearest else { return nil }
        let id = ordered[nearest], same = id == anchor.paragraphID
        return ReadingAnchor(paragraphID: id, side: .translation, fraction: same ? anchor.fraction : 0,
                             offset: same && anchor.side == .translation ? anchor.offset : nil,
                             sectionID: same ? anchor.sectionID : nil)
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
            for run in block.runs {
                let runStart = cursor
                groupText += run.text
                cursor += run.text.utf16.count
                let range = makeRange(start: runStart)
                guard range.length > 0 else { continue }
                let span = RenderedSpan(paragraphID: block.id, side: side, range: range)
                let renderedRun = MarkdownRenderedRun(run: run, span: span)
                markdownRuns[column].append(renderedRun)
            }
            let span = RenderedSpan(paragraphID: block.id, side: side, range: makeRange(start: blockStart))
            paragraphs[column].append(span)
            if !sourceMode, cursor == paragraphStart || groupText.last?.isNewline != true {
                groupText += "\n"
                cursor += 1
            }
            markdownBlocks[column].append(.init(block: block, span: span, paragraphRange: makeRange(start: paragraphStart)))
        }
        let groupSpan = RenderedSpan(paragraphID: groupID, side: side, range: makeRange(start: groupStart))
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
}
