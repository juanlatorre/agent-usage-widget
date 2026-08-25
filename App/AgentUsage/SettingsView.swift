import SwiftUI
import AgentUsageCore

/// Global settings: Used/Remaining display mode, refresh interval, and background refresh.
struct SettingsView: View {
    @Environment(StatusModel.self) private var model
    @State private var showFixtures = false
    @State private var loginItemStatus: LoginItemStatus = .unknown("loading")
    @State private var backgroundEnabled: Bool = false

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Show", selection: Binding(
                get: { model.preferences.displayMode },
                set: { newValue in
                    try? model.setDisplayMode(newValue)
                })) {
                ForEach(DisplayPreferences.DisplayMode.allCases, id: \.self) { mode in
                    Text(mode == .used ? "Used" : "Remaining").tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Refresh every", selection: Binding(
                get: { model.preferences.refreshInterval },
                set: { newValue in
                    try? model.setRefreshInterval(newValue)
                })) {
                ForEach(DisplayPreferences.RefreshInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }

            Divider()
            Section("Background refresh") {
                Toggle("Keep usage fresh in background", isOn: $backgroundEnabled)
                    .onChange(of: backgroundEnabled) { _, newValue in
                        model.setBackgroundRefreshEnabled(newValue)
                        refreshLoginStatus()
                    }
                Text(loginStatusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh all now") { Task { await model.refreshAllNow() } }
                    .disabled(model.connectedSlots.isEmpty)
            }
            Toggle("Demo fixtures", isOn: $showFixtures)
            if showFixtures {
                FixtureControls()
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { refreshLoginStatus() }
    }
}

private extension SettingsView {
    func refreshLoginStatus() {
        backgroundEnabled = model.isBackgroundRefreshEnabled
        loginItemStatus = model.loginItemStatus()
    }
    var loginStatusCaption: String {
        if model.connectedSlots.isEmpty { return "Connect an account to enable background refresh." }
        switch loginItemStatus {
        case .enabled: return "Background refresh will run at login. No menu-bar item is shown."
        case .disabled: return "Background refresh is off. You can still refresh manually."
        case .requiresApproval: return "Background item requires approval in System Settings → Login Items."
        case .notSupported: return "Background refresh is not available on this system."
        case .unknown(let s): return s
        }
    }
}

/// Demo fixture controls. Test infrastructure only — never shown as a provider.
struct FixtureControls: View {
    @Environment(StatusModel.self) private var model
    @State private var selectedSlot: AccountSlotID = .claude
    @State private var scenario: StatusModel.DemoScenario = .availablePartial

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Slot", selection: $selectedSlot) {
                ForEach(AccountCatalog.slots) { slot in
                    Text(slot.label).tag(slot.slotID)
                }
            }
            Picker("Scenario", selection: $scenario) {
                ForEach(StatusModel.DemoScenario.allCases) { scenario in
                    Text(scenario.rawValue).tag(scenario)
                }
            }
            HStack {
                Button("Apply") {
                    model.applyFixture(scenario, to: selectedSlot)
                }
                Button("Clear Slot") {
                    model.clearSlot(selectedSlot)
                }
            }
            Text("Fixtures are demo infrastructure for verifying UI states before live providers exist.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}
