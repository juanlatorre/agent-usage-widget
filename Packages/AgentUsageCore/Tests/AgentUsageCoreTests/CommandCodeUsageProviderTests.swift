import Testing
import Foundation
@testable import AgentUsageCore

final class CommandCodeStubProtocol: URLProtocol {
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
struct CommandCodeUsageProviderTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let creditsURL = CommandCodeUsageProvider.creditsURL
    private let subsURL = CommandCodeUsageProvider.subscriptionsURL

    private func creditsJSON(fiveHour: (used: Double, cap: Double, resetMs: Int64)? = (0.03, 14, 1_760_000_000_000 + 3_600_000),
                             weekly: (used: Double, cap: Double, resetMs: Int64)? = (0.6, 35, 1_760_000_000_000 + 86_400_000),
                             extra: String = "") -> String {
        func win(_ v: (Double, Double, Int64)?) -> String {
            guard let v else { return "null" }
            return #"{"used":\#(v.0),"cap":\#(v.1),"exceeded":false,"resetAt":\#(v.2)}"#
        }
        return #"{"credits":{"monthlyCredits":1},"windowLimits":{"limited":true,"fiveHour":\#(win(fiveHour)),"weekly":\#(win(weekly))}\#(extra)}"#
    }

    private func subsJSON(planId: String = "individual-goat", status: String = "active") -> String {
        #"{"success":true,"data":{"planId":"\#(planId)","status":"\#(status)"}}"#
    }

    // MARK: AC1 — credit normalization

    @Test func ac1_bothWindowsPreserveCapacityAndParticipateInBlocking() throws {
        let data = Data(creditsJSON(
            fiveHour: (7, 14, 1_760_000_000_000 + 3_600_000),
            weekly: (35, 35, 1_760_000_000_000 + 86_400_000)).utf8)
        let windows = try CommandCodeUsageProvider.normalizeCredits(data: data, now: now)
        #expect(windows.count == 2)
        let five = windows.first { $0.id == .fiveHour }!
        #expect(five.used == 7); #expect(five.limit == 14)
        #expect(five.resetAt == Date(timeIntervalSince1970: Double(1_760_000_000_000 + 3_600_000) / 1000))
        let weekly = windows.first { $0.id == .weekly }!
        #expect(weekly.isBlocking)
        // Blocking participates: GOAT blocked by weekly.
        let slot = AccountCatalog.slot(for: .commandCodeGOAT)!
        let snap = UsageSnapshot(slotID: .commandCodeGOAT, provider: .commandCode, windows: windows, capturedAt: now)
        let pres = AvailabilityEngine.derive(slot: slot, snapshot: snap, now: now.addingTimeInterval(1))
        #expect(pres.status == .blocked)
        #expect(pres.blockers.map(\.id) == [.weekly])
    }

    @Test func ac1_fractionalCreditsPreserved() throws {
        let data = Data(creditsJSON(fiveHour: (0.0347760235, 14, 1_760_000_000_000 + 3600000)).utf8)
        let windows = try CommandCodeUsageProvider.normalizeCredits(data: data, now: now)
        let five = windows.first { $0.id == .fiveHour }!
        #expect(abs(five.used - 0.0347760235) < 1e-9)
    }

    @Test func ac1_usedAboveCapBlocks() throws {
        let data = Data(creditsJSON(fiveHour: (20, 14, 1_760_000_000_000 + 3600000)).utf8)
        let windows = try CommandCodeUsageProvider.normalizeCredits(data: data, now: now)
        #expect(windows.first { $0.id == .fiveHour }?.isBlocking == true)
    }

    // MARK: AC3 — incomplete cap

    @Test func ac3_missingOrZeroCapYieldsNoWindowDerivesUnavailable() throws {
        let missingCap = Data(#"{"windowLimits":{"fiveHour":{"used":1,"resetAt":\#(Int64(1_760_000_000_000 + 3600000)),"exceeded":false},"weekly":{"used":1,"cap":35,"resetAt":\#(Int64(1_760_000_000_000 + 86400000)),"exceeded":false}}}"#.utf8)
        #expect(try CommandCodeUsageProvider.normalizeCredits(data: missingCap, now: now).count == 1)
        let zeroCap = Data(creditsJSON(fiveHour: (1, 0, 1_760_000_000_000 + 3600000)).utf8)
        #expect(try CommandCodeUsageProvider.normalizeCredits(data: zeroCap, now: now).count == 1)
        let missingReset = Data(#"{"windowLimits":{"fiveHour":{"used":1,"cap":14,"exceeded":false},"weekly":{"used":1,"cap":35,"resetAt":\#(Int64(1_760_000_000_000 + 86400000)),"exceeded":false}}}"#.utf8)
        #expect(try CommandCodeUsageProvider.normalizeCredits(data: missingReset, now: now).count == 1)
        // Single window → engine UNAVAILABLE.
        let one = try CommandCodeUsageProvider.normalizeCredits(data: missingCap, now: now)
        let slot = AccountCatalog.slot(for: .commandCodeGOAT)!
        let snap = UsageSnapshot(slotID: .commandCodeGOAT, provider: .commandCode, windows: one, capturedAt: now)
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snap, now: now).status == .unavailable)
    }

    @Test func ac3_creditsOutsideWindowLimitsIgnored() throws {
        let data = Data((creditsJSON() + "").replacingOccurrences(of: "\"limited\"", with: "\"limited\"").utf8)
        // Already covered: extra top-level fields outside windowLimits never become windows.
        let json = #"{"credits":{"monthlyCredits":99,"purchasedCredits":50},"windowLimits":{"fiveHour":{"used":1,"cap":14,"resetAt":\#(Int64(1_760_000_000_000 + 3600000))},"weekly":{"used":1,"cap":35,"resetAt":\#(Int64(1_760_000_000_000 + 86400000))}}}"#
        let windows = try CommandCodeUsageProvider.normalizeCredits(data: Data(json.utf8), now: now)
        #expect(windows.count == 2)
    }

    // MARK: R3/R4 — exceeded corroborates only

    @Test func exceededDoesNotCreateBlockingWithoutCapacityMath() throws {
        // exceeded true but used < cap → not blocking.
        let data = Data(#"{"windowLimits":{"fiveHour":{"used":1,"cap":14,"exceeded":true,"resetAt":\#(Int64(1_760_000_000_000 + 3600000))},"weekly":{"used":1,"cap":35,"resetAt":\#(Int64(1_760_000_000_000 + 86400000))}}}"#.utf8)
        let windows = try CommandCodeUsageProvider.normalizeCredits(data: data, now: now)
        #expect(windows.first { $0.id == .fiveHour }?.isBlocking == false)
    }

    // MARK: AC4 — headers

    @Test func ac4_headersContainBearerAndTruthfulUA() async throws {
        defer { CommandCodeStubProtocol.responders.removeAll(); CommandCodeStubProtocol.recorded.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommandCodeStubProtocol.self]
        CommandCodeStubProtocol.responders[creditsURL] = { _ in .init(status: 200, body: self.creditsJSON(), headers: [:]) }
        CommandCodeStubProtocol.responders[subsURL] = { _ in .init(status: 200, body: self.subsJSON(), headers: [:]) }
        let provider = CommandCodeUsageProvider(session: URLSession(configuration: config), now: { now })
        _ = try await provider.fetchUsage(credentials: CommandCodeCredentials(apiKey: "user_secret"))
        let headers = CommandCodeStubProtocol.recorded.first { $0.url == creditsURL }?.headers ?? [:]
        #expect(headers["Authorization"] == "Bearer user_secret")
        #expect(headers["Accept"] == "application/json")
        #expect(headers["User-Agent"] == CommandCodeUsageProvider.userAgent)
        #expect(!headers.values.joined().contains("user_secret") == false) // bearer present; ensure not logged elsewhere is tested elsewhere
        // Truthful UA must be command-code-cli, not agent-usage-widget.
        #expect(headers["User-Agent"]?.contains("command-code-cli") == true)
        // Do not leak secret to logs: second request also has bearer but no other leakage; just assert bearer only in auth header.
        for entry in CommandCodeStubProtocol.recorded {
            // Only Authorization header should contain the secret; URL must not.
            #expect(!entry.url.absoluteString.contains("user_secret"))
        }
    }

    // MARK: AC2 — plan metadata independence

    @Test func ac2_subscriptionFailureDoesNotInvalidateWindows() async throws {
        defer { CommandCodeStubProtocol.responders.removeAll(); CommandCodeStubProtocol.recorded.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommandCodeStubProtocol.self]
        CommandCodeStubProtocol.responders[creditsURL] = { _ in .init(status: 200, body: self.creditsJSON(), headers: [:]) }
        CommandCodeStubProtocol.responders[subsURL] = { _ in .init(status: 500, body: "", headers: [:]) }
        let provider = CommandCodeUsageProvider(session: URLSession(configuration: config), now: { now })
        let result = try await provider.fetchUsage(credentials: CommandCodeCredentials(apiKey: "k"))
        #expect(result.windows.count == 2)
        #expect(result.metadataWarning != nil)
    }

    // MARK: R5 — credits failure cannot be rescued by subscription

    @Test func r5_creditsFailureThrowsEvenIfSubscriptionWouldSucceed() async throws {
        defer { CommandCodeStubProtocol.responders.removeAll(); CommandCodeStubProtocol.recorded.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommandCodeStubProtocol.self]
        CommandCodeStubProtocol.responders[creditsURL] = { _ in .init(status: 500, body: "", headers: [:]) }
        CommandCodeStubProtocol.responders[subsURL] = { _ in .init(status: 200, body: self.subsJSON(), headers: [:]) }
        let provider = CommandCodeUsageProvider(session: URLSession(configuration: config), now: { now })
        do { _ = try await provider.fetchUsage(credentials: CommandCodeCredentials(apiKey: "k")); Issue.record("expected throw") } catch let e as CommandCodeUsageError {
            if case .http = e {} else { Issue.record("expected http, got \(e)") }
        }
    }

    // MARK: Status mapping

    @Test func transport_401And429Mapped() async throws {
        defer { CommandCodeStubProtocol.responders.removeAll(); CommandCodeStubProtocol.recorded.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommandCodeStubProtocol.self]
        CommandCodeStubProtocol.responders[creditsURL] = { _ in .init(status: 401, body: "", headers: [:]) }
        CommandCodeStubProtocol.responders[subsURL] = { _ in .init(status: 200, body: self.subsJSON(), headers: [:]) }
        let provider = CommandCodeUsageProvider(session: URLSession(configuration: config), now: { now })
        do { _ = try await provider.fetchUsage(credentials: CommandCodeCredentials(apiKey: "k")); Issue.record("expected throw") } catch let e as CommandCodeUsageError {
            #expect(e == .unauthorized(status: 401))
        }
        CommandCodeStubProtocol.responders.removeAll(); CommandCodeStubProtocol.recorded.removeAll()
        CommandCodeStubProtocol.responders[creditsURL] = { _ in .init(status: 429, body: "", headers: ["Retry-After": "17"]) }
        CommandCodeStubProtocol.responders[subsURL] = { _ in .init(status: 200, body: self.subsJSON(), headers: [:]) }
        do { _ = try await provider.fetchUsage(credentials: CommandCodeCredentials(apiKey: "k")); Issue.record("expected throw") } catch let e as CommandCodeUsageError {
            #expect(e == .rateLimited(retryAfter: 17))
        }
    }

    // MARK: Edge cases

    @Test func epochOverflowYieldsNoWindow() throws {
        let huge: Int64 = 8_640_000_000_000_001
        let data = Data(#"{"windowLimits":{"fiveHour":{"used":1,"cap":14,"resetAt":\#(huge)},"weekly":{"used":1,"cap":35,"resetAt":\#(Int64(1_760_000_000_000 + 86400000))}}}"#.utf8)
        #expect(try CommandCodeUsageProvider.normalizeCredits(data: data, now: now).count == 1)
    }

    @Test func staleResetYieldsNoWindow() throws {
        let stale: Int64 = Int64(now.timeIntervalSince1970 * 1000) - 10_000
        let data = Data(#"{"windowLimits":{"fiveHour":{"used":1,"cap":14,"resetAt":\#(stale)},"weekly":{"used":1,"cap":35,"resetAt":\#(Int64(1_760_000_000_000 + 86400000))}}}"#.utf8)
        #expect(try CommandCodeUsageProvider.normalizeCredits(data: data, now: now).count == 1)
        // Both stale → empty
        let both: Int64 = Int64(now.timeIntervalSince1970 * 1000) - 10_000
        let data2 = Data(#"{"windowLimits":{"fiveHour":{"used":1,"cap":14,"resetAt":\#(both)},"weekly":{"used":1,"cap":35,"resetAt":\#(both)}}}"#.utf8)
        #expect(try CommandCodeUsageProvider.normalizeCredits(data: data2, now: now).isEmpty)
    }

    @Test @MainActor func inactiveSubscriptionMapsToAuthAtManagerLayer() async throws {
        defer { CommandCodeStubProtocol.responders.removeAll(); CommandCodeStubProtocol.recorded.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommandCodeStubProtocol.self]
        CommandCodeStubProtocol.responders[creditsURL] = { _ in .init(status: 200, body: self.creditsJSON(), headers: [:]) }
        CommandCodeStubProtocol.responders[subsURL] = { _ in .init(status: 200, body: self.subsJSON(planId: "individual-goat", status: "inactive"), headers: [:]) }
        let store = InMemoryCredentialStore()
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cc-\(UUID().uuidString).json")
        let manager = CommandCodeConnectionManager(
            controller: CommandCodeAccountController(keychain: store, connectionsFileURL: file),
            provider: CommandCodeUsageProvider(session: URLSession(configuration: config), now: { now }),
            now: { now })
        let authFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cca-\(UUID().uuidString).json")
        try Data(#"{"apiKey":"k"}"#.utf8).write(to: authFile)
        try manager.connect(slotID: .commandCodeGOAT, file: authFile)
        let outcome = await manager.refresh(slotID: .commandCodeGOAT)
        #expect(outcome == .authenticationRequired)
    }

    // MARK: Inactive 5-hour window

    @Test func inactiveFiveHourWindowYieldsEstimatedWindowNotMissing() throws {
        // The official endpoint reports used 0 / resetAt 0 while no 5-hour
        // window is running; that must not degrade the slot to "missing
        // required window" — the account is genuinely available.
        let data = Data(creditsJSON(
            fiveHour: (0, 14, 0),
            weekly: (24.94, 35, 1_760_000_000_000 + 86_400_000)).utf8)
        let windows = try CommandCodeUsageProvider.normalizeCredits(data: data, now: now)
        let five = windows.first { $0.id == .fiveHour }
        #expect(five != nil)
        #expect(five?.used == 0)
        #expect(five?.resetAt == now.addingTimeInterval(5 * 60 * 60))
        #expect(five?.sourceDiagnostics.notes.contains("5-hour window inactive; reset time estimated") == true)
        let slot = AccountCatalog.slot(for: .commandCodeGOAT)!
        let snap = UsageSnapshot(slotID: .commandCodeGOAT, provider: .commandCode, windows: windows, capturedAt: now)
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snap, now: now).status == .available)
    }

    @Test func inactiveFiveHourWithExceededFlagIsStillIncomplete() throws {
        // exceeded:true with resetAt 0 is contradictory data — reject (AC3).
        let data = Data(#"{"windowLimits":{"fiveHour":{"used":0,"cap":14,"exceeded":true,"resetAt":0},"weekly":{"used":1,"cap":35,"resetAt":\#(Int64(1_760_000_000_000 + 86_400_000)),"exceeded":false}}}"#.utf8)
        let windows = try CommandCodeUsageProvider.normalizeCredits(data: data, now: now)
        #expect(windows.first { $0.id == .fiveHour } == nil)
    }

    @Test func activeButZeroResetWithUsageIsStillIncomplete() throws {
        // used > 0 with resetAt 0 is genuinely malformed — no window (AC3).
        let data = Data(creditsJSON(
            fiveHour: (3, 14, 0),
            weekly: (1, 35, 1_760_000_000_000 + 86_400_000)).utf8)
        let windows = try CommandCodeUsageProvider.normalizeCredits(data: data, now: now)
        #expect(windows.first { $0.id == .fiveHour } == nil)
    }
}
