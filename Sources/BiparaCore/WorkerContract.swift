/// Swift-side constants of the worker protocol and model workflow contracts.
///
/// These values mirror `docs/design/worker-protocol.md` and
/// `docs/design/model-workflow.md`. They are named constants, not tunable
/// configuration; changes require a corresponding design update. Cross-language
/// agreement is enforced by the Python test suite: numeric constants and
/// protocol examples by the shared fixtures, and the capability table by
/// `Worker/tests/test_capabilities_mirror.py`, which parses this package's
/// `ModelEffort.swift` and compares it with the worker's `CAPABILITIES`.

public enum WorkerContract {
    /// Protocol version `v` carried by every frame. Protocol 2 carries the
    /// explicit Base URL and effort in request config and the requested
    /// effort in result metadata; a protocol-1 worker is rejected at
    /// handshake before any credential is transmitted.
    public static let protocolVersion = 2

    /// Worker implementation version reported in `ready`.
    public static let workerVersion = "0.1.0"

    /// Global concurrent model operations (translation + alignment).
    /// Accepted design revision (owner, 2026-11-05): raised from 2 to 4
    /// together with per-session translation parallelism so phrase
    /// alignment keeps headroom while translation batches run in pairs.
    public static let maxInflightOperations = 4

    /// Concurrent translation batches allowed per document session.
    /// Accepted design revision (owner, 2026-11-05): replaces the original
    /// one-batch-per-session rule; wall-clock time was model-bound, so the
    /// batches of one document now dispatch in parallel.
    public static let translationBatchesPerSession = 2

    public static let glmDefaultCooldown: Duration = .seconds(10)
    public static let glmAutomaticWaitBudget: Duration = .seconds(60)
    public static let glmSerializedWindow: Duration = .seconds(60)

    /// Prompt versions the app requires from a worker handshake.
    public static let markdownTranslationPromptVersion = "translation.markdown.v1"
    public static let promptVersions = ["translation.v1", "translation.v2", markdownTranslationPromptVersion, "alignment.v1"]
    public static let currentTranslationPromptVersion = "translation.v2"
    /// Operation-specific prompt-version sets: a version belongs to exactly
    /// one operation, and each field of a snapshot is validated against
    /// its own operation's set (N6).
    public static let translationPromptVersions = ["translation.v1", "translation.v2", markdownTranslationPromptVersion]
    public static let alignmentPromptVersions = ["alignment.v1"]

    /// Maximum wire frame size in bytes, including the terminating LF.
    public static let maxFrameBytes = 1 << 20

    /// Startup deadline for the child process handshake, in seconds.
    public static let startupTimeoutSeconds: Double = 10

    /// Provider-side total invocation deadline enforced inside the worker.
    public static let invocationTimeoutSeconds: Double = 120

    /// Transport watchdog from dispatch; strictly later than the
    /// invocation deadline so a normal provider timeout still delivers
    /// its terminal frame.
    public static let transportWatchdogSeconds: Double = 130

    /// Grace period after `shutdown` before escalating to terminate.
    public static let shutdownGraceSeconds: Double = 2

    /// Batch planning bounds. Accepted design revision (owner, 2026-11-05):
    /// doubled from 32 units / 4096 bytes so a typical document plans into
    /// fewer batches and pays fewer serial model calls.
    public static let maxUnitsPerBatch = 64
    /// Maximum UTF-8 bytes of one sentence before fragment splitting.
    public static let maxSentenceUTF8Bytes = 1024

    /// Model-output bounds mirrored from the Python validation contract.
    public static let maxTranslationBytes = 8192
    public static let maxMarkdownTranslationBytes = 32_768
    public static let maxDecodedContentBytes = 131_072
    public static let maxAlignSelectionBytes = 512
    public static let maxAlignTextBytes = 8192
    public static let maxMatches = 8
    public static let maxBatchTextBytes = 8192
    public static let maxContextBytes = 512
    public static let maxInputJSONBytes = 32768
    public static let maxSourceUTF8Bytes = 1 << 20
    public static let documentFileByteLimit = 20 << 20

    /// Provider identifiers, request profiles, and the documented preset
    /// API Base URLs. A v1 profile accepts only its original Standard API
    /// URL and effective effort; v2 profiles follow the model
    /// configuration design's capability mapping.
    public static let legacyProviders = ["openai", "glm"]
    public static let providers = ["openai", "kimi", "glm", "deepseek", "anthropic"]
    public static func accepts(provider: String, profile: String) -> Bool {
        profilesByProvider[provider]?.contains(profile) == true
    }
    public static let profilesByProvider = [
        "openai": ["openai-json-schema-v1", "openai-json-schema-v2", ModelAPIProtocol.openai.profile],
        "glm": ["glm-json-v1", "glm-json-v2"],
        "kimi": ["kimi-json-v2"],
        "deepseek": ["deepseek-json-v2"],
        "anthropic": [ModelAPIProtocol.anthropic.profile],
    ]
    public static let legacyProfiles = ["openai": "openai-json-schema-v1", "glm": "glm-json-v1"]
    /// Retained v2 profiles; new configurations use ModelAPIProtocol.profile.
    public static let currentProfiles = ["openai": "openai-json-schema-v2", "glm": "glm-json-v2",
                                         "kimi": "kimi-json-v2", "deepseek": "deepseek-json-v2"]
    public static let openAIStandardBaseURL = "https://api.openai.com/v1/"
    public static let glmStandardBaseURL = "https://open.bigmodel.cn/api/paas/v4/"
    public static let glmCodingPlanBaseURL = "https://open.bigmodel.cn/api/coding/paas/v4/"
    /// The original hardcoded v1 Standard API URL for a provider.
    public static func legacyStandardBaseURL(provider: String) -> String {
        provider == "openai" ? openAIStandardBaseURL : glmStandardBaseURL
    }
    /// Effective effort of a retained v1-profile job: Auto for OpenAI,
    /// Off for GLM.
    public static func legacyEffort(profile: String) -> ModelEffort? {
        switch profile {
        case "openai-json-schema-v1": return .auto
        case "glm-json-v1": return .off
        default: return nil
        }
    }
    public static let defaultModels = [
        "openai": "gpt-4.1-mini-2025-04-14",
        "glm": "glm-4.7-flash",
    ]
}
