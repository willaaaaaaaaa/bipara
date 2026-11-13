import Testing
import cmark_gfm
@testable import BiparaCore

struct MarkdownReferencesTests {
    private func references(in source: String) throws -> MarkdownReferences {
        let parser = try #require(cmark_parser_new(CMARK_OPT_SOURCEPOS))
        cmark_parser_feed(parser, source, source.utf8.count)
        let (root, references) = MarkdownReferences.finish(parser)
        try #require(root != nil)
        cmark_node_free(root)
        return references
    }

    @Test func nestedMultilineDefinitionsUseFirstDestinationAndFilterByLabel() throws {
        let source = """
        > [manual]:
        >   https://example.org/first

        - [other]: https://example.org/other

        [manual]: https://example.org/duplicate
        """
        let index = try references(in: source)
        #expect(index.definitions(for: "[Read][MANUAL]") == "[manual]: <https://example.org/first>")
        #expect(index.definitions(for: "[other]") == "[other]: <https://example.org/other>")
        #expect(index.definitions(for: "Read the manual.") == "")
    }

    @Test func paragraphTextAndCodeCannotIntroduceReferences() throws {
        let source = """
        This paragraph continues.
        [false]: https://example.org/prose

        ```
        [false]: https://example.org/code
        ```

        [Read][false]
        """
        #expect(try references(in: source).definitions(for: "[Read][false]") == "")
    }

    @Test func foldedReferenceLabelsKeepCanonicallyEquivalentUTF8Distinct() throws {
        let precomposed = "é"
        let decomposed = "e\u{301}"
        let source = "[\(precomposed)]: https://example.org/nfc\n[\(decomposed)]: https://example.org/nfd"
        let index = try references(in: source)
        #expect(TextIdentity.equal(index.definitions(for: "[É]"), "[\(precomposed)]: <https://example.org/nfc>"))
        #expect(TextIdentity.equal(index.definitions(for: "[E\u{301}]"), "[\(decomposed)]: <https://example.org/nfd>"))
    }

    @Test func leadingDefinitionExtentUsesOriginalByteOffsets() {
        let prefix = "[手冊]:\r\n  https://example.org/manual\r\n  \"line 1\r\nline 2\"\r\n[escaped\\]]: /help\r\n"
        let prose = "Read the manual.\r\n[other]: /inside-prose"
        #expect(MarkdownReferences.leadingDefinitionBytes(in: prefix + prose) == prefix.utf8.count)
        #expect(MarkdownReferences.leadingDefinitionBytes(in: prose) == 0)
        #expect(MarkdownReferences.leadingDefinitionBytes(in: "[invalid]: several words") == 0)
        let final = "[manual]: /help"
        #expect(MarkdownReferences.leadingDefinitionBytes(in: final) == final.utf8.count)
    }
}
