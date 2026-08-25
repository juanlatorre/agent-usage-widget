import Testing
import Foundation
@testable import AgentUsage
import AgentUsageCore

/// Asserts a connect Result succeeded, recording the error otherwise.
@MainActor
func assertConnect(_ result: Result<Void, Error>) {
    if case .failure(let error) = result {
        Issue.record("connect failed: \(error)")
    }
}

/// App-model tests for the Claude connection surface (child 02): connect via
/// manager, refresh outcome mapping, disconnect isolation. Uses the in-memory
/// credential store; no Keychain and no network are touched.
@MainActor
struct ClaudeSlotModelTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// Test context: model + manager over fakes + fixture directory handles.
    private struct Context {
        let model: StatusModel
        let store: InMemoryCredentialStore
        let connectionsFile: URL
        let legacyADirectory: URL
        let inshaDirectory: URL

        var controller: ClaudeAccountController {
            ClaudeAccountController(keychain: store, connectionsFileURL: connectionsFile)
        }
    }

    private func makeContext() throws -> Context {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryCredentialStore()
        let connectionsFile = root.appendingPathComponent("claude-connections.json")
        let manager = ClaudeConnectionManager(
            controller: ClaudeAccountController(keychain: store, connectionsFileURL: connectionsFile),
            provider: ClaudeUsageProvider(
                session: neverSession(),
                now: { self.now }),
            now: { self.now })
        let snapshotStore = SnapshotStore(baseURL: root.appendingPathComponent("snapshots"))
        let preferencesStore = PreferencesStore(fileURL: root.appendingPathComponent("preferences.json"))
        let model = StatusModel(
            snapshotStore: snapshotStore,
            preferencesStore: preferencesStore,
            claudeManager: manager,
            now: { self.now })

        return Context(
            model: model,
            store: store,
            connectionsFile: connectionsFile,
            legacyADirectory: try Self.makeProfile(name: "legacy", token: "tok-h", uuid: "uuid-h"),
            inshaDirectory: try Self.makeProfile(name: "legacy-b", token: "tok-i", uuid: "uuid-i"))
    }

    private static func makeProfile(name: String, token: String, uuid: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("profile-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document: [String: Any] = [
            "claudeAiOauth": ["accessToken": token, "accountUuid": uuid]
        ]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: directory.appendingPathComponent(".credentials.json"))
        return directory
    }

    /// A session whose configuration can never perform a request in these tests.
    private func neverSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverProtocol.self]
        configuration.timeoutIntervalForRequest = 1
        return URLSession(configuration: configuration)
    }

    private final class NeverProtocol: URLProtocol {
        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    // MARK: Connect through the model

    @Test func connectMarksSlotConnectedAndStoresDistinctIdentities() throws {
        let context = try makeContext()
        let model = context.model

        assertConnect(model.connectClaudeSlot(.claude, directory: context.legacyADirectory))

        assertConnect(model.connectClaudeSlot(.claude, directory: context.inshaDirectory))

        let legacy = model.presentations.first { $0.slotID == .claude }
        let insha = model.presentations.first { $0.slotID == .claude }
        // Connected without a successful refresh yet → LOADING (parent R7).
        #expect(legacy?.status == .loading)
        #expect(insha?.status == .loading)

        // Distinct identities per slot (AC1).
        #expect(context.store.credentials(account: .claude)?.accountUUID == "uuid-h")
        #expect(context.store.credentials(account: .claude)?.accountUUID == "uuid-i")

        // The connection file carries no secrets.
        let raw = try String(contentsOf: context.connectionsFile, encoding: .utf8)
        #expect(!raw.contains("tok-h"))
        #expect(!raw.contains("tok-i"))
    }

    @Test func duplicateDirectoryIsRejectedWithoutSideEffects() throws {
        let context = try makeContext()
        let model = context.model

        assertConnect(model.connectClaudeSlot(.claude, directory: context.legacyADirectory))

        let result = model.connectClaudeSlot(.claude, directory: context.legacyADirectory)
        if case .success = result { Issue.record("duplicate binding must fail") }
        #expect(model.presentations.first { $0.slotID == .claude }?.status == .notConnected)
        #expect(context.store.credentials(account: .claude) == nil)
    }

    @Test func malformedDirectoryYieldsSanitizedFailure() throws {
        let context = try makeContext()
        let broken = context.legacyADirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        let result = context.model.connectClaudeSlot(.claude, directory: broken)
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error is ConnectionControllerError)
        #expect(context.model.presentations.first { $0.slotID == .claude }?.status == .notConnected)
    }

    // MARK: Refresh outcomes — R6/R7/R11

    @Test func transportFailureKeepsPriorSnapshotAsHistoryWithoutAuthState() async throws {
        let context = try makeContext()
        let model = context.model
        assertConnect(model.connectClaudeSlot(.claude, directory: context.legacyADirectory))

        // Seed a valid prior snapshot.
        let prior = UsageSnapshot(
            slotID: .claude, provider: .claude,
            windows: [UsageWindow(
                id: .fiveHour, name: "5 hour", isRequired: true,
                used: 40, limit: 100, resetAt: now.addingTimeInterval(1200)),
                UsageWindow(
                id: .weekly, name: "Weekly", isRequired: true,
                used: 10, limit: 100, resetAt: now.addingTimeInterval(3 * 86_400))],
            capturedAt: now.addingTimeInterval(-60))
        model.storeSnapshot(prior)

        let outcome = await model.refreshClaudeSlot(.claude)
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        let presentation = model.presentations.first { $0.slotID == .claude }
        // Transient failure keeps last valid data visible; no zero-usage fabrication.
        #expect(presentation?.status == .available)
        #expect(presentation?.historicalWindows.count == 2)
    }

    @Test func syncRestoresMissingKeychainMaterialFromSourceWhenIdentityMatches() async throws {
        let context = try makeContext()
        let model = context.model
        assertConnect(model.connectClaudeSlot(.claude, directory: context.inshaDirectory))

        // Simulate the Keychain copy vanishing while the source stays intact:
        // synchronization must heal the stored copy before fetching (ADR-0004).
        context.store.deleteCredentials(account: .claude)
        #expect(context.store.hasCredential(account: .claude) == false)

        let outcome = await model.refreshClaudeSlot(.claude)
        // Transport fails offline, but identity sync ran first and restored the
        // stored material from the bound source.
        guard case .failed = outcome else {
            Issue.record("expected failed (offline transport), got \(outcome)")
            return
        }
        #expect(context.store.credentials(account: .claude)?.accessToken == "tok-i")
        // No successful snapshot yet: still honestly LOADING, never auth-required.
        let presentation = model.presentations.first { $0.slotID == .claude }
        #expect(presentation?.status == .loading)
    }

    @Test func sourceIdentityChangeStopsRefreshAndRequiresReconnect() async throws {
        let context = try makeContext()
        let model = context.model
        assertConnect(model.connectClaudeSlot(.claude, directory: context.legacyADirectory))

        // Rotate identity behind the bound directory.
        let rotated: [String: Any] = [
            "claudeAiOauth": ["accessToken": "tok-zzz", "accountUuid": "uuid-other"]
        ]
        try JSONSerialization.data(withJSONObject: rotated)
            .write(to: context.legacyADirectory.appendingPathComponent(".credentials.json"))

        let outcome = await model.refreshClaudeSlot(.claude)
        #expect(outcome == .sourceIdentityChanged)
        #expect(model.presentations.first { $0.slotID == .claude }?.status == .authenticationRequired)
        // The stored secret was not overwritten by the foreign identity.
        #expect(context.store.credentials(account: .claude)?.accessToken == "tok-h")
    }

    // MARK: Disconnect isolation — R8/I2

    @Test func disconnectRemovesOnlyTargetSlotState() throws {
        let context = try makeContext()
        let model = context.model
        assertConnect(model.connectClaudeSlot(.claude, directory: context.legacyADirectory))

        assertConnect(model.connectClaudeSlot(.claude, directory: context.inshaDirectory))

        model.disconnectClaudeSlot(.claude)

        #expect(model.presentations.first { $0.slotID == .claude }?.status == .notConnected)
        #expect(model.presentations.first { $0.slotID == .claude }?.status == .loading)
        #expect(context.store.hasCredential(account: .claude) == false)
        #expect(context.store.hasCredential(account: .claude))

        // External profile directories remain untouched.
        #expect(FileManager.default.fileExists(
            atPath: context.legacyADirectory.appendingPathComponent(".credentials.json").path))
    }

    // MARK: Startup reconciliation

    @Test func persistedConnectionRestoresConnectedSlotOnFreshModel() throws {
        var context = try makeContext()
        assertConnect(context.model.connectClaudeSlot(.claude, directory: context.inshaDirectory))

        // A fresh model over the same stores sees the persisted binding.
        let freshManager = ClaudeConnectionManager(
            controller: context.controller,
            provider: ClaudeUsageProvider(session: neverSession(), now: { self.now }),
            now: { self.now })
        let freshModel = StatusModel(
            snapshotStore: SnapshotStore(baseURL: context.connectionsFile.deletingLastPathComponent()
                .appendingPathComponent("snapshots")),
            preferencesStore: PreferencesStore(fileURL: context.connectionsFile.deletingLastPathComponent()
                .appendingPathComponent("preferences.json")),
            claudeManager: freshManager,
            now: { self.now })
        #expect(freshModel.presentations.first { $0.slotID == .claude }?.status == .loading)
        #expect(freshModel.presentations.first { $0.slotID == .claude }?.status == .notConnected)
    }
}
