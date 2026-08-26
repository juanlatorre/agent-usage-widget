import Testing
import Foundation
@testable import AgentUsageCore

@Suite(.serialized)
struct CommandCodeAccountControllerTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Context {
        let controller: CommandCodeAccountController
        let store: InMemoryCredentialStore
        let file: URL
        let authFile: URL
    }

    private func makeContext() throws -> Context {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-cc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let file = root.appendingPathComponent("commandcode-connections.json")
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"apiKey":"user_orig"}"#.utf8).write(to: authFile)
        return Context(controller: CommandCodeAccountController(keychain: store, connectionsFileURL: file),
                       store: store, file: file, authFile: authFile)
    }

    @Test func connectImportsCredentials() throws {
        let ctx = try makeContext()
        let c = try ctx.controller.connect(slotID: .commandCodeGOAT, file: ctx.authFile, now: now)
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_orig")
        #expect(c.importedIdentity.fingerprint == CommandCodeProfileSource.fingerprint("user_orig"))
        #expect(ctx.controller.isConnected(.commandCodeGOAT))
    }

    @Test func connectionsFileCarriesNoSecrets() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .commandCodeGOAT, file: ctx.authFile, now: now)
        let raw = try String(contentsOf: ctx.file, encoding: .utf8)
        #expect(!raw.contains("user_orig"))
    }

    @Test func connectWithoutUsableMaterialFails() throws {
        let ctx = try makeContext()
        let empty = ctx.authFile.deletingLastPathComponent().appendingPathComponent("empty.json")
        try Data("{}".utf8).write(to: empty)
        #expect(throws: CommandCodeConnectionError.noUsableCredentials) {
            try ctx.controller.connect(slotID: .commandCodeGOAT, file: empty, now: now)
        }
    }

    @Test func manualConnectStoresKey() throws {
        let ctx = try makeContext()
        let c = try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "user_manual", now: now)
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_manual")
        #expect(c.source.fileName == "manual entry")
        #expect(c.source.bookmark.isEmpty)
    }

    @Test func manualConnectRejectsMalformedKey() throws {
        let ctx = try makeContext()
        #expect(throws: CommandCodeConnectionError.noUsableCredentials) {
            try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "  ", now: now)
        }
        #expect(throws: CommandCodeConnectionError.noUsableCredentials) {
            try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "user bad", now: now)
        }
    }

    // MARK: Manual paste sanitization

    @Test func manualConnectSanitizesPastedSettingsJSON() throws {
        let ctx = try makeContext()
        let c = try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: #"{"apiKey":"user_sample_paste"}"#, now: now)
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_sample_paste")
        #expect(c.source.fileIdentity == "manual:\(CommandCodeProfileSource.fingerprint("user_sample_paste"))")
    }

    @Test func manualConnectSanitizesBearerQuotedAndEmbeddedKeys() throws {
        let ctx = try makeContext()
        try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "Bearer user_bearer_ok", now: now)
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_bearer_ok")
        try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "\"user_quoted_ok\",", now: now)
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_quoted_ok")
        try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "apiKey=user_embedded_ok and some text", now: now)
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_embedded_ok")
    }

    @Test func sanitizerRejectsUnusableInput() {
        #expect(CommandCodeAccountController.sanitizedApiKey("   ") == nil)
        #expect(CommandCodeAccountController.sanitizedApiKey("not a key at all") == nil)
        #expect(CommandCodeAccountController.sanitizedApiKey(#"{"apiKey":123}"#) == nil)
        #expect(CommandCodeAccountController.sanitizedApiKey("Bearer ") == nil)
        #expect(CommandCodeAccountController.sanitizedApiKey(#"{"api_key":"user_legacy"}"#) == "user_legacy")
        #expect(CommandCodeAccountController.sanitizedApiKey("  user_padded  ") == "user_padded")
    }

    @Test func credentialSelfHealsLegacyPastedJSONBlob() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "user_real_key", now: now)
        // Simulate a pre-sanitizer save: the whole settings blob stored as the key.
        try ctx.store.saveCommandCodeCredentials(
            CommandCodeCredentials(apiKey: #"{"apiKey":"user_real_key"}"#), account: .commandCodeGOAT)
        let healed = ctx.controller.credential(for: .commandCodeGOAT)
        #expect(healed?.apiKey == "user_real_key")
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_real_key")
        let connection = ctx.controller.loadConnections()[.commandCodeGOAT]
        #expect(connection?.importedIdentity.fingerprint == CommandCodeProfileSource.fingerprint("user_real_key"))
    }

    @Test func credentialLeavesWellFormedKeyUntouched() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "user_clean_key", now: now)
        _ = ctx.controller.credential(for: .commandCodeGOAT)
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_clean_key")
    }

    @Test func syncRefreshesWhenIdentityMatches() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .commandCodeGOAT, file: ctx.authFile, now: now)
        _ = try ctx.controller.synchronize(slotID: .commandCodeGOAT, now: now.addingTimeInterval(60))
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_orig")
    }

    @Test func sourceIdentityChangeStopsSync() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .commandCodeGOAT, file: ctx.authFile, now: now)
        try Data(#"{"apiKey":"user_other"}"#.utf8).write(to: ctx.authFile)
        #expect(throws: CommandCodeConnectionError.sourceIdentityChanged) {
            try ctx.controller.synchronize(slotID: .commandCodeGOAT, now: now.addingTimeInterval(60))
        }
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT)?.apiKey == "user_orig")
    }

    @Test func manualSyncIsNoop() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connectManually(slotID: .commandCodeGOAT, apiKey: "user_m", now: now)
        let c = try ctx.controller.synchronize(slotID: .commandCodeGOAT, now: now)
        #expect(c.importedIdentity.fingerprint == CommandCodeProfileSource.fingerprint("user_m"))
    }

    @Test func disconnectRemovesOnlyThisSlot() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .commandCodeGOAT, file: ctx.authFile, now: now)
        ctx.controller.disconnect(slotID: .commandCodeGOAT)
        #expect(!ctx.controller.isConnected(.commandCodeGOAT))
        #expect(ctx.store.commandCodeCredentials(account: .commandCodeGOAT) == nil)
        #expect(FileManager.default.fileExists(atPath: ctx.authFile.path))
    }

    @Test func syncOnUnconnectedThrows() {
        let ctx = try! makeContext()
        #expect(throws: CommandCodeConnectionError.noUsableCredentials) {
            try ctx.controller.synchronize(slotID: .commandCodeGOAT)
        }
    }
}

@Suite(.serialized)
@MainActor
struct CommandCodeConnectionManagerTests {

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
                             responder: @escaping (URLRequest) -> (Int, String, [String: String])) -> CommandCodeConnectionManager {
        Stub.responder = responder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return CommandCodeConnectionManager(
            controller: CommandCodeAccountController(keychain: store, connectionsFileURL: file),
            provider: CommandCodeUsageProvider(session: URLSession(configuration: config), now: { now }),
            now: { now })
    }

    private func creditsBody(fiveCap: Double = 14, weeklyCap: Double = 35) -> String {
        let fiveMs = Int64(1_760_000_000_000 + 3_600_000)
        let weekMs = Int64(1_760_000_000_000 + 86_400_000)
        return #"{"credits":{},"windowLimits":{"fiveHour":{"used":1,"cap":\#(fiveCap),"resetAt":\#(fiveMs)},"weekly":{"used":1,"cap":\#(weeklyCap),"resetAt":\#(weekMs)}}}"#
    }

    @Test func refreshReturnsUpdated() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cc-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, file: root.appendingPathComponent("cc.json")) { _ in
            // Need to distinguish credits vs subs by URL path.
            // Return credits for /credits, subs for /subscriptions.
            // If we can't distinguish, return credits-like for both — subs decoder will tolerate missing fields.
            // Simpler: branch on URL.
            return (200, "", [:])
        }
        // Override with URL-aware responder.
        Stub.responder = { req in
            if req.url?.path.contains("credits") == true {
                return (200, self.creditsBody(), [:])
            } else {
                return (200, #"{"success":true,"data":{"planId":"individual-goat","status":"active"}}"#, [:])
            }
        }
        defer { Stub.responder = nil }
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"apiKey":"k"}"#.utf8).write(to: authFile)
        try manager.connect(slotID: .commandCodeGOAT, file: authFile)
        let outcome = await manager.refresh(slotID: .commandCodeGOAT)
        guard case let .updated(snap) = outcome else { Issue.record("expected updated, got \(outcome)"); return }
        #expect(snap.windows.count == 2)
        #expect(snap.provider == .commandCode)
    }

    @Test func creditsFailureNotRescuedBySubscriptionSuccess() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cc-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        _ = makeManager(store: store, file: root.appendingPathComponent("cc.json")) { _ in (500, "", [:]) }
        Stub.responder = { req in
            if req.url?.path.contains("credits") == true { return (500, "", [:]) }
            return (200, #"{"success":true,"data":{"planId":"individual-goat","status":"active"}}"#, [:])
        }
        defer { Stub.responder = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
        let manager = CommandCodeConnectionManager(
            controller: CommandCodeAccountController(keychain: store, connectionsFileURL: root.appendingPathComponent("cc2.json")),
            provider: CommandCodeUsageProvider(session: URLSession(configuration: config), now: { now }),
            now: { now })
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"apiKey":"k"}"#.utf8).write(to: authFile)
        try manager.connect(slotID: .commandCodeGOAT, file: authFile)
        let outcome = await manager.refresh(slotID: .commandCodeGOAT)
        #expect(outcome == .failed)
    }

    @Test func unauthorizedMapsToAuth() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cc-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        Stub.responder = { req in
            if req.url?.path.contains("credits") == true { return (401, "", [:]) }
            return (200, #"{"success":true,"data":{"planId":"individual-goat","status":"active"}}"#, [:])
        }
        defer { Stub.responder = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
        let manager = CommandCodeConnectionManager(
            controller: CommandCodeAccountController(keychain: store, connectionsFileURL: root.appendingPathComponent("cc.json")),
            provider: CommandCodeUsageProvider(session: URLSession(configuration: config), now: { now }),
            now: { now })
        let authFile = root.appendingPathComponent("auth.json")
        try Data(#"{"apiKey":"k"}"#.utf8).write(to: authFile)
        try manager.connect(slotID: .commandCodeGOAT, file: authFile)
        let outcome = await manager.refresh(slotID: .commandCodeGOAT)
        #expect(outcome == .authenticationRequired)
    }
}
