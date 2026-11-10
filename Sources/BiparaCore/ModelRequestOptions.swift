import Foundation

/// Wire protocols, independent of a user-facing vendor label.
public enum ModelAPIProtocol: String, Codable, Sendable, CaseIterable {
    case openai, anthropic

    public var profile: String { self == .openai ? "openai-responses-v3" : "anthropic-messages-v3" }
    public var operationPath: String { self == .openai ? "responses" : "v1/messages" }
    public static func from(profile: String) -> Self? { allCases.first { $0.profile == profile } }
}

public enum ModelOutputMode: String, Codable, Sendable, CaseIterable {
    case promptJSON, jsonObject, jsonSchema
}

public enum ModelAuthentication: String, Codable, Sendable, CaseIterable {
    case bearer, apiKey, custom, none
}

/// Private connection/generation settings. Never serialize into a document.
public struct ModelRequestOptions: Codable, Sendable, Equatable {
    public var endpointURL: String?
    public var authentication: ModelAuthentication = .bearer
    public var headerName: String = "X-API-Key"
    public var apiVersion: String = "2023-06-01"
    public var outputMode: ModelOutputMode = .promptJSON
    public var translationTokens: Int = 16384
    public var alignmentTokens: Int = 4096
    public var temperature: Double?
    public var extraBodyJSON: String = "{}"

    public init() {}

    public func requestURL(baseURL: String, profile: String) -> String {
        endpointURL ?? (baseURL + (ModelAPIProtocol.from(profile: profile)?.operationPath ?? "chat/completions"))
    }

    public func credentialIdentity(baseURL: String, profile: String) -> String {
        [profile, requestURL(baseURL: baseURL, profile: profile), authentication.rawValue,
         authentication == .custom ? headerName.lowercased() : ""].joined(separator: "\u{1F}")
    }

    public static let protectedBodyKeys: Set<String> = [
        "model", "input", "messages", "system", "instructions", "tools", "tool_choice", "stream",
        "text", "response_format", "output_format", "previous_response_id", "conversation",
        "background", "store", "include", "service_tier", "max_output_tokens", "max_tokens",
    ]

    public func validate(protocol api: ModelAPIProtocol) throws {
        if let endpointURL {
            guard case .success = CanonicalBaseURL.canonicalize(endpointURL, operationURL: true) else {
                throw CoreError.invalidDocument("invalid request URL")
            }
        }
        guard (1...1_048_576).contains(translationTokens), (1...1_048_576).contains(alignmentTokens),
              temperature.map({ $0.isFinite && (0...2).contains($0) }) ?? true,
              apiVersion.utf8.count <= 128, apiVersion.utf8.allSatisfy({ (32...126).contains($0) }),
              Self.validHeaderName(headerName),
              !(api == .anthropic && outputMode == .jsonObject),
              extraBodyJSON.utf8.count <= 16384 else {
            throw CoreError.invalidDocument("invalid model request options")
        }
        let reservedHeaders: Set<String> = ["host", "content-length", "transfer-encoding", "connection", "content-type", "anthropic-version"]
        guard authentication != .custom || !reservedHeaders.contains(headerName.lowercased()) else {
            throw CoreError.invalidDocument("reserved authentication header")
        }
        let data = Data(extraBodyJSON.utf8)
        try StrictJSON.preflight(data, maxBytes: 16384)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.protectedBodyKeys.isDisjoint(with: body.keys),
              (body["output_config"] as? [String: Any])?["format"] == nil else {
            throw CoreError.invalidDocument("additional parameters cannot replace task fields")
        }
        for key in ["reasoning", "thinking", "output_config"] where body[key] != nil {
            guard body[key] is [String: Any] else {
                throw CoreError.invalidDocument("reasoning parameters must be objects")
            }
        }
    }

    public static func validHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}
