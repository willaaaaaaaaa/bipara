import BiparaCore
import Foundation

/// View-facing per-tab presentation state; durable document content lives
/// in the Core `BiparaDocument`.
public struct TabState: Equatable, Sendable {
    public var sessionID: UUID
    public var document: BiparaDocument
    /// Uncommitted source text. Empty text is a valid draft.
    public var draftText: String {
        didSet {
            if !TextIdentity.equal(oldValue, draftText) {
                draftGeneration += 1
            }
        }
    }
    public var draftDirection: Direction {
        didSet { if oldValue != draftDirection { draftGeneration += 1 } }
    }
    public var draftFormat: ContentFormat {
        didSet { if oldValue != draftFormat { draftGeneration += 1 } }
    }
    public private(set) var draftGeneration = 0
    var markdownImportHint = false
    public var layout: LayoutMode
    public var pinnedSelectionUnitID: UUID?
    public var saveURL: URL?
    /// Content generation of the last save snapshot.
    public var savedContentGeneration: Int
    /// Increments with every committed translation batch.
    public var contentGeneration: Int
    public var job: JobModel
    public var elapsed = TranslationElapsed()
    /// Presentation metadata; does not alter source text or stable identity.
    public var automaticTitle = true
    /// Private runtime endpoint binding frozen at job creation. Never
    /// persisted, never part of dirty-state tracking, and never implied by
    /// the current default configuration.
    public var runtimeBinding: RuntimeModelBinding?

    public init(document: BiparaDocument, layout: LayoutMode = .sideBySide) {
        sessionID = UUID()
        self.document = document
        draftText = document.source
        draftDirection = document.requestedDirection
        draftFormat = document.requestedFormat
        self.layout = layout
        pinnedSelectionUnitID = nil
        saveURL = nil
        savedContentGeneration = 0
        contentGeneration = document.source.isEmpty ? 0 : 1
        job = JobModel()
        runtimeBinding = nil
    }

    var hasNoProseToTranslate: Bool {
        !isDraftDirty && document.isMarkdown && document.canUseMarkdownPlan && document.units.isEmpty
    }

    var canCopyTranslation: Bool {
        if document.isMarkdown {
            return document.canUseMarkdownPlan && document.units.count == document.translations.count
        }
        return job.state == .completed
    }

    public var isDraftDirty: Bool {
        !TextIdentity.equal(draftText, document.source)
            || draftDirection != document.requestedDirection
            || draftFormat != document.requestedFormat
    }

    /// Dirty for close/save prompts: unsaved draft edits or unsaved
    /// translation commits.
    public var isDirty: Bool {
        isDraftDirty || contentGeneration != savedContentGeneration
    }
}

/// Initial title from meaningful source, without changing source bytes.
public enum DocumentTitle {
    public static func derive(from source: String) -> String {
        for line in source.split(whereSeparator: { $0.isNewline }) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { continue }
            trimmed = trimmed.replacingOccurrences(of: #"^(?:#{1,6}\s+|[-*+>]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            if trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                var title="",scalars=0
                for character in trimmed.prefix(48) {
                    let count=character.unicodeScalars.count
                    guard scalars + count <= DocumentCodec.maxTitleCharacters else { break }
                    title.append(character);scalars += count
                }
                return title.isEmpty ? "Untitled" : title
            }
        }
        return "Untitled"
    }
}

/// MainActor workspace presentation state: independent document tabs with
/// add/switch/close, per-tab draft retention, and layout. Job scheduling
/// and gateway dispatch belong to `TranslationCoordinator`.
@MainActor
public final class WorkspaceStore: ObservableObject {
    public struct PreparedDocument: Sendable { let document: BiparaDocument }
    public enum PlanningError: Error { case documentTooLarge, staleDraft, revisionExhausted }
    @Published public private(set) var tabs: [TabState] = []
    @Published public private(set) var activeTabIndex: Int?
    private var untitledCounter = 0
    private let now: () -> ContinuousClock.Instant

    public init(now: @escaping () -> ContinuousClock.Instant = { .now }) { self.now = now }

    public var activeTab: TabState? {
        guard let index = activeTabIndex, tabs.indices.contains(index) else { return nil }
        return tabs[index]
    }

    public var isEmpty: Bool { tabs.isEmpty }

    // MARK: Tabs

    @discardableResult
    public func newTab(source: String = "", direction: Direction = .auto) throws -> Int {
        newTab(prepared:try Self.prepareDocument(source:source,direction:direction))
    }

    /// The app prepares nonempty imported/edited documents off the main actor.
    public nonisolated static func prepareDocument(
        source: String, direction: Direction, replacing old: BiparaDocument? = nil,
        format: ContentFormat = .auto, markdownHint: Bool = false
    ) throws -> PreparedDocument {
        let markdown = try MarkdownPlan.prepare(source, format: format, markdownHint: markdownHint)
        let plan = try markdown.map { SourcePlan(source: source, paragraphs: $0.paragraphs, units: $0.units, markdownPlan: $0) }
            ?? SourcePlanner.plan(source)
        var document = BiparaDocument(
            documentID: old?.documentID ?? UUID(),
            title: DocumentTitle.derive(from: source),
            source: source,
            sourceRevision: try old.map { try nextSourceRevision($0.sourceRevision) } ?? (source.isEmpty ? 0 : 1),
            requestedDirection: direction,
            resolvedDirection: nil,
            paragraphs: plan.paragraphs,
            units: plan.units,
            translations: [],
            jobSnapshot: nil,
            layout: old?.layout ?? .sideBySide,
            readingAnchor: nil
        )
        document.requestedFormat = format
        document.markdownResolved = markdown != nil
        document.markdownPlan = markdown
        document.readingMode = markdown == nil ? .source : (old?.isMarkdown == true ? old?.readingMode ?? .rendered : .rendered)
        if let old, !TextIdentity.equal(old.title,DocumentTitle.derive(from:old.source)), old.title != "Untitled" { document.title=old.title }
        guard try DocumentCodec.encode(document).count <= WorkerContract.documentFileByteLimit else { throw PlanningError.documentTooLarge }
        return PreparedDocument(document:document)
    }
    private nonisolated static func nextSourceRevision(_ revision: Int) throws -> Int {
        guard revision >= 0, revision < Int.max - 1 else { throw PlanningError.revisionExhausted }
        return revision + 1
    }
    @discardableResult
    public func newTab(prepared:PreparedDocument) -> Int {
        var document = prepared.document
        if document.title == "Untitled" {
            repeat { untitledCounter += 1 } while tabs.contains(where: { $0.document.title == "Untitled \(untitledCounter)" })
            document.title = "Untitled \(untitledCounter)"
        }
        tabs.append(TabState(document: document))
        activeTabIndex = tabs.count - 1
        return tabs.count - 1
    }

    public func switchTab(to index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
    }

    /// Removes a tab by index after the caller resolved any dirty-state
    /// confirmation. Never deletes files or touches other tabs.
    public func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if let active = activeTabIndex {
            if tabs.isEmpty {
                activeTabIndex = nil
            } else if index < active {
                activeTabIndex = active - 1
            } else if active >= tabs.count {
                activeTabIndex = tabs.count - 1
            }
        }
    }

    // MARK: Draft application

    /// Applies the tab's draft locally: replanning the source under a new
    /// revision and invalidating translations/mappings, exactly as the
    /// design's source-edit rule requires. Cancel-of-work and model
    /// cancellation are the coordinator's concern.
    public func applyDraft(at index: Int, prepared: PreparedDocument? = nil, forceReplan: Bool = false) throws {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        let newText = tab.draftText
        let newDirection = tab.draftDirection
        guard tab.isDraftDirty || forceReplan else { return }
        var document = try prepared?.document ?? Self.prepareDocument(
            source: newText, direction: newDirection, replacing: tab.document,
            format: tab.draftFormat,
            markdownHint: tab.markdownImportHint && TextIdentity.equal(tab.document.source, newText)
        ).document
        guard document.documentID == tab.document.documentID, document.sourceRevision == (try Self.nextSourceRevision(tab.document.sourceRevision)),
              TextIdentity.equal(document.source,newText), document.requestedDirection == newDirection,
              document.requestedFormat == tab.draftFormat else { throw PlanningError.staleDraft }
        if !forceReplan && Self.preservesRevision(tab, proposed: document) {
            tabs[index].document.requestedFormat = document.requestedFormat
            tabs[index].contentGeneration += 1
            return
        }
        document.layout = tab.layout
        if document.isMarkdown && tab.document.isMarkdown { document.readingMode = tab.document.readingMode }
        let priorDerived = DocumentTitle.derive(from: tab.document.source)
        let numbered = tab.document.title.range(of: #"^Untitled \d+$"#, options: .regularExpression) != nil
        if tab.automaticTitle && (tab.document.title == priorDerived || numbered) {
            let title = DocumentTitle.derive(from: newText)
            document.title = title == "Untitled" ? tab.document.title : title
        }
        if !TextIdentity.equal(tab.document.source, document.source) { tabs[index].markdownImportHint = false }
        tabs[index].document = document
        tabs[index].contentGeneration += 1
        tabs[index].job = JobModel()
        tabs[index].elapsed = TranslationElapsed()
        tabs[index].pinnedSelectionUnitID = nil
    }

    static func preservesRevision(_ tab: TabState, proposed: BiparaDocument) -> Bool {
        tab.document.canUseMarkdownPlan
            && TextIdentity.equal(tab.document.source, proposed.source)
            && tab.document.requestedDirection == proposed.requestedDirection
            && tab.document.isMarkdown == proposed.isMarkdown
    }

    public func index(of sessionID: UUID) -> Int? { tabs.firstIndex { $0.sessionID == sessionID } }

    public func openDocument(_ document: BiparaDocument, at url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let index = tabs.firstIndex(where: { $0.saveURL?.standardizedFileURL.resolvingSymlinksInPath() == canonical }) {
            activeTabIndex = index
            return
        }
        var tab = TabState(document: document, layout: document.layout)
        tab.automaticTitle = false
        tab.elapsed.sinceOpen = true
        tab.saveURL = canonical
        tab.savedContentGeneration = tab.contentGeneration
        if let snapshot = document.jobSnapshot {
            tab.job.snapshot = snapshot
            tab.job.completedUnitIDs = Set(document.translations.map(\.unitID))
            tab.job.totalNonblankUnits = document.units.count
            tab.job.state = tab.job.isFinished ? .completed : .paused
        }
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
    }

    // MARK: Mutations used by the coordinator

    public func withTab(_ index: Int, _ mutate: (inout TabState) -> Void) {
        guard tabs.indices.contains(index) else { return }
        mutate(&tabs[index])
        tabs[index].elapsed.observe(job: tabs[index].job, now: now())
    }

    @discardableResult
    func withTabAndReturn(_ index: Int, _ mutate: (inout TabState) -> Void) -> TabState? {
        guard tabs.indices.contains(index) else { return nil }
        mutate(&tabs[index])
        tabs[index].elapsed.observe(job: tabs[index].job, now: now())
        return tabs[index]
    }
}
