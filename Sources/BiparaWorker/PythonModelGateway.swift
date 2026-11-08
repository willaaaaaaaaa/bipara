import BiparaCore
import Foundation

/// Real `ModelGateway` adapter: one lazily launched bundled Python worker
/// child process over pipes, per docs/design/worker-protocol.md.
///
/// The adapter owns child-process transport only — launch, handshake
/// validation, frame codec, request registry with drain accounting,
/// cancellation, watchdog, shutdown escalation, and restart isolation.
/// Document logic never sees `Process` or wire dictionaries.
public final class PythonModelGateway: ModelGateway, @unchecked Sendable {
    private let manager: WorkerManager

    public init(
        executableURL: URL,
        expectedPromptVersions: [String] = WorkerContract.promptVersions,
        expectedMaxInflight: Int = WorkerContract.maxInflightOperations,
        maxRequestsPerOwner: Int = WorkerContract.translationBatchesPerSession,
        timeouts: GatewayTimeouts = GatewayTimeouts(),
        environment: @escaping @Sendable () -> [String: String] = PythonModelGateway.sanitizedWorkerEnvironment
    ) {
        manager = WorkerManager(
            executableURL: executableURL,
            expectedPromptVersions: expectedPromptVersions,
            expectedMaxInflight: expectedMaxInflight,
            maxRequestsPerOwner: maxRequestsPerOwner,
            timeouts: timeouts,
            environment: environment
        )
    }

    public func translateBatch(
        _ request: TranslateBatchRequest,
        configuration: ModelConfiguration
    ) async throws -> TranslateBatchResult {
        try Self.validate(configuration)
        let input: [String: Any] = [
            "source_language": request.sourceLanguage.rawValue, "target_language": request.targetLanguage.rawValue,
            "context_before": request.contextBefore, "context_after": request.contextAfter,
            "units": request.units.map { ["unit_id": $0.unitID.uuidString.lowercased(), "kind": $0.kind.rawValue, "text": $0.text] },
        ]
        guard WorkerContract.translationPromptVersions.contains(request.promptVersion),
              request.sourceLanguage != request.targetLanguage,
              (1...WorkerContract.maxUnitsPerBatch).contains(request.units.count),
              Set(request.units.map(\.unitID)).count == request.units.count,
              request.units.allSatisfy({ !$0.text.isEmpty && $0.text.isContractTrimmed && $0.text.utf8.count <= WorkerContract.maxSentenceUTF8Bytes }),
              request.units.reduce(0, { $0 + $1.text.utf8.count }) <= WorkerContract.maxBatchTextBytes,
              request.contextBefore.utf8.count <= WorkerContract.maxContextBytes,
              request.contextAfter.utf8.count <= WorkerContract.maxContextBytes,
              try JSONSerialization.data(withJSONObject: input).count <= WorkerContract.maxInputJSONBytes else { throw GatewayError(code: .invalidRequest, isLocal: true) }
        let payload = try Self.wirePayload(try await manager.perform(
            owner: request.ownerSessionID, route: GLMRoute(configuration),
            isTranslation: true, replayDeadline: request.rateLimitReplayDeadline
        ) { instance, requestID in
            instance.sendTranslate(request, configuration: configuration, requestID: requestID)
        })
        return try Self.mapTranslate(payload, requestedUnits: request.units, configuration: configuration,
                                     promptVersion: request.promptVersion)
    }

    public func alignSelection(
        _ request: AlignSelectionRequest,
        configuration: ModelConfiguration
    ) async throws -> AlignSelectionResult {
        try Self.validate(configuration)
        let input: [String: Any] = ["reading_text": request.readingText, "counterpart_text": request.counterpartText,
            "selection": ["before": request.before, "text": request.selectedText, "after": request.after]]
        guard !request.selectedText.isEmpty, request.selectedText.utf8.count <= WorkerContract.maxAlignSelectionBytes,
              request.readingText.utf8.count + request.counterpartText.utf8.count <= WorkerContract.maxAlignTextBytes,
              TextIdentity.equal(request.before + request.selectedText + request.after, request.readingText),
              try JSONSerialization.data(withJSONObject: input).count <= WorkerContract.maxInputJSONBytes else {
            throw GatewayError(code: .invalidRequest, isLocal: true)
        }
        let payload = try Self.wirePayload(try await manager.perform(route: GLMRoute(configuration)) { instance, requestID in
            instance.sendAlign(request, configuration: configuration, requestID: requestID)
        })
        return try Self.mapAlign(payload, configuration: configuration, counterpart: request.counterpartText)
    }

    func diagnostics() async -> (slots: Int, waiting: Int) { await manager.diagnostics() }

    public func shutdown() async {
        await manager.shutdown()
    }

    private static func validate(_ configuration: ModelConfiguration) throws {
        guard !configuration.apiKey.isEmpty else { throw GatewayError(code: .missingCredential, isLocal: true) }
        guard configuration.apiKey.utf8.count <= 4096, !configuration.model.isEmpty,
              configuration.model == configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
              configuration.model.utf8.count <= 256,
              WorkerContract.providers.contains(configuration.provider),
              WorkerContract.profilesByProvider[configuration.provider]?.contains(configuration.profile) == true else {
            throw GatewayError(code: .invalidRequest, isLocal: true)
        }
        guard ModelEffort(rawValue: configuration.effort.rawValue) != nil,
              CanonicalBaseURL.isValid(configuration.baseURL) else {
            throw GatewayError(code: .invalidRequest, isLocal: true)
        }
        if let legacyEffort = WorkerContract.legacyEffort(profile: configuration.profile) {
            // A legacy profile accepts only its original Standard API URL
            // and effective effort.
            guard configuration.baseURL == WorkerContract.legacyStandardBaseURL(provider: configuration.provider),
                  configuration.effort == legacyEffort else {
                throw GatewayError(code: .invalidRequest, isLocal: true)
            }
        }
    }

    // MARK: - Wire payload mapping

    /// A terminal `result` frame split into its strict data/meta objects.
    struct WirePayload {
        var data: [String: Any]
        var meta: [String: Any]
    }

    static func wirePayload(_ terminal: WireTerminal) throws -> WirePayload {
        guard let data = (try? JSONSerialization.jsonObject(with: terminal.dataJSON)) as? [String: Any],
              let meta = (try? JSONSerialization.jsonObject(with: terminal.metaJSON)) as? [String: Any] else {
            throw GatewayError(code: .invalidOutput)
        }
        return WirePayload(data: data, meta: meta)
    }

    static func mapTranslate(
        _ payload: WirePayload,
        requestedUnits: [TranslateBatchUnit], configuration: ModelConfiguration, promptVersion: String
    ) throws -> TranslateBatchResult {
        guard Set(payload.data.keys) == ["translations"],
              try JSONSerialization.data(withJSONObject: payload.data).count <= WorkerContract.maxDecodedContentBytes else {
            throw GatewayError(code: .invalidOutput)
        }
        let rows = try jsonKey(payload.data, "translations") { value in
            try asArray(value).map { try asObject($0) }
        }
        guard rows.count == requestedUnits.count else {
            throw GatewayError(code: .invalidOutput)
        }
        var translations: [TranslateBatchResult.UnitTranslation] = []
        translations.reserveCapacity(rows.count)
        for (row, unit) in zip(rows, requestedUnits) {
            let id = try jsonKey(row, "unit_id") { try asString($0) }
            guard id == unit.unitID.uuidString.lowercased() else {
                throw GatewayError(code: .invalidOutput)
            }
            let text = try jsonKey(row, "text") { try asString($0) }
            guard Set(row.keys) == ["unit_id", "text"], !text.isEmpty,
                  text.utf8.count <= WorkerContract.maxTranslationBytes,
                  !text.contains(where: { $0.isNewline }),
                  text.unicodeScalars.first.map({ !isContractWhitespace($0) }) == true,
                  text.unicodeScalars.last.map({ !isContractWhitespace($0) }) == true else {
                throw GatewayError(code: .invalidOutput)
            }
            translations.append(.init(unitID: unit.unitID, text: text))
        }
        return TranslateBatchResult(translations: translations, meta: try mapMeta(payload.meta, configuration: configuration, prompt: promptVersion))
    }

    static func mapAlign(_ payload: WirePayload, configuration: ModelConfiguration, counterpart: String) throws -> AlignSelectionResult {
        guard Set(payload.data.keys) == ["status", "reason", "matches"] else { throw GatewayError(code: .invalidOutput) }
        let rows = try jsonKey(payload.data, "matches") { try asArray($0) }
        let status = try jsonKey(payload.data, "status") { try asString($0) }
        let reason = try jsonKey(payload.data, "reason") { try asString($0) }
        let match: AlignSelectionResult.Match
        switch status {
        case "matched":
            guard reason == "none" else { throw GatewayError(code: .invalidOutput) }
            let rows = try jsonKey(payload.data, "matches") { value in
                try asArray(value).map { try asObject($0) }
            }
            guard (1...WorkerContract.maxMatches).contains(rows.count) else {
                throw GatewayError(code: .invalidOutput)
            }
            var matches: [AlignSelectionResult.PhraseMatch] = []
            for row in rows {
                let quote = try jsonKey(row, "quote") { try asString($0) }
                let occurrence = try jsonKey(row, "occurrence") { try asInt($0) }
                guard Set(row.keys) == ["quote", "occurrence"], !quote.isEmpty, occurrence >= 1,
                      CorrespondenceResolver.occurrenceIndex(of: quote, in: counterpart, occurrence: occurrence) != nil else {
                    throw GatewayError(code: .invalidOutput)
                }
                matches.append(.init(quote: quote, occurrence: occurrence))
            }
            guard CorrespondenceResolver.resolveMatches(matches.map { ($0.quote, $0.occurrence) }, in: counterpart) != nil else { throw GatewayError(code: .invalidOutput) }
            match = .matched(matches: matches)
        case "no_match":
            if !rows.isEmpty {
                throw GatewayError(code: .invalidOutput)
            }
            guard ["not_expressed", "ambiguous", "selection_too_broad"].contains(reason) else { throw GatewayError(code: .invalidOutput) }
            match = .noMatch(reason: reason)
        default:
            throw GatewayError(code: .invalidOutput)
        }
        return AlignSelectionResult(match: match, meta: try mapMeta(payload.meta, configuration: configuration, prompt: "alignment.v1"))
    }

    static func mapMeta(_ raw: [String: Any], configuration: ModelConfiguration, prompt: String) throws -> GatewayMeta {
        let effort = try jsonKey(raw, "requested_effort") { try asString($0) }
        guard let requestedEffort = ModelEffort(rawValue: effort) else {
            throw GatewayError(code: .invalidOutput)
        }
        let meta = GatewayMeta(
            provider: try jsonKey(raw, "provider") { try asString($0) },
            requestedModel: try jsonKey(raw, "requested_model") { try asString($0) },
            requestedEffort: requestedEffort,
            returnedModel: try jsonKey(raw, "returned_model") { try asOptionalString($0) },
            promptVersion: try jsonKey(raw, "prompt_version") { try asString($0) },
            inputTokens: try jsonKey(raw, "input_tokens") { try asOptionalInt($0) },
            outputTokens: try jsonKey(raw, "output_tokens") { try asOptionalInt($0) }
        )
        guard meta.provider == configuration.provider, meta.requestedModel == configuration.model,
              meta.requestedEffort == configuration.effort, meta.promptVersion == prompt,
              (meta.inputTokens ?? 0) >= 0, (meta.outputTokens ?? 0) >= 0 else {
            throw GatewayError(code: .invalidOutput)
        }
        return meta
    }

    private static func isContractWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    // MARK: - Environment

    /// Minimal child environment: only the system temp directory is
    /// carried over. Inherited Python paths, HOME, proxy variables,
    /// provider credentials, and tracing/debug settings never reach the
    /// worker; the packaged runtime needs no user-installed interpreter.
    public static func sanitizedWorkerEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"], !tmpdir.isEmpty {
            environment["TMPDIR"] = tmpdir
        }
        return environment
    }
}

/// Adapter-level timing knobs. Production defaults mirror the contract;
/// tests inject short deadlines without changing production constants.
public struct GatewayTimeouts: Sendable {
    public var startup: TimeInterval
    public var watchdog: TimeInterval
    public var shutdownTerm: TimeInterval
    public var shutdownKill: TimeInterval

    public init(
        startup: TimeInterval = WorkerContract.startupTimeoutSeconds,
        watchdog: TimeInterval = WorkerContract.transportWatchdogSeconds,
        shutdownTerm: TimeInterval = WorkerContract.shutdownGraceSeconds,
        shutdownKill: TimeInterval = 1.0
    ) {
        self.startup = startup
        self.watchdog = watchdog
        self.shutdownTerm = shutdownTerm
        self.shutdownKill = shutdownKill
    }
}

// MARK: - JSON value helpers (post-preflight frames only)

func jsonKey<T>(_ object: [String: Any], _ key: String, _ decode: (Any?) throws -> T) throws -> T {
    guard object.keysContains(key) else { throw GatewayError(code: .invalidOutput) }
    return try decode(object[key])
}

extension Dictionary where Key == String {
    func keysContains(_ key: String) -> Bool { index(forKey: key) != nil }
}

func asObject(_ value: Any?) throws -> [String: Any] {
    guard let object = value as? [String: Any] else { throw GatewayError(code: .invalidOutput) }
    return object
}

func asArray(_ value: Any?) throws -> [Any] {
    guard let array = value as? [Any] else { throw GatewayError(code: .invalidOutput) }
    return array
}

func asString(_ value: Any?) throws -> String {
    guard let string = value as? String else { throw GatewayError(code: .invalidOutput) }
    return string
}

func asOptionalString(_ value: Any?) throws -> String? {
    if value is NSNull || value == nil { return nil }
    return try asString(value)
}

/// Integer that rejects booleans and non-integral numbers.
func asInt(_ value: Any?) throws -> Int {
    guard let number = value as? NSNumber else { throw GatewayError(code: .invalidOutput) }
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
        throw GatewayError(code: .invalidOutput)
    }
    let int = number.intValue
    guard number.isEqual(to: NSNumber(value: int)) else {
        throw GatewayError(code: .invalidOutput)
    }
    return int
}

func asOptionalInt(_ value: Any?) throws -> Int? {
    if value is NSNull || value == nil { return nil }
    return try asInt(value)
}
