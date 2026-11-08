import Foundation
import Testing
@testable import BiparaCore

@Suite("Paragraph assembly")
struct AssemblyTests {
    /// Builds a plan whose single paragraph has exactly the given unit text
    /// ranges, so assembly behavior is tested deterministically.
    private func makePlan(units: [String], fragment: Bool = false) throws -> (SourcePlan, PlannedParagraph) {
        let source = units.joined()
        let plan = try SourcePlanner.plan(source)
        // Force unit boundaries by planning one paragraph; the planner
        // yields one sentence for short unbroken text, so synthesize the
        // units directly for multi-unit cases.
        let paragraph = plan.paragraphs[0]
        var custom = plan
        var newUnits: [PlannedUnit] = []
        var cursor = 0
        for (index, text) in units.enumerated() {
            newUnits.append(PlannedUnit(
                id: UUID(),
                paragraphID: paragraph.id,
                sourceRange: TextRange(location: cursor, length: text.utf16.count),
                textRange: TextRange(location: cursor, length: text.utf16.count),
                kind: fragment ? .fragment : .sentence
            ))
            cursor += text.utf16.count
        }
        custom.units = newUnits
        let updated = custom.paragraphs[0]
        custom.paragraphs[0] = PlannedParagraph(
            id: updated.id, sourceRange: updated.sourceRange,
            separatorRange: updated.separatorRange, unitIDs: newUnits.map(\.id)
        )
        return (custom, custom.paragraphs[0])
    }

    @Test func englishUnitsJoinWithOneSpace() throws {
        let (plan, paragraph) = try makePlan(units: ["Hello there.", "Second sentence."])
        let translations = [
            plan.units[0].id: "你好。",
            plan.units[1].id: "第二句。",
        ]
        let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations, targetLanguage: .en)
        #expect(assembly?.text == "你好。 第二句。")
        #expect(assembly?.unitRanges.count == 2)
        if let ranges = assembly?.unitRanges {
            #expect(assembly?.text.substring(utf16: ranges[0].range) == "你好。")
            #expect(assembly?.text.substring(utf16: ranges[1].range) == "第二句。")
        }
    }

    @Test func chineseUnitsJoinWithoutSpace() throws {
        let (plan, paragraph) = try makePlan(units: ["第一句。", "第二句。"])
        let translations = [plan.units[0].id: "First.", plan.units[1].id: "Second."]
        let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations, targetLanguage: .zh)
        #expect(assembly?.text == "First.Second.")
    }

    @Test(arguments: [" ", "\t", "  "])
    func splitNumberedListPrefixKeepsItsSourceGap(gap: String) throws {
        let (originalPlan, paragraph) = try makePlan(units: ["1." + gap, "Keep the file."])
        var plan = originalPlan
        // Reproduce a saved plan that splits the marker from its body.
        plan.units[0].textRange = TextRange(location: 0, length: 2)
        let translations = [plan.units[0].id: "1.", plan.units[1].id: "保留文件。"]
        let assembly = try #require(ParagraphAssembler.assemble(plan, paragraph: paragraph,
            translations: translations, targetLanguage: .zh))
        #expect(assembly.text == "1." + gap + "保留文件。")
        #expect(assembly.text.substring(utf16: assembly.unitRanges[1].range) == "保留文件。")
    }

    @Test func actualNumberedListPlanKeepsIndentationAndNewlines() throws {
        let source = "  1. Keep the file.\r\n"
        let plan = try SourcePlanner.plan(source)
        let translations = Dictionary(uniqueKeysWithValues: plan.nonblankUnits.map { unit in
            let text = source.substring(utf16: unit.textRange)!
            return (unit.id, text == "1." ? "1." : text.hasPrefix("1. ") ? "1. 保留文件。" : "保留文件。")
        })
        #expect(ParagraphAssembler.assembleDocument(plan, translations: translations, targetLanguage: .zh)
            == "  1. 保留文件。\r\n")
    }

    @Test func literalFragmentJoinPreservesSplitLiteral() throws {
        // A long identifier split mid-token; both fragments copied verbatim.
        let literal = "fetchVeryLongDataIdentifier" + String(repeating: "X", count: 1100)
        let (plan, paragraph) = try makePlan(units: [literal, ".png"], fragment: true)
        // The planner would split the oversized text itself; here units are
        // synthesized to be adjoining fragments with verbatim outputs.
        let translations = [
            plan.units[0].id: literal,
            plan.units[1].id: ".png",
        ]
        let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations, targetLanguage: .en)
        #expect(assembly?.text == literal + ".png")
    }

    @Test func nonLiteralFragmentsKeepSeparator() throws {
        let (plan, paragraph) = try makePlan(units: ["alpha", "beta"], fragment: true)
        let translations = [plan.units[0].id: "甲", plan.units[1].id: "乙"]
        let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations, targetLanguage: .en)
        #expect(assembly?.text == "甲 乙")
    }

    @Test func indentationIsPreserved() throws {
        let source = "    Hello there. Second sentence."
        let plan = try SourcePlanner.plan(source)
        let paragraph = plan.paragraphs[0]
        let translations = Dictionary(uniqueKeysWithValues: plan.nonblankUnits.map { ($0.id, "译\($0.textRange.location)") })
        let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations, targetLanguage: .en)
        #expect(assembly?.text.hasPrefix("    ") == true)
        #expect(assembly?.text.hasPrefix("     ") == false)
    }

    @Test func incompleteParagraphIsNotAssembled() throws {
        let (plan, paragraph) = try makePlan(units: ["One.", "Two."])
        let translations = [plan.units[0].id: "一。"]
        let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations, targetLanguage: .en)
        #expect(assembly == nil)
    }

    @Test func whitespaceOnlyParagraphAssemblesToItself() throws {
        let plan = try SourcePlanner.plan("字。\n   \n字。\n")
        let paragraph = plan.paragraphs[1]
        let translations: [UUID: String] = [:]
        let assembly = ParagraphAssembler.assemble(plan, paragraph: paragraph, translations: translations, targetLanguage: .en)
        #expect(assembly?.text == "   ")
        #expect(assembly?.unitRanges.isEmpty == true)
    }

    @Test func documentAssemblyRequiresCompletionAndKeepsSeparators() throws {
        let source = "第一句。\r\n\r\n第二句没有标点\n"
        let plan = try SourcePlanner.plan(source)
        var translations: [UUID: String] = [:]
        for unit in plan.nonblankUnits { translations[unit.id] = "T\(unit.sourceRange.location)" }
        let document = ParagraphAssembler.assembleDocument(plan, translations: translations, targetLanguage: .zh)
        #expect(document != nil)
        let pieces = document?.components(separatedBy: "\r\n") ?? []
        #expect(pieces.count == 3)
        #expect(pieces[1] == "")

        // Missing one unit: no complete-document assembly.
        translations.removeValue(forKey: plan.nonblankUnits[0].id)
        #expect(ParagraphAssembler.assembleDocument(plan, translations: translations, targetLanguage: .zh) == nil)
    }
}
