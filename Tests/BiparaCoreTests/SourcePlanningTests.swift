import Foundation
import Testing
@testable import BiparaCore

@Suite("Source planning")
struct SourcePlanningTests {
    private func reconstruct(_ plan: SourcePlan) -> String {
        var pieces: [String] = []
        for paragraph in plan.paragraphs {
            pieces.append(plan.source.substring(utf16: paragraph.sourceRange) ?? "⚠️content")
            pieces.append(plan.source.substring(utf16: paragraph.separatorRange) ?? "⚠️sep")
        }
        return pieces.joined()
    }

    private func unitPartitionCoversParagraphs(_ plan: SourcePlan, diagnose: Bool = false) -> Bool {
        for paragraph in plan.paragraphs {
            let content = plan.source.substring(utf16: paragraph.sourceRange) ?? ""
            if content.isEmpty || content.isWhitespaceOnly {
                if !paragraph.unitIDs.isEmpty { if diagnose { print("FAIL: ws para has units") }; return false }
                continue
            }
            let units = plan.units.filter { $0.paragraphID == paragraph.id }
            guard !units.isEmpty else { if diagnose { print("FAIL: no units for [\(content)]") }; return false }
            var cursor = paragraph.sourceRange.location
            var seen = Set<UUID>()
            for unit in units {
                guard unit.sourceRange.location == cursor,
                      unit.sourceRange.isWithin(paragraph.sourceRange),
                      unit.textRange.isWithin(unit.sourceRange),
                      seen.insert(unit.id).inserted else { if diagnose { print("FAIL: unit chain at [\(plan.source.substring(utf16: unit.sourceRange) ?? "")] u=\(unit.sourceRange) t=\(unit.textRange) cursor=\(cursor)") }; return false }
                cursor = unit.sourceRange.end ?? -1
            }
            guard cursor == paragraph.sourceRange.end else { if diagnose { print("FAIL: coverage cursor=\(cursor) want=\(paragraph.sourceRange.end ?? -1)") }; return false }
            // Every nonblank unit has nonempty trimmed text; blank units may
            // exist only when they carry no translatable core.
            for unit in units {
                let text = plan.source.substring(utf16: unit.textRange) ?? ""
                if text.isEmpty && !unit.isBlank { return false }
                if !unit.isBlank && (text != text.trimmingCharacters(in: .whitespacesAndNewlines) || text.isEmpty) { return false }
            }
        }
        return true
    }

    @Test func emptySourceHasNoParagraphs() throws {
        let plan = try SourcePlanner.plan("")
        #expect(plan.paragraphs.isEmpty && plan.units.isEmpty)
    }

    @Test func paragraphParsingAcrossSeparators() throws {
        let cases: [(String, [(Int, Int, Int, Int)])] = [
            // source, [(contentLocation, contentLength, sepLocation, sepLength)]
            ("a", [(0, 1, 1, 0)]),
            ("a\n", [(0, 1, 1, 1)]),
            ("a\r\n", [(0, 1, 1, 2)]),
            ("a\rb", [(0, 1, 1, 1), (2, 1, 3, 0)]),
            ("a\n\nb", [(0, 1, 1, 1), (2, 0, 2, 1), (3, 1, 4, 0)]),
            ("\na", [(0, 0, 0, 1), (1, 1, 2, 0)]),
            ("\n", [(0, 0, 0, 1)]),
            ("  \n\t\nx", [(0, 2, 2, 1), (3, 1, 4, 1), (5, 1, 6, 0)]),
        ]
        for (source, expected) in cases {
            let plan = try SourcePlanner.plan(source)
            #expect(plan.paragraphs.count == expected.count)
            for (paragraph, want) in zip(plan.paragraphs, expected) {
                #expect(paragraph.sourceRange == TextRange(location: want.0, length: want.1))
                #expect(paragraph.separatorRange == TextRange(location: want.2, length: want.3))
            }
            #expect(reconstruct(plan) == source)
        }
    }

    @Test func whitespaceOnlyParagraphsHaveNoUnits() throws {
        let source = "第一段。\n\n   \n\t\n第二段。\n"
        let plan = try SourcePlanner.plan(source)
        #expect(reconstruct(plan) == source)
        #expect(plan.paragraphs.count == 5)
        #expect(plan.paragraphs[1].unitIDs.isEmpty)
        #expect(plan.paragraphs[2].unitIDs.isEmpty)
        #expect(plan.paragraphs[3].unitIDs.isEmpty)
        #expect(!plan.paragraphs[0].unitIDs.isEmpty)
        #expect(!plan.paragraphs[4].unitIDs.isEmpty)
        #expect(unitPartitionCoversParagraphs(plan))
    }

    @Test func unitPartitionHoldsForMixedText() throws {
        let source = [
            "The window is open. It rained today; the street stayed wet!",
            "",
            "  Indented start with 🎉 emoji and 𪚥 supplementary CJK.  ",
            "没有标点的长句依然应当完整覆盖不留缝隙",
            "Mixed 中英 text with é and e\u{0301} accents.",
        ].joined(separator: "\n")
        let plan = try SourcePlanner.plan(source)
        #expect(reconstruct(plan) == source)
        #expect(unitPartitionCoversParagraphs(plan))
        #expect(!plan.units.isEmpty)
        // NFC and NFD accents survive exactly.
        #expect(plan.source.contains("\u{00E9}"))
        #expect(plan.source.contains("e\u{0301}"))
    }

    @Test func sentenceSplitAtPunctuationPreferred() throws {
        // 400 chars per clause, one clause = 1200 bytes + punctuation > 1024.
        let clauseA = String(repeating: "长", count: 340) + "，"
        let clauseB = String(repeating: "短", count: 340) + "。"
        let paragraph = clauseA + clauseB
        let plan = try SourcePlanner.plan(paragraph)
        #expect(plan.units.count >= 2)
        for unit in plan.units {
            let text = plan.source.substring(utf16: unit.textRange) ?? ""
            #expect(TextIdentity.utf8Length(text) <= 1024)
        }
        // Breaks land on punctuation, not mid-clause: every fragment except
        // the last ends with a clause boundary character.
        for unit in plan.units.dropLast() {
            let text = plan.source.substring(utf16: unit.textRange) ?? ""
            #expect(text.hasSuffix("，") || text.hasSuffix("。"))
        }
        #expect(unitPartitionCoversParagraphs(plan))
    }

    @Test func unbrokenLongSentenceSplitsAtComposedBoundary() throws {
        let paragraph = String(repeating: "字", count: 1500) // 3 bytes each, no punctuation
        let plan = try SourcePlanner.plan(paragraph)
        let fragments = plan.units
        #expect(fragments.count >= 5)
        #expect(fragments.allSatisfy { $0.kind == .fragment })
        for unit in fragments {
            let text = plan.source.substring(utf16: unit.textRange) ?? ""
            #expect(TextIdentity.utf8Length(text) <= 1024)
        }
        #expect(unitPartitionCoversParagraphs(plan))
    }

    @Test func fragmentSplitPreservesLiteralReconstruction() throws {
        // Joining fragment texts must reproduce the core exactly (no
        // whitespace inside the core to invent or lose).
        let paragraph = String(repeating: "句", count: 1200)
        let plan = try SourcePlanner.plan(paragraph)
        let joined = plan.units.map { plan.source.substring(utf16: $0.textRange) ?? "" }.joined()
        #expect(TextIdentity.equal(joined, paragraph))
    }

    @Test func mergeIntoPartitionAttachesGaps() {
        let merged = SourcePlanner.mergeIntoPartition(
            candidates: [
                TextRange(location: 5, length: 3),
                TextRange(location: 12, length: 4),
            ],
            contentLength: 20
        )
        // Leading gap extends the first unit; the [8,12) gap attaches to
        // the previous unit; the trailing gap extends the last unit.
        #expect(merged == [
            TextRange(location: 0, length: 12),
            TextRange(location: 12, length: 8),
        ])
        // Overlapping candidates clamp.
        let clamped = SourcePlanner.mergeIntoPartition(
            candidates: [
                TextRange(location: 0, length: 10),
                TextRange(location: 5, length: 10),
            ],
            contentLength: 15
        )
        #expect(clamped == [
            TextRange(location: 0, length: 10),
            TextRange(location: 10, length: 5),
        ])
        // No candidates: the whole paragraph is one unit.
        #expect(SourcePlanner.mergeIntoPartition(candidates: [], contentLength: 7)
                == [TextRange(location: 0, length: 7)])
    }

    @Test func batchBoundsHold() throws {
        var paragraphs: [String] = []
        for i in 0..<140 {
            paragraphs.append("第\(i)句，内容各不相同，用于填充批次边界测试。")
        }
        let source = paragraphs.joined(separator: "\n")
        let plan = try SourcePlanner.plan(source)
        let batches = try SourcePlanner.formBatches(plan)
        #expect(batches.count > 1)
        let unitByID = Dictionary(uniqueKeysWithValues: plan.units.map { ($0.id, $0) })
        for batch in batches {
            #expect(batch.unitIDs.count <= 64)
            var bytes = 0
            for id in batch.unitIDs {
                let unit = unitByID[id]!
                bytes += TextIdentity.utf8Length(plan.source.substring(utf16: unit.textRange) ?? "")
            }
            #expect(bytes <= 8192)
        }
        // Every nonblank unit appears in exactly one batch, in source order.
        let batched = batches.flatMap(\.unitIDs)
        #expect(batched.count == plan.nonblankUnits.count)
        #expect(Set(batched).count == batched.count)
        #expect(batches.flatMap(\.unitIDs) == plan.nonblankUnits.map(\.id))
    }

    @Test func contextClippingStaysWithinByteBudget() throws {
        let source = String(repeating: "前后文前后文", count: 200) + "。" + String(repeating: "后续后续", count: 200)
        let plan = try SourcePlanner.plan(source)
        let batches = try SourcePlanner.formBatches(plan)
        for batch in batches {
            #expect(TextIdentity.utf8Length(batch.contextBefore) <= 512)
            #expect(TextIdentity.utf8Length(batch.contextAfter) <= 512)
        }
    }

    @Test func sourceAboveOneMiBIsRejected() {
        let big = String(repeating: "a", count: (1 << 20) + 1)
        #expect(throws: CoreError.self) { try SourcePlanner.plan(big) }
    }

    @Test func planningIsDeterministicWithinARun() throws {
        let source = "Same input. Same plan? 理论上结构一致。"
        let first = try SourcePlanner.plan(source)
        let second = try SourcePlanner.plan(source)
        func shape(_ plan: SourcePlan) -> [[Int]] {
            plan.paragraphs.map { [$0.sourceRange.location, $0.sourceRange.length, $0.separatorRange.length] }
                + plan.units.map { [$0.sourceRange.location, $0.sourceRange.length, $0.textRange.length] }
        }
        #expect(shape(first) == shape(second))
    }
}
