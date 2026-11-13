import AppKit
import BiparaCore
@testable import BiparaAppKit
import Testing

@MainActor @Suite("Native Markdown reader")
struct MarkdownNativeReaderTests {
    @Test func sourceProjectionKeepsListPrefixesWithTheirBlocks() throws {
        let source = "# Guide\r\n\r\n- First item\r\n- Second item\r\n  - Nested item\r\n\r\n> First quote\r\n>\r\n> Second quote"
        var document = try WorkspaceStore.prepareDocument(source: source, direction: .enToZh, format: .markdown).document
        document.readingMode = .source
        let projection = try #require(document.markdownProjection())
        let index = RenderedTextIndex(document: document, layout: .sideBySide, markdown: projection)
        #expect(index.strings[0].contains("- Second item"))
        #expect(index.strings[0].contains("  - Nested item"))
        #expect(index.strings[0].contains("> Second quote"))
        for block in projection.groups.flatMap(\.source) {
            #expect(!block.runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-"))
        }
    }

    private func nativeReader(width: CGFloat = 1000) -> (ParallelReader, NSWindow) {
        _ = NSApplication.shared
        let reader = ParallelReader()
        let frame = NSRect(x: 0, y: 0, width: width, height: 550)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader
        reader.frame = frame
        return (reader, window)
    }

    private func surface(_ document: BiparaDocument, session: UUID, markdown: MarkdownReadingProjection?,
                         layout: LayoutMode = .sideBySide, presentation: ReadingPresentation = .init(),
                         typography: ReadingTypography = .init(), onAnchor: @escaping (ReadingAnchor) -> Void = { _ in }) -> NativeReadingSurface {
        NativeReadingSurface(sessionID: session, document: document, layout: layout, typography: typography,
                             presentation: presentation, language: .english, markdown: markdown,
                             onSelect: { _ in }, onHover: { _ in }, onAnchor: onAnchor)
    }

    private func views(_ reader: ParallelReader) -> [NSTextView] {
        reader.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }
    }

    private func glyphRect(_ query: String, in text: NSTextView) throws -> NSRect {
        let range = (text.string as NSString).range(of: query, options: .literal)
        try #require(range.location != NSNotFound)
        try #require(text.textLayoutManager == nil)
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    @Test func markdownTableLaysOutRealColumnsAndAlignsFollowingSection() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "A plain fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let (reader, window) = nativeReader()
        defer { window.close() }
        let section = UUID()
        let tableID = UUID()
        let next = UUID()
        let source = ["Header A", "Header B", "Cell A", String(repeating: "A longer cell needs more than one line. ", count: 12)]
        let target = ["标题甲", "标题乙", "单元甲", "单元乙"]
        let ids = source.map { _ in UUID() }
        func table(_ strings: [String]) -> [MarkdownReadingBlock] {
            strings.enumerated().map { i, text in
                .init(id: ids[i], kind: .tableCell(.init(tableID: tableID, row: i / 2, column: i % 2, columnCount: 2, header: i < 2)),
                      runs: [.init(text)])
            }
        }
        let markdown = MarkdownReadingProjection(groups: [
            .init(id: section, source: table(source), translation: table(target)),
            .init(id: next, source: [.init(id: next, kind: .heading(level: 2), runs: [.init("Next heading")])],
                  translation: [.init(id: next, kind: .heading(level: 2), runs: [.init("下一个章节")])])
        ])
        let session = UUID()
        reader.update(surface(document, session: session, markdown: markdown))
        let text = views(reader)
        let first = try glyphRect("Header A", in: text[0])
        let second = try glyphRect("Header B", in: text[0])
        #expect(second.minX > first.maxX)
        #expect(abs(first.minY - second.minY) < 0.5)
        let nextSource = try glyphRect("Next heading", in: text[0])
        let nextTarget = try glyphRect("下一个章节", in: text[1])
        #expect(abs(nextSource.minY - nextTarget.minY) < 1)
        let hit = text[0].characterIndexForInsertion(at: NSPoint(x: second.midX, y: second.midY))
        let headerRange = (text[0].string as NSString).range(of: "Header B")
        #expect(hit >= headerRange.location && hit <= NSMaxRange(headerRange))
        reader.update(surface(document, session: UUID(), markdown: nil))
        #expect(views(reader).allSatisfy { $0.textLayoutManager != nil })
        #expect(views(reader)[0].string == document.source)
    }

    @Test func wideTableStacksCellsAtLargeReadingSize() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "A plain fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let (reader, window) = nativeReader(width: 800)
        defer { window.close() }
        let tableID = UUID()
        let source = (0..<8).map { i in
            MarkdownReadingBlock(id: UUID(), kind: .tableCell(.init(tableID: tableID, row: 0, column: i, columnCount: 8, header: true)),
                                 runs: [.init("Heading \(i + 1)")])
        }
        let projection = MarkdownReadingProjection(groups: [.init(id: UUID(), source: source, translation: [])])
        var typography = ReadingTypography()
        typography.size = 28
        reader.update(surface(document, session: UUID(), markdown: projection, typography: typography))
        let text = views(reader)[0]
        #expect(text.string.contains("Column 1"))
        #expect(text.string.contains("Column 8"))
        #expect((try glyphRect("Heading 8", in: text)).minY > (try glyphRect("Heading 1", in: text)).minY)
        #expect(text.textStorage?.length == text.string.utf16.count)
    }

    @Test func missingFirstSectionStillAlignsSubsequentCompletedHeading() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "Fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let (reader, window) = nativeReader()
        defer { window.close() }
        let first = UUID()
        let second = UUID()
        let projection = MarkdownReadingProjection(groups: [
            .init(id: first, source: [.init(id: first, kind: .heading(level: 1), runs: [.init("First heading")])], translation: []),
            .init(id: second, source: [.init(id: second, kind: .heading(level: 2), runs: [.init("Second heading")])],
                  translation: [.init(id: second, kind: .heading(level: 2), runs: [.init("第二章节")])])
        ])
        reader.update(surface(document, session: UUID(), markdown: projection))
        let text = views(reader)
        #expect(abs((try glyphRect("Second heading", in: text[0])).minY - (try glyphRect("第二章节", in: text[1])).minY) < 1)
    }

    @Test func selectionAcrossStylesReprojectsAndRawSyntaxFallsBack() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "A plain fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let groupID = UUID()
        let blockID = UUID()
        let unit = UUID()
        let source = MarkdownReadingBlock(id: blockID, runs: [
            .init("Go ", unitID: unit, visibleRange: .init(location: 0, length: 3)),
            .init("café", style: .bold, unitID: unit, visibleRange: .init(location: 3, length: 4)),
            .init(" 👩🏻‍💻", unitID: unit, visibleRange: .init(location: 7, length: " 👩🏻‍💻".utf16.count))
        ])
        let target = MarkdownReadingBlock(id: blockID, runs: [
            .init("去", unitID: unit, visibleRange: .init(location: 0, length: 1)),
            .init("咖啡馆", style: .bold, unitID: unit, visibleRange: .init(location: 1, length: 3))
        ])
        let rendered = MarkdownReadingProjection(groups: [.init(id: groupID, source: [source], translation: [target])])
        let index = RenderedTextIndex(document: document, layout: .sideBySide, markdown: rendered)
        let nativeRange = (index.strings[0] as NSString).range(of: "o café 👩🏻‍💻", options: .literal)
        let selection = try #require(index.selection(column: 0, range: nativeRange))
        #expect(selection.unitID == unit)
        #expect(selection.range.location == 1)
        #expect(selection.range.length == nativeRange.length)
        let (column, ranges) = try #require(index.displayRanges(selection, counterpart: true, ranges: [.init(location: 0, length: 4)]))
        #expect(column == 1)
        #expect(ranges.map { (index.strings[1] as NSString).substring(with: $0) }.joined() == "去咖啡馆")

        let rawSource = MarkdownReadingBlock(id: blockID, runs: [
            .init("Go ", unitID: unit, visibleRange: .init(location: 0, length: 3)),
            .init("**"),
            .init("café", unitID: unit, visibleRange: .init(location: 3, length: 4)),
            .init("**"),
            .init(" 👩🏻‍💻", unitID: unit, visibleRange: .init(location: 7, length: " 👩🏻‍💻".utf16.count))
        ])
        let raw = MarkdownReadingProjection(groups: [.init(id: groupID, source: [rawSource], translation: [target])], isSourceMode: true)
        let rawIndex = RenderedTextIndex(document: document, layout: .paragraphs, markdown: raw)
        let rawRange = (rawIndex.strings[0] as NSString).range(of: "o **café**", options: .literal)
        let fallback = try #require(rawIndex.selection(column: 0, range: rawRange))
        #expect(fallback.unitID == nil)
        #expect(fallback.paragraphID == blockID)
        let (_, splitRanges) = try #require(rawIndex.displayRanges(selection, counterpart: false, ranges: [selection.range]))
        #expect(splitRanges.map { (rawIndex.strings[0] as NSString).substring(with: $0) }.joined() == "o café 👩🏻‍💻")
    }

    @Test func sourceProjectionKeepsAdjacentTableSlicesOnOneLine() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "Fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let source = ["| Name |", " Value |\r\n| --- | --- |\r\n", "| One |", " Two |"]
        let tableID = UUID()
        let blocks = source.enumerated().map { i, value in
            MarkdownReadingBlock(id: UUID(), kind: .tableCell(.init(tableID: tableID, row: i / 2, column: i % 2, columnCount: 2, header: i < 2)), runs: [.init(value)])
        }
        let projection = MarkdownReadingProjection(groups: [
            .init(id: UUID(), source: blocks, translation: blocks)
        ], isSourceMode: true)
        let index = RenderedTextIndex(document: document, layout: .sideBySide, markdown: projection)
        #expect(TextIdentity.equal(index.strings[0], source.joined() + "\n\n"))
        #expect(index.generatedSpacers[0] == [
            NSRange(location: source.joined().utf16.count, length: 1),
            NSRange(location: source.joined().utf16.count + 1, length: 1)
        ])
        #expect(index.markdownBlocks[0][1].span.range.location == source[0].utf16.count)
    }

    @Test func crossBlockSelectionWithSharedHeadingIdentityHighlightsWholeGroup() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "Fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let heading = UUID()
        let body = UUID()
        let projection = MarkdownReadingProjection(groups: [
            .init(id: heading, source: [
                .init(id: heading, kind: .heading(level: 1), runs: [.init("Heading")]),
                .init(id: body, runs: [.init("Body")])
            ], translation: [
                .init(id: heading, kind: .heading(level: 1), runs: [.init("标题")]),
                .init(id: body, runs: [.init("正文")])
            ])
        ])
        let index = RenderedTextIndex(document: document, layout: .sideBySide, markdown: projection)
        let range = (index.strings[0] as NSString).range(of: "Heading\n\nBody")
        let selection = try #require(index.selection(column: 0, range: range))
        #expect(selection.isSection)
        let (_, highlights) = try #require(index.highlightedRanges(selection, counterpart: true, ranges: []))
        #expect(highlights.map { (index.strings[1] as NSString).substring(with: $0) }.joined() == "标题\n\n正文\n")
        #expect(index.selection(column: 0, range: NSRange(location: 0, length: 10_000)) == nil)
    }

    @Test func emptySectionsAndUnmatchedFallbackKeepTheirMeaning() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "Fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let section = UUID()
        let source = [MarkdownReadingBlock(id: section, runs: [.init("First")]), .init(id: UUID(), runs: [.init("Second")])]
        let empty = RenderedTextIndex(document: document, layout: .sideBySide,
            markdown: .init(groups: [.init(id: section, source: source, translation: [])]))
        #expect(empty.markdownGroups[1].first?.span.range.length == 0)
        #expect(empty.span(.init(paragraphID: section, unitID: nil, side: .source, range: .init(location: 0, length: 5), isSection: true), counterpart: true) == nil)
        let fallback = RenderedTextIndex(document: document, layout: .sideBySide,
            markdown: .init(groups: [.init(id: section, source: source, translation: [.init(id: UUID(), runs: [.init("Saved translation")])])], isSourceMode: true))
        #expect(fallback.strings[1].contains("Saved translation"))
    }

    @Test(arguments: [false, true])
    func longBilingualSectionsAlignBlocksAndScrollTogether(sourceMode: Bool) throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "Fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let (reader, window) = nativeReader()
        defer { window.close() }
        var sourceQueries: [String] = []
        var targetQueries: [String] = []
        let groups = (0..<5).map { section -> MarkdownReadingGroup in
            let heading = UUID()
            var source: [MarkdownReadingBlock] = []
            var target: [MarkdownReadingBlock] = []
            for row in 0..<9 {
                let id = row == 0 ? heading : UUID()
                let a = "Section \(section) block \(row)"
                let b = "章节\(section)段落\(row)"
                sourceQueries.append(a); targetQueries.append(b)
                let kind: MarkdownReadingBlockKind = row == 0 ? .heading(level: 2) : .paragraph
                let prefix = sourceMode && row == 0 ? "## " : ""
                source.append(.init(id: id, kind: kind, runs: [.init(prefix + a + (row == 0 ? "" : String(repeating: " English sentences occupy several lines.", count: 4 + row % 3)) + "\n\n")]))
                target.append(.init(id: id, kind: kind, runs: [.init(prefix + b + (row == 0 ? "" : String(repeating: "中文段落长度不同，需要保持对应关系。", count: row % 3 == 0 ? 12 : 2)) + "\n\n")]))
            }
            return .init(id: heading, source: source, translation: target)
        }
        let projection = MarkdownReadingProjection(groups: groups, isSourceMode: sourceMode)
        let session = UUID()
        reader.update(surface(document, session: session, markdown: projection))
        let text = views(reader)
        for (a, b) in zip(sourceQueries, targetQueries) {
            #expect(abs((try glyphRect(a, in: text[0])).minY - (try glyphRect(b, in: text[1])).minY) < 1)
        }
        #expect(abs(text[0].frame.height - text[1].frame.height) < 1)
        let scrolls = reader.subviews.compactMap { $0 as? NSScrollView }
        let bottom = text[0].frame.height - scrolls[0].contentSize.height
        for column in 0...1 {
            for step in 0...100 {
                let y = bottom * CGFloat(column == 0 ? step : 100 - step) / 100
                scrolls[column].contentView.scroll(to: NSPoint(x: 0, y: y))
                NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrolls[column].contentView)
                #expect(abs(scrolls[0].contentView.bounds.minY - scrolls[1].contentView.bounds.minY) < 1)
            }
        }
        scrolls[1].contentView.scroll(to: NSPoint(x: 0, y: bottom / 2))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrolls[1].contentView)
        var presentation = ReadingPresentation()
        presentation.selection = .init(paragraphID: groups[0].source[0].id, unitID: nil, side: .source, range: .init(location: 0, length: 7))
        presentation.revealGeneration = 1
        reader.update(surface(document, session: session, markdown: projection, presentation: presentation))
        #expect(abs(scrolls[0].contentView.bounds.minY - scrolls[1].contentView.bounds.minY) < 1)
        scrolls[1].contentView.scroll(to: NSPoint(x: 0, y: bottom / 2))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrolls[1].contentView)
        // Reflow and mode changes restore one logical position for both panes.
        let toggled = MarkdownReadingProjection(groups: groups, isSourceMode: !sourceMode)
        reader.update(surface(document, session: session, markdown: toggled))
        #expect(scrolls[0].contentView.bounds.minY > 0)
        #expect(abs(scrolls[0].contentView.bounds.minY - scrolls[1].contentView.bounds.minY) < 1)
        let first = try glyphRect(sourceQueries[1], in: text[0])
        let other = try glyphRect(targetQueries[1], in: text[1])
        #expect(abs(first.minY - other.minY) < 1)
    }

    @Test func protectedInlineCodeKeepsCoarseCounterpartHighlight() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "Fixture.", direction: .enToZh)
        let document = try #require(workspace.activeTab?.document)
        let block = UUID()
        let unit = UUID()
        let source = MarkdownReadingBlock(id: block, runs: [
            .init("Use ", unitID: unit, visibleRange: .init(location: 0, length: 4)),
            .init("git", style: .code, unitID: unit, visibleRange: .init(location: 4, length: 3))
        ])
        let target = MarkdownReadingBlock(id: block, runs: [
            .init("用", unitID: unit, visibleRange: .init(location: 0, length: 1)),
            .init("git", style: .code, unitID: unit, visibleRange: .init(location: 1, length: 3))
        ])
        let index = RenderedTextIndex(document: document, layout: .sideBySide,
                                      markdown: .init(groups: [.init(id: block, source: [source], translation: [target])]))
        let range = NSRange(location: 0, length: 3)
        let selection = try #require(index.selection(column: 0, range: range))
        #expect(selection.unitID == unit)
        let unresolved = BiparaCore.TextRange(location: 0, length: 4)
        #expect(index.displayRanges(selection, counterpart: true, ranges: [unresolved]) == nil)
        let (_, highlights) = try #require(index.highlightedRanges(selection, counterpart: true, ranges: [unresolved]))
        #expect(highlights.map { (index.strings[1] as NSString).substring(with: $0) }.joined() == "用git")
        #expect(index.selection(column: 0, range: NSRange(location: 4, length: 3))?.unitID == nil)
    }
}
