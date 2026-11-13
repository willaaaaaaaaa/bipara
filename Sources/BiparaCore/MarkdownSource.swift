import Foundation
import Markdown
import cmark_gfm
import cmark_gfm_extensions

struct MarkdownCoordinates {
    let text: String
    private let starts: [Int]
    private let offsets: [Int]

    init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        var starts = [0]
        for index in bytes.indices {
            if bytes[index] == 10 || (bytes[index] == 13 && (index + 1 == bytes.count || bytes[index + 1] != 10)) {
                starts.append(index + 1)
            }
        }
        self.starts = starts
        var offsets = Array(repeating: -1, count: bytes.count + 1)
        var byte = 0
        var utf16 = 0
        for scalar in text.unicodeScalars {
            offsets[byte] = utf16
            byte += scalar.utf8.count
            utf16 += scalar.utf16.count
        }
        offsets[byte] = utf16
        self.offsets = offsets
    }

    private func offset(_ location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= starts.count, location.column > 0 else { return nil }
        let line = location.line - 1
        let byte = starts[line] + location.column - 1
        let end = line + 1 < starts.count ? starts[line + 1] : offsets.count - 1
        guard byte <= end, offsets[byte] >= 0 else { return nil }
        return offsets[byte]
    }

    func range(_ range: SourceRange?) -> TextRange? {
        guard let range, let start = offset(range.lowerBound), let end = offset(range.upperBound),
              end >= start else { return nil }
        let result = TextRange(location: start, length: end - start)
        return text.hasValidRange(result) ? result : nil
    }

    func text(_ range: SourceRange?) -> String? { self.range(range).flatMap { text.substring(utf16: $0) } }
}

struct MarkdownSource {
    enum Limit: Error { case structure }
    private static let extensionsReady: Void = cmark_gfm_core_extensions_ensure_registered()

    /// The tagged Swift adapter converts recursively. Bound the same C tree
    /// iteratively before allowing Swift conversion, including candidate output.
    static func parse(_ source: String) throws -> Document {
        try parseTree(source, captureReferences: false).0
    }

    private static func parseTree(_ source: String, captureReferences: Bool) throws -> (Document, MarkdownReferences) {
        _ = extensionsReady
        let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS | CMARK_OPT_SOURCEPOS)!
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        let parsed: (root: UnsafeMutablePointer<cmark_node>?, references: MarkdownReferences)
        if captureReferences {
            parsed = MarkdownReferences.finish(parser)
        } else {
            parsed = (cmark_parser_finish(parser), .empty)
            cmark_parser_free(parser)
        }
        guard let root = parsed.root else { throw MarkdownPlan.invalidPlan }
        defer { cmark_node_free(root) }
        var nodes = [(root, 0)]
        var count = 0
        while let (node, depth) = nodes.popLast() {
            count += 1
            guard count <= 100_000, depth <= 128 else {
                throw Limit.structure
            }
            if let next = cmark_node_next(node) { nodes.append((next, depth)) }
            if let child = cmark_node_first_child(node) { nodes.append((child, depth + 1)) }
        }
        return (Document(parsing: source, options: [.disableSmartOpts]), parsed.references)
    }

    let source: String
    let coordinates: MarkdownCoordinates
    let roots: [any Markup]
    let frontmatter: TextRange?
    let references: MarkdownReferences
    let detectsMarkdown: Bool
    let syntax: [String]

    init(_ source: String, translated: Bool = false) throws {
        self.source = source
        coordinates = MarkdownCoordinates(source)
        let metadata = Self.metadata(source)
        frontmatter = metadata
        // Keep source line numbers and UTF-16 offsets after masking metadata.
        var parsed = source
        if let metadata, let end = metadata.end, let stop = source.utf16Index(at: end) {
            let mask = source[..<stop].unicodeScalars.map { scalar in
                scalar.value == 10 || scalar.value == 13 ? String(scalar) : String(repeating: " ", count: scalar.utf16.count)
            }.joined()
            parsed = mask + source[stop...]
        }
        let (root, captured) = try Self.parseTree(parsed, captureReferences: !translated)
        roots = Array(root.children)
        references = captured
        var signs: [String] = []
        if metadata != nil { signs.append("metadata") }
        for node in roots { Self.appendSyntax(node, into: &signs) }
        syntax = signs
        detectsMarkdown = translated ? true : Self.detect(roots, coordinates: coordinates)
    }

    private static func metadata(_ source: String) -> TextRange? {
        guard source.hasPrefix("---") else { return nil }
        var offset = 0
        var first = true
        var start = source.startIndex
        while start < source.endIndex {
            let stop = source[start...].firstIndex(where: \.isNewline) ?? source.endIndex
            let end = stop < source.endIndex ? source.index(after: stop) : stop
            let line = source[start..<stop].trimmingCharacters(in: .whitespaces)
            offset += source[start..<end].utf16.count
            if first {
                guard line == "---" else { return nil }
                first = false
            } else if line == "---" || line == "..." {
                return .init(location: 0, length: offset)
            }
            start = end
        }
        return nil
    }

    private static func appendSyntax(_ node: any Markup, into signature: inout [String]) {
        switch node {
        case let heading as Heading: signature.append("heading:\(heading.level)"); return
        case is Paragraph: signature.append("paragraph"); return
        case is Table.Cell: signature.append("cell"); return
        case let code as CodeBlock: signature.append("code:\(code.language ?? ""):\(code.code)"); return
        case let html as HTMLBlock: signature.append("html:\(html.rawHTML)"); return
        case let list as OrderedList: signature.append("ordered:\(list.startIndex)")
        case let item as ListItem: signature.append("item:\(String(describing: item.checkbox))")
        case let table as Table: signature.append("table:\(table.columnAlignments)")
        default: signature.append(String(describing: type(of: node)))
        }
        for child in node.children { appendSyntax(child, into: &signature) }
        signature.append("/")
    }

    private static func detect(_ nodes: [any Markup], coordinates: MarkdownCoordinates) -> Bool {
        let substantive = nodes.filter { !($0 is HTMLBlock || $0 is ThematicBreak) }
        if substantive.count >= 2, substantive.contains(where: { $0 is Heading }) { return true }
        var stack = nodes
        var list = false
        var quote = false
        var inline = 0
        var link = false
        while let node = stack.popLast() {
            switch node {
            case let code as CodeBlock:
                if !code.code.isWhitespaceOnly, !code.code.isEmpty, let raw = coordinates.text(code.range) {
                    let lines = raw.split(whereSeparator: \.isNewline)
                    if let first = lines.first, let last = lines.last, lines.count >= 3 {
                        let open = first.drop(while: \.isWhitespace)
                        let close = last.trimmingCharacters(in: .whitespaces)
                        if let marker = open.first, marker == "`" || marker == "~",
                           close.count >= open.prefix(while: { $0 == marker }).count,
                           close.count >= 3, close.allSatisfy({ $0 == marker }) { return true }
                    }
                }
                continue
            case is HTMLBlock: continue
            case let table as Table:
                if table.columnAlignments.count >= 2, table.body.childCount > 0 { return true }
            case let items as any ListItemContainer:
                list = list || items.children.filter { $0.childCount > 0 }.count >= 2
            case is BlockQuote:
                if let range = node.range { quote = quote || range.upperBound.line > range.lowerBound.line }
            case is Strong, is Emphasis, is Strikethrough, is InlineCode: inline += 1
            case let value as Link:
                if let raw = coordinates.text(value.range), raw.hasPrefix("[") { link = true }
            case is Image: link = true
            default: break
            }
            stack.append(contentsOf: node.children)
        }
        return [list, quote, link || inline >= 2].filter { $0 }.count >= 2
    }

    func plan(version: String) throws -> MarkdownPlan {
        var tops: [MarkdownPlan.Top] = []
        var cursor = 0
        if let frontmatter, let text = source.substring(utf16: frontmatter) {
            let blocks: [MarkdownPlan.Block] = version == "markdown-plan.v1"
                ? [.init(kind: .literal, range: frontmatter, literal: text)]
                : MarkdownMetadata.blocks(text, range: frontmatter)
            tops.append(.init(range: frontmatter, blocks: blocks, startsSection: false, isMetadata: true))
            cursor = frontmatter.end ?? 0
        }
        for node in roots {
            guard let range = coordinates.range(node.range), let end = range.end else { throw MarkdownPlan.invalidPlan }
            appendGap(from: cursor, to: range.location, in: &tops)
            var blocks = try blocks(node)
            if blocks.isEmpty, let raw = source.substring(utf16: range) {
                blocks = [.init(kind: .literal, range: range, literal: raw)]
            }
            tops.append(.init(range: range, blocks: blocks, startsSection: node is Heading))
            cursor = end
        }
        appendGap(from: cursor, to: source.utf16.count, in: &tops)
        if let first = tops.first, first.range.location > 0 {
            tops[0].range = .init(location: 0, length: first.range.end ?? first.range.length)
        }
        return try MarkdownPlan.create(source: source, tops: tops, references: references, syntax: syntax, version: version)
    }

    private func appendGap(from: Int, to: Int, in tops: inout [MarkdownPlan.Top]) {
        guard to > from else { return }
        let range = TextRange(location: from, length: to - from)
        guard let raw = source.substring(utf16: range) else { return }
        let trailingHeading = tops.last?.startsSection == true
            && raw.range(of: #"^[ \t]+#+[ \t]*(?:[\r\n][ \t\r\n]*)?$"#, options: .regularExpression) != nil
        if raw.isWhitespaceOnly || trailingHeading {
            if let last = tops.indices.last {
                tops[last].range.length += range.length
            }
            return
        }
        tops.append(.init(range: range, blocks: [.init(kind: .literal, range: range, literal: raw)], startsSection: false))
    }

    private func blocks(_ node: any Markup, listDepth: Int = 0, quoteDepth: Int = 0, marker: String? = nil) throws -> [MarkdownPlan.Block] {
        let range = coordinates.range(node.range)
        if let table = node as? Table, let range {
            let id = UUID()
            let rows = [Array(table.head.children)] + table.body.children.map { Array($0.children) }
            let alignments = table.columnAlignments
            return try rows.enumerated().flatMap { row, cells in
                try cells.enumerated().map { column, cell in
                    let alignment: MarkdownReadingCell.Alignment = switch alignments.indices.contains(column) ? alignments[column] : nil {
                    case .center: .center
                    case .right: .trailing
                    default: .leading
                    }
                    let kind = MarkdownReadingBlockKind.tableCell(.init(tableID: id, row: row, column: column, columnCount: alignments.count, alignment: alignment, header: row == 0))
                    return try inlineBlock(cell, range: coordinates.range(cell.range) ?? .init(location: range.end ?? range.location, length: 0),
                                           kind: kind, listDepth: listDepth, quoteDepth: quoteDepth, marker: nil)
                }
            }
        }
        if let list = node as? any ListItemContainer {
            let start = (node as? OrderedList)?.startIndex
            return try list.children.enumerated().flatMap { index, child in
                let label: String
                switch (child as? ListItem)?.checkbox {
                case .checked: label = "☑"
                case .unchecked: label = "☐"
                case nil: label = start.map { "\($0 + UInt(index))." } ?? "•"
                }
                return try child.children.enumerated().flatMap { childIndex, block in
                    try blocks(block, listDepth: listDepth + 1, quoteDepth: quoteDepth, marker: childIndex == 0 ? label : nil)
                }
            }
        }
        if node is BlockQuote {
            return try node.children.enumerated().flatMap { index, child in
                try blocks(child, listDepth: listDepth, quoteDepth: quoteDepth + 1, marker: index == 0 ? marker : nil)
            }
        }
        guard let range else { throw MarkdownPlan.invalidPlan }
        if let heading = node as? Heading {
            return [try inlineBlock(node, range: range, kind: .heading(level: heading.level), listDepth: listDepth, quoteDepth: quoteDepth, marker: marker)]
        }
        if node is Paragraph {
            return [try inlineBlock(node, range: range, kind: .paragraph, listDepth: listDepth, quoteDepth: quoteDepth, marker: marker)]
        }
        let kind: MarkdownReadingBlockKind = node is CodeBlock ? .code : node is ThematicBreak ? .rule : .literal
        let literal = (node as? CodeBlock)?.code ?? source.substring(utf16: range)
        return [.init(kind: kind, range: range, listDepth: listDepth, quoteDepth: quoteDepth, marker: marker, literal: literal)]
    }

    private func inlineBlock(_ node: any Markup, range: TextRange, kind: MarkdownReadingBlockKind, listDepth: Int, quoteDepth: Int, marker: String?) throws -> MarkdownPlan.Block {
        var result = MarkdownPlan.Block(kind: kind, range: range, listDepth: listDepth, quoteDepth: quoteDepth, marker: marker)
        guard node.childCount > 0, let raw = source.substring(utf16: range) else { return result }
        var start = range.location
        var end = range.end ?? start
        var content = raw[...]
        if node is Heading {
            if let headingMarker = content.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression) {
                start += content[headingMarker].utf16.count
                content = content[headingMarker.upperBound...]
            } else if let lineEnd = content.lastIndex(where: \.isNewline),
                      content[content.index(after: lineEnd)...].allSatisfy({ $0 == "=" || $0 == "-" || $0.isWhitespace }) {
                content = content[..<lineEnd]
                end = start + content.utf16.count
            }
        }
        if case .tableCell = kind {
            let leading = content.prefix(while: { $0 == " " || $0 == "\t" })
            start += leading.utf16.count
            content = content.dropFirst(leading.count)
            let trailing = content.reversed().prefix(while: { $0 == " " || $0 == "\t" })
            end -= trailing.count
            content = content.dropLast(trailing.count)
        }
        guard !content.isEmpty, end >= start else { return result }
        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var pieces: [String] = []
        var normalizedLines: [String] = []
        var lineStarts: [Int] = []
        var continuation: String?
        var rawOffset = start
        var rawCursor = content.startIndex
        for (index, line) in lines.enumerated() {
            var prose = line
            if index > 0 {
                var quotes = quoteDepth
                prose = line.drop(while: { $0 == " " || $0 == "\t" })
                while quotes > 0, prose.first == ">" {
                    prose = prose.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
                    quotes -= 1
                }
                if continuation == nil { continuation = String(line[..<prose.startIndex]) }
            }
            lineStarts.append(rawOffset + line[..<prose.startIndex].utf16.count)
            normalizedLines.append(String(prose))
            rawOffset += line.utf16.count
            rawCursor = content.index(rawCursor, offsetBy: line.count)
            let hasNext = index + 1 < lines.count
            if hasNext {
                rawOffset += String(content[rawCursor]).utf16.count
                rawCursor = content.index(after: rawCursor)
            }
            if hasNext, !prose.reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2) {
                pieces.append(String(prose) + "\n")
            } else if hasNext, prose.hasSuffix("  ") {
                pieces.append(prose.trimmingCharacters(in: .whitespaces) + "\\\n")
            } else {
                pieces.append(String(prose) + (hasNext ? " " : ""))
            }
        }
        if normalizedLines.first?.hasPrefix("[") == true {
            let definitions = MarkdownReferences.leadingDefinitionBytes(in: normalizedLines.joined(separator: "\n"))
            if definitions > 0 {
                var consumed = 0
                var count = 0
                while count < normalizedLines.count, consumed < definitions {
                    consumed += normalizedLines[count].utf8.count + 1
                    count += 1
                }
                guard count < lineStarts.count else { return result }
                start = lineStarts[count]
                pieces.removeFirst(count)
            }
        }
        let payload = pieces.joined().trimmingWhitespaceSplit().core
        let edit = TextRange(location: start, length: end - start)
        guard edit.isWithin(range), source.hasValidRange(edit) else { throw MarkdownPlan.invalidPlan }
        result.edit = edit
        result.payload = try Self.explicitReferences(payload, references: references)
        result.continuation = continuation ?? ""
        return result
    }

    /// Locate the suffix after a link's first balanced bracket pair.
    private static func labelEnd(_ raw: String) -> String.Index? {
        var depth = 0
        var escaped = false
        for index in raw.indices {
            let character = raw[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    static func linkSuffix(_ raw: String?) -> String {
        guard let raw, let end = labelEnd(raw) else { return raw ?? "" }
        return String(raw[raw.index(after: end)...])
    }

    private static func explicitReferences(_ payload: String, references: MarkdownReferences) throws -> String {
        let selected = references.definitions(for: payload)
        guard !selected.isEmpty else { return payload }
        let text = "x " + payload
        let coordinates = MarkdownCoordinates(text)
        let doc = try parse(text + "\n\n" + selected)
        var nodes = Array(doc.children)
        var edits: [(TextRange, String)] = []
        while let node = nodes.popLast() {
            if node is Link || node is Image,
               let range = coordinates.range(node.range), let raw = coordinates.text(node.range),
               let end = labelEnd(raw), let start = raw.firstIndex(of: "[") {
                let suffix = raw[raw.index(after: end)...]
                if suffix.isEmpty || suffix == "[]" {
                    edits.append((range, String(raw[...end]) + String(raw[start...end])))
                    continue
                }
            }
            nodes.append(contentsOf: node.children)
        }
        let result = NSMutableString(string: text)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
        }
        return String((result as String).dropFirst(2))
    }
}
