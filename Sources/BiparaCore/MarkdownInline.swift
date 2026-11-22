import Foundation
import Markdown

/// Inline payload parsing and canonical visible unit strings.
struct MarkdownInline {
    var signature: [String] = []
    var runs: [MarkdownReadingRun] = []
    var prose = ""
    private(set) var source: MarkdownCoordinates
    private(set) var paragraph: Paragraph?
    private var protectedOffsets = IndexSet()
    private var indivisible: [TextRange] = []
    var hasProse: Bool { prose.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
    var visible: String { runs.map(\.text).joined() }

    init(_ raw: String, references: MarkdownReferences, tableCell: Bool = false) throws {
        // GFM removes one backslash immediately before each pipe when it splits
        // a table row, before the inline parser interprets code or references.
        let payload = tableCell ? raw.replacingOccurrences(of: #"\|"#, with: "|") : raw
        source = MarkdownCoordinates("x " + payload)
        guard !payload.isEmpty else { return }
        let document = try MarkdownSource.parse(source.text + "\n\n" + references.definitions(for: payload))
        guard document.childCount == 1, let paragraph = document.child(at: 0) as? Paragraph else {
            throw MarkdownPlan.structureMismatch
        }
        self.paragraph = paragraph
        for node in paragraph.children {
            if runs.isEmpty, let first = node as? Markdown.Text, first.string.hasPrefix("x ") {
                let text = String(first.string.dropFirst(2))
                if !text.isEmpty { runs.append(.init(text)); prose += text }
                continue
            }
            append(node, style: [], destination: nil)
            if !(node is Markdown.Text), let range = source.range(node.range)?.offset(by: -2) {
                indivisible.append(range)
            }
        }
    }

    private mutating func append(_ node: any Markup, style: MarkdownReadingRun.Style, destination: String?) {
        var style = style
        var destination = destination
        if node is InlineCode || node is InlineHTML || node is Link || node is Image,
           let range = source.range(node.range), let end = range.end {
            var start = range.location
            if node is Link || node is Image, let raw = source.text(node.range),
               let labelEnd = labelEnd(of: node, raw: raw) {
                start += raw[...labelEnd].utf16.count
            }
            if start >= 2 { protectedOffsets.insert(integersIn: (start - 2)..<(end - 2)) }
        }
        var tag: String
        switch node {
        case let text as Markdown.Text:
            runs.append(.init(text.string, style: style, destination: destination))
            prose += text.string
            return
        case is SoftBreak:
            runs.append(.init(" ", style: style, destination: destination))
            prose += " "
            return
        case is LineBreak:
            signature.append("break")
            runs.append(.init("\n", style: style, destination: destination))
            prose += "\n"
            return
        case let code as InlineCode:
            signature.append("code:" + (source.text(node.range) ?? code.code))
            runs.append(.init(code.code, style: style.union(.code)))
            return
        case let html as InlineHTML:
            signature.append("html:" + html.rawHTML)
            runs.append(.init(html.rawHTML, style: style.union(.code)))
            return
        case is Strong: tag = "strong"; style.insert(.bold)
        case is Emphasis: tag = "em"; style.insert(.italic)
        case is Strikethrough: tag = "strike"; style.insert(.strikethrough)
        case let link as Link:
            destination = link.destination
            tag = "link:" + (link.destination ?? "") + ":" + MarkdownSource.linkSuffix(source.text(node.range))
        case let image as Image:
            tag = "image:" + (image.source ?? "") + ":" + MarkdownSource.linkSuffix(source.text(node.range))
            runs.append(.init("◫ ", style: style.union(.imagePlaceholder)))
        default:
            tag = String(describing: type(of: node))
        }
        signature.append(tag)
        for child in node.children { append(child, style: style, destination: destination) }
        signature.append("/")
    }

    /// Siblings may follow translated word order. Hard breaks and raw HTML retain
    /// their position, including when nested inside a protected container.
    private struct ProtectedGroup {
        var tokens: [String] = []
        var movable: [[String]] = []
        var containsBoundary = false

        mutating func flush() {
            movable.sort { a, b in
                a.lexicographicallyPrecedes(b) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            }
            tokens.append(contentsOf: movable.joined())
            movable.removeAll(keepingCapacity: true)
        }

        mutating func append(_ item: [String], boundary: Bool = false) {
            if boundary {
                flush()
                tokens += item
                containsBoundary = true
            } else { movable.append(item) }
        }
    }

    var protectedSignature: [String] {
        var group = ProtectedGroup()
        if let paragraph {
            for child in paragraph.children { collectProtection(child, into: &group) }
        }
        group.flush()
        return group.tokens
    }

    private func collectProtection(_ node: any Markup, into group: inout ProtectedGroup) {
        let tag: String
        switch node {
        case is Markdown.Text, is SoftBreak: return
        case is Strong, is Emphasis:
            for child in node.children { collectProtection(child, into: &group) }
            return
        case is LineBreak: group.append(["break"], boundary: true); return
        case let code as InlineCode: group.append(["code:" + (source.text(node.range) ?? code.code)]); return
        case let html as InlineHTML: group.append(["html:" + html.rawHTML], boundary: true); return
        case let link as Link: tag = "link:" + (link.destination ?? "")
        case let image as Image: tag = "image:" + (image.source ?? "")
        case is Strikethrough: tag = "strike"
        default: tag = String(describing: type(of: node))
        }
        var childGroup = ProtectedGroup()
        for child in node.children { collectProtection(child, into: &childGroup) }
        childGroup.flush()
        var opening = [tag]
        if node is Link || node is Image, let raw = source.text(node.range),
           let end = labelEnd(of: node, raw: raw), let start = raw.firstIndex(of: "[") {
            let suffix = raw[raw.index(after: end)...]
            if suffix.isEmpty || suffix.first == "[" {
                opening.append("reference:" + (suffix.isEmpty || suffix == "[]" ? String(raw[start...end]) : String(suffix)))
            }
        }
        group.append(opening + childGroup.tokens + ["/"], boundary: childGroup.containsBoundary)
    }

    private func labelEnd(of node: any Markup, raw: String) -> String.Index? {
        guard raw.hasPrefix("[") || raw.hasPrefix("![") else { return nil }
        // The label may contain a literal closing bracket inside code or HTML.
        // Start after its parsed children before looking for the closing bracket.
        if node.childCount > 0, let last = node.child(at: node.childCount - 1),
           let parent = source.range(node.range), let end = source.range(last.range)?.end,
           end >= parent.location, let afterChild = raw.utf16Index(at: end - parent.location),
           let close = raw[afterChild...].firstIndex(of: "]") { return close }
        return MarkdownSource.labelEnd(raw)
    }

    func protects(_ utf16Offset: Int) -> Bool { protectedOffsets.contains(utf16Offset) }

    func fragments() throws -> [String] {
        let payload = String(source.text.dropFirst(2))
        let limit = WorkerContract.maxBatchTextBytes
        guard payload.utf8.count > limit else { return [payload] }
        var fragments: [String] = []
        var start = payload.startIndex
        var index = start
        var offset = 0
        var bytes = 0
        var boundary: (String.Index, Int)?
        while index < payload.endIndex {
            let character = payload[index]
            let next = payload.index(after: index)
            let width = payload[index..<next].utf8.count
            if bytes + width > limit {
                guard let (split, splitOffset) = boundary, split > start else {
                    throw CoreError.unsupportedInput("A Markdown unit is too large to split safely.")
                }
                let fragment = String(payload[start..<split]).trimmingWhitespaceSplit().core
                guard !fragment.isEmpty else { throw MarkdownPlan.invalidPlan }
                fragments.append(fragment)
                start = split
                index = split
                offset = splitOffset
                boundary = nil
                bytes = 0
                continue
            }
            bytes += width
            offset += payload[index..<next].utf16.count
            if (character == " " || "。！？；".contains(character)),
               !indivisible.contains(where: { $0.location < offset && ($0.end ?? 0) > offset }) {
                boundary = (next, offset)
            }
            index = next
        }
        let last = String(payload[start...]).trimmingWhitespaceSplit().core
        if !last.isEmpty { fragments.append(last) }
        return fragments
    }

    static func validShape(_ text: String, source: String) -> Bool {
        !text.isEmpty && text.isContractTrimmed && text.utf8.count <= WorkerContract.maxMarkdownTranslationBytes
            && !text.unicodeScalars.contains { $0.value == 13 }
            && text.unicodeScalars.filter { $0.value == 10 }.count <= source.unicodeScalars.filter { $0.value == 10 }.count
            && text.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !String($0).isWhitespaceOnly }
    }
}
