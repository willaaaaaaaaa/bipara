@testable import BiparaAppKit
import BiparaCore
import Foundation
import Testing

@MainActor
@Suite("Open model configuration")
struct OpenModelConfigurationTests {
    private func setup() -> (SettingsStore, ModelConfigurationRegressionTests.AuditingCredentials, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.open-model.\(UUID())")!
        let keys = ModelConfigurationRegressionTests.AuditingCredentials()
        return (SettingsStore(defaults: defaults, keychain: keys), keys, defaults)
    }

    private func record(_ effort: ModelEffort = .medium) -> ModelConfigurationRecord {
        .init(displayName: "Custom model", provider: "openai", profile: ModelAPIProtocol.openai.profile,
              modelID: "unknown-model-2027", effort: effort, baseURL: "https://gateway.example.com/api/v3/",
              vendorLabel: "A new vendor", requestOptions: ModelRequestOptions(), revision: UUID())
    }

    @Test func arbitraryVendorModelAndAllFourEffortsPersist() throws {
        for effort in ModelEffort.editable {
            let (store, keys, defaults) = setup()
            let custom = record(effort)
            store.updateDraft { $0.modelConfigurations.append(custom) }
            try store.saveDraft()
            let reloaded = SettingsStore(defaults: defaults, keychain: keys)
            #expect(reloaded.configuration(custom.id) == custom)
            #expect(reloaded.configuration(custom.id)?.vendorName == "A new vendor")
        }
        #expect(ModelEffort.editable == [.off, .low, .medium, .high])
    }

    @Test(arguments: ModelAPIProtocol.allCases)
    func customConfigurationWithoutVendorLabelSavesAndReloads(api: ModelAPIProtocol) throws {
        let (store, keys, defaults) = setup()
        var custom = record()
        custom.vendorLabel = nil
        custom.provider = api.rawValue
        custom.profile = api.profile
        custom.requestOptions?.authentication = api == .anthropic ? .apiKey : .bearer
        store.updateDraft {
            $0.modelConfigurations.append(custom)
            $0.defaultModelConfigurationID = custom.id
        }
        store.setKeyDraft(.set("SYNTHETIC_CUSTOM_KEY"), configurationID: custom.id)
        try store.saveDraft()
        #expect(!store.hasDraftChanges)

        let reloaded = SettingsStore(defaults: defaults, keychain: keys)
        #expect(reloaded.record.defaultConfiguration == custom)
        #expect(try reloaded.resolveCredential(custom.runtimeBinding) == "SYNTHETIC_CUSTOM_KEY")
        let writes = keys.writes.count
        reloaded.updateDraft { $0.appearance = .dark }
        try reloaded.saveDraft()
        #expect(reloaded.configuration(custom.id) == custom)
        #expect(keys.writes.count == writes)
    }

    @Test func invalidRetainedVendorLabelFailsBeforeCredentialWrites() throws {
        for label in ["", "Vendor\nName", String(repeating: "x", count: 129)] {
            let (store, keys, defaults) = setup()
            let committed = store.record
            var custom = record()
            custom.vendorLabel = label
            store.updateDraft { $0.modelConfigurations.append(custom) }
            store.setKeyDraft(.set("SYNTHETIC_CUSTOM_KEY"), configurationID: custom.id)
            #expect(throws: SettingsStore.SettingsError.self) { try store.saveDraft() }
            #expect(store.record == committed)
            #expect(SettingsStore(defaults: defaults, keychain: keys).record == committed)
            #expect(keys.writes.isEmpty)
            #expect(store.hasDraftChanges)
        }
    }

    @Test func vendorRenameKeepsKeyButFullURLAndAuthenticationChangesInvalidateIt() throws {
        let (store, keys, _) = setup()
        var custom = record()
        store.updateDraft { $0.modelConfigurations = [custom]; $0.defaultModelConfigurationID = custom.id }
        store.setKeyDraft(.set("SYNTHETIC_OPEN_KEY"), configurationID: custom.id)
        try store.saveDraft()
        let frozen = custom.runtimeBinding
        custom.vendorLabel = "Renamed display label"
        store.updateDraft { $0.modelConfigurations = [custom] }
        try store.saveDraft()
        #expect(try store.resolveCredential(frozen) == "SYNTHETIC_OPEN_KEY")
        custom.requestOptions?.endpointURL = "https://different.example.com/invoke"
        store.updateDraft { $0.modelConfigurations = [custom] }
        try store.saveDraft()
        #expect(!keys.hasKey(configurationID: custom.id))
        #expect(throws: SettingsStore.SettingsError.configurationUnavailable) { try store.resolveCredential(frozen) }
        store.setKeyDraft(.set("SYNTHETIC_NEW_KEY"), configurationID: custom.id)
        try store.saveDraft()
        let endpointBinding = custom.runtimeBinding
        custom.requestOptions?.authentication = .custom
        custom.requestOptions?.headerName = "X-Token"
        store.updateDraft { $0.modelConfigurations = [custom] }
        try store.saveDraft()
        #expect(!keys.hasKey(configurationID: custom.id))
        #expect(throws: SettingsStore.SettingsError.configurationUnavailable) { try store.resolveCredential(endpointBinding) }
    }

    @Test func frozenOptionsSurviveEditsAndPortableRevisionRequiresExactMatch() throws {
        let (store, _, _) = setup()
        var custom = record()
        custom.requestOptions?.extraBodyJSON = "{\"thinking\":{\"type\":\"disabled\"}}"
        store.updateDraft { $0.modelConfigurations = [custom]; $0.defaultModelConfigurationID = custom.id }
        store.setKeyDraft(.set("SYNTHETIC_KEY"), configurationID: custom.id)
        try store.saveDraft()
        let frozen = custom.runtimeBinding
        let snapshot = JobSnapshot(jobID: UUID(), sourceRevision: 0, sourceLanguage: .en, targetLanguage: .zh,
            provider: custom.provider, model: custom.modelID, profile: custom.profile, effort: custom.effort,
            translationPromptVersion: "translation.v2", alignmentPromptVersion: "alignment.v1", configurationRevision: custom.revision)
        #expect(store.matchingConfigurations(for: snapshot).map(\.id) == [custom.id])
        custom.requestOptions?.translationTokens = 5000
        store.updateDraft { $0.modelConfigurations = [custom] }
        try store.saveDraft()
        #expect(store.configuration(custom.id)?.revision != custom.revision)
        #expect(try store.resolveCredential(frozen) == "SYNTHETIC_KEY")
        #expect(frozen.requestOptions?.translationTokens == 16384)
        #expect(store.matchingConfigurations(for: snapshot).isEmpty)
    }

    @Test func credentialsAndHeadersStayOutsidePreferences() throws {
        let (store, keys, defaults) = setup()
        let custom = record()
        let secret = try ModelCredentials(apiKey: "SYNTHETIC_KEY", headers: ["X-Tenant": "SYNTHETIC_HEADER"]).encoded()
        store.updateDraft { $0.modelConfigurations = [custom]; $0.defaultModelConfigurationID = custom.id }
        store.setKeyDraft(.set(secret), configurationID: custom.id)
        try store.saveDraft()
        #expect(try ModelCredentials.decode(store.resolveCredential(custom.runtimeBinding)).headers == ["X-Tenant": "SYNTHETIC_HEADER"])
        let encoded = String(decoding: try JSONEncoder().encode(store.record), as: UTF8.self)
        #expect(!encoded.contains("SYNTHETIC_KEY") && !encoded.contains("SYNTHETIC_HEADER"))
        let reloaded = SettingsStore(defaults: defaults, keychain: keys)
        #expect(try reloaded.resolveCredential(custom.runtimeBinding) == secret)
    }

    @Test func restoringCommittedOptionsRestoresTheirRevision() throws {
        let (store, _, _) = setup()
        let original = try #require(store.record.defaultConfiguration)
        store.updateDraft {
            $0.modelConfigurations[0].requestOptions?.translationTokens = 1000
            $0.modelConfigurations[0].revision = UUID()
        }
        store.updateDraft { $0.modelConfigurations[0].requestOptions = original.requestOptions }
        try store.saveDraft()
        #expect(store.configuration(original.id)?.revision == original.revision)
        #expect(!store.hasDraftChanges)
    }

    @Test func credentialDraftRestorationUsesProtocolAndFullURL() throws {
        let custom = record()
        var changed = custom
        changed.requestOptions?.endpointURL = "https://changed.example.com/invoke"
        let decision = ConfigurationSheet.stagedKeyChange(existing: custom, keyEdit: .inherit, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: custom.baseURL,
            currentCredentialIdentity: changed.credentialIdentity, committedCredentialIdentity: custom.credentialIdentity)
        #expect(decision == .clearForEndpointChange)
        let restored = ConfigurationSheet.stagedKeyChange(existing: changed, keyEdit: .inherit, keyField: "",
            keyEnteredForCanonicalURL: nil, currentCanonicalURL: custom.baseURL,
            settingsStagedChange: decision, currentCredentialIdentity: custom.credentialIdentity,
            committedCredentialIdentity: custom.credentialIdentity)
        #expect(restored == nil)
    }

    @Test func legacySettingsSaveDoesNotMigrateOrResetCredentials() throws {
        let (store, keys, defaults) = setup()
        store.updateDraft { $0 = LegacyModelFixture.record() }
        try store.saveDraft()
        let old = store.record.modelConfigurations
        for model in old { try keys.setKey("SYNTHETIC_LEGACY_KEY", configurationID: model.id) }
        store.updateDraft { $0.appearance = .dark }
        try store.saveDraft()
        #expect(store.record.modelConfigurations == old)
        #expect(SettingsStore(defaults: defaults, keychain: keys).record.modelConfigurations == old)
        #expect(old.allSatisfy { keys.hasKey(configurationID: $0.id) })
    }

    @Test func noAuthenticationCanDispatchWithoutKey() throws {
        let (store, _, _) = setup()
        var custom = record()
        custom.requestOptions?.authentication = ModelAuthentication.none
        store.updateDraft { $0.modelConfigurations = [custom]; $0.defaultModelConfigurationID = custom.id }
        try store.saveDraft()
        #expect(try store.resolveCredential(custom.runtimeBinding).isEmpty)
    }

    @Test func taskFieldsDuplicateJSONAndHeaderInjectionAreRejected() throws {
        for json in ["[]", "{\"model\":\"other\"}", "{\"a\":1,\"a\":2}", "{\"output_config\":{\"format\":{}}}", "{\"output_config\":null}", "{\"a\":NaN}"] {
            var options = ModelRequestOptions()
            options.extraBodyJSON = json
            #expect(throws: (any Error).self) { try options.validate(protocol: .openai) }
        }
        for json in ["{\"Host\":\"other\"}", "{\"X-Key\":\"line\\r\\nvalue\"}", "{\"X-Key\":\"a\",\"x-key\":\"b\"}"] {
            #expect(throws: (any Error).self) { try ModelCredentials.parseHeaders(json) }
        }
    }
}

/// Frozen old-install data for migration and retained-job regressions.
@MainActor enum LegacyModelFixture {
    static func record() -> PreferencesRecord {
        PreferencesRecord(modelConfigurations: [
            ModelConfigurationRecord(displayName: "OpenAI", provider: "openai", profile: ModelProfileID.openaiV2,
                modelID: "gpt-4.1-mini-2025-04-14", effort: .auto, baseURL: WorkerContract.openAIStandardBaseURL),
            ModelConfigurationRecord(displayName: "GLM", provider: "glm", profile: ModelProfileID.glmV2,
                modelID: "glm-4.7-flash", effort: .off, baseURL: WorkerContract.glmStandardBaseURL),
        ])
    }
    static func install(_ defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(record()), forKey: SettingsStore.defaultsKey)
    }
}
