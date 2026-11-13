import Foundation
import NaturalLanguage

/// A planned paragraph: exact content range, its trailing separator range,
/// and ordered unit IDs. Whitespace-only paragraphs carry no units.
public struct PlannedParagraph: Equatable, Sendable, Codable {
    public var id: UUID
    public var sourceRange: TextRange
    public var separatorRange: TextRange
    public var unitIDs: [UUID]

    public init(id: UUID, sourceRange: TextRange, separatorRange: TextRange, unitIDs: [UUID]) {
        self.id = id
        self.sourceRange = sourceRange
        self.separatorRange = separatorRange
        self.unitIDs = unitIDs
    }
}

/// A planned translation unit inside one paragraph revision. The full
/// source range participates in the paragraph partition; `textRange` lies
/// within it and holds the trimmed model input.
public struct PlannedUnit: Equatable, Sendable, Codable {
    public var id: UUID
    public var paragraphID: UUID
    public var sourceRange: TextRange
    public var textRange: TextRange
    public var kind: UnitKind

    public init(id: UUID, paragraphID: UUID, sourceRange: TextRange, textRange: TextRange, kind: UnitKind) {
        self.id = id
        self.paragraphID = paragraphID
        self.sourceRange = sourceRange
        self.textRange = textRange
        self.kind = kind
    }

    /// Blank units (empty trimmed text) never travel to a provider.
    public var isBlank: Bool { textRange.isEmpty }
}

/// The complete, lossless plan of one source revision.
public struct SourcePlan: Equatable, Sendable {
    public var source: String
    public var paragraphs: [PlannedParagraph]
    public var units: [PlannedUnit]

    public var markdownPlan: MarkdownPlan?

    public init(source: String, paragraphs: [PlannedParagraph], units: [PlannedUnit], markdownPlan: MarkdownPlan? = nil) {
        self.source = source
        self.paragraphs = paragraphs
        self.units = units
        self.markdownPlan = markdownPlan
    }

    public var nonblankUnits: [PlannedUnit] { units.filter { !$0.isBlank } }
}

/// A dispatch batch: ordered units plus clipped source context.
public struct TranslationBatch: Equatable, Sendable {
    public var unitIDs: [UUID]
    public var contextBefore: String
    public var contextAfter: String

    public init(unitIDs: [UUID], contextBefore: String, contextAfter: String) {
        self.unitIDs = unitIDs
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

/// Paragraph/unit/batch planning per the model workflow contract.
public enum SourcePlanner {
    public static func plan(_ source: String) throws -> SourcePlan {
        guard TextIdentity.utf8Length(source) <= WorkerContract.maxSourceUTF8Bytes else {
            throw CoreError.inputTooLarge(
                actualBytes: TextIdentity.utf8Length(source),
                maxBytes: WorkerContract.maxSourceUTF8Bytes
            )
        }
        let paragraphs = try planParagraphs(source)
        var units: [PlannedUnit] = []
        var plannedParagraphs = paragraphs
        for index in plannedParagraphs.indices {
            let paragraph = plannedParagraphs[index]
            guard let content = source.substring(utf16: paragraph.sourceRange) else {
                throw CoreError.rangeViolation("paragraph range failed to resolve")
            }
            guard !content.isWhitespaceOnly else { continue }
            let planned = try planUnits(in: content, paragraphOffset: paragraph.sourceRange.location, paragraph: paragraph, source: source)
            plannedParagraphs[index].unitIDs = planned.map(\.id)
            units.append(contentsOf: planned)
        }
        return SourcePlan(source: source, paragraphs: plannedParagraphs, units: units)
    }

    /// Splits at CR, LF, or CRLF, keeping exact ranges and separators.
    /// No phantom paragraph after a trailing separator; empty source has
    /// no paragraphs.
    static func planParagraphs(_ source: String) throws -> [PlannedParagraph] {
        let scalars = Array(source.utf16)
        var paragraphs: [PlannedParagraph] = []
        var start = 0
        let length = scalars.count
        while start < length {
            var index = start
            var separatorLength = 0
            while index < length {
                let unit = scalars[index]
                if unit == 0x0A { separatorLength = 1; break }
                if unit == 0x0D {
                    separatorLength = (index + 1 < length && scalars[index + 1] == 0x0A) ? 2 : 1
                    break
                }
                index += 1
            }
            if separatorLength == 0 {
                // Final paragraph without trailing separator.
                paragraphs.append(PlannedParagraph(
                    id: UUID(),
                    sourceRange: TextRange(location: start, length: index - start),
                    separatorRange: TextRange(location: length, length: 0),
                    unitIDs: []
                ))
                break
            }
            paragraphs.append(PlannedParagraph(
                id: UUID(),
                sourceRange: TextRange(location: start, length: index - start),
                separatorRange: TextRange(location: index, length: separatorLength),
                unitIDs: []
            ))
            start = index + separatorLength
        }
        try validateParagraphPartition(paragraphs, totalLength: length)
        return paragraphs
    }

    static func validateParagraphPartition(_ paragraphs: [PlannedParagraph], totalLength: Int) throws {
        guard totalLength > 0 || paragraphs.isEmpty else {
            throw CoreError.rangeViolation("empty source cannot have paragraphs")
        }
        var cursor = 0
        for (index, paragraph) in paragraphs.enumerated() {
            guard paragraph.sourceRange.location == cursor,
                  let contentEnd = paragraph.sourceRange.end,
                  paragraph.separatorRange.location == contentEnd,
                  let separatorEnd = paragraph.separatorRange.end else {
                throw CoreError.rangeViolation("paragraph partition is not contiguous")
            }
            // Only the final paragraph may carry a zero-length separator;
            // every earlier separator must be an actual CR/LF/CRLF run.
            if index < paragraphs.count - 1 {
                guard paragraph.separatorRange.length == 1 || paragraph.separatorRange.length == 2 else {
                    throw CoreError.rangeViolation("non-final paragraph separator is empty")
                }
            } else {
                guard paragraph.separatorRange.length <= 2 else {
                    throw CoreError.rangeViolation("separator is longer than a CR/LF/CRLF run")
                }
                // A trailing paragraph with neither content nor separator is
                // fabricated; the planner never emits one (empty sources
                // have no paragraphs at all).
                guard paragraph.sourceRange.length > 0 || paragraph.separatorRange.length > 0 else {
                    throw CoreError.rangeViolation("trailing phantom paragraph")
                }
            }
            cursor = separatorEnd
        }
        guard cursor == totalLength else {
            throw CoreError.rangeViolation("paragraph partition does not cover the source")
        }
    }

    /// Sentence units via NLTokenizer, completed into a full partition,
    /// then oversized sentences split into fragments. Whitespace-only
    /// tokenizer candidates (e.g. U+2028/U+2029 runs) are gaps, not units:
    /// they attach to neighboring units so every stored unit carries
    /// nonempty trimmed text.
    static func planUnits(in content: String, paragraphOffset: Int, paragraph: PlannedParagraph, source: String) throws -> [PlannedUnit] {
        let candidates = sentenceCandidates(in: content).filter { range in
            guard let text = content.substring(utf16: range) else { return false }
            return !(text.isEmpty || text.isWhitespaceOnly)
        }
        let merged = mergeIntoPartition(candidates: candidates, contentLength: content.utf16.count)
        var units: [PlannedUnit] = []
        for entry in merged {
            let full = entry
            guard let unitSource = content.substring(utf16: full) else {
                throw CoreError.rangeViolation("unit range failed to resolve")
            }
            let (leading, core, _) = unitSource.trimmingWhitespaceSplit()
            let innerLocation = full.location + leading.utf16.count
            let innerLength = core.utf16.count
            let inner = TextRange(location: innerLocation, length: innerLength)
            let unit = PlannedUnit(
                id: UUID(),
                paragraphID: paragraph.id,
                sourceRange: full.offset(by: paragraphOffset)!,
                textRange: inner.offset(by: paragraphOffset)!,
                kind: .sentence
            )
            if TextIdentity.utf8Length(core) > WorkerContract.maxSentenceUTF8Bytes {
                units.append(contentsOf: try splitOversized(unit, content: content, offset: paragraphOffset))
            } else {
                units.append(unit)
            }
        }
        return units
    }

    /// NLTokenizer sentence candidates as UTF-16 ranges within the paragraph.
    static func sentenceCandidates(in content: String) -> [TextRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = content
        var ranges: [TextRange] = []
        tokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
            let location = content.utf16.distance(from: content.utf16.startIndex, to: range.lowerBound.samePosition(in: content.utf16) ?? content.utf16.startIndex)
            let length = content.utf16.distance(
                from: range.lowerBound.samePosition(in: content.utf16) ?? content.utf16.startIndex,
                to: range.upperBound.samePosition(in: content.utf16) ?? content.utf16.startIndex
            )
            ranges.append(TextRange(location: location, length: length))
            return true
        }
        return ranges
    }

    /// Completes candidate ranges (ordered, possibly gappy or empty) into a
    /// full, nonoverlapping partition of [0, contentLength). Gaps attach to
    /// the previous unit; leading/trailing gaps extend the first/last unit.
    static func mergeIntoPartition(candidates: [TextRange], contentLength: Int) -> [TextRange] {
        let normalized = candidates
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        var merged: [TextRange] = []
        var cursor = 0
        for candidate in normalized {
            let start = max(candidate.location, cursor)
            guard let end = candidate.end, end > start else { continue }
            if start > cursor, var previous = merged.popLast() {
                previous = TextRange(location: previous.location, length: start - previous.location)
                merged.append(previous)
            }
            merged.append(TextRange(location: start, length: end - start))
            cursor = end
        }
        if merged.isEmpty {
            return contentLength > 0 ? [TextRange(location: 0, length: contentLength)] : []
        }
        if merged[0].location > 0, let firstEnd = merged[0].end {
            merged[0] = TextRange(location: 0, length: firstEnd)
        }
        if let last = merged.last, let lastEnd = last.end, lastEnd < contentLength {
            merged[merged.count - 1] = TextRange(location: last.location, length: contentLength - last.location)
        }
        return merged
    }

    /// Splits an oversized sentence at the last clause punctuation or
    /// whitespace boundary within the byte limit, else at a
    /// composed-character boundary. All pieces become fragments.
    /// Every emitted range is in document coordinates. Piece texts never
    /// begin or end with whitespace: the split boundary may sit on a
    /// whitespace cluster, but the piece's text then ends at the last
    /// non-whitespace cluster at or before that boundary, and the skipped
    /// whitespace run becomes boundary whitespace carried by the following
    /// fragment's source range (never its text range). This keeps the
    /// required punctuation/whitespace split preference while every unit
    /// satisfies the trimmed-text rule the worker and the codec enforce.
    static func splitOversized(_ unit: PlannedUnit, content: String, offset: Int) throws -> [PlannedUnit] {
        let limit = WorkerContract.maxSentenceUTF8Bytes
        // `content` is the paragraph-local string; the unit's ranges are
        // document-global. Cluster offsets stay local and are converted
        // once, at emission, through the global core location.
        let coreGlobalLocation = unit.textRange.location
        let coreLocalRange = TextRange(location: coreGlobalLocation - offset, length: unit.textRange.length)
        guard let core = content.substring(utf16: coreLocalRange), !core.isEmpty else {
            throw CoreError.rangeViolation("split range failed to resolve")
        }
        struct Cluster {
            var offset: Int
            var utf16: Int
            var utf8: Int
            var whitespace: Bool
            var breakable: Bool
        }
        var clusters: [Cluster] = []
        var clusterOffset = 0
        for cluster in core {
            let size = TextIdentity.utf8Length(String(cluster))
            if size > limit {
                throw CoreError.unsupportedInput("a single composed character exceeds the unit byte bound")
            }
            let whitespace = Array(cluster.unicodeScalars).allSatisfy { $0.isContractWhitespace }
            clusters.append(Cluster(
                offset: clusterOffset,
                utf16: cluster.utf16.count,
                utf8: size,
                whitespace: whitespace,
                breakable: isClauseBoundary(cluster)
            ))
            clusterOffset += cluster.utf16.count
        }

        // Greedy byte-limited windows over cluster indices. Within a window
        // the split boundary prefers the last breakable cluster (punctuation
        // OR whitespace); the piece text ends at the last non-whitespace
        // cluster at or before that boundary.
        var pieces: [(textStart: Int, textEnd: Int)] = []  // local UTF-16 offsets
        var windowStart = 0
        while windowStart < clusters.count {
            var windowEnd = windowStart
            var bytes = clusters[windowStart].utf8
            while windowEnd + 1 < clusters.count, bytes + clusters[windowEnd + 1].utf8 <= limit {
                windowEnd += 1
                bytes += clusters[windowEnd].utf8
            }
            guard let textStartIndex = (windowStart...windowEnd).first(where: { !clusters[$0].whitespace }) else {
                // Entirely-whitespace window (a >limit whitespace run): all
                // of it is boundary whitespace; no text piece is emitted.
                windowStart = windowEnd + 1
                continue
            }
            let boundaryIndex: Int
            if windowEnd + 1 >= clusters.count {
                boundaryIndex = windowEnd
            } else if let lastBreakable = (textStartIndex...windowEnd).last(where: { clusters[$0].breakable }) {
                boundaryIndex = lastBreakable
            } else {
                boundaryIndex = windowEnd
            }
            guard let textEndIndex = (textStartIndex...boundaryIndex).last(where: { !clusters[$0].whitespace }) else {
                throw CoreError.rangeViolation("split produced an empty text piece")
            }
            pieces.append((
                textStart: clusters[textStartIndex].offset,
                textEnd: clusters[textEndIndex].offset + clusters[textEndIndex].utf16
            ))
            windowStart = boundaryIndex + 1
        }
        guard !pieces.isEmpty else {
            throw CoreError.rangeViolation("oversized split produced no pieces")
        }

        // Tile the unit's full source range in document coordinates: the
        // first fragment's source range keeps the unit's leading whitespace,
        // the last keeps the trailing whitespace, and each later fragment's
        // source range opens with the whitespace run left behind.
        return pieces.enumerated().map { index, piece in
            let textStart = coreGlobalLocation + piece.textStart
            let textEnd = coreGlobalLocation + piece.textEnd
            let sourceStart = index == 0 ? unit.sourceRange.location : pieces[index - 1].textEnd + coreGlobalLocation
            let sourceEnd = index == pieces.count - 1 ? unit.sourceRange.end! : textEnd
            return PlannedUnit(
                id: UUID(),
                paragraphID: unit.paragraphID,
                sourceRange: TextRange(location: sourceStart, length: sourceEnd - sourceStart),
                textRange: TextRange(location: textStart, length: textEnd - textStart),
                kind: .fragment
            )
        }
    }

    /// A preferred split boundary: any cluster composed solely of the
    /// shared contract-whitespace set (Unicode White_Space plus
    /// U+001C-U+001F, matching Python's `str.strip()` semantics used by
    /// the worker and the codec), or a single-scalar clause punctuation.
    static func isClauseBoundary(_ cluster: Character) -> Bool {
        let scalars = Array(cluster.unicodeScalars)
        if scalars.allSatisfy({ $0.isContractWhitespace }) {
            return true
        }
        guard scalars.count == 1 else { return false }
        return "，。！？；：、．,.!?;:）)」』\"'".unicodeScalars.contains(scalars[0])
    }

    /// Greedy ordered batches: at most 64 units and 8192 UTF-8 bytes of
    /// unit text, crossing paragraphs; blank units never batch.
    public static func formBatches(_ plan: SourcePlan) throws -> [TranslationBatch] {
        if let markdown = plan.markdownPlan { return try markdownBatches(plan, markdown: markdown) }
        let units = plan.nonblankUnits
        var batches: [TranslationBatch] = []
        var current: [PlannedUnit] = []
        var currentBytes = 0
        func closeBatch() {
            guard !current.isEmpty else { return }
            let first = current.first!, last = current.last!
            batches.append(TranslationBatch(
                unitIDs: current.map(\.id),
                contextBefore: clippedContext(
                    source: plan.source, before: first.textRange.location, limit: WorkerContract.maxContextBytes
                ),
                contextAfter: clippedContext(
                    source: plan.source, after: last.textRange.end ?? 0, limit: WorkerContract.maxContextBytes
                )
            ))
            current = []
            currentBytes = 0
        }
        for unit in units {
            guard let text = plan.source.substring(utf16: unit.textRange) else {
                throw CoreError.rangeViolation("unit text failed to resolve")
            }
            let bytes = TextIdentity.utf8Length(text)
            if !current.isEmpty,
               current.count >= WorkerContract.maxUnitsPerBatch || currentBytes + bytes > WorkerContract.maxBatchTextBytes {
                closeBatch()
            }
            current.append(unit)
            currentBytes += bytes
        }
        closeBatch()
        return batches
    }

    private static func markdownBatches(_ plan: SourcePlan, markdown: MarkdownPlan) throws -> [TranslationBatch] {
        var result: [TranslationBatch] = []
        var units: [PlannedUnit] = []
        var bytes = 0
        func batch(_ units: [PlannedUnit]) throws -> TranslationBatch {
            let before = clippedContext(source: plan.source, before: units[0].textRange.location, limit: WorkerContract.maxContextBytes)
            let after = clippedContext(source: plan.source, after: units[units.count - 1].textRange.end ?? 0, limit: WorkerContract.maxContextBytes)
            let rows = units.map { ["unit_id": $0.id.uuidString.lowercased(), "kind": $0.kind.rawValue, "text": markdown.requestText(for: $0) ?? ""] }
            let object: [String: Any] = ["source_language": "en", "target_language": "zh", "context_before": before, "context_after": after, "units": rows]
            guard try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]).count <= WorkerContract.maxInputJSONBytes else {
                throw CoreError.unsupportedInput("A Markdown translation request exceeds the serialized byte limit.")
            }
            return TranslationBatch(unitIDs: units.map(\.id), contextBefore: before, contextAfter: after)
        }
        for unit in plan.nonblankUnits {
            guard let text = markdown.requestText(for: unit), !text.isEmpty else { throw MarkdownPlan.invalidPlan }
            let width = text.utf8.count
            guard width <= WorkerContract.maxBatchTextBytes else { throw MarkdownPlan.invalidPlan }
            if !units.isEmpty, (bytes + width > WorkerContract.maxBatchTextBytes
                || units.count == WorkerContract.maxUnitsPerBatch || (try? batch(units + [unit])) == nil) {
                result.append(try batch(units))
                units.removeAll(keepingCapacity: true)
                bytes = 0
            }
            units.append(unit)
            bytes += width
        }
        if !units.isEmpty { result.append(try batch(units)) }
        return result
    }

    /// Up to `limit` UTF-8 bytes of source context before `location`,
    /// clipped at composed-character boundaries. `location` must already
    /// be a valid cluster boundary; traversal walks whole clusters ending
    /// at the current position, never below `startIndex`.
    static func clippedContext(source: String, before location: Int, limit: Int) -> String {
        var start = location
        var bytes = 0
        while start > 0 {
            guard let boundary = source.utf16Index(at: start), boundary > source.startIndex else { break }
            let clusterStart = source.index(before: boundary)
            let cluster = source[clusterStart..<boundary]
            let size = TextIdentity.utf8Length(String(cluster))
            if bytes + size > limit { break }
            bytes += size
            start -= cluster.utf16.count
        }
        guard location > start else { return "" }
        return source.substring(utf16: TextRange(location: start, length: location - start)) ?? ""
    }

    static func clippedContext(source: String, after location: Int, limit: Int) -> String {
        var end = location
        var bytes = 0
        let total = source.utf16.count
        while end < total {
            guard let index = source.utf16Index(at: end) else { break }
            let cluster = String(source[index])
            let size = TextIdentity.utf8Length(cluster)
            if bytes + size > limit { break }
            bytes += size
            end += cluster.utf16.count
        }
        return String(source.substring(utf16: TextRange(location: location, length: end - location)) ?? "")
    }
}
