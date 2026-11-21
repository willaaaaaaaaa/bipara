import BiparaCore
import SwiftUI

public struct WorkspaceView: View {
    @ObservedObject private var runtime: AppRuntime
    @ObservedObject private var workspace: WorkspaceStore
    @ObservedObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var tabStripWidth: CGFloat?
    @State private var projectedMarkdown: ProjectedMarkdown?

    private struct ProjectionKey: Equatable {
        let session: UUID
        let revision: Int
        let translationCount: Int
        let jobID: UUID?
        let mode: MarkdownReadingMode
    }

    private struct ProjectedMarkdown {
        let key: ProjectionKey
        let value: MarkdownReadingProjection
    }

    public init(runtime: AppRuntime) { self.runtime = runtime; workspace = runtime.workspace; settings = runtime.settings }
    private func t(_ key:String) -> String { runtime.text(key) }
    private var theme: AppTheme { settings.record.theme }

    private var documentGradient: LinearGradient {
        let hue = Double(workspace.activeTab?.document.documentID.uuid.0 ?? 0) / 256
        let dark = colorScheme == .dark
        return LinearGradient(colors: [hue, (hue + 0.19).truncatingRemainder(dividingBy: 1)].map {
            Color(hue: $0, saturation: dark ? 0.38 : 0.24, brightness: dark ? 0.38 : 0.98)
        }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var toolbarStyle: AnyShapeStyle {
        switch theme {
        case .dynamicCapsule: AnyShapeStyle(.bar)
        case .gradientFrame: AnyShapeStyle(documentGradient)
        case .smokedGlass: reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial)
        }
    }

    public var body: some View {
        VStack(spacing:0) {
            tabs
                .background {
                    switch theme {
                    case .dynamicCapsule: Color.clear
                    case .gradientFrame: documentGradient
                    case .smokedGlass:
                        if reduceTransparency { Color(nsColor: .controlBackgroundColor) }
                        else if #available(macOS 26.0, *) { Rectangle().fill(.clear).glassEffect(.regular.tint(.gray.opacity(0.18)), in: .rect) }
                        else { Rectangle().fill(.regularMaterial) }
                    }
                }
            Divider()
            if let tab = workspace.activeTab {
                if runtime.editing.contains(tab.sessionID) { input(tab).id(tab.sessionID) }
                else {
                    readingKey(tab)
                    documentReader(tab)
                    status(tab)
                }
            } else {
                VStack(spacing:14) {
                    Image(systemName:"text.book.closed").font(.system(size:42,weight:.light)).foregroundStyle(.secondary)
                    Text("Bipara").font(.largeTitle.weight(.medium))
                    Text(t("Read two languages, together.")).font(.title3).foregroundStyle(.secondary)
                    HStack {
                        Button(t("New Translation"),action:runtime.newTab).buttonStyle(.borderedProminent)
                        Button(t("Open…"),action:runtime.openPanel)
                    }.padding(.top,8)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .padding([.horizontal, .bottom], theme == .gradientFrame ? 4 : 0)
        .background { if theme == .gradientFrame { documentGradient } }
        .frame(minWidth:800,minHeight:560)
        .toolbar {
            if let tab = workspace.activeTab {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker(t("Reading layout"), selection: Binding(
                        get: { tab.readingView },
                        set: { choice in
                            Task { @MainActor in
                                guard runtime.activeSession == tab.sessionID else { return }
                                runtime.setReadingView(choice)
                            }
                        }
                    )) {
                        layoutIcon("Side by side", systemImage: "rectangle.split.2x1")
                            .tag(ReadingViewChoice.paired(.sideBySide))
                        layoutIcon(tab.document.isMarkdown ? "Sections" : "Paragraphs", systemImage: "rectangle.split.1x2")
                            .tag(ReadingViewChoice.paired(.paragraphs))
                        if tab.document.canUseMarkdownPlan {
                            layoutIcon("Translation Reader", systemImage: "doc.text")
                                .accessibilityIdentifier("reading.layout.translationReader").tag(ReadingViewChoice.translationReader)
                        }
                    }.pickerStyle(.segmented).frame(width: 124)
                        .accessibilityIdentifier("reading.layout").disabled(runtime.editing.contains(tab.sessionID))
                    if tab.document.isMarkdown && tab.document.canUseMarkdownPlan && !runtime.editing.contains(tab.sessionID) {
                        Picker(t("Reading mode"), selection: Binding(
                            get: { tab.document.readingMode },
                            set: { mode in
                                Task { @MainActor in
                                    guard runtime.activeSession == tab.sessionID else { return }
                                    runtime.changeReadingMode(mode, session: tab.sessionID)
                                }
                            }
                        )) {
                            Text(t("Preview")).tag(MarkdownReadingMode.rendered)
                            Text(t("Source")).tag(MarkdownReadingMode.source)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("reading.mode")
                    }
                }
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    activeModelMenu
                    Button(primaryTitle(tab),action:runtime.primaryAction)
                        .disabled(runtime.closing.contains(tab.sessionID) || (tab.hasNoProseToTranslate && !runtime.editing.contains(tab.sessionID)) || (![.queued,.running].contains(tab.job.state) && (runtime.composing.contains(tab.sessionID) || tab.draftText.isWhitespaceOnly || tab.draftText.isEmpty)))
                        .accessibilityIdentifier("translation.primary")
                    Menu {
                        Button(t("Edit Original")){runtime.editOriginal(tab.sessionID)}
                        Button(t("Copy Original")){runtime.copy(original:true)}
                        Button(t("Copy Translation")) { runtime.copy(original: false) }.disabled(!tab.canCopyTranslation || runtime.replacing.contains(tab.sessionID))
                        formatPicker(tab)
                        if tab.job.state != .completed {
                            Button(t("Retranslate")) { Task { await runtime.translate(tab.sessionID, retranslate: true) } }
                                .disabled([.queued, .running].contains(tab.job.state) || tab.hasNoProseToTranslate)
                                .accessibilityIdentifier("document.retranslate")
                        }
                    } label:{Image(systemName:"ellipsis.circle")}.accessibilityLabel(t("Document actions"))
                }
            }
        }
        .toolbarBackground(toolbarStyle, for: .windowToolbar)
        .toolbarBackground(theme == .dynamicCapsule ? Visibility.automatic : .visible, for: .windowToolbar)
        .background(WindowLifecycle(runtime:runtime,settings:false))
        .environment(\.locale,Locale(identifier:settings.record.interfaceLanguage.rawValue))
        .onChange(of:settings.record){_, record in runtime.appearance.apply(record.appearance)}
        .onChange(of:runtime.settingsRequested){_, requested in
            if requested { openWindow(id: "settings"); runtime.settingsRequested = false }
        }
        .sheet(item:Binding(get:{runtime.bindingRequest},set:{runtime.bindingRequest=$0})) { request in
            BindingSheet(request:request,language:settings.record.interfaceLanguage) { configurationID in
                runtime.bindAndResume(request,configurationID:configurationID)
            } onCancel:{runtime.bindingRequest=nil}
        }
        .sheet(item: $runtime.markdownFailure) { report in
            markdownFailureSheet(report)
        }
        .alert(t("Unable to complete the action"),isPresented:Binding(get:{runtime.errorMessage != nil},set:{if !$0{runtime.errorMessage=nil}})) {
            Button(t("OK")){runtime.errorMessage=nil}
        } message:{Text(t(runtime.errorMessage ?? ""))}
    }

    private func markdownFailureSheet(_ report: AppRuntime.MarkdownFailurePresentation) -> some View {
        MarkdownFailureSheet(report: report, language: settings.record.interfaceLanguage) {
            runtime.markdownFailure = nil
        }
        .id(report.id)
    }
    private func layoutIcon(_ key: String, systemImage: String) -> some View {
        let title = t(key)
        return Image(systemName: systemImage)
            .accessibilityLabel(title)
            .help(title)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.tabs, id: \.sessionID) { tab in
                            tabItem(tab).id(tab.sessionID)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabStripWidth = $0 }
                }
                .frame(maxWidth: tabStripWidth)
                .accessibilityIdentifier("workspace.tabs")
                .onChange(of: workspace.activeTab?.sessionID, initial: true) { _, session in
                    if let session { proxy.scrollTo(session) }
                }
            }
            .layoutPriority(1)
            Button(action: runtime.newTab) { Image(systemName: "plus") }
                .fixedSize().layoutPriority(2)
                .buttonStyle(.borderless)
                .accessibilityLabel(t("New Translation")).accessibilityIdentifier("new.tab")
                .help(t("New Translation"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func tabItem(_ tab: TabState) -> some View {
        let selected = workspace.activeTab?.sessionID == tab.sessionID
        let failed = runtime.hasTranslationFailure(for: tab.sessionID)
        let status = t(failed ? "Translation failed" : tab.job.state.rawValue.capitalized)
        return HStack(spacing: 7) {
            Button {
                if let index = workspace.index(of: tab.sessionID) { workspace.switchTab(to: index) }
            } label: {
                HStack(spacing: 5) {
                    Text(tab.document.title).lineLimit(1)
                    if tab.isDirty { Image(systemName: "circle.fill").font(.system(size: 5)) }
                    if failed { Image(systemName: "exclamationmark.triangle.fill") }
                    if [.queued, .running].contains(tab.job.state) {
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                    }
                }.frame(maxWidth: 180)
            }
            .buttonStyle(.plain).accessibilityIdentifier("tab.\(tab.sessionID)")
            .help(tab.document.title).accessibilityLabel(tab.document.title)
            .accessibilityValue(status + (tab.isDirty ? ", " + t("Unsaved changes") : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { Task { _ = await runtime.close(tab.sessionID) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain).accessibilityLabel(t("Close tab") + ": " + tab.document.title)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var activeModelMenu: some View {
        let active = settings.record.defaultConfiguration
        return Menu {
            ForEach(settings.record.modelConfigurations) { configuration in
                Button {
                    do { try settings.selectActiveModel(configuration.id) }
                    catch { runtime.report(error, fallback: "Unable to switch the active model.") }
                } label: {
                    let title = configuration.pickerLabel(effortLabel: configuration.effort.label(t))
                    if configuration.id == active?.id { Label(title, systemImage: "checkmark") }
                    else { Text(title) }
                }
            }
            if active == nil {
                Button(t("Add Model in Settings…")) { openWindow(id: "settings") }
            }
        } label: {
            Text(active.map { $0.selectionLabel(in: settings.record.modelConfigurations, effortLabel: $0.effort.label(t)) } ?? t("Active Model")).lineLimit(1)
        }
        .accessibilityLabel(t("Active Model"))
        .accessibilityValue(active.map { $0.pickerLabel(effortLabel: $0.effort.label(t)) } ?? t("No configurations"))
        .accessibilityIdentifier("translation.activeModel")
        .help(activeModelHelp(active))
    }

    private func activeModelHelp(_ active: ModelConfigurationRecord?) -> String {
        guard let tab = workspace.activeTab,
              [.paused, .failed].contains(tab.job.state),
              let job = tab.job.snapshot ?? tab.document.jobSnapshot,
              active?.id != tab.runtimeBinding?.configurationID || active?.modelID != job.model
                || active?.effort != job.effort else { return t("Default for new translations. Existing jobs keep their model.") }
        return t("Resume and Retry use the original model.") + " " + job.model
    }

    private func readingKey(_ tab: TabState) -> some View {
        GeometryReader { geometry in
            let layout: LayoutMode = tab.isTranslationReader ? .paragraphs : tab.layout
            let pane = geometry.size.width / (layout == .sideBySide ? 2 : 1)
            let inset = ReadingMetrics.inset(pane:pane,layout:layout,preference:settings.record.readingWidth,window:geometry.size.width)
            HStack(spacing:0) {
                if tab.isTranslationReader {
                    Text(t("Translation")).padding(.horizontal, inset)
                } else if tab.layout == .sideBySide {
                    Text(t("Original")).padding(.horizontal,inset).frame(width:pane,alignment:.leading)
                    Text(t("Translation")).padding(.horizontal,inset).frame(width:pane,alignment:.leading)
                } else {
                    HStack(spacing:16) {
                        Text(t("Original")).foregroundStyle(Color(nsColor:ThemeColors.source))
                        Text(t("Translation")).foregroundStyle(Color(nsColor:ThemeColors.translation))
                            .padding(.leading,8).overlay(alignment:.leading){Rectangle().fill(.secondary).frame(width:2)}
                    }.padding(.horizontal,inset)
                }
            }.font(.caption).foregroundStyle(.primary).frame(height:34)
        }.frame(height:34)
    }

    @ViewBuilder
    private func documentReader(_ tab: TabState) -> some View {
        let document = tab.document
        let key = ProjectionKey(session: tab.sessionID, revision: document.sourceRevision, translationCount: document.translations.count,
                                jobID: document.jobSnapshot?.jobID, mode: document.readingMode)
        let projection = projectedMarkdown.flatMap { value in
            value.key.session == key.session && value.key.revision == key.revision && value.key.jobID == key.jobID && value.key.mode == key.mode && value.key.translationCount <= key.translationCount ? value.value : nil
        }
        Group {
            if !document.isMarkdown || projection != nil {
                NativeReadingSurface(sessionID: tab.sessionID, document: document, layout: tab.isTranslationReader ? .paragraphs : tab.layout, typography: settings.record.typography,
                    presentation: runtime.reading[tab.sessionID] ?? .init(), language: settings.record.interfaceLanguage,
                    readingWidth: settings.record.readingWidth, jobState: tab.job.state,
                    markdown: projection, translationOnly: tab.isTranslationReader, reduceMotion: reduceMotion,
                    onMount: { runtime.nativeReader = $0 },
                    onAnchor: { anchor in
                        if tab.isTranslationReader {
                            if runtime.reading[tab.sessionID]?.readerAnchor != anchor { runtime.reading[tab.sessionID, default: .init()].readerAnchor = anchor }
                        } else if runtime.reading[tab.sessionID]?.anchors[tab.layout] != anchor {
                            runtime.reading[tab.sessionID, default: .init()].anchors[tab.layout] = anchor
                        }
                    })
                    .id(tab.sessionID)
            } else {
                ProgressView().accessibilityLabel(t("Preparing Markdown"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) {
            guard document.isMarkdown, projectedMarkdown?.key != key else { return }
            let value = await Task.detached { document.markdownProjection() }.value
            guard !Task.isCancelled, let value else { return }
            projectedMarkdown = ProjectedMarkdown(key: key, value: value)
        }
    }

    private func formatPicker(_ tab: TabState) -> some View {
        Picker(t("Format"), selection: Binding(
            get: { tab.draftFormat },
            set: { runtime.changeFormat($0, session: tab.sessionID) }
        )) {
            Text(t("Auto")).tag(ContentFormat.auto)
            Text(t("Markdown")).tag(ContentFormat.markdown)
            Text(t("Plain Text")).tag(ContentFormat.plainText)
        }
        .accessibilityIdentifier("document.format")
        .disabled(runtime.composing.contains(tab.sessionID))
    }

    private func input(_ tab:TabState)->some View {
        VStack(alignment:.leading,spacing:16) {
            Text(t(tab.document.source.isEmpty ? "New Translation" : "Edit Original")).font(.title2.weight(.semibold))
            HStack {
                Text(t("Paste Chinese or English text to get started.")).foregroundStyle(.secondary)
                failureDetails(tab)
            }
            SourceEditorView(text:Binding(get:{workspace.tabs.first(where:{$0.sessionID==tab.sessionID})?.draftText ?? ""},set:{value in mutate(tab.sessionID){$0.draftText=value}}),
                isComposing:Binding(get:{runtime.composing.contains(tab.sessionID)},set:{value in if value != runtime.composing.contains(tab.sessionID) {if value{runtime.composing.insert(tab.sessionID)}else{runtime.composing.remove(tab.sessionID)}}}), language:settings.record.interfaceLanguage, typography:settings.record.typography)
            HStack {
                formatPicker(tab)
                if let detected = runtime.formatStatus(tab) {
                    Text(t("Auto") + " · " + detected)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("document.detectedFormat")
                }
                Spacer()
                if !tab.document.source.isEmpty {
                    Button(t("Cancel")) { runtime.cancelEditing(tab.sessionID) }
                }
                Button(t("Apply")) {
                    Task {
                        do { try await runtime.apply(tab.sessionID) }
                        catch { runtime.report(error, fallback: "The edited text could not be applied.") }
                    }
                }
                .disabled(runtime.composing.contains(tab.sessionID) || (tab.draftText.isEmpty && tab.document.source.isEmpty))
                Button(t("Translate")){Task{await runtime.translate(tab.sessionID)}}.buttonStyle(.borderedProminent)
                    .disabled(tab.draftText.isEmpty || tab.draftText.isWhitespaceOnly || runtime.composing.contains(tab.sessionID))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: DraftDetectionKey(generation: tab.draftGeneration, composing: runtime.composing.contains(tab.sessionID))) {
            await runtime.detectDraftFormat(tab.sessionID)
        }
    }
    private struct DraftDetectionKey: Equatable {
        let generation: Int
        let composing: Bool
    }

    @ViewBuilder private func failureDetails(_ tab: TabState) -> some View {
        if runtime.hasTranslationFailure(for: tab.sessionID) {
            Button(t("Show Failure Details")) { runtime.showTranslationFailure(for: tab.sessionID) }
                .accessibilityIdentifier("translation.failureDetails")
        }
    }

    private func status(_ tab:TabState)->some View {
        let capsule = theme == .dynamicCapsule
        return HStack(spacing:10) {
            if !tab.document.canUseMarkdownPlan {
                Text(t("This Markdown plan is unavailable. Retranslate to rebuild it."))
            } else if tab.document.isMarkdown && tab.document.units.isEmpty {
                Text(t("No prose to translate"))
            }
            if !capsule { Spacer() }
            if runtime.copyFeedback?.session == tab.sessionID, runtime.copyFeedback?.succeeded == false {
                Text(t("Copy failed")).foregroundStyle(.secondary)
            }
            failureDetails(tab)
            if runtime.showsCompletionCopy(tab) {
                Button(t(runtime.copyFeedback?.succeeded == true ? "Copied" : "Copy Translation")) {
                    runtime.copy(original: false)
                }
                .fixedSize().layoutPriority(2)
                .accessibilityIdentifier("reader.copyTranslation")
            }
            TranslationJobStatus(tab:tab,configuration:tab.runtimeBinding.flatMap{settings.record.configuration(id:$0.configurationID)},language:settings.record.interfaceLanguage)
        }.font(.caption).controlSize(.small)
            .padding(.horizontal, capsule ? 16 : 20)
            .padding(.vertical, capsule ? 5 : 8)
            .background {
                if capsule {
                    Capsule().fill(Color(nsColor: .controlBackgroundColor))
                        .overlay { Capsule().strokeBorder(.primary.opacity(0.16)) }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background {
                if theme == .smokedGlass && !reduceTransparency {
                    Rectangle().fill(.regularMaterial).overlay { Color.gray.opacity(0.10) }
                } else if !capsule {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .accessibilityElement(children:.contain).accessibilityIdentifier("reading.status")
    }
    private func primaryTitle(_ tab:TabState)->String {
        if !tab.document.canUseMarkdownPlan { return t("Retranslate") }
        return t([JobState.running:"Cancel",.queued:"Cancel",.paused:"Resume",.failed:"Retry",.completed:"Retranslate"][tab.job.state] ?? "Translate")
    }
    private func mutate(_ session:UUID,_ body:(inout TabState)->Void) {if let i=workspace.index(of:session){workspace.withTab(i,body)}}
}

/// Only this small subtree refreshes the clock; the native reading surface does not.
private struct TranslationJobStatus: View {
    let tab: TabState
    let configuration: ModelConfigurationRecord?
    let language: InterfaceLanguage
    private func t(_ key:String)->String { AppLocalization.text(key,language:language) }
    var body: some View {
        if tab.job.totalNonblankUnits > 0 {
            if [.queued,.running].contains(tab.job.state) {
                TimelineView(.periodic(from:.now,by:1)) { _ in content }
            } else { content }
        }
    }
    private var content: some View {
        let snapshot = tab.job.snapshot ?? tab.document.jobSnapshot
        let name = configuration?.modelID == snapshot?.model ? configuration?.resolvedName : snapshot?.model
        let detail = snapshot.map { "\(ModelConfigurationRecord.interfaceLabel(profile: $0.profile, provider: $0.provider)) · \($0.model) · \($0.effort.label(t))" } ?? ""
        let timeHelp = t(tab.elapsed.sinceOpen ? "Active translation time since this file was opened, excluding pauses." : "Active translation time includes queueing and retries and excludes pauses.")
        return ViewThatFits(in:.horizontal) {
            HStack(spacing:7) { if let name { Text(name).fixedSize(); Text("·") }; progress; elapsed }
            HStack(spacing:7) { Image(systemName:"info.circle").help(detail); progress; elapsed }
        }
        .foregroundStyle(.primary).monospacedDigit()
        .help(detail + "\n" + t("Completed translation units / total units") + "\n" + timeHelp)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(detail), \(t(tab.job.state.rawValue.capitalized)), \(tab.document.translations.count) / \(tab.job.totalNonblankUnits)")
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("translation.jobStatus")
    }
    private var progress: some View {
        HStack(spacing:5) {
            if [.queued,.running].contains(tab.job.state) { ProgressView().controlSize(.mini) }
            else if tab.job.state == .completed { Image(systemName:"checkmark") }
            else { Text(t(tab.job.state == .failed ? "Translation stopped" : tab.job.state.rawValue.capitalized)) }
            Text("\(tab.document.translations.count)/\(tab.job.totalNonblankUnits)")
        }.fixedSize()
    }
    @ViewBuilder private var elapsed: some View {
        if tab.elapsed.hasActivity { Text("· " + TranslationElapsed.format(seconds:tab.elapsed.seconds())).fixedSize().accessibilityHidden(true) }
    }
}

public struct SettingsContent: View {
    @ObservedObject var runtime: AppRuntime
    public init(runtime:AppRuntime){self.runtime=runtime}
    public var body:some View {
        SettingsView(store:runtime.settings,keychain:runtime.keychain)
            .navigationTitle(runtime.text("Settings"))
            .background(WindowLifecycle(runtime:runtime,settings:true))
            .onChange(of:runtime.settings.record){_, record in runtime.appearance.apply(record.appearance)}
    }
}

/// Explicit session-local configuration binding for an opened document:
/// matching configurations show their display name and destination host;
/// a file cannot prove its original endpoint, so the choice is explicit.
struct BindingSheet: View {
    let request: AppRuntime.BindingRequest
    let language: InterfaceLanguage
    let onPick: (UUID) -> Void
    let onCancel: () -> Void
    private func t(_ key: String) -> String { AppLocalization.text(key, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Choose the model configuration")).font(.headline)
            Text(String(format: t("This document was translated with %@. Pick the local configuration to use before continuing."), request.snapshot.model))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(request.matches) { configuration in
                Button {
                    onPick(configuration.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(configuration.resolvedName).lineLimit(1)
                            Text(CanonicalBaseURL.host(of: configuration.baseURL) ?? configuration.baseURL)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(configuration.effort.label(t)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("binding.option.\(configuration.id)")
            }
            HStack {
                Spacer()
                Button(t("Cancel"), action: onCancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("binding.cancel")
            }
        }.padding(20).frame(width: 460)
    }
}

private struct MarkdownFailureSheet: View {
    let report: AppRuntime.MarkdownFailurePresentation
    let language: InterfaceLanguage
    let dismiss: () -> Void
    @State private var selectedUnit: UUID?

    private func t(_ key: String) -> String { AppLocalization.text(key, language: language) }

    var body: some View {
        let passages = report.failure.passages
        let passage = passages.first { $0.id == selectedUnit } ?? passages.first
        let difference = report.failure.difference
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Markdown validation failed")).font(.headline)
            Text(report.title).lineLimit(1).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch difference {
                    case .inlineStructure(let expected, let received):
                        structure(t("Inline formatting or protected content differs."), expected: expected, received: received)
                    case .blockStructure(let expected, let received):
                        structure(t("Block structure differs after insertion into the document."), expected: expected, received: received)
                    case .textShape:
                        Text(t("The reply violates the text length, whitespace, or line break rules."))
                    case .inlineParse:
                        Text(t("The reply could not be read as a single inline Markdown passage."))
                    case .tablePipe:
                        Text(t("The reply contains an unescaped pipe (|) inside a table cell."))
                    case .blockParse:
                        Text(t("The document could not be parsed after inserting the replies."))
                    case .unitOrder:
                        Text(t("The translation units do not match the source order."))
                    }

                    if passages.count > 1 {
                        Picker(t("Submitted unit"), selection: Binding(
                            get: { passage?.id },
                            set: { selectedUnit = $0 }
                        )) {
                            ForEach(passages) { item in
                                Text(unitLabel(item)).tag(Optional(item.id))
                            }
                        }
                    } else if let passage {
                        Text(unitLabel(passage)).font(.subheadline.weight(.semibold))
                    }
                    if let passage {
                        HStack(alignment: .top, spacing: 12) {
                            panel(t("Original sent to the model"), passage.input)
                            panel(t("Actual model reply"), passage.reply)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            HStack {
                Text(t("Completed translations were kept.")).foregroundStyle(.secondary)
                Spacer()
                Button(t("OK"), action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: 510)
    }

    private func unitLabel(_ passage: MarkdownPlan.ValidationFailure.Passage) -> String {
        String(format: t("Unit %lld"), passage.unitNumber)
    }

    private func structure(_ label: String, expected: [String], received: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
            HStack(alignment: .top, spacing: 12) {
                panel(t("Expected structure"), signature(expected))
                panel(t("Received structure"), signature(received))
            }
        }
    }

    private func signature(_ tokens: [String]) -> String {
        guard !tokens.isEmpty else { return t("No corresponding structure") }
        let lines = tokens.prefix(8).map { token in
            switch token {
            case "strong": return t("Bold (**)")
            case "em": return t("Italic (*)")
            case "strike": return t("Strikethrough (~~)")
            case "break": return t("Hard line break")
            case "paragraph": return t("Paragraph")
            case "/": return t("End of structure")
            default:
                let start = token.prefix(160)
                return start.count == token.count ? String(start) : String(start) + "…"
            }
        }
        return (lines + (tokens.count > lines.count ? ["…"] : [])).joined(separator: "\n")
    }

    private func panel(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.subheadline.weight(.semibold))
            Text(verbatim: value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
