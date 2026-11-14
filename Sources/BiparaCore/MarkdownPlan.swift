import Foundation

/// The parser and planner are pinned together. Portable files persist source ranges
/// and identities; rendered text and normalized payloads are rebuilt and verified.
public struct MarkdownPlan: Equatable, Sendable {
    public static let version = "markdown-plan.v2"
    static let supportedVersions = ["markdown-plan.v1", version]
    public let planVersion: String
    public static let detectorVersion = "markdown-detection.v1"

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
        var metadataScalar = false
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

    public func validateTranslations(_ translations: [UnitTranslation], language: Language, newUnitIDs: Set<UUID>? = nil) throws {
        let order = Dictionary(uniqueKeysWithValues: units.enumerated().map { ($1.id, $0) })
        let tableUnits = Set(tops.flatMap(\.blocks).flatMap { block -> [UUID] in
            if case .tableCell = block.kind { return block.units }
            return []
        })
        var previous = -1
        for translation in translations {
            guard let position = order[translation.unitID], position > previous else { throw Self.structureMismatch }
            previous = position
            if let newUnitIDs, !newUnitIDs.contains(translation.unitID) { continue }
            guard let original = payloads[translation.unitID],
                  MarkdownInline.validShape(translation.text, source: original),
                  let actual = try? MarkdownInline(translation.text, references: references),
                  signatures[translation.unitID]?.elementsEqual(actual.signature, by: TextIdentity.equal) == true,
                  !tableUnits.contains(translation.unitID) || !Self.hasUnescapedPipe(translation.text) else { throw Self.structureMismatch }
        }
        let values = Dictionary(uniqueKeysWithValues: translations.map { ($0.unitID, $0.text) })
        let projected = replacedSource(using: values, language: language)
        guard let parsed = try? MarkdownSource(projected, translated: true), parsed.syntax.elementsEqual(syntax, by: TextIdentity.equal) else {
            throw Self.structureMismatch
        }
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

    func replacing(_ raw: String, offset: Int, blocks: [Block], values: [UUID: String], language: Language) -> String {
        let edits = blocks.compactMap { block -> (TextRange, String)? in
            guard !block.units.isEmpty, let edit = block.edit, let local = edit.offset(by: -offset),
                  let payload = translatedPayload(block, values: values, language: language) else { return nil }
            if block.metadataScalar {
                return (local, TextIdentity.equal(payload, block.payload) ? raw.substring(utf16: local)! : MarkdownMetadata.quoted(payload))
            }
            return (local, payload.replacingOccurrences(of: "\n", with: "\n" + block.continuation))
        }.sorted { $0.0.location < $1.0.location }
        var pieces: [String] = []
        var cursor = raw.startIndex
        for (range, value) in edits {
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
