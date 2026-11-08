import Foundation
import Testing
@testable import BiparaCore

/// Regression tests for planner↔codec agreement: every planned unit must
/// carry nonempty trimmed text and survive a document round trip, including
/// oversized-sentence splits whose only break candidates are whitespace
/// and paragraphs containing U+2028/U+2029 whitespace-only tokens.
@Suite("Fragment trimming and whitespace tokens")
struct FragmentTrimTests {
    private func assertPlanIsStorable(_ plan: SourcePlan) throws {
        for unit in plan.units {
            let text = plan.source.substring(utf16: unit.textRange) ?? ""
            #expect(!text.isEmpty, "unit text empty")
            #expect(text.isContractTrimmed, "unit text not trimmed: [\(text.suffix(20))]")
            #expect(unit.sourceRange.length >= 1 && unit.textRange.length >= 1)
        }
        var reconstructed = ""
        for paragraph in plan.paragraphs {
            reconstructed += (plan.source.substring(utf16: paragraph.sourceRange) ?? "")
            reconstructed += (plan.source.substring(utf16: paragraph.separatorRange) ?? "")
        }
        #expect(reconstructed == plan.source)
        var document = BiparaDocument(
            documentID: UUID(), title: "t", source: plan.source, sourceRevision: 1,
            requestedDirection: .enToZh, resolvedDirection: .enToZh,
            paragraphs: plan.paragraphs, units: plan.units, translations: [],
            jobSnapshot: nil, layout: .sideBySide, readingAnchor: nil
        )
        try DocumentCodec.validate(&document)
    }

    @Test func whitespacePreferredBreaksProduceTrimmedFragments() throws {
        // No punctuation anywhere: the old whitespace-preferring break
        // produced fragments ending in " " and the codec rejected the file.
        let inputs = [
            String(repeating: "word ", count: 250),
            String(repeating: "字", count: 400) + " " + String(repeating: "字", count: 400),
            "alpha\tbeta" + String(repeating: "gamma delta ", count: 150),
        ]
        for source in inputs {
            try assertPlanIsStorable(try SourcePlanner.plan(source))
        }
    }

    @Test func whitespaceOnlyTokenizerTokensBecomeGaps() throws {
        // U+2028/U+2029 runs (copied from some Mac/PDF sources) used to
        // become zero-length units that failed codec validation on reopen.
        let source = "test \u{2028}\u{2028}\u{2028} case. More text follows here."
        let plan = try SourcePlanner.plan(source)
        #expect(plan.units.allSatisfy { !$0.isBlank })
        try assertPlanIsStorable(plan)
    }

    @Test func oversizedSplitsRemainStorable() throws {
        let inputs = [
            String(repeating: "长", count: 340) + "，" + String(repeating: "短", count: 340) + "。",
            String(repeating: "字", count: 1500),
            String(repeating: "句", count: 1200),
        ]
        for source in inputs {
            try assertPlanIsStorable(try SourcePlanner.plan(source))
        }
    }

    @Test func interiorWhitespaceRunAboveLimitStillSplits() throws {
        // A pathological >1 KiB whitespace run inside one sentence: the
        // run is boundary whitespace, never a unit or a piece boundary.
        let source = "start" + String(repeating: " ", count: 2000) + "end"
        let plan = try SourcePlanner.plan(source)
        try assertPlanIsStorable(plan)
        #expect(!plan.units.isEmpty)
    }
}
