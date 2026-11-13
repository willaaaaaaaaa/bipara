import AppKit
import BiparaCore

/// Converts an immutable reading projection into TextKit attributes.
/// Layout and selection remain in the existing native reading surface.
@MainActor
enum MarkdownReaderStyles {
    static func stackedTableIDs(in projection: MarkdownReadingProjection, width: CGFloat, fontSize: CGFloat) -> Set<UUID> {
        guard !projection.isSourceMode else { return [] }
        let minimumColumnWidth = max(56, fontSize * 3)
        var stacked: Set<UUID> = []
        for group in projection.groups {
            for blocks in [group.source, group.translation] {
                for block in blocks {
                    if case .tableCell(let cell) = block.kind, CGFloat(cell.columnCount) * minimumColumnWidth > width {
                        stacked.insert(cell.tableID)
                    }
                }
            }
        }
        return stacked
    }

    static func attributed(index: RenderedTextIndex, column: Int, sourceMode: Bool, font: NSFont,
                           baseStyle: NSParagraphStyle, width: CGFloat, stackedTables: Set<UUID>) -> NSMutableAttributedString {
        let bodyFont = font
        let text = NSMutableAttributedString(string: index.strings[column], attributes: [
            .font: bodyFont,
            .foregroundColor: ThemeColors.source,
            .paragraphStyle: baseStyle,
            .ligature: 0
        ])
        let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        var tables: [UUID: NSTextTable] = [:]
        // A pane in Sections mode contains both sides of the same source table.
        for side in [ReadingSide.source, .translation] {
            tables.removeAll(keepingCapacity: true)
            for block in index.markdownBlocks[column] where block.span.side == side {
                let foreground = side == .source ? ThemeColors.source : ThemeColors.translation
                let style = baseStyle.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacing = sourceMode ? 0 : 9
                var blockFont = bodyFont
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: foreground]
                if !sourceMode {
                    let maxDepth = max(0, Int((width - max(font.pointSize * 4, 60)) / 18))
                    let depth = min(maxDepth, max(0, block.block.listDepth) + max(0, block.block.quoteDepth))
                    let inset = CGFloat(depth) * 18
                    style.headIndent = inset
                    style.firstLineHeadIndent = inset
                    if let marker = block.block.marker, !marker.isEmpty {
                        let markerWidth = ceil((marker as NSString).size(withAttributes: [.font: bodyFont]).width)
                        let labelWidth = min(max(1, width - inset), max(20, markerWidth + 8))
                        style.headIndent += labelWidth
                        style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                        style.paragraphSpacing = 4
                    }
                    if block.block.quoteDepth > 0 { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
                    switch block.block.kind {
                    case .heading(let level):
                        let scales: [CGFloat] = [1.55, 1.35, 1.22, 1.12, 1.05, 1]
                        blockFont = NSFontManager.shared.convert(font, toSize: font.pointSize * scales[min(5, max(0, level - 1))])
                        blockFont = NSFontManager.shared.convert(blockFont, toHaveTrait: .boldFontMask)
                        style.paragraphSpacingBefore = 10
                        style.paragraphSpacing = 10
                    case .code:
                        blockFont = ReadingTextStyle.monospacedFont(size: font.pointSize)
                        style.lineBreakMode = .byCharWrapping
                        attributes[.backgroundColor] = codeBackground
                    case .literal:
                        style.lineBreakMode = .byWordWrapping
                        style.paragraphSpacing = 0
                    case .rule:
                        attributes[.foregroundColor] = NSColor.secondaryLabelColor
                    case .tableCell(let cell):
                        style.paragraphSpacing = 0
                        style.lineBreakMode = .byCharWrapping
                        if cell.header { blockFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                        if stackedTables.contains(cell.tableID) {
                            style.paragraphSpacing = cell.column + 1 == cell.columnCount ? 10 : 2
                        } else {
                            style.alignment = switch cell.alignment {
                            case .leading: .left
                            case .center: .center
                            case .trailing: .right
                            }
                            let table: NSTextTable
                            if let existing = tables[cell.tableID] { table = existing }
                            else {
                                table = NSTextTable()
                                table.numberOfColumns = cell.columnCount
                                table.layoutAlgorithm = .fixed
                                table.collapsesBorders = true
                                tables[cell.tableID] = table
                            }
                            let cellBlock = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: 1,
                                                            startingColumn: cell.column, columnSpan: 1)
                            cellBlock.setValue(100 / CGFloat(cell.columnCount), type: .percentageValueType, for: .width)
                            cellBlock.setWidth(3, type: .absoluteValueType, for: .padding)
                            cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                            cellBlock.setBorderColor(.separatorColor)
                            if cell.header { cellBlock.backgroundColor = .quaternaryLabelColor.withAlphaComponent(0.12) }
                            style.textBlocks = [cellBlock]
                            style.firstLineHeadIndent = 0
                            style.headIndent = 0
                        }
                    case .paragraph:
                        break
                    }
                }
                // Use the same baseline grid for Latin and CJK fallback fonts.
                style.minimumLineHeight = ceil(blockFont.pointSize * baseStyle.minimumLineHeight / font.pointSize)
                style.maximumLineHeight = style.minimumLineHeight
                style.lineHeightMultiple = 1
                attributes[.font] = blockFont
                attributes[.paragraphStyle] = style
                text.addAttributes(attributes, range: block.paragraphRange)
            }
        }
        if !sourceMode {
            for value in index.markdownRuns[column] {
                let run = value.run
                let range = value.span.range
                guard let current = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { continue }
                var runFont = current
                if run.style.contains(.code) {
                    runFont = ReadingTextStyle.monospacedFont(size: current.pointSize)
                    text.addAttribute(.backgroundColor, value: codeBackground, range: range)
                }
                if run.style.contains(.bold) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if run.style.contains(.italic) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                text.addAttribute(.font, value: runFont, range: range)
                if run.style.contains(.strikethrough) {
                    text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
                if run.destination != nil || run.linkTargetBlockID != nil {
                    // No .link attribute: clicking should retain native selection.
                    text.addAttributes([.foregroundColor: NSColor.linkColor,
                                        .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                }
            }
        }
        for spacer in index.generatedSpacers[column] {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = font.pointSize * 0.7
            style.maximumLineHeight = style.minimumLineHeight
            style.paragraphSpacing = 6
            text.addAttribute(.paragraphStyle, value: style, range: spacer)
        }
        return text
    }
}
