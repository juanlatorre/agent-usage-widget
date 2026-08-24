import Testing
import Foundation
@testable import AgentUsageCore

/// URLProtocol stub for the OpenCode usage endpoint.
final class OpenCodeStubProtocol: URLProtocol {

    struct Response { let status: Int; let body: String }

    nonisolated(unsafe) static var responders: [URL: (URLRequest) -> Response] = [:]
    nonisolated(unsafe) static var recordedRequests: [(url: URL, headers: [String: String])] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.recordedRequests.append((url, request.allHTTPHeaderFields ?? [:]))
        let responder = Self.responders[url] ?? { _ in Response(status: 500, body: "") }
        let response = responder(request)
        let http = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: response.status == 429 ? ["Retry-After": "17"] : [:])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct OpenCodeUsageProviderTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private func shapeA(rolling: Int = 3600, weekly: Int = 86400, monthly: Int = 2592000,
                        status: String? = nil) -> Data {
        var top: [String: Any] = [:]
        top["rollingUsage"] = ["usagePercent": 12.0, "resetInSec": rolling]
        top["weeklyUsage"] = ["usagePercent": 34.0, "resetInSec": weekly]
        top["monthlyUsage"] = ["usagePercent": 56.0, "resetInSec": monthly]
        if let status { top["status"] = status }
        top["useBalance"] = false
        return try! JSONSerialization.data(withJSONObject: top)
    }

    private func shapeB(rolling: String? = nil, weekly: String? = nil, monthly: String? = nil) -> Data {
        func iso(_ interval: TimeInterval) -> String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            return f.string(from: now.addingTimeInterval(interval))
        }
        var inner: [String: Any] = [:]
        inner["rolling"] = ["percent": 12.0, "resetsAt": rolling ?? iso(3600)]
        inner["weekly"] = ["percent": 34.0, "resetsAt": weekly ?? iso(86400)]
        inner["monthly"] = ["percent": 56.0, "resetsAt": monthly ?? iso(2592000)]
        return try! JSONSerialization.data(withJSONObject: ["usage": inner])
    }

    // MARK: AC1 — both response shapes

    @Test func ac1_shapeA_normalizesThreeWindowsEquivalently() throws {
        let windows = try OpenCodeUsageProvider.normalize(data: shapeA(), now: now)
        #expect(windows.count == 3)
        let ids = Set(windows.map(\.id))
        #expect(ids == [.fiveHour, .weekly, .monthly])
        #expect(windows.first { $0.id == .fiveHour }?.used == 12)
        #expect(windows.first { $0.id == .weekly }?.used == 34)
        #expect(windows.first { $0.id == .monthly }?.used == 56)
        #expect(windows.first { $0.id == .fiveHour }?.resetAt == now.addingTimeInterval(3600))
    }

    @Test func ac1_shapeB_normalizesThreeWindowsEquivalently() throws {
        let windows = try OpenCodeUsageProvider.normalize(data: shapeB(), now: now)
        #expect(windows.count == 3)
        let ids = Set(windows.map(\.id))
        #expect(ids == [.fiveHour, .weekly, .monthly])
        #expect(windows.first { $0.id == .fiveHour }?.used == 12)
    }

    @Test func ac1_shapesAreEquivalentInNormalizedSnapshot() throws {
        let a = try OpenCodeUsageProvider.normalize(data: shapeA(), now: now)
        let b = try OpenCodeUsageProvider.normalize(data: shapeB(), now: now)
        // Same percentages per window; resets differ only by representation but
        // both resolve to the same intervals.
        for kind in [UsageWindowKind.fiveHour, .weekly, .monthly] {
            let wa = a.first { $0.id == kind }
            let wb = b.first { $0.id == kind }
            #expect(wa?.used == wb?.used)
            // Allow sub-second ISO truncation noise: compare within 2s.
            let delta = abs((wa?.resetAt.timeIntervalSince1970 ?? 0) - (wb?.resetAt.timeIntervalSince1970 ?? 0))
            #expect(delta < 2, "kind \(kind) reset drift \(delta)")
        }
    }

    // MARK: AC2 — any period blocks

    @Test func ac2_monthlyAtHundredBlocks() throws {
        // 5h 42%, weekly 68%, monthly 100% — GO blocked by monthly, limiting is monthly.
        var payload: [String: Any] = [
            "rollingUsage": ["usagePercent": 42.0, "resetInSec": 3600],
            "weeklyUsage": ["usagePercent": 68.0, "resetInSec": 86400],
            "monthlyUsage": ["usagePercent": 100.0, "resetInSec": 2592000],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let windows = try OpenCodeUsageProvider.normalize(data: data, now: now)
        let slot = AccountCatalog.slot(for: .openCodeGO)!
        let snapshot = UsageSnapshot(slotID: .openCodeGO, provider: .opencode, windows: windows, capturedAt: now)
        let presentation = AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: now.addingTimeInterval(1))
        #expect(presentation.status == .blocked)
        #expect(presentation.blockers.map(\.id) == [.monthly])
        #expect(presentation.limitingWindow?.kind == .monthly)
    }

    @Test func ac2_singlePeriodBlockSticks() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "rollingUsage": ["usagePercent": 100.0, "resetInSec": 1800],
            "weeklyUsage": ["usagePercent": 10.0, "resetInSec": 86400],
            "monthlyUsage": ["usagePercent": 10.0, "resetInSec": 2592000],
        ] as [String: Any])
        let windows = try OpenCodeUsageProvider.normalize(data: data, now: now)
        let slot = AccountCatalog.slot(for: .openCodeGO)!
        let snapshot = UsageSnapshot(slotID: .openCodeGO, provider: .opencode, windows: windows, capturedAt: now)
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: now).status == .blocked)
    }

    // MARK: AC3 — missing month

    @Test func ac3_missingMonthlyWindowDerivesUnavailable() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "rollingUsage": ["usagePercent": 10.0, "resetInSec": 3600],
            "weeklyUsage": ["usagePercent": 20.0, "resetInSec": 86400],
        ] as [String: Any])
        let windows = try OpenCodeUsageProvider.normalize(data: data, now: now)
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.id != .monthly })
        let slot = AccountCatalog.slot(for: .openCodeGO)!
        let snapshot = UsageSnapshot(slotID: .openCodeGO, provider: .opencode, windows: windows, capturedAt: now)
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: now).status == .unavailable)
    }

    @Test func ac3_missingPercentOrResetIsIncomplete() throws {
        let noPercent = try JSONSerialization.data(withJSONObject: [
            "rollingUsage": ["resetInSec": 3600],
            "weeklyUsage": ["usagePercent": 10.0, "resetInSec": 86400],
            "monthlyUsage": ["usagePercent": 10.0, "resetInSec": 2592000],
        ] as [String: Any])
        #expect(try OpenCodeUsageProvider.normalize(data: noPercent, now: now).count == 2)

        let noReset = try JSONSerialization.data(withJSONObject: [
            "rollingUsage": ["usagePercent": 10.0],
            "weeklyUsage": ["usagePercent": 10.0, "resetInSec": 86400],
            "monthlyUsage": ["usagePercent": 10.0, "resetInSec": 2592000],
        ] as [String: Any])
        #expect(try OpenCodeUsageProvider.normalize(data: noReset, now: now).count == 2)
    }

    // MARK: R4 — failure status

    @Test func r4_failureStatusYieldsEmptyWindowsNotException() throws {
        let failure = shapeA(status: "error")
        #expect(try OpenCodeUsageProvider.normalize(data: failure, now: now).isEmpty)
        let failureShapeB: [String: Any] = ["status": "failed", "usage": ["rolling": ["percent": 10.0, "resetsAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))]]]
        let data = try JSONSerialization.data(withJSONObject: failureShapeB)
        #expect(try OpenCodeUsageProvider.normalize(data: data, now: now).isEmpty)
    }

    @Test func r4_successStatusesPassThrough() throws {
        for token in ["ok", "success", "active", "ready", "OK", "SUCCESS"] {
            let data = shapeA(status: token)
            #expect(try OpenCodeUsageProvider.normalize(data: data, now: now).count == 3, "token \(token)")
        }
    }

    // MARK: R5 — ignored members

    @Test func r5_useBalanceAndExtraFieldsAreIgnored() throws {
        var payload: [String: Any] = [
            "rollingUsage": ["usagePercent": 12.0, "resetInSec": 3600],
            "weeklyUsage": ["usagePercent": 34.0, "resetInSec": 86400],
            "monthlyUsage": ["usagePercent": 56.0, "resetInSec": 2592000],
            "useBalance": true,
            "credits": ["balance": 99],
            "extra": "ignored",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let windows = try OpenCodeUsageProvider.normalize(data: data, now: now)
        #expect(windows.count == 3)
        #expect(windows.allSatisfy { $0.id == .fiveHour || $0.id == .weekly || $0.id == .monthly })
    }

    // MARK: Edge cases

    @Test func negativeResetIsIncomplete() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "rollingUsage": ["usagePercent": 10.0, "resetInSec": -5],
            "weeklyUsage": ["usagePercent": 10.0, "resetInSec": 86400],
            "monthlyUsage": ["usagePercent": 10.0, "resetInSec": 2592000],
        ] as [String: Any])
        #expect(try OpenCodeUsageProvider.normalize(data: data, now: now).count == 2)
    }

    @Test func malformedISODerivesIncompleteWindow() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "usage": ["rolling": ["percent": 10.0, "resetsAt": "not-a-date"]]
        ] as [String: Any])
        // Rolling with malformed date is dropped, no other windows present.
        #expect(try OpenCodeUsageProvider.normalize(data: data, now: now).isEmpty)
    }

    @Test func outOfRangePercentIsIncomplete() throws {
        for value in [140.0, -5.0] {
            let data = try JSONSerialization.data(withJSONObject: [
                "rollingUsage": ["usagePercent": value, "resetInSec": 3600],
            ] as [String: Any])
            let windows = try OpenCodeUsageProvider.normalize(data: data, now: now)
            #expect(windows.isEmpty, "value \(value) should be incomplete")
        }
        // Infinite/NaN are not JSON-serializable — exercise through raw string.
        let infJSON = Data(#"{"rollingUsage":{"usagePercent":"Infinity","resetInSec":3600}}"# .utf8)
        // String "Infinity" decodes as nil Double, so treated as missing.
        #expect(try OpenCodeUsageProvider.normalize(data: infJSON, now: now).isEmpty)
    }

    @Test func undecodablePayloadIsTransportFailure() {
        #expect(throws: OpenCodeUsageError.self) {
            try OpenCodeUsageProvider.normalize(data: Data("not json".utf8), now: now)
        }
    }

    // MARK: Transport contract

    @Test func transport_sendsBearerAndHeadersAndMapsErrors() async throws {
        defer { OpenCodeStubProtocol.responders.removeAll(); OpenCodeStubProtocol.recordedRequests.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeStubProtocol.self]

        // 401 → unauthorized
        OpenCodeStubProtocol.responders[usageURL] = { _ in .init(status: 401, body: "") }
        do {
            _ = try await OpenCodeUsageProvider(session: URLSession(configuration: config), now: { now })
                .fetchUsage(credentials: OpenCodeCredentials(apiKey: "k1"))
            Issue.record("expected unauthorized")
        } catch let e as OpenCodeUsageError {
            #expect(e == .unauthorized(status: 401))
        }

        // 429 → rate limited with Retry-After
        OpenCodeStubProtocol.responders[usageURL] = { _ in .init(status: 429, body: "") }
        do {
            _ = try await OpenCodeUsageProvider(session: URLSession(configuration: config), now: { now })
                .fetchUsage(credentials: OpenCodeCredentials(apiKey: "k1"))
            Issue.record("expected rateLimited")
        } catch let e as OpenCodeUsageError {
            #expect(e == .rateLimited(retryAfter: 17))
        }

        // 200 success with correct headers
        OpenCodeStubProtocol.responders[usageURL] = { _ in .init(
            status: 200,
            body: String(data: shapeA(), encoding: .utf8)!) }
        _ = try await OpenCodeUsageProvider(session: URLSession(configuration: config), now: { now })
            .fetchUsage(credentials: OpenCodeCredentials(apiKey: "my-key"))
        let last = OpenCodeStubProtocol.recordedRequests.last!
        #expect(last.headers["Authorization"] == "Bearer my-key")
        #expect(last.headers["Accept"] == "application/json")
        #expect(last.headers["User-Agent"]?.contains("agent-usage-widget") == true)
        #expect(!(last.headers["User-Agent"]?.contains("opencode") == true && last.headers["User-Agent"] != "agent-usage-widget/0.1"))
    }

    @Test func timeout_mapsToTransport() async throws {
        final class TimedOut: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TimedOut.self]
        do {
            _ = try await OpenCodeUsageProvider(session: URLSession(configuration: config))
                .fetchUsage(credentials: OpenCodeCredentials(apiKey: "k"))
            Issue.record("expected timeout")
        } catch let e as OpenCodeUsageError {
            if case .transport = e {} else { Issue.record("expected transport, got \(e)") }
        }
    }
}
