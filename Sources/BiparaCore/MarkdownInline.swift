import Foundation
import Markdown

/// Inline payload parsing and canonical visible unit strings.
struct MarkdownInline {
    var signature: [String] = []
    var runs: [MarkdownReadingRun] = []
    var prose = ""
    private var source: MarkdownCoordinates
    private var indivisible: [TextRange] = []
    var hasProse: Bool { prose.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
    var visible: String { runs.map(\.text).joined() }

    init(_ payload: String, references: MarkdownReferences) throws {
        source = MarkdownCoordinates("x " + payload)
        guard !payload.isEmpty else { return }
        let document = try MarkdownSource.parse(source.text + "\n\n" + references.definitions(for: payload))
        guard document.childCount == 1, let paragraph = document.child(at: 0) as? Paragraph else {
            throw MarkdownPlan.structureMismatch
        }
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
            runs.append(.init("◫ ", style: style))
        default:
            tag = String(describing: type(of: node))
        }
        signature.append(tag)
        for child in node.children { append(child, style: style, destination: destination) }
        signature.append("/")
    }

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
