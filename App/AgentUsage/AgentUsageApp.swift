import SwiftUI
import AgentUsageCore

@main
struct AgentUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(statusModel)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(statusModel)
        }
    }

    @State private var statusModel: StatusModel = {
        // UI tests run hermetically against temporary stores and an in-memory
        // credential store, so automated runs never touch the real Keychain.
        let uitest = ProcessInfo.processInfo.environment["AGENT_USAGE_UITEST"] == "1"
        let snapshotBase: URL?
        let preferencesFile: URL?
        let claudeManager: ClaudeConnectionManager
        if uitest {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentusage-uitest-\(UUID().uuidString)", isDirectory: true)
            snapshotBase = root.appendingPathComponent("snapshots", isDirectory: true)
            preferencesFile = root.appendingPathComponent("preferences.json")
            claudeManager = ClaudeConnectionManager(
                controller: ClaudeAccountController(
                    keychain: InMemoryCredentialStore(),
                    connectionsFileURL: root.appendingPathComponent("claude-connections.json")))
            // Optional hermetic seed: pre-connect both Claude slots to fixture
            // profile directories so UI tests can exercise Connected-state actions.
            if ProcessInfo.processInfo.environment["AGENT_USAGE_UITEST_CLAUDE_FIXTURE"] == "1" {
                Self.seedClaudeFixtures(manager: claudeManager, root: root)
            }
        } else {
            snapshotBase = SnapshotStore.defaultBaseURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
            preferencesFile = PreferencesStore.defaultFileURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
            let keychain = KeychainStore(serviceNamePrefix: "com.juanlatorre.agent-usage")
            let connectionsFile = ClaudeAccountController.defaultFileURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
            if let connectionsFile {
                claudeManager = ClaudeConnectionManager(
                    controller: ClaudeAccountController(
                        keychain: keychain,
                        connectionsFileURL: connectionsFile))
            } else {
                claudeManager = ClaudeConnectionManager(
                    controller: ClaudeAccountController(
                        keychain: keychain,
                        connectionsFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("claude-connections.json")))
            }
        }
        let snapshotStore = snapshotBase.map { SnapshotStore(baseURL: $0) }
        let preferencesStore = preferencesFile.map { PreferencesStore(fileURL: $0) }
        let model = StatusModel(
            snapshotStore: snapshotStore,
            preferencesStore: preferencesStore,
            claudeManager: claudeManager)
        model.loadPersistedSnapshots()
        return model
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private extension AgentUsageApp {

    /// Creates fixture Claude profile directories and connects both slots
    /// through the real connection path (no network involved in connecting).
    static func seedClaudeFixtures(manager: ClaudeConnectionManager, root: URL) {
        func fixtureProfile(named name: String, token: String, uuid: String) -> URL? {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let document: [String: Any] = [
                    "claudeAiOauth": ["accessToken": token, "accountUuid": uuid]
                ]
                try JSONSerialization.data(withJSONObject: document)
                    .write(to: directory.appendingPathComponent(".credentials.json"))
                return directory
            } catch {
                return nil
            }
        }

        if let legacy = fixtureProfile(named: "fixture-legacy", token: "uitest-h", uuid: "uuid-h") {
            try? manager.connect(slotID: .claudeLegacyA, directory: legacy)
        }
        if let insha = fixtureProfile(named: "fixture-legacy-b", token: "uitest-i", uuid: "uuid-i") {
            try? manager.connect(slotID: .claudethe team, directory: insha)
        }
    }
}
