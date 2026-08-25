import Testing
import Foundation
@testable import AgentUsageCore

/// Dedicated URLProtocol stub for the manager suite: separate static registry
/// from `CodexStubProtocol` so concurrent suites cannot interfere.
final class CodexManagerStubProtocol: URLProtocol {

    struct Response {
        let status: Int
        let body: String
    }

    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.responder?(request) ?? Response(status: 500, body: "")
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.status == 429 ? ["Retry-After": "17"] : [:])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Connection lifecycle tests for the GPT Personal slot (child spec R1/R7,
/// AC4; parent R12/R13/I2). Fake Keychain, fixture directories, no network.
@Suite(.serialized)
struct CodexAccountControllerTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Context {
        let controller: CodexAccountController
        let store: InMemoryCredentialStore
        let connectionsFile: URL
        let codexDirectory: URL
        let claudeDirectory: URL

        var claudeController: ClaudeAccountController {
            ClaudeAccountController(keychain: store,
                                    connectionsFileURL: claudeConnectionsFile)
        }
        let claudeConnectionsFile: URL
    }

    /// Build a temp world: fake keychain + two fixture profile directories.
    private func makeContext() throws -> Context {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let codexConnections = root.appendingPathComponent("codex-connections.json")
        let claudeConnections = root.appendingPathComponent("claude-connections.json")

        return Context(
            controller: CodexAccountController(keychain: store, connectionsFileURL: codexConnections),
            store: store,
            connectionsFile: codexConnections,
            codexDirectory: try Self.makeCodexProfile(at: root, name: "codex",
                                                      token: "tok-openai", accountID: "acct-1"),
            claudeDirectory: try Self.makeClaudeProfile(at: root, name: "claude",
                                                        token: "tok-claude", uuid: "uuid-claude"),
            claudeConnectionsFile: claudeConnections)
    }

    private static func write(_ document: [String: Any], to directory: URL, file: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document)
            .write(to: directory.appendingPathComponent(file))
        return directory
    }

    private static func makeCodexProfile(at root: URL, name: String,
                                         token: String, accountID: String?) throws -> URL {
        var tokens: [String: Any] = ["access_token": token]
        if let accountID { tokens["account_id"] = accountID }
        return try write(["auth_mode": "chatgpt", "tokens": tokens],
                         to: root.appendingPathComponent("profile-\(name)-\(UUID().uuidString)"),
                         file: "auth.json")
    }

    private static func makeClaudeProfile(at root: URL, name: String,
                                          token: String, uuid: String) throws -> URL {
        try write(["claudeAiOauth": ["accessToken": token, "accountUuid": uuid]],
                  to: root.appendingPathComponent("profile-\(name)-\(UUID().uuidString)"),
                  file: ".credentials.json")
    }

    // MARK: Connect — explicit consent imports material (AC3/parent AC3)

    @Test func connectImportsCredentialsIntoSlotKeychainEntry() throws {
        let context = try makeContext()
        let connection = try context.controller.connect(
            slotID: .gptPersonal, directory: context.codexDirectory, now: now)

        #expect(context.store.codexCredentials(account: .gptPersonal)?.accessToken == "tok-openai")
        #expect(context.store.codexCredentials(account: .gptPersonal)?.accountID == "acct-1")
        #expect(connection.importedIdentity.accountID == "acct-1")
        #expect(context.controller.isConnected(.gptPersonal))
        #expect(connection.source.directoryName.hasPrefix("profile-codex-"))
    }

    @Test func connectWithoutUsableMaterialFailsWithoutSideEffects() throws {
        let context = try makeContext()
        let empty = context.connectionsFile.deletingLastPathComponent()
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(throws: CodexConnectionError.noUsableCredentials) {
            try context.controller.connect(slotID: .gptPersonal, directory: empty, now: now)
        }
        #expect(context.store.codexCredentials(account: .gptPersonal) == nil)
        #expect(!context.controller.isConnected(.gptPersonal))
    }

    @Test func apiKeyOnlyDirectoryIsRejected() throws {
        let context = try makeContext()
        let apiOnly = context.connectionsFile.deletingLastPathComponent()
            .appendingPathComponent("apionly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: apiOnly, withIntermediateDirectories: true)
        try Data(#"{"auth_mode":"apikey"}"#.utf8)
            .write(to: apiOnly.appendingPathComponent("auth.json"))

        #expect(throws: CodexConnectionError.noUsableCredentials) {
            try context.controller.connect(slotID: .gptPersonal, directory: apiOnly, now: now)
        }
    }

    @Test func foreignProviderDirectoryIsRejectedWithoutSideEffects() throws {
        let context = try makeContext()

        // A Claude profile directory holds no Codex material: connecting it to
        // the GPT Personal slot fails as unusable BEFORE any import happens.
        _ = try context.claudeController.connect(
            slotID: .claude, directory: context.claudeDirectory, now: now)
        #expect(throws: CodexConnectionError.noUsableCredentials) {
            try context.controller.connect(slotID: .gptPersonal, directory: context.claudeDirectory, now: now)
        }
        #expect(context.store.codexCredentials(account: .gptPersonal) == nil)
        #expect(!context.controller.isConnected(.gptPersonal))

        // Symmetrically, a Codex auth.json is unusable for a Claude slot with a fresh controller.
        let freshClaude = ClaudeAccountController(keychain: context.store, connectionsFileURL: context.claudeConnectionsFile.deletingLastPathComponent().appendingPathComponent("claude-fresh-\(UUID().uuidString).json"))
        #expect(throws: ConnectionControllerError.noUsableCredentials) {
            try freshClaude.connect(slotID: .claude, directory: context.codexDirectory, now: now)
        }
        #expect(!freshClaude.isConnected(.claude))
        #expect(!context.controller.isConnected(.gptPersonal))
    }

    @Test func connectionsFileCarriesNoSecrets() throws {
        let context = try makeContext()
        _ = try context.controller.connect(slotID: .gptPersonal, directory: context.codexDirectory, now: now)

        let raw = try String(contentsOf: context.connectionsFile, encoding: .utf8)
        #expect(!raw.contains("tok-openai"))
        #expect(raw.contains("directoryIdentity"))
    }

    // MARK: Synchronize — identity rules (R7/AC4)

    @Test func syncRestoresMissingKeychainWhenSourceIdentityMatches() throws {
        let context = try makeContext()
        _ = try context.controller.connect(slotID: .gptPersonal, directory: context.codexDirectory, now: now)

        // Simulate the stored copy vanishing while the source stays intact.
        context.store.deleteCodexCredentials(account: .gptPersonal)
        _ = try context.controller.synchronize(slotID: .gptPersonal, now: now.addingTimeInterval(60))

        #expect(context.store.codexCredentials(account: .gptPersonal)?.accessToken == "tok-openai")
    }

    @Test func syncWithRotatedTokenRefreshesStoredCopy() throws {
        let context = try makeContext()
        _ = try context.controller.connect(slotID: .gptPersonal, directory: context.codexDirectory, now: now)

        // Same identity (same account id), rotated secret → sync refreshes it.
        let rotated = try Self.write(
            ["auth_mode": "chatgpt", "tokens": ["access_token": "tok-rotated", "account_id": "acct-1"]],
            to: context.codexDirectory, file: "auth.json")
        _ = rotated
        _ = try context.controller.synchronize(slotID: .gptPersonal, now: now.addingTimeInterval(60))

        #expect(context.store.codexCredentials(account: .gptPersonal)?.accessToken == "tok-rotated")
    }

    @Test func sourceIdentityChangeStopsSyncWithoutOverwriting() throws {
        let context = try makeContext()
        _ = try context.controller.connect(slotID: .gptPersonal, directory: context.codexDirectory, now: now)

        // A different ChatGPT identity appears behind the bound directory.
        _ = try Self.write(
            ["auth_mode": "chatgpt", "tokens": ["access_token": "tok-other", "account_id": "acct-other"]],
            to: context.codexDirectory, file: "auth.json")

        #expect(throws: CodexConnectionError.sourceIdentityChanged) {
            try context.controller.synchronize(slotID: .gptPersonal, now: now.addingTimeInterval(60))
        }
        // The stored secret was not overwritten by the foreign identity.
        #expect(context.store.codexCredentials(account: .gptPersonal)?.accessToken == "tok-openai")
    }

    // MARK: Disconnect — app-owned material only (I2)

    @Test func disconnectRemovesOnlyCodexSlotMaterial() throws {
        let context = try makeContext()
        _ = try context.controller.connect(slotID: .gptPersonal, directory: context.codexDirectory, now: now)
        _ = try context.claudeController.connect(
            slotID: .claude, directory: context.claudeDirectory, now: now)

        context.controller.disconnect(slotID: .gptPersonal)

        #expect(!context.controller.isConnected(.gptPersonal))
        #expect(context.store.codexCredentials(account: .gptPersonal) == nil)
        // The sibling provider's slot is untouched.
        #expect(context.claudeController.isConnected(.claude))
        #expect(context.store.credentials(account: .claude)?.accessToken == "tok-claude")
        // The external profile is never modified and the user stays signed in.
        #expect(FileManager.default.fileExists(
            atPath: context.codexDirectory.appendingPathComponent("auth.json").path))
    }
}

/// Manager-level refresh outcomes through the model seam (child spec R4).
@Suite(.serialized)
@MainActor
struct CodexConnectionManagerTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeManager(
        store: InMemoryCredentialStore,
        connectionsFile: URL,
        responders: @escaping (URLRequest) -> CodexManagerStubProtocol.Response
    ) -> CodexConnectionManager {
        CodexManagerStubProtocol.responder = responders
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexManagerStubProtocol.self]
        return CodexConnectionManager(
            controller: CodexAccountController(keychain: store, connectionsFileURL: connectionsFile),
            provider: CodexUsageProvider(session: URLSession(configuration: configuration),
                                         now: { self.now }),
            now: { self.now })
    }

    @Test func refreshReturnsUpdatedSnapshotWithWeeklyWindow() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, connectionsFile: root.appendingPathComponent("codex.json")) { _ in
            CodexManagerStubProtocol.Response(status: 200, body: #"{"rate_limit":{"allowed":true,"primary_window":{"used_percent":33,"reset_at":\#(1_760_000_000 + 86_400)}}}"#)
        }
        defer { CodexManagerStubProtocol.responder = nil }

        let directory = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"tok-a","account_id":"acct-a"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))
        try manager.connect(slotID: .gptPersonal, directory: directory)

        let outcome = await manager.refresh(slotID: .gptPersonal)
        guard case let .updated(snapshot) = outcome else {
            Issue.record("expected updated, got \(outcome)")
            return
        }
        #expect(snapshot.slotID == .gptPersonal)
        #expect(snapshot.provider == .gpt)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].id == .weekly)
        #expect(snapshot.windows[0].used == 33)
    }

    @Test func refreshWithIncompleteWeeklyDataMapsToFailedNotAuth() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, connectionsFile: root.appendingPathComponent("codex.json")) { _ in
            CodexManagerStubProtocol.Response(status: 200, body: #"{"rate_limit":{"allowed":true,"primary_window":{"used_percent":10}}}"#)
        }
        defer { CodexManagerStubProtocol.responder = nil }

        let directory = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"tok-a"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))
        try manager.connect(slotID: .gptPersonal, directory: directory)

        let outcome = await manager.refresh(slotID: .gptPersonal)
        guard case let .updated(snapshot) = outcome else {
            Issue.record("expected updated empty snapshot (UNAVAILABLE), got \(outcome)")
            return
        }
        #expect(snapshot.windows.isEmpty)
        // Through engine it derives UNAVAILABLE, never failed/auth.
        let slot = AccountCatalog.slot(for: .gptPersonal)!
        #expect(AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: Date()).status == .unavailable)
    }

    @Test func unauthorizedResponseMapsToAuthenticationRequired() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let manager = makeManager(store: store, connectionsFile: root.appendingPathComponent("codex.json")) { _ in
            CodexManagerStubProtocol.Response(status: 401, body: "")
        }
        defer { CodexManagerStubProtocol.responder = nil }

        let directory = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"tok-a"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))
        try manager.connect(slotID: .gptPersonal, directory: directory)

        let outcome = await manager.refresh(slotID: .gptPersonal)
        #expect(outcome == .authenticationRequired)
    }
}
