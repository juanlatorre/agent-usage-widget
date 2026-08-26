import Testing
import Foundation
@testable import AgentUsageCore

@Suite(.serialized)
struct OpenCodeAccountControllerTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Context {
        let controller: OpenCodeAccountController
        let store: InMemoryCredentialStore
        let connectionsFile: URL
        let authFile: URL
    }

    private func makeContext() throws -> Context {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let connectionsFile = root.appendingPathComponent("opencode-connections.json")
        let authFile = root.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["opencode-go": ["key": "sk-orig"]])
            .write(to: authFile)
        return Context(
            controller: OpenCodeAccountController(keychain: store, connectionsFileURL: connectionsFile),
            store: store, connectionsFile: connectionsFile, authFile: authFile)
    }

    @Test func connectImportsCredentialsIntoSlotKeychainEntry() throws {
        let ctx = try makeContext()
        let c = try ctx.controller.connect(slotID: .openCodeGO, file: ctx.authFile, now: now)
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk-orig")
        #expect(c.importedIdentity.fingerprint == OpenCodeProfileSource.fingerprint("sk-orig"))
        #expect(ctx.controller.isConnected(.openCodeGO))
    }

    @Test func connectionsFileCarriesNoSecrets() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .openCodeGO, file: ctx.authFile, now: now)
        let raw = try String(contentsOf: ctx.connectionsFile, encoding: .utf8)
        #expect(!raw.contains("sk-orig"))
        #expect(raw.contains("fileIdentity"))
    }

    @Test func connectWithoutUsableMaterialFailsWithoutSideEffects() throws {
        let ctx = try makeContext()
        let empty = ctx.authFile.deletingLastPathComponent().appendingPathComponent("empty.json")
        try Data("{}".utf8).write(to: empty)
        #expect(throws: OpenCodeConnectionError.noUsableCredentials) {
            try ctx.controller.connect(slotID: .openCodeGO, file: empty, now: now)
        }
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO) == nil)
        #expect(!ctx.controller.isConnected(.openCodeGO))
    }

    @Test func manualConnectStoresKeyWithoutFile() throws {
        let ctx = try makeContext()
        let c = try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: "sk-manual", now: now)
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk-manual")
        #expect(c.source.fileName == "manual entry")
        #expect(c.source.bookmark.isEmpty)
    }

    @Test func manualConnectRejectsMalformedKey() throws {
        let ctx = try makeContext()
        #expect(throws: OpenCodeConnectionError.noUsableCredentials) {
            try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: "   ", now: now)
        }
        #expect(throws: OpenCodeConnectionError.noUsableCredentials) {
            try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: "sk bad", now: now)
        }
    }

    @Test func syncRefreshesWhenIdentityMatches() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .openCodeGO, file: ctx.authFile, now: now)
        // Write a new key but same file — fingerprint changes, so this is an
        // identity mismatch scenario. To test same-identity sync, rewrite the
        // same key (idempotent sync path: same fingerprint).
        _ = try ctx.controller.synchronize(slotID: .openCodeGO, now: now.addingTimeInterval(60))
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk-orig")
    }

    @Test func sourceIdentityChangeStopsSyncWithoutOverwriting() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .openCodeGO, file: ctx.authFile, now: now)
        try JSONSerialization.data(withJSONObject: ["opencode-go": ["key": "sk-other"]])
            .write(to: ctx.authFile)
        #expect(throws: OpenCodeConnectionError.sourceIdentityChanged) {
            try ctx.controller.synchronize(slotID: .openCodeGO, now: now.addingTimeInterval(60))
        }
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk-orig")
    }

    @Test func manualConnectionSyncIsNoop() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: "sk-m", now: now)
        let c = try ctx.controller.synchronize(slotID: .openCodeGO, now: now)
        #expect(c.importedIdentity.fingerprint == OpenCodeProfileSource.fingerprint("sk-m"))
    }

    @Test func disconnectRemovesOnlyThisSlotMaterial() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connect(slotID: .openCodeGO, file: ctx.authFile, now: now)
        ctx.controller.disconnect(slotID: .openCodeGO)
        #expect(!ctx.controller.isConnected(.openCodeGO))
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO) == nil)
        #expect(FileManager.default.fileExists(atPath: ctx.authFile.path))
    }

    @Test func syncOnUnconnectedSlotThrows() {
        let ctx = try! makeContext()
        #expect(throws: OpenCodeConnectionError.noUsableCredentials) {
            try ctx.controller.synchronize(slotID: .openCodeGO)
        }
    }
    // MARK: Manual paste sanitization

    @Test func manualConnectSanitizesPastedSettingsBlob() throws {
        let ctx = try makeContext()
        try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: #"{"apiKey":"sk_pasted"}"#, now: now)
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk_pasted")
        try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: "Bearer sk_bearer_ok", now: now)
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk_bearer_ok")
        try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: "\"sk_quoted_ok\",", now: now)
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk_quoted_ok")
    }

    @Test func manualConnectAcceptsNativeAuthJSON() throws {
        let ctx = try makeContext()
        try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: #"{"opencode-go":{"key":"sk_native"}}"#, now: now)
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk_native")
    }

    @Test func sanitizerRejectsUnusableInput() {
        #expect(OpenCodeAccountController.sanitizedApiKey("   ") == nil)
        #expect(OpenCodeAccountController.sanitizedApiKey("garbage input") == nil)
        #expect(OpenCodeAccountController.sanitizedApiKey(#"{"apiKey":123}"#) == nil)
        #expect(OpenCodeAccountController.sanitizedApiKey("key=sk-embedded_ok123 note") == "sk-embedded_ok123")
        #expect(OpenCodeAccountController.sanitizedApiKey("  sk_padded  ") == "sk_padded")
    }

    @Test func credentialSelfHealsLegacyPastedJSONBlob() throws {
        let ctx = try makeContext()
        _ = try ctx.controller.connectManually(slotID: .openCodeGO, apiKey: "sk_real_key", now: now)
        try ctx.store.saveOpenCodeCredentials(
            OpenCodeCredentials(apiKey: #"{"apiKey":"sk_real_key"}"#), account: .openCodeGO)
        #expect(ctx.controller.credential(for: .openCodeGO)?.apiKey == "sk_real_key")
        #expect(ctx.store.openCodeCredentials(account: .openCodeGO)?.apiKey == "sk_real_key")
        let connection = ctx.controller.loadConnections()[.openCodeGO]
        #expect(connection?.importedIdentity.fingerprint == OpenCodeProfileSource.fingerprint("sk_real_key"))
    }
}

@Suite(.serialized)
@MainActor
struct OpenCodeConnectionManagerTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    final class ManagerStub: URLProtocol {
        nonisolated(unsafe) static var responder: ((URLRequest) -> (status: Int, body: String))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, body) = Self.responder?(request) ?? (500, "")
            let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: status == 429 ? ["Retry-After": "17"] : [:])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeManager(store: InMemoryCredentialStore, file: URL,
                             responder: @escaping (URLRequest) -> (Int, String)) -> OpenCodeConnectionManager {
        ManagerStub.responder = responder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManagerStub.self]
        return OpenCodeConnectionManager(
            controller: OpenCodeAccountController(keychain: store, connectionsFileURL: file),
            provider: OpenCodeUsageProvider(session: URLSession(configuration: config), now: { now }),
            now: { now })
    }

    @Test func refreshReturnsUpdatedSnapshotWithThreeWindows() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-opencode-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, file: root.appendingPathComponent("opencode.json")) { _ in
            let body = try! JSONSerialization.data(withJSONObject: [
                "rollingUsage": ["usagePercent": 10.0, "resetInSec": 3600],
                "weeklyUsage": ["usagePercent": 20.0, "resetInSec": 86400],
                "monthlyUsage": ["usagePercent": 30.0, "resetInSec": 2592000],
            ] as [String: Any])
            return (200, String(data: body, encoding: .utf8)!)
        }
        defer { ManagerStub.responder = nil }

        let authFile = root.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["opencode-go": ["key": "tok-a"]])
            .write(to: authFile)
        try manager.connect(slotID: .openCodeGO, file: authFile)

        let outcome = await manager.refresh(slotID: .openCodeGO)
        guard case let .updated(snapshot) = outcome else {
            Issue.record("expected updated, got \(outcome)"); return
        }
        #expect(snapshot.slotID == .openCodeGO)
        #expect(snapshot.provider == .opencode)
        #expect(snapshot.windows.count == 3)
        #expect(Set(snapshot.windows.map(\.id)) == [.fiveHour, .weekly, .monthly])
    }

    @Test func refreshWithIncompleteWindowsStillUpdatedDerivesUnavailable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-opencode-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, file: root.appendingPathComponent("opencode.json")) { _ in
            let body = try! JSONSerialization.data(withJSONObject: [
                "rollingUsage": ["usagePercent": 10.0, "resetInSec": 3600],
            ] as [String: Any])
            return (200, String(data: body, encoding: .utf8)!)
        }
        defer { ManagerStub.responder = nil }

        let authFile = root.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["opencode-go": ["key": "tok-a"]])
            .write(to: authFile)
        try manager.connect(slotID: .openCodeGO, file: authFile)

        let outcome = await manager.refresh(slotID: .openCodeGO)
        guard case let .updated(snapshot) = outcome else {
            Issue.record("expected updated empty/partial, got \(outcome)"); return
        }
        #expect(snapshot.windows.count == 1)
        let slot = AccountCatalog.slot(for: .openCodeGO)!
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: Date()).status == .unavailable)
    }

    @Test func unauthorizedMapsToAuthenticationRequired() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-opencode-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, file: root.appendingPathComponent("opencode.json")) { _ in (401, "") }
        defer { ManagerStub.responder = nil }

        let authFile = root.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["opencode-go": ["key": "tok-a"]])
            .write(to: authFile)
        try manager.connect(slotID: .openCodeGO, file: authFile)
        let outcome = await manager.refresh(slotID: .openCodeGO)
        #expect(outcome == .authenticationRequired)
    }
}
