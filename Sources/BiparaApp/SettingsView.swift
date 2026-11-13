import BiparaCore
import SwiftUI

// MARK: - Effort display

extension ModelEffort {
    /// Localized list/editor label. `auto` is Default; a known
    /// nonreasoning model shows Not applicable in the editor instead.
    func label(_ t: (String) -> String, applicable: Bool = true) -> String {
        guard applicable else { return t("Not applicable") }
        switch self {
        case .auto: return t("Default")
        case .off: return t("Off")
        case .on: return t("On")
        case .minimal: return t("Minimal")
        case .low: return t("Low")
        case .medium: return t("Medium")
        case .high: return t("High")
        case .xhigh: return t("Extra high")
        case .max: return t("Max")
        }
    }
}

// MARK: - Settings

public struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    private let keychain: any CredentialStore
    @State private var selectedConfigurationID: UUID?
    @State private var sheet: SheetKind?
    @State private var error: String?

    /// The single presented sheet: the configuration editor or the
    /// default-replacement deletion flow.
    enum SheetKind: Identifiable {
        case editor(EditorKind)
        case deletion(DeletionRequest)

        var id: UUID {
            switch self {
            case .editor(let kind): return kind.id
            case .deletion(let request): return request.id
            }
        }
    }

    /// Which configuration editor sheet is open, if any.
    enum EditorKind: Identifiable {
        case add
        case edit(ModelConfigurationRecord)

        var id: UUID {
            switch self {
            case .add: return UUID()
            case .edit(let record): return record.id
            }
        }

        var existing: ModelConfigurationRecord? {
            switch self {
            case .add: return nil
            case .edit(let record): return record
            }
        }
    }

    public init(store: SettingsStore, keychain: any CredentialStore) { self.store = store; self.keychain = keychain }
    private func t(_ key: String) -> String { AppLocalization.text(key, language: store.record.interfaceLanguage) }

    /// An explicit default-replacement choice when deleting the default of
    /// a nonempty draft; cancellation leaves the draft unchanged.
    struct DeletionRequest: Identifiable {
        let id = UUID()
        let target: UUID
        let others: [ModelConfigurationRecord]
    }

    public var body: some View {
        VStack(spacing:0) {
            if let failure = store.loadFailure {
                // Blocking load/migration failure: preserved data stays
                // authoritative, Save is refused, and a failed migration
                // can be retried in place (S3).
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(t(failure.messageKey)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if failure.kind == .migrationFailed {
                        Button(t("Try Again")) { store.retryMigration() }
                            .accessibilityIdentifier("settings.load.retry")
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                .accessibilityIdentifier("settings.load.banner")
            }
            if let notice = store.maintenanceNotice {
                Text(t(notice)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.top, 8)
                    .accessibilityIdentifier("settings.maintenance.notice")
            }
            Form {
                Section(t("General")) {
                    Picker(t("Interface language"), selection: binding(\.interfaceLanguage)) {
                        Text("English").tag(InterfaceLanguage.english)
                        Text("简体中文").tag(InterfaceLanguage.simplifiedChinese)
                    }.accessibilityIdentifier("settings.language")
                    Picker(t("Translation Direction"), selection: Binding(
                        get: { store.draft.translationDirection },
                        set: { value in store.updateDraft { $0.preferredTranslationDirection = value } }
                    )) {
                        Text(t("Automatic")).tag(Direction.auto)
                        Text(t("Chinese → English")).tag(Direction.zhToEn)
                        Text(t("English → Chinese")).tag(Direction.enToZh)
                    }.accessibilityIdentifier("settings.translation.direction")
                    Picker(t("Appearance"), selection: binding(\.appearance)) {
                        Text(t("System")).tag(AppearanceMode.system)
                        Text(t("Light")).tag(AppearanceMode.light)
                        Text(t("Dark")).tag(AppearanceMode.dark)
                    }.accessibilityIdentifier("settings.appearance")
                    Toggle(t("Don't ask to save on close"), isOn: Binding(
                        get: { store.draft.dontAskToSaveOnClose },
                        set: { value in store.updateDraft { $0.skipDocumentSavePrompt = value } }
                    )).accessibilityIdentifier("settings.close.skipSave")
                }
                Section(t("Models")) {
                    modelsSection
                }
                Section(t("Reading")) {
                    Picker(t("Reading Width"), selection: Binding(
                        get: { store.draft.readingWidth },
                        set: { value in store.updateDraft { $0.preferredReadingWidth = value } }
                    )) {
                        ForEach(ReadingWidth.allCases, id: \.self) { Text(t($0.rawValue.capitalized)).tag($0) }
                    }.accessibilityIdentifier("settings.reading.width")
                    Picker(t("Correspondence Color"), selection: Binding(
                        get: { store.draft.correspondenceColor },
                        set: { value in store.updateDraft { $0.preferredCorrespondenceColor = value } }
                    )) {
                        ForEach(CorrespondenceColor.allCases, id: \.self) { preset in
                            HStack {
                                Circle().fill(Color(nsColor: ThemeColors.correspondence(preset))).frame(width: 12, height: 12)
                                Text(t(preset.rawValue.capitalized))
                            }.tag(preset)
                        }
                    }.accessibilityIdentifier("settings.reading.highlight")
                    Picker(t("Font family"), selection: typography(\.family)) {
                        Text(t("Monospaced")).tag(ReadingTypography.Family.monospaced)
                        Text(t("System")).tag(ReadingTypography.Family.system)
                        Text(t("Serif")).tag(ReadingTypography.Family.serif)
                    }
                    Picker(t("Line height"), selection: typography(\.lineHeight)) {
                        Text(t("Editor")).tag(ReadingTypography.LineHeight.editor)
                        Text(t("Compact")).tag(ReadingTypography.LineHeight.compact)
                        Text(t("Comfortable")).tag(ReadingTypography.LineHeight.comfortable)
                        Text(t("Spacious")).tag(ReadingTypography.LineHeight.spacious)
                    }
                    LabeledContent(t("Reading size")) {
                        Slider(value: typography(\.size), in: 12...28, step: 1)
                            .accessibilityLabel(t("Reading size"))
                            .accessibilityIdentifier("settings.reading.size")
                        Text("\(Int(store.draft.typography.size)) pt").monospacedDigit().frame(width: 44)
                            .accessibilityHidden(true)
                    }
                }
            }.formStyle(.grouped).padding(.vertical,8)
            Divider()
            if let error {
                Text(t(error)).font(.callout).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading)
                    .fixedSize(horizontal:false,vertical:true).padding(.horizontal,20).padding(.top,12).accessibilityIdentifier("settings.error")
            }
            HStack {
                Spacer()
                Button(t("Cancel")) { store.cancelDraft(); selectedConfigurationID = nil; sheet = nil; error = nil }
                    .disabled(!store.hasDraftChanges).accessibilityIdentifier("settings.cancel")
                Button(t("Save")) {
                    do { try store.saveDraft(); selectedConfigurationID = nil; error = nil }
                    catch SettingsStore.SettingsError.duplicateNameEffort { self.error = "Two configurations share the same name and effort. Give one a different display name." }
                    catch SettingsStore.SettingsError.compensationFailed { self.error = "Some credential changes could not be rolled back. Check the model settings before trying again." }
                    catch SettingsStore.SettingsError.invalidField("default model") { self.error = "Choose a new active model before saving." }
                    catch SettingsStore.SettingsError.invalidField { self.error = "Some settings are invalid. Check the model and reading settings, then save again." }
                    catch { self.error = "Settings could not be saved. Previous values were restored where possible." }
                }.keyboardShortcut(.defaultAction).disabled(!store.hasDraftChanges || store.loadFailure != nil).accessibilityIdentifier("settings.save")
            }
            .padding(.horizontal,20).padding(.vertical,12)
        }
        .frame(width:560,height:700)
        .sheet(item: $sheet) { kind in
            switch kind {
            case .editor(let editorKind):
                ConfigurationSheet(store: store, keychain: keychain, existing: editorKind.existing) { result in
                    self.sheet = nil
                    applySheet(result)
                } onCancel: { self.sheet = nil }
            case .deletion(let request):
                DeletionSheet(request: request, language: store.record.interfaceLanguage) { replacement in
                    self.sheet = nil
                    deleteConfiguration(request.target, replacement: replacement)
                } onCancel: { self.sheet = nil }
            }
        }
    }

    // MARK: Models section

    @ViewBuilder private var modelsSection: some View {
        // The active configuration is independent of the row selected for editing.
        Picker(t("Active Model"), selection: defaultBinding) {
            if store.draft.defaultModelConfigurationID == nil {
                Text(t(store.draft.modelConfigurations.isEmpty ? "No configurations" : "Choose a model")).tag(UUID?.none)
            }
            ForEach(store.draft.modelConfigurations) { configuration in
                Text(configuration.resolvedName).tag(UUID?.some(configuration.id))
            }
        }.accessibilityIdentifier("settings.model.default")
        if let selection = store.draft.defaultModelConfigurationID, selection != store.record.defaultModelConfigurationID {
            Text(t("Save applies the model selected here.")).font(.caption).foregroundStyle(.secondary)
        }
        if store.draft.modelConfigurations.isEmpty {
            Text(t("Add a model configuration to translate.")).font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(store.draft.modelConfigurations) { configuration in
                    let selected = selectedConfigurationID == configuration.id
                    let effort = configuration.effort.label(t)
                    let summary = "\(configuration.vendorName) · \(configuration.modelID) · \(effort)"
                    Button {
                        selectedConfigurationID = configuration.id
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(configuration.resolvedName)
                                .fontWeight(.medium)
                            Spacer(minLength: 0)
                            Text(summary)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .truncationMode(.middle)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            selected ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("\(configuration.resolvedName)\n\(summary)")
                    .accessibilityIdentifier("settings.model.row")
                    .accessibilityLabel(configuration.resolvedName)
                    .accessibilityValue("\(configuration.vendorName), \(configuration.modelID), \(effort)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("settings.models.list")
        }
        HStack {
            Button(t("Add")) { sheet = .editor(.add) }.accessibilityIdentifier("settings.models.add")
            Button(t("Edit")) {
                if let id = selectedConfigurationID,
                   let existing = store.draft.modelConfigurations.first(where: { $0.id == id }) {
                    sheet = .editor(.edit(existing))
                }
            }
            .disabled(selectedConfigurationID == nil)
            .accessibilityIdentifier("settings.models.edit")
            Button(t("Delete")) {
                if let id = selectedConfigurationID { requestDeletion(of: id) }
            }
            .disabled(selectedConfigurationID == nil)
            .accessibilityIdentifier("settings.models.delete")
        }
        // Any staged configuration deletion (active, non-active, or last
        // entry) explains the credential consequence before Save executes
        // it. A key-only deletion staged in the editor (the configuration
        // itself remains in the draft) is not a configuration deletion and
        // keeps its own sheet copy.
        if store.keyDrafts.contains(where: { pair in
            guard case .delete = pair.value else { return false }
            return !store.draft.modelConfigurations.contains(where: { $0.id == pair.key })
        }) {
            Text(t("A deleted configuration can no longer supply a credential for undispatched work. Dispatched requests can finish."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultBinding: Binding<UUID?> {
        Binding(
            get: { store.draft.defaultModelConfigurationID },
            set: { value in store.updateDraft { $0.defaultModelConfigurationID = value } })
    }

    // MARK: Sheet results

    private func applySheet(_ result: ConfigurationSheet.Result) {
        switch result {
        case .add(let record):
            store.updateDraft { draft in
                let wasEmpty = draft.modelConfigurations.isEmpty
                draft.modelConfigurations.append(record)
                // The first entry added to an empty draft becomes its
                // visibly selected default; later adds preserve it.
                if wasEmpty { draft.defaultModelConfigurationID = record.id }
            }
            selectedConfigurationID = record.id
        case .edit(let record):
            store.updateDraft { draft in
                guard let index = draft.modelConfigurations.firstIndex(where: { $0.id == record.id }) else { return }
                draft.modelConfigurations[index] = record
            }
        case .remove(let id):
            requestDeletion(of: id)
        }
    }

    private func requestDeletion(of id: UUID) {
        guard store.draft.modelConfigurations.contains(where: { $0.id == id }) else { return }
        let others = store.draft.modelConfigurations.filter { $0.id != id }
        // Deleting the default while other entries remain requires choosing
        // a replacement in the deletion sheet; deleting the last entry
        // clears the default; a nondefault deletion preserves the default.
        if store.draft.defaultModelConfigurationID == id, !others.isEmpty {
            sheet = .deletion(DeletionRequest(target: id, others: others))
        } else {
            deleteConfiguration(id, replacement: nil)
        }
    }

    private func deleteConfiguration(_ id: UUID, replacement: UUID?) {
        store.removeConfigurationFromDraft(id: id, replacement: replacement)
        if selectedConfigurationID == id { selectedConfigurationID = nil }
    }

    private func binding<T>(_ path: WritableKeyPath<PreferencesRecord, T>) -> Binding<T> {
        Binding(get: { store.draft[keyPath: path] }, set: { value in store.updateDraft { $0[keyPath: path] = value } })
    }
    private func typography<T>(_ path: WritableKeyPath<ReadingTypography, T>) -> Binding<T> {
        Binding(get: { store.draft.typography[keyPath: path] }, set: { value in store.updateDraft { $0.typography[keyPath: path] = value } })
    }
}

// MARK: - Deletion sheet (default replacement)

private struct DeletionSheet: View {
    let request: SettingsView.DeletionRequest
    let language: InterfaceLanguage
    let onConfirm: (UUID?) -> Void
    let onCancel: () -> Void
    @State private var replacement: UUID?
    private func t(_ key: String) -> String { AppLocalization.text(key, language: language) }

    init(request: SettingsView.DeletionRequest, language: InterfaceLanguage,
         onConfirm: @escaping (UUID?) -> Void, onCancel: @escaping () -> Void) {
        self.request = request; self.language = language
        self.onConfirm = onConfirm; self.onCancel = onCancel
        _replacement = State(initialValue: request.others.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Choose a replacement active model")).font(.headline)
            Text(t("Deleting the active model requires choosing a replacement. Dispatched requests can finish, but later requests needing the deleted credential cannot continue."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(t("Active Model"), selection: $replacement) {
                ForEach(request.others) { configuration in
                    Text(configuration.resolvedName).tag(UUID?.some(configuration.id))
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings.models.replacement")
            HStack {
                Spacer()
                Button(t("Cancel"), action: onCancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("settings.models.delete.cancel")
                Button(t("Delete")) { onConfirm(replacement) }
                    .keyboardShortcut(.defaultAction).disabled(replacement == nil)
                    .accessibilityIdentifier("settings.models.delete.confirm")
            }
        }.padding(20).frame(width: 440)
    }
}

// MARK: - Configuration editor sheet

/// Add/Edit sheet. Confirming updates the Settings draft only; the API
/// key edit is staged through `keyDrafts`. Save and Add never make a
/// network request. Existing key material is never
/// displayed.
struct ConfigurationSheet: View, Identifiable {
    enum Result {
        case add(ModelConfigurationRecord)
        case edit(ModelConfigurationRecord)
        case remove(UUID)
    }

    enum KeyEdit: Equatable {
        /// No explicit change in this sheet session: inherit whatever the
        /// Settings draft already stages for this entry (including a
        /// staged deletion shown as "Key will be deleted").
        case inherit
        /// Cancels, within this sheet, a deletion the Settings draft
        /// already staged; applied only when the sheet is confirmed.
        case restore
        case replace
        case delete
    }

    let id = UUID()
    @ObservedObject var store: SettingsStore
    let keychain: any CredentialStore
    let existing: ModelConfigurationRecord?
    let onConfirm: (Result) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var provider: String
    @State private var profile: String
    @State private var modelID: String
    @State private var effort: ModelEffort
    @State private var baseURL: String
    @State private var options: ModelRequestOptions
    @State private var keyEdit: KeyEdit = .inherit
    @State private var keyField: String = ""
    /// Canonical URL the currently typed key was entered for. A key typed
    /// for endpoint A never travels to endpoint B; returning to A's exact
    /// canonical form re-applies it (D1).
    @State private var keyEnteredForCanonicalURL: String?
    @State private var error: String?

    init(store: SettingsStore, keychain: any CredentialStore, existing: ModelConfigurationRecord?,
         onConfirm: @escaping (Result) -> Void, onCancel: @escaping () -> Void) {
        self.store = store; self.keychain = keychain; self.existing = existing
        self.onConfirm = onConfirm; self.onCancel = onCancel
        _displayName = State(initialValue: existing?.displayName ?? "")
        let api = existing.flatMap { ModelAPIProtocol.from(profile: $0.profile) } ?? .openai
        _provider = State(initialValue: api.rawValue)
        _profile = State(initialValue: api.profile)
        _modelID = State(initialValue: existing?.modelID ?? "")
        _effort = State(initialValue: existing?.effort ?? .low)
        _baseURL = State(initialValue: existing?.baseURL ?? "")
        _options = State(initialValue: existing?.requestOptions ?? ModelRequestOptions())
    }

    private func t(_ key: String) -> String { AppLocalization.text(key, language: store.record.interfaceLanguage) }

    /// The canonical form of the edited URL (identity when invalid).
    private var canonicalURL: String {
        if case .success(let canonical) = CanonicalBaseURL.canonicalize(baseURL) { return canonical }
        return baseURL
    }

    /// The committed endpoint this entry's credential belongs to: the
    /// saved record's URL when one exists. A reopened sheet shows the
    /// draft URL, so using `existing` here would misjudge a restored URL
    /// as changed.
    private var committedConfiguration: ModelConfigurationRecord? {
        guard let existing else { return nil }
        return store.record.configuration(id: existing.id) ?? existing
    }

    private var api: ModelAPIProtocol { ModelAPIProtocol(rawValue: provider) ?? .openai }
    private var credentialIdentity: String {
        var canonical = options
        if let endpoint = options.endpointURL,
           case .success(let value) = CanonicalBaseURL.canonicalize(endpoint, operationURL: true) { canonical.endpointURL = value }
        return canonical.credentialIdentity(baseURL: canonicalURL, profile: profile)
    }

    /// True when the edited URL no longer equals the committed canonical
    /// URL: the draft credential is then cleared and requires re-entry.
    private var urlChanged: Bool {
        guard let committedConfiguration else { return false }
        return committedConfiguration.credentialIdentity != credentialIdentity
    }

    private var typedKeyApplies: Bool {
        ConfigurationSheet.typedKeyApplies(
            keyEdit: keyEdit, keyEnteredForCanonicalURL: keyEnteredForCanonicalURL, canonicalURL: credentialIdentity)
    }

    /// The effective staged credential change for this entry. A typed key
    /// only applies at the exact canonical endpoint it was entered for
    /// (protocol switches and manual URL/path changes
    /// invalidate it; equivalent canonical spellings re-apply it);
    /// otherwise the committed-key URL rule governs (changed URL clears
    /// the key, restoring the exact committed URL restores the original
    /// key state unless the user explicitly replaced/deleted it).
    private var stagedKeyChange: SettingsStore.KeyDraftChange? {
        ConfigurationSheet.stagedKeyChange(
            existing: existing, keyEdit: keyEdit, keyField: keyField,
            keyEnteredForCanonicalURL: keyEnteredForCanonicalURL, currentCanonicalURL: canonicalURL,
            settingsStagedChange: existing.flatMap { store.keyDrafts[$0.id] },
            committedBaseURL: committedConfiguration?.baseURL,
            currentProvider: provider, committedProvider: committedConfiguration?.provider,
            currentCredentialIdentity: credentialIdentity, committedCredentialIdentity: committedConfiguration?.credentialIdentity)
    }

    private var hasStagedReplacement: Bool {
        if case .set = stagedKeyChange { return true }
        return false
    }

    /// The editor state produced by a keystroke in the key field: typing
    /// is an explicit replacement action, so inherit/restore states enter
    /// `.replace` (a new-entry key otherwise stayed dropped — N3).
    static func transitionedKeyEdit(onTyping keyEdit: KeyEdit) -> KeyEdit {
        (keyEdit == .inherit || keyEdit == .restore) ? .replace : keyEdit
    }

    /// Pure editor-credential state machine (D1), testable at the seam.
    static func typedKeyApplies(keyEdit: KeyEdit, keyEnteredForCanonicalURL: String?, canonicalURL: String) -> Bool {
        guard keyEdit == .replace, let enteredFor = keyEnteredForCanonicalURL else { return false }
        return enteredFor == canonicalURL
    }

    /// The credential change this sheet commits on confirmation. With the
    /// URL unchanged, `inherit` preserves whatever the Settings draft
    /// already staged; `restore` explicitly clears a staged deletion; an
    /// endpoint change always deletes the committed key unless an explicit
    /// replacement key typed at the new endpoint is staged (N1/N3).
    static func stagedKeyChange(
        existing: ModelConfigurationRecord?,
        keyEdit: KeyEdit,
        keyField: String,
        keyEnteredForCanonicalURL: String?,
        currentCanonicalURL: String,
        settingsStagedChange: SettingsStore.KeyDraftChange? = nil,
        committedBaseURL: String? = nil,
        currentProvider: String? = nil, committedProvider: String? = nil,
        currentCredentialIdentity: String? = nil, committedCredentialIdentity: String? = nil
    ) -> SettingsStore.KeyDraftChange? {
        let typedApplies = typedKeyApplies(
            keyEdit: keyEdit, keyEnteredForCanonicalURL: keyEnteredForCanonicalURL, canonicalURL: currentCredentialIdentity ?? currentCanonicalURL)
        if existing == nil {
            return typedApplies && !keyField.isEmpty ? .set(keyField) : nil
        }
        // The endpoint rule references the COMMITTED endpoint (falling
        // back to the record shown when none is saved), so restoring the
        // committed URL in a later sheet session automatically cancels an
        // endpoint-driven clear while preserving explicit Delete.
        let reference = committedBaseURL ?? existing!.baseURL
        let urlChanged = currentCredentialIdentity.map { $0 != (committedCredentialIdentity ?? existing!.credentialIdentity) }
            ?? (reference != currentCanonicalURL || (committedProvider ?? existing!.provider) != (currentProvider ?? existing!.provider))
        let base: SettingsStore.KeyDraftChange?
        switch settingsStagedChange {
        case .set where currentCredentialIdentity.map({ $0 == existing!.credentialIdentity })
            ?? (existing!.baseURL == currentCanonicalURL && existing!.provider == (currentProvider ?? existing!.provider)):
            // The previous sheet entered this replacement for the current
            // draft endpoint. A rename or reopen must preserve it.
            base = settingsStagedChange
        case .delete:
            base = .delete // explicit user intent survives URL restoration
        default:
            base = urlChanged ? .clearForEndpointChange : nil
        }
        switch keyEdit {
        case .replace:
            if typedApplies { return keyField.isEmpty ? base : .set(keyField) }
            return base
        case .delete: return .delete
        case .restore: return urlChanged ? .clearForEndpointChange : nil
        case .inherit: return base
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t(existing == nil ? "Add model configuration" : "Edit model configuration")).font(.headline)
            Form {
                Section {
                    TextField(t("Name"), text: $displayName)
                        .accessibilityIdentifier("settings.model.name")
                    Picker(t("Protocol"), selection: $provider) {
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                    }.accessibilityIdentifier("settings.model.protocol")
                    TextField(t("Model ID"), text: $modelID).accessibilityIdentifier("settings.model.id")
                    effortPicker
                    TextField(t("API Base URL"), text: $baseURL).accessibilityIdentifier("settings.model.url")
                    keyRow
                }
            }.formStyle(.grouped)
            .onChange(of: provider) { old, _ in
                profile = api.profile
                if old == "openai" && options.authentication == .bearer { options.authentication = .apiKey }
                else if old == "anthropic" && options.authentication == .apiKey { options.authentication = .bearer }
            }
            if let error {
                Text(t(error)).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.model.sheet.error")
            }
            HStack {
                if existing != nil {
                    Button(t("Delete"), role: .destructive) { onConfirm(.remove(existing!.id)) }
                        .accessibilityIdentifier("settings.model.delete")
                }
                Spacer()
                Button(t("Cancel"), action: onCancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("settings.model.cancel")
                Button(t(existing == nil ? "Add" : "Apply")) { confirm() }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("settings.model.confirm")
            }
        }
        .padding(20).frame(width: 500, height: 440)
    }

    private var effortPicker: some View {
        Picker(t("Reasoning Effort"), selection: $effort) {
            if !ModelEffort.editable.contains(effort) {
                Text(t("Choose an effort level")).tag(effort)
            }
            ForEach(ModelEffort.editable, id: \.self) { value in Text(value.label(t)).tag(value) }
        }.accessibilityIdentifier("settings.model.effort")
    }

    /// The typed-key binding: each keystroke (re)binds the key to the
    /// canonical endpoint current at entry time.
    private var keyFieldBinding: Binding<String> {
        Binding(
            get: { keyField },
            set: { value in
                keyField = value
                keyEnteredForCanonicalURL = credentialIdentity
                keyEdit = ConfigurationSheet.transitionedKeyEdit(onTyping: keyEdit)
            })
    }

    private func resetCredentialEntry(_ edit: KeyEdit) {
        keyEdit = edit
        keyField = ""
        keyEnteredForCanonicalURL = nil
    }

    @ViewBuilder private var keyRow: some View {
        if existing == nil {
            // A new entry: entering a key is optional; a missing key is a
            // valid saved configuration that blocks model dispatch. The
            // typed key applies only to the canonical URL shown at entry.
            if keyEdit == .replace, keyEnteredForCanonicalURL != nil, !typedKeyApplies {
                // The URL changed after the key was typed: the key stays
                // bound to its entry-time endpoint and will not be saved.
                // Mirrors the edit-mode note (D1) instead of silently
                // dropping the field's visible text on confirm.
                Text(t("Typed key ignored — it was entered for another endpoint.")).font(.callout).foregroundStyle(.secondary)
                Button(t("Enter key")) { resetCredentialEntry(.replace) }
            } else {
                SecureField(t("API key (optional)"), text: keyFieldBinding).accessibilityIdentifier("settings.model.key.field")
            }
        } else {
            let stagedSettings = stagedKeyChange
            let stagedSet = hasStagedReplacement
            let committed = keychain.hasKey(configurationID: existing!.id) || stagedSet
            HStack {
                if keyEdit == .inherit, store.keyDrafts[existing!.id] != nil,
                   stagedSettings == .delete || stagedSettings == .clearForEndpointChange {
                    // A deletion the Settings draft already stages; cancel
                    // is local to this sheet and applies on confirmation.
                    Text(t("Key will be deleted")).foregroundStyle(.secondary)
                    Button(t("Cancel changes")) { keyEdit = .restore }.accessibilityIdentifier("settings.model.key.cancel")
                } else if keyEdit == .restore {
                    if urlChanged {
                        Text(t("Key cleared — enter the key for the new URL")).font(.callout).foregroundStyle(.secondary)
                        Button(t("Enter key")) { resetCredentialEntry(.replace) }
                    } else {
                        // The staged deletion is cancelled locally; the
                        // committed key remains until Save decides.
                        Text(t("API key set")).foregroundStyle(.secondary)
                        Button(t("Replace")) { resetCredentialEntry(.replace) }.accessibilityIdentifier("settings.model.key.replace")
                        Button(t("Delete")) { keyEdit = .delete }.accessibilityIdentifier("settings.model.key.delete")
                    }
                } else if keyEdit == .replace {
                    if typedKeyApplies || keyEnteredForCanonicalURL == nil {
                        // Fresh Replace (no key typed yet) or a key typed at
                        // exactly this endpoint: the field is live, and the
                        // first keystroke binds the key to this canonical URL.
                        SecureField(t("API key"), text: keyFieldBinding).accessibilityIdentifier("settings.model.key.field")
                        Button(t("Cancel changes")) { resetCredentialEntry(.inherit) }
                    } else if !urlChanged {
                        // The URL is back at the committed endpoint: the
                        // committed key state applies and the typed key
                        // (entered for a different endpoint) is ignored.
                        Text(t("Typed key ignored — it was entered for another endpoint.")).font(.callout).foregroundStyle(.secondary)
                        Button(t("Cancel changes")) { resetCredentialEntry(.inherit) }
                    } else {
                        // The typed key belonged to a different endpoint.
                        Text(t("Key cleared — enter the key for the new URL")).font(.callout).foregroundStyle(.secondary)
                        Button(t("Enter key")) { resetCredentialEntry(.replace) }
                    }
                } else if keyEdit == .delete {
                    Text(t("Key will be deleted")).foregroundStyle(.secondary)
                    Button(t("Cancel changes")) { keyEdit = .inherit }
                } else if urlChanged && !stagedSet {
                    Text(t("Key cleared — enter the key for the new URL")).font(.callout).foregroundStyle(.secondary)
                    Button(t("Enter key")) { resetCredentialEntry(.replace) }
                } else if committed {
                    Text(t("API key set")).foregroundStyle(.secondary)
                    Button(t("Replace")) { resetCredentialEntry(.replace) }.accessibilityIdentifier("settings.model.key.replace")
                    Button(t("Delete")) { keyEdit = .delete }.accessibilityIdentifier("settings.model.key.delete")
                } else {
                    Text(t("No API key")).foregroundStyle(.secondary)
                    Button(t("Enter key")) { resetCredentialEntry(.replace) }
                }
            }
        }
    }

    private func confirm() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty,
              modelID == modelID.trimmingCharacters(in: .whitespacesAndNewlines),
              modelID.utf8.count <= 256, !modelID.contains("\n"), !modelID.contains("\r") else {
            error = "Enter the actual model ID (trimmed, at most 256 UTF-8 bytes)."; return
        }
        guard trimmedName.unicodeScalars.count <= 128, !trimmedName.contains("\n"), !trimmedName.contains("\r") else {
            error = "The display name must be a single line of at most 128 characters."; return
        }
        guard case .success(let canonical) = CanonicalBaseURL.canonicalize(baseURL) else {
            error = "Enter a complete HTTPS API Base URL (for example https://api.openai.com/v1/) without an operation path such as /chat/completions."; return
        }
        guard ModelEffort.editable.contains(effort) else { error = "Choose an effort level"; return }
        do {
            if let endpoint = options.endpointURL {
                guard case .success(let value) = CanonicalBaseURL.canonicalize(endpoint, operationURL: true) else {
                    error = "Enter a valid HTTPS request URL."; return
                }
                options.endpointURL = value
            }
            try options.validate(protocol: api)
            if keyEdit == .replace {
                guard options.authentication == .none || keyField.utf8.allSatisfy({ (32...126).contains($0) }) else {
                    error = "Check the API key for invalid characters."; return
                }
                guard keyField.utf8.count <= 4096 else {
                    error = "Credentials must be at most 4096 bytes."; return
                }
            }
        } catch { self.error = "The saved request options are incompatible with this protocol. Choose the original protocol or add a new configuration."; return }
        var record = ModelConfigurationRecord(
            id: existing?.id ?? UUID(), displayName: trimmedName.isEmpty ? nil : trimmedName,
            provider: provider, profile: api.profile, modelID: modelID, effort: effort,
            baseURL: canonical,
            vendorLabel: existing?.vendorLabel ?? (existing?.requestOptions == nil ? existing?.vendorName : nil),
            requestOptions: options, revision: UUID())
        if let committedConfiguration, record.hasSameRequest(as: committedConfiguration) {
            record.revision = committedConfiguration.revision
        } else if let existing, record.hasSameRequest(as: existing) {
            record.revision = existing.revision
        }
        // The resolved display-name/effort pair must be unique within the
        // draft, compared after trimming with case-insensitive names.
        let nameKey = record.resolvedName.lowercased() + "\u{1F}" + record.effort.rawValue
        let collision = store.draft.modelConfigurations.contains { configuration in
            configuration.id != record.id
                && configuration.resolvedName.lowercased() + "\u{1F}" + configuration.effort.rawValue == nameKey
        }
        guard !collision else {
            error = "Two configurations share the same name and effort. Give one a different display name."; return
        }
        if let existing {
            // The sheet's final key decision is committed only on
            // confirmation; canceling the sheet leaves the Settings
            // draft's staged credential change untouched (N1). The Save
            // transaction independently enforces the endpoint rule.
            store.setKeyDraft(stagedKeyChange, configurationID: existing.id)
            onConfirm(.edit(record))
        } else {
            if let staged = stagedKeyChange { store.setKeyDraft(staged, configurationID: record.id) }
            onConfirm(.add(record))
        }
    }
}
