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
        let codexManager: CodexConnectionManager
        let openCodeManager: OpenCodeConnectionManager
        let commandCodeManager: CommandCodeConnectionManager
        let zaiManager: ZaiConnectionManager
        if uitest {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentusage-uitest-\(UUID().uuidString)", isDirectory: true)
            snapshotBase = root.appendingPathComponent("snapshots", isDirectory: true)
            preferencesFile = root.appendingPathComponent("preferences.json")
            claudeManager = ClaudeConnectionManager(
                controller: ClaudeAccountController(
                    keychain: InMemoryCredentialStore(),
                    connectionsFileURL: root.appendingPathComponent("claude-connections.json")))
            codexManager = CodexConnectionManager(
                controller: CodexAccountController(
                    keychain: InMemoryCredentialStore(),
                    connectionsFileURL: root.appendingPathComponent("codex-connections.json")))
            openCodeManager = OpenCodeConnectionManager(
                controller: OpenCodeAccountController(
                    keychain: InMemoryCredentialStore(),
                    connectionsFileURL: root.appendingPathComponent("opencode-connections.json")))
            commandCodeManager = CommandCodeConnectionManager(
                controller: CommandCodeAccountController(
                    keychain: InMemoryCredentialStore(),
                    connectionsFileURL: root.appendingPathComponent("commandcode-connections.json")))
            zaiManager = ZaiConnectionManager(
                controller: ZaiAccountController(
                    keychain: InMemoryCredentialStore(),
                    connectionsFileURL: root.appendingPathComponent("zai-connections.json")))
            // Optional hermetic seed: pre-connect slots to fixture profile
            // directories so UI tests can exercise Connected-state actions.
            if ProcessInfo.processInfo.environment["AGENT_USAGE_UITEST_CLAUDE_FIXTURE"] == "1" {
                Self.seedClaudeFixtures(manager: claudeManager, root: root)
            }
            if ProcessInfo.processInfo.environment["AGENT_USAGE_UITEST_CODEX_FIXTURE"] == "1" {
                Self.seedCodexFixture(manager: codexManager, root: root)
            }
            if ProcessInfo.processInfo.environment["AGENT_USAGE_UITEST_OPENCODE_FIXTURE"] == "1" {
                Self.seedOpenCodeFixture(manager: openCodeManager, root: root)
            }
            if ProcessInfo.processInfo.environment["AGENT_USAGE_UITEST_COMMANDCODE_FIXTURE"] == "1" {
                Self.seedCommandCodeFixture(manager: commandCodeManager, root: root)
            }
            if ProcessInfo.processInfo.environment["AGENT_USAGE_UITEST_ZAI_FIXTURE"] == "1" {
                Self.seedZaiFixture(manager: zaiManager, root: root)
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
            let codexConnectionsFile = CodexAccountController.defaultFileURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
            if let codexConnectionsFile {
                codexManager = CodexConnectionManager(
                    controller: CodexAccountController(
                        keychain: keychain,
                        connectionsFileURL: codexConnectionsFile))
            } else {
                codexManager = CodexConnectionManager(
                    controller: CodexAccountController(
                        keychain: keychain,
                        connectionsFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("codex-connections.json")))
            }
            let openCodeConnectionsFile = OpenCodeAccountController.defaultFileURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
            if let openCodeConnectionsFile {
                openCodeManager = OpenCodeConnectionManager(
                    controller: OpenCodeAccountController(
                        keychain: keychain,
                        connectionsFileURL: openCodeConnectionsFile))
            } else {
                openCodeManager = OpenCodeConnectionManager(
                    controller: OpenCodeAccountController(
                        keychain: keychain,
                        connectionsFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("opencode-connections.json")))
            }
            let commandCodeConnectionsFile = CommandCodeAccountController.defaultFileURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
            if let commandCodeConnectionsFile {
                commandCodeManager = CommandCodeConnectionManager(
                    controller: CommandCodeAccountController(
                        keychain: keychain,
                        connectionsFileURL: commandCodeConnectionsFile))
            } else {
                commandCodeManager = CommandCodeConnectionManager(
                    controller: CommandCodeAccountController(
                        keychain: keychain,
                        connectionsFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("commandcode-connections.json")))
            }
            let zaiConnectionsFile = ZaiAccountController.defaultFileURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
            if let zaiConnectionsFile {
                zaiManager = ZaiConnectionManager(
                    controller: ZaiAccountController(
                        keychain: keychain,
                        connectionsFileURL: zaiConnectionsFile))
            } else {
                zaiManager = ZaiConnectionManager(
                    controller: ZaiAccountController(
                        keychain: keychain,
                        connectionsFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("zai-connections.json")))
            }
        }
        let snapshotStore = snapshotBase.map { SnapshotStore(baseURL: $0) }
        let preferencesStore = preferencesFile.map { PreferencesStore(fileURL: $0) }
        let model = StatusModel(
            snapshotStore: snapshotStore,
            preferencesStore: preferencesStore,
            claudeManager: claudeManager,
            codexManager: codexManager,
            openCodeManager: openCodeManager,
            commandCodeManager: commandCodeManager,
            zaiManager: zaiManager)
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

        if let profile = fixtureProfile(named: "fixture-claude", token: "uitest-h", uuid: "uuid-h") {
            try? manager.connect(slotID: .claude, directory: profile)
        }
    }

    static func seedZaiFixture(manager: ZaiConnectionManager, root: URL) {
        // Prefer opencode auth shape so the same fixture covers local import.
        let opencodeFile = root.appendingPathComponent("fixture-zai-opencode-auth.json")
        let document: [String: Any] = ["zai-coding-plan": ["key": "uitest-zai"]]
        _ = try? JSONSerialization.data(withJSONObject: document).write(to: opencodeFile)
        // Try opencode auth file first; if not usable, try manual fallback.
        if (try? manager.connect(slotID: .zaiCodingPlan, file: opencodeFile)) == nil {
            try? manager.connectManually(slotID: .zaiCodingPlan, apiKey: "uitest-zai")
        }
    }

    static func seedCommandCodeFixture(manager: CommandCodeConnectionManager, root: URL) {
        let file = root.appendingPathComponent("fixture-commandcode-auth.json")
        let document: [String: Any] = ["apiKey": "uitest-commandcode"]
        _ = try? JSONSerialization.data(withJSONObject: document).write(to: file)
        try? manager.connect(slotID: .commandCodeGOAT, file: file)
    }

    static func seedOpenCodeFixture(manager: OpenCodeConnectionManager, root: URL) {
        let file = root.appendingPathComponent("fixture-opencode-auth.json")
        let document: [String: Any] = ["opencode-go": ["key": "uitest-opencode"]]
        _ = try? JSONSerialization.data(withJSONObject: document).write(to: file)
        try? manager.connect(slotID: .openCodeGO, file: file)
    }

    /// Creates a fixture Codex profile directory and connects the GPT Personal
    /// slot through the real connection path (no network involved in connecting).
    static func seedCodexFixture(manager: CodexConnectionManager, root: URL) {
        let directory = root.appendingPathComponent("fixture-codex", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let document: [String: Any] = [
                "auth_mode": "chatgpt",
                "tokens": ["accessToken": "uitest-codex", "account_id": "uuid-codex"]
            ]
            try JSONSerialization.data(withJSONObject: document)
                .write(to: directory.appendingPathComponent("auth.json"))
            try? manager.connect(slotID: .gptPersonal, directory: directory)
        } catch {
            return
        }
    }
}
