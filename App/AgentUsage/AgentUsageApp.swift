import SwiftUI
import AgentUsageCore

@main
struct AgentUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar extra: the always-on surface. Renders per-account rings in
        // the bar and opens a popover with per-slot rows + actions.
        MenuBarExtra {
            MenuBarContentView()
                .environment(statusModel)
        } label: {
            MenuBarIconView(presentations: statusModel.presentations)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "main") {
            RootView()
                .environment(statusModel)
                .frame(minWidth: 720, minHeight: 520)
                .handlesExternalEvents(preferring: ["agent-usage"], allowing: ["agent-usage"])
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["agent-usage"])
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
            // The unsandboxed app carries no app-groups entitlement (Xcode would
            // demand a Developer ID provisioning profile), so it materializes the
            // Team-prefixed group container by direct path. The sandboxed widget
            // resolves this same container through its entitlement.
            let sharedGroup = SharedStoreLocations.ensureCanonicalGroupContainer()
            snapshotBase = sharedGroup.map { $0.appendingPathComponent("snapshots", isDirectory: true) }
                ?? SnapshotStore.defaultBaseURL(appGroupID: SharedStoreLocations.canonicalAppGroupID)
            preferencesFile = sharedGroup.map { $0.appendingPathComponent("preferences.json", isDirectory: false) }
                ?? PreferencesStore.defaultFileURL(appGroupID: SharedStoreLocations.canonicalAppGroupID)
            let keychain = KeychainStore(serviceNamePrefix: "com.juanlatorre.agent-usage",
                                          sharedAccessGroup: WidgetRefresher.sharedKeychainGroup)
            let connectionsFile = sharedGroup.map { $0.appendingPathComponent("claude-connections.json", isDirectory: false) }
                ?? ClaudeAccountController.defaultFileURL(appGroupID: SharedStoreLocations.canonicalAppGroupID)
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
            let codexConnectionsFile = sharedGroup.map { $0.appendingPathComponent("codex-connections.json", isDirectory: false) }
                ?? CodexAccountController.defaultFileURL(appGroupID: SharedStoreLocations.canonicalAppGroupID)
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
            let openCodeConnectionsFile = sharedGroup.map { $0.appendingPathComponent("opencode-connections.json", isDirectory: false) }
                ?? OpenCodeAccountController.defaultFileURL(appGroupID: SharedStoreLocations.canonicalAppGroupID)
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
            let commandCodeConnectionsFile = sharedGroup.map { $0.appendingPathComponent("commandcode-connections.json", isDirectory: false) }
                ?? CommandCodeAccountController.defaultFileURL(appGroupID: SharedStoreLocations.canonicalAppGroupID)
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
            let zaiConnectionsFile = sharedGroup.map { $0.appendingPathComponent("zai-connections.json", isDirectory: false) }
                ?? ZaiAccountController.defaultFileURL(appGroupID: SharedStoreLocations.canonicalAppGroupID)
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
        let appGroupID = SharedStoreLocations.canonicalAppGroupID
        let snapshotStore = snapshotBase.map { base in
            SnapshotStore(
                baseURL: base,
                mirrors: [
                    SnapshotStore.appSupportBaseURL(),
                    SharedStoreLocations.widgetContainerDirectory().map { $0.appendingPathComponent("snapshots", isDirectory: true) },
                    SnapshotStore.groupContainerBaseURL(appGroupID: appGroupID),
                ].compactMap { $0 }.filter { $0 != base })
        }
        let preferencesStore = preferencesFile.map { file in
            PreferencesStore(
                fileURL: file,
                mirrors: SharedStoreLocations.mirrorURLs(
                    forFileName: file.lastPathComponent, primary: file))
        }
        let model = StatusModel(
            snapshotStore: snapshotStore,
            preferencesStore: preferencesStore,
            claudeManager: claudeManager,
            codexManager: codexManager,
            openCodeManager: openCodeManager,
            commandCodeManager: commandCodeManager,
            zaiManager: zaiManager)
        model.loadPersistedSnapshots()
        // Wire 07 refresh service so onAppear/.task handleAppActivation actually fetches
        // (before this, refreshService was nil and the app stayed Loading... forever).
        if let snapshotStore {
            let failureFile = SharedStoreLocations.groupContainer(appGroupID: SharedStoreLocations.canonicalAppGroupID).map { $0.appendingPathComponent("refresh-failures.json") }
                ?? RefreshFailureStore.defaultFileURL(appGroupID: SharedStoreLocations.canonicalAppGroupID)
            let failureStore = failureFile.map { RefreshFailureStore(fileURL: $0) }
                ?? RefreshFailureStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("refresh-failures.json"))
            let scheduler = RefreshScheduler(
                preferences: { model.preferences },
                connectedSlots: { model.connectedSlots },
                snapshots: { [:] },
                isAuthBlocked: { model.authenticationRequiredSlots.contains($0) }
            )
            // Keep presentation fresh when a background fetch publishes a new snapshot
            let fetcher = UnifiedFetcher.fetcher(statusModel: model)
            let service = RefreshService(
                scheduler: scheduler,
                snapshotStore: snapshotStore,
                failureStore: failureStore,
                fetcher: fetcher,
                onSnapshotPublished: { snap in Task { @MainActor in model.storeSnapshot(snap) } }
            )
            // Restore server-directed Retry-After deadlines across launches so a
            // rate-limited provider is not re-hit immediately on every relaunch.
            scheduler.hydrateFailures(failureStore.load())
            model.attachRefreshService(scheduler: scheduler, failureStore: failureStore, service: service)
            // Real login-item support (previously nil — the toggle always read
            // "not available"). Background refresh is on by default with an
            // explicit opt-out remembered in UserDefaults.
            model.loginItemController = SMLoginItemController()
            model.enableBackgroundRefreshByDefault()
            // Migrate keychain items into the shared access group, then mirror
            // current credentials into the widget container so the sandboxed
            // extension can refresh usage itself (its sandbox cannot read the
            // login Keychain — attempting it surfaced the login-password
            // prompt every few minutes).
            let sharedKeychain = KeychainStore(serviceNamePrefix: "com.juanlatorre.agent-usage",
                                                sharedAccessGroup: WidgetRefresher.sharedKeychainGroup)
            model.migrateKeychainToSharedGroup(keychain: sharedKeychain)
            if let widgetContainer = SharedStoreLocations.widgetContainerDirectory() {
                model.mirrorCredentialsToWidgetContainer(container: widgetContainer, keychain: sharedKeychain)
            }
            // Re-mirror connection records into the widget's container so its
            // self-heal sees every connected slot (files written before the
            // mirror existed were never copied).
            Self.remirrorConnectionsToWidgetContainer()
        }
        return model
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window must NOT quit the app: the refresh pipeline keeps
    /// widget snapshots fresh, and without it every slot degrades to
    /// Unavailable once the 15-minute honesty horizon passes. Quit explicitly
    /// via ⌘Q or Dock → Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon click with no visible window reopens the main window —
    /// exactly once: the handler checks for a visible window before opening
    /// (WindowGroup would otherwise stack duplicates).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated {
                let hasMain = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if !hasMain {
                    Self.reopenHandler?()
                }
            }
        }
        return true
    }

    /// Retained openWindow action set by RootView.onAppear; survives window close.
    /// MainActor-isolated: set from the main scene, read from the (main-actor)
    /// AppKit reopen callback.
    @MainActor static var reopenHandler: (() -> Void)?
    @MainActor static var lastReopenAt: Date?
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

    /// Copy the canonical connection records into the widget extension's
    /// container so its in-widget refresh sees every connected slot even for
    /// files last written before the mirroring code existed.
    static func remirrorConnectionsToWidgetContainer() {
        let fm = FileManager.default
        guard let appSupport = SharedStoreLocations.appSupportDirectory(),
              let widgetContainer = SharedStoreLocations.widgetContainerDirectory() else { return }
        for name in ["claude-connections.json", "codex-connections.json", "opencode-connections.json",
                     "commandcode-connections.json", "zai-connections.json", "connections.json"] {
            let src = appSupport.appendingPathComponent(name)
            let dst = widgetContainer.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.copyItem(at: src, to: dst)
            }
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
            try? manager.connect(slotID: .chatGPT, directory: directory)
        } catch {
            return
        }
    }
}
