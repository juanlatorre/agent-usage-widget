import SwiftUI
import AgentUsageCore

/// Global settings: Used/Remaining display mode and refresh interval.
struct SettingsView: View {
    @Environment(StatusModel.self) private var model
    @State private var showFixtures = false

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

            Toggle("Demo fixtures", isOn: $showFixtures)
            if showFixtures {
                FixtureControls()
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Demo fixture controls. Test infrastructure only — never shown as a provider.
struct FixtureControls: View {
    @Environment(StatusModel.self) private var model
    @State private var selectedSlot: AccountSlotID = .claudeLegacyA
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
