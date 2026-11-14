import AppKit
import BiparaCore
import BiparaWorker
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// App-owned composition and native actions. Documents stay in WorkspaceStore.
@MainActor
public final class AppRuntime: ObservableObject {
    public let workspace: WorkspaceStore
    public let settings: SettingsStore
    public let keychain: any CredentialStore
    public let appearance = AppearanceController()
    public let coordinator: TranslationCoordinator
    public let gateway: any ModelGateway
    public let files: DocumentFileService
    @Published public var editing: Set<UUID> = []
    @Published public var composing: Set<UUID> = []
    @Published public var reading: [UUID: ReadingPresentation] = [:]
    @Published public var errorMessage: String?
    @Published public var closing: Set<UUID> = []
    @Published public var focusedWindowRole: String?
    /// A pending explicit configuration-binding request for an opened
    /// document whose snapshot has no usable local runtime binding.
    @Published public var bindingRequest: BindingRequest?
    /// Set when an alert directed the user to Settings; the reading view
    /// opens the Settings window in response.
    @Published public var settingsRequested = false
    /// Test seam for scripted alert answers (consent, confirmations);
    /// production leaves it nil and the native NSAlert path runs.
    public var alertHandler: (@MainActor (String, String, [String]) async -> Int)?
    private struct DraftPlanKey: Equatable {
        let revision: Int
        let generation: Int
        let direction: Direction
    }

    private struct DraftPlanning {
        let key: DraftPlanKey
        let task: Task<WorkspaceStore.PreparedDocument, Error>
    }

    private var draftPlanning: [UUID: DraftPlanning] = [:]
    @Published private var detectedFormats: [UUID: (generation: Int, format: ContentFormat)] = [:]
    private var saveTasks: [UUID: (UUID, Task<Bool, Never>)] = [:]
    private var analysis: [UUID: Task<Void, Never>] = [:]
    private var cache: [UUID: SelectionCache] = [:]
    private var copyTask: Task<Void, Never>?
    private var disclosures: [String: Task<Bool, Never>] = [:]
    private let defaults: UserDefaults
    private var settingsObservation: AnyCancellable?

    /// An explicit session-local binding choice for one document snapshot,
    /// showing the configuration's display name and destination host.
    /// `.resume` continues translation; `.analysis` only binds phrase
    /// analysis of existing translations without retranslating.
    public struct BindingRequest: Identifiable, Equatable {
        public enum Purpose: Equatable { case resume, analysis }
        public let id = UUID()
        public let session: UUID
        public let snapshot: JobSnapshot
        public let matches: [ModelConfigurationRecord]
        public let purpose: Purpose
    }

    public init(gateway: any ModelGateway, keychain: any CredentialStore = KeychainStore(), defaults: UserDefaults = .standard,
                files: DocumentFileService = DocumentFileService()) {
        self.gateway = gateway; self.keychain = keychain; self.defaults = defaults; self.files = files
        workspace = WorkspaceStore(); settings = SettingsStore(defaults: defaults, keychain: keychain)
        coordinator = TranslationCoordinator(gateway: gateway)
        appearance.apply(settings.record.appearance)
        settingsObservation = settings.$record.dropFirst().sink { [weak self] record in
            guard let self else { return }
            self.appearance.apply(record.appearance)
            // The publisher emits before the new record is stored; use the
            // emitted language, not self.settings.record.
            self.applyLocalizedChrome(language: record.interfaceLanguage)
        }
    }

    /// The settings window title and the app-menu Settings command follow
    /// the app's interface language. SwiftUI Commands do not reliably
    /// re-evaluate observed state on this OS, so the native menu item is
    /// retitled directly alongside the window.
    func applyLocalizedChrome(language: InterfaceLanguage? = nil) {
        let localization = language ?? settings.record.interfaceLanguage
        for window in NSApp.windows where (window.delegate as? WindowLifecycle.Coordinator)?.settings == true {
            window.title = AppLocalization.text("Settings", language: localization)
        }
        if let appItems = NSApp.mainMenu?.items.first?.submenu?.items {
            for item in appItems where item.keyEquivalent == "," && !item.isSeparatorItem {
                item.title = AppLocalization.text("Settings…", language: localization)
            }
        }
    }

    public static func production() -> AppRuntime {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BiparaWorker.app/Contents/MacOS/BiparaWorker")
        return AppRuntime(gateway: PythonModelGateway(executableURL: executable))
    }
    public func text(_ key: String) -> String { AppLocalization.text(key, language: settings.record.interfaceLanguage) }
    public var activeSession: UUID? { workspace.activeTab?.sessionID }
    public var mainWindow: NSWindow? { NSApp.windows.first { ($0.delegate as? WindowLifecycle.Coordinator)?.settings == false } }

    public func newTab() {
        do { let i = try workspace.newTab(); editing.insert(workspace.tabs[i].sessionID) }
        catch { errorMessage = "This text could not be opened." }
    }
    public func setLayout(_ layout: LayoutMode) {
        guard let i = workspace.activeTabIndex else { return }
        workspace.withTab(i) { $0.layout = layout; $0.document.layout = layout }
    }

    private func preparedDraft(_ tab: TabState, direction: Direction) async throws -> WorkspaceStore.PreparedDocument {
        let key = DraftPlanKey(revision: tab.document.sourceRevision, generation: tab.draftGeneration, direction: direction)
        if let existing = draftPlanning[tab.sessionID], existing.key == key {
            return try await existing.task.value
        }
        draftPlanning[tab.sessionID]?.task.cancel()
        let task = Task.detached {
            try Task.checkCancellation()
            let sameSource = TextIdentity.equal(tab.draftText, tab.document.source)
            let preserveSavedAuto = tab.document.requestedFormat == .auto && tab.document.isMarkdown && sameSource
            return try WorkspaceStore.prepareDocument(
                source: tab.draftText, direction: direction, replacing: tab.document,
                format: tab.draftFormat, markdownHint: (tab.markdownImportHint && sameSource) || preserveSavedAuto
            )
        }
        draftPlanning[tab.sessionID] = DraftPlanning(key: key, task: task)
        return try await task.value
    }

    private func currentDraft(_ tab: TabState) -> Int? {
        guard let index = workspace.index(of: tab.sessionID), !composing.contains(tab.sessionID),
              workspace.tabs[index].draftGeneration == tab.draftGeneration,
              workspace.tabs[index].document.sourceRevision == tab.document.sourceRevision else { return nil }
        return index
    }

    func formatStatus(_ tab: TabState) -> String? {
        guard tab.draftFormat == .auto else { return nil }
        if !tab.isDraftDirty { return text(tab.document.isMarkdown ? "Markdown" : "Plain Text") }
        guard let detection = detectedFormats[tab.sessionID], detection.generation == tab.draftGeneration else { return nil }
        return text(detection.format == .markdown ? "Markdown" : "Plain Text")
    }

    func detectDraftFormat(_ session: UUID) async {
        guard let index = workspace.index(of: session), !composing.contains(session) else { return }
        let tab = workspace.tabs[index]
        guard tab.isDraftDirty, tab.draftFormat == .auto else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            guard currentDraft(tab) != nil else { return }
            let prepared = try await preparedDraft(tab, direction: tab.draftDirection)
            try Task.checkCancellation()
            guard currentDraft(tab) != nil else { return }
            detectedFormats[session] = (tab.draftGeneration, prepared.document.isMarkdown ? .markdown : .plainText)
        } catch {
            // Apply and Translate surface planning errors on explicit actions.
        }
    }

    func cancelEditing(_ session: UUID) {
        guard let index = workspace.index(of: session) else { return }
        workspace.withTab(index) {
            $0.draftText = $0.document.source
            $0.draftDirection = $0.document.requestedDirection
            $0.draftFormat = $0.document.requestedFormat
        }
        draftPlanning.removeValue(forKey: session)?.task.cancel()
        detectedFormats[session] = nil
        editing.remove(session)
    }

    func changeFormat(_ format: ContentFormat, session: UUID) {
        guard let index = workspace.index(of: session) else { return }
        workspace.withTab(index) { $0.draftFormat = format }
        guard !editing.contains(session) else { return }
        let tab = workspace.tabs[index]
        Task {
            guard currentDraft(tab) != nil else { return }
            do {
                if try await apply(session) { return }
            } catch is CancellationError {
            } catch {
                report(error, fallback: "The selected format could not be applied.")
            }
            guard let current = currentDraft(tab) else { return }
            workspace.withTab(current) { $0.draftFormat = $0.document.requestedFormat }
        }
    }

    func changeReadingMode(_ mode: MarkdownReadingMode, session: UUID) {
        guard let index = workspace.index(of: session) else { return }
        let document = workspace.tabs[index].document
        guard document.isMarkdown, document.canUseMarkdownPlan, document.readingMode != mode else { return }
        workspace.withTab(index) { $0.document.readingMode = mode }
        analysis.removeValue(forKey: session)?.cancel()
        reading[session]?.selectionGeneration += 1
        reading[session]?.selection = nil
        reading[session]?.hover = nil
        reading[session]?.phraseRanges = []
        reading[session]?.analyzing = false
    }

    @discardableResult
    public func apply(_ session: UUID) async throws -> Bool {
        try await apply(session, saving: false)
    }

    private func apply(_ session: UUID, saving: Bool) async throws -> Bool {
        guard let index = workspace.index(of: session), !composing.contains(session) else { throw ActionError.composing }
        let tab = workspace.tabs[index]
        guard tab.isDraftDirty else { editing.remove(session); return true }
        let prepared = try await preparedDraft(tab, direction: tab.draftDirection)
        guard let current = currentDraft(tab) else { throw ActionError.draftChanged }
        let proposed = prepared.document
        let preservesRevision = WorkspaceStore.preservesRevision(tab, proposed: proposed)
        let currentTab = workspace.tabs[current]
        let hasWork = currentTab.job.snapshot != nil || currentTab.document.jobSnapshot != nil || !currentTab.document.translations.isEmpty
        let rebuildingPlan = !tab.document.canUseMarkdownPlan
        if !preservesRevision, rebuildingPlan || (hasWork && proposed.isMarkdown != tab.document.isMarkdown) {
            guard await confirmFormatReplacement(rebuildingPlan: rebuildingPlan) else { return false }
        } else if saving, !preservesRevision, !workspace.tabs[current].document.translations.isEmpty {
            guard await alert("Apply changes and save?", detail: "Applying the edited original clears its existing translations.",
                              buttons: ["Apply Changes and Save", "Cancel"]) == 0 else { return false }
        }
        guard let current = currentDraft(tab) else { throw ActionError.draftChanged }
        try commitDraft(prepared, at: current)
        if !tab.draftText.isEmpty { editing.remove(session) }
        return true
    }

    private func confirmFormatReplacement(rebuildingPlan: Bool) async -> Bool {
        await alert("Apply the new document format?",
                    detail: rebuildingPlan
                        ? "Rebuilding the Markdown plan clears the current results."
                        : "Changing the resolved format stops translation and clears the current results.",
                    buttons: ["Apply Format", "Cancel"]) == 0
    }

    private func commitDraft(_ prepared: WorkspaceStore.PreparedDocument, at index: Int, forceReplan: Bool = false) throws {
        let tab = workspace.tabs[index]
        let session = tab.sessionID
        let replacesRevision = forceReplan || !WorkspaceStore.preservesRevision(tab, proposed: prepared.document)
        if replacesRevision { coordinator.cancel(tabIndex: index, workspace: workspace) }
        try workspace.applyDraft(at: index, prepared: prepared, forceReplan: forceReplan)
        draftPlanning.removeValue(forKey: session)?.task.cancel()
        detectedFormats[session] = nil
        guard replacesRevision else { return }
        analysis.removeValue(forKey: session)?.cancel()
        reading[session] = ReadingPresentation()
        cache[session] = nil
        workspace.withTab(index) { $0.runtimeBinding = nil }
    }

    public func primaryAction() {
        guard let i = workspace.activeTabIndex else { return }
        let tab = workspace.tabs[i]
        if [.queued,.running].contains(tab.job.state) { coordinator.cancel(tabIndex: i, workspace: workspace); return }
        if tab.hasNoProseToTranslate { return }
        Task { await translate(tab.sessionID, retranslate: !tab.document.canUseMarkdownPlan) }
    }

    /// Credential resolver for the coordinator: resolves the frozen
    /// runtime binding against the saved record inside the Settings
    /// transaction boundary. An already dispatched request keeps its key;
    /// later dispatches observe deletion/endpoint changes.
    private func dispatchCredential(_ binding: RuntimeModelBinding) throws -> String {
        do {
            return try settings.resolveCredential(binding)
        } catch SettingsStore.SettingsError.missingCredential {
            throw GatewayError(code: .missingCredential, isLocal: true)
        } catch SettingsStore.SettingsError.configurationUnavailable {
            throw GatewayError(code: .configurationUnavailable, isLocal: true)
        } catch SettingsStore.SettingsError.keychainFailure {
            throw GatewayError(code: .missingCredential, isLocal: true)
        }
    }

    public func translate(_ session: UUID, retranslate: Bool = false, overrideBinding: RuntimeModelBinding? = nil) async {
        do {
            guard let i = workspace.index(of: session), !composing.contains(session),
                  !workspace.tabs[i].draftText.isEmpty, !workspace.tabs[i].draftText.isWhitespaceOnly else { return }
            let preferences = settings.record
            let tab = workspace.tabs[i]
            let retained = tab.job.snapshot ?? tab.document.jobSnapshot
            let forceReplan = retranslate && tab.document.isMarkdown
                && tab.document.markdownPlan?.planVersion != MarkdownPlan.version
            var prepared: WorkspaceStore.PreparedDocument?
            if tab.isDraftDirty || forceReplan {
                prepared = try await preparedDraft(tab, direction: tab.draftDirection)
            }
            var proposed = prepared?.document ?? tab.document
            let replacement = retranslate || (!tab.isDraftDirty && tab.job.state == .completed && overrideBinding == nil)
            let fresh = replacement || retained == nil || !WorkspaceStore.preservesRevision(tab, proposed: proposed)

            if fresh, proposed.requestedDirection != preferences.translationDirection, !proposed.isMarkdown || !proposed.units.isEmpty {
                if var candidate = prepared?.document {
                    candidate.requestedDirection = preferences.translationDirection
                    prepared = WorkspaceStore.PreparedDocument(document: candidate)
                } else {
                    prepared = try await preparedDraft(tab, direction: preferences.translationDirection)
                }
                proposed = prepared?.document ?? tab.document
            }
            guard let preparedIndex = currentDraft(tab), !closing.contains(session) else { return }
            guard proposed.canUseMarkdownPlan else { throw TranslationCoordinator.CoordinatorError.retiredPromptVersion }
            let currentTab = workspace.tabs[preparedIndex]
            let hasWork = currentTab.job.snapshot != nil || currentTab.document.jobSnapshot != nil || !currentTab.document.translations.isEmpty
            let rebuildingPlan = !currentTab.document.canUseMarkdownPlan
            let formatReplacement = (tab.isDraftDirty && rebuildingPlan)
                || (hasWork && proposed.isMarkdown != currentTab.document.isMarkdown)

            guard workspace.tabs[preparedIndex].job.attemptGeneration == tab.job.attemptGeneration else { return }
            if proposed.isMarkdown && proposed.units.isEmpty {
                if formatReplacement || (forceReplan && hasWork) {
                    guard await confirmFormatReplacement(rebuildingPlan: rebuildingPlan) else { return }
                }
                guard let current = currentDraft(tab), !closing.contains(session),
                      workspace.tabs[current].contentGeneration == tab.contentGeneration,
                      workspace.tabs[current].job.attemptGeneration == tab.job.attemptGeneration else { return }
                if let prepared { try commitDraft(prepared, at: current, forceReplan: forceReplan) }
                editing.remove(session)
                return
            }
            let direction = fresh
                ? try TranslationCoordinator.resolveDirection(
                    proposed.requestedDirection, source: proposed.markdownPlan?.prose ?? proposed.source)
                : nil
            var snapshot: JobSnapshot
            var binding: RuntimeModelBinding?
            if let overrideBinding, let retainedSnapshot = retained, !fresh {
                snapshot = retainedSnapshot
                binding = overrideBinding
            } else if let direction {
                guard let configuration = preferences.defaultConfiguration else {
                    await offerSettings(title: "Add a model configuration in Settings before translating.",
                                        detail: "Add a model configuration to translate.")
                    return
                }
                snapshot = JobSnapshot(
                    jobID: UUID(), sourceRevision: tab.document.sourceRevision,
                    sourceLanguage: direction.0, targetLanguage: direction.1,
                    provider: configuration.provider, model: configuration.modelID,
                    profile: configuration.profile, effort: configuration.effort,
                    translationPromptVersion: proposed.translationPromptVersion, alignmentPromptVersion: "alignment.v1",
                    configurationRevision: configuration.revision)
                binding = configuration.runtimeBinding
            } else {
                guard let retained else { return }
                snapshot = retained
                binding = tab.runtimeBinding
            }

            // An opened document needs an explicit session-local binding
            // before model calls; the current default is never an implicit
            // substitute and a similarly named entry is never selected
            // automatically.
            guard let frozen = binding else {
                if let retained { requestBinding(session: session, snapshot: retained) }
                return
            }

            // Preflight the frozen binding before any confirmation dialog.
            do { _ = try settings.resolveCredential(frozen) }
            catch SettingsStore.SettingsError.missingCredential {
                await offerSettings(title: "Add an API key in Settings before translating.",
                                    detail: "The selected model has no API key yet.")
                return
            }
            catch SettingsStore.SettingsError.configurationUnavailable {
                if fresh { errorMessage = "The selected model changed. Choose a model and try again." }
                else {
                    await offerSettings(title: "The original model configuration is unavailable.",
                                        detail: "Restore the original configuration, or use Retranslate to start with the active model.")
                }
                return
            }
            catch { report(error, fallback: "Translation stopped. Check the model settings and retry."); return }

            guard await consent(provider: frozen.provider, origin: CanonicalBaseURL.origin(of: frozen.requestOptions?.endpointURL ?? frozen.baseURL)) else { return }
            try Task.checkCancellation()
            if formatReplacement {
                guard await confirmFormatReplacement(rebuildingPlan: rebuildingPlan) else { return }
            } else if replacement {
                guard await alert("Replace existing translations?", detail: "Retranslating clears the current translations and correspondence.",
                                  buttons: ["Retranslate", "Cancel"]) == 0 else { return }
            }
            try Task.checkCancellation()
            guard let current = currentDraft(tab), !closing.contains(session),
                  workspace.tabs[current].contentGeneration == tab.contentGeneration,
                  workspace.tabs[current].job.snapshot == tab.job.snapshot,
                  workspace.tabs[current].job.attemptGeneration == tab.job.attemptGeneration else { return }
            if fresh { _ = try dispatchCredential(frozen) }
            if let prepared {
                let replacesRevision = forceReplan || !WorkspaceStore.preservesRevision(workspace.tabs[current], proposed: prepared.document)
                workspace.withTab(current) { $0.draftDirection = prepared.document.requestedDirection }
                try commitDraft(prepared, at: current, forceReplan: forceReplan)
                if replacement && !replacesRevision { discardTranslations(session) }
                snapshot.sourceRevision = workspace.tabs[current].document.sourceRevision
            } else if replacement {
                discardTranslations(session)
            }
            workspace.withTab(current) { $0.runtimeBinding = frozen }
            if cache[session] == nil { cache[session] = .init() }
            editing.remove(session)
            try await coordinator.translate(tabIndex: current, workspace: workspace, snapshot: snapshot, binding: frozen,
                                            credential: dispatchCredential)
        } catch is CancellationError { }
        catch TranslationCoordinator.CoordinatorError.manualDirectionRequired {
            if await alert("Choose a translation direction", detail: "Automatic could not determine a direction for this text.",
                           buttons: ["Open Settings", "Cancel"]) == 0 {
                settingsRequested = true
            }
        }
        catch TranslationCoordinator.CoordinatorError.retiredPromptVersion {
            errorMessage = "This document was translated with an older prompt version and cannot resume. Use Retranslate to continue with the current version."
        }
        catch { report(error,fallback:"Translation stopped. Completed paragraphs were kept; check the model settings and retry.") }
    }

    /// A dispatch-blocking preflight failure that Settings can resolve
    /// (empty configuration list, missing key) offers Settings directly,
    /// with zero model calls (model-settings: "offers Settings when a job
    /// cannot dispatch").
    private func offerSettings(title: String, detail: String) async {
        if await alert(title, detail: detail, buttons: ["Open Settings", "Cancel"]) == 0 {
            settingsRequested = true
        }
    }

    /// Offers an explicit binding for a snapshot with no usable local
    /// binding: a picker over matching configurations, or configuration
    /// creation / explicit Retranslate when none matches.
    private func requestBinding(session: UUID, snapshot: JobSnapshot) {
        let matches = settings.matchingConfigurations(for: snapshot)
        guard !matches.isEmpty else {
            Task { await offerMissingConfiguration(session: session, snapshot: snapshot) }
            return
        }
        bindingRequest = BindingRequest(session: session, snapshot: snapshot, matches: matches, purpose: .resume)
    }

    private func offerMissingConfiguration(session: UUID, snapshot: JobSnapshot) async {
        guard !Task.isCancelled, let i = workspace.index(of: session),
              workspace.tabs[i].document.jobSnapshot == snapshot else { return }
        let action = await alert("No matching model configuration",
            detail: String(format: text("This document needs a configuration for %@ before model operations can continue. Add one in Settings, or retranslate with the current default."), snapshot.model),
            buttons: ["Retranslate", "Settings…", "Cancel"])
        guard !Task.isCancelled, let current = workspace.index(of: session),
              workspace.tabs[current].document.jobSnapshot == snapshot else { return }
        if action == 0 {
            // Retranslate cancels this session's analysis task. Start the
            // explicit action independently so it cannot cancel itself.
            Task {
                guard let i = workspace.index(of: session),
                      workspace.tabs[i].document.jobSnapshot == snapshot else { return }
                await translate(session, retranslate: true)
            }
        } else if action == 1 { settingsRequested = true }
    }

    /// Revalidates a binding-sheet choice against the saved record at
    /// confirmation: the candidate must still exist with exactly the
    /// fields that were presented — ID, provider, model, profile, effort,
    /// and canonical endpoint (N4). A same-named replacement entry has a
    /// different ID and never inherits the old candidate's authorization.
    private func validatedBindingChoice(_ request: BindingRequest, configurationID: UUID) -> ModelConfigurationRecord? {
        guard let presented = request.matches.first(where: { $0.id == configurationID }),
              let current = settings.configuration(configurationID),
              current.provider == presented.provider,
              current.modelID == presented.modelID,
              current.profile == presented.profile,
              current.effort == presented.effort,
              current.baseURL == presented.baseURL, current.requestOptions == presented.requestOptions,
              current.revision == presented.revision else { return nil }
        return current
    }

    /// A stale confirmed candidate is never bound: refresh the sheet from
    /// current state so the user explicitly confirms the configuration as
    /// it now exists (N4).
    private func refreshBindingRequest(_ request: BindingRequest) {
        bindingRequest = nil
        guard let i = workspace.index(of: request.session),
              workspace.tabs[i].document.jobSnapshot == request.snapshot else { return }
        switch request.purpose {
        case .resume:
            requestBinding(session: request.session, snapshot: request.snapshot)
        case .analysis:
            let matches = settings.matchingConfigurations(for: request.snapshot)
            if !matches.isEmpty {
                bindingRequest = BindingRequest(session: request.session, snapshot: request.snapshot, matches: matches, purpose: .analysis)
            } else {
                Task { await offerMissingConfiguration(session: request.session, snapshot: request.snapshot) }
            }
        }
    }

    /// Applies an explicit binding choice from the binding sheet and
    /// resumes the document's retained snapshot.
    public func bindAndResume(_ request: BindingRequest, configurationID: UUID) {
        guard request.purpose == .resume else { bindForAnalysis(request, configurationID: configurationID); return }
        guard let configuration = validatedBindingChoice(request, configurationID: configurationID) else {
            refreshBindingRequest(request)
            return
        }
        bindingRequest = nil
        guard let i = workspace.index(of: request.session),
              workspace.tabs[i].document.jobSnapshot == request.snapshot else { return }
        // Explicit rebinding clears cached model analysis for the session.
        if workspace.tabs[i].runtimeBinding != nil { cache[request.session] = nil }
        workspace.withTab(i) { $0.runtimeBinding = configuration.runtimeBinding }
        Task { await translate(request.session, overrideBinding: configuration.runtimeBinding) }
    }

    /// Applies an explicit binding for phrase analysis of an existing
    /// translation (D3): no translation starts, the document is not
    /// dirtied, and the binding choice is revalidated against the saved
    /// record at confirmation. The pending selection analysis re-runs
    /// under the new binding.
    public func bindForAnalysis(_ request: BindingRequest, configurationID: UUID) {
        guard request.purpose == .analysis,
              let configuration = validatedBindingChoice(request, configurationID: configurationID) else {
            if request.purpose == .analysis { refreshBindingRequest(request) }
            return
        }
        bindingRequest = nil
        guard let i = workspace.index(of: request.session),
              workspace.tabs[i].document.jobSnapshot == request.snapshot else { return }
        if workspace.tabs[i].runtimeBinding != nil { cache[request.session] = nil }
        workspace.withTab(i) { $0.runtimeBinding = configuration.runtimeBinding }
        // Re-run the pending selection analysis under the new binding;
        // the re-entered schedule advances the selection owner so any
        // pre-binding analysis task can no longer commit.
        reading[request.session]?.phraseRanges = []
        reading[request.session]?.analyzing = false
        reading[request.session]?.selectionGeneration += 1
        scheduleAnalysis(for: reading[request.session]?.selection, session: request.session)
    }

    func discardTranslations(_ session: UUID) {
        guard let i = workspace.index(of: session) else { return }
        coordinator.cancel(tabIndex: i, workspace: workspace)
        workspace.withTab(i) { $0.document.translations = []; $0.document.jobSnapshot = nil; $0.document.resolvedDirection = nil; $0.job = JobModel(); $0.elapsed = TranslationElapsed(); $0.runtimeBinding = nil; $0.contentGeneration += 1 }
        cache[session] = nil; analysis.removeValue(forKey:session)?.cancel()
        var presentation = ReadingPresentation(); presentation.anchors = reading[session]?.anchors ?? [:]
        reading[session] = presentation
    }

    public func save(_ session: UUID, to destination: URL? = nil) async -> Bool {
        let previous = saveTasks[session]?.1, token = UUID()
        let task = Task { [weak self] in
            if let previous { _ = await previous.value }
            guard let self else { return false }
            return await self.performSave(session, destination: destination)
        }
        saveTasks[session] = (token, task)
        defer { if saveTasks[session]?.0 == token { saveTasks[session] = nil } }
        return await task.value
    }
    private func performSave(_ session: UUID, destination: URL?) async -> Bool {
        var attemptedDestination: URL?
        do {
            guard let i = workspace.index(of: session), !composing.contains(session) else { return false }
            if workspace.tabs[i].isDraftDirty {
                guard try await apply(session, saving: true) else { return false }
            }
            guard let i = workspace.index(of: session) else { return false }
            var url = destination ?? workspace.tabs[i].saveURL
            if url == nil {
                let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "bipara") ?? .json]
                panel.nameFieldStringValue = workspace.tabs[i].document.title + ".bipara"
                guard await present(panel) == .OK else { return false }; url = panel.url
            }
            guard let url, let i = workspace.index(of: session) else { return false }
            attemptedDestination = url
            let generation = workspace.tabs[i].contentGeneration
            var document = workspace.tabs[i].document
            document.layout = workspace.tabs[i].layout
            document.readingAnchor = reading[session]?.anchors[workspace.tabs[i].layout]
            try await files.save(document, to: url, ownerSessionID: session)
            guard let i = workspace.index(of: session) else { return true }
            let old = workspace.tabs[i].saveURL
            workspace.withTab(i) { $0.saveURL = DocumentFileService.canonicalURL(url); $0.savedContentGeneration = generation }
            if let old, DocumentFileService.canonicalURL(old) != DocumentFileService.canonicalURL(url) { await files.releaseDestination(old, ownerSessionID: session) }
            return true
        } catch {
            if let attemptedDestination, workspace.tabs.first(where:{$0.sessionID == session})?.saveURL.map(DocumentFileService.canonicalURL) != DocumentFileService.canonicalURL(attemptedDestination) {
                await files.releaseDestination(attemptedDestination, ownerSessionID:session)
            }
            report(error,fallback:"The document could not be saved. Your unsaved work is still open."); return false
        }
    }

    public func openPanel() {
        Task {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText, Self.markdownType, UTType(filenameExtension: "bipara") ?? .json]
            if let longMarkdownType = UTType(filenameExtension: "markdown"), !panel.allowedContentTypes.contains(longMarkdownType) {
                panel.allowedContentTypes.append(longMarkdownType)
            }
            panel.allowsMultipleSelection = true
            guard await present(panel) == .OK else { return }
            for url in panel.urls { await open(url) }
        }
    }
    private static var markdownType: UTType { UTType(filenameExtension: "md") ?? .plainText }

    public func open(_ url: URL) async {
        do {
            let ext = url.pathExtension.lowercased()
            let markdownHint = ["md", "markdown"].contains(ext)
            if ext == "txt" || markdownHint {
                let files = files
                let prepared = try await Task.detached {
                    try WorkspaceStore.prepareDocument(source: files.importText(url), direction: .auto, markdownHint: markdownHint)
                }.value
                let i = workspace.newTab(prepared: prepared)
                workspace.withTab(i) { $0.markdownImportHint = markdownHint }
                editing.insert(workspace.tabs[i].sessionID)
                let title = DocumentTitle.derive(from: url.deletingPathExtension().lastPathComponent)
                if title != "Untitled" { workspace.withTab(i) { $0.document.title = title; $0.automaticTitle = false } }
            } else {
                let document = try await files.open(url)
                let previous = workspace.tabs.map(\.sessionID)
                workspace.openDocument(document, at: url)
                if let tab = workspace.activeTab {
                    do { try await files.reserveDestination(url, ownerSessionID: tab.sessionID) }
                    catch { if !previous.contains(tab.sessionID), let i = workspace.index(of: tab.sessionID) { workspace.closeTab(at: i) }; throw error }
                    if let anchor = document.readingAnchor { reading[tab.sessionID, default: .init()].anchors[tab.layout] = anchor }
                }
            }
        } catch { report(error,fallback:"This file is invalid, unavailable, or already owned by another tab. Existing documents were kept.") }
    }

    public func close(_ session: UUID) async -> Bool {
        guard !closing.contains(session) else { return false }
        closing.insert(session); defer { closing.remove(session) }
        if let task = saveTasks[session]?.1 { _ = await task.value }
        guard let i = workspace.index(of: session) else { return true }
        if [.running,.queued].contains(workspace.tabs[i].job.state) {
            guard await alert("Stop translation and close?", detail: "Completed work will be kept until you decide whether to save it.", buttons: ["Stop and Close","Keep Tab"]) == 0 else { return false }
            coordinator.cancel(tabIndex: i, workspace: workspace)
        }
        guard let i = workspace.index(of: session) else { return true }
        if workspace.tabs[i].isDirty && !settings.record.dontAskToSaveOnClose {
            let action = await alert("Save changes before closing?", detail: workspace.tabs[i].document.title, buttons: ["Save","Discard","Cancel"])
            if action == 2 { return false }
            if action == 0 {
                guard await save(session), let current = workspace.index(of: session),
                      !workspace.tabs[current].isDirty else { return false }
            }
        }
        guard let i = workspace.index(of: session) else { return true }
        let url = workspace.tabs[i].saveURL
        draftPlanning.removeValue(forKey: session)?.task.cancel()
        detectedFormats[session] = nil
        workspace.closeTab(at: i); analysis.removeValue(forKey:session)?.cancel(); reading[session] = nil; cache[session] = nil; editing.remove(session)
        if let url { await files.releaseDestination(url, ownerSessionID: session) }
        return true
    }
    public func closeAll() async -> Bool {
        for session in workspace.tabs.map(\.sessionID) { if !(await close(session)) { return false } }
        return true
    }
    public func prepareToQuit() async -> Bool {
        guard await closeSettings() else { return false }
        return await closeAll()
    }
    public func closeSettings() async -> Bool {
        guard settings.hasDraftChanges else { return true }
        let action = await alert("Save Settings changes?", detail: "Unsaved model, appearance, and credential changes are still in this draft.", buttons: ["Save","Discard","Cancel"], window: NSApp.keyWindow)
        if action == 1 { settings.cancelDraft(); return true }
        if action == 0 {
            do { try settings.saveDraft(); return true }
            catch SettingsStore.SettingsError.invalidField { errorMessage = "Some settings are invalid. Check the model and reading settings, then save again." }
            catch { errorMessage = "Settings could not be saved. Previous values were restored where possible." }
        }
        return false
    }

    public func export(bilingual: Bool, markdown: Bool = false) {
        guard let tab = workspace.activeTab else { return }
        Task {
            do {
                let text: String
                let document = tab.document
                let files = files
                if bilingual {
                    text = try await Task.detached { try files.exportBilingual(document, markdown: markdown) }.value
                } else {
                    do {
                        text = try await Task.detached { try files.exportTranslation(document, markdown: markdown) }.value
                    } catch DocumentFileService.FileError.incompleteTranslation {
                        let detail = document.isMarkdown
                            ? "This translation is incomplete. Partial export omits unfinished blocks, lists and tables."
                            : "This translation is incomplete. Partial export omits every unfinished paragraph."
                        guard await alert(document.isMarkdown ? "Export completed blocks only?" : "Export completed paragraphs only?",
                                          detail: detail, buttons: ["Export Partial", "Cancel"]) == 0 else { return }
                        text = try await Task.detached {
                            try files.exportTranslation(document, allowPartial: true, markdown: markdown)
                        }.value
                    }
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [markdown ? Self.markdownType : .plainText]
                panel.nameFieldStringValue = tab.document.title + (markdown ? ".md" : ".txt")
                guard await present(panel) == .OK, let url = panel.url else { return }
                try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value
            } catch DocumentFileService.FileError.noCompletedParagraphs {
                errorMessage = tab.document.isMarkdown ? "There are no completed blocks to export yet." : "There are no completed paragraphs to export yet."
            } catch {
                errorMessage = "The export could not be written."
            }
        }
    }

    public func copy(original: Bool) {
        guard let document = workspace.activeTab?.document else { return }
        copyTask?.cancel()
        if original {
            writeClipboard(document.source)
        } else if document.isMarkdown {
            let previousClipboard = NSPasteboard.general.changeCount
            copyTask = Task {
                let files = files
                let export = Task.detached { try files.exportTranslation(document, markdown: true) }
                guard let value = try? await export.value, !Task.isCancelled,
                      NSPasteboard.general.changeCount == previousClipboard else { return }
                writeClipboard(value)
            }
        } else if let value = try? files.exportTranslation(document) {
            writeClipboard(value)
        }
    }

    private func writeClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    public func selected(_ selection: ReadingSelection?, session: UUID) {
        guard reading[session]?.selection != selection else { return }
        analysis.removeValue(forKey:session)?.cancel()
        reading[session,default:.init()].selection = selection
        reading[session,default:.init()].selectionGeneration += 1
        reading[session,default:.init()].phraseRanges = []
        reading[session,default:.init()].analyzing = false
        scheduleAnalysis(for: selection, session: session)
    }

    /// Schedules the debounced phrase analysis for a selection. Called by
    /// `selected` for new selections and re-entered directly after an
    /// explicit analysis binding is confirmed (D3), so the pending
    /// selection re-runs under the new binding even though the selection
    /// value itself did not change.
    private struct AnalysisInput: Sendable {
        let source: String
        let target: String
        let request: AlignSelectionRequest
    }

    private nonisolated static func analysisInput(
        document: BiparaDocument, unitID: UUID, selection: ReadingSelection
    ) -> AnalysisInput? {
        guard let source = document.visibleUnitText(unitID, side: .source),
              let target = document.visibleUnitText(unitID, side: .translation),
              source.utf8.count + target.utf8.count <= WorkerContract.maxAlignTextBytes else { return nil }
        let reading = selection.side == .source ? source : target
        let counterpart = selection.side == .source ? target : source
        guard selection.range.length > 0,
              let end = selection.range.end,
              let selected = reading.substring(utf16: selection.range),
              selected.utf8.count <= WorkerContract.maxAlignSelectionBytes else { return nil }
        let before = (reading as NSString).substring(to: selection.range.location)
        let after = (reading as NSString).substring(from: end)
        let request = AlignSelectionRequest(readingText: reading, counterpartText: counterpart,
                                           before: before, selectedText: selected, after: after)
        return .init(source: source, target: target, request: request)
    }

    private func scheduleAnalysis(for selection: ReadingSelection?, session: UUID) {
        guard let selection, let unit = selection.unitID, let i = workspace.index(of: session) else { return }
        let tab = workspace.tabs[i]
        let document = tab.document
        guard document.canUseMarkdownPlan, (!document.isMarkdown || document.readingMode == .rendered),
              selection.range.length > 0,
              let snapshot = document.jobSnapshot,
              WorkerContract.alignmentPromptVersions.contains(snapshot.alignmentPromptVersion),
              let translated = document.translations.first(where: { $0.unitID == unit }) else { return }
        // Keep the existing immediate plain-text range/size preflight. Markdown
        // projection can parse inline syntax, so do that off the UI actor.
        let preflight = document.isMarkdown ? nil : Self.analysisInput(document: document, unitID: unit, selection: selection)
        guard document.isMarkdown || preflight != nil else { return }
        let generation = reading[session]!.selectionGeneration
        let revision = document.sourceRevision
        let binding = tab.runtimeBinding
        analysis[session]?.cancel()
        analysis[session] = Task {
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                let payload: AnalysisInput?
                if let preflight { payload = preflight }
                else {
                    payload = await Task.detached {
                        Self.analysisInput(document: document, unitID: unit, selection: selection)
                    }.value
                }
                try Task.checkCancellation()
                guard let payload, let current = workspace.index(of: session),
                      workspace.tabs[current].document.sourceRevision == revision,
                      reading[session]?.selectionGeneration == generation,
                      workspace.tabs[current].document.translations.first(where: { $0.unitID == unit }) == translated else { return }
                let key = binding.map { bound in
                    SelectionCache.Key(
                        sourceRevision: revision, unit: unit, source: Data(payload.source.utf8), target: Data(payload.target.utf8),
                        targetCompletedAt: translated.completedAt, side: selection.side.rawValue,
                        location: selection.range.location, length: selection.range.length,
                        provider: snapshot.provider, model: snapshot.model, profile: snapshot.profile, effort: snapshot.effort.rawValue,
                        bindingID: bound.configurationID, promptVersion: snapshot.alignmentPromptVersion
                    )
                }
                if let key, let cached = cache[session, default: .init()].value(for: key) {
                    reading[session]?.phraseRanges = cached
                    return
                }
                if let binding, let key {
                    // Already bound: resolve by frozen configuration
                    // identity and endpoint URL. Same-URL model/effort edits
                    // to the configuration do not disable analysis — the
                    // job keeps its frozen snapshot (D3). Consent suspends
                    // first; the owner and credential are revalidated after
                    // it, with the key resolved in the Settings transaction
                    // boundary immediately before dispatch (N5).
                    guard let configuration = settings.configuration(binding.configurationID),
                          configuration.credentialIdentity == binding.credentialIdentity,
                          await consent(provider:configuration.provider, origin:CanonicalBaseURL.origin(of:binding.requestOptions?.endpointURL ?? binding.baseURL)) else { return }
                    try Task.checkCancellation()
                    guard let postConsent = workspace.index(of:session), workspace.tabs[postConsent].document.sourceRevision == revision,
                          reading[session]?.selectionGeneration == generation,
                          workspace.tabs[postConsent].document.translations.first(where:{$0.unitID==unit}) == translated else { return }
                    let credentials: ModelCredentials
                    do { credentials = try ModelCredentials.decode(settings.resolveCredential(binding)) }
                    catch { return } // deleted/changed endpoint during consent: retain the fallback, zero calls
                    reading[session]?.analyzing = true
                    let result = try await gateway.alignSelection(payload.request,
                        configuration:.init(provider:snapshot.provider,model:snapshot.model,profile:snapshot.profile,
                                           baseURL:binding.baseURL,effort:snapshot.effort,apiKey:credentials.apiKey,
                                           configurationID:binding.configurationID, requestOptions: binding.requestOptions, secretHeaders: credentials.headers))
                    try Task.checkCancellation()
                    guard let current = workspace.index(of:session), workspace.tabs[current].document.sourceRevision == revision,
                          reading[session]?.selectionGeneration == generation,
                          workspace.tabs[current].document.translations.first(where:{$0.unitID==unit}) == translated else { return }
                    let ranges: [BiparaCore.TextRange]
                    if case .matched(let matches) = result.match { ranges = CorrespondenceResolver.resolveMatches(matches.map{($0.quote,$0.occurrence)},in:payload.request.counterpartText)?.ranges ?? [] }
                    else { ranges = [] }
                    cache[session,default:.init()].insert(ranges,for:key); reading[session]?.phraseRanges = ranges
                } else {
                    // An opened document with no session-local binding makes
                    // no model call; it can be bound explicitly for
                    // analysis of the existing translation (D3). No call
                    // happens before that confirmation.
                    let matches = settings.matchingConfigurations(for: snapshot)
                    guard bindingRequest == nil else { return }
                    guard !matches.isEmpty else {
                        await offerMissingConfiguration(session: session, snapshot: snapshot)
                        return
                    }
                    bindingRequest = BindingRequest(session: session, snapshot: snapshot, matches: matches, purpose: .analysis)
                }
            } catch { }
            if reading[session]?.selectionGeneration == generation { reading[session]?.analyzing = false }
        }
    }
    func hasSelectionTask(for session: UUID) -> Bool { analysis[session] != nil }
    func report(_ error:Error,fallback:String) {
        switch error {
        case WorkspaceStore.PlanningError.documentTooLarge: errorMessage="This text creates a document larger than the 20 MiB file limit. Shorten the original; your previous document and draft were kept."
        case TranslationCoordinator.CoordinatorError.documentTooLarge: errorMessage="The document reached the 20 MiB file limit. Completed translations were kept."
        case DocumentFileService.FileError.oversized: errorMessage="This document exceeds the 20 MiB file limit. Existing documents were kept."
        case CoreError.inputTooLarge: errorMessage="The original exceeds the 1 MiB text limit. Shorten it before applying."
        case CoreError.unsupportedInput where workspace.activeTab?.draftFormat != .plainText:
            errorMessage = "The Markdown cannot be planned within the supported limits. Edit the original or choose Plain Text."
        case TranslationCoordinator.CoordinatorError.invalidMarkdownStructure:
            errorMessage = "The model changed the Markdown structure. Completed translations were kept."
        case let error as GatewayError: errorMessage = translationFailureMessage(error)
        default: errorMessage=fallback
        }
    }

    private func translationFailureMessage(_ error: GatewayError) -> String {
        var details: [String] = []
        if let status = error.httpStatus {
            details.append("HTTP \(status)")
        }
        if let code = error.providerCode {
            details.append(String(format: text("Provider error code: %@"), code))
        }
        let reason: String?
        switch error.validationFailure {
        case .missingContent: reason = "The model returned no text."
        case .invalidJSON: reason = "The model response is not valid JSON."
        case .translationShape: reason = "The response does not match the translation format."
        case .unitMismatch: reason = "The response does not match the requested translation units and order."
        case .invalidTranslationText: reason = "The response contains invalid translation text."
        case .outputTooLarge: reason = "The translated output exceeds the size limit."
        case .alignmentShape: reason = "The response does not match the correspondence format."
        case .markdownStructureMismatch: reason = "The model changed the Markdown structure. Completed translations were kept."
        case nil:
            switch error.code {
            case .invalidOutput: reason = "The translation failed response validation."
            case .outputLimit: reason = "The model stopped at its output limit."
            case .unsupportedCapability where error.httpStatus == nil:
                reason = "The model request failed profile validation."
            default: reason = nil
            }
        }
        if let reason { details.append(text(reason)) }
        if details.isEmpty {
            details.append(String(format: text("Failure code: %@"), error.code.rawValue))
        }
        return text("Translation stopped. Completed paragraphs were kept.") + "\n\n" + details.joined(separator: "\n")
    }

    public func hover(_ selection: ReadingSelection?, session:UUID) {
        if reading[session]?.hover != selection { reading[session,default:.init()].hover = selection }
    }
    public func pin() {
        guard let session = activeSession else { return }
        reading[session,default:.init()].pinned = reading[session]?.selection ?? reading[session]?.hover
        reading[session]?.pinnedPhraseRanges = reading[session]?.phraseRanges ?? []
    }
    public func clearPin() { if let session = activeSession { reading[session]?.pinned = nil } }
    public func reveal() { if let session = activeSession { reading[session,default:.init()].revealGeneration += 1 } }

    /// Transmission acknowledgement, recorded locally per provider and
    /// canonical origin; consent for one gateway never authorizes another.
    private func consent(provider: String, origin: String) async -> Bool {
        let key = "dev.bipara.disclosure.\(provider)|\(origin)"
        if defaults.bool(forKey:key) { return true }
        if let existing = disclosures[key] { return await existing.value }
        let host = CanonicalBaseURL.host(of: origin) ?? origin
        let task = Task {
            let answer = await alert(String(format: text("Send text to %@?"), host),
                detail:String(format: text("Translation sends source and context to %@. Selection analysis sends the selected unit and its translation. Hovering makes no request."), host),
                buttons:["Continue","Cancel"])
            if answer == 0 { defaults.set(true,forKey:key); return true }
            return false
        }
        disclosures[key] = task
        defer { disclosures[key] = nil }
        return await task.value
    }
    private func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        if let window = mainWindow { return await withCheckedContinuation{ continuation in panel.beginSheetModal(for:window){continuation.resume(returning:$0)} } }
        return panel.runModal()
    }
    func alert(_ title:String, detail:String, buttons:[String], window:NSWindow? = nil) async -> Int {
        // Test seam: scripted answers drive consent/confirmation flows
        // deterministically; production leaves it nil.
        if let alertHandler { return await alertHandler(title, detail, buttons) }
        let alert = NSAlert(); alert.messageText = text(title); alert.informativeText = text(detail)
        for button in buttons { alert.addButton(withTitle:text(button)) }
        let response: NSApplication.ModalResponse
        if let window = window ?? mainWindow {
            response = await withCheckedContinuation{ continuation in alert.beginSheetModal(for:window){continuation.resume(returning:$0)} }
        } else if NSApp.windows.contains(where: \.isVisible) {
            response = alert.runModal()
        } else {
            // No attachable window and no visible window (for example a
            // headless test process): never enter a modal wait nobody can
            // answer; treat it as the dismiss (last) action.
            return buttons.count - 1
        }
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
    public enum ActionError: Error { case composing, draftChanged }
}
