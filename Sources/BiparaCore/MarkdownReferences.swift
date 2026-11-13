import cmark_gfm

/// Reference definitions selected by the pinned parser, including definitions
/// in nested containers and definitions whose destination spans lines.
struct MarkdownReferences: Equatable, Sendable {
    // cmark compares folded label bytes. Swift String hashing would also
    // equate canonically equivalent spellings that cmark keeps distinct.
    private let entries: [[UInt8]: String]
    static let empty = MarkdownReferences(entries: [:])

    func definitions(for payload: String) -> String {
        guard !entries.isEmpty, payload.contains("[") else { return "" }
        var selected: Set<[UInt8]> = []
        var label: [UInt8] = []
        var insideLabel = false
        var escaped = false
        for byte in payload.utf8 {
            if !escaped, byte == 91 {
                label.removeAll(keepingCapacity: true)
                insideLabel = true
            } else if !escaped, byte == 93, insideLabel {
                if let key = Self.normalizedLabel(&label), entries[key] != nil {
                    selected.insert(key)
                }
                insideLabel = false
            } else if insideLabel {
                label.append(byte)
                if label.count > Int(MAX_LINK_LABEL_LENGTH) { insideLabel = false }
            }
            escaped = byte == 92 && !escaped
        }
        return selected.sorted(by: { $0.lexicographicallyPrecedes($1) }).compactMap { entries[$0] }.joined(separator: "\n")
    }

    /// Measure the leading definitions cmark removes before parsing a
    /// block's inline text. The caller supplies the container-stripped text.
    static func leadingDefinitionBytes(in text: String) -> Int {
        guard text.utf8.first == 91, let memory = cmark_get_default_mem_allocator(),
              let map = cmark_reference_map_new(memory) else { return 0 }
        defer { cmark_map_free(map) }
        var bytes = Array(text.utf8)
        let length = bytes.count
        // cmark supplies a terminating newline to block content, and its
        // inline subject peeks at a NUL sentinel after the chunk.
        if bytes.last != 10, bytes.last != 13 { bytes.append(10) }
        let chunkLength = bytes.count
        bytes.append(0)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            guard let start = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < length, start[offset] == 91 {
                var chunk = cmark_chunk(data: start + offset, len: Int32(chunkLength - offset), alloc: 0)
                let consumed = cmark_parse_reference_inline(memory, &chunk, map)
                guard consumed > 0 else { break }
                offset += Int(consumed)
            }
            return min(offset, length)
        }
    }

    private static func normalizedLabel(_ label: inout [UInt8]) -> [UInt8]? {
        guard !label.isEmpty, let memory = cmark_get_default_mem_allocator() else { return nil }
        return label.withUnsafeMutableBufferPointer { bytes in
            var chunk = cmark_chunk(data: bytes.baseAddress, len: Int32(bytes.count), alloc: 0)
            guard let normalized = normalize_map_label(memory, &chunk) else { return nil }
            defer { memory.pointee.free(normalized) }
            return labelBytes(normalized)
        }
    }

    private static func labelBytes(_ label: UnsafePointer<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        var cursor = label
        while cursor.pointee != 0 {
            result.append(cursor.pointee)
            cursor += 1
        }
        return result
    }

    /// Consume the parser. The caller owns the returned tree and must free it.
    static func finish(_ parser: UnsafeMutablePointer<cmark_parser>) -> (root: UnsafeMutablePointer<cmark_node>?, references: Self) {
        guard let memory = cmark_get_default_mem_allocator(),
              let hook = cmark_syntax_extension_new("bipara-reference-capture") else {
            let root = cmark_parser_finish(parser)
            cmark_parser_free(parser)
            return (root, .empty)
        }
        let capture = Capture()
        cmark_syntax_extension_set_private(hook, Unmanaged.passUnretained(capture).toOpaque(), nil)
        cmark_syntax_extension_set_postprocess_func(hook) { extensionPointer, parserPointer, root in
            guard let opaque = cmark_syntax_extension_get_private(extensionPointer) else { return root }
            let capture = Unmanaged<Capture>.fromOpaque(opaque).takeUnretainedValue()
            capture.read(parserPointer?.pointee.refmap?.pointee.refs)
            return root
        }
        cmark_parser_attach_syntax_extension(parser, hook)
        let root = cmark_parser_finish(parser)
        cmark_parser_free(parser)
        cmark_syntax_extension_free(memory, hook)
        return (root, Self(entries: capture.entries.mapValues(\.definition)))
    }

    private final class Capture {
        var entries: [[UInt8]: (age: Int, definition: String)] = [:]

        func read(_ head: UnsafeMutablePointer<cmark_map_entry>?) {
            var cursor = head
            // The parser destroys its reference map after this synchronous
            // callback, so copy all selected values while the map is valid.
            while let entry = cursor {
                cursor = entry.pointee.next
                let reference = UnsafeRawPointer(entry).assumingMemoryBound(to: cmark_reference.self).pointee
                guard !reference.is_attributes_reference, let label = entry.pointee.label else { continue }
                let key = MarkdownReferences.labelBytes(label)
                let age = entry.pointee.age
                guard age < (entries[key]?.age ?? Int.max) else { continue }
                let destination = Self.escaped(Self.string(reference.url), destination: true)
                let title = Self.string(reference.title)
                let suffix = title.isEmpty ? "" : " \"" + Self.escaped(title, destination: false) + "\""
                entries[key] = (age, "[\(String(decoding: key, as: UTF8.self))]: <\(destination)>\(suffix)")
            }
        }

        private static func string(_ chunk: cmark_chunk) -> String {
            String(decoding: UnsafeBufferPointer(start: chunk.data, count: Int(chunk.len)), as: UTF8.self)
        }

        private static func escaped(_ text: String, destination: Bool) -> String {
            var result = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "&": result += "&amp;"
                case "\\": result += "\\\\"
                case "<" where destination, ">" where destination: result += "\\" + String(scalar)
                case "\"" where !destination: result += "\\\""
                case "\r": result += "&#13;"
                case "\n": result += "&#10;"
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result
        }
    }
}
