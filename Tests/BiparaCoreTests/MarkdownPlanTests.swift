import Foundation
import Markdown
import Testing
@testable import BiparaCore

struct MarkdownPlanTests {
    private let rich = """
    ---
    title: Metadata
    ---

    # Start
    Read **this** and [the guide][guide].
    The next source line.

    - [x] Ready
      - Nested item
    - [ ] Waiting

    | Name | Value |
    | :--- | ---: |
    | A \\| B | |
    | C |

    ```sh
    # protected
    echo 'hello'
    ```

    ## Start
    > Quoted prose.\\
    > A hard break.

    [guide]: https://example.org/docs
    """

    private func document(_ source: String, version: String = MarkdownPlan.version) throws -> BiparaDocument {
        let parsed = try MarkdownPlan.prepare(source, format: .markdown, plannerVersion: version)
        let plan = try #require(parsed)
        var document = BiparaDocument(documentID: UUID(), title: "Markdown fixture", source: source, sourceRevision: 1,
            requestedDirection: .enToZh, resolvedDirection: nil, paragraphs: plan.paragraphs, units: plan.units,
            translations: [], jobSnapshot: nil, layout: .sideBySide, readingAnchor: nil)
        document.markdownResolved = true
        document.requestedFormat = .auto
        document.readingMode = .rendered
        document.markdownPlan = plan
        return document
    }

    @Test func detectorUsesStrongOrCombinedSignals() throws {
        for text in ["A line of prose.", "1. One item", "https://example.org", "---", "# A title", "**one phrase**", "```\nunfinished",
                     "---\nAn ordinary line.\n---\n\nAnother line.", "---\nname: unclosed\n\nA line of prose."] {
            #expect(try MarkdownPlan.prepare(text, format: .auto) == nil)
        }
        for text in ["# Title\n\nBody", "```sh\necho hi\n```", "| A | B |\n|---|---|\n| one | two |", "- **One**\n- **Two**"] {
            #expect(try MarkdownPlan.prepare(text, format: .auto) != nil)
        }
        #expect(try MarkdownPlan.prepare("Body", format: .auto, markdownHint: true) != nil)
        #expect(try MarkdownPlan.prepare(rich, format: .plainText, markdownHint: true) == nil)
        let metadata = "---\r\nname: stable-id\r\ndescription: Read the guide.\r\n...\r\n\r\nOpen the window."
        #expect(try MarkdownPlan.prepare(metadata, format: .auto) != nil)
        #expect(try MarkdownPlan.prepare(metadata, format: .plainText) == nil)
    }

    @Test func structuredSourcePreservesLiteralsAndRoundTrips() throws {
        let source = rich.replacingOccurrences(of: "\n", with: "\r\n")
        var value = try document(source)
        let plan = try #require(value.markdownPlan)
        #expect(plan.units.allSatisfy { $0.kind == .markdownInline })
        #expect(plan.units.count == 12)
        #expect(plan.prose.contains("The next source line."))
        #expect(!plan.prose.contains("echo"))
        #expect(value.markdownProjection()?.groups.count == 3)
        value.translations = plan.units.map {
            UnitTranslation(unitID: $0.id, text: value.requestText(for: $0)!, completedAt: Date(timeIntervalSince1970: 0))
        }
        value.resolvedDirection = .enToZh
        value.jobSnapshot = JobSnapshot(jobID: UUID(), sourceRevision: 1, sourceLanguage: .en, targetLanguage: .zh,
            provider: "openai", model: "fixture", profile: "openai-json-schema-v2", effort: .low,
            translationPromptVersion: WorkerContract.markdownTranslationPromptVersion, alignmentPromptVersion: "alignment.v1")
        try plan.validateTranslations(value.translations, language: .zh)
        let exported = try #require(value.markdownExport(bilingual: false, plain: false, allowPartial: false))
        #expect(exported.contains("echo 'hello'\r\n"))
        #expect(exported.contains("[guide]: https://example.org/docs"))
        let decoded = try DocumentCodec.decode(DocumentCodec.encode(value))
        #expect(TextIdentity.equal(decoded.source, source))
        #expect(decoded.units == value.units)
        #expect(decoded.requestedFormat == .auto)
        #expect(decoded.markdownProjection()?.groups.map(\.id) == value.markdownProjection()?.groups.map(\.id))
    }

    @Test func invalidModelResultsCannotInjectStructureOrChangeLinks() throws {
        let value = try document("# Start\n\nRead **this** and [the guide](https://example.org).", version: "markdown-plan.v4")
        let unit = try #require(value.units.last)
        let plan = try #require(value.markdownPlan)
        for output in ["- **this** [guide](https://example.org)", "Read **this** and [guide](https://bad.example).",
                       "Read this and [guide](https://example.org).", "# **this** and [guide](https://example.org)"] {
            #expect(throws: GatewayError.self) {
                try plan.validateTranslations([.init(unitID: unit.id, text: output, completedAt: .now)], language: .zh)
            }
        }
    }

    @Test func markdownFailureDetailsPreserveReplyAndPointToTheChangedUnit() throws {
        let value = try document("# Title\n\nStart here.\n\n**Protocol.** Refactor this.\n\nFinish here.", version: "markdown-plan.v4")
        let plan = try #require(value.markdownPlan)
        let changed = plan.units[2]
        let newIDs = Set(plan.units.map(\.id))
        let unchanged = plan.units.map { UnitTranslation(unitID: $0.id, text: plan.requestText(for: $0)!, completedAt: .now) }

        var invalid = unchanged
        invalid[2].text = "**原则。**重构此处。"
        let inline = try #require(throws: MarkdownPlan.ValidationFailure.self) {
            try plan.validateBatch(invalid, language: .zh, newUnitIDs: newIDs)
        }
        #expect(inline.difference == .inlineStructure(expected: ["strong", "/"], received: []))
        #expect(inline.passages.map(\.id) == [changed.id])
        #expect(inline.passages.first?.input == "**Protocol.** Refactor this.")
        #expect(inline.passages.first?.reply == "**原则。**重构此处。")

        invalid = unchanged
        invalid[3].text = "# 完成"
        let block = try #require(throws: MarkdownPlan.ValidationFailure.self) {
            try plan.validateBatch(invalid, language: .zh, newUnitIDs: newIDs)
        }
        #expect(block.difference == .blockStructure(expected: ["paragraph"], received: ["heading:1"]))
        #expect(block.passages.map(\.unitNumber) == [4, 1, 2, 3])
        #expect(block.passages.first?.reply == "# 完成")
    }

    @Test func onlyStandaloneCodeMayMoveWithinItsOwnUnit() throws {
        let source = "Use `Bash` with `rg` when `Grep` and `Glob` are unavailable."
        let reply = "当会话没有 `Grep` 或 `Glob` 时，用带 `rg` 的 `Bash`。"
        for version in MarkdownPlan.supportedVersions {
            let value = try document(source, version: version)
            let plan = try #require(value.markdownPlan)
            let id = try #require(plan.units.first?.id)
            let translated = UnitTranslation(unitID: id, text: reply, completedAt: .now)
            if !["markdown-plan.v1", "markdown-plan.v2"].contains(version) {
                #expect(value.translationPromptVersion == (version == "markdown-plan.v3" ? "translation.markdown.v2" : version == "markdown-plan.v4" ? "translation.markdown.v4" : WorkerContract.markdownTranslationPromptVersion))
                try plan.validateBatch([translated], language: .zh, newUnitIDs: [id])
                var duplicate = translated
                duplicate.text = reply.replacingOccurrences(of: "`Glob`", with: "`Grep`")
                let error = try #require(throws: MarkdownPlan.ValidationFailure.self) {
                    try plan.validateBatch([duplicate], language: .zh, newUnitIDs: [id])
                }
                #expect(error.difference == .inlineStructure(expected: ["code:`Glob`"], received: ["code:`Grep`"]))
            } else {
                #expect(value.translationPromptVersion == "translation.markdown.v1")
                #expect(throws: GatewayError.self) { try plan.validateTranslations([translated], language: .zh) }
            }
        }

        for (original, damaged) in [
            (source, reply.replacingOccurrences(of: "`rg`", with: "")),
            (source, reply.replacingOccurrences(of: "`rg`", with: "`RG`")),
            ("Use `Café` then `B`.", "先 `B` 后 `Cafe\u{301}`。"),
            ("Use `A` **before** `B`.", "使用 `B` **然后** `A`。"),
            ("Use [`A`](https://example.org) then `B`.", "先用 [`B`](https://example.org) 再用 `A`。"),
            ("Use `A`.\\\nThen `B`.", "先用 `B`。\\\n再用 `A`。"),
        ] {
            let plan = try #require(try document(original, version: "markdown-plan.v4").markdownPlan)
            let id = try #require(plan.units.first?.id)
            #expect(throws: GatewayError.self) {
                try plan.validateTranslations([.init(unitID: id, text: damaged, completedAt: .now)], language: .zh)
            }
        }
    }

    @Test func codeSpansMayReorderOnlyBetweenTheSameMarkupBoundaries() throws {
        for (source, reply) in [
            ("Run `check` from `toolkit`. Then **review**.", "运行 `toolkit` 中的 `check`。然后 **审阅**。"),
            ("**Use `A` then `B` now**.", "**现在用 `B` 和 `A`**。"),
            ("See [use `A` and `B` here](https://example.org).", "见[此处使用 `B` 和 `A`](https://example.org)。"),
            ("Use `A` and `B` **here** then `C` and `D`.", "用 `B` 和 `A` **在此**，再用 `D` 和 `C`。"),
        ] {
            for version in ["markdown-plan.v3", "markdown-plan.v4"] {
                let plan = try #require(try document(source, version: version).markdownPlan)
                let id = try #require(plan.units.first?.id)
                let translation = UnitTranslation(unitID: id, text: reply, completedAt: .now)
                if version == "markdown-plan.v4" {
                    try plan.validateBatch([translation], language: .zh, newUnitIDs: [id])
                } else {
                    #expect(throws: GatewayError.self) { try plan.validateTranslations([translation], language: .zh) }
                }
            }
        }
        for (source, reply) in [
            ("Use `A` then **use `B` now**.", "使用 `B` 然后 **使用 `A`**。"),
            ("**Use `A` now** then **use `B` now**.", "**使用 `B`** 然后 **使用 `A`**。"),
            ("Use `A` and `B` then **review**.", "用 `B` 和 `B`，然后 **审阅**。"),
            ("Use `A` and `B` then **review**.", "用 `B` 和 `A`，然后 *审阅*。"),
            ("Use `A` and `B` then [review](https://example.org).", "用 `B` 和 `A`，然后[审阅](https://example.com)。"),
        ] {
            let plan = try #require(try document(source, version: "markdown-plan.v4").markdownPlan)
            let id = try #require(plan.units.first?.id)
            #expect(throws: GatewayError.self) {
                try plan.validateTranslations([.init(unitID: id, text: reply, completedAt: .now)], language: .zh)
            }
        }
    }

    @Test func offsetsAndReferencesFollowTheParsedDocument() throws {
        let cases: [(String, [String])] = [
            ("# Heading #\n\nA paragraph.", ["Heading", "A paragraph."]),
            ("# Title\n\n[guide]: https://example.org\n[Example][guide].", ["Title", "[Example][guide]."]),
            ("# Title\n\n[manual]:\n  https://example.org/manual\nRead [manual] now.", ["Title", "Read [manual][manual] now."]),
            ("# Title\n\n> [manual]:\n>   https://example.org/manual\n> Read [manual] now.", ["Title", "Read [manual][manual] now."]),
            ("# Title\n\n-\tExample.\n\tContinuation.", ["Title", "Example. Continuation."]),
            ("# Title\n\n> A **bold\n> wrapped phrase**.", ["Title", "A **bold wrapped phrase**."]),
            ("# Title\n\n> A **bold\\\n> broken phrase**.", ["Title", "A **bold\\\nbroken phrase**."]),
            ("# Title\n\n> [guide]: https://example.org\n\n[guide].", ["Title", "[guide][guide]."]),
        ]
        for (source, expected) in cases {
            let value = try document(source)
            let payloads = value.units.compactMap { value.requestText(for: $0) }
            #expect(payloads == expected, Comment(rawValue: source))
            let translations = zip(value.units, payloads).map {
                UnitTranslation(unitID: $0.id, text: $1, completedAt: .now)
            }
            try value.markdownPlan?.validateTranslations(translations, language: .en)
        }
        let invalidDefinition = try document("# Title\n\nProse.\n[a]: https://example.org\n\nRead [Guide][a].")
        #expect(invalidDefinition.units.compactMap { invalidDefinition.requestText(for: $0) } ==
            ["Title", "Prose. [a]: https://example.org", "Read [Guide][a]."])
    }

    @Test func tableCannotMoveContentAcrossCells() throws {
        let value = try document("# Title\n\n| X | Y |\n| - | - |\n| A\\|B | C |")
        let unit = try #require(value.units.first { value.requestText(for: $0) == "A\\|B" })
        #expect(throws: GatewayError.self) {
            try value.markdownPlan?.validateTranslations([.init(unitID: unit.id, text: "A|B", completedAt: .now)], language: .en)
        }
    }

    @Test func unavailablePlanStaysLiteralAndLegacyNeverRedetects() throws {
        let source = "# Title\n\nBody."
        var value = try document(source)
        let json = try #require(String(data: DocumentCodec.encode(value), encoding: .utf8))
        let unavailable = Data(json.replacingOccurrences(of: MarkdownPlan.version, with: "markdown-plan.future").utf8)
        let decoded = try DocumentCodec.decode(unavailable)
        #expect(decoded.isMarkdown && !decoded.canUseMarkdownPlan)
        #expect(decoded.markdownProjection()?.groups.first?.source.first?.runs.first?.text == source)
        #expect(decoded.markdownExport(bilingual: false, plain: false, allowPartial: false) == nil)
        let plain = try SourcePlanner.plan(source)
        value.markdownResolved = false
        value.markdownPlan = nil
        value.paragraphs = plain.paragraphs
        value.units = plain.units
        value.requestedFormat = .plainText
        let v3 = try #require(String(data: DocumentCodec.encode(value), encoding: .utf8))
        let v2 = Data(v3.replacingOccurrences(of: "\"schema_version\":3", with: "\"schema_version\":2").utf8)
        #expect(try !DocumentCodec.decode(v2).isMarkdown)
    }

    @Test func metadataTranslatesProseAndPreservesMachineFields() throws {
        let source = "---\r\nname: stable-id\r\ntitle: 'Reader''s guide' # keep comment\r\ndescription: Read the full guide.\r\nversion: 1\r\nconfig:\r\n  description: Nested value\r\n---\r\n\r\n# Body\r\n\r\nText."
        var value = try document(source)
        let plan = try #require(value.markdownPlan)
        #expect(plan.planVersion == MarkdownPlan.version)
        #expect(plan.units.compactMap(plan.requestText).prefix(2) == ["Reader's guide", "Read the full guide."])
        #expect(!plan.prose.contains("stable-id"))
        #expect(!plan.prose.contains("Nested value"))
        let translated = "说明: \"引号\" # 内容"
        value.translations = value.units.map { .init(unitID: $0.id, text: translated, completedAt: .now) }
        try plan.validateTranslations(value.translations, language: .zh)
        let exported = try #require(value.markdownExport(bilingual: false, plain: false, allowPartial: false))
        #expect(exported.contains("name: stable-id\r\n"))
        #expect(exported.contains("version: 1\r\nconfig:\r\n  description: Nested value\r\n"))
        #expect(exported.contains("title: " + MarkdownMetadata.quoted(translated) + " # keep comment\r\n"))
        #expect(exported.contains("description: " + MarkdownMetadata.quoted(translated) + "\r\n"))
        let plain = try #require(value.markdownExport(bilingual: false, plain: true, allowPartial: false))
        #expect(plain.contains("title: " + MarkdownMetadata.quoted(translated) + " # keep comment"))
        let reparsed = try #require(try MarkdownPlan.prepare(exported, format: .markdown))
        #expect(reparsed.units.compactMap(reparsed.requestText).prefix(2) == [translated, translated])
        for mode in [MarkdownReadingMode.source, .rendered] {
            value.readingMode = mode
            let target = value.markdownProjection()?.groups.first?.translation.flatMap(\.runs).map(\.text).joined() ?? ""
            #expect(target.contains(MarkdownMetadata.quoted(translated)))
            #expect(!target.contains("Read the full guide."))
        }
    }

    @Test func metadataSkipsComplexValuesAndDecodesQuotedStrings() throws {
        for scalar in ["|\n  Multiline prose", ">-\n  Folded prose", "&anchor Value", "*alias", "[one, two]", "true", "123", "One line\n  Continued line"] {
            let plan = try #require(try MarkdownPlan.prepare("---\ndescription: " + scalar + "\n---\n\n# Body\n\nText.", format: .markdown))
            #expect(plan.units.count == 2, Comment(rawValue: scalar))
        }
        for metadata in ["extra: {\ndescription: Keep nested prose unchanged\n}\ntitle: Main title", "extra: \"A multiline\ndescription: quoted text\"", "description: \"One\\n\\nTwo\"",
                         "extra: &keep \"A multiline\ndescription: still quoted text\"\ntitle: Main title",
                         "extra:\n  {\ndescription: Keep nested prose unchanged\n  }\ntitle: Main title",
                         "extra:\n  \"A multiline\ndescription: still quoted text\"\ntitle: Main title"] {
            let plan = try #require(try MarkdownPlan.prepare("---\n" + metadata + "\n---\n\n# Body\n\nText.", format: .markdown))
            #expect(plan.units.count == 2, Comment(rawValue: metadata))
        }
        let semantic = "Read \"quotes\" and C:\\files 😀"
        let source = "---\ndescription: " + MarkdownMetadata.quoted(semantic) + " # comment\n---\n"
        let plan = try #require(try MarkdownPlan.prepare(source, format: .markdown))
        #expect(plan.prose.contains("Read"))
        let unchanged = plan.units.map { UnitTranslation(unitID: $0.id, text: plan.requestText(for: $0)!, completedAt: .now) }
        try plan.validateTranslations(unchanged, language: .en)
        let quoted = MarkdownMetadata.quoted("冒号: # \"引号\"\n换行\t制表\\路径")
        #expect(try JSONDecoder().decode(String.self, from: Data(quoted.utf8)) == "冒号: # \"引号\"\n换行\t制表\\路径")
    }

    @Test func legacyMetadataPlansKeepSavedIdentitiesAndVersion() throws {
        let source = "---\ndescription: Read the guide.\n---\n\n# Body\n\nText."
        let legacy = try document(source, version: "markdown-plan.v1")
        #expect(legacy.units.count == 2)
        let encoded = try DocumentCodec.encode(legacy)
        let restored = try DocumentCodec.decode(encoded)
        #expect(restored.markdownPlan?.planVersion == "markdown-plan.v1")
        #expect(restored.units == legacy.units)
        #expect(restored.markdownProjection()?.groups.first?.source == legacy.markdownProjection()?.groups.first?.source)
        let savedAgain = try DocumentCodec.decode(DocumentCodec.encode(restored))
        #expect(savedAgain.units == legacy.units)
        #expect(savedAgain.markdownPlan?.planVersion == "markdown-plan.v1")
        #expect(try document(source).units.count == 3)
    }

    @Test func protectedCodeAndURLsCompareExactBytes() throws {
        let value = try document("# Title\n\nUse `Café` and [the link](https://example.org/Café).")
        let unit = try #require(value.units.last)
        let original = try #require(value.requestText(for: unit))
        let changed = original.decomposedStringWithCanonicalMapping
        #expect(!TextIdentity.equal(original, changed))
        #expect(throws: GatewayError.self) {
            try value.markdownPlan?.validateTranslations([.init(unitID: unit.id, text: changed, completedAt: .now)], language: .en)
        }
    }

    @Test func overDepthRejectedBeforeSwiftTreeConversion() throws {
        let deep = String(repeating: "> ", count: 130) + "Text"
        #expect(throws: CoreError.self) { try MarkdownPlan.prepare(deep, format: .markdown) }
    }
}

extension MarkdownPlanTests {
    private func prepared(_ source: String, _ reply: String) throws -> BiparaDocument {
        var value = try document(source)
        let plan = try #require(value.markdownPlan)
        let id = try #require(plan.units.first?.id)
        let batch = [UnitTranslation(unitID: id, text: reply, completedAt: Date(timeIntervalSince1970: 123))]
        value.translations = try plan.preparedBatch(batch, language: .zh, newUnitIDs: [id])
        return value
    }

    @Test func translatedLabelsRenderWithoutExposingDelimiters() throws {
        for (source, reply, visible) in [
            ("**Reply:** name one.", "**回复：**列出一项。", "回复：列出一项。"),
            ("Then **(optional)** continue.", "先**（可选）**再继续。", "先（可选）再继续。"),
            ("Use **C++** today.", "请用**C++**开发。", "请用C++开发。"),
            ("Use **+1** for approval.", "用**+1**表示认可。", "用+1表示认可。"),
            ("Then __reply__ again.", "请__回复__后继续。", "请回复后继续。"),
            ("**Outer *inner:*** continue.", "**外层 *内层：***继续。", "外层 内层：继续。"),
            ("*Note:* read it.", "*注：*阅读。", "注：阅读。"),
            ("***Reply:*** answer.", "***回复：***回答。", "回复：回答。"),
            ("**A:** first, **B:** second.", "**甲：**其一，**乙：**其二。", "甲：其一，乙：其二。"),
            ("**A:** first, *B:* second.", "**甲：**其一，*乙：*其二。", "甲：其一，乙：其二。"),
            ("**A:** keep `**x：**y` and [link](url_foo).", "**甲：**保留 `**x：**y` 和[链接](url_foo)。", "甲：保留 **x：**y 和链接。")
        ] {
            let value = try prepared(source, reply)
            let id = try #require(value.units.first?.id)
            #expect(value.visibleUnitText(id, side: .translation) == visible)
            let exported = try #require(value.markdownExport(bilingual: false, plain: false, allowPartial: false))
            #expect(try MarkdownInline(exported, references: .empty).visible == visible)
            #expect(value.markdownProjection()?.groups.first?.translation.first?.runs.contains { !$0.style.isEmpty } == true)
        }
        for (source, literal) in [
            ("Use **syntax**.", #"使用 \*\* 以及结尾 **"#),
            ("Calculate **this** expression.", "计算 2 * 3 ** 4"),
            ("Use **this** `**x：**y`.", "运行 `**x：**y`"),
            ("Read **this** [link](/p/**x：**y).", "打开[指南](/p/**x：**y)。"),
            ("Keep **bold** and the literal **原：**样.", "保留 **粗体** 和 **原：**样。"),
            ("Use **words** and some__raw__identifier.", "保留 some__raw__identifier。")
        ] {
            #expect(try prepared(source, literal).translations.first?.text == literal)
        }
    }

    @Test func emphasisCanFollowTranslatedWordOrderAndProtectedGroups() throws {
        for (source, reply) in [
            ("Use `A` and **use `B` now**.", "先用 `B`，再用 *`A`*。"),
            ("Read **this** before proceeding.", "先阅读此处。"),
            ("Read this before proceeding.", "**先**阅读此处。"),
            ("See [A](/a) then [B](/b).", "先见[乙](/b)，再见[甲](/a)。"),
            ("Read [guide](/guide \"User guide\").", "见[指南](</guide> \"用户指南\")。")
        ] {
            #expect(try prepared(source, reply).translations.first?.text == reply)
        }
        for (source, reply) in [
            ("Use [`A`](/guide), then `B`.", "使用[`B`](/guide)和 `A`。"),
            ("Use ~~`A`~~ and `B`.", "使用 ~~`B`~~ 和 `A`。"),
            ("Cancel ~~tomorrow~~.", "明天取消。"),
            ("Use `A`.\\\nThen `B`.", "先 `B`。\\\n再 `A`。"),
            ("Read `A` and `A`.", "阅读 `A`。"),
            ("Read [A][one].\n\n[one]: /same\n[two]: /same", "见[甲][two]。"),
            ("Read [use `]` here][one].\n\n[one]: /same\n[two]: /same", "见[看 `]`][two]。"),
            ("Read ![A](/photo).", "见[甲](/photo)。")
        ] {
            #expect(throws: MarkdownPlan.ValidationFailure.self) { _ = try prepared(source, reply) }
        }
    }

    @Test func blockIntroducersBecomeLiteralOnlyWhereTheyChangeTheBlock() throws {
        for (source, reply, exported) in [
            ("Read this.", "# 标题", "\\# 标题"),
            ("Read this.", "2. 阅读", "2\\. 阅读"),
            ("# Read this.", "# 标题", "# # 标题"),
            ("# Read this.", "指南 #", "# 指南 \\#"),
            ("# Read this. #", "指南 #", "# 指南 # #"),
            ("Read here.\\\nThen continue.", "这里。\\\n2. 继续", "这里。\\\n2. 继续"),
            ("- Read this.", "[x] 完成", "- \\[x] 完成"),
            ("- > Read this.", "[x] 完成", "- > [x] 完成"),
            ("Read here.", "见 2. 或 # 标题", "见 2. 或 # 标题"),
            ("Read here.\\\nThen continue.", "这里。\\\n# 继续", "这里。\\\n\\# 继续"),
            ("| Header |\n| --- |", "甲|乙\\|丙", "| 甲\\|乙\\|丙 |\n| --- |"),
            ("| Header |\n| --- |", #"甲\\|乙\\\|丙"#, "| " + #"甲\\\|乙\\\|丙"# + " |\n| --- |")
        ] {
            let value = try prepared(source, reply)
            #expect(value.markdownExport(bilingual: false, plain: false, allowPartial: false) == exported)
        }
    }

    @Test func canonicalTranslationsRoundTripAndKeepProviderAttribution() throws {
        var value = try prepared("**Reply:** name one.", "**回复：**列出一项。")
        let id = try #require(value.units.first?.id)
        value.resolvedDirection = .enToZh
        value.jobSnapshot = JobSnapshot(jobID: UUID(), sourceRevision: 1, sourceLanguage: .en, targetLanguage: .zh,
            provider: "openai", model: "fixture", profile: "openai-json-schema-v2", effort: .low,
            translationPromptVersion: "translation.markdown.v4", alignmentPromptVersion: "alignment.v1")
        let loaded = try DocumentCodec.decode(DocumentCodec.encode(value))
        #expect(loaded.translations == value.translations)
        #expect(loaded.jobSnapshot?.translationPromptVersion == "translation.markdown.v4")
        #expect(loaded.visibleUnitText(id, side: .translation) == "回复：列出一项。")
        #expect(loaded.markdownExport(bilingual: false, plain: false, allowPartial: false) == "**回复**：列出一项。")

        let legacy = try document("**First label.** More text.\n\n**Next:** continue.", version: "markdown-plan.v4")
        let old = try #require(legacy.markdownPlan)
        let upgraded = old.upgradedForRetry()
        #expect(upgraded.planVersion == "markdown-plan.v5")
        #expect(upgraded.units == old.units && upgraded.paragraphs == old.paragraphs)
        let complete = UnitTranslation(unitID: old.units[0].id, text: "**已完成。** 继续。", returnedModel: "first-model", completedAt: .distantPast)
        let next = UnitTranslation(unitID: old.units[1].id, text: "**下一步：**继续。", returnedModel: "next-model", completedAt: .distantFuture)
        let batch = try upgraded.preparedBatch([complete, next], language: .zh, newUnitIDs: [next.unitID])
        #expect(batch[0] == complete)
        #expect(batch[1].text == "**下一步**：继续。")
        #expect(batch[1].returnedModel == next.returnedModel && batch[1].completedAt == next.completedAt)
        #expect(try upgraded.preparedBatch(batch, language: .zh, newUnitIDs: [next.unitID]) == batch)
    }

    @Test func failedCanonicalizationReportsTheOriginalReply() throws {
        let value = try document("**Label:** keep `x`.")
        let plan = try #require(value.markdownPlan)
        let id = try #require(plan.units.first?.id)
        let raw = "**标签：**保留 `y`。"
        let error = try #require(throws: MarkdownPlan.ValidationFailure.self) {
            _ = try plan.preparedBatch([.init(unitID: id, text: raw, completedAt: .now)], language: .zh, newUnitIDs: [id])
        }
        #expect(error.passages.first?.reply == raw)
        #expect(error.difference == .inlineStructure(expected: ["code:`x`"], received: ["code:`y`"]))
    }
}

extension MarkdownPlanTests {
    @Test func tableReadingAndSelectionMatchTheExportedCell() throws {
        let raw = #"REPLACE `a\|b` then `c\\\|d` and p\\\|q [guide](/a\|b) [reference][r\|x] END"#
        let source = "| Head | Cell |\n|---|---|\n| " + raw + " | More |\n\n[r|x]: /reference\n\n" + #"Outside `a\|b`."#
        var value = try document(source)
        let plan = try #require(value.markdownPlan)
        let unit = try #require(plan.units.first { plan.requestText(for: $0) == raw })
        let translated = raw.replacingOccurrences(of: "REPLACE", with: "替换").replacingOccurrences(of: "END", with: "结束")
        let staged = plan.units.map { UnitTranslation(unitID: $0.id, text: $0.id == unit.id ? translated : plan.requestText(for: $0)!, completedAt: .now) }
        value.translations = try plan.preparedBatch(staged, language: .zh, newUnitIDs: Set(plan.units.map(\.id)))
        #expect(value.translations.first { $0.unitID == unit.id }?.text == translated)
        let exported = try #require(value.markdownExport(bilingual: false, plain: false, allowPartial: false))
        #expect(exported.contains(translated))
        let table = try #require(try MarkdownSource.parse(exported).child(at: 0) as? Table)
        let cell = try #require(table.body.child(at: 0)?.child(at: 0) as? Table.Cell)
        let externalCode = cell.children.compactMap { ($0 as? InlineCode)?.code }
        #expect(externalCode == ["a|b", #"c\\|d"#])
        let externalLinks = cell.children.compactMap { ($0 as? Link)?.destination }
        #expect(externalLinks.count == 2)
        let projected = try #require(value.markdownProjection())
        let target = try #require(projected.groups.flatMap(\.translation).first { $0.id == unit.paragraphID })
        let original = try #require(projected.groups.flatMap(\.source).first { $0.id == unit.paragraphID })
        #expect(target.runs.filter { $0.style.contains(.code) }.map(\.text) == externalCode)
        #expect(original.runs.filter { $0.style.contains(.code) }.map(\.text) == externalCode)
        #expect(target.runs.compactMap(\.destination) == externalLinks)
        let visible = #"替换 a|b then c\\|d and p\|q guide reference 结束"#
        #expect(value.visibleUnitText(unit.id, side: .translation) == visible)
        #expect(value.visibleUnitText(unit.id, side: .source) == visible.replacingOccurrences(of: "替换", with: "REPLACE").replacingOccurrences(of: "结束", with: "END"))
        let plain = try #require(value.markdownExport(bilingual: false, plain: true, allowPartial: false))
        #expect(plain.contains(visible))
        #expect(plain.contains(#"Outside a\|b."#))
        let last = try #require(target.runs.last)
        let range = try #require(last.visibleRange)
        #expect(visible.substring(utf16: range) == last.text)

        let unsafe = translated.replacingOccurrences(of: #"[reference][r\|x]"#, with: "reference")
        #expect(throws: MarkdownPlan.ValidationFailure.self) {
            _ = try plan.preparedBatch([.init(unitID: unit.id, text: unsafe, completedAt: .now)], language: .zh, newUnitIDs: [unit.id])
        }
    }

    @Test func leadingByteOrderMarkSurvivesMarkdownExportAsText() throws {
        let text = "\u{FEFF}开头"
        let value = try prepared("First sentence.", text)
        let id = try #require(value.units.first?.id)
        let exported = try #require(value.markdownExport(bilingual: false, plain: false, allowPartial: false))
        let actual = try #require(try MarkdownSource.parse(exported).child(at: 0) as? Paragraph)
        #expect(actual.plainText == text)
        #expect(value.visibleUnitText(id, side: .translation) == text)
    }
}
