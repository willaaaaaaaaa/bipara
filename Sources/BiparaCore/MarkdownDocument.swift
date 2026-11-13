import Foundation

extension BiparaDocument {
    public var isMarkdown: Bool { markdownResolved }
    public var canUseMarkdownPlan: Bool { !isMarkdown || markdownPlan != nil }

    public var translationPromptVersion: String {
        isMarkdown ? WorkerContract.markdownTranslationPromptVersion : WorkerContract.currentTranslationPromptVersion
    }

    public func requestText(for unit: PlannedUnit) -> String? {
        if isMarkdown { return markdownPlan?.requestText(for: unit) }
        return source.substring(utf16: unit.textRange)
    }

    public func visibleUnitText(_ unitID: UUID, side: ReadingSide) -> String? {
        guard let unit = units.first(where: { $0.id == unitID }) else { return nil }
        let text = side == .source ? requestText(for: unit) : translations.first(where: { $0.unitID == unitID })?.text
        guard isMarkdown else { return text }
        guard let plan = markdownPlan, let text,
              let inline = try? MarkdownInline(text, references: plan.references) else { return nil }
        return inline.visible
    }

    public func markdownProjection() -> MarkdownReadingProjection? {
        guard isMarkdown else { return nil }
        guard let plan = markdownPlan else {
            return .init(groups: [.init(id: documentID,
                source: [.init(id: documentID, kind: .literal, runs: [.init(source)])],
                translation: translations.map { .init(id: $0.unitID, kind: .literal, runs: [.init($0.text)]) }
            )], isSourceMode: true)
        }
        return plan.projection(translations: translations, language: jobSnapshot?.targetLanguage ?? .zh, mode: readingMode)
    }

    public func markdownExport(bilingual: Bool, plain: Bool, allowPartial: Bool) -> String? {
        markdownPlan?.export(translations: translations, language: jobSnapshot?.targetLanguage ?? .zh,
                             bilingual: bilingual, plain: plain, partial: allowPartial)
    }
}

extension MarkdownPlan {
    private var groups: [[Top]] {
        guard tops.contains(where: \.startsSection) else { return tops.map { [$0] } }
        var result: [[Top]] = []
        for top in tops {
            if result.isEmpty || top.startsSection { result.append([top]) }
            else { result[result.count - 1].append(top) }
        }
        return result
    }

    func projection(translations: [UnitTranslation], language: Language, mode: MarkdownReadingMode) -> MarkdownReadingProjection {
        let values = Dictionary(uniqueKeysWithValues: translations.map { ($0.unitID, $0.text) })
        let headingAnchors = anchors()
        let result: [MarkdownReadingGroup] = groups.compactMap { group in
            guard let id = group.first?.id else { return nil }
            if mode == .source {
                let original = group.flatMap { sourceBlocks($0, values: nil, language: language) }
                let translated = group.flatMap { sourceBlocks($0, values: values, language: language) }
                return .init(id: id, source: original, translation: translated)
            }
            let original = group.flatMap { top in
                top.isMetadata ? sourceBlocks(top, values: nil, language: language)
                    : top.blocks.map { rendered($0, values: nil, language: language, anchors: headingAnchors) }
            }
            let translated = group.flatMap { top -> [MarkdownReadingBlock] in
                if top.isMetadata { return sourceBlocks(top, values: values, language: language) }
                let ready = completedBlocks(top.blocks, values: values)
                return ready.map { rendered($0, values: values, language: language, anchors: headingAnchors) }
            }
            return .init(id: id, source: original, translation: translated)
        }
        return .init(groups: result, isSourceMode: mode == .source)
    }

    private func anchors() -> [String: UUID] {
        var candidates: [String: [UUID]] = [:]
        for top in tops where top.startsSection {
            guard let block = top.blocks.first, let inline = try? MarkdownInline(block.payload, references: references) else { continue }
            let slug = inline.visible.lowercased().unicodeScalars.compactMap { scalar -> String? in
                if scalar.properties.isWhitespace { return "-" }
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" { return String(scalar) }
                return nil
            }.joined()
            if !slug.isEmpty { candidates[slug, default: []].append(block.id) }
        }
        return candidates.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private func rendered(_ block: Block, values: [UUID: String]?, language: Language, anchors: [String: UUID]) -> MarkdownReadingBlock {
        let unitTexts = block.units.compactMap { id -> (UUID, String)? in
            (values == nil ? requestPayload(id) : values?[id]).map { (id, $0) }
        }
        let runs: [MarkdownReadingRun]
        if let literal = block.literal {
            runs = [.init(literal)]
        } else if unitTexts.isEmpty {
            runs = (try? MarkdownInline(block.payload, references: references).runs) ?? [.init(block.payload)]
        } else {
            var result: [MarkdownReadingRun] = []
            for (index, pair) in unitTexts.enumerated() {
                if index > 0, values == nil || language == .en { result.append(.init(" ")) }
                let (id, text) = pair
                let inline = (try? MarkdownInline(text, references: references).runs) ?? [.init(text)]
                var offset = 0
                for run in inline {
                    let length = run.text.utf16.count
                    let target = run.destination.flatMap { destination in
                        destination.hasPrefix("#") ? anchors[String(destination.dropFirst()).removingPercentEncoding ?? ""] : nil
                    }
                    let selectable = !run.style.contains(.code) && run.text != "◫ " && !run.text.contains("\n")
                    result.append(.init(run.text, style: run.style, destination: run.destination, linkTargetBlockID: target,
                        unitID: selectable ? id : nil, visibleRange: selectable ? .init(location: offset, length: length) : nil))
                    offset += length
                }
            }
            runs = result
        }
        return .init(id: block.id, kind: block.kind, runs: runs, listDepth: block.listDepth, quoteDepth: block.quoteDepth, marker: block.marker)
    }

    private func completedBlocks(_ blocks: [Block], values: [UUID: String]) -> [Block] {
        var pendingRows: [UUID: Set<Int>] = [:]
        for block in blocks {
            if case let .tableCell(cell) = block.kind,
               !block.units.allSatisfy({ values[$0] != nil }) {
                pendingRows[cell.tableID, default: []].insert(cell.row)
            }
        }
        return blocks.filter { block in
            guard block.units.allSatisfy({ values[$0] != nil }) else { return false }
            if case let .tableCell(cell) = block.kind, let rows = pendingRows[cell.tableID] {
                return !rows.contains(0) && !rows.contains(cell.row)
            }
            return true
        }
    }

    private func sourceBlocks(_ top: Top, values: [UUID: String]?, language: Language) -> [MarkdownReadingBlock] {
        guard let raw = source.substring(utf16: top.range) else { return [] }
        let blocks = top.blocks
        if top.isMetadata {
            guard values == nil || blocks.allSatisfy({ block in block.units.allSatisfy { values?[$0] != nil } }) else { return [] }
            let text = values.map { replacing(raw, offset: top.range.location, blocks: blocks, values: $0, language: language) } ?? raw
            return [.init(id: top.id, kind: .literal, runs: [.init(text)])]
        }
        let visible = values.map { Set(completedBlocks(blocks, values: $0).map(\.id)) }
        var result: [MarkdownReadingBlock] = []
        var cursor = top.range.location
        for (index, block) in blocks.enumerated() {
            var next = index + 1 < blocks.count ? blocks[index + 1].range.location : top.range.end ?? cursor
            if index + 1 < blocks.count {
                // List/quote prefixes belong to the following block, not the
                // preceding block's alignment spacer. Table cells share lines.
                if case .tableCell = blocks[index + 1].kind {} else {
                    let lineStart = (source as NSString).lineRange(for: NSRange(location: next, length: 0)).location
                    if lineStart > cursor { next = lineStart }
                }
            }
            guard next >= cursor,
                  let slice = source.substring(utf16: .init(location: cursor, length: next - cursor)) else { continue }
            if let visible, !visible.contains(block.id) {
                cursor = next
                continue
            }
            let text = values.map { replacing(slice, offset: cursor, blocks: [block], values: $0, language: language) } ?? slice
            result.append(.init(id: block.id, kind: block.kind, runs: [.init(text)]))
            cursor = next
        }
        return result.isEmpty && values == nil ? [.init(id: top.id, kind: .literal, runs: [.init(raw)])] : result
    }

    func export(translations: [UnitTranslation], language: Language, bilingual: Bool, plain: Bool, partial: Bool) -> String? {
        let values = Dictionary(uniqueKeysWithValues: translations.map { ($0.unitID, $0.text) })
        let complete = units.allSatisfy { values[$0.id] != nil }
        guard complete || partial || bilingual else { return nil }
        if !bilingual, !plain, complete { return replacedSource(using: values, language: language) }
        let ready: (Top) -> Bool = { top in top.blocks.allSatisfy { $0.units.allSatisfy { values[$0] != nil } } }
        let groupText: ([Top], Bool) -> String = { group, target in
            group.filter { !target || ready($0) }.compactMap { top in
                if top.isMetadata {
                    guard let raw = source.substring(utf16: top.range) else { return nil }
                    return target ? replacing(raw, offset: top.range.location, blocks: top.blocks, values: values, language: language) : raw
                }
                if plain {
                    return top.blocks.map { block in
                        let display = rendered(block, values: target ? values : nil, language: language, anchors: [:])
                        return (display.marker.map { $0 + " " } ?? "") + display.runs.map(\.text).joined()
                    }.joined(separator: "\n")
                }
                guard let raw = source.substring(utf16: top.range) else { return nil }
                return target ? replacing(raw, offset: top.range.location, blocks: top.blocks, values: values, language: language) : raw
            }.joined(separator: "\n\n")
        }
        if !bilingual {
            let selected = tops.filter(ready)
            guard !selected.isEmpty || complete else { return nil }
            let body = groupText(selected, true)
            let definitions = plain ? "" : references.definitions(for: body)
            return definitions.isEmpty ? body : body + "\n\n" + definitions
        }
        let body = groups.map { group in
            let target = groupText(group, true)
            let missing = group.contains { !ready($0) }
            let label = plain ? "Translation" : "**Translation**"
            let status = missing ? "\n\n[Untranslated blocks omitted]" : ""
            return (plain ? "Original" : "**Original**") + "\n\n" + groupText(group, false)
                + "\n\n" + label + "\n\n" + target + status
        }.joined(separator: "\n\n")
        let definitions = plain ? "" : references.definitions(for: body)
        // Prepend the effective reference map so reordered sections cannot
        // give a later duplicate definition precedence over the original.
        return definitions.isEmpty ? body : definitions + "\n\n" + body
    }
}
