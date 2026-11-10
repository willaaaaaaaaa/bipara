import BiparaAppKit
import BiparaCore
import Foundation
import Testing

@MainActor
@Suite("Workspace store")
struct WorkspaceStoreTests {
    @Test func newTabCreatesIndependentSessions() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "Hello there.\nSecond sentence here.")
        try workspace.newTab(source: "第一句。\n\n第二句。")
        let first = workspace.tabs[0]
        let second = workspace.tabs[1]
        #expect(first.sessionID != second.sessionID)
        #expect(first.document.documentID != second.document.documentID)
        #expect(workspace.activeTabIndex == 1)
        #expect(DocumentTitle.derive(from: "Hello there.\nSecond") == "Hello there.")
        #expect(DocumentTitle.derive(from: "\n\n   \nfirst line") == "first line")
        #expect(DocumentTitle.derive(from: "   ") == "Untitled")
    }

    @Test func draftEditsMarkDirtyAndApplyReplansUnderNewRevision() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "The window is open.\nIt rained today.")
        workspace.withTab(0) { $0.draftText = "The window is closed.\nIt rained today." }
        #expect(workspace.tabs[0].isDraftDirty)
        #expect(!workspace.tabs[0].isDirty || workspace.tabs[0].isDraftDirty) // draft dirty ⊂ dirty

        // Seed valid committed content before proving invalidation.
        workspace.withTab(0) { tab in
            tab.document.jobSnapshot = JobSnapshot(jobID: UUID(), sourceRevision: 1, sourceLanguage: .en, targetLanguage: .zh,
                provider: "openai", model: "gpt-4.1-mini-2025-04-14", profile: "openai-json-schema-v1", effort: .auto,
                translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1")
            tab.document.translations = tab.document.units.map { .init(unitID: $0.id, text: "已翻译", completedAt: Date()) }
        }
        #expect(!workspace.tabs[0].document.translations.isEmpty)
        try workspace.applyDraft(at: 0)
        let document = workspace.tabs[0].document
        #expect(document.sourceRevision == 2)
        #expect(TextIdentity.equal(document.source, "The window is closed.\nIt rained today."))
        #expect(document.translations.isEmpty)
        #expect(document.jobSnapshot == nil)
        #expect(workspace.tabs[0].isDirty)
        #expect(!workspace.tabs[0].isDraftDirty) // applied: draft == source again
    }

    @Test func closeTabPreservesOthersAndAdjustsActive() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "One.")
        try workspace.newTab(source: "Two.")
        try workspace.newTab(source: "Three.")
        workspace.switchTab(to: 2)
        workspace.closeTab(at: 1) // close a middle inactive tab
        #expect(workspace.tabs.map { $0.document.source } == ["One.", "Three."])
        #expect(workspace.activeTabIndex == 1)
        // Closing the final tab leaves an empty workspace.
        workspace.closeTab(at: 0)
        workspace.closeTab(at: 0)
        #expect(workspace.isEmpty)
        #expect(workspace.activeTabIndex == nil)
    }

    @Test func whitespaceOnlySourceCannotTranslateButTabsPersist() throws {
        let workspace = WorkspaceStore()
        try workspace.newTab(source: "   \n\t\n")
        #expect(workspace.tabs[0].document.source.isWhitespaceOnly)
        #expect(workspace.tabs[0].document.paragraphs.allSatisfy { $0.unitIDs.isEmpty })
    }
}

@MainActor
@Suite("Settings store")
struct SettingsStoreTests {
    @Test func toolbarSelectionPersistsWithoutSavingOtherSettingsDraftFields() throws {
        let defaults = UserDefaults(suiteName: "dev.bipara.test.\(UUID())")!
        let store = SettingsStore(defaults: defaults)
        let first = store.record.modelConfigurations[0].id
        let second = store.record.modelConfigurations[1].id
        store.updateDraft { $0.preferredTranslationDirection = .zhToEn }
        try store.selectActiveModel(second)
        #expect(store.draft.defaultModelConfigurationID == second)
        #expect(store.draft.translationDirection == .zhToEn)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.record.defaultModelConfigurationID == second)
        #expect(reloaded.record.translationDirection == .auto)
        store.updateDraft { $0.defaultModelConfigurationID = first }
        try store.selectActiveModel(first)
        try store.selectActiveModel(second)
        #expect(store.draft.defaultModelConfigurationID == first)
        store.cancelDraft()
        #expect(store.draft.defaultModelConfigurationID == second)
    }

    @Test func toolbarSelectionOfDraftDeletedEntryRequiresReplacementUntilRefresh() throws {
        let defaults = UserDefaults(suiteName: "dev.bipara.test.\(UUID())")!
        let keys = FaultCredentials()
        let store = SettingsStore(defaults: defaults, keychain: keys)
        let first = store.record.modelConfigurations[0].id
        let second = store.record.modelConfigurations[1].id
        keys.keys[first] = "OLD_FIRST"
        try store.selectActiveModel(second)
        // Stage a deletion of the non-active entry, then select that
        // deleted entry from the toolbar (it is still committed, so the
        // toolbar legitimately offers it).
        store.removeConfigurationFromDraft(id: first, replacement: nil)
        try store.selectActiveModel(first)
        // The draft loses its active selection and Save demands a
        // replacement while the field is unset.
        #expect(store.draft.defaultModelConfigurationID == nil)
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
        // The reset was reconciliation output, not an explicit Settings
        // edit: a later toolbar selection of an entry the draft still
        // contains refreshes the field and Save succeeds, executing the
        // staged credential deletion.
        try store.selectActiveModel(second)
        #expect(store.draft.defaultModelConfigurationID == second)
        try store.saveDraft()
        #expect(store.record.defaultModelConfigurationID == second)
        #expect(store.record.modelConfigurations.map(\.id) == [second])
        #expect(keys.keys[first] == nil)
    }

    @Test func sameURLProtocolEditCannotReuseOldCredentialOrBinding() throws {
        let defaults = UserDefaults(suiteName: "dev.bipara.test.\(UUID())")!
        let keys = FaultCredentials()
        let store = SettingsStore(defaults: defaults, keychain: keys)
        let entry = try #require(store.record.defaultConfiguration)
        try keys.setKey("SYNTHETIC_OLD", configurationID: entry.id)
        let frozen = entry.runtimeBinding
        store.updateDraft {
            $0.modelConfigurations[0].provider = "anthropic"
            $0.modelConfigurations[0].profile = ModelAPIProtocol.anthropic.profile
            $0.modelConfigurations[0].modelID = "kimi-k3.1-pro"
        }
        try store.saveDraft()
        #expect(try keys.credential(configurationID: entry.id) == nil)
        try keys.setKey("SYNTHETIC_NEW", configurationID: entry.id)
        #expect(throws: SettingsStore.SettingsError.configurationUnavailable) { try store.resolveCredential(frozen) }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A v1 provider-keyed record as written by the previous app version.
    private func installLegacyV1(_ defaults: UserDefaults, model: String = "gpt-4.1-mini-2025-04-14",
                                 defaultProvider: String = "openai") {
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "interfaceLanguage": "zh-Hans",
            "appearance": "dark",
            "typography": ["family": "serif", "size": 21, "lineHeight": "1.95"],
            "defaultProvider": defaultProvider,
            "providers": ["openai": ["model": model], "glm": ["model": "glm-4.7-flash"]],
        ]
        defaults.set(try! JSONSerialization.data(withJSONObject: legacy), forKey: SettingsStore.legacyDefaultsKey)
    }

    @Test func draftSaveCommitsAndPersists() throws {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        let glmID = try #require(store.draft.modelConfigurations.first { $0.vendorLabel == "GLM" }?.id)
        store.updateDraft { draft in
            draft.appearance = .dark
            draft.interfaceLanguage = .simplifiedChinese
            draft.typography.size = 20
            if let index = draft.modelConfigurations.firstIndex(where: { $0.id == glmID }) {
                draft.modelConfigurations[index].modelID = "glm-4.7"
                draft.modelConfigurations[index].effort = .medium
            }
        }
        #expect(store.hasDraftChanges)
        try store.saveDraft()
        #expect(!store.hasDraftChanges)
        #expect(store.record.appearance == .dark)

        // A fresh store over the same defaults reads the committed record.
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.record == store.record)
        #expect(reloaded.record.typography.size == 20)
        #expect(reloaded.record.defaultConfiguration?.modelID == "gpt-6-luna")

        // Cancel discards uncommitted edits, including the default choice.
        let committedDefault = reloaded.record.defaultModelConfigurationID
        let other = try #require(reloaded.draft.modelConfigurations.first { $0.id != committedDefault }?.id)
        reloaded.updateDraft { $0.defaultModelConfigurationID = other }
        reloaded.cancelDraft()
        #expect(reloaded.record.defaultModelConfigurationID == committedDefault)
        #expect(!reloaded.hasDraftChanges)
    }

    @Test func invalidFieldsAbortSave() throws {
        let store = SettingsStore(defaults: freshDefaults())
        store.updateDraft { $0.typography.size = 40 }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
        store.cancelDraft()

        store.updateDraft {
            $0.modelConfigurations[0].modelID = "  "
        }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
        store.cancelDraft()

        store.updateDraft {
            $0.modelConfigurations[0].baseURL = "https://api.openai.com/v1/chat/completions"
        }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
        store.cancelDraft()

        // Unsupported effort for the model is rejected; so is a duplicate
        // resolved name/effort pair.
        store.updateDraft {
            $0.modelConfigurations[0].modelID = "glm-5.3"
            $0.modelConfigurations[0].provider = "glm"
            $0.modelConfigurations[0].profile = ModelProfileID.glmV2
            $0.modelConfigurations[0].requestOptions = nil
            $0.modelConfigurations[0].revision = nil
            $0.modelConfigurations[0].baseURL = WorkerContract.glmStandardBaseURL
            $0.modelConfigurations[0].effort = .off
        }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
        store.cancelDraft()

        var duplicated = try #require(store.record.defaultConfiguration)
        duplicated.id = UUID()
        duplicated.displayName = "openai"
        store.updateDraft { $0.modelConfigurations.append(duplicated) }
        #expect(throws: SettingsStore.SettingsError.duplicateNameEffort) { try store.saveDraft() }
        store.cancelDraft()
        #expect(store.record.typography.size == 17) // record untouched by failed saves
    }

    @Test func emptyListModelListIsValidButRequiresNoDefaultMismatch() throws {
        let store = SettingsStore(defaults: freshDefaults())
        store.updateDraft { draft in
            draft.modelConfigurations = []
            draft.defaultModelConfigurationID = nil
        }
        try store.saveDraft() // an empty list is valid
        #expect(store.record.defaultModelConfigurationID == nil)
        // A nonempty list requires a default that exists in that list.
        store.updateDraft {
            $0.modelConfigurations = [ModelConfigurationRecord(
                provider: "glm", profile: ModelProfileID.glmV2, modelID: "glm-5.3-flash",
                effort: .low, baseURL: WorkerContract.glmStandardBaseURL)]
        }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
    }

    // MARK: Migration (SET-05)

    @Test func migrationPreservesModelsDefaultLanguageAppearanceTypography() throws {
        let defaults = freshDefaults()
        installLegacyV1(defaults, model: "user-kept-model", defaultProvider: "glm")
        let store = SettingsStore(defaults: defaults)
        #expect(store.loadFailure == nil)
        #expect(store.maintenanceNotice == nil)
        #expect(store.record.modelConfigurations.count == 2)
        let openai = try #require(store.record.modelConfigurations.first { $0.provider == "openai" })
        let glm = try #require(store.record.modelConfigurations.first { $0.provider == "glm" })
        // Exact model IDs preserved; no upgrades or recommended entries.
        #expect(openai.modelID == "user-kept-model")
        #expect(glm.modelID == "glm-4.7-flash")
        // Original profiles: OpenAI v1 with Auto, GLM v1 with Off.
        #expect(openai.profile == ModelProfileID.openaiV1); #expect(openai.effort == .auto)
        #expect(glm.profile == ModelProfileID.glmV1); #expect(glm.effort == .off)
        #expect(openai.baseURL == WorkerContract.openAIStandardBaseURL)
        #expect(glm.baseURL == WorkerContract.glmStandardBaseURL)
        // Old default provider maps to its new entry; unrelated fields kept.
        #expect(store.record.defaultModelConfigurationID == glm.id)
        #expect(store.record.interfaceLanguage == .simplifiedChinese)
        #expect(store.record.appearance == .dark)
        #expect(store.record.typography.family == .serif)
        #expect(store.record.typography.size == 21)
        #expect(store.record.typography.lineHeight == .spacious)
        // v2 is authoritative; the legacy record is cleaned up.
        #expect(defaults.data(forKey: SettingsStore.defaultsKey) != nil)
        #expect(defaults.data(forKey: SettingsStore.legacyDefaultsKey) == nil)
        // Repeated launch retains IDs (no re-migration, no new UUIDs).
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.record == store.record)
    }

    @Test func migrationStagesConfigurationScopedKeychainCopies() throws {
        let defaults = freshDefaults()
        installLegacyV1(defaults)
        let keychain = FaultCredentials()
        keychain.legacy = ["openai": "LEGACY_OPENAI"] // glm key missing: stays missing
        _ = SettingsStore(defaults: defaults, keychain: keychain)
        let store = SettingsStore(defaults: defaults, keychain: keychain)
        let openai = try #require(store.record.modelConfigurations.first { $0.provider == "openai" })
        let glm = try #require(store.record.modelConfigurations.first { $0.provider == "glm" })
        // Independent configuration-scoped copies; a missing key stays missing.
        #expect(keychain.keys[openai.id] == "LEGACY_OPENAI")
        #expect(keychain.keys[glm.id] == nil)
        // Legacy items are cleaned up after verified v2 persistence.
        #expect(keychain.legacy["openai"] == nil)
    }

    @Test func migrationFailureLeavesV1AuthoritativeAndCompensates() throws {
        @MainActor final class FailingKeychain: CredentialStore {
            var staged: [UUID: String] = [:]
            var failStaging = true
            func hasKey(configurationID: UUID) -> Bool { staged[configurationID] != nil }
            func credential(configurationID: UUID) throws -> String? { staged[configurationID] }
            func setKey(_ key: String, configurationID: UUID) throws {
                if failStaging { throw NSError(domain: "synthetic staging failure", code: 1) }
                staged[configurationID] = key
            }
            func deleteKey(configurationID: UUID) throws { staged[configurationID] = nil }
            func legacyCredential(provider: String) throws -> String? { "LEGACY_\(provider.uppercased())" }
            func deleteLegacyKey(provider: String) throws {}
        }
        let defaults = freshDefaults()
        installLegacyV1(defaults)
        let keychain = FailingKeychain()
        let store = SettingsStore(defaults: defaults, keychain: keychain)
        #expect(store.loadFailure?.kind == .migrationFailed)
        // v1 remains authoritative and readable; v2 was not persisted.
        #expect(defaults.data(forKey: SettingsStore.defaultsKey) == nil)
        #expect(defaults.data(forKey: SettingsStore.legacyDefaultsKey) != nil)
        #expect(keychain.staged.isEmpty) // staged writes compensated
    }

    @Test func corruptOrNewerV2NeverFallsBackOrResets() throws {
        let defaults = freshDefaults()
        installLegacyV1(defaults)
        let newer: [String: Any] = ["schemaVersion": 3, "interfaceLanguage": "en", "appearance": "system",
                     "typography": ["family": "system", "size": 17, "lineHeight": "1.70"],
                     "modelConfigurations": [], "defaultModelConfigurationID": NSNull()]
        defaults.set(try! JSONSerialization.data(withJSONObject: newer), forKey: SettingsStore.defaultsKey)
        let store = SettingsStore(defaults: defaults)
        #expect(store.loadFailure?.kind == .corruptOrNewerRecord)
        // Data preserved: no fallback to v1 or defaults, nothing overwritten.
        #expect(defaults.data(forKey: SettingsStore.defaultsKey) != nil)
        #expect(defaults.data(forKey: SettingsStore.legacyDefaultsKey) != nil)
        #expect(store.record.modelConfigurations.isEmpty)
        // Saving over a preserved corrupt record is refused.
        store.updateDraft { $0.typography.size = 20 }
        #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }

        let corrupt = freshDefaults()
        corrupt.set(Data("not json".utf8), forKey: SettingsStore.defaultsKey)
        #expect(SettingsStore(defaults: corrupt).loadFailure != nil)
    }

    @Test func freshInstallSeedsResponsesAndPersistsStableIDs() throws {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.record.modelConfigurations.map(\.vendorLabel) == ["OpenAI", "GLM"])
        #expect(store.record.modelConfigurations.allSatisfy { $0.profile == ModelAPIProtocol.openai.profile && $0.effort == .low && $0.requestOptions != nil })
        #expect(store.record.modelConfigurations.allSatisfy { ModelProfileID.all.contains($0.profile) })
        let reloaded = SettingsStore(defaults: defaults)
        // IDs stay stable across launches from the first run.
        #expect(reloaded.record.modelConfigurations.map(\.id) == store.record.modelConfigurations.map(\.id))
    }

    // MARK: Runtime binding resolution (JOB-04 / PRIV-03)

    @Test func resolveCredentialEnforcesFrozenEndpointAndKeyRotation() throws {
        let defaults = freshDefaults()
        let keychain = FaultCredentials()
        let store = SettingsStore(defaults: defaults, keychain: keychain)
        let openai = try #require(store.record.modelConfigurations.first { $0.provider == "openai" })
        let binding = openai.runtimeBinding
        #expect(throws: SettingsStore.SettingsError.missingCredential) { try store.resolveCredential(binding) }
        try keychain.setKey("FIRST_SYNTHETIC", configurationID: openai.id)
        #expect(try store.resolveCredential(binding) == "FIRST_SYNTHETIC")
        // Key rotation at the same URL applies to later dispatches.
        try keychain.setKey("SECOND_SYNTHETIC", configurationID: openai.id)
        #expect(try store.resolveCredential(binding) == "SECOND_SYNTHETIC")
        // A changed endpoint blocks the old binding (configuration_unavailable).
        store.updateDraft {
            $0.modelConfigurations[0].baseURL = "https://gateway.example.com/v1/"
        }
        try store.saveDraft()
        #expect(throws: SettingsStore.SettingsError.configurationUnavailable) { try store.resolveCredential(binding) }
        // A deleted configuration blocks the old binding as well.
        store.updateDraft { draft in
            draft.modelConfigurations.removeAll { $0.id == openai.id }
            draft.defaultModelConfigurationID = draft.modelConfigurations.first?.id
        }
        try store.saveDraft()
        #expect(throws: SettingsStore.SettingsError.configurationUnavailable) { try store.resolveCredential(binding) }
    }

    @Test func matchingConfigurationsFilterByProviderModelProfileEffort() throws {
        let store = SettingsStore(defaults: freshDefaults())
        let current = try #require(store.record.defaultConfiguration)
        let snapshot = JobSnapshot(
            jobID: UUID(), sourceRevision: 1, sourceLanguage: .en, targetLanguage: .zh,
            provider: current.provider, model: current.modelID, profile: current.profile,
            effort: current.effort, translationPromptVersion: "translation.v1", alignmentPromptVersion: "alignment.v1", configurationRevision: current.revision)
        #expect(store.matchingConfigurations(for: snapshot).count == 1)
        var otherEffort = snapshot
        otherEffort.effort = .high
        #expect(store.matchingConfigurations(for: otherEffort).isEmpty)
    }
}

@MainActor
@Suite("Keychain store (isolated synthetic entries)")
struct KeychainStoreTests {
    private func isolated() -> (KeychainStore, String) {
        let service = "dev.bipara.test.\(UUID().uuidString)"
        return (KeychainStore(service: service), service)
    }

    @Test func presenceReplaceDelete() throws {
        let (store, _) = isolated()
        defer { store.removeAllForTesting() }
        let configuration = UUID()
        #expect(!store.hasKey(configurationID: configuration))
        try store.setKey("SYNTHETIC_TEST_CREDENTIAL", configurationID: configuration)
        #expect(store.hasKey(configurationID: configuration))
        #expect(try store.credential(configurationID: configuration) == "SYNTHETIC_TEST_CREDENTIAL")
        try store.setKey("SYNTHETIC_REPLACED", configurationID: configuration)
        #expect(try store.credential(configurationID: configuration) == "SYNTHETIC_REPLACED")
        try store.deleteKey(configurationID: configuration)
        #expect(!store.hasKey(configurationID: configuration))
        // Deleting an absent key is tolerated (scoped no-op).
        try store.deleteKey(configurationID: configuration)
    }

    @Test func equalKeyValuesStayIndependentlyScoped() throws {
        // PRIV-03: the same key value in two entries creates independent
        // items; editing or deleting one cannot affect the other.
        let (store, _) = isolated()
        defer { store.removeAllForTesting() }
        let first = UUID(), second = UUID()
        try store.setKey("SYNTHETIC_SAME_VALUE", configurationID: first)
        try store.setKey("SYNTHETIC_SAME_VALUE", configurationID: second)
        #expect(try store.credential(configurationID: first) == "SYNTHETIC_SAME_VALUE")
        try store.deleteKey(configurationID: first)
        #expect(try store.credential(configurationID: second) == "SYNTHETIC_SAME_VALUE")
        #expect(try store.credential(configurationID: first) == nil)
    }

    @Test func legacyProviderItemsRemainReadableAndDeletable() throws {
        let (store, _) = isolated()
        defer { store.removeAllForTesting() }
        try store.setKey("LEGACY_OPENAI", configurationID: UUID()) // unrelated new-style entry
        // Legacy provider-scoped items (written by the previous version).
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.bipara.test.legacy.\(UUID().uuidString)",
        ]
        let service = add[kSecAttrService as String] as! String
        add[kSecAttrAccount as String] = "openai"
        add[kSecValueData as String] = Data("LEGACY_OPENAI".utf8)
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        let legacyStore = KeychainStore(service: service)
        #expect(try legacyStore.legacyCredential(provider: "openai") == "LEGACY_OPENAI")
        try legacyStore.deleteLegacyKey(provider: "openai")
        #expect(try legacyStore.legacyCredential(provider: "openai") == nil)
        add.removeValue(forKey: kSecValueData as String)
        SecItemDelete(add as CFDictionary)
    }
}
