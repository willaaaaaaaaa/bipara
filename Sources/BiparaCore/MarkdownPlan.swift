import Foundation

/// The parser and planner are pinned together. Portable files persist source ranges
/// and identities; rendered text and normalized payloads are rebuilt and verified.
public struct MarkdownPlan: Equatable, Sendable {
    public static let version = "markdown-plan.v4"
    static let supportedVersions = ["markdown-plan.v1", "markdown-plan.v2", "markdown-plan.v3", version]
    public let planVersion: String
    public static let detectorVersion = "markdown-detection.v2"

    struct Block: Equatable, Sendable {
        var id = UUID()
        var kind: MarkdownReadingBlockKind = .paragraph
        var range: TextRange
        var edit: TextRange?
        var payload = ""
        var units: [UUID] = []
        var listDepth = 0
        var quoteDepth = 0
        var marker: String?
        var literal: String?
        var continuation = ""
        var metadataKey: String?
    }

    struct Top: Equatable, Sendable {
        var id = UUID()
        var range: TextRange
        var blocks: [Block]
        var startsSection: Bool
        var isMetadata = false
    }

    let source: String
    var tops: [Top]
    let references: MarkdownReferences
    let syntax: [String]
    public private(set) var paragraphs: [PlannedParagraph]
    public private(set) var units: [PlannedUnit]
    public private(set) var prose: String
    private var payloads: [UUID: String]
    private var signatures: [UUID: [String]]

    public func requestText(for unit: PlannedUnit) -> String? { requestPayload(unit.id) }
    func requestPayload(_ id: UUID) -> String? { payloads[id] }

    public static func prepare(_ source: String, format: ContentFormat, markdownHint: Bool = false, plannerVersion: String = version) throws -> MarkdownPlan? {
        guard supportedVersions.contains(plannerVersion) else { throw invalidPlan }
        let size = source.utf8.count
        guard size <= WorkerContract.maxSourceUTF8Bytes else {
            throw CoreError.inputTooLarge(actualBytes: size, maxBytes: WorkerContract.maxSourceUTF8Bytes)
        }
        guard format != .plainText else { return nil }
        let parser: MarkdownSource
        do { parser = try MarkdownSource(source) }
        catch MarkdownSource.Limit.structure {
            if format == .auto, !markdownHint, !source.contains(where: { "#*_`~[>|".contains($0) }) { return nil }
            throw CoreError.unsupportedInput("Markdown structure exceeds the node or nesting limit.")
        }
        if format == .auto, !markdownHint, !parser.detectsMarkdown { return nil }
        return try parser.plan(version: plannerVersion)
    }

    func restored(paragraphs storedParagraphs: [PlannedParagraph], units storedUnits: [PlannedUnit]) throws -> Self {
        guard storedParagraphs.count == paragraphs.count, storedUnits.count == units.count,
              Set(storedParagraphs.map(\.id)).count == storedParagraphs.count,
              Set(storedUnits.map(\.id)).count == storedUnits.count else { throw Self.invalidPlan }
        let blockIDs = Dictionary(uniqueKeysWithValues: zip(paragraphs.map(\.id), storedParagraphs.map(\.id)))
        let unitIDs = Dictionary(uniqueKeysWithValues: zip(units.map(\.id), storedUnits.map(\.id)))
        for (expected, stored) in zip(paragraphs, storedParagraphs) {
            guard expected.sourceRange == stored.sourceRange, expected.separatorRange == stored.separatorRange,
                  expected.unitIDs.compactMap({ unitIDs[$0] }) == stored.unitIDs else { throw Self.invalidPlan }
        }
        for (expected, stored) in zip(units, storedUnits) {
            guard expected.sourceRange == stored.sourceRange, expected.textRange == stored.textRange,
                  expected.kind == stored.kind, blockIDs[expected.paragraphID] == stored.paragraphID else {
                throw Self.invalidPlan
            }
        }
        var result = self
        result.paragraphs = storedParagraphs
        result.units = storedUnits
        result.payloads = Dictionary(uniqueKeysWithValues: payloads.compactMap { id, text in unitIDs[id].map { ($0, text) } })
        result.signatures = Dictionary(uniqueKeysWithValues: signatures.compactMap { id, signature in unitIDs[id].map { ($0, signature) } })
        for index in result.tops.indices {
            for blockIndex in result.tops[index].blocks.indices {
                let old = result.tops[index].blocks[blockIndex].id
                guard let id = blockIDs[old] else { throw Self.invalidPlan }
                result.tops[index].blocks[blockIndex].id = id
                result.tops[index].blocks[blockIndex].units = result.tops[index].blocks[blockIndex].units.compactMap { unitIDs[$0] }
            }
            result.tops[index].id = result.tops[index].blocks.first?.id ?? result.tops[index].id
        }
        return result
    }

    static let invalidPlan = CoreError.invalidDocument("Markdown plan does not match its source")
    static let structureMismatch = GatewayError(code: .invalidOutput, isLocal: true, validationFailure: .markdownStructureMismatch)

    static func create(source: String, tops input: [Top], references: MarkdownReferences, syntax: [String], version: String) throws -> Self {
        var tops = input
        var paragraphs: [PlannedParagraph] = []
        var units: [PlannedUnit] = []
        var prose: [String] = []
        var payloads: [UUID: String] = [:]
        var signatures: [UUID: [String]] = [:]
        for index in tops.indices {
            for blockIndex in tops[index].blocks.indices {
                var block = tops[index].blocks[blockIndex]
                if let edit = block.edit, !block.payload.isEmpty {
                    let inline = try MarkdownInline(block.payload, references: references)
                    if inline.hasProse {
                        prose.append(inline.prose)
                        let fragments = try inline.fragments()
                        for fragment in fragments {
                            let unit = PlannedUnit(
                                id: UUID(), paragraphID: block.id, sourceRange: edit, textRange: edit,
                                kind: fragments.count == 1 ? .markdownInline : .markdownFragment
                            )
                            units.append(unit)
                            payloads[unit.id] = fragment
                            signatures[unit.id] = fragments.count == 1 ? inline.signature
                                : try MarkdownInline(fragment, references: references).signature
                            block.units.append(unit.id)
                        }
                    }
                }
                tops[index].blocks[blockIndex] = block
                paragraphs.append(PlannedParagraph(
                    id: block.id, sourceRange: block.range,
                    separatorRange: TextRange(location: block.range.end ?? block.range.location, length: 0),
                    unitIDs: block.units
                ))
            }
            tops[index].id = tops[index].blocks.first?.id ?? tops[index].id
        }
        let plan = Self(planVersion: version, source: source, tops: tops, references: references, syntax: syntax,
                        paragraphs: paragraphs, units: units, prose: prose.joined(separator: "\n"), payloads: payloads, signatures: signatures)
        _ = try SourcePlanner.formBatches(SourcePlan(source: source, paragraphs: paragraphs, units: units, markdownPlan: plan))
        return plan
    }

    public struct ValidationFailure: Error, Sendable, CustomStringConvertible {
        public enum Difference: Equatable, Sendable {
            case unitOrder, textShape, inlineParse, tablePipe, blockParse
            case inlineStructure(expected: [String], received: [String])
            case blockStructure(expected: [String], received: [String])
        }

        public struct Passage: Identifiable, Sendable {
            public let id: UUID
            public let unitNumber: Int
            public let input: String
            public let reply: String
        }

        public let difference: Difference
        public let passages: [Passage]
        public var description: String { "markdown_structure_mismatch" }
    }

    public func validateTranslations(_ translations: [UnitTranslation], language: Language, newUnitIDs: Set<UUID>? = nil) throws {
        try validate(translations, language: language, newUnitIDs: newUnitIDs, reportDetails: false)
    }

    public func validateBatch(_ translations: [UnitTranslation], language: Language, newUnitIDs: Set<UUID>) throws {
        try validate(translations, language: language, newUnitIDs: newUnitIDs, reportDetails: true)
    }

    private func validate(
        _ translations: [UnitTranslation], language: Language, newUnitIDs: Set<UUID>?, reportDetails: Bool
    ) throws {
        let order = Dictionary(uniqueKeysWithValues: units.enumerated().map { ($1.id, $0) })
        func failure(_ difference: ValidationFailure.Difference, for rejected: [UnitTranslation]) -> any Error {
            guard reportDetails else { return Self.structureMismatch }
            let passages = rejected.compactMap { translation -> ValidationFailure.Passage? in
                guard let position = order[translation.unitID], let input = payloads[translation.unitID] else { return nil }
                return .init(id: translation.unitID, unitNumber: position + 1, input: input, reply: translation.text)
            }
            return ValidationFailure(difference: difference, passages: passages)
        }
        let tableUnits = Set(tops.flatMap(\.blocks).flatMap { block -> [UUID] in
            if case .tableCell = block.kind { return block.units }
            return []
        })
        var previous = -1
        for translation in translations {
            guard let position = order[translation.unitID], position > previous,
                  let original = payloads[translation.unitID], let expected = signatures[translation.unitID] else {
                throw failure(.unitOrder, for: [])
            }
            previous = position
            if let newUnitIDs, !newUnitIDs.contains(translation.unitID) { continue }
            guard MarkdownInline.validShape(translation.text, source: original) else {
                throw failure(.textShape, for: [translation])
            }
            guard let actual = try? MarkdownInline(translation.text, references: references) else {
                throw failure(.inlineParse, for: [translation])
            }
            if let difference = inlineDifference(expected, actual.signature) {
                throw failure(difference, for: [translation])
            }
            if tableUnits.contains(translation.unitID), Self.hasUnescapedPipe(translation.text) {
                throw failure(.tablePipe, for: [translation])
            }
        }
        func batch() -> [UnitTranslation] {
            translations.filter { newUnitIDs?.contains($0.unitID) ?? true }
        }
        let values = Dictionary(uniqueKeysWithValues: translations.map { ($0.unitID, $0.text) })
        let projected = replacedSource(using: values, language: language)
        guard let parsed = try? MarkdownSource(projected, translated: true) else {
            throw failure(.blockParse, for: batch())
        }
        if let change = Self.signatureChange(syntax, parsed.syntax) {
            guard reportDetails else { throw Self.structureMismatch }
            // Prefer inputs whose replacements overlap the first changed
            // target node. Other batch inputs remain available for context.
            var nearby: Set<UUID> = []
            if let range = parsed.syntaxRange(at: change.index), let end = range.end {
                var delta = 0
                for edit in replacementEdits(offset: 0, blocks: tops.flatMap(\.blocks), values: values, language: language) {
                    let start = edit.range.location + delta
                    let length = edit.text.utf16.count
                    if start < end, start + length > range.location {
                        nearby.formUnion(edit.units)
                    }
                    delta += length - edit.range.length
                }
            }
            let submitted = batch()
            throw failure(.blockStructure(expected: change.expected, received: change.received),
                          for: submitted.filter { nearby.contains($0.unitID) } + submitted.filter { !nearby.contains($0.unitID) })
        }
    }

    private func inlineDifference(_ expected: [String], _ received: [String]) -> ValidationFailure.Difference? {
        guard let change = Self.signatureChange(expected, received) else { return nil }
        let orderedDifference = ValidationFailure.Difference.inlineStructure(expected: change.expected, received: change.received)
        func isCode(_ token: String) -> Bool { token.hasPrefix("code:") }
        switch planVersion {
        case "markdown-plan.v4": break
        case "markdown-plan.v3" where expected.allSatisfy(isCode) && received.allSatisfy(isCode): break
        default: return orderedDifference
        }

        func unmatched(_ spans: ArraySlice<String>, against others: ArraySlice<String>) -> [String] {
            var counts: [Data: Int] = [:]
            for other in others { counts[Data(other.utf8), default: 0] += 1 }
            return spans.filter { span in
                let key = Data(span.utf8)
                guard counts[key, default: 0] > 0 else { return true }
                counts[key, default: 0] -= 1
                return false
            }
        }
        // Every non-code token (including a closing tag or hard break) bounds a run.
        var source = change.expected[...]
        var target = change.received[...]
        while !source.isEmpty || !target.isEmpty {
            let original = source.prefix(while: isCode)
            let translated = target.prefix(while: isCode)
            let missing = unmatched(original, against: translated)
            let added = unmatched(translated, against: original)
            source = source.dropFirst(original.count)
            target = target.dropFirst(translated.count)
            if let left = source.first, let right = target.first, TextIdentity.equal(left, right) {
                source = source.dropFirst()
                target = target.dropFirst()
            } else if !source.isEmpty || !target.isEmpty {
                return orderedDifference
            }
            if !missing.isEmpty || !added.isEmpty {
                return .inlineStructure(expected: missing, received: added)
            }
        }
        return nil
    }

    private static func signatureChange(_ expected: [String], _ received: [String])
        -> (index: Int, expected: [String], received: [String])? {
        let index = zip(expected, received).prefix(while: { TextIdentity.equal($0, $1) }).count
        guard index != expected.count || index != received.count else { return nil }
        let suffix = zip(expected.dropFirst(index).reversed(), received.dropFirst(index).reversed())
            .prefix(while: { TextIdentity.equal($0, $1) }).count
        return (index, Array(expected[index..<(expected.count - suffix)]), Array(received[index..<(received.count - suffix)]))
    }

    private static func hasUnescapedPipe(_ text: String) -> Bool {
        var escaped = false
        for character in text {
            if character == "|", !escaped { return true }
            escaped = character == "\\" && !escaped
        }
        return false
    }

    func translatedPayload(_ block: Block, values: [UUID: String], language: Language) -> String? {
        guard !block.units.isEmpty else { return block.payload }
        let pieces = block.units.compactMap { values[$0] }
        guard pieces.count == block.units.count else { return nil }
        return pieces.joined(separator: language == .en ? " " : "")
    }

    private func replacementEdits(offset: Int, blocks: [Block], values: [UUID: String], language: Language)
        -> [(range: TextRange, text: String, units: [UUID])] {
        blocks.compactMap { block -> (range: TextRange, text: String, units: [UUID])? in
            guard !block.units.isEmpty, let edit = block.edit, let local = edit.offset(by: -offset),
                  let payload = translatedPayload(block, values: values, language: language) else { return nil }
            if block.metadataKey != nil {
                return (local, TextIdentity.equal(payload, block.payload) ? source.substring(utf16: edit)! : MarkdownMetadata.quoted(payload), block.units)
            }
            return (local, payload.replacingOccurrences(of: "\n", with: "\n" + block.continuation), block.units)
        }.sorted { $0.range.location < $1.range.location }
    }

    func replacing(_ raw: String, offset: Int, blocks: [Block], values: [UUID: String], language: Language) -> String {
        let edits = replacementEdits(offset: offset, blocks: blocks, values: values, language: language)
        var pieces: [String] = []
        var cursor = raw.startIndex
        for (range, value, _) in edits {
            guard let end = range.end, let startIndex = raw.utf16Index(at: range.location),
                  let endIndex = raw.utf16Index(at: end), startIndex >= cursor else {
                // The plan only contains ordered, validated source edits.
                return ""
            }
            pieces.append(String(raw[cursor..<startIndex]))
            pieces.append(value)
            cursor = endIndex
        }
        pieces.append(String(raw[cursor...]))
        return pieces.joined()
    }

    func replacedSource(using values: [UUID: String], language: Language) -> String {
        replacing(source, offset: 0, blocks: tops.flatMap(\.blocks), values: values, language: language)
    }
}
