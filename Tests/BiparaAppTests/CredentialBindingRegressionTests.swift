import AppKit
@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing

/// Migration, credentials, endpoint restoration, analysis authorization and
/// prompt compatibility at the state/store/editor boundaries. URL parity
/// also has cases in CanonicalBaseURLTests and the Python suite.
@MainActor
@Suite("Credential migration and endpoint binding")
struct CredentialBindingRegressionTests {
    private func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func installLegacyV1(_ defaults: UserDefaults, defaultProvider: String = "openai") {
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "interfaceLanguage": "en",
            "appearance": "system",
            "typography": ["family": "system", "size": 17, "lineHeight": "1.70"],
            "defaultProvider": defaultProvider,
            "providers": ["openai": ["model": "user-openai-model"], "glm": ["model": "glm-4.7-flash"]],
        ]
        defaults.set(try! JSONSerialization.data(withJSONObject: legacy), forKey: SettingsStore.legacyDefaultsKey)
    }

    // MARK: - abort migration on legacy credential read failure

    @Test func legacyCredentialReadFailureAbortsMigrationWithoutDestructiveCleanup() throws {
        let defaults = freshDefaults()
        installLegacyV1(defaults)
        let keychain = FaultCredentials()
        // GLM's legacy read fails; OpenAI's succeeds (its staged copy must
        // be compensated, and the uncopied GLM key must not be deleted).
        keychain.failLegacyReadProvider = "glm"
        let store = SettingsStore(defaults: defaults, keychain: keychain)
        #expect(store.loadFailure == SettingsLoadFailure(kind: .migrationFailed, messageKey: SettingsStore.messageMigrationFailed))
        // No authoritative v2 was created; v1 stays readable.
        #expect(defaults.data(forKey: SettingsStore.defaultsKey) == nil)
        #expect(defaults.data(forKey: SettingsStore.legacyDefaultsKey) != nil)
        // Both original legacy keys remain; no cleanup was attempted for
        // the uncopied credential.
        #expect(keychain.legacy["openai"] == "OLD_OPENAI")
        #expect(keychain.legacy["glm"] == "OLD_GLM")
        // The staged OpenAI copy was compensated away.
        #expect(keychain.keys.values.allSatisfy { $0 != "OLD_OPENAI" })
        // An unrelated edit cannot bypass the failed migration: Save is refused.
        store.updateDraft { $0.appearance = .dark }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
        #expect(defaults.data(forKey: SettingsStore.defaultsKey) == nil)
    }

    // MARK: - blocking failures surfaced; retry after resolution

    @Test func failedMigrationBlocksUnrelatedSaveAndRetriesAfterResolution() throws {
        let defaults = freshDefaults()
        installLegacyV1(defaults)
        let keychain = FaultCredentials()
        keychain.failLegacyReadProvider = "glm"
        let store = SettingsStore(defaults: defaults, keychain: keychain)
        #expect(store.loadFailure?.kind == .migrationFailed)
        // Unrelated edit → Save must not make the failed migration's empty
        // in-memory record authoritative.
        store.updateDraft { $0.typography.size = 20 }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
        #expect(defaults.data(forKey: SettingsStore.defaultsKey) == nil)
        // Resolve the underlying failure and retry in place.
        keychain.failLegacyReadProvider = nil
        store.retryMigration()
        #expect(store.loadFailure == nil)
        #expect(store.record.modelConfigurations.count == 2)
        #expect(store.record.modelConfigurations.map(\.modelID).contains("user-openai-model"))
        #expect(defaults.data(forKey: SettingsStore.defaultsKey) != nil)
        #expect(defaults.data(forKey: SettingsStore.legacyDefaultsKey) == nil)
        #expect(keychain.legacy.isEmpty) // cleanup succeeded on retry
        // Ordinary Save works again and preserves the migrated record.
        store.updateDraft { $0.typography.size = 20 }
        try store.saveDraft()
        #expect(store.record.typography.size == 20)
    }

    @Test func corruptOrNewerRecordRemainsBlockedWithoutRetryPath() throws {
        let defaults = freshDefaults()
        installLegacyV1(defaults)
        let newer: [String: Any] = ["schemaVersion": 3, "interfaceLanguage": "en", "appearance": "system",
                                    "typography": ["family": "system", "size": 17, "lineHeight": "1.70"],
                                    "modelConfigurations": [], "defaultModelConfigurationID": NSNull()]
        defaults.set(try! JSONSerialization.data(withJSONObject: newer), forKey: SettingsStore.defaultsKey)
        let store = SettingsStore(defaults: defaults, keychain: FaultCredentials())
        #expect(store.loadFailure?.kind == .corruptOrNewerRecord)
        store.retryMigration() // no-op for corrupt records
        #expect(store.loadFailure?.kind == .corruptOrNewerRecord)
        store.updateDraft { $0.appearance = .dark }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
        // Both preserved records are intact.
        #expect(defaults.data(forKey: SettingsStore.defaultsKey) != nil)
        #expect(defaults.data(forKey: SettingsStore.legacyDefaultsKey) != nil)
    }

    // MARK: - residual legacy cleanup retried across launches

    @Test func residualLegacyCleanupRetriesIndependentlyAcrossLaunches() throws {
        let defaults = freshDefaults()
        installLegacyV1(defaults)
        let keychain = FaultCredentials()
        keychain.failLegacyDeleteProvider = "glm"
        let first = SettingsStore(defaults: defaults, keychain: keychain)
        // Migration itself succeeded: v2 is authoritative with stable IDs.
        #expect(first.loadFailure == nil)
        #expect(first.maintenanceNotice == SettingsStore.messageCleanupResidue)
        #expect(first.record.modelConfigurations.count == 2)
        let migratedIDs = first.record.modelConfigurations.map(\.id)
        // One legacy key could not be removed; pending state was recorded.
        #expect(keychain.legacy["openai"] == nil)
        #expect(keychain.legacy["glm"] == "OLD_GLM")
        #expect(defaults.stringArray(forKey: SettingsStore.pendingLegacyCleanupKey) == ["glm"])

        // Relaunch: only the cleanup retries — no migration, no new IDs,
        // no credential copies, v2 contents unchanged.
        keychain.failLegacyDeleteProvider = nil
        let second = SettingsStore(defaults: defaults, keychain: keychain)
        #expect(second.loadFailure == nil)
        #expect(second.maintenanceNotice == nil)
        #expect(second.record.modelConfigurations.map(\.id) == migratedIDs)
        #expect(second.record.modelConfigurations.map(\.modelID) == first.record.modelConfigurations.map(\.modelID))
        #expect(keychain.legacy.isEmpty)
        #expect(defaults.stringArray(forKey: SettingsStore.pendingLegacyCleanupKey) == nil)

        // Later launches are idempotent.
        let third = SettingsStore(defaults: defaults, keychain: keychain)
        #expect(third.maintenanceNotice == nil)
        #expect(third.record.modelConfigurations.map(\.id) == migratedIDs)
    }

    // MARK: - committed credentials deleted through draft → Save

    @Test func configurationDeletionRemovesCommittedKeyOnlyThroughSave() throws {
        let defaults = freshDefaults()
        let keychain = FaultCredentials()
        let store = SettingsStore(defaults: defaults, keychain: keychain, record: LegacyModelFixture.record())
        // Two committed configurations sharing one key value.
        let openai = try #require(store.record.modelConfigurations.first { $0.provider == "openai" })
        let glm = try #require(store.record.modelConfigurations.first { $0.provider == "glm" })
        try keychain.setKey("SYNTHETIC_SAME_VALUE", configurationID: openai.id)
        try keychain.setKey("SYNTHETIC_SAME_VALUE", configurationID: glm.id)

        // Cancel leaves the Keychain unchanged.
        store.removeConfigurationFromDraft(id: openai.id, replacement: glm.id)
        #expect(store.keyDrafts[openai.id] == .delete)
        store.cancelDraft()
        #expect(try keychain.credential(configurationID: openai.id) == "SYNTHETIC_SAME_VALUE")
        #expect(try keychain.credential(configurationID: glm.id) == "SYNTHETIC_SAME_VALUE")

        // Save deletes exactly the removed configuration's item; the
        // equal-valued sibling item survives independently.
        store.removeConfigurationFromDraft(id: openai.id, replacement: glm.id)
        try store.saveDraft()
        #expect(try keychain.credential(configurationID: openai.id) == nil)
        #expect(try keychain.credential(configurationID: glm.id) == "SYNTHETIC_SAME_VALUE")
        #expect(store.record.defaultModelConfigurationID == glm.id)

        // A deletion-write failure aborts the Save and compensates so the
        // committed key is preserved.
        let other = freshDefaults()
        let keychain2 = FaultCredentials()
        let store2 = SettingsStore(defaults: other, keychain: keychain2)
        let victim = try #require(store2.record.defaultConfiguration)
        try keychain2.setKey("COMMITTED_KEY", configurationID: victim.id) // write #1
        keychain2.failAt = 2 // the deletion write inside the Save transaction
        store2.removeConfigurationFromDraft(id: victim.id, replacement: store2.record.modelConfigurations.first { $0.id != victim.id }?.id)
        #expect(throws: SettingsStore.SettingsError.self) { try store2.saveDraft() }
        #expect(try keychain2.credential(configurationID: victim.id) == "COMMITTED_KEY")
    }

    @Test func addedThenDeletedConfigurationWithinDraftNeverTouchesKeychain() throws {
        let store = SettingsStore(defaults: freshDefaults(), keychain: FaultCredentials())
        let added = ModelConfigurationRecord(
            displayName: "Transient", provider: "openai", profile: ModelProfileID.openaiV2,
            modelID: "gpt-6-luna", effort: .low, baseURL: WorkerContract.openAIStandardBaseURL)
        store.updateDraft { $0.modelConfigurations.append(added) }
        store.setKeyDraft(.set("NEVER_COMMITTED"), configurationID: added.id)
        store.removeConfigurationFromDraft(id: added.id, replacement: nil)
        #expect(store.keyDrafts[added.id] == nil) // never committed: no staged deletion
        try store.saveDraft()
        #expect(store.record.modelConfigurations.count == 2)
    }

    // MARK: - typed keys bound to their canonical endpoint (seam)

    @Test func typedKeyStagingBindsToCanonicalEndpoint() throws {
        let a = "https://api.openai.com/v1/"
        let b = "https://gateway.example.com:8443/openai/v1/"
        let pathOnlyB = "https://api.openai.com/team%2Fname/v1/"
        // New entry: typed at A, URL edited to B → the typed key does not
        // travel to B; back at A (or an equivalent canonical spelling) it
        // applies again.
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: nil, keyEdit: .replace, keyField: "KEY_A",
            keyEnteredForCanonicalURL: a, currentCanonicalURL: b) == nil)
        // Equivalent canonical spellings re-apply the typed key: the
        // editor passes the canonicalized URL on both sides, so an
        // uppercase/no-trailing-slash spelling of A canonicalizes to A.
        var equivalentA: String?
        if case .success(let canonical) = CanonicalBaseURL.canonicalize("https://API.OPENAI.COM/v1") {
            equivalentA = canonical
        }
        #expect(equivalentA == a)
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: nil, keyEdit: .replace, keyField: "KEY_A",
            keyEnteredForCanonicalURL: a, currentCanonicalURL: equivalentA ?? "") == .set("KEY_A"))
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: nil, keyEdit: .replace, keyField: "KEY_A",
            keyEnteredForCanonicalURL: a, currentCanonicalURL: a) == .set("KEY_A"))
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: nil, keyEdit: .replace, keyField: "KEY_A",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: a) == nil)
        // A path-only change on the same host invalidates the typed key.
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: nil, keyEdit: .replace, keyField: "KEY_A",
            keyEnteredForCanonicalURL: a, currentCanonicalURL: pathOnlyB) == nil)
        // Existing entry committed at A: typing at B and returning the URL
        // to A restores the original key state (staged nil, not the typed
        // value); an explicit Delete persists regardless of URL.
        let committed = ModelConfigurationRecord(
            provider: "openai", profile: ModelProfileID.openaiV2, modelID: "gpt-6-luna",
            effort: .low, baseURL: a)
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: committed, keyEdit: .replace, keyField: "KEY_B",
            keyEnteredForCanonicalURL: b, currentCanonicalURL: a) == nil)
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: committed, keyEdit: .replace, keyField: "KEY_B",
            keyEnteredForCanonicalURL: b, currentCanonicalURL: b) == .set("KEY_B"))
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: committed, keyEdit: .replace, keyField: "KEY_B",
            keyEnteredForCanonicalURL: b, currentCanonicalURL: a) == nil) // A→B→A: typed key only at B
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: committed, keyEdit: .delete, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: a) == .delete)
        // URL changed from the committed endpoint with no explicit edit:
        // the committed key is cleared (deleted on Save).
        #expect(ConfigurationSheet.stagedKeyChange(
            existing: committed, keyEdit: .inherit, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: b) == .clearForEndpointChange)
    }

    // MARK: - Runtime fixtures shared by the dispatch-level findings

    @MainActor
    private func preparedApp(gateway: ScriptedGateway = ScriptedGateway()) -> (AppRuntime, FaultCredentials, UserDefaults) {
        let keys = FaultCredentials(), defs = UserDefaults(suiteName: "dev.bipara.test.\(UUID())")!
        LegacyModelFixture.install(defs)
        let app = AppRuntime(gateway: gateway, keychain: keys, defaults: defs)
        for configuration in app.settings.record.modelConfigurations { keys.keys[configuration.id] = "SYNTHETIC_TEST_CREDENTIAL" }
        // No disclosure presets: consent tests exercise the real flow.
        return (app, keys, defs)
    }

    /// Marks the tab like an opened document: snapshot + translations, no
    /// session-local runtime binding.
    @MainActor
    private func openedTab(_ app: AppRuntime, source: String, completed: Bool, promptVersions: (String, String) = ("translation.v1", "alignment.v1")) throws -> UUID {
        try app.workspace.newTab(source: source, direction: .enToZh)
        let index = app.workspace.tabs.count - 1
        let document = app.workspace.tabs[index].document
        let translatedUnits = completed ? document.units : Array(document.units.prefix(1))
        let snapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: document.sourceRevision,
            sourceLanguage: .en, targetLanguage: .zh,
            provider: "openai", model: "gpt-4.1-mini-2025-04-14", profile: ModelProfileID.openaiV2,
            effort: .auto,
            translationPromptVersion: promptVersions.0, alignmentPromptVersion: promptVersions.1)
        app.workspace.withTab(index) {
            $0.document.jobSnapshot = snapshot
            $0.document.resolvedDirection = .enToZh
            $0.document.translations = translatedUnits.map {
                .init(unitID: $0.id, text: "译文\($0.sourceRange.location)", returnedModel: nil, completedAt: Date())
            }
            $0.job.snapshot = snapshot
            $0.job.completedUnitIDs = Set(translatedUnits.map(\.id))
            $0.job.totalNonblankUnits = document.units.count
            $0.job.state = completed ? .completed : .paused
            // An opened file starts content-saved (not dirty).
            $0.savedContentGeneration = $0.contentGeneration
        }
        return app.workspace.tabs[index].sessionID
    }

    // MARK: - explicit binding for analysis of existing translations

    @Test func openedDocumentAnalysisRequiresExplicitBindingWithoutRetranslating() async throws {
        let gateway = ScriptedGateway()
        let (app, _, defs) = preparedApp(gateway: gateway)
        defs.set(true, forKey: "dev.bipara.disclosure.openai|https://api.openai.com")
        let session = try openedTab(app, source: "The window is open. It rained today.", completed: true)
        let document = app.workspace.tabs[0].document
        let selection = ReadingSelection(
            paragraphID: document.paragraphs[0].id, unitID: document.units[0].id,
            side: .source, range: .init(location: 0, length: 3))
        app.selected(selection, session: session)
        // After the debounce the app offers an explicit analysis binding;
        // no model call happens before that confirmation.
        try await appWaitUntil { app.bindingRequest != nil }
        let request = try #require(app.bindingRequest)
        #expect(request.purpose == .analysis)
        #expect(gateway.alignmentDispatchCount == 0)
        #expect(gateway.dispatchCount == 0)
        // Cancellation: no call, the fallback stays.
        app.bindingRequest = nil
        try await Task.sleep(for: .milliseconds(500))
        #expect(gateway.alignmentDispatchCount == 0)

        // Confirming the binding runs analysis under the frozen snapshot:
        // the snapshot's model/profile/effort with the chosen endpoint. A
        // different selection re-triggers the offer (identical selections
        // are deduplicated by design).
        app.selected(ReadingSelection(
            paragraphID: document.paragraphs[0].id, unitID: document.units[0].id,
            side: .source, range: .init(location: 4, length: 5)), session: session)
        try await appWaitUntil { app.bindingRequest != nil }
        let confirmed = try #require(app.bindingRequest)
        let match = try #require(confirmed.matches.first)
        app.bindForAnalysis(confirmed, configurationID: match.id)
        try await appWaitUntil { gateway.alignmentDispatchCount == 1 }
        let used = try #require(gateway.alignConfigurations.first)
        #expect(used.model == "gpt-4.1-mini-2025-04-14") // frozen snapshot model
        #expect(used.profile == ModelProfileID.openaiV2)
        #expect(used.effort == .auto)
        #expect(used.baseURL == match.baseURL)
        #expect(gateway.dispatchCount == 0) // analysis-only binding never translates
        #expect(!app.workspace.tabs[0].isDirty) // binding does not dirty content
    }

    @Test func sameURLModelEditKeepsAnalysisOnFrozenSnapshotWhileEndpointChangesBlockIt() async throws {
        let gateway = ScriptedGateway()
        let (app, keys, defs) = preparedApp(gateway: gateway)
        defs.set(true, forKey: "dev.bipara.disclosure.openai|https://api.openai.com")
        let session = try openedTab(app, source: "The window is open. It rained today.", completed: true)
        let defaultID = try #require(app.settings.record.defaultConfiguration?.id)
        app.workspace.withTab(0) { $0.runtimeBinding = RuntimeModelBinding(configurationID: defaultID, baseURL: WorkerContract.openAIStandardBaseURL, provider: "openai") }
        let document = app.workspace.tabs[0].document
        let selection = ReadingSelection(
            paragraphID: document.paragraphs[0].id, unitID: document.units[0].id,
            side: .source, range: .init(location: 0, length: 3))

        // A model edit at the same endpoint does not disable analysis; the
        // job keeps its frozen snapshot values.
        app.settings.updateDraft {
            if let i = $0.modelConfigurations.firstIndex(where: { $0.id == defaultID }) {
                $0.modelConfigurations[i].modelID = "edited-model"
            }
        }
        try app.settings.saveDraft()
        app.selected(selection, session: session)
        try await appWaitUntil { gateway.alignmentDispatchCount == 1 }
        #expect(gateway.alignConfigurations.last?.model == "gpt-4.1-mini-2025-04-14")

        // An endpoint change on the bound configuration blocks later
        // analysis quietly (local configuration_unavailable, no call).
        app.settings.updateDraft {
            if let i = $0.modelConfigurations.firstIndex(where: { $0.id == defaultID }) {
                $0.modelConfigurations[i].baseURL = "https://gateway.example.com/v1/"
            }
        }
        try app.settings.saveDraft()
        app.reading[session]?.selectionGeneration += 1 // supersede the cached pending analysis
        app.selected(ReadingSelection(
            paragraphID: document.paragraphs[0].id, unitID: document.units[0].id,
            side: .source, range: .init(location: 4, length: 5)), session: session)
        try await Task.sleep(for: .milliseconds(500))
        #expect(gateway.alignmentDispatchCount == 1)

        // Deletion of the bound configuration behaves the same way.
        app.settings.updateDraft {
            $0.modelConfigurations.removeAll { $0.id == defaultID }
            $0.defaultModelConfigurationID = $0.modelConfigurations.first?.id
        }
        try app.settings.saveDraft()
        app.reading[session]?.selectionGeneration += 1
        app.selected(selection, session: session)
        try await Task.sleep(for: .milliseconds(500))
        #expect(gateway.alignmentDispatchCount == 1)
        _ = keys
    }

    @Test func unboundPartialDocumentAnalysisOnUntranslatedUnitMakesNoRequest() async throws {
        let gateway = ScriptedGateway()
        let (app, _, defs) = preparedApp(gateway: gateway)
        defs.set(true, forKey: "dev.bipara.disclosure.openai|https://api.openai.com")
        let session = try openedTab(app, source: "The window is open. It rained today.", completed: false)
        let document = app.workspace.tabs[0].document
        let untranslated = try #require(document.units.last)
        app.selected(ReadingSelection(
            paragraphID: untranslated.paragraphID, unitID: untranslated.id,
            side: .source, range: .init(location: 0, length: 3)), session: session)
        try await Task.sleep(for: .milliseconds(500))
        #expect(app.bindingRequest == nil) // no analysis offer for untranslated text
        #expect(gateway.alignmentDispatchCount == 0)
    }

    // MARK: - retired prompt versions block Resume, Retranslate proceeds

    @Test func retiredPromptVersionsBlockResumeAndRetranslateUsesCurrentVersions() async throws {
        let gateway = ScriptedGateway()
        let (app, _, defs) = preparedApp(gateway: gateway)
        defs.set(true, forKey: "dev.bipara.disclosure.openai|https://api.openai.com")
        app.alertHandler = { _, _, _ in 0 } // confirm the explicit Retranslate
        let session = try openedTab(
            app, source: String(repeating: "Hello there. ", count: 40),
            completed: false, promptVersions: ("translation.v0", "alignment.v0"))
        let defaultID = try #require(app.settings.record.defaultConfiguration?.id)
        app.workspace.withTab(0) { $0.runtimeBinding = RuntimeModelBinding(configurationID: defaultID, baseURL: WorkerContract.openAIStandardBaseURL, provider: "openai") }
        let translationsBefore = app.workspace.tabs[0].document.translations

        await app.translate(session)
        // Zero dispatch: retired prompt versions cannot resume, existing
        // translations and attribution stay untouched.
        #expect(gateway.dispatchCount == 0)
        #expect(app.workspace.tabs[0].document.translations == translationsBefore)
        #expect(app.workspace.tabs[0].document.jobSnapshot?.translationPromptVersion == "translation.v0")
        #expect(app.errorMessage != nil)

        // Explicit Retranslate creates a new current-version snapshot and
        // completes normally.
        app.errorMessage = nil
        await app.translate(session, retranslate: true)
        try await appWaitUntil { app.workspace.tabs[0].job.state == .completed }
        #expect(gateway.dispatchCount > 0)
        #expect(app.workspace.tabs[0].document.jobSnapshot?.translationPromptVersion == "translation.v2")
        #expect(app.workspace.tabs[0].document.jobSnapshot?.alignmentPromptVersion == "alignment.v1")
    }

    // MARK: - dropped typed key consequences at the dispatch seam

    @Test func endpointChangeDropsTypedKeyAndRequiresReEntryBeforeDispatch() async throws {
        let gateway = ScriptedGateway()
        let (app, keys, defs) = preparedApp(gateway: gateway)
        // Both endpoints' acknowledgements are preset: consent is covered
        // by its own test below, and headless runs must never reach the
        // modal alert path.
        defs.set(true, forKey: "dev.bipara.disclosure.openai|https://api.openai.com")
        defs.set(true, forKey: "dev.bipara.disclosure.openai|https://gateway.example.com")
        // A configuration saved at endpoint B whose editor dropped a key
        // typed for endpoint A (see typedKeyStagingBindsToCanonicalEndpoint):
        // it commits with no key.
        let moved = ModelConfigurationRecord(
            displayName: "Moved", provider: "openai", profile: ModelProfileID.openaiV2,
            modelID: "gpt-6-luna", effort: .low, baseURL: "https://gateway.example.com/v1/")
        app.settings.updateDraft { draft in
            draft.modelConfigurations = [moved]
            draft.defaultModelConfigurationID = moved.id
        }
        try app.settings.saveDraft()
        try app.workspace.newTab(source: "The window is open.", direction: .enToZh)
        let session = app.workspace.tabs[0].sessionID
        var offeredKeyAlert = false
        app.alertHandler = { _, _, buttons in
            offeredKeyAlert = (buttons == ["Open Settings", "Cancel"]); return 1 // Cancel
        }
        await app.translate(session)
        #expect(gateway.dispatchCount == 0) // preflight: missing key at the new endpoint
        // The missing-key preflight offers Settings rather than only an
        // error message (model-settings contract).
        #expect(offeredKeyAlert)
        app.alertHandler = nil

        // Entering the key for B enables dispatch — captured destination
        // is exactly B, never the endpoint the dropped key belonged to.
        keys.keys[moved.id] = "SYNTHETIC_KEY_FOR_B"
        await app.translate(session)
        try await appWaitUntil { app.workspace.tabs[0].job.state == .completed }
        #expect(gateway.configurations.allSatisfy { $0.baseURL == "https://gateway.example.com/v1/" })
    }

    // MARK: - Consent (first use, cancellation, per provider/origin)

    @Test func firstUseConsentCancellationAndPerOriginAcknowledgement() async throws {
        let gateway = ScriptedGateway()
        let (app, _, defs) = preparedApp(gateway: gateway)
        var captured: [(String, String)] = []
        var answers: [Int] = []
        app.alertHandler = { title, detail, _ in
            captured.append((title, detail))
            return answers.isEmpty ? 0 : answers.removeFirst()
        }
        try app.workspace.newTab(source: "The window is open.", direction: .enToZh)
        var session = app.workspace.tabs[0].sessionID

        // First use: the user cancels — no dispatch, nothing recorded.
        answers = [1]
        await app.translate(session)
        #expect(gateway.dispatchCount == 0)
        #expect(captured.count == 1 && captured[0].0.contains("api.openai.com"))
        #expect(!defs.bool(forKey: "dev.bipara.disclosure.openai|https://api.openai.com"))

        // Same selection retried and confirmed: dispatch proceeds and the
        // acknowledgement is recorded for that provider/origin only.
        answers = [0]
        await app.translate(session)
        try await appWaitUntil { app.workspace.tabs[0].job.state == .completed }
        #expect(gateway.dispatchCount >= 1)
        #expect(defs.bool(forKey: "dev.bipara.disclosure.openai|https://api.openai.com"))
        // A later dispatch needs no new acknowledgement.
        let consentCalls = captured.count
        try app.workspace.newTab(source: "Another sentence.", direction: .enToZh)
        session = app.workspace.tabs[1].sessionID
        await app.translate(session)
        try await appWaitUntil { app.workspace.tabs[1].job.state == .completed }
        #expect(captured.count == consentCalls)

        // A different provider/origin requires its own acknowledgement.
        let glmID = try #require(app.settings.record.modelConfigurations.first { $0.provider == "glm" }?.id)
        app.settings.updateDraft { $0.defaultModelConfigurationID = glmID }
        try app.settings.saveDraft()
        try app.workspace.newTab(source: "Third document here.", direction: .enToZh)
        session = app.workspace.tabs[2].sessionID
        answers = [1] // refused first
        await app.translate(session)
        #expect(gateway.dispatchCount == 2) // the two confirmed tabs' batches only
        #expect(captured.last?.0.contains("open.bigmodel.cn") == true)
        #expect(!defs.bool(forKey: "dev.bipara.disclosure.glm|https://open.bigmodel.cn"))
        answers = [0]
        await app.translate(session)
        try await appWaitUntil { app.workspace.tabs[2].job.state == .completed }
        #expect(gateway.dispatchCount >= 3)
        #expect(defs.bool(forKey: "dev.bipara.disclosure.glm|https://open.bigmodel.cn"))
        // The OpenAI origin's earlier consent never authorized the GLM one
        // and vice versa; a distinct OpenAI-compatible gateway asks again.
        app.settings.updateDraft {
            if let i = $0.modelConfigurations.firstIndex(where: { $0.provider == "openai" }) {
                $0.modelConfigurations[i].baseURL = "https://gateway.example.com/v1/"
            }
            $0.defaultModelConfigurationID = $0.modelConfigurations.first { $0.provider == "openai" }?.id
        }
        // The endpoint change deletes the committed key at Save; a
        // replacement key typed for the new endpoint is staged explicitly.
        if let openaiID = app.settings.record.modelConfigurations.first(where: { $0.provider == "openai" })?.id {
            app.settings.setKeyDraft(.set("SYNTHETIC_GATEWAY_KEY"), configurationID: openaiID)
        }
        try app.settings.saveDraft()
        try app.workspace.newTab(source: "Fourth document here.", direction: .enToZh)
        session = app.workspace.tabs[3].sessionID
        answers = [0]
        await app.translate(session)
        try await appWaitUntil { app.workspace.tabs[3].job.state == .completed }
        #expect(gateway.dispatchCount >= 4)
        #expect(captured.last?.0.contains("gateway.example.com") == true)
        #expect(defs.bool(forKey: "dev.bipara.disclosure.openai|https://gateway.example.com"))
    }
}
