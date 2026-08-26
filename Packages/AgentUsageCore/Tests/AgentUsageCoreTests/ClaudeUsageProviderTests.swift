import Testing
import Foundation
import XCTest
@testable import AgentUsageCore

/// Contract tests for the Claude usage transport and normalization (child spec
/// R4–R7, AC2/AC3/AC5). Transport is stubbed with URLProtocol; no real network.
/// Serialized because the stub registry is shared per-process.
@Suite(.serialized)
@MainActor struct ClaudeUsageProviderTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: AC2 — successful aggregate normalization

    @Test func ac2_aggregatePayloadNormalizesBothWindows() throws {
        let json = """
        {"five_hour": {"utilization": 42.5, "resets_at": "\(iso(secondsFromNow: 1800))"},
         "seven_day": {"utilization": 12.0, "resets_at": "\(iso(secondsFromNow: 3 * 86_400))"}}
        """
        let windows = try ClaudeUsageProvider.normalize(data: Data(json.utf8), now: now)

        #expect(windows.count == 2)
        let fiveHour = windows.first { $0.id == .fiveHour }
        let weekly = windows.first { $0.id == .weekly }
        #expect(fiveHour?.used == 42.5)
        #expect(fiveHour?.limit == 100)
        #expect(fiveHour?.resetAt == now.addingTimeInterval(1800))
        #expect(weekly?.used == 12.0)
        #expect(weekly?.resetAt == now.addingTimeInterval(3 * 86_400))
    }

    // MARK: AC3 — variant payloads

    @Test func ac3_exactKeyWinsOverVariants() throws {
        let json = """
        {"five_hour": {"utilization": 10, "resets_at": "\(iso(secondsFromNow: 1000))"},
         "five_hour_opus": {"utilization": 90, "resets_at": "\(iso(secondsFromNow: 2000))"}}
        """
        let windows = try ClaudeUsageProvider.normalize(data: Data(json.utf8), now: now)
        let fiveHour = windows.first { $0.id == .fiveHour }
        #expect(fiveHour?.used == 10)
        #expect(fiveHour?.sourceDiagnostics.notes.isEmpty == true)
    }

    @Test func ac3_variantPicksMostConstrainedLatestResetOnTie() throws {
        // No aggregate key; opus variant is more constrained than sonnet.
        let json = """
        {"seven_day_sonnet": {"utilization": 30, "resets_at": "\(iso(secondsFromNow: 86_400))"},
         "seven_day_opus": {"utilization": 75, "resets_at": "\(iso(secondsFromNow: 90_000))"}}
        """
        let windows = try ClaudeUsageProvider.normalize(data: Data(json.utf8), now: now)
        let weekly = windows.first { $0.id == .weekly }
        #expect(weekly?.used == 75)
        #expect(weekly?.resetAt == now.addingTimeInterval(90_000))
        #expect(weekly?.sourceDiagnostics.notes.contains("normalized from seven_day_opus") == true)
    }

    @Test func ac3_tiedUtilizationPrefersLatestReset() throws {
        let json = """
        {"five_hour_a": {"utilization": 50, "resets_at": "\(iso(secondsFromNow: 1000))"},
         "five_hour_b": {"utilization": 50, "resets_at": "\(iso(secondsFromNow: 2000))"}}
        """
        let windows = try ClaudeUsageProvider.normalize(data: Data(json.utf8), now: now)
        let fiveHour = windows.first { $0.id == .fiveHour }
        #expect(fiveHour?.resetAt == now.addingTimeInterval(2000))
    }

    @Test func ac3_unknownKeysIgnored() throws {
        let json = """
        {"five_hour": {"utilization": 20, "resets_at": "\(iso(secondsFromNow: 900))"},
         "code_execution": {"utilization": 99, "resets_at": "\(iso(secondsFromNow: 1))"},
         "team_member": {"utilization": 99, "resets_at": "\(iso(secondsFromNow: 2))"}}
        """
        let windows = try ClaudeUsageProvider.normalize(data: Data(json.utf8), now: now)
        #expect(windows.count == 1)
        #expect(windows.first?.id == .fiveHour)
    }

    // MARK: R6 — missing/null data never becomes zero usage

    @Test func r6_missingWindowYieldsNoWindowNotZero() throws {
        let json = """
        {"five_hour": {"utilization": 30, "resets_at": "\(iso(secondsFromNow: 1200))"}}
        """
        let windows = try ClaudeUsageProvider.normalize(data: Data(json.utf8), now: now)
        #expect(windows.count == 1)
        #expect(windows.first?.id == .fiveHour)
    }

    @Test func r6_nullWindowAndNullResetAndNullUtilizationAreIncomplete() throws {
        let json = """
        {"five_hour": null,
         "seven_day": {"utilization": null, "resets_at": null}}
        """
        let windows = try ClaudeUsageProvider.normalize(data: Data(json.utf8), now: now)
        #expect(windows.isEmpty)
    }

    @Test func r6_unparseableResetTimestampIsIncomplete() throws {
        let json = """
        {"five_hour": {"utilization": 30, "resets_at": "not-a-date"}}
        """
        let windows = try ClaudeUsageProvider.normalize(data: Data(json.utf8), now: now)
        #expect(windows.isEmpty)
    }

    @Test func undecodablePayloadThrowsTransportError() {
        #expect(throws: ClaudeUsageError.transport("undecodable usage payload")) {
            _ = try ClaudeUsageProvider.normalize(data: Data("[]".utf8), now: now)
        }
    }

    // MARK: AC5 — failure mapping over stubbed transport

    @Test func ac5_httpStatusMapping() async throws {
        try await assertStatus(200) { result in
            if case .updated = result {} else { Issue.record("expected updated") }
        }
        try await assertStatus(401) { result in
            #expect(result == .authenticationRequired)
        }
        try await assertStatus(403) { result in
            #expect(result == .authenticationRequired)
        }
        try await assertStatus(429) { result in
            // 429 must surface the server-directed Retry-After to the scheduler
            // (R7) instead of a blind backoff failure.
            if case .rateLimited = result {} else { Issue.record("429 must be rateLimited with Retry-After") }
        }
        try await assertStatus(500) { result in
            if case .failed = result {} else { Issue.record("5xx must be a degraded failure") }
        }
    }

    @Test func rateLimitedCarriesServerRetryAfter() async throws {
        StubProtocol.responders[StubProtocol.usageURL] = { _ in
            StubProtocol.Response(status: 429, body: "{}", headers: ["Retry-After": "3306"])
        }
        defer { StubProtocol.responders.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let manager = ClaudeConnectionManager(
            controller: try controllerWithStoredCredential(),
            provider: ClaudeUsageProvider(session: URLSession(configuration: configuration), now: { self.now }))
        let outcome = await manager.refresh(slotID: .claude)
        guard case let .rateLimited(retryAfter) = outcome else {
            Issue.record("expected rateLimited, got \(outcome)"); return
        }
        #expect(retryAfter == 3306)
    }

    private func assertStatus(
        _ status: Int,
        assertion: (ClaudeRefreshOutcome) -> Void
    ) async throws {
        StubProtocol.responders[StubProtocol.usageURL] = { _ in
            StubProtocol.Response(status: status, body: "{}")
        }
        defer { StubProtocol.responders.removeAll() }

        // Protocol classes must be installed on the configuration BEFORE the
        // session copies it; otherwise requests escape to the real network.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let manager = ClaudeConnectionManager(
            controller: try controllerWithStoredCredential(),
            provider: ClaudeUsageProvider(session: session, now: { self.now }))
        let outcome = await manager.refresh(slotID: .claude)
        assertion(outcome)
    }

    private func controllerWithStoredCredential() throws -> ClaudeAccountController {
        let dir = try ClaudeFixtures.makeDirectory(name: "stub", token: "tok", uuid: "u")
        return ClaudeFixtures.makeController().tap {
            _ = try? $0.connect(slotID: .claude, directory: dir, now: now)
        }
    }

    private func iso(secondsFromNow interval: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(interval))
    }
}

extension ClaudeAccountController {
    fileprivate func tap(_ block: (ClaudeAccountController) throws -> Void) -> ClaudeAccountController {
        do { try block(self) } catch { Issue.record("fixture connect failed: \(error)") }
        return self
    }
}
