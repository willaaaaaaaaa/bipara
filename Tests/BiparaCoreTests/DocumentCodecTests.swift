import Foundation
import Testing
@testable import BiparaCore

@Suite("Document codec (.bipara v1)")
struct DocumentCodecTests {
    private func makeDocument(
        source: String = "The window is open.\n",
        translated: Bool = true,
        resolved: Direction? = .enToZh,
        requested: Direction = .enToZh
    ) throws -> BiparaDocument {
        let plan = try SourcePlanner.plan(source)
        let units = plan.nonblankUnits
        let snapshot = JobSnapshot(
            jobID: UUID(),
            sourceRevision: 1,
            sourceLanguage: .en,
            targetLanguage: .zh,
            provider: "openai",
            model: "gpt-4.1-mini-2025-04-14",
            profile: "openai-json-schema-v1", effort: .auto,
            translationPromptVersion: "translation.v1",
            alignmentPromptVersion: "alignment.v1"
        )
        let translations = translated
            ? units.map { UnitTranslation(unitID: $0.id, text: "译\($0.sourceRange.location)", completedAt: Date(timeIntervalSince1970: 1_790_000_000)) }
            : []
        return BiparaDocument(
            documentID: UUID(),
            title: "The window is open.",
            source: source,
            sourceRevision: 1,
            requestedDirection: requested,
            resolvedDirection: translated ? resolved : nil,
            paragraphs: plan.paragraphs,
            units: plan.units,
            translations: translations,
            jobSnapshot: translated ? snapshot : nil,
            layout: .sideBySide,
            readingAnchor: plan.paragraphs.first.map { ReadingAnchor(paragraphID: $0.id, side: .source, fraction: 0) }
        )
    }

    @Test func completeDocumentRoundTrips() throws {
        let document = try makeDocument()
        let data = try DocumentCodec.encode(document)
        let decoded = try DocumentCodec.decode(data)
        #expect(decoded == document)
        #expect(decoded.jobSnapshot?.provider == "openai")
        #expect(decoded.translations.count == document.translations.count)
        // Field names match the v1 format exactly.
        let text = String(data: data, encoding: .utf8) ?? ""
        for key in ["\"format\"", "\"schema_version\"", "\"document_id\"", "\"source_revision\"",
                    "\"job_snapshot\"", "\"translation_prompt_version\"", "\"reading_anchor\"",
                    "\"separator_range\"", "\"unit_ids\"", "\"completed_at\""] {
            #expect(text.contains(key))
        }
        #expect(text.contains("\"format\":\"bipara\""))
    }

    @Test func emptyUntranslatedDocumentRoundTrips() throws {
        let document = try makeDocument(source: "", translated: false, resolved: nil, requested: .auto)
        let decoded = try DocumentCodec.decode(try DocumentCodec.encode(document))
        #expect(decoded.source.isEmpty)
        #expect(decoded.paragraphs.isEmpty && decoded.units.isEmpty)
        #expect(decoded.jobSnapshot == nil && decoded.resolvedDirection == nil)
        #expect(decoded.layout == .sideBySide)
    }

    @Test func partialDocumentRoundTripsPausedWork() throws {
        // Multi-paragraph source with only the first paragraph translated.
        let source = "第一段完整句子。\n\n第二段完整句子。\n"
        let plan = try SourcePlanner.plan(source)
        let firstUnit = plan.nonblankUnits[0]
        let snapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: 1,
            sourceLanguage: .zh, targetLanguage: .en,
            provider: "glm", model: "glm-4.7-flash", profile: "glm-json-v1", effort: .off,
            translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1"
        )
        let document = BiparaDocument(
            documentID: UUID(), title: "部分", source: source, sourceRevision: 1,
            requestedDirection: .zhToEn, resolvedDirection: .zhToEn,
            paragraphs: plan.paragraphs, units: plan.units,
            translations: [UnitTranslation(unitID: firstUnit.id, text: "First paragraph.", completedAt: Date(timeIntervalSince1970: 0))],
            jobSnapshot: snapshot, layout: .paragraphs, readingAnchor: nil
        )
        let decoded = try DocumentCodec.decode(try DocumentCodec.encode(document))
        #expect(decoded.translations.count == 1)
        #expect(decoded.jobSnapshot == snapshot)
        #expect(decoded.layout == .paragraphs)
    }

    @Test func duplicateDecodedKeysRejected() throws {
        let document = try makeDocument()
        var data = try DocumentCodec.encode(document)
        let text = String(data: data, encoding: .utf8)!
        let duplicated = text.replacingOccurrences(
            of: "\"format\":\"bipara\",",
            with: "\"format\":\"bipara\",\"\\u0066ormat\":\"bipara\","
        )
        data = Data(duplicated.utf8)
        #expect(throws: CoreError.self) { try DocumentCodec.decode(data) }
    }

    @Test func invalidVariantsRejected() throws {
        let base = try makeDocument()
        let encode: (BiparaDocument) throws -> Data = { try DocumentCodec.encode($0) }

        // Newer schema version.
        var newer = String(data: try encode(base), encoding: .utf8)!
        newer = newer.replacingOccurrences(of: "\"schema_version\":2", with: "\"schema_version\":3")
        #expect(throws: CoreError.self) { try DocumentCodec.decode(Data(newer.utf8)) }

        // Duplicate paragraph IDs (needs a multi-paragraph document).
        var twoParagraphs = try makeDocument(source: "One full sentence.\n\nTwo full sentence.\n")
        twoParagraphs.paragraphs[1].id = twoParagraphs.paragraphs[0].id
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(twoParagraphs)) }

        // Duplicate unit IDs across paragraphs.
        var dupUnits = try makeDocument(source: "One full sentence.\n\nTwo full sentence.\n")
        dupUnits.units[1].id = dupUnits.units[0].id
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(dupUnits)) }

        // Out-of-bounds range.
        var outOfBounds = base
        outOfBounds.paragraphs[0].sourceRange = TextRange(location: 0, length: 999)
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(outOfBounds)) }

        // Partial-grapheme range.
        var splitGrapheme = base
        splitGrapheme.source = "a👩🏽\u{200D}💻b\n"
        let emojiPlan = try SourcePlanner.plan(splitGrapheme.source)
        splitGrapheme.paragraphs = emojiPlan.paragraphs
        splitGrapheme.units = emojiPlan.units
        splitGrapheme.translations = []
        splitGrapheme.jobSnapshot = nil
        splitGrapheme.units[0].textRange = TextRange(location: 1, length: 1)
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(splitGrapheme)) }

        // Snapshot revision mismatch.
        var mismatched = base
        mismatched.jobSnapshot?.sourceRevision = 2
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(mismatched)) }

        // Translations without snapshot.
        var noSnapshot = base
        noSnapshot.jobSnapshot = nil
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(noSnapshot)) }

        // Empty title.
        var untitled = base
        untitled.title = ""
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(untitled)) }

        // Multiline title.
        var multiline = base
        multiline.title = "line one\nline two"
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(multiline)) }

        // Unit referencing unknown paragraph.
        var orphan = base
        orphan.units[0].paragraphID = UUID()
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(orphan)) }

        // Untrimmed translation text.
        var padded = base
        padded.translations[0].text = "  padded  "
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(padded)) }

        // Resolved direction contradicting the request.
        var contradicted = base
        contradicted.requestedDirection = .zhToEn
        contradicted.resolvedDirection = .enToZh
        contradicted.jobSnapshot?.sourceLanguage = .zh
        contradicted.jobSnapshot?.targetLanguage = .en
        #expect(throws: CoreError.self) { try DocumentCodec.decode(encode(contradicted)) }
    }

    @Test func truncatedUTF8AndOversizeRejected() throws {
        let data = try DocumentCodec.encode(try makeDocument())
        #expect(throws: CoreError.self) { try DocumentCodec.decode(data.dropFirst(10)) }
        #expect(throws: CoreError.self) {
            try DocumentCodec.decode(Data(repeating: 0x20, count: WorkerContract.documentFileByteLimit + 1))
        }
    }

    @Test func invalidReadingAnchorResetsToFirstParagraph() throws {
        var document = try makeDocument()
        document.readingAnchor = ReadingAnchor(paragraphID: UUID(), side: .translation, fraction: 2.0)
        let decoded = try DocumentCodec.decode(try DocumentCodec.encode(document))
        #expect(decoded.readingAnchor?.paragraphID == decoded.paragraphs.first?.id)
        #expect(decoded.readingAnchor?.fraction == 0)
        #expect(decoded.readingAnchor?.side == .source)
    }

    @Test func decodeIgnoresUnknownTopLevelFields() throws {
        let document = try makeDocument()
        var text = String(data: try DocumentCodec.encode(document), encoding: .utf8)!
        text = text.replacingOccurrences(of: "\"format\":\"bipara\"", with: "\"format\":\"bipara\",\"future_field\":{\"x\":1}")
        let decoded = try DocumentCodec.decode(Data(text.utf8))
        #expect(decoded.documentID == document.documentID)
    }

    @Test func snapshotWithUnavailablePromptStillOpens() throws {
        // Format rule: an old prompt/profile still opens for reading;
        // Resume gating is app policy, not codec policy.
        var document = try makeDocument()
        document.jobSnapshot?.translationPromptVersion = "translation.v0"
        document.jobSnapshot?.profile = "openai-json-v0"
        let decoded = try DocumentCodec.decode(try DocumentCodec.encode(document))
        #expect(decoded.jobSnapshot?.translationPromptVersion == "translation.v0")
        #expect(decoded.jobSnapshot?.profile == "openai-json-v0")
    }

    @Test func fractionalSecondTimestampsRoundTrip() throws {
        var document = try makeDocument()
        let precise = Date(timeIntervalSince1970: 1_790_000_000.567)
        document.translations[0].completedAt = precise
        let decoded = try DocumentCodec.decode(try DocumentCodec.encode(document))
        #expect(decoded == document)
        // Whole-second legacy stamps also decode.
        var text = String(data: try DocumentCodec.encode(document), encoding: .utf8)!
        if let range = text.range(of: #""completed_at":"[^"]*""#, options: .regularExpression) {
            text = text.replacingCharacters(in: range, with: #""completed_at":"2026-09-21T14:13:20Z""#)
        }
        let legacy = try DocumentCodec.decode(Data(text.utf8))
        #expect(legacy.translations[0].completedAt.timeIntervalSince1970 == 1_790_000_000)
    }

    @Test func titleLimitCountsUnicodeCharacters() throws {
        var document = try makeDocument()
        document.title = String(repeating: "\u{1F600}", count: 256)
        let decoded = try DocumentCodec.decode(try DocumentCodec.encode(document))
        #expect(decoded.title.unicodeScalars.count == 256)
        document.title = String(repeating: "\u{1F600}", count: 257)
        #expect(throws: CoreError.self) { try DocumentCodec.decode(try DocumentCodec.encode(document)) }
    }

    @Test func phantomAndZeroSeparatorParagraphsRejected() throws {
        var document = try makeDocument(source: "One full sentence.\nTwo full sentence.\n")

        // Phantom trailing paragraph (zero content, zero separator).
        document.paragraphs.append(PlannedParagraph(
            id: UUID(),
            sourceRange: TextRange(location: document.source.utf16.count, length: 0),
            separatorRange: TextRange(location: document.source.utf16.count, length: 0),
            unitIDs: []
        ))
        #expect(throws: CoreError.self) { try DocumentCodec.decode(try DocumentCodec.encode(document)) }

        // Zero-length separator on a non-final paragraph.
        var zeroSep = try makeDocument(source: "One full sentence.\nTwo full sentence.\n")
        zeroSep.paragraphs[0].separatorRange = TextRange(location: zeroSep.paragraphs[0].sourceRange.end ?? 0, length: 0)
        #expect(throws: CoreError.self) { try DocumentCodec.decode(try DocumentCodec.encode(zeroSep)) }
    }

    @Test func zeroLengthUnitRejected() throws {
        var document = try makeDocument(source: "One full sentence.\n")
        document.units[0].textRange = TextRange(location: document.units[0].textRange.location, length: 0)
        #expect(throws: CoreError.self) { try DocumentCodec.decode(try DocumentCodec.encode(document)) }
    }

    @Test func snapshotWithoutResolvedDirectionRejected() throws {
        var document = try makeDocument(translated: false)
        document.requestedDirection = .auto
        document.resolvedDirection = nil
        document.jobSnapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: 1,
            sourceLanguage: .en, targetLanguage: .zh,
            provider: "openai", model: "m", profile: "openai-json-schema-v1", effort: .auto,
            translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1"
        )
        #expect(throws: CoreError.self) { try DocumentCodec.decode(try DocumentCodec.encode(document)) }
    }

    // MARK: - Schema 2 with v1 reading compatibility (DOC-04)

    /// Serializes a document as schema 1 by stripping the v2 snapshot
    /// `effort` field, mirroring what the previous app version wrote.
    private func v1Data(from document: BiparaDocument) throws -> Data {
        var text = String(data: try DocumentCodec.encode(document), encoding: .utf8)!
        text = text.replacingOccurrences(of: "\"schema_version\":2", with: "\"schema_version\":1")
        if let range = text.range(of: #""effort":"[a-z]+","#, options: .regularExpression) {
            text = text.replacingCharacters(in: range, with: "")
        }
        return Data(text.utf8)
    }

    @Test func v1OpenAISnapshotDerivesAutoAndKeepsLegacyProfile() throws {
        let base = try makeDocument()
        let decoded = try DocumentCodec.decode(try v1Data(from: base))
        #expect(decoded.jobSnapshot?.effort == .auto)
        #expect(decoded.jobSnapshot?.profile == "openai-json-schema-v1")
        #expect(decoded.jobSnapshot?.model == base.jobSnapshot?.model)
        #expect(decoded.translations.map(\.text) == base.translations.map(\.text))
        #expect(decoded.documentID == base.documentID)
        #expect(decoded.sourceRevision == base.sourceRevision)
        // The original v1 bytes are not rewritten: an explicit save writes
        // schema 2 with the derived effort.
        let saved = try DocumentCodec.decode(try DocumentCodec.encode(decoded))
        #expect(saved.jobSnapshot?.effort == .auto)
        #expect(String(data: try DocumentCodec.encode(decoded), encoding: .utf8)!.contains("\"schema_version\":2"))
    }

    @Test func v1GLMSnapshotDerivesOff() throws {
        let source = "第一段完整句子。\n"
        let plan = try SourcePlanner.plan(source)
        var document = try makeDocument()
        document.source = source
        document.paragraphs = plan.paragraphs
        document.units = plan.units
        document.translations = plan.nonblankUnits.map {
            .init(unitID: $0.id, text: "译文", completedAt: Date(timeIntervalSince1970: 0))
        }
        document.jobSnapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: 1,
            sourceLanguage: .zh, targetLanguage: .en,
            provider: "glm", model: "glm-4.7-flash", profile: "glm-json-v1", effort: .off,
            translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1")
        document.requestedDirection = .zhToEn
        document.resolvedDirection = .zhToEn
        let decoded = try DocumentCodec.decode(try v1Data(from: document))
        #expect(decoded.jobSnapshot?.effort == .off)
        #expect(decoded.jobSnapshot?.profile == "glm-json-v1")
    }

    @Test func v1UnknownOldProfileReadsAsUnspecifiedAuto() throws {
        var document = try makeDocument()
        document.jobSnapshot?.profile = "openai-json-v0"
        let decoded = try DocumentCodec.decode(try v1Data(from: document))
        // Readable for reading; unavailable for model calls is app policy.
        #expect(decoded.jobSnapshot?.profile == "openai-json-v0")
        #expect(decoded.jobSnapshot?.effort == .auto)
    }

    @Test func v2SnapshotWithoutEffortRejected() throws {
        let base = try makeDocument()
        var text = String(data: try DocumentCodec.encode(base), encoding: .utf8)!
        guard let range = text.range(of: #""effort":"[a-z]+","#, options: .regularExpression) else {
            Issue.record("effort field not found in encoded snapshot")
            return
        }
        text = text.replacingCharacters(in: range, with: "")
        #expect(throws: CoreError.self) { try DocumentCodec.decode(Data(text.utf8)) }
    }

    @Test func v2SnapshotEffortRoundTripsAndCapabilitiesValidate() throws {
        var document = try makeDocument()
        document.jobSnapshot?.profile = "glm-json-v2"
        document.jobSnapshot?.provider = "glm"
        document.jobSnapshot?.model = "glm-5.3-flash"
        document.jobSnapshot?.effort = .low
        let decoded = try DocumentCodec.decode(try DocumentCodec.encode(document))
        #expect(decoded.jobSnapshot?.effort == .low)
        // An effort unsupported by the model is rejected in a v2 file.
        document.jobSnapshot?.effort = .off
        #expect(throws: CoreError.self) { try DocumentCodec.decode(try DocumentCodec.encode(document)) }
        // A legacy profile requires its original effective effort in v2.
        var legacy = try makeDocument()
        legacy.jobSnapshot?.effort = .low
        #expect(throws: CoreError.self) { try DocumentCodec.decode(try DocumentCodec.encode(legacy)) }
    }

    @Test func portableFilesExcludePrivateRuntimeBinding() throws {
        let document = try makeDocument()
        let text = String(data: try DocumentCodec.encode(document), encoding: .utf8)!
        // No endpoint, display alias, local configuration ID, or key material.
        #expect(!text.contains("api.openai.com"))
        #expect(!text.contains("base_url"))
        #expect(!text.contains("display_name"))
        #expect(!text.contains("configuration_id"))
        #expect(!text.contains("keychain"))
        #expect(!text.contains("SYNTHETIC"))
    }
}
