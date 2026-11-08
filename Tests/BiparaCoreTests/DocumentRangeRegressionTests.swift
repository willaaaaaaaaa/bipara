import Foundation
import Testing
@testable import BiparaCore

/// Core document integrity and range regressions.
@Suite("Core document and range regressions")
struct DocumentRangeRegressionTests {
    // MARK: preceding-context traversal

    @Test func leadingIndentationDoesNotCrashContext() throws {
        // First unit text begins at 1; the old backward walk decremented
        // below startIndex and trapped.
        let plan = try SourcePlanner.plan(" Hello")
        let batches = try SourcePlanner.formBatches(plan)
        #expect(!batches.isEmpty)
        // The single leading space is valid preceding context within the
        // byte cap; the fix is that traversal no longer traps on it.
        #expect(batches[0].contextBefore == " ")
    }

    @Test func contextClippingIsExactAndWholeCluster() throws {
        // Direct helper checks with hand-computable expected slices.
        // The ZWJ emoji sequence is one grapheme cluster of 15 UTF-8 bytes
        // (4 + 4 + 3 + 4) and 7 UTF-16 units.
        let cjk170 = String(repeating: "汉", count: 170)   // 510 bytes
        let cjk165 = String(repeating: "汉", count: 165)   // 495 bytes
        let emoji = "👩🏽\u{200D}💻"
        let limit = WorkerContract.maxContextBytes

        // Pure CJK: 200 chars = 600 bytes; 170 chars = 510 <= 512 < 513.
        let beforeCJK = String(repeating: "汉", count: 200) + "M"
        let cut = beforeCJK.utf16.count - 1
        #expect(SourcePlanner.clippedContext(source: beforeCJK, before: cut, limit: limit) == cjk170)

        // Whole-cluster clipping at the FAR end: the nearest clusters are
        // kept, so the emoji (15) plus 165 CJK (495) = 510 fits and only
        // the OLDEST CJK clusters are dropped; the emoji is never split.
        let beforeEmoji = String(repeating: "汉", count: 200) + emoji + "M"
        let emojiCut = beforeEmoji.utf16.count - 1
        #expect(SourcePlanner.clippedContext(source: beforeEmoji, before: emojiCut, limit: limit) == cjk165 + emoji)

        // Following context: same budgets forward; the emoji cluster stays
        // whole at the near end, far-end CJK is dropped.
        let afterCJK = "M" + String(repeating: "汉", count: 200)
        #expect(SourcePlanner.clippedContext(source: afterCJK, after: 1, limit: limit) == cjk170)
        let afterEmoji = "M" + emoji + String(repeating: "汉", count: 200)
        #expect(SourcePlanner.clippedContext(source: afterEmoji, after: 1, limit: limit) == emoji + cjk165)

        // Document start / end never walk out of bounds.
        #expect(SourcePlanner.clippedContext(source: beforeCJK, before: 0, limit: limit) == "")
        #expect(SourcePlanner.clippedContext(source: afterCJK, after: afterCJK.utf16.count, limit: limit) == "")
    }

    @Test func middleBatchesCarryExactContiguousContexts() throws {
        // A multi-batch plan with CJK and composed emoji around the cut
        // points: middle batches must have nonempty contexts on both
        // sides, within the byte budget, and contiguous with the batch's
        // units in the exact source (verified by re-slicing the source at
        // the unit boundaries, not by substring search).
        // Proven batch-producing fixture shape (see batchBoundsHold),
        // scaled to guarantee >= 3 batches.
        let sentences = (0..<120).map { index in
            "第\(index)句，" + String(repeating: "批次边界测试内容", count: 8) + "。"
        }
        let source = sentences.joined(separator: "\n")
        let plan = try SourcePlanner.plan(source)
        let batches = try SourcePlanner.formBatches(plan)
        #expect(batches.count >= 3)
        let unitByID = Dictionary(uniqueKeysWithValues: plan.units.map { ($0.id, $0) })

        // A middle batch with nonempty contexts on both sides must exist;
        // this is the setup precondition, asserted unconditionally.
        let middleIndex = batches.firstIndex { batch in
            guard let first = unitByID[batch.unitIDs.first!],
                  let last = unitByID[batch.unitIDs.last!] else { return false }
            return first.textRange.location > 0
                && (last.textRange.end ?? 0) < source.utf16.count
                && !batch.contextBefore.isEmpty
                && !batch.contextAfter.isEmpty
        }
        guard let middleUnwrapped = middleIndex else {
            Issue.record("no middle batch with two-sided contexts")
            return
        }
        let middle = batches[middleUnwrapped]

        // Byte budget holds for every batch.
        for batch in batches {
            #expect(TextIdentity.utf8Length(batch.contextBefore) <= 512)
            #expect(TextIdentity.utf8Length(batch.contextAfter) <= 512)
        }

        // Contexts are the exact contiguous source slices adjacent to the
        // batch's first/last unit texts (code-unit identity).
        let first = unitByID[middle.unitIDs.first!]!
        let last = unitByID[middle.unitIDs.last!]!
        let expectedBefore = source.substring(utf16: TextRange(
            location: first.textRange.location - middle.contextBefore.utf16.count,
            length: middle.contextBefore.utf16.count
        ))
        #expect(expectedBefore != nil)
        #expect(TextIdentity.equal(expectedBefore!, middle.contextBefore))
        let expectedAfter = source.substring(utf16: TextRange(
            location: last.textRange.end ?? 0,
            length: middle.contextAfter.utf16.count
        ))
        #expect(expectedAfter != nil)
        #expect(TextIdentity.equal(expectedAfter!, middle.contextAfter))

        // The first batch's preceding context is exactly the leading
        // whitespace of the document (no earlier text exists).
        let firstBatch = batches[0]
        let firstUnit = unitByID[firstBatch.unitIDs.first!]!
        let prefix = source.substring(utf16: TextRange(location: 0, length: firstUnit.textRange.location)) ?? ""
        #expect(TextIdentity.equal(prefix, firstBatch.contextBefore))
    }

    // MARK: document-global fragment ranges in later paragraphs

    @Test func oversizedUnitInLaterParagraphKeepsGlobalRanges() throws {
        let source = "x\n" + String(repeating: "a", count: 1500)
        let plan = try SourcePlanner.plan(source)
        #expect(plan.paragraphs.count == 2)
        let second = plan.paragraphs[1]
        let fragments = plan.units.filter { $0.paragraphID == second.id }
        #expect(fragments.count >= 2)
        for fragment in fragments {
            #expect(fragment.textRange.location >= second.sourceRange.location)
            #expect(fragment.textRange.isWithin(second.sourceRange))
            #expect(fragment.sourceRange.isWithin(second.sourceRange))
            #expect(fragment.textRange.isWithin(fragment.sourceRange))
        }
        // Planning → batching → codec round trip all work on the same plan.
        let batches = try SourcePlanner.formBatches(plan)
        #expect(!batches.isEmpty)
        var document = BiparaDocument(
            documentID: UUID(), title: "t", source: source, sourceRevision: 1,
            requestedDirection: .enToZh, resolvedDirection: .enToZh,
            paragraphs: plan.paragraphs, units: plan.units, translations: [],
            jobSnapshot: nil, layout: .sideBySide, readingAnchor: nil
        )
        try DocumentCodec.validate(&document)
        let decoded = try DocumentCodec.decode(try DocumentCodec.encode(document))
        #expect(decoded == document)
    }

    // MARK: whitespace split preference with trimmed text

    @Test func whitespaceBoundaryPreferredOverMidWordSplit() throws {
        // Ordinary whitespace AND the four contract-whitespace separators
        // (U+001C-U+001F) that the shared trim set treats as boundaries.
        // For every separator the planner must split on whole-word
        // boundaries, never "hell" / "o".
        let separators = [" ", "\t", "\u{1C}", "\u{1D}", "\u{1E}", "\u{1F}", "  "]
        for separator in separators {
            let source = (0..<300).map { _ in "hello" }.joined(separator: separator)
            let plan = try SourcePlanner.plan(source)
            #expect(plan.units.count >= 2)
            for fragment in plan.units {
                let text = plan.source.substring(utf16: fragment.textRange) ?? ""
                #expect(TextIdentity.utf8Length(text) <= 1024)
                #expect(text.isContractTrimmed)
                // Whole words only. The "  " entry is a two-Character
                // whitespace run (not one multi-scalar grapheme), pinning
                // the run case alongside the single-cluster separators.
                let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{1C}" || $0 == "\u{1D}" || $0 == "\u{1E}" || $0 == "\u{1F}" })
                #expect(!words.isEmpty)
                #expect(words.allSatisfy { $0 == "hello" })
            }
            // Planner → codec agreement for each separator family.
            var document = BiparaDocument(
                documentID: UUID(), title: "ws", source: source, sourceRevision: 1,
                requestedDirection: .enToZh, resolvedDirection: .enToZh,
                paragraphs: plan.paragraphs, units: plan.units, translations: [],
                jobSnapshot: nil, layout: .sideBySide, readingAnchor: nil
            )
            try DocumentCodec.validate(&document)
        }
    }

    @Test func whitespaceRunAboveLimitStaysBoundaryWhitespace() throws {
        // start + 2000 spaces + end: neither piece's text contains the run.
        let source = "start" + String(repeating: " ", count: 2000) + "end"
        let plan = try SourcePlanner.plan(source)
        let texts = plan.units.map { plan.source.substring(utf16: $0.textRange) ?? "" }
        #expect(texts.contains("start"))
        #expect(texts.contains("end"))
        for text in texts {
            #expect(TextIdentity.utf8Length(text) <= 1024)
        }
    }

    @Test func punctuationStillPreferredOverWhitespace() throws {
        // 长×340 + "，" + 短×340 + "。": splits land on punctuation first.
        let source = String(repeating: "长", count: 340) + "，" + String(repeating: "短", count: 340) + "。"
        let plan = try SourcePlanner.plan(source)
        let fragments = plan.units
        #expect(fragments.count >= 2)
        for fragment in fragments.dropLast() {
            let text = plan.source.substring(utf16: fragment.textRange) ?? ""
            #expect(text.hasSuffix("，") || text.hasSuffix("。") || text.hasSuffix("， "))
        }
        for fragment in fragments {
            let text = plan.source.substring(utf16: fragment.textRange) ?? ""
            #expect(TextIdentity.utf8Length(text) <= 1024)
            #expect(text.isContractTrimmed)
        }
    }

    // MARK: T1 — real oversized single grapheme

    @Test func oversizedSingleGraphemeIsExplicitError() {
        // "a" + 600 combining acutes is ONE composed character of 1201
        // UTF-8 bytes: un-splittable, explicitly unsupported.
        let source = "a" + String(repeating: "\u{0301}", count: 600)
        do {
            _ = try SourcePlanner.plan(source)
            Issue.record("expected unsupportedInput")
        } catch let error as CoreError {
            guard case .unsupportedInput = error else {
                Issue.record("wrong error kind: \(error)")
                return
            }
            #expect(true)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: ill-formed stored ranges are rejected, never crash

    @Test func negativeAndIllFormedRangesRejectedWithoutCrash() throws {
        let base = try makeBaseDocument(source: "abc")
        for range in [
            TextRange(location: 1, length: -1),
            TextRange(location: -1, length: 1),
            TextRange(location: 3, length: -3),
            TextRange(location: Int.max - 2, length: 10),
        ] {
            var document = base
            document.units[0].textRange = range
            #expect(throws: CoreError.self) {
                try DocumentCodec.decode(try DocumentCodec.encode(document))
            }
        }
        // Paragraph ranges too.
        var paragraphCase = base
        paragraphCase.paragraphs[0].separatorRange = TextRange(location: 3, length: -1)
        #expect(throws: CoreError.self) {
            try DocumentCodec.decode(try DocumentCodec.encode(paragraphCase))
        }
    }

    // MARK: inner range must be the exact trimmed core

    @Test func textRangeHidingNonwhitespaceSourceRejected() throws {
        var document = try makeBaseDocument(source: "abc")
        document.units[0].sourceRange = TextRange(location: 0, length: 3)
        document.units[0].textRange = TextRange(location: 0, length: 1)  // hides "bc"
        #expect(throws: CoreError.self) {
            try DocumentCodec.decode(try DocumentCodec.encode(document))
        }
        // Boundary-whitespace-only exclusion stays valid.
        var valid = try makeBaseDocument(source: "  abc  ")
        let unit = valid.units[0]
        let full = valid.source.substring(utf16: unit.sourceRange) ?? ""
        let (leading, core, _) = full.trimmingWhitespaceSplit()
        valid.units[0].textRange = TextRange(
            location: unit.sourceRange.location + leading.utf16.count,
            length: core.utf16.count
        )
        #expect(throws: Never.self) {
            _ = try DocumentCodec.decode(try DocumentCodec.encode(valid))
        }
    }

    // MARK: empty completed translation rejected

    @Test func emptyTranslationRejected() throws {
        var document = try makeBaseDocument(source: "abc", translated: true)
        document.translations[0].text = ""
        #expect(throws: CoreError.self) {
            try DocumentCodec.decode(try DocumentCodec.encode(document))
        }
    }

    // MARK: explicit nulls and required presence

    @Test func encodedNullablesAreExplicit() throws {
        let document = try makeBaseDocument(source: "abc", translated: false)
        let text = String(data: try DocumentCodec.encode(document), encoding: .utf8) ?? ""
        #expect(text.contains("\"job_snapshot\":null"))
        #expect(text.contains("\"reading_anchor\":null"))
        #expect(text.contains("\"resolved\":null"))
        // A translated document writes explicit null returned_model.
        var translated = try makeBaseDocument(source: "abc", translated: true)
        translated.translations[0].returnedModel = nil
        let translatedText = String(data: try DocumentCodec.encode(translated), encoding: .utf8) ?? ""
        #expect(translatedText.contains("\"returned_model\":null"))
    }

    @Test func missingRequiredNullableFieldsRejectedExplicitNullAccepted() throws {
        let document = try makeBaseDocument(source: "abc", translated: false)
        let good = String(data: try DocumentCodec.encode(document), encoding: .utf8)!
        #expect(throws: Never.self) { _ = try DocumentCodec.decode(Data(good.utf8)) }

        // Remove the required nullable job_snapshot key entirely.
        let missingSnapshot = good.replacingOccurrences(of: ",\"job_snapshot\":null", with: "")
        #expect(!missingSnapshot.contains("job_snapshot"))
        #expect(throws: CoreError.self) { _ = try DocumentCodec.decode(Data(missingSnapshot.utf8)) }

        // Remove reading_anchor.
        let missingAnchor = good.replacingOccurrences(of: ",\"reading_anchor\":null", with: "")
        #expect(throws: CoreError.self) { _ = try DocumentCodec.decode(Data(missingAnchor.utf8)) }

        // Remove direction.resolved (last key inside its object, so the
        // comma precedes it).
        let missingResolved = good.replacingOccurrences(of: ",\"resolved\":null", with: "")
        #expect(!missingResolved.contains("\"resolved\""))
        #expect(throws: CoreError.self) { _ = try DocumentCodec.decode(Data(missingResolved.utf8)) }

        // Unknown v1 extra fields remain tolerated.
        let extended = good.replacingOccurrences(
            of: "\"format\":\"bipara\"",
            with: "\"format\":\"bipara\",\"future\":{\"x\":1}"
        )
        #expect(throws: Never.self) { _ = try DocumentCodec.decode(Data(extended.utf8)) }
    }

    // MARK: occurrence continuation across combining marks

    @Test func occurrenceContinuationInsidePrecedingGrapheme() {
        // Python resolves occurrence 2 at code-point index 2 (the second
        // standalone "e"); Swift must agree in UTF-16 units and validate
        // the final span's composed boundaries.
        let counterpart = "e\u{0301}e"
        #expect(CorrespondenceResolver.occurrenceIndex(of: "e", in: counterpart, occurrence: 2) == 2)
        let resolved = CorrespondenceResolver.resolveMatches([(quote: "e", occurrence: 2)], in: counterpart)
        #expect(resolved?.ranges == [TextRange(location: 2, length: 1)])
        // Occurrence 1 lands inside the first grapheme: counting succeeds
        // but the final span fails composed-boundary verification.
        #expect(CorrespondenceResolver.occurrenceIndex(of: "e", in: counterpart, occurrence: 1) == 0)
        #expect(CorrespondenceResolver.resolveMatches([(quote: "e", occurrence: 1)], in: counterpart) == nil)
        // Nonoverlap continuation still holds on plain repeats.
        #expect(CorrespondenceResolver.occurrenceIndex(of: "can", in: "I can can fruit.", occurrence: 2) == 6)
        #expect(CorrespondenceResolver.occurrenceIndex(of: "aa", in: "aaa", occurrence: 1) == 0)
        #expect(CorrespondenceResolver.occurrenceIndex(of: "aa", in: "aaa", occurrence: 2) == nil)
    }

    // MARK: scaling correctness (no wall-clock assertions)

    @Test func largeSingleParagraphDocumentValidatesAndRoundTrips() throws {
        // 4000 units in ONE paragraph (synthesized: NLTokenizer groups short
        // sentences, so the planner will not produce this shape). Membership
        // validation must stay linear; this asserts correctness at scale
        // without timing claims.
        let tokens = (0..<4000).map { String(format: "w%05d", $0) }  // 6 chars each
        let source = tokens.joined(separator: " ")
        let paragraphID = UUID()
        var units: [PlannedUnit] = []
        var unitIDs: [UUID] = []
        for (index, _) in tokens.enumerated() {
            let id = UUID()
            let tokenStart = index * 7
            let fullLength = index == tokens.count - 1 ? 6 : 7  // last has no trailing space
            units.append(PlannedUnit(
                id: id, paragraphID: paragraphID,
                sourceRange: TextRange(location: tokenStart, length: fullLength),
                textRange: TextRange(location: tokenStart, length: 6),
                kind: .sentence
            ))
            unitIDs.append(id)
        }
        let paragraphs = [PlannedParagraph(
            id: paragraphID,
            sourceRange: TextRange(location: 0, length: source.utf16.count),
            separatorRange: TextRange(location: source.utf16.count, length: 0),
            unitIDs: unitIDs
        )]
        var document = BiparaDocument(
            documentID: UUID(), title: "scale", source: source, sourceRevision: 1,
            requestedDirection: .enToZh, resolvedDirection: .enToZh,
            paragraphs: paragraphs, units: units, translations: [],
            jobSnapshot: nil, layout: .paragraphs, readingAnchor: nil
        )
        #expect(document.units.count == 4000)
        try DocumentCodec.validate(&document)
        let data = try DocumentCodec.encode(document)
        let decoded = try DocumentCodec.decode(data)
        #expect(decoded.units.count == 4000)
    }

    // MARK: helpers

    private func makeBaseDocument(source: String, translated: Bool = false) throws -> BiparaDocument {
        let plan = try SourcePlanner.plan(source)
        let snapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: 1,
            sourceLanguage: .en, targetLanguage: .zh,
            provider: "openai", model: "gpt-4.1-mini-2025-04-14",
            profile: "openai-json-schema-v1", effort: .auto,
            translationPromptVersion: "translation.v1",
            alignmentPromptVersion: "alignment.v1"
        )
        let translations = translated
            ? plan.nonblankUnits.map {
                UnitTranslation(unitID: $0.id, text: "译", completedAt: Date(timeIntervalSince1970: 0))
            }
            : []
        return BiparaDocument(
            documentID: UUID(), title: "base", source: source, sourceRevision: 1,
            requestedDirection: translated ? .enToZh : .auto,
            resolvedDirection: translated ? .enToZh : nil,
            paragraphs: plan.paragraphs, units: plan.units,
            translations: translations, jobSnapshot: translated ? snapshot : nil,
            layout: .sideBySide, readingAnchor: nil
        )
    }
}
