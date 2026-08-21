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
        // UI tests run hermetically against a temporary store.
        let uitest = ProcessInfo.processInfo.environment["AGENT_USAGE_UITEST"] == "1"
        let snapshotBase: URL?
        let preferencesFile: URL?
        if uitest {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentusage-uitest-", isDirectory: true)
            snapshotBase = root.appendingPathComponent("snapshots", isDirectory: true)
            preferencesFile = root.appendingPathComponent("preferences.json")
        } else {
            snapshotBase = SnapshotStore.defaultBaseURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
            preferencesFile = PreferencesStore.defaultFileURL(
                appGroupID: "group.com.juanlatorre.agent-usage")
        }
        let snapshotStore = snapshotBase.map { SnapshotStore(baseURL: $0) }
        let preferencesStore = preferencesFile.map { PreferencesStore(fileURL: $0) }
        let model = StatusModel(
            snapshotStore: snapshotStore,
            preferencesStore: preferencesStore)
        model.loadPersistedSnapshots()
        return model
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
