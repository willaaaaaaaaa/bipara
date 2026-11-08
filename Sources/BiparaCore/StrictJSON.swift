import Foundation

/// Errors from the strict JSON preflight.
public enum StrictJSONError: Error, Equatable, Sendable {
    case tooLarge(actualBytes: Int, maxBytes: Int)
    case invalidUTF8
    case malformed
    case duplicateKey
}

/// Shared strict-JSON preflight for IPC frames and document files.
///
/// Validates UTF-8 and size, scans object/array/string structure with an
/// iterative stack (no value AST), and rejects duplicate decoded keys per
/// object — including keys that differ only in escape spelling such as
/// `"a"` versus `"\u0061"` — before Foundation decoding. Codable then
/// validates grammar details, types, and fields.
public enum StrictJSON {
    public static func preflight(_ data: Data, maxBytes: Int) throws(StrictJSONError) {
        guard data.count <= maxBytes else {
            throw .tooLarge(actualBytes: data.count, maxBytes: maxBytes)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw .invalidUTF8
        }
        var scanner = Scanner(bytes: [UInt8](data))
        try scanner.scanRoot()
    }

    /// Preflight, then decode with Codable.
    public static func decode<T: Decodable>(
        _ type: T.Type, from data: Data, maxBytes: Int
    ) throws(StrictJSONError) -> T {
        try preflight(data, maxBytes: maxBytes)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .malformed
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        enum Frame {
            case object(keys: Set<[UInt8]>)
            case array
        }

        private enum Phase {
            case value
            case objectKeyOrClose
            case objectKeyAfterComma
            case colon
            case arrayValueOrClose
            case commaOrClose
            case done
        }

        mutating func scanRoot() throws(StrictJSONError) {
            var stack: [Frame] = []
            var phase: Phase = .value
            while true {
                skipWhitespace()
                guard index < bytes.count else {
                    if phase == .done && stack.isEmpty { return }
                    throw .malformed
                }
                let byte = bytes[index]
                switch phase {
                case .value, .arrayValueOrClose:
                    if phase == .arrayValueOrClose, byte == closeBracket {
                        _ = stack.popLast()
                        phase = containerComplete(stack)
                        index += 1
                        continue
                    }
                    switch byte {
                    case openBrace:
                        stack.append(.object(keys: []))
                        phase = .objectKeyOrClose
                        index += 1
                    case openBracket:
                        stack.append(.array)
                        phase = .arrayValueOrClose
                        index += 1
                    case quote:
                        _ = try scanString()
                        phase = valueComplete(stack)
                    case minus, digit0...digit9:
                        try scanNumber()
                        phase = valueComplete(stack)
                    case let b where b == UInt8(ascii: "t") || b == UInt8(ascii: "f") || b == UInt8(ascii: "n"):
                        try scanLiteral()
                        phase = valueComplete(stack)
                    default:
                        throw .malformed
                    }
                case .objectKeyOrClose, .objectKeyAfterComma:
                    // `.objectKeyAfterComma` exists so a trailing comma
                    // (`{"a":1,}`) cannot reuse the close accepted by
                    // `.objectKeyOrClose`.
                    if byte == closeBrace {
                        guard phase == .objectKeyOrClose else { throw .malformed }
                        _ = stack.popLast()
                        phase = containerComplete(stack)
                        index += 1
                    } else if byte == quote {
                        let key = try scanString()
                        guard case .object(var keys) = stack.last ?? .array else {
                            throw .malformed
                        }
                        if !keys.insert(key).inserted {
                            throw .duplicateKey
                        }
                        stack[stack.count - 1] = .object(keys: keys)
                        phase = .colon
                    } else {
                        throw .malformed
                    }
                case .colon:
                    guard byte == colon else { throw .malformed }
                    phase = .value
                    index += 1
                case .commaOrClose:
                    if case .object = stack.last ?? .array {
                        if byte == closeBrace {
                            _ = stack.popLast()
                            phase = containerComplete(stack)
                            index += 1
                        } else if byte == comma {
                            phase = .objectKeyAfterComma
                            index += 1
                        } else {
                            throw .malformed
                        }
                    } else {
                        // Array element finished.
                        if byte == closeBracket {
                            _ = stack.popLast()
                            phase = containerComplete(stack)
                            index += 1
                        } else if byte == comma {
                            phase = .value
                            index += 1
                        } else {
                            throw .malformed
                        }
                    }
                case .done:
                    throw .malformed // non-whitespace after the root value
                }
            }
        }

        private func valueComplete(_ stack: [Frame]) -> Phase {
            stack.isEmpty ? .done : .commaOrClose
        }

        private func containerComplete(_ stack: [Frame]) -> Phase {
            stack.isEmpty ? .done : .commaOrClose
        }

        private mutating func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == space || bytes[index] == tab || bytes[index] == newline || bytes[index] == carriageReturn {
                index += 1
            }
        }

        /// Scans a JSON string and returns its decoded UTF-8 bytes.
        private mutating func scanString() throws(StrictJSONError) -> [UInt8] {
            index += 1 // opening quote
            var raw: [UInt8] = []
            var hasEscape = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte == quote {
                    index += 1
                    if !hasEscape { return raw }
                    return try decodeEscaped(raw)
                }
                if byte == backslash {
                    hasEscape = true
                    index += 1
                    guard index < bytes.count else { throw .malformed }
                    let esc = bytes[index]
                    switch esc {
                    case quote, backslash, slash, UInt8(ascii: "b"), UInt8(ascii: "f"),
                         UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        raw.append(backslash)
                        raw.append(esc)
                        index += 1
                    case UInt8(ascii: "u"):
                        raw.append(backslash)
                        raw.append(esc)
                        index += 1
                        for _ in 0..<4 {
                            guard index < bytes.count, isHex(bytes[index]) else { throw .malformed }
                            raw.append(bytes[index])
                            index += 1
                        }
                    default:
                        throw .malformed
                    }
                    continue
                }
                if byte < 0x20 {
                    throw .malformed // unescaped control character
                }
                raw.append(byte)
                index += 1
            }
            throw .malformed // unterminated string
        }

        /// Decode a raw string body that contains escapes, using Foundation.
        private func decodeEscaped(_ raw: [UInt8]) throws(StrictJSONError) -> [UInt8] {
            var document = [UInt8](); document.reserveCapacity(raw.count + 2)
            document.append(quote)
            document.append(contentsOf: raw)
            document.append(quote)
            do {
                let text = try JSONDecoder().decode(String.self, from: Data(document))
                return Array(text.utf8)
            } catch {
                throw .malformed
            }
        }

        private mutating func scanNumber() throws(StrictJSONError) {
            if bytes[index] == minus { index += 1 }
            guard index < bytes.count, bytes[index] >= digit0, bytes[index] <= digit9 else { throw .malformed }
            if bytes[index] == digit0 {
                index += 1
            } else {
                while index < bytes.count, bytes[index] >= digit0, bytes[index] <= digit9 { index += 1 }
            }
            if index < bytes.count, bytes[index] == period {
                index += 1
                let fracStart = index
                while index < bytes.count, bytes[index] >= digit0, bytes[index] <= digit9 { index += 1 }
                if index == fracStart { throw .malformed }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == plus || bytes[index] == minus { index += 1 }
                let expStart = index
                while index < bytes.count, bytes[index] >= digit0, bytes[index] <= digit9 { index += 1 }
                if index == expStart { throw .malformed }
            }
        }

        private mutating func scanLiteral() throws(StrictJSONError) {
            for expected in [UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n")] where bytes[index] == expected {
                let word: [UInt8]
                switch expected {
                case UInt8(ascii: "t"): word = Array("true".utf8)
                case UInt8(ascii: "f"): word = Array("false".utf8)
                default: word = Array("null".utf8)
                }
                guard index + word.count <= bytes.count else { throw .malformed }
                for (offset, char) in word.enumerated() where bytes[index + offset] != char {
                    throw .malformed
                }
                index += word.count
                return
            }
            throw .malformed
        }

        private func isHex(_ byte: UInt8) -> Bool {
            (byte >= digit0 && byte <= digit9)
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
        }
    }
}

private let quote = UInt8(ascii: "\"")
private let backslash = UInt8(ascii: "\\")
private let slash = UInt8(ascii: "/")
private let openBrace = UInt8(ascii: "{")
private let closeBrace = UInt8(ascii: "}")
private let openBracket = UInt8(ascii: "[")
private let closeBracket = UInt8(ascii: "]")
private let colon = UInt8(ascii: ":")
private let comma = UInt8(ascii: ",")
private let minus = UInt8(ascii: "-")
private let plus = UInt8(ascii: "+")
private let period = UInt8(ascii: ".")
private let digit0 = UInt8(ascii: "0")
private let digit9 = UInt8(ascii: "9")
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")
private let newline = UInt8(ascii: "\n")
private let carriageReturn = UInt8(ascii: "\r")
