import Foundation

/// Recognizes only top-level, single-line prose scalars. Other YAML stays opaque.
/// Never evaluate tags, aliases, nested values or multiline scalar syntax.
enum MarkdownMetadata {
    static func blocks(_ text: String, range: TextRange) -> [MarkdownPlan.Block] {
        // Accept only independently complete mapping lines. YAML collections,
        // tags and multiline values can contain apparent top-level keys.
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." || trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*:"#, options: .regularExpression) != nil,
                  let colon = line.firstIndex(of: ":") else {
                return [.init(kind: .literal, range: range, literal: text)]
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let first = value.first, "!&*|>".contains(first) {
                return [.init(kind: .literal, range: range, literal: text)]
            }
            if value.hasPrefix("\"") || value.hasPrefix("'") {
                if scalar(value) == nil { return [.init(kind: .literal, range: range, literal: text)] }
            } else if value.contains("{") || value.contains("[") {
                return [.init(kind: .literal, range: range, literal: text)]
            }
        }
        let ns = text as NSString
        let pattern = #"(?m)^(title|description):[ \t]*([^\r\n]+)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var blocks: [MarkdownPlan.Block] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let valueRange = match.range(at: 2)
            let lineEnd = NSMaxRange(match.range)
            let tail = ns.substring(from: lineEnd)
            // An indented continuation makes this a multiline value, not a scalar we own.
            let following = tail.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            if let following, following.first?.isWhitespace == true { continue }
            guard let (value, length) = scalar(ns.substring(with: valueRange)), !value.contains(where: \.isNewline),
                  let inline = try? MarkdownInline(value, references: .empty), inline.hasProse else { continue }
            let edit = TextRange(location: range.location + valueRange.location, length: length)
            if valueRange.location > cursor {
                let gap = TextRange(location: range.location + cursor, length: valueRange.location - cursor)
                blocks.append(.init(kind: .literal, range: gap, literal: ns.substring(with: NSRange(location: cursor, length: gap.length))))
            }
            blocks.append(.init(kind: .literal, range: edit, edit: edit, payload: value, metadataScalar: true))
            cursor = valueRange.location + length
        }
        if cursor < ns.length {
            blocks.append(.init(kind: .literal, range: .init(location: range.location + cursor, length: ns.length - cursor),
                                literal: ns.substring(from: cursor)))
        }
        return blocks
    }

    private static func scalar(_ raw: String) -> (String, Int)? {
        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            let quote = raw.first!
            var cursor = raw.index(after: raw.startIndex)
            while cursor < raw.endIndex {
                if quote == "\"", raw[cursor] == "\\" {
                    cursor = raw.index(after: cursor)
                    guard cursor < raw.endIndex else { return nil }
                } else if raw[cursor] == quote {
                    let end = raw.index(after: cursor)
                    if quote == "'", end < raw.endIndex, raw[end] == "'" {
                        cursor = raw.index(after: end)
                        continue
                    }
                    let suffix = raw[end...].trimmingCharacters(in: .whitespaces)
                    guard suffix.isEmpty || (raw[end...].first?.isWhitespace == true && suffix.hasPrefix("#")) else { return nil }
                    let token = String(raw[..<end])
                    let value: String?
                    if quote == "'" { value = String(token.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
                    else { value = try? JSONDecoder().decode(String.self, from: Data(token.utf8)) }
                    return value.map { ($0, token.utf16.count) }
                }
                cursor = raw.index(after: cursor)
            }
            return nil
        }
        guard let first = raw.first, !"!&*{}[]>|%@`#".contains(first) else { return nil }
        let end = raw.range(of: #"[ \t]+#"#, options: .regularExpression)?.lowerBound ?? raw.endIndex
        let value = raw[..<end].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, Double(value) == nil,
              !["true", "false", "null", "~", "yes", "no", "on", "off"].contains(value.lowercased()),
              value.range(of: #":[ \t]"#, options: .regularExpression) == nil else { return nil }
        return (value, value.utf16.count)
    }

    static func quoted(_ value: String) -> String {
        // JSON strings are also YAML double-quoted scalars, including escaped newlines.
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}
