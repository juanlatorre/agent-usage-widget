import Testing
import Foundation
@testable import AgentUsageCore

@Suite(.serialized)
struct ZaiAccountControllerTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Context {
        let controller: ZaiAccountController
        let store: InMemoryCredentialStore
        let file: URL
        let authFile: URL
    }

    private func makeContext() throws -> Context {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentusage-zai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let file = root.appendingPathComponent("zai-connections.json")
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"zai-coding-plan":{"type":"api","key":"tok_orig"}}"#.utf8).write(to: authFile)
        return Context(controller: ZaiAccountController(keychain: store, connectionsFileURL: file), store: store, file: file, authFile: authFile)
    }

    @Test func connectImportsCredentials() throws {
        let ctx = try makeContext()
        let c = try ctx.controller.connect(slotID: .zaiCodingPlan, file: ctx.authFile, now: now)
        #expect(ctx.store.zaiCredentials(account: .zaiCodingPlan)?.apiKey == "tok_orig")
        #expect(c.importedIdentity.fingerprint == ZaiProfileSource.fingerprint("tok_orig"))
        #expect(ctx.controller.isConnected(.zaiCodingPlan))
    }

    @Test func connectionsFileCarriesNoSecrets() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .zaiCodingPlan, file: ctx.authFile, now: now)
        let raw = try String(contentsOf: ctx.file, encoding: .utf8)
        #expect(!raw.contains("tok_orig"))
    }

    @Test func connectWithoutUsableMaterialFails() throws {
        let ctx = try makeContext()
        let empty = ctx.authFile.deletingLastPathComponent().appendingPathComponent("empty.json")
        try Data("{}".utf8).write(to: empty)
        #expect(throws: ZaiConnectionError.noUsableCredentials) {
            try ctx.controller.connect(slotID: .zaiCodingPlan, file: empty, now: now)
        }
    }

    @Test func manualConnectStoresKey() throws {
        let ctx = try makeContext()
        let c = try ctx.controller.connectManually(slotID: .zaiCodingPlan, apiKey: "tok_manual", now: now)
        #expect(ctx.store.zaiCredentials(account: .zaiCodingPlan)?.apiKey == "tok_manual")
        #expect(c.source.fileName == "manual entry")
        #expect(c.source.bookmark.isEmpty)
    }

    @Test func manualConnectRejectsMalformedKey() throws {
        let ctx = try makeContext()
        #expect(throws: ZaiConnectionError.noUsableCredentials) {
            try ctx.controller.connectManually(slotID: .zaiCodingPlan, apiKey: "  ", now: now)
        }
        #expect(throws: ZaiConnectionError.noUsableCredentials) {
            try ctx.controller.connectManually(slotID: .zaiCodingPlan, apiKey: "tok bad", now: now)
        }
    }

    @Test func syncRefreshesWhenIdentityMatches() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .zaiCodingPlan, file: ctx.authFile, now: now)
        _ = try ctx.controller.synchronize(slotID: .zaiCodingPlan, now: now.addingTimeInterval(60))
        #expect(ctx.store.zaiCredentials(account: .zaiCodingPlan)?.apiKey == "tok_orig")
    }

    @Test func sourceIdentityChangeStopsSync() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .zaiCodingPlan, file: ctx.authFile, now: now)
        try Data(#"{"zai-coding-plan":{"key":"tok_other"}}"#.utf8).write(to: ctx.authFile)
        #expect(throws: ZaiConnectionError.sourceIdentityChanged) {
            try ctx.controller.synchronize(slotID: .zaiCodingPlan, now: now.addingTimeInterval(60))
        }
        #expect(ctx.store.zaiCredentials(account: .zaiCodingPlan)?.apiKey == "tok_orig")
    }

    @Test func manualSyncIsNoop() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connectManually(slotID: .zaiCodingPlan, apiKey: "tok_m", now: now)
        let c = try ctx.controller.synchronize(slotID: .zaiCodingPlan, now: now)
        #expect(c.importedIdentity.fingerprint == ZaiProfileSource.fingerprint("tok_m"))
    }

    @Test func disconnectRemovesOnlyThisSlot() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .zaiCodingPlan, file: ctx.authFile, now: now)
        ctx.controller.disconnect(slotID: .zaiCodingPlan)
        #expect(!ctx.controller.isConnected(.zaiCodingPlan))
        #expect(ctx.store.zaiCredentials(account: .zaiCodingPlan) == nil)
        #expect(FileManager.default.fileExists(atPath: ctx.authFile.path))
    }

    @Test func syncOnUnconnectedThrows() {
        let ctx = try! makeContext()
        #expect(throws: ZaiConnectionError.noUsableCredentials) {
            try ctx.controller.synchronize(slotID: .zaiCodingPlan)
        }
    }
}

@Suite(.serialized)
@MainActor
struct ZaiConnectionManagerTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var responder: ((URLRequest) -> (status: Int, body: String, headers: [String: String]))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (s, b, h) = Self.responder?(request) ?? (500, "", [:])
            let http = HTTPURLResponse(url: request.url!, statusCode: s, httpVersion: "HTTP/1.1", headerFields: h)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(b.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeManager(store: InMemoryCredentialStore, file: URL,
                             responder: @escaping (URLRequest) -> (Int, String, [String: String])) -> ZaiConnectionManager {
        Stub.responder = responder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return ZaiConnectionManager(
            controller: ZaiAccountController(keychain: store, connectionsFileURL: file),
            provider: ZaiUsageProvider(session: URLSession(configuration: config), now: { now }),
            now: { now })
    }

    private func quotaBody(percentage: Double = 42.5) -> String {
        let reset = 1_760_000_000_000 + 3_600_000
        return #"{"code":0,"success":true,"data":{"level":"pro","limits":[{"type":"TOKENS_LIMIT","percentage":\#(percentage),"nextResetTime":\#(Double(reset))},{"type":"TIME_LIMIT","usage":500,"currentValue":123,"nextResetTime":\#(Double(reset))}]}}"#
    }

    @Test func refreshReturnsSingleFiveHourWindowTimeLimitIgnored() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zai-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, file: root.appendingPathComponent("zai.json")) { _ in (200, self.quotaBody(), [:]) }
        defer { Stub.responder = nil }
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"zai-coding-plan":{"key":"k"}}"#.utf8).write(to: authFile)
        try manager.connect(slotID: .zaiCodingPlan, file: authFile)
        let outcome = await manager.refresh(slotID: .zaiCodingPlan)
        guard case let .updated(snap) = outcome else { Issue.record("expected updated, got \(outcome)"); return }
        #expect(snap.windows.count == 1)
        #expect(snap.windows[0].id == .fiveHour)
        #expect(snap.windows[0].used == 42.5)
        #expect(snap.provider == .zai)
    }

    @Test func bothAuthFormsRejectedMapsToAuth() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zai-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, file: root.appendingPathComponent("zai.json")) { _ in (401, "", [:]) }
        defer { Stub.responder = nil }
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"zai-coding-plan":{"key":"k"}}"#.utf8).write(to: authFile)
        try manager.connect(slotID: .zaiCodingPlan, file: authFile)
        let outcome = await manager.refresh(slotID: .zaiCodingPlan)
        #expect(outcome == .authenticationRequired)
    }

    @Test func bearerThenRawSuccessPersists() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zai-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        var call = 0
        let manager = makeManager(store: store, file: root.appendingPathComponent("zai.json")) { req in
            call += 1
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer k" { return (401, "", [:]) }
            return (200, self.quotaBody(percentage: 11), [:])
        }
        defer { Stub.responder = nil }
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"zai-coding-plan":{"key":"k"}}"#.utf8).write(to: authFile)
        try manager.connect(slotID: .zaiCodingPlan, file: authFile)
        let outcome = await manager.refresh(slotID: .zaiCodingPlan)
        guard case let .updated(snap) = outcome else { Issue.record("expected updated, got \(outcome)"); return }
        #expect(snap.windows[0].used == 11)
        #expect(call == 2)
    }

    @Test func missingTokensLimitStillUpdatedDerivesUnavailable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zai-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, file: root.appendingPathComponent("zai.json")) { _ in
            let reset = Double(1_760_000_000_000 + 3_600_000)
            let body = #"{"code":0,"success":true,"data":{"limits":[{"type":"TIME_LIMIT","usage":500,"currentValue":1,"nextResetTime":\#(reset)}]}}"#
            return (200, body, [:])
        }
        defer { Stub.responder = nil }
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"zai-coding-plan":{"key":"k"}}"#.utf8).write(to: authFile)
        try manager.connect(slotID: .zaiCodingPlan, file: authFile)
        let outcome = await manager.refresh(slotID: .zaiCodingPlan)
        guard case let .updated(snap) = outcome else { Issue.record("expected updated, got \(outcome)"); return }
        #expect(snap.windows.isEmpty)
        let slot = AccountCatalog.slot(for: .zaiCodingPlan)!
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snap, now: Date()).status == .unavailable)
    }
}
