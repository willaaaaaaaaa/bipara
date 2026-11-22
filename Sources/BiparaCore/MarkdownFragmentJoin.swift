import Foundation
import Markdown

/// Keep the serialized block equivalent to the reader's independently attributed units.
enum MarkdownFragmentJoin {
    static func payload(_ pieces: [String], separator: String, references: MarkdownReferences, tableCell: Bool) -> String? {
        guard let parsed = try? pieces.map({ try MarkdownInline($0, references: references) }) else { return nil }
        let expected = Representation(parsed, separator: separator)
        var cell: Representation?
        if tableCell && pieces.contains(where: { $0.contains("|") }) {
            guard let inlines = try? pieces.map({ try MarkdownInline($0, references: references, tableCell: true) }) else { return nil }
            cell = Representation(inlines, separator: separator)
        }
        func matches(_ payload: String) -> Bool {
            guard let joined = try? MarkdownInline(payload, references: references), expected.matches(joined) else { return false }
            if let cell {
                guard let joinedCell = try? MarkdownInline(payload, references: references, tableCell: true) else { return false }
                return cell.matches(joinedCell)
            }
            return true
        }

        func spelling(_ parts: [String]) -> String? {
            let original = parts.joined(separator: separator)
            if matches(original) { return original }
            guard separator.isEmpty else { return nil }
            var merged = parts
            var changed = false
            for i in 1..<parts.count {
                guard let marker = merged[i - 1].last, marker == "*" || marker == "_", merged[i].first == marker else { continue }
                let left = merged[i - 1].reversed().prefix(while: { $0 == marker }).count
                let right = merged[i].prefix(while: { $0 == marker }).count
                let count = min(left, right)
                guard count <= 3 else { continue }
                merged[i - 1].removeLast(count)
                merged[i].removeFirst(count)
                changed = true
            }
            let joined = merged.joined()
            return changed && matches(joined) ? joined : nil
        }

        if let original = spelling(pieces) { return original }

        // Rewrite only literal prose. Code, links and attributed spans keep their spelling.
        let escaped = pieces.indices.map { index in
            let beforeMarkup = separator.isEmpty && index + 1 < parsed.count && !parsed[index + 1].signature.isEmpty
            let afterMarkup = separator.isEmpty && index > 0 && !parsed[index - 1].signature.isEmpty
            return escapeProse(in: parsed[index], raw: pieces[index], afterMarkup: afterMarkup, beforeMarkup: beforeMarkup)
        }
        return escaped.elementsEqual(pieces, by: TextIdentity.equal) ? nil : spelling(escaped)
    }

    private struct Representation {
        let protected: [String]
        let runs: [Span]

        init(_ pieces: [MarkdownInline], separator: String) {
            protected = pieces.flatMap { orderedProtectedTokens($0.signature) }
            var joined: [MarkdownReadingRun] = []
            for (index, piece) in pieces.enumerated() {
                if index > 0 && !separator.isEmpty { joined.append(.init(separator)) }
                joined.append(contentsOf: piece.runs)
            }
            runs = spans(joined)
        }

        func matches(_ inline: MarkdownInline) -> Bool {
            orderedProtectedTokens(inline.signature).elementsEqual(protected, by: TextIdentity.equal) && spans(inline.runs) == runs
        }
    }

    // The styled runs prove emphasis coverage. Other nodes must also retain their
    // original ordered syntax, including code spelling and link destinations/titles.
    private static func orderedProtectedTokens(_ signature: [String]) -> [String] {
        var emphasis: [Bool] = []
        return signature.filter { token in
            if token == "/" { return emphasis.popLast() == false }
            if token == "break" || token.hasPrefix("code:") || token.hasPrefix("html:") { return true }
            let isEmphasis = token == "em" || token == "strong"
            emphasis.append(isEmphasis)
            return !isEmphasis
        }
    }

    private struct Span: Equatable {
        let style: MarkdownReadingRun.Style
        let destination: String?
        var text: Data
    }

    private static func spans(_ runs: [MarkdownReadingRun]) -> [Span] {
        var result: [Span] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.indices.last, result[last].style == run.style, result[last].destination == run.destination {
                result[last].text.append(contentsOf: run.text.utf8)
            } else {
                result.append(.init(style: run.style, destination: run.destination, text: Data(run.text.utf8)))
            }
        }
        return result
    }

    private static func escapeProse(in inline: MarkdownInline, raw: String, afterMarkup: Bool, beforeMarkup: Bool) -> String {
        guard let paragraph = inline.paragraph else { return raw }
        let spelling = inline.source.text as NSString
        var result = ""
        var cursor = 2 // MarkdownInline prepends "x " to keep every fragment in a paragraph.
        for node in paragraph.children {
            guard let text = node as? Markdown.Text, let range = inline.source.range(text.range), let end = range.end else { continue }
            let start = max(2, range.location)
            guard start < end else { continue }
            guard start >= cursor else { return raw }
            result += spelling.substring(with: NSRange(location: cursor, length: start - cursor))
            let visible = range.location == 0 ? String(text.string.dropFirst(2)) : text.string
            result += escapeLiteral(visible, afterMarkup: afterMarkup && start == 2, beforeMarkup: beforeMarkup && end == spelling.length)
            cursor = end
        }
        return result + spelling.substring(from: cursor)
    }

    private static func escapeLiteral(_ text: String, afterMarkup: Bool, beforeMarkup: Bool) -> String {
        let scalars = text.unicodeScalars
        var escaped = ""
        for index in scalars.indices {
            let scalar = scalars[index]
            if (afterMarkup && index == scalars.startIndex) || (beforeMarkup && scalars.index(after: index) == scalars.endIndex) {
                // Entity boundaries also keep a neighboring emphasis delimiter flanking punctuation.
                escaped += "&#\(scalar.value);"
            } else {
                switch scalar.value {
                case 33...47, 58...64, 91...96, 123...126: escaped.append("\\")
                default: break
                }
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
