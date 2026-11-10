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
    private var saveTasks: [UUID: (UUID, Task<Bool, Never>)] = [:]
    private var analysis: [UUID: Task<Void, Never>] = [:]
    private var cache: [UUID: SelectionCache] = [:]
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

    public func apply(_ session: UUID) async throws {
        guard let i = workspace.index(of: session), !composing.contains(session) else { throw ActionError.composing }
        guard workspace.tabs[i].isDraftDirty else { editing.remove(session);return }
        let draft = workspace.tabs[i].draftText, direction = workspace.tabs[i].draftDirection
        let original = workspace.tabs[i].document
        let prepared = try await Task.detached { try WorkspaceStore.prepareDocument(source:draft,direction:direction,replacing:original) }.value
        guard let current = workspace.index(of: session), TextIdentity.equal(workspace.tabs[current].draftText, draft),
               workspace.tabs[current].draftDirection == direction, workspace.tabs[current].document.documentID == original.documentID,
               workspace.tabs[current].document.sourceRevision == original.sourceRevision,
               workspace.tabs[current].document.layout == original.layout, !composing.contains(session) else { throw ActionError.draftChanged }
        coordinator.cancel(tabIndex: current, workspace: workspace)
        try workspace.applyDraft(at: current, prepared: prepared)
        analysis[session]?.cancel(); reading[session] = ReadingPresentation(); cache[session] = nil
        workspace.withTab(current) { $0.runtimeBinding = nil }
        if !draft.isEmpty { editing.remove(session) }
    }

    public func primaryAction() {
        guard let i = workspace.activeTabIndex else { return }
        let tab = workspace.tabs[i]
        if [.queued,.running].contains(tab.job.state) { coordinator.cancel(tabIndex: i, workspace: workspace); return }
        Task { await translate(tab.sessionID) }
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
            let initial = workspace.tabs[i]
            let initialSnapshot = initial.job.snapshot ?? initial.document.jobSnapshot
            let fresh = retranslate || initial.isDraftDirty || initialSnapshot == nil
                || (initial.job.state == .completed && overrideBinding == nil)
            let requestedDirection = preferences.translationDirection
            let direction = fresh
                ? try TranslationCoordinator.resolveDirection(requestedDirection, source: initial.draftText)
                : nil
            let tab = initial
            let replacement = retranslate || (!tab.isDraftDirty && tab.job.state == .completed && overrideBinding == nil)
            let retained = initialSnapshot

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
                    translationPromptVersion: WorkerContract.currentTranslationPromptVersion, alignmentPromptVersion: "alignment.v1",
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
            if replacement {
                guard await alert("Replace existing translations?", detail: "Retranslating clears the current translations and correspondence.", buttons: ["Retranslate","Cancel"]) == 0 else { return }
            }
            let prepared: WorkspaceStore.PreparedDocument?
            if fresh, tab.isDraftDirty || requestedDirection != tab.document.requestedDirection {
                let source = tab.draftText, document = tab.document
                prepared = try await Task.detached {
                    try WorkspaceStore.prepareDocument(source: source, direction: requestedDirection, replacing: document)
                }.value
            } else {
                prepared = nil
            }
            try Task.checkCancellation()
            guard let current = workspace.index(of: session), !closing.contains(session), !composing.contains(session),
                  workspace.tabs[current].contentGeneration == tab.contentGeneration,
                  workspace.tabs[current].document.sourceRevision == tab.document.sourceRevision,
                  workspace.tabs[current].job.snapshot == tab.job.snapshot,
                  workspace.tabs[current].job.attemptGeneration == tab.job.attemptGeneration,
                  TextIdentity.equal(workspace.tabs[current].draftText, tab.draftText),
                  workspace.tabs[current].draftDirection == tab.draftDirection,
                  prepared == nil || workspace.tabs[current].document.layout == tab.document.layout else { return }
            if fresh { _ = try dispatchCredential(frozen) }
            if replacement || prepared != nil { discardTranslations(session) }
            if let prepared {
                workspace.withTab(current) { $0.draftDirection = requestedDirection }
                try workspace.applyDraft(at: current, prepared: prepared)
                reading[session] = ReadingPresentation()
                snapshot.sourceRevision = workspace.tabs[current].document.sourceRevision
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
        guard let i = workspace.index(of: request.session) else { return }
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
                if !workspace.tabs[i].document.translations.isEmpty {
                    guard await alert("Apply changes and save?", detail: "Applying the edited original clears its existing translations.", buttons: ["Apply Changes and Save","Cancel"]) == 0 else { return false }
                }
                try await apply(session)
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
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension:"bipara") ?? .json]; panel.allowsMultipleSelection = true
            guard await present(panel) == .OK else { return }
            for url in panel.urls { await open(url) }
        }
    }
    public func open(_ url: URL) async {
        do {
            if url.pathExtension.lowercased() == "txt" {
                let files = files
                let prepared = try await Task.detached { try WorkspaceStore.prepareDocument(source:files.importText(url),direction:.auto) }.value
                let i = workspace.newTab(prepared:prepared); editing.insert(workspace.tabs[i].sessionID)
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

    public func export(bilingual: Bool) {
        guard let tab = workspace.activeTab else { return }
        Task {
            do {
                let text: String
                if bilingual { text = try files.exportBilingual(tab.document) }
                else {
                    do { text = try files.exportTranslation(tab.document) }
                    catch DocumentFileService.FileError.incompleteTranslation {
                        guard await alert("Export completed paragraphs only?",detail:"This translation is incomplete. Partial export omits every unfinished paragraph.",buttons:["Export Partial","Cancel"]) == 0 else { return }
                        text = try files.exportTranslation(tab.document,allowPartial:true)
                    }
                }
                let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = tab.document.title + ".txt"
                guard await present(panel) == .OK, let url = panel.url else { return }
                try await Task.detached { try text.write(to: url, atomically:true, encoding:.utf8) }.value
            } catch DocumentFileService.FileError.noCompletedParagraphs { errorMessage="There are no completed paragraphs to export yet." }
            catch { errorMessage = "The export could not be written." }
        }
    }
    public func copy(original: Bool) {
        guard let doc = workspace.activeTab?.document else { return }
        let plan = SourcePlan(source:doc.source,paragraphs:doc.paragraphs,units:doc.units)
        let translations = Dictionary(uniqueKeysWithValues:doc.translations.map{($0.unitID,$0.text)})
        guard let value = original ? doc.source : ParagraphAssembler.assembleDocument(plan, translations:translations,targetLanguage:doc.jobSnapshot?.targetLanguage ?? .zh) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string)
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
    private func scheduleAnalysis(for selection: ReadingSelection?, session: UUID) {
        guard let selection, let unit = selection.unitID, let i = workspace.index(of:session),
              let planned = workspace.tabs[i].document.units.first(where:{$0.id==unit}),
              let snapshot = workspace.tabs[i].document.jobSnapshot,
              let translated = workspace.tabs[i].document.translations.first(where:{$0.unitID==unit}),
              let source = workspace.tabs[i].document.source.substring(utf16:planned.textRange) else { return }
        let readingText = selection.side == .source ? source : translated.text
        let counterpart = selection.side == .source ? translated.text : source
        guard readingText.hasValidRange(selection.range), selection.range.length > 0,
              let selectedText = readingText.substring(utf16:selection.range), selectedText.utf8.count <= 512,
              readingText.utf8.count + counterpart.utf8.count <= WorkerContract.maxAlignTextBytes else { return }
        // Retired prompt versions — or one operation's version in the
        // other's field — cannot dispatch analysis either; the coarse
        // fallback remains (D4, N6).
        guard WorkerContract.alignmentPromptVersions.contains(snapshot.alignmentPromptVersion) else { return }
        let binding = workspace.tabs[i].runtimeBinding
        var key: SelectionCache.Key?
        if let binding {
            key = SelectionCache.Key(sourceRevision:workspace.tabs[i].document.sourceRevision,unit:unit,
                source:Data(source.utf8),target:Data(translated.text.utf8),targetCompletedAt:translated.completedAt,
                side:selection.side.rawValue,location:selection.range.location,length:selection.range.length,
                provider:snapshot.provider,model:snapshot.model,profile:snapshot.profile,effort:snapshot.effort.rawValue,
                bindingID:binding.configurationID,promptVersion:snapshot.alignmentPromptVersion)
            if let cached = cache[session,default:.init()].value(for:key!) { reading[session]?.phraseRanges = cached; return }
        }
        let generation = reading[session]!.selectionGeneration, revision = workspace.tabs[i].document.sourceRevision
        analysis[session]?.cancel()
        analysis[session] = Task {
            do {
                try await Task.sleep(for:.milliseconds(350)); try Task.checkCancellation()
                guard let current = workspace.index(of:session), workspace.tabs[current].document.sourceRevision == revision,
                      reading[session]?.selectionGeneration == generation,
                      workspace.tabs[current].document.translations.first(where:{$0.unitID==unit}) == translated else { return }
                if let binding {
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
                    let before = (readingText as NSString).substring(to:selection.range.location)
                    let after = (readingText as NSString).substring(from:selection.range.end!)
                    let result = try await gateway.alignSelection(.init(readingText:readingText,counterpartText:counterpart,before:before,selectedText:selectedText,after:after),
                        configuration:.init(provider:snapshot.provider,model:snapshot.model,profile:snapshot.profile,
                                           baseURL:binding.baseURL,effort:snapshot.effort,apiKey:credentials.apiKey,
                                           configurationID:binding.configurationID, requestOptions: binding.requestOptions, secretHeaders: credentials.headers))
                    try Task.checkCancellation()
                    guard let current = workspace.index(of:session), workspace.tabs[current].document.sourceRevision == revision,
                          reading[session]?.selectionGeneration == generation,
                          workspace.tabs[current].document.translations.first(where:{$0.unitID==unit}) == translated else { return }
                    let ranges: [BiparaCore.TextRange]
                    if case .matched(let matches) = result.match { ranges = CorrespondenceResolver.resolveMatches(matches.map{($0.quote,$0.occurrence)},in:counterpart)?.ranges ?? [] }
                    else { ranges = [] }
                    cache[session,default:.init()].insert(ranges,for:key!); reading[session]?.phraseRanges = ranges
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
