import Testing
import Foundation
@testable import AgentUsageCore

/// URLProtocol-based transport stub. No request ever reaches the network.
final class StubProtocol: URLProtocol {

    struct Response {
        let status: Int
        let body: String
    }

    nonisolated(unsafe) static var responders: [URL: (URLRequest) -> Response] = [:]
    nonisolated(unsafe) static var recordedRequests: [(url: URL, headers: [String: String])] = []

    private static let usageHost = "api.anthropic.com"

    static var usageURL: URL {
        URL(string: "https://api.anthropic.com/api/oauth/usage")!
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.recordedRequests.append((
            url,
            request.allHTTPHeaderFields ?? [:]
        ))
        let responder = Self.responders[url] ?? { _ in Response(status: 500, body: "") }
        let response = responder(request)

        let http = HTTPURLResponse(
            url: url, statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.status == 429 ? ["Retry-After": "17"] : [:])!

        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Verifies the exact request contract of the Claude adapter (child spec R4).
/// Serialized because the stub registry is shared per-process.
@Suite(.serialized)
struct ClaudeTransportContractTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("R4: GET usage endpoint with Bearer + anthropic-beta header")
    func r4_requestShape() async throws {
        StubProtocol.responders[StubProtocol.usageURL] = { _ in
            StubProtocol.Response(status: 200, body: "{}")
        }
        defer {
            StubProtocol.responders.removeAll()
            StubProtocol.recordedRequests.removeAll()
        }

        // Protocol classes must be installed on the configuration BEFORE the
        // session copies it; otherwise requests escape to the real network.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let provider = ClaudeUsageProvider(session: URLSession(configuration: configuration),
                                           now: { self.now })
        _ = try await provider.fetchUsage(
            credentials: ClaudeOAuthCredentials(accessToken: "secret-bearer"))

        #expect(!StubProtocol.recordedRequests.isEmpty)
        let request = StubProtocol.recordedRequests[0]
        #expect(request.url == ClaudeUsageProvider.usageURL)
        #expect(request.headers["Authorization"] == "Bearer secret-bearer")
        #expect(request.headers["anthropic-beta"] == "oauth-2025-04-20")
    }

    @Test("AC5: timeout maps to typed transport failure")
    func timeoutMapsToTransportError() async throws {
        final class TimedOutProtocol: URLProtocol {
            override static func canInit(with request: URLRequest) -> Bool { true }
            override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                // Simulate the transport timing out instead of waiting 30s.
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            override func stopLoading() {}
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimedOutProtocol.self]
        let provider = ClaudeUsageProvider(session: URLSession(configuration: configuration))

        do {
            _ = try await provider.fetchUsage(
                credentials: ClaudeOAuthCredentials(accessToken: "t"))
            Issue.record("expected timeout failure")
        } catch let error as ClaudeUsageError {
            if case .transport = error {} else {
                Issue.record("expected .transport, got \(error)")
            }
        }
    }

    @Test("AC5: Retry-After seconds are surfaced for 429")
    func retryAfterParsing() throws {
        let response = HTTPURLResponse(
            url: StubProtocol.usageURL, statusCode: 429,
            httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "23"])!
        #expect(ClaudeUsageProvider.retryAfter(from: response) == 23)

        let missing = HTTPURLResponse(
            url: StubProtocol.usageURL, statusCode: 429,
            httpVersion: "HTTP/1.1", headerFields: [:])!
        #expect(ClaudeUsageProvider.retryAfter(from: missing) == nil)

        let httpDate = HTTPURLResponse(
            url: StubProtocol.usageURL, statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])!
        #expect(ClaudeUsageProvider.retryAfter(from: httpDate) == nil)
    }
}
