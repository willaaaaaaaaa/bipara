import Foundation
import Testing
@testable import BiparaCore

struct MarkdownFragmentJoinTests {
    private let longProse = String(repeating: "word ", count: WorkerContract.maxBatchTextBytes / 5)

    private func fixture(_ source: String, replies: [String], language: Language = .zh,
                         version: String = MarkdownPlan.version) throws -> (MarkdownPlan, BiparaDocument) {
        let plan = try #require(try MarkdownPlan.prepare(source, format: .markdown, plannerVersion: version))
        let direction: Direction = language == .zh ? .enToZh : .zhToEn
        var document = BiparaDocument(documentID: UUID(), title: "Fragment fixture", source: source, sourceRevision: 1,
            requestedDirection: direction, resolvedDirection: direction, paragraphs: plan.paragraphs, units: plan.units,
            translations: [], jobSnapshot: nil, layout: .sideBySide, readingAnchor: nil)
        document.markdownResolved = true
        document.requestedFormat = .markdown
        document.readingMode = .rendered
        document.markdownPlan = plan
        document.jobSnapshot = JobSnapshot(jobID: UUID(), sourceRevision: 1, sourceLanguage: language == .zh ? .en : .zh, targetLanguage: language,
            provider: "openai", model: "fixture", profile: "openai-json-schema-v2", effort: .low,
            translationPromptVersion: document.translationPromptVersion, alignmentPromptVersion: "alignment.v1")
        try #require(plan.units.count == replies.count)
        document.translations = zip(plan.units, replies).map { .init(unitID: $0.id, text: $1, completedAt: .now) }
        return (plan, document)
    }

    @Test func literalFragmentsKeepTheirTextAndStyleInTheReaderAndMarkdown() throws {
        for (language, left, right, expected) in [
            (Language.zh, "左*字", "右*尾", "左*字右*尾"),
            (.zh, "左[名称]", "(https://example.org)尾", "左[名称](https://example.org)尾"),
            (.zh, "左`", "右`尾", "左`右`尾"),
            (.zh, "左\\", "*右", "左\\*右"),
            (.zh, "左&am", "p;右", "左&amp;右"),
            (.en, "left *middle", "middle* end", "left *middle middle* end"),
            (.en, "first", "second", "first second"),
        ] {
            let (plan, doc) = try fixture(longProse + "tail", replies: [left, right], language: language)
            try plan.validateBatch(doc.translations, language: language, newUnitIDs: [plan.units[1].id])
            let reopened = try DocumentCodec.decode(DocumentCodec.encode(doc))
            let plain = try #require(reopened.markdownExport(bilingual: false, plain: true, allowPartial: false))
            #expect(plain == expected)
            let rendered = try #require(reopened.markdownProjection()?.groups.first?.translation.first?.runs)
            #expect(rendered.map(\.text).joined() == expected)
            #expect(rendered.allSatisfy { $0.style.isEmpty && $0.destination == nil })
            let markdown = try #require(reopened.markdownExport(bilingual: false, plain: false, allowPartial: false))
            var sourceMode = reopened
            sourceMode.readingMode = .source
            #expect(sourceMode.markdownProjection()?.groups.first?.translation.first?.runs.map(\.text).joined() == markdown)
            let reparsed = try #require(try MarkdownPlan.prepare(markdown, format: .markdown))
            let exportedRuns = try #require(reparsed.projection(translations: [], language: language, mode: .rendered).groups.first?.source.first?.runs)
            #expect(exportedRuns.map(\.text).joined() == expected)
            #expect(exportedRuns.allSatisfy { $0.style.isEmpty && $0.destination == nil })
        }
    }

    @Test func splitTableCellPreservesABackslashBeforeAnEscapedPipe() throws {
        let source = "| Value |\n| --- |\n| " + longProse + "tail |"
        let (plan, doc) = try fixture(source, replies: ["值", #"始\"#, #"\|数"#])
        try plan.validateTranslations(doc.translations, language: .zh)
        let reopened = try DocumentCodec.decode(DocumentCodec.encode(doc))
        let markdown = try #require(reopened.markdownExport(bilingual: false, plain: false, allowPartial: false))
        let reparsed = try #require(try MarkdownPlan.prepare(markdown, format: .markdown))
        let preview = try #require(reopened.markdownProjection()?.groups.last?.translation.last)
        let exported = try #require(reparsed.projection(translations: [], language: .zh, mode: .rendered).groups.last?.source.last)
        #expect(preview.runs.map(\.text).joined() == #"始\|数"#)
        #expect(exported.runs.map(\.text).joined() == #"始\|数"#)
    }

    @Test func adjacentMatchingEmphasisCanShareOneSpanInTheExport() throws {
        for (a, b, style) in [("**", "**", MarkdownReadingRun.Style.bold), ("*", "*", .italic), ("_", "_", .italic), ("**", "__", .bold)] {
            let (plan, doc) = try fixture(a + "left" + a + " " + longProse + b + "right" + b,
                                          replies: [a + "粗" + a, b + "体" + b])
            try plan.validateTranslations(doc.translations, language: .zh)
            let reopened = try DocumentCodec.decode(DocumentCodec.encode(doc))
            let markdown = try #require(reopened.markdownExport(bilingual: false, plain: false, allowPartial: false))
            let reparsed = try #require(try MarkdownPlan.prepare(markdown, format: .markdown))
            let runs = try #require(reparsed.projection(translations: [], language: .zh, mode: .rendered).groups.first?.source.first?.runs)
            #expect(runs.map(\.text).joined() == "粗体")
            #expect(runs.allSatisfy { $0.style == style })
        }
    }

    @Test func literalStarsBetweenProtectedCodeSpansStayLiteral() throws {
        let (plan, doc) = try fixture("`a` " + longProse + "`b` tail", replies: ["`a` 前*段", "后*段 `b`"])
        try plan.validateTranslations(doc.translations, language: .zh)
        let markdown = try #require(doc.markdownExport(bilingual: false, plain: false, allowPartial: false))
        let reparsed = try #require(try MarkdownPlan.prepare(markdown, format: .markdown))
        let runs = try #require(reparsed.projection(translations: [], language: .zh, mode: .rendered).groups.first?.source.first?.runs)
        #expect(runs.map(\.text).joined() == "a 前*段后*段 b")
        #expect(runs.filter { $0.style == .code }.map(\.text) == ["a", "b"])
        #expect(runs.allSatisfy { !$0.style.contains(.italic) })
    }

    @Test func inlineEmphasisKeepsItsVisibleExtentAtAChineseWordBoundary() throws {
        let (plan, doc) = try fixture(longProse + "_italic_ tail", replies: ["甲", "_乙_"])
        try plan.validateTranslations(doc.translations, language: .zh)
        let markdown = try #require(doc.markdownExport(bilingual: false, plain: false, allowPartial: false))
        let reparsed = try #require(try MarkdownPlan.prepare(markdown, format: .markdown))
        let runs = try #require(reparsed.projection(translations: [], language: .zh, mode: .rendered).groups.first?.source.first?.runs)
        #expect(runs.map(\.text) == ["甲", "乙"])
        #expect(runs.map(\.style) == [[], .italic])
    }

    @Test func adjacentProtectedSpansCannotSilentlyMergeWhenAFragmentCompletes() throws {
        let source = "`a` " + longProse + "`b` tail\n\nOther block."
        let (plan, doc) = try fixture(source, replies: ["`a`", "`b`", "另一段。"])
        let first = plan.units[0].id
        let second = plan.units[1].id
        let other = plan.units[2].id
        try plan.validateBatch([doc.translations[0], doc.translations[2]], language: .zh, newUnitIDs: [first, other])
        let error = try #require(throws: MarkdownPlan.ValidationFailure.self) {
            try plan.validateBatch(doc.translations, language: .zh, newUnitIDs: [second, other])
        }
        #expect(error.passages.map(\.id) == [second])
        #expect(throws: GatewayError.self) { try DocumentCodec.decode(DocumentCodec.encode(doc)) }

        let (legacy, previous) = try fixture(source, replies: ["`a`", "`b`", "另一段。"], version: "markdown-plan.v4")
        try legacy.validateTranslations(previous.translations, language: .zh)
    }

    @Test func hardBreakAndInlineCodeSurviveAFragmentJoin() throws {
        let source = "one\\\ntwo `a` " + longProse + "tail"
        let (plan, doc) = try fixture(source, replies: ["甲\\\n乙 `a`", "尾"])
        try plan.validateTranslations(doc.translations, language: .zh)
        let reopened = try DocumentCodec.decode(DocumentCodec.encode(doc))
        #expect(reopened.markdownExport(bilingual: false, plain: true, allowPartial: false) == "甲\n乙 a尾")
        #expect(reopened.markdownExport(bilingual: false, plain: false, allowPartial: false) == "甲\\\n乙 `a`尾")
    }
}
