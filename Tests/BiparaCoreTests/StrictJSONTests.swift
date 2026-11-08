import Foundation
import Testing
@testable import BiparaCore

@Suite("Strict JSON preflight")
struct StrictJSONTests {
    private func check(_ text: String, maxBytes: Int = 1 << 20) throws(StrictJSONError) {
        try StrictJSON.preflight(Data(text.utf8), maxBytes: maxBytes)
    }

    @Test func acceptsValidDocuments() throws {
        try check(#"{"a":1,"b":[true,false,null,"x"],"c":{"d":1.5e-3}}"#)
        try check("[]")
        try check("{}")
        try check(#""plain""#)
        try check("42")
        try check("-0.5E+10")
        try check(#"{"中文":["🎉","\ud83d\ude00"]}"#)
        try check("  \n{}\t\r  ")
        try check(#"{"a\/b":1}"#)
        // Canonically equivalent but code-point-different keys stay distinct:
        // precomposed U+00E9 vs "e" + combining acute U+0301.
        try check("{\"\u{00E9}\":1,\"e\u{0301}\":2}")
    }

    @Test func rejectsDuplicatePlainKeys() {
        #expect(throws: StrictJSONError.duplicateKey) { try check(#"{"a":1,"a":2}"#) }
    }

    @Test func rejectsDuplicateEscapedAliasKeys() {
        // "a" and "\u0061" decode to the same key within one object.
        #expect(throws: StrictJSONError.duplicateKey) { try check(#"{"a":1,"\u0061":2}"#) }
        #expect(throws: StrictJSONError.duplicateKey) { try check(#"{"ab":1,"\u0061b":2}"#) }
        // Escaped quote and escaped unicode must decode before comparison.
        #expect(throws: StrictJSONError.duplicateKey) {
            try check(#"{"a\"b":1,"\u0061\u0022b":2}"#)
        }
    }

    @Test func sameKeyInDistinctObjectsIsValid() throws {
        try check(#"{"a":{"a":1},"b":[{"a":2}]}"#)
    }

    @Test func rejectsObjectTrailingComma() {
        #expect(throws: StrictJSONError.malformed) { try check(#"{"a":1,}"#) }
        #expect(throws: StrictJSONError.malformed) { try check(#"{"a":1, }"#) }
        #expect(throws: StrictJSONError.malformed) { try check(#"{"a":1,"b":2,}"#) }
        #expect(throws: StrictJSONError.malformed) { try check(#"{"a":{"b":1,}}"#) }
        #expect(throws: StrictJSONError.malformed) { try check(#"{,}"#) }
        #expect(throws: StrictJSONError.malformed) { try check(#"[{"a":1,}]"#) }
    }

    @Test func rejectsMalformedDocuments() {
        let bad = [
            "",
            "{",
            "}",
            #"{"a"}"#,
            #"{"a":}"#,
            #"[1,]"#,
            #"{,"a":1}"#,
            "\"unterminated",
            #"01"#,
            #"1."#,
            #"1e"#,
            "tru",
            "NaN",
            "Infinity",
            #"{"a":1}x"#,
            "[1 2]",
            #"{"a":1 "b":2}"#,
            "\"a\tb\"",
        ]
        for text in bad {
            #expect(throws: StrictJSONError.self) { try check(text) }
        }
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: StrictJSONError.invalidUTF8) {
            try StrictJSON.preflight(Data([0x22, 0xFF, 0x22]), maxBytes: 1024)
        }
    }

    @Test func rejectsOversizedPayload() {
        let big = Data(repeating: UInt8(ascii: " "), count: 65)
        #expect(throws: StrictJSONError.tooLarge(actualBytes: 65, maxBytes: 64)) {
            try StrictJSON.preflight(big, maxBytes: 64)
        }
    }

    @Test func decodesCodableAfterPreflight() throws {
        struct Sample: Codable, Equatable { let a: Int; let b: String }
        let data = Data(#"{"a":1,"b":"x"}"#.utf8)
        let value = try StrictJSON.decode(Sample.self, from: data, maxBytes: 1024)
        #expect(value == Sample(a: 1, b: "x"))
        // A type mismatch surfaces as malformed after the preflight passes.
        let wrong = Data(#"{"a":"not an int","b":"x"}"#.utf8)
        #expect(throws: StrictJSONError.malformed) {
            _ = try StrictJSON.decode(Sample.self, from: wrong, maxBytes: 1024)
        }
        // Duplicate keys never reach Codable's last-wins behavior.
        let dup = Data(#"{"a":1,"a":2,"b":"x"}"#.utf8)
        #expect(throws: StrictJSONError.duplicateKey) {
            _ = try StrictJSON.decode(Sample.self, from: dup, maxBytes: 1024)
        }
    }
}
