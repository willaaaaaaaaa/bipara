import Foundation
import Markdown

extension MarkdownInline {
    /// Pair likely style delimiters in the reply. A punctuation-ended span can
    /// otherwise appear as literal stars, or cmark can pair two different labels.
    func repairEmphasis(in text: String, original: String, references: MarkdownReferences) -> String {
        struct Opener {
            let marker: Character
            let range: Range<Int>
            let punctuationEnd: Int
            let needsStars: Bool
        }
        let chars = Array(text)
        var offsets = [0]
        for char in chars { offsets.append(offsets.last! + char.utf16.count) }
        func movablePunctuation(at i: Int) -> Bool {
            chars.indices.contains(i) && (chars[i].isPunctuation || chars[i].isSymbol) && !#"\[]<>*_~`"#.contains(chars[i]) && !protects(offsets[i])
        }
        var stack: [Opener] = []
        var edits: [(Range<Int>, String)] = []
        var originalProse: String?
        var index = 0
        while index < chars.count {
            let start = index
            let marker = chars[index]
            index += 1
            if marker == "\n" { stack.removeAll(); continue }
            if marker == "\\" { index = min(index + 1, chars.count); continue }
            guard marker == "*" || marker == "_", !protects(offsets[start]) else { continue }
            while index < chars.count && chars[index] == marker && !protects(offsets[index]) { index += 1 }
            let width = index - start
            guard width <= 3 else { stack.removeAll(); continue }
            let prev = start > 0 ? chars[start - 1] : " "
            let next = index < chars.count ? chars[index] : " "
            let prevPunct = prev.isPunctuation || prev.isSymbol
            let nextPunct = next.isPunctuation || next.isSymbol
            let left = !next.isWhitespace && (!nextPunct || prev.isWhitespace || prevPunct)
            let right = !prev.isWhitespace && (!prevPunct || next.isWhitespace || nextPunct)
            let intraword = marker == "_" && left && right && !prevPunct && !nextPunct &&
                (prev.unicodeScalars.contains { $0.properties.isIdeographic } || next.unicodeScalars.contains { $0.properties.isIdeographic })

            var trailing = start
            if !right && (next.isLetter || next.isNumber) {
                while movablePunctuation(at: trailing - 1) { trailing -= 1 }
                if trailing > 0 && chars[trailing - 1] == "\\" { trailing = start }
            }
            let canClose = right && (marker == "*" || !left || nextPunct || intraword)
            var first = stack.count
            var remaining = width
            while first > 0, stack[first - 1].marker == marker, stack[first - 1].range.count <= remaining {
                first -= 1
                remaining -= stack[first].range.count
                if remaining == 0 { break }
            }
            if remaining == 0 && (canClose || trailing < start) {
                let openers = stack[first...]
                stack.removeSubrange(first...)
                let needsStars = intraword || openers.contains(where: \.needsStars)
                guard trailing < start || needsStars || openers.contains(where: { $0.punctuationEnd > $0.range.upperBound }),
                      let outer = openers.first, let inner = openers.last, inner.punctuationEnd < trailing else { continue }
                let spelling = String(chars[outer.range.lowerBound..<index])
                if original.contains(spelling) {
                    if originalProse == nil { originalProse = (try? MarkdownInline(original, references: references))?.prose ?? original }
                    if originalProse?.contains(spelling) == true { continue }
                }
                let canonical = needsStars ? "*" : String(marker)
                for opener in openers {
                    let leading = String(chars[opener.range.upperBound..<opener.punctuationEnd])
                    if !leading.isEmpty || needsStars {
                        edits.append((opener.range.lowerBound..<opener.punctuationEnd, leading + String(repeating: canonical, count: opener.range.count)))
                    }
                }
                if trailing < start || needsStars {
                    edits.append((trailing..<index, String(repeating: canonical, count: width) + String(chars[trailing..<start])))
                }
            } else {
                var leading = index
                if !left && (prev.isLetter || prev.isNumber) {
                    while movablePunctuation(at: leading) { leading += 1 }
                }
                if (left && (marker == "*" || !right || prevPunct || intraword)) || leading > index {
                    stack.append(.init(marker: marker, range: start..<index, punctuationEnd: leading, needsStars: intraword))
                }
            }
        }
        guard !edits.isEmpty else { return text }
        var candidate = ""
        var cursor = 0
        for (range, value) in edits.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            guard range.lowerBound >= cursor else { return text }
            candidate += String(chars[cursor..<range.lowerBound]) + value
            cursor = range.upperBound
        }
        candidate += String(chars[cursor...])
        guard let repaired = try? MarkdownInline(candidate, references: references),
              repaired.visible.utf8.count < visible.utf8.count,
              TextIdentity.equal(repaired.visible.filter { $0 != "*" && $0 != "_" }, visible.filter { $0 != "*" && $0 != "_" }),
              repaired.protectedSignature.elementsEqual(protectedSignature, by: TextIdentity.equal) else { return text }
        return candidate
    }
}

extension MarkdownPlan {
    func literalBlockMarkers(in raw: String, unit: UUID, block: Block) -> String {
        var text = raw
        if block.edit?.location == 0, unit == block.units.first, text.hasPrefix("\u{FEFF}") {
            // A literal U+FEFF at byte zero would be consumed as the document BOM.
            text = "&#xFEFF;" + text.dropFirst()
        }
        if case .tableCell = block.kind {
            guard text.contains("|") else { return text }
            let inline = try? MarkdownInline(text, references: references)
            var result = ""
            var escaped = false
            var offset = 0
            for character in text {
                if character == "|", !escaped, inline?.protects(offset) == false { result += "\\" }
                result.append(character)
                escaped = character == "\\" && !escaped
                offset += character.utf16.count
            }
            return result
        }
        guard block.metadataKey == nil else { return text }
        if case .heading = block.kind, let edit = block.edit,
           let prefix = source.substring(utf16: .init(location: block.range.location, length: edit.location - block.range.location)),
           prefix.hasPrefix("#") {
            guard unit == block.units.last, let end = edit.end, let stop = source.utf16Index(at: end),
                  !source[stop...].prefix(while: { !$0.isNewline }).contains("#"),
                  let hashes = text.range(of: #"(?:^|(?<=[ \t]))#+$"#, options: .regularExpression) else { return text }
            var result = text
            result.insert("\\", at: hashes.lowerBound)
            return result
        }

        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { i, line in
            let first = unit == block.units.first && i == 0
            guard first || i > 0 else { return line }
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            if first, let marker = block.marker, !["☑", "☐"].contains(marker),
               body.range(of: #"^\[[ xX]\](?:[ \t]|$)"#, options: .regularExpression) != nil,
               let edit = block.edit, let at = source.utf16Index(at: edit.location),
               source[..<at].suffix(16).range(of: #"(?:[-+*]|[0-9]{1,9}[.)])[ \t]+$"#, options: .regularExpression) != nil {
                return String(line[..<body.startIndex]) + "\\" + body
            }
            guard let match = body.range(of: #"^(?:[0-9]{1,9}[.)](?=[ \t]|$)|[#>+*=_~\-]|\[)"#, options: .regularExpression) else { return line }
            // A numbered marker other than 1 can start a list but cannot interrupt
            // a paragraph. Ask the same parser with the actual line position.
            let probe = (first ? "" : "x\\\n") + line
            guard let parsed = try? MarkdownSource.parse(probe),
                  parsed.childCount != 1 || !(parsed.child(at: 0) is Paragraph) else { return line }
            var result = line
            result.insert("\\", at: body.index(before: match.upperBound))
            return result
        }.joined(separator: "\n")
    }
}
