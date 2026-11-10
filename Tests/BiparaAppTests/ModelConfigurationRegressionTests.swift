import AppKit
@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing

/// Credential, editor and runtime-binding regressions driven through
/// the real owning paths: the configuration editor sheet state machine and
/// SettingsStore Save transaction, runtime binding/analysis, prompt-version
/// dispatch eligibility and URL validation parity with Worker/tests.
@MainActor
@Suite("Model configuration and reader regressions")
struct ModelConfigurationRegressionTests {
    private func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Records every credential-store call so regressions can assert that
    /// blocked states never reach the store.
    @MainActor final class AuditingCredentials: CredentialStore {
        var keys: [UUID: String] = [:]
        var legacy: [String: String] = [:]
        var reads: [(String, UUID?)] = []
        var writes: [(String, UUID?)] = []
        var legacyReads: [String] = []
        var legacyDeletes: [String] = []
        var nextError: NSError?
        func hasKey(configurationID: UUID) -> Bool { keys[configurationID] != nil }
        func credential(configurationID: UUID) throws -> String? {
            reads.append(("credential", configurationID))
            if let nextError { throw nextError }
            return keys[configurationID]
        }
        func setKey(_ key: String, configurationID: UUID) throws {
            writes.append(("set", configurationID))
            if let nextError { throw nextError }
            keys[configurationID] = key
        }
        func deleteKey(configurationID: UUID) throws {
            writes.append(("delete", configurationID))
            if let nextError { throw nextError }
            keys[configurationID] = nil
        }
        func legacyCredential(provider: String) throws -> String? {
            legacyReads.append(provider)
            if let nextError { throw nextError }
            return legacy[provider]
        }
        func deleteLegacyKey(provider: String) throws {
            legacyDeletes.append(provider)
            if let nextError { throw nextError }
            legacy[provider] = nil
        }
    }

    // MARK: - reopened editor cancel cannot retain a key at a changed endpoint

    /// Drives endpoint restoration through the sheet state machine: the
    /// staged changes are computed the way the sheet computes them at
    /// confirmation, and Cancel key / sheet cancellation are represented by
    /// discarding sheet-local state without touching the store.
    @Test func reopenedEditorCancelKeyThenSheetCancelCannotRetainOldKeyAtNewEndpoint() throws {
        let keychain = AuditingCredentials()
        let store = SettingsStore(defaults: freshDefaults(), keychain: keychain, record: LegacyModelFixture.record())
        let configuration = try #require(store.record.modelConfigurations.first { $0.provider == "openai" })
        try keychain.setKey("KA_SYNTHETIC", configurationID: configuration.id)

        // Edit 1: change endpoint A -> B, confirm the sheet.
        let b = "https://gateway.example.com/v1/"
        var edited = configuration
        edited.baseURL = b
        // The sheet computes its final staged key decision on confirmation:
        // with the URL changed and no replacement typed, that decision is
        // a deletion of the committed key.
        let sheetDecision = ConfigurationSheet.stagedKeyChange(
            existing: configuration, keyEdit: .inherit, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: b)
        #expect(sheetDecision == .clearForEndpointChange)
        store.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == configuration.id }) else { return }
            draft.modelConfigurations[i] = edited
        }
        store.setKeyDraft(sheetDecision, configurationID: configuration.id)

        // Edit 2 uses the committed A reference, as the real view does.
        // Cancel key changes only sheet-local intent; Cancel sheet drops it.
        let localCancelDecision = ConfigurationSheet.stagedKeyChange(
            existing: edited, keyEdit: .restore, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: b,
            settingsStagedChange: store.keyDrafts[configuration.id],
            committedBaseURL: configuration.baseURL)
        #expect(localCancelDecision == .clearForEndpointChange)
        #expect(store.keyDrafts[configuration.id] == sheetDecision)

        // Settings Save: B is committed and KA is gone — the old key can
        // never resolve for the new endpoint.
        try store.saveDraft()
        #expect(store.record.configuration(id: configuration.id)?.baseURL == b)
        #expect(try keychain.credential(configurationID: configuration.id) == nil)
        #expect(throws: SettingsStore.SettingsError.missingCredential) {
            _ = try store.resolveCredential(RuntimeModelBinding(configurationID: configuration.id, baseURL: b, provider: "openai"))
        }
        // And KA never became usable at B under any spelling.
        #expect(!keychain.keys.values.contains("KA_SYNTHETIC"))
    }

    /// Endpoint restoration through the store transaction: even a caller
    /// that clears the staged deletion entirely cannot make Save retain
    /// KA at endpoint B — the transaction enforces the rule itself.
    @Test func saveTransactionEnforcesEndpointCredentialRuleEvenWithoutStagedDelete() throws {
        let keychain = AuditingCredentials()
        let store = SettingsStore(defaults: freshDefaults(), keychain: keychain, record: LegacyModelFixture.record())
        let configuration = try #require(store.record.modelConfigurations.first { $0.provider == "openai" })
        try keychain.setKey("KA_SYNTHETIC", configurationID: configuration.id)
        store.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == configuration.id }) else { return }
            draft.modelConfigurations[i].baseURL = "https://gateway.example.com/v1/"
        }
        // Simulate the old buggy "Cancel key" outcome: staged deletion gone.
        store.setKeyDraft(nil, configurationID: configuration.id)
        try store.saveDraft()
        #expect(try keychain.credential(configurationID: configuration.id) == nil)
        // A -> B -> A restoration before Save restores the original state.
        let glm = try #require(store.record.modelConfigurations.first { $0.provider == "glm" })
        try keychain.setKey("KG_SYNTHETIC", configurationID: glm.id)
        store.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == glm.id }) else { return }
            draft.modelConfigurations[i].baseURL = "https://alt.example.com/v1/"
        }
        store.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == glm.id }) else { return }
            draft.modelConfigurations[i].baseURL = WorkerContract.glmStandardBaseURL
        }
        try store.saveDraft()
        #expect(try keychain.credential(configurationID: glm.id) == "KG_SYNTHETIC")
        // An explicit replacement typed at the new endpoint wins.
        store.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == glm.id }) else { return }
            draft.modelConfigurations[i].baseURL = "https://rotated.example.com/v1/"
        }
        store.setKeyDraft(.set("NEW_ENDPOINT_KEY"), configurationID: glm.id)
        try store.saveDraft()
        #expect(try keychain.credential(configurationID: glm.id) == "NEW_ENDPOINT_KEY")
    }


    // MARK: - Two-session endpoint restoration

    @Test func twoSessionEndpointRestoreRecoversKeyStateWithExplicitCancel() throws {
        let keychain = AuditingCredentials()
        let store = SettingsStore(defaults: freshDefaults(), keychain: keychain, record: LegacyModelFixture.record())
        let configuration = try #require(store.record.modelConfigurations.first { $0.provider == "openai" })
        try keychain.setKey("KA_SYNTHETIC", configurationID: configuration.id)
        let a = configuration.baseURL
        let b = "https://gateway.example.com/v1/"

        // Sheet 1: A -> B, confirmed. The draft record now shows B and the
        // Settings draft stages the automatic deletion.
        let sheet1 = ConfigurationSheet.stagedKeyChange(
            existing: configuration, keyEdit: .inherit, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: b)
        #expect(sheet1 == .clearForEndpointChange)
        var draftB = configuration
        draftB.baseURL = b
        store.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == configuration.id }) else { return }
            draft.modelConfigurations[i] = draftB
        }
        store.setKeyDraft(sheet1, configurationID: configuration.id)

        // Sheet 2 (reopened, existing = the DRAFT record at B): restoring
        // the committed URL A and clicking Cancel key (restore) must clear
        // the staged deletion — the committed reference is A, not B.
        let committedReference = store.record.configuration(id: configuration.id)?.baseURL
        let restoreDecision = ConfigurationSheet.stagedKeyChange(
            existing: draftB, keyEdit: .restore, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: a,
            settingsStagedChange: store.keyDrafts[configuration.id],
            committedBaseURL: committedReference)
        #expect(restoreDecision == nil)
        store.setKeyDraft(restoreDecision, configurationID: configuration.id)
        store.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == configuration.id }) else { return }
            draft.modelConfigurations[i].baseURL = a
        }

        try store.saveDraft()
        // The original key state survived the A -> B -> A round trip.
        #expect(try keychain.credential(configurationID: configuration.id) == "KA_SYNTHETIC")
        #expect(try store.resolveCredential(RuntimeModelBinding(configurationID: configuration.id, baseURL: a, provider: "openai")) == "KA_SYNTHETIC")
    }

    @Test func reopenedEndpointReplacementSurvivesUnrelatedEdit() throws {
        let keys = AuditingCredentials()
        let store = SettingsStore(defaults: freshDefaults(), keychain: keys, record: LegacyModelFixture.record())
        let original = try #require(store.record.defaultConfiguration)
        keys.keys[original.id] = "SYNTHETIC_KEY_A"
        let b = "https://gateway.example.com/v1/"
        var edited = original
        edited.baseURL = b
        let replacement = ConfigurationSheet.stagedKeyChange(
            existing: original, keyEdit: .replace, keyField: "SYNTHETIC_KEY_B",
            keyEnteredForCanonicalURL: b, currentCanonicalURL: b,
            committedBaseURL: original.baseURL)
        store.setKeyDraft(replacement, configurationID: original.id)
        store.updateDraft { $0.modelConfigurations[0] = edited }
        // Reopening and confirming a rename inherits the key entered for B.
        let inherited = ConfigurationSheet.stagedKeyChange(
            existing: edited, keyEdit: .inherit, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: b,
            settingsStagedChange: store.keyDrafts[original.id], committedBaseURL: original.baseURL)
        #expect(inherited == .set("SYNTHETIC_KEY_B"))
        store.setKeyDraft(inherited, configurationID: original.id)
        store.updateDraft { $0.modelConfigurations[0].displayName = "Renamed" }
        try store.saveDraft()
        #expect(try store.resolveCredential(.init(configurationID: original.id, baseURL: b, provider: original.provider)) == "SYNTHETIC_KEY_B")
    }

    @Test func endpointRestoreWithoutKeyActionRestoresCommittedKey() throws {
        let keys = AuditingCredentials()
        let store = SettingsStore(defaults: freshDefaults(), keychain: keys, record: LegacyModelFixture.record())
        let original = try #require(store.record.defaultConfiguration)
        keys.keys[original.id] = "SYNTHETIC_KEY_A"
        var edited = original
        edited.baseURL = "https://gateway.example.com/v1/"
        let cleared = ConfigurationSheet.stagedKeyChange(
            existing: original, keyEdit: .inherit, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: edited.baseURL,
            committedBaseURL: original.baseURL)
        store.setKeyDraft(cleared, configurationID: original.id)
        store.updateDraft { $0.modelConfigurations[0] = edited }
        // A second sheet restores A without any explicit key action.
        let restored = ConfigurationSheet.stagedKeyChange(
            existing: edited, keyEdit: .inherit, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: original.baseURL,
            settingsStagedChange: store.keyDrafts[original.id], committedBaseURL: original.baseURL)
        #expect(restored == nil)
        store.setKeyDraft(restored, configurationID: original.id)
        store.updateDraft { $0.modelConfigurations[0] = original }
        try store.saveDraft()
        #expect(try store.resolveCredential(.init(configurationID: original.id, baseURL: original.baseURL, provider: original.provider)) == "SYNTHETIC_KEY_A")
    }

    @Test func explicitKeyIntentAndEndpointInvalidationSurviveReopening() throws {
        let a = "https://api.openai.com/v1/", b = "https://gateway.example.com/v1/"
        let original = ModelConfigurationRecord(provider: "openai", profile: ModelProfileID.openaiV2,
            modelID: "gpt-6-luna", effort: .low, baseURL: a)
        var edited = original
        edited.baseURL = b
        // Explicit Delete is never automatically undone by restoring A.
        #expect(ConfigurationSheet.stagedKeyChange(existing: edited, keyEdit: .inherit,
            keyField: "", keyEnteredForCanonicalURL: nil, currentCanonicalURL: a,
            settingsStagedChange: .delete, committedBaseURL: a) == .delete)
        // A pending replacement for B cannot be inherited at C, or at A.
        for endpoint in [a, "https://other.example.com/v1/"] {
            let change = ConfigurationSheet.stagedKeyChange(existing: edited, keyEdit: .inherit,
                keyField: "", keyEnteredForCanonicalURL: nil, currentCanonicalURL: endpoint,
                settingsStagedChange: .set("SYNTHETIC_KEY_B"), committedBaseURL: a)
            #expect(change != .set("SYNTHETIC_KEY_B"))
        }
        // An explicit replacement at A remains on a rename at A.
        #expect(ConfigurationSheet.stagedKeyChange(existing: original, keyEdit: .inherit,
            keyField: "", keyEnteredForCanonicalURL: nil, currentCanonicalURL: a,
            settingsStagedChange: .set("SYNTHETIC_REPLACEMENT_A"), committedBaseURL: a) == .set("SYNTHETIC_REPLACEMENT_A"))
        // The transaction itself ignores an obsolete automatic clear at A.
        let keys = AuditingCredentials()
        keys.keys[original.id] = "SYNTHETIC_ORIGINAL"
        let store = SettingsStore(defaults: freshDefaults(), keychain: keys,
            record: PreferencesRecord(modelConfigurations: [original], defaultModelConfigurationID: original.id))
        store.setKeyDraft(.clearForEndpointChange, configurationID: original.id)
        try store.saveDraft()
        #expect(keys.keys[original.id] == "SYNTHETIC_ORIGINAL")
        store.setKeyDraft(.delete, configurationID: original.id)
        try store.saveDraft()
        #expect(keys.keys[original.id] == nil)
    }

    // MARK: - present v2 value of the wrong storage type blocks

    @Test func presentNonDataStringAndNumberV2ValuesBlock() throws {
        for value in ["not-json-string", 42, true] {
            let defaults = freshDefaults()
            defaults.set(value, forKey: SettingsStore.defaultsKey)
            let keychain = AuditingCredentials()
            keychain.legacy = ["openai": "LEGACY_KEY", "glm": "LEGACY_KEY"]
            let store = SettingsStore(defaults: defaults, keychain: keychain)
            #expect(store.loadFailure?.kind == .corruptOrNewerRecord)
            // The original object is preserved untouched.
            #expect(defaults.object(forKey: SettingsStore.defaultsKey) != nil)
            // No migration or credential activity occurred.
            #expect(keychain.legacyReads.isEmpty)
            #expect(keychain.writes.isEmpty)
            // An unrelated edit cannot bypass the failure.
            store.updateDraft { $0.appearance = .dark }
            #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
            #expect(keychain.writes.isEmpty)
            // The stored object is still the original wrong-typed value.
            let persisted = try #require(defaults.object(forKey: SettingsStore.defaultsKey))
            #expect(!(persisted is Data))
            if let string = value as? String {
                #expect(defaults.string(forKey: SettingsStore.defaultsKey) == string)
            }
        }
    }

    @Test func presentDictionaryV2ValueBlocksAndPreservesDictionary() throws {
        let defaults = freshDefaults()
        let wrong: [String: Any] = ["schemaVersion": 2, "unexpected": true]
        defaults.set(wrong, forKey: SettingsStore.defaultsKey)
        let store = SettingsStore(defaults: defaults, keychain: AuditingCredentials())
        #expect(store.loadFailure != nil)
        let persisted = try #require(defaults.dictionary(forKey: SettingsStore.defaultsKey))
        #expect(persisted["unexpected"] as? Bool == true)
    }

    @Test func absentV2StillMigratesAndFreshInstallStillSeeds() throws {
        // Absence (nil object) is still absence: v1 migrates.
        let migrating = freshDefaults()
        let legacy: [String: Any] = [
            "schemaVersion": 1, "interfaceLanguage": "en", "appearance": "system",
            "typography": ["family": "system", "size": 17, "lineHeight": "1.70"],
            "defaultProvider": "openai",
            "providers": ["openai": ["model": "kept-model"], "glm": ["model": "glm-4.7-flash"]],
        ]
        migrating.set(try! JSONSerialization.data(withJSONObject: legacy), forKey: SettingsStore.legacyDefaultsKey)
        let migrated = SettingsStore(defaults: migrating, keychain: AuditingCredentials())
        #expect(migrated.loadFailure == nil)
        #expect(migrated.record.modelConfigurations.contains { $0.modelID == "kept-model" })
        // Fresh install seeds.
        let fresh = SettingsStore(defaults: freshDefaults(), keychain: AuditingCredentials())
        #expect(fresh.loadFailure == nil)
        #expect(fresh.record.modelConfigurations.count == 2)
    }

    // MARK: - typing in the Add key field stages the key

    /// Simulates the real typing path: the SecureField binding drives both
    /// the text and the editor state, exactly as the view wires it.
    @Test func typingInAddSecureFieldStagesKeyThroughRealBindingPath() throws {
        let keychain = AuditingCredentials()
        let store = SettingsStore(defaults: freshDefaults(), keychain: keychain, record: LegacyModelFixture.record())
        // Mirror of the sheet's local state driven by keyFieldBinding.
        var keyField = ""
        var keyEdit: ConfigurationSheet.KeyEdit = .inherit
        var keyEnteredForCanonicalURL: String?
        let a = WorkerContract.openAIStandardBaseURL
        let b = "https://gateway.example.com/v1/"
        func typeKey(_ value: String, at canonical: String) {
            keyField = value
            keyEnteredForCanonicalURL = canonical
            keyEdit = ConfigurationSheet.transitionedKeyEdit(onTyping: keyEdit) // the binding's shared transition
        }
        func staged(existing: ModelConfigurationRecord?, canonical: String) -> SettingsStore.KeyDraftChange? {
            ConfigurationSheet.stagedKeyChange(
                existing: existing, keyEdit: keyEdit, keyField: keyField,
                keyEnteredForCanonicalURL: keyEnteredForCanonicalURL, currentCanonicalURL: canonical)
        }
        // Pre-fix behavior: typing left keyEdit == .inherit and staged nil.
        typeKey("NEW_SYNTHETIC_KEY", at: a)
        #expect(keyEdit == .replace)
        #expect(staged(existing: nil, canonical: a) == .set("NEW_SYNTHETIC_KEY"))
        // Endpoint change invalidates the typed key.
        #expect(staged(existing: nil, canonical: b) == nil)
        // A -> B -> A re-applies it.
        #expect(staged(existing: nil, canonical: a) == .set("NEW_SYNTHETIC_KEY"))
        // Add confirmation stages only the Settings draft; Save commits.
        let added = ModelConfigurationRecord(
            displayName: "Typed key entry", provider: "openai", profile: ModelProfileID.openaiV2,
            modelID: "gpt-6-luna", effort: .low, baseURL: a)
        store.updateDraft { draft in
            draft.modelConfigurations.append(added)
            draft.defaultModelConfigurationID = added.id
        }
        if let stagedChange = staged(existing: nil, canonical: a) {
            store.setKeyDraft(stagedChange, configurationID: added.id)
        }
        try store.saveDraft()
        #expect(try keychain.credential(configurationID: added.id) == "NEW_SYNTHETIC_KEY")
        // Another configuration's key stays independent.
        let other = try #require(store.record.modelConfigurations.first { $0.id != added.id })
        #expect(try keychain.credential(configurationID: other.id) == nil)
        // Credential resolution works for the new configuration.
        #expect(try store.resolveCredential(RuntimeModelBinding(configurationID: added.id, baseURL: a, provider: "openai")) == "NEW_SYNTHETIC_KEY")
        // Settings cancellation before Save discards a typed key (fresh store).
        let cancelStore = SettingsStore(defaults: freshDefaults(), keychain: keychain, record: LegacyModelFixture.record())
        let draftEntry = ModelConfigurationRecord(
            provider: "glm", profile: ModelProfileID.glmV2, modelID: "glm-5.3", effort: .low,
            baseURL: WorkerContract.glmStandardBaseURL)
        cancelStore.updateDraft { $0.modelConfigurations = [draftEntry]; $0.defaultModelConfigurationID = draftEntry.id }
        cancelStore.setKeyDraft(.set("DISCARDED_KEY"), configurationID: draftEntry.id)
        cancelStore.cancelDraft()
        #expect(cancelStore.keyDrafts.isEmpty)
        // A deliberately blank key stays blank and valid.
        keyField = ""
        #expect(staged(existing: nil, canonical: a) == nil)
    }

    // MARK: - binding confirmation revalidates the presented candidate

    private func appWithOpenedPausedDocument(gateway: ScriptedGateway) throws -> (AppRuntime, AuditingCredentials, UserDefaults, UUID, ModelConfigurationRecord) {
        let keychain = AuditingCredentials()
        let defaults = UserDefaults(suiteName: "dev.bipara.test.\(UUID())")!
        LegacyModelFixture.install(defaults)
        let app = AppRuntime(gateway: gateway, keychain: keychain, defaults: defaults)
        let match = try #require(app.settings.record.defaultConfiguration)
        try app.workspace.newTab(source: String(repeating: "Hello there. ", count: 40), direction: .enToZh)
        let session = app.workspace.tabs[0].sessionID
        let document = app.workspace.tabs[0].document
        let snapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: document.sourceRevision,
            sourceLanguage: .en, targetLanguage: .zh,
            provider: match.provider, model: match.modelID, profile: match.profile,
            effort: match.effort,
            translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1")
        app.workspace.withTab(0) {
            $0.document.jobSnapshot = snapshot
            $0.document.resolvedDirection = .enToZh
            $0.document.translations = document.units.prefix(1).map {
                .init(unitID: $0.id, text: "已保存译文", returnedModel: nil, completedAt: Date())
            }
            $0.job.snapshot = snapshot
            $0.job.completedUnitIDs = Set(document.units.prefix(1).map(\.id))
            $0.job.totalNonblankUnits = document.units.count
            $0.job.state = .paused
            $0.savedContentGeneration = $0.contentGeneration
        }
        return (app, keychain, defaults, session, match)
    }

    @Test func staleBindingCandidateRequiresRefreshedConfirmation() async throws {
        let gateway = ScriptedGateway()
        let (app, keychain, defaults, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
        keychain.keys[match.id] = "MATCH_KEY"
        defaults.set(true, forKey: "dev.bipara.disclosure.\(match.provider)|https://api.openai.com")

        // Present the binding sheet (no runtime binding yet).
        await app.translate(session)
        let request = try #require(app.bindingRequest)
        #expect(request.purpose == .resume)
        // While pending, the user saves the candidate with a different endpoint.
        app.settings.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == match.id }) else { return }
            draft.modelConfigurations[i].baseURL = "https://drifted.example.com/v1/"
        }
        try app.settings.saveDraft()
        // Confirming the OLD sheet must not bind the drifted endpoint.
        app.bindAndResume(request, configurationID: match.id)
        #expect(gateway.dispatchCount == 0)
        #expect(app.workspace.tabs[0].runtimeBinding == nil)
        // A refreshed sheet is presented instead, from current state.
        let refreshed = try #require(app.bindingRequest)
        #expect(refreshed.matches.first?.baseURL == "https://drifted.example.com/v1/")
        // Explicitly confirming the refreshed candidate binds the drifted
        // endpoint only after that fresh confirmation.
        keychain.keys[match.id] = "DRIFT_KEY"
        defaults.set(true, forKey: "dev.bipara.disclosure.openai|https://drifted.example.com")
        app.bindAndResume(refreshed, configurationID: match.id)
        try await appWaitUntil { app.workspace.tabs[0].runtimeBinding != nil }
        #expect(app.workspace.tabs[0].runtimeBinding?.baseURL == "https://drifted.example.com/v1/")
        _ = try await appWaitUntilAsync { app.workspace.tabs[0].job.state == .completed || app.workspace.tabs[0].job.state == .failed }
        if app.workspace.tabs[0].job.state == .completed {
            #expect(gateway.configurations.allSatisfy { $0.baseURL == "https://drifted.example.com/v1/" })
        }
    }

    @Test func deletedAndRecreatedSameNameCandidateDoesNotInheritAuthorization() async throws {
        let gateway = ScriptedGateway()
        let (app, keychain, defaults, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
        keychain.keys[match.id] = "MATCH_KEY"
        defaults.set(true, forKey: "dev.bipara.disclosure.\(match.provider)|https://api.openai.com")
        await app.translate(session)
        let request = try #require(app.bindingRequest)
        // Delete the candidate and recreate a same-named entry (new ID).
        let presentedName = match.resolvedName
        app.settings.updateDraft { draft in
            draft.modelConfigurations.removeAll { $0.id == match.id }
            draft.modelConfigurations.append(ModelConfigurationRecord(
                displayName: presentedName, provider: match.provider, profile: match.profile,
                modelID: match.modelID, effort: match.effort, baseURL: match.baseURL))
            draft.defaultModelConfigurationID = draft.modelConfigurations.first?.id
        }
        try app.settings.saveDraft()
        app.bindAndResume(request, configurationID: match.id)
        #expect(gateway.dispatchCount == 0)
        #expect(app.workspace.tabs[0].runtimeBinding == nil)
        // The recreated entry is offered as a fresh candidate.
        let refreshed = try #require(app.bindingRequest)
        #expect(refreshed.matches.allSatisfy { $0.id != match.id })
        app.bindingRequest = nil
    }

    @Test func unchangedAnalysisCandidateStillBindsAndSnapshotMatchDriftRefreshes() async throws {
        let gateway = ScriptedGateway()
        let (app, keychain, defaults, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
        keychain.keys[match.id] = "MATCH_KEY"
        defaults.set(true, forKey: "dev.bipara.disclosure.\(match.provider)|https://api.openai.com")
        let document = app.workspace.tabs[0].document
        let unit = document.units[0]
        let selection = ReadingSelection(
            paragraphID: document.paragraphs[0].id, unitID: unit.id,
            side: .source, range: .init(location: 0, length: 3))
        // Analysis binding request for the unbound opened document.
        app.selected(selection, session: session)
        try await appWaitUntil { app.bindingRequest != nil }
        var request = try #require(app.bindingRequest)
        #expect(request.purpose == .analysis)
        // While pending, the candidate's endpoint is saved to a different
        // URL: the snapshot-matching fields still match, but the presented
        // endpoint no longer exists.
        app.settings.updateDraft { draft in
            guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == match.id }) else { return }
            draft.modelConfigurations[i].baseURL = "https://analysis-drift.example.com/v1/"
        }
        try app.settings.saveDraft()
        app.bindForAnalysis(request, configurationID: match.id)
        #expect(gateway.alignmentDispatchCount == 0)
        // A refreshed analysis request appears from current state.
        request = try #require(app.bindingRequest)
        #expect(request.purpose == .analysis)
        #expect(request.matches.first?.baseURL == "https://analysis-drift.example.com/v1/")
        keychain.keys[request.matches.first!.id] = "MATCH_KEY"
        defaults.set(true, forKey: "dev.bipara.disclosure.openai|https://analysis-drift.example.com")
        // An unchanged candidate confirms and dispatches under the frozen snapshot.
        app.bindForAnalysis(request, configurationID: request.matches.first!.id)
        try await appWaitUntil { gateway.alignmentDispatchCount == 1 }
        let used = try #require(gateway.alignConfigurations.first)
        #expect(used.model == document.jobSnapshot?.model)
        #expect(used.profile == document.jobSnapshot?.profile)
        #expect(used.effort == document.jobSnapshot?.effort)
        #expect(gateway.dispatchCount == 0) // analysis-only, no translation
    }

    @Test func analysisWithoutMatchingConfigurationOffersRecovery() async throws {
        for staleSheet in [false, true] {
            let gateway = ScriptedGateway()
            let (app, _, _, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
            let document = app.workspace.tabs[0].document
            let selection = ReadingSelection(paragraphID: document.paragraphs[0].id,
                unitID: document.units[0].id, side: .source, range: .init(location: 0, length: 3))
            var request: AppRuntime.BindingRequest?
            if staleSheet {
                app.selected(selection, session: session)
                try await appWaitUntil { app.bindingRequest != nil }
                request = app.bindingRequest
            }
            app.settings.removeConfigurationFromDraft(id: match.id,
                replacement: app.settings.record.modelConfigurations.first { $0.id != match.id }?.id)
            try app.settings.saveDraft()
            var offered = false
            app.alertHandler = { title, _, buttons in
                #expect(title == "No matching model configuration")
                #expect(buttons == ["Retranslate", "Settings…", "Cancel"])
                offered = true
                return 1 // Open Settings, with no model operation.
            }
            if let request { app.bindForAnalysis(request, configurationID: match.id) }
            else { app.selected(selection, session: session) }
            try await appWaitUntil { offered && app.settingsRequested }
            #expect(gateway.dispatchCount == 0)
            #expect(gateway.alignmentDispatchCount == 0)
            #expect(app.workspace.tabs[0].runtimeBinding == nil)
            #expect(app.workspace.tabs[0].document == document)
            #expect(!app.workspace.tabs[0].isDirty)
            #expect(app.bindingRequest == nil)
        }
    }

    @Test func analysisRecoveryRequiresExplicitRetranslateConfirmation() async throws {
        for action in ["cancel", "decline-retranslate", "retranslate"] {
            let gateway = ScriptedGateway()
            let (app, keys, defaults, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
            let replacement = try #require(app.settings.record.modelConfigurations.first { $0.id != match.id })
            keys.keys[replacement.id] = "SYNTHETIC_RECOVERY_KEY"
            defaults.set(true, forKey: "dev.bipara.disclosure.\(replacement.provider)|\(CanonicalBaseURL.origin(of: replacement.baseURL))")
            app.settings.removeConfigurationFromDraft(id: match.id, replacement: replacement.id)
            try app.settings.saveDraft()
            let original = app.workspace.tabs[0].document
            var offered = false, confirmed = false
            app.alertHandler = { title, _, _ in
                #expect(gateway.dispatchCount == 0)
                if title == "No matching model configuration" {
                    offered = true
                    return action == "cancel" ? 2 : 0
                }
                #expect(title == "Replace existing translations?")
                confirmed = true
                return action == "retranslate" ? 0 : 1
            }
            app.selected(ReadingSelection(paragraphID: original.paragraphs[0].id,
                unitID: original.units[0].id, side: .source, range: .init(location: 0, length: 3)), session: session)
            try await appWaitUntil { offered && (action == "cancel" || confirmed) }
            if action == "retranslate" {
                try await appWaitUntil { app.workspace.tabs[0].job.state == .completed }
                #expect(gateway.dispatchCount > 0)
                #expect(gateway.configurations.allSatisfy { $0.model == replacement.modelID && $0.baseURL == replacement.baseURL })
            } else {
                #expect(gateway.dispatchCount == 0)
                #expect(app.workspace.tabs[0].document == original)
                #expect(!app.workspace.tabs[0].isDirty)
            }
            #expect(gateway.alignmentDispatchCount == 0)
        }
    }

    // MARK: - consent suspends before credential resolution and dispatch

    /// Consent is driven through the real alert seam; the race is
    /// controlled by withholding the alert answer while the mutation
    /// happens, exactly at the consent suspension point.
    /// MainActor gate for scripted consent races: the alert handler marks
    /// itself shown, then parks (cancellation-safe) until the test
    /// releases it with a chosen answer. No busy-waiting on a cancelled
    /// task can starve the main actor.
    @MainActor final class AlertGate {
        var shown = false
        var released = false
        var answer = 0
    }

    @Test func consentSuspensionRevalidatesBeforeDispatch() async throws {
        // Baseline: unchanged Continue dispatches exactly once to the
        // frozen destination (acknowledgement preset).
        do {
            let gateway = ScriptedGateway()
            let (app, keychain, defaults, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
            keychain.keys[match.id] = "MATCH_KEY"
            defaults.set(true, forKey: "dev.bipara.disclosure.\(match.provider)|https://api.openai.com")
            app.workspace.withTab(0) { $0.runtimeBinding = RuntimeModelBinding(configurationID: match.id, baseURL: match.baseURL, provider: match.provider) }
            let document = app.workspace.tabs[0].document
            let unit = document.units[0]
            app.selected(ReadingSelection(
                paragraphID: document.paragraphs[0].id, unitID: unit.id,
                side: .source, range: .init(location: 0, length: 3)), session: session)
            try await appWaitUntil { gateway.alignmentDispatchCount == 1 }
            #expect(gateway.alignConfigurations.last?.baseURL == match.baseURL)
        }
        // Custom origin (no preset acknowledgement) so consent genuinely
        // suspends; mutate during the suspension, then Continue.
        for mutation in ["delete", "endpoint", "rotate"] {
            let gateway = ScriptedGateway()
            let (app, keychain, _, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
            let gateURL = "https://consent-gate.example.com/v1/"
            app.settings.updateDraft { draft in
                guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == match.id }) else { return }
                draft.modelConfigurations[i].baseURL = gateURL
            }
            try app.settings.saveDraft()
            keychain.keys[match.id] = "FIRST_KEY"
            app.workspace.withTab(0) { $0.runtimeBinding = RuntimeModelBinding(configurationID: match.id, baseURL: gateURL, provider: "openai") }
            let document = app.workspace.tabs[0].document
            let unit = document.units[0]
            let gate = AlertGate()
            app.alertHandler = { [weak gate] _, _, _ in
                guard let gate else { return 1 }
                gate.shown = true
                while !gate.released {
                    if Task.isCancelled { return 1 }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                return gate.answer
            }
            app.selected(ReadingSelection(
                paragraphID: document.paragraphs[0].id, unitID: unit.id,
                side: .source, range: .init(location: 0, length: 3)), session: session)
            // The consent alert is now pending.
            try await appWaitUntil { gate.shown }
            switch mutation {
            case "delete":
                app.settings.updateDraft { draft in
                    draft.modelConfigurations.removeAll { $0.id == match.id }
                    draft.defaultModelConfigurationID = draft.modelConfigurations.first?.id
                }
                try app.settings.saveDraft()
            case "endpoint":
                app.settings.updateDraft { draft in
                    guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == match.id }) else { return }
                    draft.modelConfigurations[i].baseURL = "https://moved.example.com/v1/"
                }
                try app.settings.saveDraft()
            default:
                keychain.keys[match.id] = "ROTATED_KEY"
            }
            gate.released = true // Continue
            if mutation == "rotate" {
                try await appWaitUntil { gateway.alignmentDispatchCount == 1 }
                #expect(gateway.alignConfigurations.last?.apiKey == "ROTATED_KEY")
                #expect(gateway.alignConfigurations.last?.baseURL == gateURL)
            } else {
                try await Task.sleep(for: .milliseconds(600))
                #expect(gateway.alignmentDispatchCount == 0)
            }
            app.alertHandler = nil
        }
    }

    @Test func consentCancellationAndSelectionChangeDuringConsentMakeZeroCalls() async throws {
        for mode in ["cancel", "selection-change"] {
            let gateway = ScriptedGateway()
            let (app, keychain, _, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
            keychain.keys[match.id] = "MATCH_KEY"
            let gateURL = "https://unacknowledged.example.com/v1/"
            app.settings.updateDraft { draft in
                guard let i = draft.modelConfigurations.firstIndex(where: { $0.id == match.id }) else { return }
                draft.modelConfigurations[i].baseURL = gateURL
            }
            try app.settings.saveDraft()
            app.workspace.withTab(0) { $0.runtimeBinding = RuntimeModelBinding(configurationID: match.id, baseURL: gateURL, provider: "openai") }
            let document = app.workspace.tabs[0].document
            let unit = document.units[0]
            let gate = AlertGate()
            gate.answer = 1 // Cancel
            app.alertHandler = { [weak gate] _, _, _ in
                guard let gate else { return 1 }
                gate.shown = true
                while !gate.released {
                    if Task.isCancelled { return 1 }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                return gate.answer
            }
            app.selected(ReadingSelection(
                paragraphID: document.paragraphs[0].id, unitID: unit.id,
                side: .source, range: .init(location: 0, length: 3)), session: session)
            try await appWaitUntil { gate.shown }
            if mode == "selection-change" {
                gate.answer = 0 // Continue, but the selection was replaced
                app.selected(ReadingSelection(
                    paragraphID: document.paragraphs[0].id, unitID: unit.id,
                    side: .source, range: .init(location: 4, length: 4)), session: session)
            }
            gate.released = true
            try await Task.sleep(for: .milliseconds(600))
            #expect(gateway.alignmentDispatchCount == 0)
            app.alertHandler = nil
        }
    }

    // MARK: - operation-specific prompt versions

    @Test func operationSpecificPromptVersionsGateResumeAndAnalysis() async throws {
        let combinations: [(String, String, Bool, Bool)] = [
            // (translation field, alignment field, resume allowed, analysis allowed)
            ("translation.v1", "alignment.v1", true, true),
            ("alignment.v1", "translation.v1", false, false),   // swapped
            ("translation.v1", "translation.v1", false, false),  // translation version in alignment field
            ("alignment.v1", "alignment.v1", false, true),       // alignment version in translation field; analysis field still valid
            ("translation.v0", "alignment.v1", false, true),     // retired translation version
            ("translation.v1", "alignment.v0", false, false),    // retired alignment version blocks Resume too
        ]
        for (translationVersion, alignmentVersion, resumeAllowed, analysisAllowed) in combinations {
            let gateway = ScriptedGateway()
            let (app, keychain, defaults, session, match) = try appWithOpenedPausedDocument(gateway: gateway)
            keychain.keys[match.id] = "MATCH_KEY"
            defaults.set(true, forKey: "dev.bipara.disclosure.\(match.provider)|https://api.openai.com")
            app.workspace.withTab(0) { tab in
                tab.document.jobSnapshot?.translationPromptVersion = translationVersion
                tab.document.jobSnapshot?.alignmentPromptVersion = alignmentVersion
                tab.job.snapshot = tab.document.jobSnapshot
                tab.runtimeBinding = RuntimeModelBinding(configurationID: match.id, baseURL: match.baseURL, provider: match.provider)
            }
            let translationsBefore = app.workspace.tabs[0].document.translations
            // Resume path.
            await app.translate(session)
            if resumeAllowed {
                _ = try await appWaitUntilAsync { app.workspace.tabs[0].job.state == .completed || app.workspace.tabs[0].job.state == .failed }
                #expect(gateway.dispatchCount > 0)
            } else {
                #expect(gateway.dispatchCount == 0)
                #expect(app.workspace.tabs[0].document.translations == translationsBefore)
                #expect(app.workspace.tabs[0].document.jobSnapshot?.translationPromptVersion == translationVersion)
                #expect(app.errorMessage != nil)
                app.errorMessage = nil
            }
            // Analysis path (fresh runtime to keep counts clean).
            let analysisGateway = ScriptedGateway()
            let keychain2 = AuditingCredentials()
            let defaults2 = UserDefaults(suiteName: "dev.bipara.test.\(UUID())")!
            LegacyModelFixture.install(defaults2)
            let analysisApp = AppRuntime(gateway: analysisGateway, keychain: keychain2, defaults: defaults2)
            let analysisMatch = try #require(analysisApp.settings.record.defaultConfiguration)
            keychain2.keys[analysisMatch.id] = "MATCH_KEY"
            defaults2.set(true, forKey: "dev.bipara.disclosure.\(analysisMatch.provider)|https://api.openai.com")
            try analysisApp.workspace.newTab(source: "The window is open.", direction: .enToZh)
            let document = analysisApp.workspace.tabs[0].document
            analysisApp.workspace.withTab(0) {
                $0.document.jobSnapshot = JobSnapshot(
                    jobID: UUID(), sourceRevision: document.sourceRevision,
                    sourceLanguage: .en, targetLanguage: .zh,
                    provider: analysisMatch.provider, model: analysisMatch.modelID,
                    profile: analysisMatch.profile, effort: analysisMatch.effort,
                    translationPromptVersion: translationVersion,
                    alignmentPromptVersion: alignmentVersion)
                $0.document.resolvedDirection = .enToZh
                $0.document.translations = document.units.map {
                    .init(unitID: $0.id, text: "译文", returnedModel: nil, completedAt: Date())
                }
                $0.job.snapshot = $0.document.jobSnapshot
                $0.job.state = .completed
                $0.savedContentGeneration = $0.contentGeneration
                $0.runtimeBinding = RuntimeModelBinding(configurationID: analysisMatch.id, baseURL: analysisMatch.baseURL, provider: "openai")
            }
            let analysisUnit = document.units[0]
            analysisApp.selected(ReadingSelection(
                paragraphID: document.paragraphs[0].id, unitID: analysisUnit.id,
                side: .source, range: .init(location: 0, length: 3)), session: analysisApp.workspace.tabs[0].sessionID)
            try await Task.sleep(for: .milliseconds(700))
            if analysisAllowed {
                #expect(analysisGateway.alignmentDispatchCount == 1)
            } else {
                #expect(analysisGateway.alignmentDispatchCount == 0)
            }
        }
    }

    // MARK: - trailing-slash suffix, empty query/fragment, port parity

    @Test func operationSuffixTrailingSlashesRejected() {
        for suffix in ["/chat/completions", "/responses", "/messages"] {
            for trailing in ["", "/", "//", "///"] {
                let raw = "https://api.example.com/v1\(suffix)\(trailing)"
                #expect(
                    CanonicalBaseURL.canonicalize(raw) == .failure(.operationSuffix),
                    "expected rejection: \(raw)")
            }
        }
    }

    @Test func emptyAndNonEmptyQueryOrFragmentRejected() {
        for raw in [
            "https://api.example.com/v1/?", "https://api.example.com/v1/#",
            "https://api.example.com/v1/?x=1", "https://api.example.com/v1/#f",
            "https://api.example.com/v1/?#",
        ] {
            #expect(
                CanonicalBaseURL.canonicalize(raw) == .failure(.queryOrFragmentNotAllowed),
                "expected rejection: \(raw)")
        }
    }

    @Test func portRangeValidation() {
        #expect(CanonicalBaseURL.canonicalize("https://api.example.com:65536/v1/") == .failure(.malformed))
        #expect(CanonicalBaseURL.canonicalize("https://api.example.com:0/v1/") == .failure(.malformed))
        #expect(CanonicalBaseURL.canonicalize("https://api.example.com:abc/v1/") == .failure(.malformed))
        #expect(CanonicalBaseURL.canonicalize("https://api.example.com:65535/v1/") == .success("https://api.example.com:65535/v1/"))
        #expect(CanonicalBaseURL.canonicalize("https://api.example.com:8443/v1/") == .success("https://api.example.com:8443/v1/"))
        #expect(CanonicalBaseURL.canonicalize("https://api.example.com:443/v1") == .success("https://api.example.com/v1/"))
    }

    @Test func encodedPathAndInteriorSegmentsPreserved() {
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com/team%2Fname/v1") == .success("https://gateway.example.com/team%2Fname/v1/"))
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com/a%20b/q%3Fs/v1/") == .success("https://gateway.example.com/a%20b/q%3Fs/v1/"))
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com//a//v1//") == .success("https://gateway.example.com//a//v1/"))
    }
}

/// Async variant of the app barrier used by the consent-race tests.
@MainActor
func appWaitUntilAsync(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while await !condition() {
        if ContinuousClock.now >= deadline { throw NSError(domain: "app barrier timeout", code: 1) }
        try await Task.sleep(for: .milliseconds(5))
    }
}
