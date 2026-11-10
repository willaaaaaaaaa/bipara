import Foundation

/// Canonical API Base URL validation, per the model configuration design.
/// Requires a host and HTTPS; rejects user information, query, fragment,
/// whitespace/control characters, malformed percent-encoding anywhere it
/// appears, percent-encoding in the host, and full operation suffixes.
/// Preserves a meaningful path (including its percent-encoded reserved
/// characters, byte-for-byte) and port; canonicalizes scheme/host casing,
/// the default HTTPS port, and repeated trailing slashes. Shared by the
/// Settings editor, dispatch validation, and the gateway seam.
public enum CanonicalBaseURL {
    public enum ValidationError: Error, Equatable {
        case empty
        case tooManyBytes
        case whitespaceOrControl
        case notHTTPS
        case missingHost
        case userInfoNotAllowed
        case queryOrFragmentNotAllowed
        case operationSuffix
        case malformedPercentEncoding
        case malformed
    }

    public static let maxUTF8Bytes = 2048
    static let operationSuffixes = ["/chat/completions", "/responses", "/messages"]

    /// Returns the canonical form, or the precise rejection reason.
    public static func canonicalize(_ raw: String, operationURL: Bool = false) -> Result<String, ValidationError> {
        guard !raw.isEmpty else { return .failure(.empty) }
        guard raw.utf8.count <= maxUTF8Bytes else { return .failure(.tooManyBytes) }
        guard !raw.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F }) else {
            return .failure(.whitespaceOrControl)
        }
        // Validate percent-encoding against the raw input: Foundation's
        // encoded-path accessor silently rewrites a bare `%` into `%25`,
        // so malformed sequences must be rejected before that happens
        // rather than silently retyped.
        guard hasWellFormedPercentEncoding(raw) else {
            return .failure(.malformedPercentEncoding)
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return .failure(.malformed)
        }
        guard scheme == "https" else { return .failure(.notHTTPS) }
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return .failure(.missingHost)
        }
        // A percent-encoded host would be silently decoded above; reject
        // it instead of rewriting the destination.
        if url.host(percentEncoded: true)?.contains("%") == true {
            return .failure(.malformedPercentEncoding)
        }
        guard url.user == nil, url.password == nil else { return .failure(.userInfoNotAllowed) }
        guard url.query == nil, url.fragment == nil, !raw.contains("?"), !raw.contains("#") else {
            return .failure(.queryOrFragmentNotAllowed)
        }
        // Preserve percent-encoded path semantics: operate on the encoded
        // path so `%2F`, `%3F`, and `%20` stay encoded rather than decoding
        // into path separators, query starts, or spaces.
        let encodedPath = url.path(percentEncoded: true)
        // Operation-suffix rejection accounts for permitted trailing-slash
        // normalization: `/v1/chat/completions/` and `/v1/messages///`
        // are operation paths (N7).
        var pathForSuffixCheck = encodedPath
        while pathForSuffixCheck.count > 1, pathForSuffixCheck.hasSuffix("/") {
            pathForSuffixCheck = String(pathForSuffixCheck.dropLast())
        }
        guard operationURL || !operationSuffixes.contains(where: { pathForSuffixCheck.lowercased().hasSuffix($0) }) else {
            return .failure(.operationSuffix)
        }
        var canonical = "https://\(host)"
        if let port = url.port {
            // Ports are validated, not silently truncated: an out-of-range
            // port is malformed input (N7). The default HTTPS port is
            // canonicalized away.
            guard (1...65535).contains(port) else { return .failure(.malformed) }
            if port != 443 { canonical += ":\(port)" }
        }
        var path = encodedPath
        while path.count > 1, path.hasSuffix("/") { path = String(path.dropLast()) }
        if path == "/" { path = "" }
        if !path.isEmpty, !path.hasPrefix("/") { path = "/" + path }
        canonical += operationURL ? (encodedPath.isEmpty ? "/" : encodedPath) : (path.isEmpty ? "/" : path + "/")
        return .success(canonical)
    }

    /// Every `%` in the raw input introduces exactly two hexadecimal
    /// digits; a bare or truncated `%` is malformed and rejected.
    static func hasWellFormedPercentEncoding(_ raw: String) -> Bool {
        var scalars = raw.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "%" else { continue }
            guard let first = scalars.next(), first.isHexDigitASCII,
                  let second = scalars.next(), second.isHexDigitASCII else {
                return false
            }
        }
        return true
    }

    public static func isValid(_ url: String) -> Bool {
        if case .success = canonicalize(url) { return true }
        return false
    }

    /// `scheme://host[:port]` transmission-acknowledgement identity.
    public static func origin(of canonical: String) -> String {
        guard let url = URL(string: canonical), let host = url.host(percentEncoded: false) else {
            return canonical
        }
        var origin = "https://\(host)"
        if let port = url.port, port != 443 { origin += ":\(port)" }
        return origin
    }

    public static func host(of canonical: String) -> String? {
        URL(string: canonical)?.host(percentEncoded: false)
    }
}

private extension Unicode.Scalar {
    var isHexDigitASCII: Bool {
        (value >= 0x30 && value <= 0x39)  // 0-9
            || (value >= 0x41 && value <= 0x46)  // A-F
            || (value >= 0x61 && value <= 0x66)  // a-f
    }
}
