import Testing
import Foundation
@testable import AgentUsage
import AgentUsageCore

/// App-model tests for the GPT Personal connection surface (child 03): connect
/// via manager, refresh outcome mapping, disconnect isolation. Uses in-memory
/// credential stores; no Keychain and no network are touched.
@MainActor
struct CodexSlotModelTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// Dedicated URLProtocol stub so this suite never races other suites' registries.
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: ((URLRequest) -> StubResponse)?
        struct StubResponse { let status: Int; let body: String }
        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = Self.responder?(request) ?? StubResponse(status: 500, body: "")
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage?limit_id=codex")!

    private struct Context {
        let model: StatusModel
        let store: InMemoryCredentialStore
        let connectionsFile: URL
        let codexDirectory: URL

        var controller: CodexAccountController {
            CodexAccountController(keychain: store, connectionsFileURL: connectionsFile)
        }
    }

    private func makeContext(responder: ((URLRequest) -> StubURLProtocol.StubResponse)? = nil) throws -> Context {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-codexmodel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let connectionsFile = root.appendingPathComponent("codex-connections.json")
        StubURLProtocol.responder = responder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let manager = CodexConnectionManager(
            controller: CodexAccountController(keychain: store, connectionsFileURL: connectionsFile),
            provider: CodexUsageProvider(
                session: URLSession(configuration: configuration),
                now: { self.now }),
            now: { self.now })
        let snapshotStore = SnapshotStore(baseURL: root.appendingPathComponent("snapshots"))
        let preferencesStore = PreferencesStore(fileURL: root.appendingPathComponent("preferences.json"))
        let model = StatusModel(
            snapshotStore: snapshotStore,
            preferencesStore: preferencesStore,
            claudeManager: nil,
            codexManager: manager,
            now: { self.now })

        return Context(
            model: model,
            store: store,
            connectionsFile: connectionsFile,
            codexDirectory: try Self.makeCodexProfile(
                at: root, token: "tok-openai", accountID: "acct-m1"))
    }

    private static func makeCodexProfile(at root: URL, token: String, accountID: String?) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tokens: [String: Any] = ["access_token": token]
        if let accountID { tokens["account_id"] = accountID }
        let document: [String: Any] = ["auth_mode": "chatgpt", "tokens": tokens]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: directory.appendingPathComponent("auth.json"))
        return directory
    }

    // MARK: Connect through the model

    @Test func connectMarksGPTSlotConnectedAndStoresCredential() throws {
        let context = try makeContext()

        assertConnect(context.model.connectCodexSlot(.gptPersonal, directory: context.codexDirectory))

        let presentation = context.model.presentations.first { $0.slotID == .gptPersonal }
        // Connected without a successful refresh yet → LOADING (parent R7).
        #expect(presentation?.status == .loading)
        #expect(context.store.codexCredentials(account: .gptPersonal)?.accessToken == "tok-openai")

        // The connection file carries no secrets.
        let raw = try String(contentsOf: context.connectionsFile, encoding: .utf8)
        #expect(!raw.contains("tok-openai"))
    }

    @Test func malformedDirectoryYieldsSanitizedFailure() throws {
        let broken = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        let context = try makeContext()
        let result = context.model.connectCodexSlot(.gptPersonal, directory: broken)
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error is CodexConnectionError)
        #expect(context.model.presentations.first { $0.slotID == .gptPersonal }?.status == .notConnected)
    }

    // MARK: Refresh outcomes — R4/R11

    @Test func successfulRefreshPersistsWeeklySnapshotAndClearsAuth() async throws {
        let context = try makeContext(responder: { _ in
            StubURLProtocol.StubResponse(
                status: 200,
                body: #"{"rate_limit":{"allowed":true,"primary_window":{"used_percent":64,"reset_at":\#(1_760_000_000 + 200_000)}}}"#)
        })
        defer { StubURLProtocol.responder = nil }
        assertConnect(context.model.connectCodexSlot(.gptPersonal, directory: context.codexDirectory))

        let outcome = await context.model.refreshCodexSlot(.gptPersonal)
        guard case let .updated(snapshot) = outcome else {
            Issue.record("expected updated, got \(outcome)")
            return
        }
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].id == .weekly)

        let presentation = context.model.presentations.first { $0.slotID == .gptPersonal }
        #expect(presentation?.status == .available)

        // The snapshot survives a fresh model over the same stores.
        let fresh = StatusModel(
            snapshotStore: SnapshotStore(
                baseURL: context.connectionsFile.deletingLastPathComponent()
                    .appendingPathComponent("snapshots")),
            preferencesStore: PreferencesStore(
                fileURL: context.connectionsFile.deletingLastPathComponent()
                    .appendingPathComponent("preferences.json")),
            claudeManager: nil,
            codexManager: CodexConnectionManager(
                controller: context.controller,
                provider: CodexUsageProvider(),
                now: { self.now }),
            now: { self.now })
        let restored = fresh.presentations.first { $0.slotID == .gptPersonal }
        #expect(restored?.status == .available)
    }

    @Test func exhaustedWeeklyWindowBlocksThroughEngine() async throws {
        let context = try makeContext(responder: { _ in
            StubURLProtocol.StubResponse(
                status: 200,
                body: #"{"rate_limit":{"allowed":false,"limit_reached":true,"primary_window":{"used_percent":100,"limit_reached":true,"reset_after_seconds":261623}}}"#)
        })
        defer { StubURLProtocol.responder = nil }
        assertConnect(context.model.connectCodexSlot(.gptPersonal, directory: context.codexDirectory))

        let outcome = await context.model.refreshCodexSlot(.gptPersonal)
        guard case let .updated(snapshot) = outcome else {
            Issue.record("expected updated, got \(outcome)")
            return
        }
        let presentation = context.model.presentations.first { $0.slotID == .gptPersonal }
        #expect(presentation?.status == .blocked)
        #expect(presentation?.blockers.count == 1)
        // availableAt equals the weekly reset derived from reset_after_seconds.
        #expect(presentation?.availableAt == snapshot.windows[0].resetAt)
    }

    @Test func unauthorizedRefreshRaisesAuthenticationRequiredKeepingHistory() async throws {
        // First refresh succeeds so a historical snapshot exists…
        let context = try makeContext(responder: { _ in
            StubURLProtocol.StubResponse(
                status: 200,
                body: #"{"rate_limit":{"allowed":true,"primary_window":{"used_percent":20,"reset_at":\#(1_760_000_000 + 100_000)}}}"#)
        })
        assertConnect(context.model.connectCodexSlot(.gptPersonal, directory: context.codexDirectory))
        _ = await context.model.refreshCodexSlot(.gptPersonal)

        // …then the provider starts rejecting the credential.
        StubURLProtocol.responder = { _ in
            StubURLProtocol.StubResponse(status: 403, body: "")
        }
        defer { StubURLProtocol.responder = nil }

        let outcome = await context.model.refreshCodexSlot(.gptPersonal)
        #expect(outcome == .authenticationRequired)
        let presentation = context.model.presentations.first { $0.slotID == .gptPersonal }
        #expect(presentation?.status == .authenticationRequired)
        // Prior data stays visible purely as historical context (parent R7/R11).
        #expect(presentation?.historicalWindows.isEmpty == false)
    }

    @Test func incompleteWeeklyPayloadKeepsPriorStateWithoutFabrication() async throws {
        let context = try makeContext(responder: { _ in
            // 200 with no usable window pair — must NOT become available-at-zero.
            StubURLProtocol.StubResponse(
                status: 200,
                body: #"{"rate_limit":{"allowed":true,"primary_window":{"used_percent":10}}}"#)
        })
        defer { StubURLProtocol.responder = nil }
        assertConnect(context.model.connectCodexSlot(.gptPersonal, directory: context.codexDirectory))

        let outcome = await context.model.refreshCodexSlot(.gptPersonal)
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        // No snapshot existed before → honestly LOADING, never AVAILABLE at 0%.
        let presentation = context.model.presentations.first { $0.slotID == .gptPersonal }
        #expect(presentation?.status == .loading)
    }

    // MARK: Disconnect isolation — I2

    @Test func disconnectRemovesOnlyGPTSlotState() async throws {
        let context = try makeContext()
        assertConnect(context.model.connectCodexSlot(.gptPersonal, directory: context.codexDirectory))

        context.model.disconnectCodexSlot(.gptPersonal)

        #expect(context.model.presentations.first { $0.slotID == .gptPersonal }?.status == .notConnected)
        #expect(context.store.codexCredentials(account: .gptPersonal) == nil)
        // External profile remains untouched; user stays signed in to Codex.
        #expect(FileManager.default.fileExists(
            atPath: context.codexDirectory.appendingPathComponent("auth.json").path))
    }

    // MARK: Startup reconciliation

    @Test func persistedConnectionRestoresConnectedSlotOnFreshModel() throws {
        let context = try makeContext()
        assertConnect(context.model.connectCodexSlot(.gptPersonal, directory: context.codexDirectory))

        let freshManager = CodexConnectionManager(
            controller: context.controller,
            provider: CodexUsageProvider(),
            now: { self.now })
        let freshModel = StatusModel(
            snapshotStore: SnapshotStore(baseURL: context.connectionsFile.deletingLastPathComponent()
                .appendingPathComponent("snapshots")),
            preferencesStore: PreferencesStore(fileURL: context.connectionsFile.deletingLastPathComponent()
                .appendingPathComponent("preferences.json")),
            claudeManager: nil,
            codexManager: freshManager,
            now: { self.now })
        #expect(freshModel.presentations.first { $0.slotID == .gptPersonal }?.status == .loading)
    }
}
