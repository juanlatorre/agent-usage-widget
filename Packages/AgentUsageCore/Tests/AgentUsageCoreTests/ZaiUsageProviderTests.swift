import Testing
import Foundation
@testable import AgentUsageCore

final class ZaiStubProtocol: URLProtocol {
    struct Response { let status: Int; let body: String; let headers: [String: String] }
    nonisolated(unsafe) static var responders: [URL: (URLRequest) -> Response] = [:]
    nonisolated(unsafe) static var recorded: [(url: URL, headers: [String: String])] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.recorded.append((url, request.allHTTPHeaderFields ?? [:]))
        let responder = Self.responders[url] ?? { _ in Response(status: 500, body: "", headers: [:]) }
        let r = responder(request)
        let http = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ZaiUsageProviderTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let usageURL = ZaiUsageProvider.usageURL

    private func envelope(limits: [[String: Any]]? = nil, code: Int = 0, success: Bool = true) -> Data {
        var data: [String: Any] = [:]
        if let limits {
            data["limits"] = limits
            data["level"] = "pro"
        }
        var top: [String: Any] = ["data": data, "code": code, "success": success]
        if limits == nil { top["data"] = ["level": "pro"] }
        return try! JSONSerialization.data(withJSONObject: top)
    }

    private func tokensLimit(percentage: Double, resetMs: Double) -> [String: Any] {
        ["type": "TOKENS_LIMIT", "percentage": percentage, "nextResetTime": resetMs]
    }
    private func timeLimit() -> [String: Any] {
        ["type": "TIME_LIMIT", "usage": 500, "currentValue": 123, "nextResetTime": Double(1_760_000_000_000 + 86_400_000)]
    }

    // MARK: AC1 — required limit only

    @Test func ac1_onlyTokensLimitBecomesOneFiveHourWindowTimeLimitIgnored() throws {
        let reset = Double(1_760_000_000_000 + 3_600_000)
        let data = envelope(limits: [tokensLimit(percentage: 42.5, resetMs: reset), timeLimit()])
        let windows = try ZaiUsageProvider.normalize(data: data, now: now)
        #expect(windows.count == 1)
        #expect(windows[0].id == .fiveHour)
        #expect(windows[0].used == 42.5)
        #expect(windows[0].limit == 100)
        #expect(windows[0].resetAt == Date(timeIntervalSince1970: reset / 1000))
    }

    @Test func ac1_noTimeLimitLeakIntoWindows() throws {
        let data = envelope(limits: [tokensLimit(percentage: 10, resetMs: Double(1_760_000_000_000 + 3_600_000))])
        let windows = try ZaiUsageProvider.normalize(data: data, now: now)
        #expect(windows.count == 1)
        #expect(windows[0].id == .fiveHour)
    }

    // MARK: AC2 — auth compatibility

    @Test func ac2_bearerUnauthorizedRetriesRawTokenOnce() async throws {
        defer { ZaiStubProtocol.responders.removeAll(); ZaiStubProtocol.recorded.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ZaiStubProtocol.self]
        var call = 0
        ZaiStubProtocol.responders[usageURL] = { req in
            call += 1
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            if auth == "Bearer my-key" {
                return .init(status: 401, body: "", headers: [:])
            }
            #expect(auth == "my-key")
            let reset = Double(1_760_000_000_000 + 3_600_000)
            let body = String(data: self.envelope(limits: [self.tokensLimit(percentage: 10, resetMs: reset)]), encoding: .utf8)!
            return .init(status: 200, body: body, headers: [:])
        }
        let provider = ZaiUsageProvider(session: URLSession(configuration: config), now: { now })
        let result = try await provider.fetchUsage(credentials: ZaiCredentials(apiKey: "my-key"))
        #expect(result.windows.count == 1)
        #expect(ZaiStubProtocol.recorded.count == 2)
        #expect(ZaiStubProtocol.recorded[0].headers["Authorization"] == "Bearer my-key")
        #expect(ZaiStubProtocol.recorded[1].headers["Authorization"] == "my-key")
        // Accept-Language headers present
        #expect(ZaiStubProtocol.recorded[0].headers["Accept"] == "application/json")
    }

    @Test func ac2_bothAuthFormsRejectedThrows() async throws {
        defer { ZaiStubProtocol.responders.removeAll(); ZaiStubProtocol.recorded.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ZaiStubProtocol.self]
        ZaiStubProtocol.responders[usageURL] = { _ in .init(status: 401, body: "", headers: [:]) }
        let provider = ZaiUsageProvider(session: URLSession(configuration: config), now: { now })
        do { _ = try await provider.fetchUsage(credentials: ZaiCredentials(apiKey: "k")); Issue.record("expected throw") }
        catch let e as ZaiUsageError { #expect(e == .unauthorized(status: 401)) }
        #expect(ZaiStubProtocol.recorded.count == 2)
    }

    // MARK: AC3 — missing required quota

    @Test func ac3_missingTokensLimitIsEmptyDerivesUnavailable() throws {
        let data = envelope(limits: [timeLimit()])
        let windows = try ZaiUsageProvider.normalize(data: data, now: now)
        #expect(windows.isEmpty)
        let slot = AccountCatalog.slot(for: .zaiCodingPlan)!
        let snap = UsageSnapshot(slotID: .zaiCodingPlan, provider: .zai, windows: windows, capturedAt: now)
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snap, now: now).status == .unavailable)
    }

    @Test func ac3_missingPercentageOrResetIsEmpty() throws {
        let noPercent: [String: Any] = ["type": "TOKENS_LIMIT", "nextResetTime": Double(1_760_000_000_000 + 3_600_000)]
        #expect(try ZaiUsageProvider.normalize(data: envelope(limits: [noPercent]), now: now).isEmpty)
        let noReset: [String: Any] = ["type": "TOKENS_LIMIT", "percentage": 10]
        #expect(try ZaiUsageProvider.normalize(data: envelope(limits: [noReset]), now: now).isEmpty)
    }

    @Test func ac3_percentageOutOfBoundsIsEmpty() throws {
        for p in [140.0, -5.0] {
            let l: [String: Any] = ["type": "TOKENS_LIMIT", "percentage": p, "nextResetTime": Double(1_760_000_000_000 + 3_600_000)]
            #expect(try ZaiUsageProvider.normalize(data: envelope(limits: [l]), now: now).isEmpty, "p \(p)")
        }
    }

    @Test func ac3_unsuccessfulEnvelopeIsEmpty() throws {
        let data = try JSONSerialization.data(withJSONObject: ["code": 1, "success": false, "data": ["limits": [tokensLimit(percentage: 10, resetMs: Double(1_760_000_000_000 + 3_600_000))]]])
        #expect(try ZaiUsageProvider.normalize(data: data, now: now).isEmpty)
    }

    @Test func duplicateTokensLimitIsInvalid() throws {
        let r = Double(1_760_000_000_000 + 3_600_000)
        let data = envelope(limits: [tokensLimit(percentage: 10, resetMs: r), tokensLimit(percentage: 20, resetMs: r)])
        #expect(try ZaiUsageProvider.normalize(data: data, now: now).isEmpty)
    }

    @Test func malformedEpochIsEmpty() throws {
        let l: [String: Any] = ["type": "TOKENS_LIMIT", "percentage": 10, "nextResetTime": -1.0]
        #expect(try ZaiUsageProvider.normalize(data: envelope(limits: [l]), now: now).isEmpty)
        let stale: Double = (now.timeIntervalSince1970 * 1000) - 10_000
        let l2: [String: Any] = ["type": "TOKENS_LIMIT", "percentage": 10, "nextResetTime": stale]
        #expect(try ZaiUsageProvider.normalize(data: envelope(limits: [l2]), now: now).isEmpty)
    }

    @Test func transport_429And500Mapped() async throws {
        defer { ZaiStubProtocol.responders.removeAll(); ZaiStubProtocol.recorded.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ZaiStubProtocol.self]
        // 429 on both attempts (Bearer + raw) → rateLimited
        ZaiStubProtocol.responders[usageURL] = { _ in .init(status: 429, body: "", headers: ["Retry-After": "17"]) }
        let provider = ZaiUsageProvider(session: URLSession(configuration: config), now: { now })
        do { _ = try await provider.fetchUsage(credentials: ZaiCredentials(apiKey: "k")); Issue.record("expected") }
        catch let e as ZaiUsageError { #expect(e == .rateLimited(retryAfter: 17)) }
        ZaiStubProtocol.responders.removeAll(); ZaiStubProtocol.recorded.removeAll()
        // 5xx (no retry — only auth retry)
        ZaiStubProtocol.responders[usageURL] = { _ in .init(status: 500, body: "", headers: [:]) }
        do { _ = try await provider.fetchUsage(credentials: ZaiCredentials(apiKey: "k")); Issue.record("expected") }
        catch let e as ZaiUsageError { #expect(e == .http(status: 500)) }
    }
}
