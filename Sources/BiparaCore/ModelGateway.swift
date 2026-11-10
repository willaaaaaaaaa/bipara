import Foundation

/// The only Swift-to-model seam, per the technical design. The real
/// adapter owns child-process and credential transport details; a fixture
/// adapter supplies deterministic tests. Neither exposes `Process`, JSON
/// dictionaries, or LangChain objects to document logic.
public protocol ModelGateway: Sendable {
    /// Translate one bounded batch of units. Cancelling the calling task
    /// sends protocol cancellation; the caller resumes with
    /// `CancellationError` while the physical operation drains.
    func translateBatch(
        _ request: TranslateBatchRequest,
        configuration: ModelConfiguration
    ) async throws -> TranslateBatchResult

    /// Analyze a committed selection against the existing counterpart
    /// translation. Uses the document's job snapshot configuration.
    func alignSelection(
        _ request: AlignSelectionRequest,
        configuration: ModelConfiguration
    ) async throws -> AlignSelectionResult

    /// Graceful shutdown for app quit: send `shutdown`, close stdin, stop
    /// accepting work, and reap the child with the documented escalation.
    func shutdown() async
}

/// Provider/model/profile/effort plus the canonical endpoint and the
/// credential for one dispatch. The app layer reads the key from
/// Keychain per dispatched operation; the gateway never stores it.
public struct ModelConfiguration: Sendable, Equatable {
    public var provider: String
    public var model: String
    public var profile: String
    public var baseURL: String
    public var effort: ModelEffort
    public var apiKey: String
    public var requestOptions: ModelRequestOptions?
    public var secretHeaders: [String: String]
    /// In-memory admission identity. It is not part of the worker request.
    public var configurationID: UUID?

    public init(
        provider: String,
        model: String,
        profile: String,
        baseURL: String,
        effort: ModelEffort,
        apiKey: String,
        configurationID: UUID? = nil,
        requestOptions: ModelRequestOptions? = nil,
        secretHeaders: [String: String] = [:]
    ) {
        self.provider = provider
        self.model = model
        self.profile = profile
        self.baseURL = baseURL
        self.effort = effort
        self.apiKey = apiKey
        self.configurationID = configurationID
        self.requestOptions = requestOptions
        self.secretHeaders = secretHeaders
    }
}

/// One unit of a translation dispatch batch.
public struct TranslateBatchUnit: Sendable, Equatable {
    public var unitID: UUID
    public var kind: UnitKind
    public var text: String

    public init(unitID: UUID, kind: UnitKind, text: String) {
        self.unitID = unitID
        self.kind = kind
        self.text = text
    }
}

public struct TranslateBatchRequest: Sendable, Equatable {
    /// Local scheduling identity, never serialized to the Python/model input.
    public var ownerSessionID: UUID?
    /// Local deadline for waiting through a shared GLM cooldown on replay.
    public var rateLimitReplayDeadline: ContinuousClock.Instant?
    /// Frozen job version; retries and resumed legacy jobs retain it.
    public var promptVersion: String
    public var sourceLanguage: Language
    public var targetLanguage: Language
    public var contextBefore: String
    public var contextAfter: String
    public var units: [TranslateBatchUnit]

    public init(
        sourceLanguage: Language,
        targetLanguage: Language,
        contextBefore: String,
        contextAfter: String,
        units: [TranslateBatchUnit], ownerSessionID: UUID? = nil,
        promptVersion: String = WorkerContract.currentTranslationPromptVersion
    ) {
        self.ownerSessionID = ownerSessionID
        self.promptVersion = promptVersion
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.units = units
    }
}

public struct TranslateBatchResult: Sendable, Equatable {
    public struct UnitTranslation: Sendable, Equatable {
        public var unitID: UUID
        public var text: String

        public init(unitID: UUID, text: String) {
            self.unitID = unitID
            self.text = text
        }
    }

    public var translations: [UnitTranslation]
    public var meta: GatewayMeta

    public init(translations: [UnitTranslation], meta: GatewayMeta) {
        self.translations = translations
        self.meta = meta
    }
}

public struct AlignSelectionRequest: Sendable, Equatable {
    public var readingText: String
    public var counterpartText: String
    public var before: String
    public var selectedText: String
    public var after: String

    public init(
        readingText: String,
        counterpartText: String,
        before: String,
        selectedText: String,
        after: String
    ) {
        self.readingText = readingText
        self.counterpartText = counterpartText
        self.before = before
        self.selectedText = selectedText
        self.after = after
    }
}

public struct AlignSelectionResult: Sendable, Equatable {
    public struct PhraseMatch: Sendable, Equatable {
        public var quote: String
        public var occurrence: Int

        public init(quote: String, occurrence: Int) {
            self.quote = quote
            self.occurrence = occurrence
        }
    }

    public enum Match: Sendable, Equatable {
        case matched(matches: [PhraseMatch])
        case noMatch(reason: String)
    }

    public var match: Match
    public var meta: GatewayMeta

    public init(match: Match, meta: GatewayMeta) {
        self.match = match
        self.meta = meta
    }
}

/// Attribution returned with every terminal result. Token usage may be
/// unavailable and is then nil — never zero or invented.
public struct GatewayMeta: Sendable, Equatable {
    public var provider: String
    public var requestedModel: String
    /// Canonical requested effort echoed by the worker, including Auto;
    /// it is not a claim about measured provider reasoning.
    public var requestedEffort: ModelEffort
    public var returnedModel: String?
    public var promptVersion: String
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(
        provider: String,
        requestedModel: String,
        requestedEffort: ModelEffort,
        returnedModel: String?,
        promptVersion: String,
        inputTokens: Int?,
        outputTokens: Int?
    ) {
        self.provider = provider
        self.requestedModel = requestedModel
        self.requestedEffort = requestedEffort
        self.returnedModel = returnedModel
        self.promptVersion = promptVersion
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Typed gateway failures. Codes mirror the worker protocol's error table
/// plus the local lifecycle failures the design assigns to the adapter.
public struct GatewayError: Error, Sendable, Equatable {
    public enum Code: String, Sendable {
        // Worker-reported, per-request errors.
        case invalidRequest = "invalid_request"
        case unsupportedCapability = "unsupported_capability"
        case missingCredential = "missing_credential"
        case authentication = "authentication"
        case modelUnavailable = "model_unavailable"
        case quotaExceeded = "quota_exceeded"
        case rateLimited = "rate_limited"
        case network = "network"
        case timeout = "timeout"
        case contextLimit = "context_limit"
        case outputLimit = "output_limit"
        case refused = "refused"
        case invalidOutput = "invalid_output"
        case busy = "busy"
        case workerFailed = "worker_failed"
        // Local lifecycle failures.
        case executableMissing
        case startupFailed
        case incompatibleWorker
        case workerDied
        case watchdogExpired
        case shuttingDown
        /// Local missing/deleted/changed model configuration: the saved
        /// entry no longer exists at the snapshot Base URL. Raised before
        /// worker dispatch, never a Python wire error.
        case configurationUnavailable = "configuration_unavailable"
    }

    public enum ValidationFailure: String, Sendable {
        case missingContent = "missing_content"
        case invalidJSON = "invalid_json"
        case translationShape = "translation_shape"
        case unitMismatch = "unit_mismatch"
        case invalidTranslationText = "invalid_translation_text"
        case outputTooLarge = "output_too_large"
        case alignmentShape = "alignment_shape"
    }

    // Keep in sync with the worker. The provider's code field is untrusted.
    private static let providerCodes: Set<String> = [
        "401", "1000", "1001", "1003", "1005", "1113", "1200",
        "1210", "1211", "1212", "1213", "1214", "1215",
        "1220", "1221", "1222", "1230", "1234", "1261",
        "1301", "1302", "1305", "1308", "1309", "1310", "1311", "1313",
        "1314", "1315", "1316", "1317", "1318", "1319", "1320", "1321",
        "invalid_api_key", "model_not_found", "context_length_exceeded",
        "invalid_request_error", "insufficient_quota", "rate_limit_exceeded",
        "credit_balance_exhausted", "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded", "organization_usage_limit_exceeded",
        "slow_down", "server_is_overloaded",
    ]

    public var code: Code
    public let httpStatus: Int?
    public let providerCode: String?
    public let validationFailure: ValidationFailure?

    public func glmCooldown(provider: String) -> Duration? {
        guard !isLocal, provider == "glm", code == .rateLimited, httpStatus == 429,
              providerCode == "1302" || providerCode == "1305" else { return nil }
        return retryAfterMS.map { .milliseconds($0) } ?? WorkerContract.glmDefaultCooldown
    }
    /// Milliseconds after which a retry may be enabled; nil when unknown.
    public var retryAfterMS: Int?
    /// True when the physical operation never reached the worker.
    public var isLocal: Bool

    public init(
        code: Code, retryAfterMS: Int? = nil, isLocal: Bool = false,
        httpStatus: Int? = nil, providerCode: String? = nil,
        validationFailure: ValidationFailure? = nil
    ) {
        self.code = code
        self.retryAfterMS = retryAfterMS
        self.isLocal = isLocal
        self.httpStatus = httpStatus.flatMap { (300...599).contains($0) ? $0 : nil }
        self.providerCode = providerCode.flatMap { Self.providerCodes.contains($0) ? $0 : nil }
        self.validationFailure = validationFailure
    }
}
