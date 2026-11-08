import Foundation

/// Capability-specific model effort, per the model configuration design.
/// `auto` means provider/model default (graded `reasoning_effort` omitted);
/// `off` is an explicit request to disable reasoning; `on` enables binary
/// thinking where no graded effort exists; `minimal` is the lowest graded
/// level, offered only for models whose provider documents it.
public enum ModelEffort: String, Codable, Sendable, CaseIterable, Equatable {
    case auto
    case off
    case on
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    public var isExplicit: Bool { self != .auto }
}

/// Versioned request-profile identifiers. New configurations use v2
/// profiles; v1 profiles remain compatibility contracts for migrated
/// configurations and retained jobs.
public enum ModelProfileID {
    public static let openaiV1 = "openai-json-schema-v1"
    public static let openaiV2 = "openai-json-schema-v2"
    public static let glmV1 = "glm-json-v1"
    public static let glmV2 = "glm-json-v2"

    public static var all: Set<String> { Set(WorkerContract.profilesByProvider.values.flatMap { $0 }) }

    public static func profiles(provider: String) -> [String] {
        WorkerContract.profilesByProvider[provider] ?? []
    }

    public static func provider(of profile: String) -> String? {
        WorkerContract.profilesByProvider.first { $0.value.contains(profile) }?.key
    }
}

/// One local capability-table entry: the effort choices a model actually
/// supports under a v2 profile. This is local code, not an editable generic
/// parameter dictionary; unknown model IDs are saved-and-attempted with
/// Auto only.
public struct ModelCapability: Sendable, Equatable {
    public let provider: String
    public let efforts: [ModelEffort]
    /// True for a known model that has no reasoning controls at all; the
    /// editor then shows Not applicable and disables effort selection.
    public let nonreasoning: Bool

    public init(provider: String, efforts: [ModelEffort], nonreasoning: Bool) {
        self.provider = provider
        self.efforts = efforts
        self.nonreasoning = nonreasoning
    }
}

/// The local capability table from the model configuration design, checked
/// 2026-11-05 against docs.bigmodel.cn and developers.openai.com. Bipara
/// presents only supported choices and rejects unsupported stored/wire
/// values; it never displays Off while requesting Low and never clamps a
/// stored value to a different one.
public enum ModelCapabilities {
    public static let openaiNonreasoningModel = "gpt-4.1-mini-2025-04-14"
    public static let openAIReasoningModel = "gpt-6-luna"
    public static let glmBinaryThinkingModel = "glm-4.7-flash"
    /// GLM models whose thinking cannot be disabled (reasoning_effort
    /// low/high/max only, provider default max). Consumed by the
    /// cross-language mirror test as the Swift-side mode declaration.
    public static let glmForcedThinkingModels: Set<String> = [
        "glm-5.3", "glm-5.3-flash", "glm-5.3-flashx", "glm-5.3-flashx-legal",
    ]
    /// GLM models with binary thinking controls only (no graded effort).
    /// Consumed by the cross-language mirror test as the Swift-side mode
    /// declaration.
    public static let glmBinaryModels: Set<String> = [
        "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.7-flashx", "glm-4.7-flash",
    ]

    private static let entries: [String: ModelCapability] = [
        // OpenAI: `off` maps to reasoning_effort "none", offered only where
        // the model accepts disabling reasoning; gpt-5.5/5.4/5.2 top out at
        // xhigh. The deprecated gpt-4.1 family (removal 2027-01-14) keeps
        // its nonreasoning entry until a separately adopted default change.
        "gpt-6-sol": ModelCapability(
            provider: "openai", efforts: [.auto, .off, .low, .medium, .high, .xhigh, .max], nonreasoning: false),
        "kimi-k3.1-pro": ModelCapability(
            provider: "kimi", efforts: [.auto, .low, .high, .max], nonreasoning: false),
        "kimi-k3.1-pro-highspeed": ModelCapability(
            provider: "kimi", efforts: [.auto, .low, .high, .max], nonreasoning: false),
        "kimi-k3": ModelCapability(
            provider: "kimi", efforts: [.auto, .low, .high, .max], nonreasoning: false),
        "deepseek-flash": ModelCapability(
            provider: "deepseek", efforts: [.auto, .off, .low, .high, .max], nonreasoning: false),
        "deepseek-v4-pro": ModelCapability(
            provider: "deepseek", efforts: [.auto, .off, .low, .high, .max], nonreasoning: false),
        openaiNonreasoningModel: ModelCapability(
            provider: "openai", efforts: [.auto], nonreasoning: true),
        "gpt-6-astra": ModelCapability(
            provider: "openai", efforts: [.auto, .low, .medium, .high, .xhigh, .max], nonreasoning: false),
        openAIReasoningModel: ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh, .max],
            nonreasoning: false),
        "gpt-6.1-sol": ModelCapability(
            provider: "openai", efforts: [.auto, .low, .medium, .high, .xhigh, .max], nonreasoning: false),
        "gpt-6.1-terra": ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh, .max],
            nonreasoning: false),
        "gpt-5.6": ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh, .max],
            nonreasoning: false),
        "gpt-5.6-sol": ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh, .max],
            nonreasoning: false),
        "gpt-5.6-terra": ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh, .max],
            nonreasoning: false),
        "gpt-5.6-luna": ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh, .max],
            nonreasoning: false),
        "gpt-5.5": ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh],
            nonreasoning: false),
        "gpt-5.4": ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh],
            nonreasoning: false),
        "gpt-5.2": ModelCapability(
            provider: "openai",
            efforts: [.auto, .off, .low, .medium, .high, .xhigh],
            nonreasoning: false),
        // GLM: reasoning_effort is GLM-5.2+ only. The 5.3 series cannot
        // disable thinking (provider default effort is max). GLM-5.2 can
        // disable thinking and accepts the full graded set including
        // minimal (the provider maps low/medium to high and xhigh to max).
        "glm-5.3": ModelCapability(
            provider: "glm", efforts: [.auto, .low, .high, .max], nonreasoning: false),
        "glm-5.3-flash": ModelCapability(
            provider: "glm", efforts: [.auto, .low, .high, .max], nonreasoning: false),
        "glm-5.3-flashx": ModelCapability(
            provider: "glm", efforts: [.auto, .low, .high, .max], nonreasoning: false),
        "glm-5.3-flashx-legal": ModelCapability(
            provider: "glm", efforts: [.auto, .low, .high, .max], nonreasoning: false),
        "glm-5.2": ModelCapability(
            provider: "glm",
            efforts: [.auto, .off, .minimal, .low, .medium, .high, .xhigh, .max],
            nonreasoning: false),
        "glm-5.1": ModelCapability(
            provider: "glm", efforts: [.auto, .off, .on], nonreasoning: false),
        "glm-5": ModelCapability(
            provider: "glm", efforts: [.auto, .off, .on], nonreasoning: false),
        "glm-5-turbo": ModelCapability(
            provider: "glm", efforts: [.auto, .off, .on], nonreasoning: false),
        "glm-4.7": ModelCapability(
            provider: "glm", efforts: [.auto, .off, .on], nonreasoning: false),
        "glm-4.7-flashx": ModelCapability(
            provider: "glm", efforts: [.auto, .off, .on], nonreasoning: false),
        glmBinaryThinkingModel: ModelCapability(
            provider: "glm", efforts: [.auto, .off, .on], nonreasoning: false),
    ]

    public static func entry(model: String, provider: String) -> ModelCapability? {
        entries[model].flatMap { $0.provider == provider ? $0 : nil }
    }

    /// Effort choices offered for a model. Unknown model IDs allow Auto
    /// only; an explicit effort for them requires a documented capability
    /// entry and tests first.
    public static func efforts(model: String, provider: String) -> [ModelEffort] {
        entry(model: model, provider: provider)?.efforts ?? [.auto]
    }

    public static func supports(_ effort: ModelEffort, model: String, provider: String) -> Bool {
        efforts(model: model, provider: provider).contains(effort)
    }
}
