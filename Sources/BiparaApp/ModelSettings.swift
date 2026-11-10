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
    public var vendorLabel: String?
    public var requestOptions: ModelRequestOptions?
    public var revision: UUID?

    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        provider: String,
        profile: String,
        modelID: String,
        effort: ModelEffort,
        baseURL: String,
        vendorLabel: String? = nil,
        requestOptions: ModelRequestOptions? = nil,
        revision: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.profile = profile
        self.modelID = modelID
        self.effort = effort
        self.baseURL = baseURL
        self.vendorLabel = vendorLabel
        self.requestOptions = requestOptions
        self.revision = revision
    }

    public var resolvedName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? modelID : trimmed
    }
}

/// Vendor labels and seed connections for fresh preferences. The model
/// editor does not expose presets or use these values to prefill fields.
enum ModelVendor: String, CaseIterable {
    case openai, kimi, glm, deepseek, anthropic

    var name: String {
        switch self {
        case .openai: "OpenAI"
        case .kimi: "Kimi"
        case .glm: "GLM"
        case .deepseek: "DeepSeek"
        case .anthropic: "Anthropic"
        }
    }

    var models: [String] {
        switch self {
        case .openai: ["gpt-6-luna", "gpt-6-astra", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.1-terra"]
        case .kimi: ["kimi-k3.1-pro", "kimi-k3.1-pro-highspeed", "kimi-k3"]
        case .glm: ["glm-5.3-flash", "glm-5.3"]
        case .deepseek: ["deepseek-flash", "deepseek-v4-pro"]
        case .anthropic: ["claude-sonnet-4-6"]
        }
    }

    var baseURL: String {
        switch self {
        case .openai: WorkerContract.openAIStandardBaseURL
        case .kimi: "https://api.moonshot.cn/v1/"
        case .glm: WorkerContract.glmStandardBaseURL
        case .deepseek: "https://api.deepseek.com/"
        case .anthropic: "https://api.anthropic.com/"
        }
    }
}

extension ModelConfigurationRecord {
    func hasSameRequest(as other: Self) -> Bool {
        provider == other.provider && profile == other.profile && modelID == other.modelID
            && effort == other.effort && baseURL == other.baseURL && requestOptions == other.requestOptions
    }
    var vendorName: String { vendorLabel ?? ModelVendor(rawValue: provider)?.name ?? provider }

    public var credentialIdentity: String {
        requestOptions?.credentialIdentity(baseURL: baseURL, profile: profile) ?? (provider + "\u{1F}" + baseURL)
    }

    public var runtimeBinding: RuntimeModelBinding {
        RuntimeModelBinding(configurationID: id, baseURL: baseURL, provider: provider,
                            requestOptions: requestOptions, credentialIdentity: credentialIdentity)
    }

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
    public let requestOptions: ModelRequestOptions?
    public let credentialIdentity: String

    public init(configurationID: UUID, baseURL: String, provider: String,
                requestOptions: ModelRequestOptions? = nil, credentialIdentity: String? = nil) {
        self.configurationID = configurationID
        self.provider = provider
        self.baseURL = baseURL
        self.requestOptions = requestOptions
        self.credentialIdentity = credentialIdentity ?? (provider + "\u{1F}" + baseURL)
    }
}

/// An optional envelope stored only in Keychain; old plain keys remain readable.
struct ModelCredentials: Codable {
    var apiKey: String
    var headers: [String: String]
    private static let prefix = "bipara-credentials-v1:"

    static func decode(_ value: String) throws -> Self {
        guard value.hasPrefix(prefix) else { return Self(apiKey: value, headers: [:]) }
        return try JSONDecoder().decode(Self.self, from: Data(value.dropFirst(prefix.count).utf8))
    }

    func encoded() throws -> String {
        if headers.isEmpty { return apiKey }
        return Self.prefix + String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    static func parseHeaders(_ json: String) throws -> [String: String] {
        let data = Data(json.utf8)
        let headers = try StrictJSON.decode([String: String].self, from: data, maxBytes: 4096)
        let reserved: Set<String> = ["host", "content-length", "transfer-encoding", "connection", "content-type", "authorization", "x-api-key", "anthropic-version"]
        guard headers.count <= 32, headers.allSatisfy({ name, value in
            ModelRequestOptions.validHeaderName(name) && !reserved.contains(name.lowercased())
                && value.utf8.allSatisfy { (32...126).contains($0) }
        }), Set(headers.keys.map { $0.lowercased() }).count == headers.count else {
            throw SettingsStore.SettingsError.invalidField("secret headers")
        }
        return headers
    }
}
