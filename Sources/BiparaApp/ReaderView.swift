import BiparaCore
import SwiftUI

public struct WorkspaceView: View {
    @ObservedObject private var runtime: AppRuntime
    @ObservedObject private var workspace: WorkspaceStore
    @ObservedObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    public init(runtime: AppRuntime) { self.runtime = runtime; workspace = runtime.workspace; settings = runtime.settings }
    private func t(_ key:String) -> String { runtime.text(key) }
    public var body: some View {
        VStack(spacing:0) {
            tabs
            Divider()
            if let tab = workspace.activeTab {
                if runtime.editing.contains(tab.sessionID) { input(tab).id(tab.sessionID) }
                else {
                    readingKey(tab)
                    NativeReadingSurface(sessionID:tab.sessionID,document:tab.document,layout:tab.layout,typography:settings.record.typography,
                        presentation:runtime.reading[tab.sessionID] ?? .init(),language:settings.record.interfaceLanguage,
                        readingWidth:settings.record.readingWidth,correspondenceColor:settings.record.correspondenceColor,jobState:tab.job.state,
                        onSelect:{runtime.selected($0,session:tab.sessionID)},onHover:{runtime.hover($0,session:tab.sessionID)},
                        onAnchor:{ anchor in
                            if runtime.reading[tab.sessionID]?.anchors[tab.layout] != anchor {
                                runtime.reading[tab.sessionID,default:.init()].anchors[tab.layout] = anchor
                            }
                        }).frame(maxWidth:.infinity,maxHeight:.infinity)
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
        .frame(minWidth:800,minHeight:560)
        .toolbar {
            ToolbarItem(placement:.navigation) { Button(action:runtime.newTab){Label(t("New Translation"),systemImage:"plus")}.accessibilityIdentifier("new.tab") }
            ToolbarItemGroup(placement:.primaryAction) {
                if let tab = workspace.activeTab {
                    Picker(t("Reading layout"),selection:Binding(get:{tab.layout},set:{runtime.setLayout($0)})) {
                        Image(systemName:"rectangle.split.2x1").accessibilityLabel(t("Side by side")).tag(LayoutMode.sideBySide)
                        Image(systemName:"rectangle.split.1x2").accessibilityLabel(t("Paragraphs")).tag(LayoutMode.paragraphs)
                    }.pickerStyle(.segmented).frame(width:86).help(t("Side by side / Paragraphs")).accessibilityIdentifier("reading.layout").disabled(runtime.editing.contains(tab.sessionID))
                    activeModelMenu
                    Button(primaryTitle(tab),action:runtime.primaryAction)
                        .disabled(runtime.closing.contains(tab.sessionID) || (![.queued,.running].contains(tab.job.state) && (runtime.composing.contains(tab.sessionID) || tab.draftText.isWhitespaceOnly || tab.draftText.isEmpty)))
                        .accessibilityIdentifier("translation.primary")
                    Menu {
                        Button(t("Edit Original")){runtime.editing.insert(tab.sessionID)}
                        Button(t("Copy Original")){runtime.copy(original:true)}
                        Button(t("Copy Translation")){runtime.copy(original:false)}.disabled(tab.job.state != .completed)
                        Button(t("Retranslate")){Task{await runtime.translate(tab.sessionID,retranslate:true)}}.disabled([.queued,.running].contains(tab.job.state))
                    } label:{Image(systemName:"ellipsis.circle")}.accessibilityLabel(t("Document actions"))
                }
            }
        }
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
        .alert(t("Unable to complete the action"),isPresented:Binding(get:{runtime.errorMessage != nil},set:{if !$0{runtime.errorMessage=nil}})) {
            Button(t("OK")){runtime.errorMessage=nil}
        } message:{Text(t(runtime.errorMessage ?? ""))}
        .onExitCommand { runtime.clearPin() }
    }
    private var tabs: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:4) {
                ForEach(workspace.tabs,id:\.sessionID){tab in
                    HStack(spacing:7) {
                        Button {
                            if let i=workspace.index(of:tab.sessionID){workspace.switchTab(to:i)}
                        } label:{
                            HStack(spacing:5){
                                Text(tab.document.title).lineLimit(1)
                                if tab.isDirty {Image(systemName:"circle.fill").font(.system(size:5))}
                                if [.queued,.running].contains(tab.job.state){ProgressView().controlSize(.mini)}
                            }.frame(maxWidth:180)
                        }.buttonStyle(.plain).accessibilityIdentifier("tab.\(tab.sessionID)")
                            .help(tab.document.title)
                            .accessibilityLabel(tab.document.title)
                            .accessibilityValue(t(tab.job.state.rawValue.capitalized) + (tab.isDirty ? ", " + t("Unsaved changes") : ""))
                            .accessibilityAddTraits(workspace.activeTab?.sessionID == tab.sessionID ? .isSelected:[])
                        Button {Task{_ = await runtime.close(tab.sessionID)}} label:{Image(systemName:"xmark").font(.system(size:9,weight:.semibold))}
                            .buttonStyle(.plain).accessibilityLabel(t("Close tab")+": "+tab.document.title)
                    }.padding(.horizontal,12).padding(.vertical,8)
                     .background(workspace.activeTab?.sessionID==tab.sessionID ? Color.accentColor.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))
                }
                Button(action:runtime.newTab){Image(systemName:"plus")}.buttonStyle(.borderless).accessibilityLabel(t("New Translation"))
            }.padding(.horizontal,12).padding(.vertical,6)
        }.accessibilityIdentifier("workspace.tabs")
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
            Text(active?.resolvedName ?? t("Active Model")).lineLimit(1)
        }
        .accessibilityLabel(t("Active Model"))
        .accessibilityValue(active?.resolvedName ?? t("No configurations"))
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
            let pane = geometry.size.width / (tab.layout == .sideBySide ? 2 : 1)
            let inset = ReadingMetrics.inset(pane:pane,layout:tab.layout,preference:settings.record.readingWidth,window:geometry.size.width)
            HStack(spacing:0) {
                if tab.layout == .sideBySide {
                    Text(t("Original")).padding(.horizontal,inset).frame(width:pane,alignment:.leading)
                    Text(t("Translation")).padding(.horizontal,inset).frame(width:pane,alignment:.leading)
                } else {
                    HStack(spacing:16) {
                        Text(t("Original")).foregroundStyle(Color(nsColor:ThemeColors.source))
                        Text(t("Translation")).foregroundStyle(Color(nsColor:ThemeColors.translation))
                            .padding(.leading,8).overlay(alignment:.leading){Rectangle().fill(.secondary).frame(width:2)}
                    }.padding(.horizontal,inset)
                }
            }.font(.caption).foregroundStyle(.secondary).frame(height:34)
        }.frame(height:34)
    }

    private func input(_ tab:TabState)->some View {
        VStack(alignment:.leading,spacing:16) {
            Text(t(tab.document.source.isEmpty ? "New Translation" : "Edit Original")).font(.title2.weight(.semibold))
            Text(t("Paste Chinese or English text to get started.")).foregroundStyle(.secondary)
            SourceEditorView(text:Binding(get:{workspace.tabs.first(where:{$0.sessionID==tab.sessionID})?.draftText ?? ""},set:{value in mutate(tab.sessionID){$0.draftText=value}}),
                isComposing:Binding(get:{runtime.composing.contains(tab.sessionID)},set:{value in if value != runtime.composing.contains(tab.sessionID) {if value{runtime.composing.insert(tab.sessionID)}else{runtime.composing.remove(tab.sessionID)}}}))
            HStack {
                Text(t("Your original is preserved exactly.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !tab.document.source.isEmpty {
                    Button(t("Cancel")) {mutate(tab.sessionID){$0.draftText=$0.document.source;$0.draftDirection=$0.document.requestedDirection};runtime.editing.remove(tab.sessionID)}
                    Button(t("Apply")){Task{do{try await runtime.apply(tab.sessionID)}catch{runtime.report(error,fallback:"The edited text could not be applied.")}}}.disabled(runtime.composing.contains(tab.sessionID))
                }
                Button(t("Translate")){Task{await runtime.translate(tab.sessionID)}}.buttonStyle(.borderedProminent)
                    .disabled(tab.draftText.isEmpty || tab.draftText.isWhitespaceOnly || runtime.composing.contains(tab.sessionID))
            }
        }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func status(_ tab:TabState)->some View {
        let state=runtime.reading[tab.sessionID] ?? .init(), match=state.pinned ?? state.selection ?? state.hover
        return HStack(spacing:12) {
            if state.analyzing {ProgressView().controlSize(.small);Text(t("Analyzing selection…"))}
            else if let match {
                Text(t(!state.displayedPhraseRanges.isEmpty ? "Suggested phrase correspondence" : match.unitID == nil ? "Paragraph match" : tab.document.units.first(where:{$0.id==match.unitID})?.kind == .fragment ? "Fragment match" : "Sentence match"))
                Button(t("Pin"),action:runtime.pin).disabled(!state.canPin)
                if state.pinned != nil {Button(t("Clear pin"),action:runtime.clearPin)}
                Button(t("Reveal counterpart"),action:runtime.reveal)
            } else {Text(t("Select text to explore correspondence.")).foregroundStyle(.secondary)}
            Spacer()
            TranslationJobStatus(tab:tab,configuration:tab.runtimeBinding.flatMap{settings.record.configuration(id:$0.configurationID)},language:settings.record.interfaceLanguage)
        }.font(.caption).controlSize(.small).padding(.horizontal,20).padding(.vertical,10).background(.bar)
            .accessibilityElement(children:.contain).accessibilityIdentifier("reading.status")
    }
    private func primaryTitle(_ tab:TabState)->String {
        t([JobState.running:"Cancel",.queued:"Cancel",.paused:"Resume",.failed:"Retry",.completed:"Retranslate"][tab.job.state] ?? "Translate")
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
        let detail = snapshot.map { "\(ModelVendor(rawValue:$0.provider)?.name ?? $0.provider) · \($0.model) · \($0.effort.label(t))" } ?? ""
        let timeHelp = t(tab.elapsed.sinceOpen ? "Active translation time since this file was opened; paused time and selection analysis are excluded." : "Active translation time, including queueing and retries; paused time and selection analysis are excluded.")
        return ViewThatFits(in:.horizontal) {
            HStack(spacing:7) { if let name { Text(name).lineLimit(1); Text("·") }; progress; elapsed }
            HStack(spacing:7) { Image(systemName:"info.circle").help(detail); progress; elapsed }
        }
        .foregroundStyle(.secondary).monospacedDigit()
        .help(detail + "\n" + t("Completed translation units / total units") + "\n" + timeHelp)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(detail), \(t(tab.job.state.rawValue.capitalized)), \(tab.document.translations.count) / \(tab.job.totalNonblankUnits)")
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
