import Foundation

/// A committed translation of one unit.
public struct UnitTranslation: Equatable, Sendable {
    public var unitID: UUID
    public var text: String
    public var returnedModel: String?
    public var completedAt: Date

    public init(unitID: UUID, text: String, returnedModel: String? = nil, completedAt: Date) {
        self.unitID = unitID
        self.text = text
        self.returnedModel = returnedModel
        self.completedAt = completedAt
    }
}

/// The immutable job configuration of one document revision. Portable
/// attribution only: the endpoint and local configuration identity are
/// intentionally absent and live in app-layer runtime state.
public struct JobSnapshot: Equatable, Sendable {
    public var jobID: UUID
    public var sourceRevision: Int
    public var sourceLanguage: Language
    public var targetLanguage: Language
    public var provider: String
    public var model: String
    public var profile: String
    public var effort: ModelEffort
    public var translationPromptVersion: String
    public var alignmentPromptVersion: String

    public init(
        jobID: UUID, sourceRevision: Int,
        sourceLanguage: Language, targetLanguage: Language,
        provider: String, model: String, profile: String,
        effort: ModelEffort,
        translationPromptVersion: String, alignmentPromptVersion: String
    ) {
        self.jobID = jobID
        self.sourceRevision = sourceRevision
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.provider = provider
        self.model = model
        self.profile = profile
        self.effort = effort
        self.translationPromptVersion = translationPromptVersion
        self.alignmentPromptVersion = alignmentPromptVersion
    }
}

/// A saved reading position.
public struct ReadingAnchor: Equatable, Sendable {
    public var paragraphID: UUID
    public var side: ReadingSide
    public var fraction: Double

    public init(paragraphID: UUID, side: ReadingSide, fraction: Double) {
        self.paragraphID = paragraphID
        self.side = side
        self.fraction = fraction
    }
}

/// The in-memory `.bipara` document, matching format v2 (with compatible
/// v1 reading).
public struct BiparaDocument: Equatable, Sendable {
    public var documentID: UUID
    public var title: String
    public var source: String
    public var sourceRevision: Int
    public var requestedDirection: Direction
    public var resolvedDirection: Direction?
    public var paragraphs: [PlannedParagraph]
    public var units: [PlannedUnit]
    public var translations: [UnitTranslation]
    public var jobSnapshot: JobSnapshot?
    public var layout: LayoutMode
    public var readingAnchor: ReadingAnchor?

    public init(
        documentID: UUID, title: String, source: String, sourceRevision: Int,
        requestedDirection: Direction, resolvedDirection: Direction?,
        paragraphs: [PlannedParagraph], units: [PlannedUnit],
        translations: [UnitTranslation], jobSnapshot: JobSnapshot?,
        layout: LayoutMode, readingAnchor: ReadingAnchor?
    ) {
        self.documentID = documentID
        self.title = title
        self.source = source
        self.sourceRevision = sourceRevision
        self.requestedDirection = requestedDirection
        self.resolvedDirection = resolvedDirection
        self.paragraphs = paragraphs
        self.units = units
        self.translations = translations
        self.jobSnapshot = jobSnapshot
        self.layout = layout
        self.readingAnchor = readingAnchor
    }
}

/// Encoder/decoder for the versioned local `.bipara` file (UTF-8 JSON).
///
/// Decoding runs the shared strict preflight (size, UTF-8, duplicate
/// decoded keys) and then validates every type, identity, range, reference,
/// and partition against the actual source before returning a document.
/// A newer schema version is rejected without rewriting anything.
public enum DocumentCodec {
    public static let formatName = "bipara"
    /// Written schema version. Version 1 files are read through the
    /// in-memory snapshot migration (derived Auto/Off effort) but never
    /// rewritten on open.
    public static let schemaVersion = 2
    public static let readableSchemaVersions: ClosedRange<Int> = 1...2
    public static let maxTitleCharacters = 256

    // MARK: Encoding

    public static func encode(_ document: BiparaDocument) throws -> Data {
        let dto = DocumentDTO(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(dto)
        } catch {
            throw CoreError.invalidDocument("encoding failed")
        }
    }

    // MARK: Decoding

    public static func decode(_ data: Data) throws -> BiparaDocument {
        guard data.count <= WorkerContract.documentFileByteLimit else {
            throw CoreError.invalidDocument("file exceeds the 20 MiB limit")
        }
        do {
            try StrictJSON.preflight(data, maxBytes: WorkerContract.documentFileByteLimit)
        } catch {
            throw CoreError.invalidDocument("strict preflight failed")
        }
        let dto: DocumentDTO
        do {
            dto = try JSONDecoder().decode(DocumentDTO.self, from: data)
        } catch {
            throw CoreError.invalidDocument("decoding failed: \(error.localizedDescription)")
        }
        guard dto.format == formatName else {
            throw CoreError.invalidDocument("unknown format")
        }
        guard readableSchemaVersions.contains(dto.schemaVersion) else {
            throw CoreError.invalidDocument("unsupported schema version \(dto.schemaVersion)")
        }
        if dto.schemaVersion == 1, let snapshotDTO = dto.jobSnapshot {
            // A v1 snapshot carries no effort. Derive Auto for the OpenAI
            // legacy profile and Off for GLM; an unknown old profile uses
            // Auto only as unspecified attribution and stays unavailable
            // for model calls. The original file is never rewritten.
            let derived = WorkerContract.legacyEffort(profile: snapshotDTO.profile).map {
                $0 == .auto ? ModelEffort.auto : ModelEffort.off
            } ?? .auto
            snapshotDTO.effort = derived
        }
        if dto.schemaVersion == 2, let snapshotDTO = dto.jobSnapshot, snapshotDTO.effort == nil {
            throw CoreError.invalidDocument("a v2 job snapshot requires an effort value")
        }
        var document = BiparaDocument(
            documentID: dto.documentID,
            title: dto.title,
            source: dto.source,
            sourceRevision: dto.sourceRevision,
            requestedDirection: dto.direction.requested,
            resolvedDirection: dto.direction.resolved,
            paragraphs: dto.paragraphs.map(\.value),
            units: dto.units.map(\.value),
            translations: dto.translations.map(\.value),
            jobSnapshot: dto.jobSnapshot?.value,
            layout: dto.layout,
            readingAnchor: dto.readingAnchor?.value
        )
        try validate(&document)
        if let snapshot = document.jobSnapshot, dto.schemaVersion == 2 {
            try validateSnapshotCapabilities(snapshot)
        }
        return document
    }

    /// A v2 file's snapshot effort must be consistent with its profile and,
    /// for known models, the capability table. Derived v1 values are exempt
    /// (they preserve the original contract) and stay readable.
    private static func validateSnapshotCapabilities(_ snapshot: JobSnapshot) throws {
        if let legacy = WorkerContract.legacyEffort(profile: snapshot.profile) {
            guard snapshot.effort == legacy else {
                throw CoreError.invalidDocument("legacy profile effort mismatch")
            }
            return
        }
        guard WorkerContract.currentProfiles.values.contains(snapshot.profile) else { return }
        if let capability = ModelCapabilities.entry(model: snapshot.model, provider: snapshot.provider) {
            guard capability.efforts.contains(snapshot.effort) else {
                throw CoreError.invalidDocument("snapshot effort is unsupported for the model")
            }
        }
    }

    // MARK: Semantic validation

    public static func validate(_ document: inout BiparaDocument) throws {
        // Title: nonempty, single line, bounded by Unicode characters.
        if document.title.isEmpty
            || document.title.unicodeScalars.count > maxTitleCharacters
            || document.title.contains("\n") || document.title.contains("\r") {
            throw CoreError.invalidDocument("invalid title")
        }
        if TextIdentity.utf8Length(document.source) > WorkerContract.maxSourceUTF8Bytes {
            throw CoreError.invalidDocument("source exceeds the 1 MiB bound")
        }
        if document.sourceRevision < 0 || document.sourceRevision == Int.max {
            throw CoreError.invalidDocument("source revision is outside the editable range")
        }
        // Direction consistency. A job snapshot always implies a resolved
        // direction: the job ran against concrete languages.
        if let resolved = document.resolvedDirection {
            guard resolved != .auto else {
                throw CoreError.invalidDocument("resolved direction cannot be auto")
            }
            if document.requestedDirection != .auto, document.requestedDirection != resolved {
                throw CoreError.invalidDocument("resolved direction contradicts the request")
            }
        } else if document.jobSnapshot != nil {
            throw CoreError.invalidDocument("a job snapshot requires a resolved direction")
        }

        // Paragraph partition covers the exact source with valid ranges.
        try SourcePlanner.validateParagraphPartition(document.paragraphs, totalLength: document.source.utf16.count)
        var paragraphIDs = Set<UUID>()
        for paragraph in document.paragraphs {
            guard document.source.hasValidRange(paragraph.sourceRange),
                  document.source.hasValidRange(paragraph.separatorRange) else {
                throw CoreError.invalidDocument("paragraph range violates composed boundaries")
            }
            guard let separator = document.source.substring(utf16: paragraph.separatorRange),
                  separator.isEmpty || separator == "\n" || separator == "\r\n" || separator == "\r" else {
                throw CoreError.invalidDocument("separator contains non-newline characters")
            }
            guard paragraphIDs.insert(paragraph.id).inserted else {
                throw CoreError.invalidDocument("duplicate paragraph ID")
            }
        }

        // Units: unique, referenced, valid ranges, ordered by source.
        // Index maps and membership sets are built once: validation must
        // stay near-linear at the 1 MiB source / 20 MiB file scale.
        var unitIDs = Set<UUID>()
        var previousUnitEnd = -1
        let paragraphByID = Dictionary(uniqueKeysWithValues: document.paragraphs.map { ($0.id, $0) })
        let unitsByID = Dictionary(document.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unitIDSetsByParagraph = Dictionary(
            document.paragraphs.map { ($0.id, Set($0.unitIDs)) },
            uniquingKeysWith: { first, _ in first }
        )
        var orderedUnitsByParagraph: [UUID: [PlannedUnit]] = [:]
        for unit in document.units {
            orderedUnitsByParagraph[unit.paragraphID, default: []].append(unit)
        }
        for unit in document.units {
            guard unitIDs.insert(unit.id).inserted else {
                throw CoreError.invalidDocument("duplicate unit ID")
            }
            guard let paragraph = paragraphByID[unit.paragraphID] else {
                throw CoreError.invalidDocument("unit references an unknown paragraph")
            }
            guard unitIDSetsByParagraph[unit.paragraphID]?.contains(unit.id) == true else {
                throw CoreError.invalidDocument("paragraph does not reference its unit")
            }
            // Range shape is checked before any substring: negative,
            // reversed, or overflowing stored ranges are invalid content,
            // never a crash.
            guard unit.sourceRange.isWellFormed, unit.textRange.isWellFormed else {
                throw CoreError.invalidDocument("unit range is not well formed")
            }
            guard unit.sourceRange.isWithin(paragraph.sourceRange),
                  unit.textRange.isWithin(unit.sourceRange),
                  document.source.hasValidRange(unit.sourceRange),
                  document.source.hasValidRange(unit.textRange) else {
                throw CoreError.invalidDocument("unit range violation")
            }
            // The planner never produces zero-length units; stored content
            // with one is invalid, not silently tolerable.
            guard unit.sourceRange.length >= 1, unit.textRange.length >= 1 else {
                throw CoreError.invalidDocument("zero-length unit")
            }
            guard let unitSource = document.source.substring(utf16: unit.sourceRange),
                  let text = document.source.substring(utf16: unit.textRange) else {
                throw CoreError.invalidDocument("unit text range unresolved")
            }
            // The inner range must be the exact contract-trimmed core of
            // the full unit range: excluded content may only be boundary
            // whitespace, never translatable source.
            let (leading, core, _) = unitSource.trimmingWhitespaceSplit()
            let expectedInner = TextRange(
                location: unit.sourceRange.location + leading.utf16.count,
                length: core.utf16.count
            )
            guard unit.textRange == expectedInner else {
                throw CoreError.invalidDocument("text range is not the trimmed core of the unit")
            }
            if text.contains("\n") || text.contains("\r") {
                throw CoreError.invalidDocument("unit text contains a line break")
            }
            guard let end = unit.sourceRange.end, end > previousUnitEnd else {
                throw CoreError.invalidDocument("units are not in source order")
            }
            previousUnitEnd = end
        }
        // Whitespace-only paragraphs have no units; every nonblank
        // paragraph's units tile its content exactly, in the paragraph's
        // stored reference order (no unstable re-sorting).
        for paragraph in document.paragraphs {
            let paragraphUnits = paragraph.unitIDs.map { unitsByID[$0] }
            guard !paragraphUnits.contains(where: { $0 == nil }) else {
                throw CoreError.invalidDocument("paragraph references an unknown unit")
            }
            let referenced = paragraphUnits.map { $0! }
            // The paragraph's reference order must match document order.
            guard referenced.map(\.id) == (orderedUnitsByParagraph[paragraph.id] ?? []).map(\.id) else {
                throw CoreError.invalidDocument("paragraph unit order does not match document order")
            }
            guard let content = document.source.substring(utf16: paragraph.sourceRange) else {
                throw CoreError.invalidDocument("paragraph content unresolved")
            }
            if content.isEmpty || content.isWhitespaceOnly {
                guard paragraph.unitIDs.isEmpty else {
                    throw CoreError.invalidDocument("whitespace-only paragraph carries units")
                }
                continue
            }
            guard !referenced.isEmpty else {
                throw CoreError.invalidDocument("nonblank paragraph without units")
            }
            var cursor = paragraph.sourceRange.location
            for unit in referenced {
                guard unit.sourceRange.location == cursor else {
                    throw CoreError.invalidDocument("unit partition has a gap or overlap")
                }
                cursor = unit.sourceRange.end ?? -1
            }
            guard cursor == paragraph.sourceRange.end else {
                throw CoreError.invalidDocument("unit partition does not cover the paragraph")
            }
        }

        // Translations: source order, unique, referenced, validated text.
        var translatedIDs = Set<UUID>()
        var previousTranslationLocation = -1
        for translation in document.translations {
            guard translatedIDs.insert(translation.unitID).inserted else {
                throw CoreError.invalidDocument("duplicate translation")
            }
            guard let unit = unitsByID[translation.unitID] else {
                throw CoreError.invalidDocument("translation references an unknown unit")
            }
            guard !unit.isBlank else {
                throw CoreError.invalidDocument("blank unit is translated")
            }
            let location = unit.textRange.location
            guard location > previousTranslationLocation else {
                throw CoreError.invalidDocument("translations are not in source order")
            }
            previousTranslationLocation = location
            let text = translation.text
            // Model-result rules: nonempty (independently of trimming,
            // since "".isContractTrimmed is true), trimmed, no line breaks,
            // and within the per-string byte bound.
            if text.isEmpty
                || !text.isContractTrimmed
                || text.contains("\n") || text.contains("\r")
                || TextIdentity.utf8Length(text) > WorkerContract.maxTranslationBytes {
                throw CoreError.invalidDocument("translation text violates model-output bounds")
            }
        }
        if !document.translations.isEmpty, document.jobSnapshot == nil {
            throw CoreError.invalidDocument("translations without a job snapshot")
        }

        // Job snapshot coherence. Prompt versions, profiles, provider IDs,
        // and model IDs are kept literal: snapshots from older app versions
        // still open for reading, and Resume gating is app policy.
        if let snapshot = document.jobSnapshot {
            guard snapshot.sourceLanguage != snapshot.targetLanguage else {
                throw CoreError.invalidDocument("snapshot languages must differ")
            }
            guard snapshot.sourceRevision == document.sourceRevision else {
                throw CoreError.invalidDocument("snapshot revision does not match the document")
            }
            if let resolved = document.resolvedDirection {
                let expected: [Language]
                switch resolved {
                case .zhToEn: expected = [.zh, .en]
                case .enToZh: expected = [.en, .zh]
                case .auto: expected = []
                }
                if expected == [.zh, .en] {
                    guard snapshot.sourceLanguage == .zh, snapshot.targetLanguage == .en else {
                        throw CoreError.invalidDocument("snapshot languages contradict the direction")
                    }
                } else if expected == [.en, .zh] {
                    guard snapshot.sourceLanguage == .en, snapshot.targetLanguage == .zh else {
                        throw CoreError.invalidDocument("snapshot languages contradict the direction")
                    }
                }
            }
            // Deliberately no prompt/profile validity gate here: a snapshot
            // with an unavailable old prompt/profile still opens for
            // reading; Resume gating is app policy, not codec policy.
        }

        // Reading anchor: an invalid optional anchor resets, not rejects.
        if let anchor = document.readingAnchor {
            if anchor.fraction.isFinite, anchor.fraction >= 0, anchor.fraction <= 1,
               document.paragraphs.contains(where: { $0.id == anchor.paragraphID }) {
                // keep
            } else if let first = document.paragraphs.first {
                document.readingAnchor = ReadingAnchor(paragraphID: first.id, side: .source, fraction: 0)
            } else {
                document.readingAnchor = nil
            }
        }
    }
}

// MARK: - Wire DTOs (exact field names of format v1)

private struct DocumentDTO: Codable {
    var format: String
    var schemaVersion: Int
    var documentID: UUID
    var title: String
    var source: String
    var sourceRevision: Int
    var direction: DirectionDTO
    var paragraphs: [ParagraphDTO]
    var units: [UnitDTO]
    var translations: [TranslationDTO]
    var jobSnapshot: JobSnapshotDTO?
    var layout: LayoutMode
    var readingAnchor: ReadingAnchorDTO?

    enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case documentID = "document_id"
        case title
        case source
        case sourceRevision = "source_revision"
        case direction
        case paragraphs
        case units
        case translations
        case jobSnapshot = "job_snapshot"
        case layout
        case readingAnchor = "reading_anchor"
    }

    init(_ document: BiparaDocument) {
        format = DocumentCodec.formatName
        schemaVersion = DocumentCodec.schemaVersion
        documentID = document.documentID
        title = document.title
        source = document.source
        sourceRevision = document.sourceRevision
        direction = DirectionDTO(requested: document.requestedDirection, resolved: document.resolvedDirection)
        paragraphs = document.paragraphs.map(ParagraphDTO.init)
        units = document.units.map(UnitDTO.init)
        translations = document.translations.map(TranslationDTO.init)
        jobSnapshot = document.jobSnapshot.map(JobSnapshotDTO.init)
        layout = document.layout
        readingAnchor = document.readingAnchor.map(ReadingAnchorDTO.init)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required nullable fields must be present; explicit null is the
        // only legal empty form. Missing keys are corrupt content.
        for key: CodingKeys in [.jobSnapshot, .readingAnchor] {
            guard container.contains(key) else {
                throw DecodingError.keyNotFound(key, .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "required nullable field is missing"
                ))
            }
        }
        format = try container.decode(String.self, forKey: .format)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        documentID = try container.decode(UUID.self, forKey: .documentID)
        title = try container.decode(String.self, forKey: .title)
        source = try container.decode(String.self, forKey: .source)
        sourceRevision = try container.decode(Int.self, forKey: .sourceRevision)
        direction = try container.decode(DirectionDTO.self, forKey: .direction)
        paragraphs = try container.decode([ParagraphDTO].self, forKey: .paragraphs)
        units = try container.decode([UnitDTO].self, forKey: .units)
        translations = try container.decode([TranslationDTO].self, forKey: .translations)
        jobSnapshot = try container.decodeIfPresent(JobSnapshotDTO.self, forKey: .jobSnapshot)
        layout = try container.decode(LayoutMode.self, forKey: .layout)
        readingAnchor = try container.decodeIfPresent(ReadingAnchorDTO.self, forKey: .readingAnchor)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(title, forKey: .title)
        try container.encode(source, forKey: .source)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(direction, forKey: .direction)
        try container.encode(paragraphs, forKey: .paragraphs)
        try container.encode(units, forKey: .units)
        try container.encode(translations, forKey: .translations)
        if let jobSnapshot {
            try container.encode(jobSnapshot, forKey: .jobSnapshot)
        } else {
            try container.encodeNil(forKey: .jobSnapshot)
        }
        try container.encode(layout, forKey: .layout)
        if let readingAnchor {
            try container.encode(readingAnchor, forKey: .readingAnchor)
        } else {
            try container.encodeNil(forKey: .readingAnchor)
        }
    }
}

private struct DirectionDTO: Codable {
    var requested: Direction
    var resolved: Direction?

    enum CodingKeys: String, CodingKey {
        case requested
        case resolved
    }

    init(requested: Direction, resolved: Direction?) {
        self.requested = requested
        self.resolved = resolved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.resolved) else {
            throw DecodingError.keyNotFound(CodingKeys.resolved, .init(
                codingPath: decoder.codingPath,
                debugDescription: "required nullable field direction.resolved is missing"
            ))
        }
        requested = try container.decode(Direction.self, forKey: .requested)
        resolved = try container.decodeIfPresent(Direction.self, forKey: .resolved)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requested, forKey: .requested)
        // Required nullable fields are written explicitly as null.
        if let resolved {
            try container.encode(resolved, forKey: .resolved)
        } else {
            try container.encodeNil(forKey: .resolved)
        }
    }
}

private struct RangeDTO: Codable {
    var location: Int
    var length: Int

    init(_ range: TextRange) {
        location = range.location
        length = range.length
    }

    var value: TextRange { TextRange(location: location, length: length) }
}

private struct ParagraphDTO: Codable {
    var id: UUID
    var sourceRange: RangeDTO
    var separatorRange: RangeDTO
    var unitIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case id
        case sourceRange = "source_range"
        case separatorRange = "separator_range"
        case unitIDs = "unit_ids"
    }

    init(_ paragraph: PlannedParagraph) {
        id = paragraph.id
        sourceRange = RangeDTO(paragraph.sourceRange)
        separatorRange = RangeDTO(paragraph.separatorRange)
        unitIDs = paragraph.unitIDs
    }

    var value: PlannedParagraph {
        PlannedParagraph(
            id: id,
            sourceRange: sourceRange.value,
            separatorRange: separatorRange.value,
            unitIDs: unitIDs
        )
    }
}

private struct UnitDTO: Codable {
    var id: UUID
    var paragraphID: UUID
    var sourceRange: RangeDTO
    var textRange: RangeDTO
    var kind: UnitKind

    enum CodingKeys: String, CodingKey {
        case id
        case paragraphID = "paragraph_id"
        case sourceRange = "source_range"
        case textRange = "text_range"
        case kind
    }

    init(_ unit: PlannedUnit) {
        id = unit.id
        paragraphID = unit.paragraphID
        sourceRange = RangeDTO(unit.sourceRange)
        textRange = RangeDTO(unit.textRange)
        kind = unit.kind
    }

    var value: PlannedUnit {
        PlannedUnit(
            id: id,
            paragraphID: paragraphID,
            sourceRange: sourceRange.value,
            textRange: textRange.value,
            kind: kind
        )
    }
}

private struct TranslationDTO: Codable {
    var unitID: UUID
    var text: String
    var returnedModel: String?
    var completedAt: Date

    enum CodingKeys: String, CodingKey {
        case unitID = "unit_id"
        case text
        case returnedModel = "returned_model"
        case completedAt = "completed_at"
    }

    init(_ translation: UnitTranslation) {
        unitID = translation.unitID
        text = translation.text
        returnedModel = translation.returnedModel
        completedAt = translation.completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // returned_model is nullable but required: explicit null only.
        guard container.contains(CodingKeys.returnedModel) else {
            throw DecodingError.keyNotFound(CodingKeys.returnedModel, .init(
                codingPath: decoder.codingPath,
                debugDescription: "required nullable field returned_model is missing"
            ))
        }
        unitID = try container.decode(UUID.self, forKey: .unitID)
        text = try container.decode(String.self, forKey: .text)
        returnedModel = try container.decodeIfPresent(String.self, forKey: .returnedModel)
        let raw = try container.decode(String.self, forKey: .completedAt)
        guard let date = ISO8601Transcoder.decode(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .completedAt, in: container, debugDescription: "invalid ISO-8601 timestamp"
            )
        }
        completedAt = date
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unitID, forKey: .unitID)
        try container.encode(text, forKey: .text)
        if let returnedModel {
            try container.encode(returnedModel, forKey: .returnedModel)
        } else {
            try container.encodeNil(forKey: .returnedModel)
        }
        try container.encode(ISO8601Transcoder.encode(completedAt), forKey: .completedAt)
    }

    var value: UnitTranslation {
        UnitTranslation(
            unitID: unitID,
            text: text,
            returnedModel: returnedModel,
            completedAt: completedAt
        )
    }
}

/// UTC ISO-8601 timestamps. Encoding always writes millisecond precision so
/// a save/load cycle is byte-stable; decoding also accepts whole-second
/// stamps written by older files. Formatters are built per call: the codec
/// runs off the main actor and `ISO8601DateFormatter` is not Sendable.
private enum ISO8601Transcoder {
    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decode(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

private class JobSnapshotDTO: Codable {
    var jobID: UUID
    var sourceRevision: Int
    var sourceLanguage: Language
    var targetLanguage: Language
    var provider: String
    var model: String
    var profile: String
    /// Required in v2 files; absent in v1 files (derived on read).
    var effort: ModelEffort?
    var translationPromptVersion: String
    var alignmentPromptVersion: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case sourceRevision = "source_revision"
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case provider
        case model
        case profile
        case effort
        case translationPromptVersion = "translation_prompt_version"
        case alignmentPromptVersion = "alignment_prompt_version"
    }

    init(_ snapshot: JobSnapshot) {
        jobID = snapshot.jobID
        sourceRevision = snapshot.sourceRevision
        sourceLanguage = snapshot.sourceLanguage
        targetLanguage = snapshot.targetLanguage
        provider = snapshot.provider
        model = snapshot.model
        profile = snapshot.profile
        effort = snapshot.effort
        translationPromptVersion = snapshot.translationPromptVersion
        alignmentPromptVersion = snapshot.alignmentPromptVersion
    }

    var value: JobSnapshot {
        JobSnapshot(
            jobID: jobID,
            sourceRevision: sourceRevision,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: provider,
            model: model,
            profile: profile,
            effort: effort ?? .auto,
            translationPromptVersion: translationPromptVersion,
            alignmentPromptVersion: alignmentPromptVersion
        )
    }
}

private struct ReadingAnchorDTO: Codable {
    var paragraphID: UUID
    var side: ReadingSide
    var fraction: Double

    enum CodingKeys: String, CodingKey {
        case paragraphID = "paragraph_id"
        case side
        case fraction
    }

    init(_ anchor: ReadingAnchor) {
        paragraphID = anchor.paragraphID
        side = anchor.side
        fraction = anchor.fraction
    }

    var value: ReadingAnchor {
        ReadingAnchor(paragraphID: paragraphID, side: side, fraction: fraction)
    }
}
