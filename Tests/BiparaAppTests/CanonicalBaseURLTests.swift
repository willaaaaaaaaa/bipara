import BiparaCore
@testable import BiparaAppKit
import Testing

@Suite("Canonical API Base URL validation")
struct CanonicalBaseURLTests {
    @Test func canonicalForms() {
        // Scheme/host casing, default port, trailing slash, base path.
        #expect(CanonicalBaseURL.canonicalize("https://api.openai.com/v1/") == .success("https://api.openai.com/v1/"))
        #expect(CanonicalBaseURL.canonicalize("HTTPS://API.OPENAI.COM/v1") == .success("https://api.openai.com/v1/"))
        #expect(CanonicalBaseURL.canonicalize("https://open.bigmodel.cn/api/paas/v4///") == .success("https://open.bigmodel.cn/api/paas/v4/"))
        #expect(CanonicalBaseURL.canonicalize("https://Gateway.Example.com:443/openai/v1") == .success("https://gateway.example.com/openai/v1/"))
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com:8443/openai/v1/") == .success("https://gateway.example.com:8443/openai/v1/"))
    }

    @Test func rejections() {
        #expect(CanonicalBaseURL.canonicalize("") == .failure(.empty))
        #expect(CanonicalBaseURL.canonicalize("http://api.openai.com/v1/") == .failure(.notHTTPS))
        #expect(CanonicalBaseURL.canonicalize("api.openai.com/v1/") == .failure(.malformed))
        #expect(CanonicalBaseURL.canonicalize("https:///v1/") == .failure(.missingHost))
        #expect(CanonicalBaseURL.canonicalize("https://user:pw@api.openai.com/v1/") == .failure(.userInfoNotAllowed))
        #expect(CanonicalBaseURL.canonicalize("https://api.openai.com/v1/?x=1") == .failure(.queryOrFragmentNotAllowed))
        #expect(CanonicalBaseURL.canonicalize("https://api.openai.com/v1/#f") == .failure(.queryOrFragmentNotAllowed))
        #expect(CanonicalBaseURL.canonicalize("https://api.openai.com/v1/chat/completions") == .failure(.operationSuffix))
        #expect(CanonicalBaseURL.canonicalize("https://open.bigmodel.cn/api/paas/v4/Responses") == .failure(.operationSuffix))
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com/api/messages") == .failure(.operationSuffix))
        #expect(CanonicalBaseURL.canonicalize("https://api.openai.com/v1/ ") == .failure(.whitespaceOrControl))
        #expect(CanonicalBaseURL.canonicalize(String(repeating: "a", count: 2049)) == .failure(.tooManyBytes))
        // Malformed percent-encoding is rejected on the raw input, never
        // silently retyped (a bare % would otherwise be rewritten to %25
        // by the encoded-path accessor).
        #expect(CanonicalBaseURL.canonicalize("https://h.com/a%zz/") == .failure(.malformedPercentEncoding))
        #expect(CanonicalBaseURL.canonicalize("https://h.com/a%2/") == .failure(.malformedPercentEncoding))
        #expect(CanonicalBaseURL.canonicalize("https://h.com/a%") == .failure(.malformedPercentEncoding))
        #expect(CanonicalBaseURL.canonicalize("https://h.com/%2F%G1/") == .failure(.malformedPercentEncoding))
        // A percent-encoded host is rejected rather than silently decoded.
        #expect(CanonicalBaseURL.canonicalize("https://exa%2Fmple.com/v1/") == .failure(.malformedPercentEncoding))
    }

    @Test func encodedPathBytesAndRootSlashCollapsing() {
        // Encoded reserved characters survive byte-for-byte: %2F never
        // becomes a path separator, %20 never becomes a raw space.
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com/team%2Fname/v1") == .success("https://gateway.example.com/team%2Fname/v1/"))
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com/a%20b/v1/") == .success("https://gateway.example.com/a%20b/v1/"))
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com/q%3Fs/v1/") == .success("https://gateway.example.com/q%3Fs/v1/"))
        // Equivalent spellings collapse to one canonical value — including
        // repeated trailing slashes on the root path. Interior empty
        // segments are meaningful path content and are preserved.
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com//") == .success("https://gateway.example.com/"))
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com///a///") == .success("https://gateway.example.com///a/"))
        #expect(CanonicalBaseURL.canonicalize("https://gateway.example.com/") == CanonicalBaseURL.canonicalize("https://gateway.example.com///"))
    }

    @Test func originsAndHosts() {
        #expect(CanonicalBaseURL.origin(of: "https://api.openai.com/v1/") == "https://api.openai.com")
        #expect(CanonicalBaseURL.origin(of: "https://gateway.example.com:8443/openai/v1/") == "https://gateway.example.com:8443")
        #expect(CanonicalBaseURL.host(of: "https://open.bigmodel.cn/api/paas/v4/") == "open.bigmodel.cn")
    }
}
