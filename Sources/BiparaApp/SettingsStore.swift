import BiparaCore
import Foundation

/// Interface language for app chrome only; document text and translation
/// direction are unaffected.
public enum InterfaceLanguage: String, Codable, Sendable, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

/// System-default appearance with explicit Light/Dark overrides.
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

public enum ReadingWidth: String, Codable, Sendable, CaseIterable {
    case standard, wide, window
}

public enum CorrespondenceColor: String, Codable, Sendable, CaseIterable {
    case blue, teal, amber, purple

    public static let defaultPreset: Self = .amber
}

/// Reading typography shared across all tabs.
public struct ReadingTypography: Codable, Sendable, Equatable {
    public enum Family: String, Codable, Sendable, CaseIterable {
        case system
        case serif
    }

    public enum LineHeight: String, Codable, Sendable, CaseIterable {
        case compact = "1.45"
        case comfortable = "1.70"
        case spacious = "1.95"
    }

    public var family: Family
    /// Reading text size in points; 14...28, default 17.
    public var size: Double
    public var lineHeight: LineHeight

    public init(family: Family = .system, size: Double = 17, lineHeight: LineHeight = .comfortable) {
        self.family = family
        self.size = size
        self.lineHeight = lineHeight
    }
}

/// Fresh-install seeding retains the two existing baseline models with
/// separate IDs and no credentials; new configurations use v2 profiles.
public func defaultModelConfigurations() -> [ModelConfigurationRecord] {
    [
        ModelConfigurationRecord(
            displayName: "OpenAI",
            provider: "openai",
            profile: ModelProfileID.openaiV2,
            modelID: WorkerContract.defaultModels["openai"]!,
            effort: .auto,
            baseURL: WorkerContract.openAIStandardBaseURL),
        ModelConfigurationRecord(
            displayName: "GLM",
            provider: "glm",
            profile: ModelProfileID.glmV2,
            modelID: WorkerContract.defaultModels["glm"]!,
            effort: .off,
            baseURL: WorkerContract.glmStandardBaseURL),
    ]
}

/// The single versioned preferences record persisted in UserDefaults
/// (schema 2). Layout is per-document and deliberately not part of
/// preferences.
public struct PreferencesRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var interfaceLanguage: InterfaceLanguage
    public var appearance: AppearanceMode
    public var typography: ReadingTypography
    public var modelConfigurations: [ModelConfigurationRecord]
    public var defaultModelConfigurationID: UUID?
    public var preferredTranslationDirection: Direction?
    public var preferredReadingWidth: ReadingWidth?
    public var preferredCorrespondenceColor: CorrespondenceColor?
    public var skipDocumentSavePrompt: Bool?

    public var translationDirection: Direction { preferredTranslationDirection ?? .auto }
    public var readingWidth: ReadingWidth { preferredReadingWidth ?? .wide }
    public var correspondenceColor: CorrespondenceColor { preferredCorrespondenceColor ?? .defaultPreset }
    public var dontAskToSaveOnClose: Bool { skipDocumentSavePrompt ?? false }

    public init(
        schemaVersion: Int = 2,
        interfaceLanguage: InterfaceLanguage = .english,
        appearance: AppearanceMode = .system,
        typography: ReadingTypography = ReadingTypography(),
        modelConfigurations: [ModelConfigurationRecord] = defaultModelConfigurations(),
        defaultModelConfigurationID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.interfaceLanguage = interfaceLanguage
        self.appearance = appearance
        self.typography = typography
        self.modelConfigurations = modelConfigurations
        self.defaultModelConfigurationID = defaultModelConfigurationID ?? modelConfigurations.first?.id
    }

    public func configuration(id: UUID) -> ModelConfigurationRecord? {
        modelConfigurations.first { $0.id == id }
    }

    public var defaultConfiguration: ModelConfigurationRecord? {
        defaultModelConfigurationID.flatMap { configuration(id: $0) }
    }
}

/// The v1 provider-keyed record shape, read only by migration.
private struct LegacyPreferencesRecordV1: Codable, Equatable {
    struct Provider: Codable, Equatable {
        var model: String
    }

    var schemaVersion: Int?
    var interfaceLanguage: InterfaceLanguage?
    var appearance: AppearanceMode?
    var typography: ReadingTypography?
    var defaultProvider: String?
    var providers: [String: Provider]?
}

/// A blocking load or migration failure. The preserved record (corrupt or
/// newer v2) or the original v1 data stays authoritative; ordinary Save is
/// refused until the failure is resolved. A failed migration can be
/// retried after its underlying cause (for example a transient Keychain
/// failure) is resolved.
public struct SettingsLoadFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A v2 record exists but is corrupt or from a newer schema. Data
        /// is preserved; this build refuses to interpret or overwrite it.
        case corruptOrNewerRecord
        /// The one-time v1→v2 migration failed and was rolled back; v1
        /// remains authoritative and readable. Retrying re-runs only the
        /// migration.
        case migrationFailed
    }

    public let kind: Kind
    /// Localization key the UI surfaces verbatim through `t()`.
    public let messageKey: String

    public init(kind: Kind, messageKey: String) {
        self.kind = kind
        self.messageKey = messageKey
    }
}

/// MainActor observable settings state with an explicit draft: Save
/// validates and commits the whole draft atomically; Cancel discards it.
/// Keychain writes are coordinated by the owner before commit (see the
/// technical design's persistence-transaction rules). Credential reads
/// for model dispatch are serialized on this actor so they can never
/// observe a half-applied draft.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let defaultsKey = "dev.bipara.preferences.v2"
    public static let legacyDefaultsKey = "dev.bipara.preferences.v1"
    /// UserDefaults marker listing provider-scoped legacy keys whose
    /// deletion is still pending after a successful migration (S4); the
    /// retry never re-runs the migration or recopies credentials.
    public static let pendingLegacyCleanupKey = "dev.bipara.preferences.pendingLegacyCleanup"
    public static let schemaVersion = 2

    // Localization keys for load/maintenance outcomes (surfaced via t()).
    public static let messageCorruptOrNewer = "settings.load.corruptNewer"
    public static let messageMigrationFailed = "settings.load.migrationFailed"
    public static let messageMigrationCompensation = "settings.load.migrationCompensation"
    public static let messageCleanupResidue = "settings.maintenance.cleanupResidue"

    /// Draft intent is separate from the eventual Keychain mutation: only
    /// endpoint-driven clearing is undone automatically on URL restoration.
    public enum KeyDraftChange: Equatable {
        case set(String)
        case delete
        case clearForEndpointChange
    }

    @Published public private(set) var record: PreferencesRecord
    @Published public private(set) var draft: PreferencesRecord
    @Published public private(set) var keyDrafts: [UUID: KeyDraftChange] = [:]
    /// Blocking load/migration failure: preserved data stays authoritative
    /// and ordinary Save is refused (never silently reset).
    @Published public private(set) var loadFailure: SettingsLoadFailure?
    /// Non-fatal outcomes the UI should surface (for example residual
    /// legacy-key cleanup that will be retried automatically).
    @Published public private(set) var maintenanceNotice: String?
    public var hasDraftChanges: Bool { draft != record || !keyDrafts.isEmpty }

    private var hasDraftModelSelection = false
    private let defaults: UserDefaults
    private let keychain: (any CredentialStore)?

    public init(
        defaults: UserDefaults = .standard,
        keychain: (any CredentialStore)? = nil,
        record: PreferencesRecord? = nil
    ) {
        self.defaults = defaults
        self.keychain = keychain
        if let record {
            self.record = record
            draft = record
            return
        }
        let loaded = Self.loadOrMigrate(defaults: defaults, keychain: keychain)
        let initial = loaded.record
        self.record = initial
        draft = initial
        applyMaintenanceOutcome(loaded)
        if loaded.persistFreshSeed {
            persist(initial)
        }
    }

    /// Applies the non-record parts of a load outcome (failure state and
    /// pending-cleanup persistence).
    private func applyMaintenanceOutcome(_ loaded: LoadOutcome) {
        loadFailure = loaded.loadFailure
        maintenanceNotice = loaded.maintenanceNotice
        if loaded.persistPendingCleanup {
            defaults.set(loaded.pendingCleanupProviders, forKey: Self.pendingLegacyCleanupKey)
        } else if loaded.clearPendingCleanup {
            defaults.removeObject(forKey: Self.pendingLegacyCleanupKey)
        }
    }

    /// Re-runs only the v1→v2 migration after a failed attempt. Safe to
    /// call repeatedly; a still-failing migration keeps the same blocked
    /// state and preserved data. No-op for corrupt/newer-record failures
    /// and after a successful load.
    public func retryMigration() {
        guard loadFailure?.kind == .migrationFailed else { return }
        let loaded = Self.loadOrMigrate(defaults: defaults, keychain: keychain)
        record = loaded.record
        draft = loaded.record
        hasDraftModelSelection = false
        keyDrafts = [:]
        applyMaintenanceOutcome(loaded)
        if loaded.persistFreshSeed {
            persist(loaded.record)
        }
    }

    // MARK: Draft

    public func updateDraft(_ change: (inout PreferencesRecord) -> Void) {
        let priorID = draft.defaultModelConfigurationID
        change(&draft)
        if priorID != draft.defaultModelConfigurationID {
            hasDraftModelSelection = draft.defaultModelConfigurationID != record.defaultModelConfigurationID
        }
    }

    public func selectActiveModel(_ id: UUID) throws {
        guard loadFailure == nil, record.configuration(id: id) != nil else {
            throw SettingsError.configurationUnavailable
        }
        let previous = record
        guard id != previous.defaultModelConfigurationID else { return }
        var updated = previous
        updated.defaultModelConfigurationID = id
        let encoded = try JSONEncoder().encode(updated)
        defaults.set(encoded, forKey: Self.defaultsKey)
        guard defaults.data(forKey: Self.defaultsKey) == encoded else {
            persist(previous)
            throw SettingsError.invalidField("Active Model")
        }
        if draft.configuration(id: id) == nil {
            // The toolbar picked an entry the draft no longer contains (a
            // staged deletion): the draft's active field is unset so Save
            // demands a replacement. This reset is reconciliation output,
            // not an explicit Settings edit — a later toolbar selection of
            // an entry the draft still contains refreshes the field.
            draft.defaultModelConfigurationID = nil
        } else if !hasDraftModelSelection {
            draft.defaultModelConfigurationID = id
        }
        record = updated
    }

    /// The credential edit staged for one configuration. A URL change in
    /// the editor supersedes an inherited key (see the editor contract);
    /// explicit Replace/Delete survives a restored URL.
    public func setKeyDraft(_ change: KeyDraftChange?, configurationID: UUID) {
        keyDrafts[configurationID] = change
    }

    public func clearKeyDraft(configurationID: UUID) {
        keyDrafts[configurationID] = nil
    }

    public func cancelDraft() {
        draft = record
        hasDraftModelSelection = false
        keyDrafts = [:]
    }

    /// Removes a configuration from the draft (S2): a committed entry's
    /// Keychain item is deleted only through the next Save transaction,
    /// so Cancel leaves the Keychain unchanged; an entry added within the
    /// same draft was never committed and simply drops its staged key.
    public func removeConfigurationFromDraft(id: UUID, replacement: UUID?) {
        let committed = record.configuration(id: id) != nil
        updateDraft { draft in
            draft.modelConfigurations.removeAll { $0.id == id }
            if draft.defaultModelConfigurationID == id {
                draft.defaultModelConfigurationID = replacement
            }
        }
        if committed {
            setKeyDraft(.delete, configurationID: id)
        } else {
            clearKeyDraft(configurationID: id)
        }
    }

    /// Commits the draft as one record. Prepared Keychain writes happen
    /// first; a Keychain failure aborts the whole save and compensates
    /// attempted writes so no half-applied preferences draft persists.
    /// A blocking load/migration failure refuses the save so preserved
    /// data can never be silently replaced by an unrelated edit.
    public func saveDraft() throws {
        if loadFailure != nil {
            // Never overwrite preserved corrupt/newer data or bypass a
            // failed migration with an unrelated edit.
            throw SettingsError.invalidField("stored preferences record")
        }
        try Self.validate(draft)
        var changes: [UUID: KeychainStore.KeychainChange] = [:]
        for (id, intent) in keyDrafts {
            switch intent {
            case .set(let key): changes[id] = .set(key)
            case .delete: changes[id] = .delete
            case .clearForEndpointChange:
                if record.configuration(id: id)?.baseURL != draft.configuration(id: id)?.baseURL
                    || record.configuration(id: id)?.provider != draft.configuration(id: id)?.provider {
                    changes[id] = .delete
                }
            }
        }
        for (id, change) in changes {
            if case .set(let key) = change, key.isEmpty || key.utf8.count > 4096 {
                throw SettingsError.invalidField("API key")
            }
            guard record.configuration(id: id) != nil || draft.configuration(id: id) != nil else {
                throw SettingsError.invalidField("model configuration")
            }
        }
        // Committed-endpoint credential rule (N1): an endpoint change can
        // never retain the old credential. Unless an explicit replacement
        // key is staged for the new endpoint, the committed key is deleted
        // in this same transaction — a staged-deletion cancel inside the
        // editor cannot make the old key travel to the new endpoint.
        for configuration in draft.modelConfigurations {
            guard let committed = record.configuration(id: configuration.id),
                  committed.baseURL != configuration.baseURL || committed.provider != configuration.provider else { continue }
            if case .set = changes[configuration.id] {} else {
                changes[configuration.id] = .delete
            }
        }
        if !changes.isEmpty {
            guard let keychain else { throw SettingsError.keychainFailure(underlying: "unavailable") }
            let ordered = changes.keys.sorted { $0.uuidString < $1.uuidString }
            var attempted: [(UUID, String?)] = []
            do {
                for id in ordered {
                    // Capture the previous value immediately before each
                    // write so compensation restores exactly what was
                    // replaced (absent stays absent).
                    attempted.append((id, try keychain.credential(configurationID: id)))
                    switch changes[id]! {
                    case .set(let value): try keychain.setKey(value, configurationID: id)
                    case .delete: try keychain.deleteKey(configurationID: id)
                    }
                }
            } catch {
                var compensationFailed = false
                for (id, previous) in attempted.reversed() {
                    do {
                        if let previous { try keychain.setKey(previous, configurationID: id) }
                        else { try keychain.deleteKey(configurationID: id) }
                    } catch { compensationFailed = true }
                }
                if compensationFailed { throw SettingsError.compensationFailed }
                throw SettingsError.keychainFailure(underlying: "credential write failed")
            }
        }
        persist(draft)
        record = draft
        hasDraftModelSelection = false
        keyDrafts = [:]
    }

    // MARK: Runtime credential resolution

    /// Resolves the frozen runtime binding to a dispatchable credential.
    /// Requires the saved configuration to still exist with the exact
    /// snapshot Base URL; a missing/changed entry is a local
    /// `configuration_unavailable`. Runs on this actor so it is serialized
    /// with Settings persistence transactions.
    public func resolveCredential(_ binding: RuntimeModelBinding) throws -> String {
        guard let configuration = record.configuration(id: binding.configurationID) else {
            throw SettingsError.configurationUnavailable
        }
        guard configuration.baseURL == binding.baseURL, configuration.provider == binding.provider else {
            throw SettingsError.configurationUnavailable
        }
        guard let keychain else { throw SettingsError.keychainFailure(underlying: "unavailable") }
        guard let key = try keychain.credential(configurationID: binding.configurationID),
              !key.isEmpty, key.utf8.count <= 4096 else {
            throw SettingsError.missingCredential
        }
        return key
    }

    /// Configurations matching a portable snapshot for explicit binding.
    public func matchingConfigurations(for snapshot: JobSnapshot) -> [ModelConfigurationRecord] {
        record.modelConfigurations.filter {
            $0.provider == snapshot.provider && $0.modelID == snapshot.model
                && $0.profile == snapshot.profile && $0.effort == snapshot.effort
        }
    }

    public func configuration(_ id: UUID) -> ModelConfigurationRecord? {
        record.configuration(id: id)
    }

    private func persist(_ record: PreferencesRecord) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Validation

    static func validate(_ draft: PreferencesRecord) throws {
        guard draft.schemaVersion == schemaVersion else {
            throw SettingsError.invalidField("schema version")
        }
        guard (14.0...28.0).contains(draft.typography.size) else {
            throw SettingsError.invalidField("reading size")
        }
        var seenNameEffort = Set<String>()
        for configuration in draft.modelConfigurations {
            guard WorkerContract.providers.contains(configuration.provider) else {
                throw SettingsError.invalidField("provider")
            }
            guard WorkerContract.profilesByProvider[configuration.provider]?.contains(configuration.profile) == true else {
                throw SettingsError.invalidField("profile")
            }
            let modelID = configuration.modelID
            guard !modelID.isEmpty,
                  modelID == modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                  !modelID.contains("\n"), !modelID.contains("\r"),
                  modelID.utf8.count <= 256 else {
                throw SettingsError.invalidField("model id")
            }
            if let displayName = configuration.displayName {
                let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed == displayName || trimmed.isEmpty || displayName.isEmpty,
                      !displayName.contains("\n"), !displayName.contains("\r"),
                      displayName.unicodeScalars.count <= 128 else {
                    throw SettingsError.invalidField("display name")
                }
            }
            guard case .success = CanonicalBaseURL.canonicalize(configuration.baseURL) else {
                throw SettingsError.invalidField("API Base URL")
            }
            if let legacyEffort = WorkerContract.legacyEffort(profile: configuration.profile) {
                guard configuration.baseURL == WorkerContract.legacyStandardBaseURL(provider: configuration.provider),
                      configuration.effort == legacyEffort else {
                    throw SettingsError.invalidField("legacy profile connection")
                }
            } else {
                guard ModelCapabilities.supports(configuration.effort, model: modelID, provider: configuration.provider) else {
                    throw SettingsError.invalidField("effort level")
                }
            }
            // Resolved display-name/effort pairs must be unique within the
            // draft, compared after trimming with case-insensitive names.
            let key = configuration.resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                + "\u{1F}" + configuration.effort.rawValue
            guard seenNameEffort.insert(key).inserted else {
                throw SettingsError.duplicateNameEffort
            }
        }
        if let defaultID = draft.defaultModelConfigurationID {
            guard draft.modelConfigurations.contains(where: { $0.id == defaultID }) else {
                throw SettingsError.invalidField("default model")
            }
        }
        if !draft.modelConfigurations.isEmpty, draft.defaultModelConfigurationID == nil {
            throw SettingsError.invalidField("default model")
        }
    }

    // MARK: Load and migration

    private struct LoadOutcome {
        var record: PreferencesRecord
        var loadFailure: SettingsLoadFailure?
        var maintenanceNotice: String?
        var persistFreshSeed = false
        /// Pending legacy-key cleanup state to persist for a later launch.
        var pendingCleanupProviders: [String] = []
        var persistPendingCleanup = false
        var clearPendingCleanup = false

        static func emptyRecord() -> PreferencesRecord {
            PreferencesRecord(modelConfigurations: [], defaultModelConfigurationID: nil)
        }
    }

    /// Loads the v2 record; performs the one-time v1→v2 migration when v2
    /// is absent. Migration is offline and never validates account
    /// entitlement with a network call. A failed legacy-credential read
    /// aborts the migration before any destructive cleanup, leaving v1
    /// authoritative (S1).
    private static func loadOrMigrate(
        defaults: UserDefaults,
        keychain: (any CredentialStore)?
    ) -> LoadOutcome {
        // A present v2 value of any type is authoritative evidence the key
        // exists: a present-but-non-Data value blocks (corrupt) instead of
        // being treated as absent and overwritten (N2).
        if defaults.object(forKey: defaultsKey) != nil {
            guard let data = defaults.data(forKey: defaultsKey) else {
                return LoadOutcome(record: LoadOutcome.emptyRecord(),
                                   loadFailure: SettingsLoadFailure(
                                       kind: .corruptOrNewerRecord, messageKey: messageCorruptOrNewer))
            }
            do {
                let record = try JSONDecoder().decode(PreferencesRecord.self, from: data)
                guard record.schemaVersion == schemaVersion else {
                    // Corrupt or newer: preserve data, do not fall back.
                    return LoadOutcome(record: LoadOutcome.emptyRecord(),
                                       loadFailure: SettingsLoadFailure(
                                           kind: .corruptOrNewerRecord, messageKey: messageCorruptOrNewer))
                }
                // Verified v2 load: retry any pending legacy-key cleanup
                // independently, without rerunning the migration (S4).
                var outcome = LoadOutcome(record: record, clearPendingCleanup: true)
                let pending = pendingCleanupProviders(from: defaults)
                if !pending.isEmpty {
                    if let keychain {
                        var remaining: [String] = []
                        for provider in pending {
                            do { try keychain.deleteLegacyKey(provider: provider) }
                            catch { remaining.append(provider) }
                        }
                        if remaining.isEmpty {
                            defaults.removeObject(forKey: pendingLegacyCleanupKey)
                        } else {
                            defaults.set(remaining, forKey: pendingLegacyCleanupKey)
                            outcome.clearPendingCleanup = false
                            outcome.maintenanceNotice = messageCleanupResidue
                        }
                    } else {
                        outcome.clearPendingCleanup = false
                    }
                }
                return outcome
            } catch {
                return LoadOutcome(record: LoadOutcome.emptyRecord(),
                                   loadFailure: SettingsLoadFailure(
                                       kind: .corruptOrNewerRecord, messageKey: messageCorruptOrNewer))
            }
        }
        guard let legacyData = defaults.data(forKey: legacyDefaultsKey) else {
            // Fresh install: seed and persist so configuration IDs stay
            // stable across launches from the very first run.
            return LoadOutcome(record: PreferencesRecord(), persistFreshSeed: true)
        }
        // One-time migration of a valid v1 record. Any failure is blocking
        // and retryable: v1 stays authoritative, Save is refused, and
        // nothing destructive has happened.
        func migrationFailed(_ messageKey: String = messageMigrationFailed) -> LoadOutcome {
            LoadOutcome(record: LoadOutcome.emptyRecord(),
                        loadFailure: SettingsLoadFailure(kind: .migrationFailed, messageKey: messageKey))
        }
        guard let legacy = try? JSONDecoder().decode(LegacyPreferencesRecordV1.self, from: legacyData) else {
            return migrationFailed()
        }
        guard let providers = legacy.providers, let defaultProvider = legacy.defaultProvider,
              WorkerContract.legacyProviders.contains(defaultProvider),
              WorkerContract.legacyProviders.allSatisfy({ providers[$0] != nil }) else {
            return migrationFailed()
        }
        var entries: [ModelConfigurationRecord] = []
        for provider in WorkerContract.legacyProviders {
            guard let model = providers[provider]?.model,
                  !model.trimmingCharacters(in: .whitespaces).isEmpty,
                  model.utf8.count <= 256 else {
                return migrationFailed()
            }
            // Preserve the old effective request profile and effort: OpenAI
            // v1 with Auto, GLM v1 with Off, original hardcoded Standard
            // API URL, and the exact existing model ID. No upgrades, no
            // Coding Plan, no recommended entries.
            let entry = ModelConfigurationRecord(
                id: UUID(),
                displayName: provider == "openai" ? "OpenAI" : "GLM",
                provider: provider,
                profile: WorkerContract.legacyProfiles[provider]!,
                modelID: model,
                effort: WorkerContract.legacyEffort(profile: WorkerContract.legacyProfiles[provider]!)!,
                baseURL: WorkerContract.legacyStandardBaseURL(provider: provider))
            entries.append(entry)
        }
        let defaultID = entries.first { $0.provider == defaultProvider }!.id

        // Stage independent configuration-scoped copies of the two legacy
        // provider-scoped Keychain items; a missing key stays missing. A
        // FAILED read (unlike a missing item) aborts the whole migration
        // before anything is persisted or cleaned up (S1).
        var stagedKeys: [(UUID, String)] = []
        if let keychain {
            for entry in entries {
                let legacyKey: String?
                do {
                    legacyKey = try keychain.legacyCredential(provider: entry.provider)
                } catch {
                    return migrationFailed()
                }
                if let legacyKey, !legacyKey.isEmpty {
                    stagedKeys.append((entry.id, legacyKey))
                }
            }
            do {
                for (id, key) in stagedKeys {
                    try keychain.setKey(key, configurationID: id)
                }
            } catch {
                // On failure compensate staged writes and leave v1
                // authoritative and readable; report compensation failures.
                var compensationFailed = false
                for (id, _) in stagedKeys {
                    do { try keychain.deleteKey(configurationID: id) } catch { compensationFailed = true }
                }
                return migrationFailed(compensationFailed ? messageMigrationCompensation : messageMigrationFailed)
            }
        }

        let migrated = PreferencesRecord(
            schemaVersion: schemaVersion,
            interfaceLanguage: legacy.interfaceLanguage ?? .english,
            appearance: legacy.appearance ?? .system,
            typography: legacy.typography ?? ReadingTypography(),
            modelConfigurations: entries,
            defaultModelConfigurationID: defaultID)

        // Persist, then read back the complete v2 record; only verified
        // persistence makes v2 authoritative.
        do {
            let data = try JSONEncoder().encode(migrated)
            defaults.set(data, forKey: defaultsKey)
            guard let readBack = defaults.data(forKey: defaultsKey),
                  try JSONDecoder().decode(PreferencesRecord.self, from: readBack) == migrated else {
                throw CocoaError(.coderInvalidValue)
            }
        } catch {
            defaults.removeObject(forKey: defaultsKey)
            var compensationFailed = false
            if let keychain {
                for (id, _) in stagedKeys {
                    do { try keychain.deleteKey(configurationID: id) } catch { compensationFailed = true }
                }
            }
            return migrationFailed(compensationFailed ? messageMigrationCompensation : messageMigrationFailed)
        }

        // Cleanup of superseded legacy keys/record only after verified v2
        // persistence; a cleanup failure records the minimum pending state
        // so a later launch retries only that cleanup — never the
        // migration, never new IDs, never credential copies (S4).
        var remainingProviders: [String] = []
        if let keychain {
            for provider in WorkerContract.legacyProviders {
                do { try keychain.deleteLegacyKey(provider: provider) }
                catch { remainingProviders.append(provider) }
            }
        }
        defaults.removeObject(forKey: legacyDefaultsKey)
        if remainingProviders.isEmpty {
            return LoadOutcome(record: migrated, clearPendingCleanup: true)
        }
        return LoadOutcome(
            record: migrated,
            maintenanceNotice: messageCleanupResidue,
            pendingCleanupProviders: remainingProviders,
            persistPendingCleanup: true)
    }

    private static func pendingCleanupProviders(from defaults: UserDefaults) -> [String] {
        guard let providers = defaults.stringArray(forKey: pendingLegacyCleanupKey) else { return [] }
        return providers.filter { WorkerContract.legacyProviders.contains($0) }
    }

    public enum SettingsError: Error, Equatable {
        case invalidField(String)
        case duplicateNameEffort
        case keychainFailure(underlying: String)
        case compensationFailed
        case missingCredential
        case configurationUnavailable
    }
}
