import BiparaCore
import Foundation

/// One saved model configuration. Credentials live in configuration-scoped
/// Keychain items and are represented here only by presence.
public struct ModelConfigurationRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Optional trimmed single-line alias; blank resolves to `modelID`.
    public var displayName: String?
    public var provider: String
    public var profile: String
    public var modelID: String
    public var effort: ModelEffort
    /// Canonical HTTPS API Base URL.
    public var baseURL: String

    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        provider: String,
        profile: String,
        modelID: String,
        effort: ModelEffort,
        baseURL: String
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.profile = profile
        self.modelID = modelID
        self.effort = effort
        self.baseURL = baseURL
    }

    public var resolvedName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? modelID : trimmed
    }
}

/// Documented connection presets. They prefill editable connection
/// information (provider, profile, URL, and — for a new entry whose model
/// is empty or another preset's recommendation — the recommended
/// model/effort); they do not create a provider engine, test a key, or
/// make a network request.
enum ModelVendor: String, CaseIterable {
    case openai, kimi, glm, deepseek

    var name: String {
        switch self {
        case .openai: "OpenAI"
        case .kimi: "Kimi"
        case .glm: "GLM"
        case .deepseek: "DeepSeek"
        }
    }

    var models: [String] {
        switch self {
        case .openai: ["gpt-6-luna", "gpt-6-astra", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.1-terra"]
        case .kimi: ["kimi-k3.1-pro", "kimi-k3.1-pro-highspeed", "kimi-k3"]
        case .glm: ["glm-5.3-flash", "glm-5.3"]
        case .deepseek: ["deepseek-flash", "deepseek-v4-pro"]
        }
    }

    var baseURL: String {
        switch self {
        case .openai: WorkerContract.openAIStandardBaseURL
        case .kimi: "https://api.moonshot.cn/v1/"
        case .glm: WorkerContract.glmStandardBaseURL
        case .deepseek: "https://api.deepseek.com/"
        }
    }
}

extension ModelConfigurationRecord {
    var vendorName: String { ModelVendor(rawValue: provider)?.name ?? provider }

    func pickerLabel(effortLabel: String) -> String {
        "\(resolvedName) · \(vendorName) · \(modelID) · \(effortLabel)"
    }
}

/// The private runtime endpoint binding frozen at job creation. Never
/// persisted in the portable document, never sent to the model, and never
/// implied by the current default configuration.
public struct RuntimeModelBinding: Equatable, Sendable {
    public let configurationID: UUID
    public let baseURL: String
    public let provider: String

    public init(configurationID: UUID, baseURL: String, provider: String) {
        self.configurationID = configurationID
        self.provider = provider
        self.baseURL = baseURL
    }
}
