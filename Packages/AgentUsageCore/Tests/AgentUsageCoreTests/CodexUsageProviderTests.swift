import Testing
import Foundation
@testable import AgentUsageCore

/// URLProtocol-based transport stub for the Codex usage endpoint.
final class CodexStubProtocol: URLProtocol {

    struct Response {
        let status: Int
        let body: String
    }

    nonisolated(unsafe) static var responders: [URL: (URLRequest) -> Response] = [:]
    nonisolated(unsafe) static var recordedRequests: [(url: URL, headers: [String: String])] = []

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

/// Verifies the exact request contract of the Codex adapter (child spec R1).
@Suite(.serialized)
struct CodexTransportContractTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage?limit_id=codex")!

    @Test("R1: GET usage endpoint with Bearer, account id, JSON accept, truthful UA")
    func r1_requestShape() async throws {
        let completeBody = #"{"rate_limit":{"allowed":true,"primary_window":{"used_percent":5,"reset_at":\#(Int(self.now.timeIntervalSince1970) + 86_400)}}}"#
        CodexStubProtocol.responders[Self.usageURL] = { _ in
            CodexStubProtocol.Response(status: 200, body: completeBody)
        }
        defer {
            CodexStubProtocol.responders.removeAll()
            CodexStubProtocol.recordedRequests.removeAll()
        }

        // Protocol classes must be installed on the configuration BEFORE the
        // session copies it; otherwise requests escape to the real network.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexStubProtocol.self]
        let provider = CodexUsageProvider(session: URLSession(configuration: configuration),
                                          now: { self.now })
        _ = try await provider.fetchUsage(
            credentials: CodexOAuthCredentials(accessToken: "secret-bearer",
                                               accountID: "acct-42"))

        #expect(!CodexStubProtocol.recordedRequests.isEmpty)
        let request = CodexStubProtocol.recordedRequests[0]
        #expect(request.url == CodexUsageProvider.usageURL)
        #expect(request.headers["Authorization"] == "Bearer secret-bearer")
        #expect(request.headers["ChatGPT-Account-Id"] == "acct-42")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["User-Agent"]?.contains("agent-usage-widget") == true)
        // A truthful client UA must not impersonate the Codex CLI (R1).
        #expect(request.headers["User-Agent"]?.contains("codex-cli") != true)
    }

    @Test("R4: account header omitted when credential carries no account id")
    func omitsAccountHeaderWhenAbsent() async throws {
        let completeBody = #"{"rate_limit":{"allowed":true,"primary_window":{"used_percent":5,"reset_at":\#(Int(self.now.timeIntervalSince1970) + 86_400)}}}"#
        CodexStubProtocol.responders[Self.usageURL] = { _ in
            CodexStubProtocol.Response(status: 200, body: completeBody)
        }
        defer {
            CodexStubProtocol.responders.removeAll()
            CodexStubProtocol.recordedRequests.removeAll()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexStubProtocol.self]
        let provider = CodexUsageProvider(session: URLSession(configuration: configuration),
                                          now: { self.now })
        _ = try await provider.fetchUsage(
            credentials: CodexOAuthCredentials(accessToken: "t", accountID: nil))

        let request = CodexStubProtocol.recordedRequests[0]
        #expect(request.headers["ChatGPT-Account-Id"] == nil)
    }

    @Test("R4: 401/403 map to authentication required; 429 surfaces Retry-After")
    func errorMapping() async throws {
        defer {
            CodexStubProtocol.responders.removeAll()
            CodexStubProtocol.recordedRequests.removeAll()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexStubProtocol.self]

        CodexStubProtocol.responders[Self.usageURL] = { _ in
            CodexStubProtocol.Response(status: 403, body: "")
        }
        do {
            _ = try await CodexUsageProvider(session: URLSession(configuration: configuration),
                                             now: { self.now })
                .fetchUsage(credentials: CodexOAuthCredentials(accessToken: "t"))
            Issue.record("expected unauthorized")
        } catch let error as CodexUsageError {
            #expect(error == .unauthorized(status: 403))
        }

        CodexStubProtocol.responders[Self.usageURL] = { _ in
            CodexStubProtocol.Response(status: 429, body: "")
        }
        do {
            _ = try await CodexUsageProvider(session: URLSession(configuration: configuration),
                                             now: { self.now })
                .fetchUsage(credentials: CodexOAuthCredentials(accessToken: "t"))
            Issue.record("expected rate limited")
        } catch let error as CodexUsageError {
            #expect(error == .rateLimited(retryAfter: 17))
        }
    }

    @Test("R5: timeout maps to typed transport failure")
    func timeoutMapsToTransportError() async throws {
        final class TimedOutProtocol: URLProtocol {
            override static func canInit(with request: URLRequest) -> Bool { true }
            override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            override func stopLoading() {}
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimedOutProtocol.self]
        let provider = CodexUsageProvider(session: URLSession(configuration: configuration))

        do {
            _ = try await provider.fetchUsage(
                credentials: CodexOAuthCredentials(accessToken: "t"))
            Issue.record("expected timeout failure")
        } catch let error as CodexUsageError {
            if case .transport = error {} else {
                Issue.record("expected .transport, got \(error)")
            }
        }
    }
}

/// Normalization contract tests (child spec R2/R3/R6, AC1/AC2/AC4).
struct CodexNormalizationTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// Asserts normalization yields no required window (honest UNAVAILABLE)
    /// rather than throwing — transport succeeded but data is incomplete.
    /// Mirrors Claude contract where compactMap drops incomplete windows.
    private func assertUnavailableEmpty(
        _ body: () throws -> [UsageWindow]
    ) {
        do {
            let windows = try body()
            #expect(windows.isEmpty, "expected empty windows for incomplete payload, got \(windows)")
        } catch {
            Issue.record("expected empty windows (UNAVAILABLE), got throw \(error)")
        }
    }

    /// Verified live payload shape (AgentBar grounding): weekly primary window.
    private func payload(percent: String?, resetAt: String?, resetAfter: String?,
                         limitReached: String? = nil) -> Data {
        var window = "{"
        var parts: [String] = []
        if let percent { parts.append(#""used_percent":\#(percent)"#) }
        if let resetAt { parts.append(#""reset_at":\#(resetAt)"#) }
        if let resetAfter { parts.append(#""reset_after_seconds":\#(resetAfter)"#) }
        parts.append(#""limit_window_seconds":604800"#)
        window += parts.joined(separator: ",") + "}"
        let reached = limitReached.map { #""limit_reached":\#($0),"# } ?? ""
        return Data(#"""
        {"plan_type":"prolite","rate_limit":{"allowed":false,\#(reached)
         "primary_window":\#(window),"secondary_window":null},
         "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","used_percent":88}],
         "credits":{"has_credits":false,"balance":"0"},
         "spend_control":{"reached":false}}
        """#.data(using: .utf8)!)
    }

    // MARK: AC1 — live weekly usage

    @Test func ac1_completeWeeklyWindowNormalizes() throws {
        let data = payload(percent: "96", resetAt: "\(1_760_000_000 + 86_400)", resetAfter: nil)
        let windows = try CodexUsageProvider.normalize(data: data, now: now)

        #expect(windows.count == 1)
        let weekly = try #require(windows.first)
        #expect(weekly.id == .weekly)
        #expect(weekly.isRequired)
        #expect(weekly.used == 96)
        #expect(weekly.limit == 100)
        #expect(weekly.resetAt == Date(timeIntervalSince1970: 1_760_000_000 + 86_400))
        #expect(weekly.sourceDiagnostics.sourceKind == "codex-oauth-usage")
    }

    @Test func ac1_epochAndRelativeResetsBothAccepted() throws {
        let absolute = try CodexUsageProvider.normalize(
            data: payload(percent: "10", resetAt: "1760086400", resetAfter: nil), now: now)
        #expect(absolute[0].resetAt == now.addingTimeInterval(86_400))
        #expect(absolute[0].sourceDiagnostics.notes.isEmpty)

        let relative = try CodexUsageProvider.normalize(
            data: payload(percent: "10", resetAt: nil, resetAfter: "3600"), now: now)
        #expect(relative[0].resetAt == now.addingTimeInterval(3_600))
        #expect(relative[0].sourceDiagnostics.notes.contains("reset derived from reset_after_seconds"))
    }

    @Test func ac1_alreadyElapsedRelativeResetCannotSupportCurrentClaim() throws {
        // reset_after_seconds == 0 means the period just expired (resetAt == now).
        // Transport preserves it; engine's expiredByNow branch derives UNAVAILABLE
        // pending post-reset verification (ADR-0005, F3 fix >= now).
        let zero = payload(percent: "99", resetAt: nil, resetAfter: "0")
        let windows = try CodexUsageProvider.normalize(data: zero, now: now)
        #expect(windows.count == 1)
        let weekly = try #require(windows.first)
        #expect(weekly.resetAt == now)
        let slot = AccountCatalog.slot(for: .chatGPT)!
        let snapshot = UsageSnapshot(slotID: .chatGPT, provider: .gpt, windows: windows, capturedAt: now)
        let presentation = AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: now)
        #expect(presentation.status == .unavailable)
    }

    // MARK: AC2 — exhausted week

    @Test func ac2_exhaustedWeekBlocksOnWeeklyWindow() throws {
        let data = payload(percent: "100", resetAt: "\(1_760_000_000 + 261_623)",
                           resetAfter: nil, limitReached: "true")
        let windows = try CodexUsageProvider.normalize(data: data, now: now)

        let weekly = try #require(windows.first)
        #expect(weekly.used == 100)
        #expect(weekly.isBlocking)
        #expect(weekly.resetAt == Date(timeIntervalSince1970: 1_760_000_000 + 261_623))

        // Through the engine: blocked with availableAt at the weekly reset (AC2).
        let slot = AccountCatalog.slot(for: .chatGPT)!
        let fiveHour = UsageWindow(
            id: .fiveHour, name: "5 hour", isRequired: true,
            used: 30, limit: 100,
            resetAt: Date(timeIntervalSince1970: 1_760_000_000 + 18_000),
            sourceDiagnostics: SourceDiagnostics(sourceKind: "test", sourceReliability: "test", notes: []))
        let snapshot = UsageSnapshot(
            slotID: .chatGPT, provider: .gpt,
            windows: windows + [fiveHour], capturedAt: now)
        let presentation = AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: now.addingTimeInterval(1))
        #expect(presentation.status == .blocked)
        #expect(presentation.availableAt == weekly.resetAt)
    }

    // MARK: AC4 — incomplete data never fabricates availability

    @Test func ac4_missingPercentYieldsNoWindowNotZero() throws {
        let data = payload(percent: nil, resetAt: "1760086400", resetAfter: nil)
        let windows = try CodexUsageProvider.normalize(data: data, now: now)
        #expect(windows.isEmpty)
        // Through engine: UNAVAILABLE with no fabrication of 0%.
        let slot = AccountCatalog.slot(for: .chatGPT)!
        let snapshot = UsageSnapshot(slotID: .chatGPT, provider: .gpt, windows: windows, capturedAt: now)
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: now).status == .unavailable)
    }

    @Test func ac4_missingResetYieldsNoWindowNeverAvailableAtZero() throws {
        // The exact AgentBar inheritance this spec forbids (NO2/R2).
        let data = payload(percent: "0", resetAt: nil, resetAfter: nil)
        let windows = try CodexUsageProvider.normalize(data: data, now: now)
        #expect(windows.isEmpty)
        let slot = AccountCatalog.slot(for: .chatGPT)!
        let snapshot = UsageSnapshot(slotID: .chatGPT, provider: .gpt, windows: windows, capturedAt: now)
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: now).status == .unavailable)
    }

    @Test func ac4_pastOrNonpositiveResetsAreIncomplete() throws {
        let pastEpoch = payload(percent: "50", resetAt: "1759999999", resetAfter: nil)
        #expect(try CodexUsageProvider.normalize(data: pastEpoch, now: now).isEmpty)
        let negativeRelative = payload(percent: "50", resetAt: nil, resetAfter: "-30")
        #expect(try CodexUsageProvider.normalize(data: negativeRelative, now: now).isEmpty)
    }

    @Test func ac4_outOfRangePercentIsIncomplete() throws {
        let above = payload(percent: "140", resetAt: "1760086400", resetAfter: nil)
        #expect(try CodexUsageProvider.normalize(data: above, now: now).isEmpty)
        let below = payload(percent: "-5", resetAt: "1760086400", resetAfter: nil)
        #expect(try CodexUsageProvider.normalize(data: below, now: now).isEmpty)
    }

    @Test func ac4_missingPrimaryWindowIsIncomplete() throws {
        let data = Data(#"{"plan_type":"pro","rate_limit":{"allowed":true}}"#.utf8)
        #expect(try CodexUsageProvider.normalize(data: data, now: now).isEmpty)
    }

    @Test func malformedPayloadIsTransportFailureNotIncomplete() throws {
        #expect(throws: CodexUsageError.self) {
            try CodexUsageProvider.normalize(data: Data("not json".utf8), now: now)
        }
        // Top-level primary_window without rate_limit is not a valid Codex
        // payload — transport succeeded but required Weekly is missing, so
        // normalize returns empty windows (UNAVAILABLE) rather than throwing.
        let wrongShape = Data(#"{"primary_window":{"used_percent":10}}"#.utf8)
        #expect(try CodexUsageProvider.normalize(data: wrongShape, now: now).isEmpty)
    }

    // MARK: R6 — extra limits cannot block v1

    @Test func r6_extraLimitsCreditsAndPlanAreIgnored() throws {
        // additional_rate_limits reports 88% and spend control is reached;
        // only the primary weekly window may exist or affect anything.
        let data = payload(percent: "12", resetAt: "1760086400", resetAfter: nil,
                           limitReached: "false")
        let windows = try CodexUsageProvider.normalize(data: data, now: now)
        #expect(windows.count == 1)
        #expect(windows[0].id == .weekly)
        #expect(windows[0].used == 12)
    }

    // MARK: R3 — corroboration flags cannot replace a complete window

    @Test func r3_limitReachedAloneDoesNotCreateAWindow() throws {
        let flaggedNoData = Data("""
        {"rate_limit":{"allowed":false,"limit_reached":true,"primary_window":null}}
        """.utf8)
        #expect(try CodexUsageProvider.normalize(data: flaggedNoData, now: now).isEmpty)
    }
}
