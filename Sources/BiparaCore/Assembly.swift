import Foundation

/// One unit's placement inside an assembled translated paragraph.
public struct AssembledUnitRange: Equatable, Sendable {
    public var unitID: UUID
    /// Range within the assembled paragraph text, excluding any inserted
    /// separator and the paragraph's preserved indentation.
    public var range: TextRange

    public init(unitID: UUID, range: TextRange) {
        self.unitID = unitID
        self.range = range
    }
}

/// The deterministic result of assembling one fully translated paragraph.
public struct ParagraphAssembly: Equatable, Sendable {
    public var text: String
    public var unitRanges: [AssembledUnitRange]

    public init(text: String, unitRanges: [AssembledUnitRange]) {
        self.text = text
        self.unitRanges = unitRanges
    }
}

/// Deterministic paragraph assembly per the model workflow contract.
///
/// Units join with one ASCII space for English and no space for Chinese.
/// Exception: adjoining fragments whose outputs exactly copy their source
/// text retain their original inter-fragment whitespace, preserving split
/// literal strings and commands. Paragraph indentation
/// and whitespace after a separately tokenized numbered-list marker are
/// preserved; no automatic final punctuation is added.
public enum ParagraphAssembler {
    /// Returns nil while any nonblank unit of the paragraph is unfinished;
    /// a partly translated paragraph is never presented as complete.
    public static func assemble(
        _ plan: SourcePlan,
        paragraph: PlannedParagraph,
        translations: [UUID: String],
        targetLanguage: Language
    ) -> ParagraphAssembly? {
        let units = paragraph.unitIDs.compactMap { id in plan.units.first { $0.id == id } }
        let nonblank = units.filter { !$0.isBlank }
        guard !nonblank.isEmpty else {
            // Whitespace-only paragraph: assembled as its exact content.
            let text = plan.source.substring(utf16: paragraph.sourceRange) ?? ""
            return ParagraphAssembly(text: text, unitRanges: [])
        }
        guard nonblank.allSatisfy({ translations[$0.id] != nil }) else { return nil }

        guard let content = plan.source.substring(utf16: paragraph.sourceRange) else { return nil }
        let (indentation, _, _) = content.trimmingWhitespaceSplit()

        var pieces: [String] = [indentation]
        var ranges: [AssembledUnitRange] = []
        var offset = indentation.utf16.count
        for (index, unit) in nonblank.enumerated() {
            let translation = translations[unit.id]!
            if index > 0 {
                let previous = nonblank[index - 1]
                let previousText = translations[previous.id]!
                let separator: String
                if index == 1,
                   let marker = plan.source.substring(utf16: previous.textRange),
                   TextIdentity.equal(previousText, marker),
                   marker.range(of: #"^[0-9]{1,9}[.)]$"#, options: .regularExpression) != nil,
                   let end = previous.textRange.end,
                   let gap = plan.source.substring(utf16: TextRange(location: end, length: unit.textRange.location - end)),
                   !gap.isEmpty, gap.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    separator = gap
                } else {
                    separator = insertedSeparator(
                        previous: previous, previousText: previousText,
                        next: unit, nextText: translation, source: plan.source, targetLanguage: targetLanguage
                    )
                }
                pieces.append(separator)
                offset += separator.utf16.count
            }
            pieces.append(translation)
            ranges.append(AssembledUnitRange(
                unitID: unit.id,
                range: TextRange(location: offset, length: translation.utf16.count)
            ))
            offset += translation.utf16.count
        }
        return ParagraphAssembly(text: pieces.joined(), unitRanges: ranges)
    }

    /// The separator inserted between two translated units: one ASCII space
    /// for English targets, none for Chinese, or the original boundary gap
    /// for verified literal fragments.
    static func insertedSeparator(
        previous: PlannedUnit, previousText: String,
        next: PlannedUnit, nextText: String,
        source: String, targetLanguage: Language
    ) -> String {
        if isLiteralFragmentJoin(
            previous: previous, previousText: previousText,
            next: next, nextText: nextText, source: source
        ) {
            let start = previous.textRange.end!
            return source.substring(utf16: TextRange(location: start, length: next.textRange.location - start))!
        }
        return targetLanguage == .en ? " " : ""
    }

    /// True when adjoining split fragments copied their source verbatim
    /// and their source gap contains only boundary whitespace.
    static func isLiteralFragmentJoin(
        previous: PlannedUnit, previousText: String,
        next: PlannedUnit, nextText: String,
        source: String
    ) -> Bool {
        guard previous.kind == .fragment, next.kind == .fragment,
              previous.paragraphID == next.paragraphID else { return false }
        guard let previousTextRange = previous.textRange.end,
              previousTextRange <= next.textRange.location,
              let gap = source.substring(utf16: TextRange(location: previousTextRange, length: next.textRange.location - previousTextRange)),
              gap.unicodeScalars.allSatisfy({ $0.isContractWhitespace }) else { return false }
        guard let previousSource = source.substring(utf16: previous.textRange),
              let nextSource = source.substring(utf16: next.textRange) else { return false }
        return TextIdentity.equal(previousText, previousSource)
            && TextIdentity.equal(nextText, nextSource)
    }

    /// Assembles the complete translated plain text of a document, using
    /// each paragraph's exact source separator. Returns nil unless every
    /// nonblank unit is translated.
    public static func assembleDocument(
        _ plan: SourcePlan,
        translations: [UUID: String],
        targetLanguage: Language
    ) -> String? {
        var pieces: [String] = []
        for paragraph in plan.paragraphs {
            guard let assembly = assemble(
                plan, paragraph: paragraph, translations: translations, targetLanguage: targetLanguage
            ) else { return nil }
            pieces.append(assembly.text)
            pieces.append(plan.source.substring(utf16: paragraph.separatorRange) ?? "")
        }
        return pieces.joined()
    }
}
