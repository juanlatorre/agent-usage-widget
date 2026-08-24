import SwiftUI
import AgentUsageCore

/// App-side model that owns catalog state, persisted snapshots, and preferences,
/// and derives all presentation through `AvailabilityEngine`.
///
/// This type is deliberately UI-independent so it can be tested without SwiftUI.
@MainActor
@Observable
final class StatusModel {

    /// Demo fixtures used to exercise states before live providers exist (child spec O4).
    enum DemoScenario: String, CaseIterable, Identifiable {
        case none = "No snapshot"
        case availablePartial = "Available · partial usage"
        case multipleBlockers = "Blocked · multiple windows"
        case incomplete = "Incomplete data"
        case staleHistory = "Expired history"
        case postResetPending = "Pending reset verification"

        var id: String { rawValue }
    }

    /// Non-secret runtime connection state per slot, persisted in preferences container.
    struct ConnectionState: Codable {
        var connectedSlotIDs: Set<String> = []
    }

    private(set) var slots: [AccountSlot]
    @ObservationIgnored private let snapshotStore: SnapshotStore?
    @ObservationIgnored private let preferencesStore: PreferencesStore?
    @ObservationIgnored private let connectionsURL: URL?
    /// Claude connection/refresh orchestration; nil only in degenerate stores.
    @ObservationIgnored private(set) var claudeManager: ClaudeConnectionManager?
    /// Codex (GPT Personal) connection/refresh orchestration; nil only in degenerate stores.
    @ObservationIgnored private(set) var codexManager: CodexConnectionManager?
    /// OpenCode GO connection/refresh orchestration; nil only in degenerate stores.
    @ObservationIgnored private(set) var openCodeManager: OpenCodeConnectionManager?
    /// Command Code GOAT connection/refresh orchestration; nil only in degenerate stores.
    @ObservationIgnored private(set) var commandCodeManager: CommandCodeConnectionManager?
    @ObservationIgnored private(set) var zaiManager: ZaiConnectionManager?

    private(set) var preferences: DisplayPreferences
    private(set) var presentations: [AccountPresentation] = []
    private var snapshots: [AccountSlotID: UsageSnapshot] = [:]
    /// Slots whose last refresh reported missing/rejected credentials (parent R7).
    private(set) var authenticationRequiredSlots: Set<AccountSlotID> = []

    /// Injected clock for deterministic behavior and previews.
    @ObservationIgnored var now: () -> Date

    init(
        snapshotStore: SnapshotStore?,
        preferencesStore: PreferencesStore?,
        claudeManager: ClaudeConnectionManager? = nil,
        codexManager: CodexConnectionManager? = nil,
        openCodeManager: OpenCodeConnectionManager? = nil,
        commandCodeManager: CommandCodeConnectionManager? = nil,
        zaiManager: ZaiConnectionManager? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.snapshotStore = snapshotStore
        self.preferencesStore = preferencesStore
        self.claudeManager = claudeManager
        self.codexManager = codexManager
        self.openCodeManager = openCodeManager
        self.commandCodeManager = commandCodeManager
        self.zaiManager = zaiManager
        self.now = now
        self.preferences = preferencesStore?.load() ?? DisplayPreferences()
        self.connectionsURL = preferencesStore.map(Self.connectionsFileURL(of:))
        self.slots = Self.loadConnections(from: connectionsURL)
        // Persisted profile connections are authoritative for their slots:
        // a slot bound to a profile directory is genuinely connected.
        if let claudeManager {
            for slotID in ClaudeAccountController.managedSlots where claudeManager.isConnected(slotID) {
                if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                    slots[index].isConnected = true
                }
            }
        }
        if let codexManager {
            for slotID in CodexAccountController.managedSlots where codexManager.isConnected(slotID) {
                if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                    slots[index].isConnected = true
                }
            }
        }
        if let openCodeManager {
            for slotID in OpenCodeAccountController.managedSlots where openCodeManager.isConnected(slotID) {
                if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                    slots[index].isConnected = true
                }
            }
        }
        if let commandCodeManager {
            for slotID in CommandCodeAccountController.managedSlots where commandCodeManager.isConnected(slotID) {
                if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                    slots[index].isConnected = true
                }
            }
        }
        if let zaiManager {
            for slotID in ZaiAccountController.managedSlots where zaiManager.isConnected(slotID) {
                if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                    slots[index].isConnected = true
                }
            }
        }
        refreshDerivedState()
    }

    // MARK: - Derived state

    /// Recompute presentation for all slots. Availability is never stored as truth.
    func refreshDerivedState() {
        presentations = AvailabilityEngine.deriveAll(
            slots: slots, snapshots: snapshots, now: now(),
            authenticationRequired: authenticationRequiredSlots)
    }

    private func presentation(for slotID: AccountSlotID) -> AccountPresentation? {
        presentations.first { $0.slotID == slotID }
    }

    // MARK: - Display preference changes

    /// Changing Used/Remaining recomputes presentation percentages only;
    /// availability logic is untouched by definition (parent R6).
    func setDisplayMode(_ mode: DisplayPreferences.DisplayMode) throws {
        preferences.displayMode = mode
        try persistPreferences()
        refreshDerivedState()
    }

    func setRefreshInterval(_ interval: DisplayPreferences.RefreshInterval) throws {
        preferences.refreshInterval = interval
        try persistPreferences()
    }

    private func persistPreferences() throws {
        guard let preferencesStore else { return }
        try preferencesStore.save(preferences)
    }

    // MARK: - Connections (fixture-era)

    /// Toggle a slot's connected state. v1 child scope has no real profile import;
    /// this exists so LOADING versus NOT CONNECTED can be exercised.
    func setConnected(_ slotID: AccountSlotID, _ connected: Bool) {
        guard let index = slots.firstIndex(where: { $0.slotID == slotID }) else { return }
        slots[index].isConnected = connected
        persistConnections()
        refreshDerivedState()
    }

    private func persistConnections() {
        guard let connectionsURL else { return }
        let state = ConnectionState(
            connectedSlotIDs: Set(slots.filter(\.isConnected).map { $0.slotID.rawValue }))
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: connectionsURL, options: .atomic)
        }
    }

    private static func loadConnections(from url: URL?) -> [AccountSlot] {
        guard let url, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ConnectionState.self, from: data) else {
            return AccountCatalog.slots
        }
        return AccountCatalog.slots.map { slot in
            var copy = slot
            copy.isConnected = state.connectedSlotIDs.contains(slot.slotID.rawValue)
            return copy
        }
    }

    private static func connectionsFileURL(of store: PreferencesStore) -> URL {
        store.fileURL.deletingLastPathComponent().appendingPathComponent("connections.json")
    }

    // MARK: - Fixture injection (demo/test infrastructure)

    /// Apply a fixture scenario to one slot. Not a production provider path.
    func applyFixture(_ scenario: DemoScenario, to slotID: AccountSlotID) {
        guard let slot = slots.first(where: { $0.slotID == slotID }),
              let index = slots.firstIndex(where: { $0.slotID == slotID }) else { return }
        let current = now()
        slots[index].isConnected = true
        defer { persistConnections() }

        switch scenario {
        case .none:
            snapshots[slotID] = nil
        case .availablePartial:
            // All required windows present; the first sits at 42% used / 58%
            // remaining so it becomes the limiting window (AC2 shape).
            let windows: [UsageWindow] = slot.requiredWindows.enumerated().map { index, kind in
                let used: Double = index == 0 ? 42 : 10
                return UsageWindow(
                    id: kind, name: kind.displayName, isRequired: true,
                    used: used, limit: 100,
                    resetAt: current.addingTimeInterval(Double(1800 + index * 3600)))
            }
            snapshots[slotID] = UsageSnapshot(
                slotID: slotID, provider: slot.provider,
                windows: windows, capturedAt: current)
        case .multipleBlockers:
            // First two required windows exhausted with different resets; any
            // remaining required windows partially used (AC1 shape).
            let windows: [UsageWindow] = slot.requiredWindows.enumerated().map { index, kind in
                switch index {
                case 0:
                    return UsageWindow(
                        id: kind, name: kind.displayName, isRequired: true,
                        used: 100, limit: 100, resetAt: current.addingTimeInterval(3600))
                case 1:
                    return UsageWindow(
                        id: kind, name: kind.displayName, isRequired: true,
                        used: 100, limit: 100,
                        resetAt: current.addingTimeInterval(3 * 24 * 3600))
                default:
                    return UsageWindow(
                        id: kind, name: kind.displayName, isRequired: true,
                        used: 39, limit: 100,
                        resetAt: current.addingTimeInterval(12 * 24 * 3600))
                }
            }
            snapshots[slotID] = UsageSnapshot(
                slotID: slotID, provider: slot.provider,
                windows: windows, capturedAt: current)
        case .incomplete:
            // Drop the last required window so the snapshot is always incomplete.
            let windows: [UsageWindow] = slot.requiredWindows.dropLast().map { kind in
                UsageWindow(
                    id: kind, name: kind.displayName, isRequired: true,
                    used: 30, limit: 100, resetAt: current.addingTimeInterval(1200))
            }
            snapshots[slotID] = UsageSnapshot(
                slotID: slotID, provider: slot.provider,
                windows: windows, capturedAt: current)
        case .staleHistory:
            snapshots[slotID] = UsageSnapshot(
                slotID: slotID, provider: slot.provider,
                windows: [UsageWindow(
                    id: .fiveHour, name: "5 hour", isRequired: true,
                    used: 65, limit: 100, resetAt: current.addingTimeInterval(600))],
                capturedAt: current.addingTimeInterval(-16 * 60))
        case .postResetPending:
            snapshots[slotID] = UsageSnapshot(
                slotID: slotID, provider: slot.provider,
                windows: [UsageWindow(
                    id: .fiveHour, name: "5 hour", isRequired: true,
                    used: 100, limit: 100, resetAt: current.addingTimeInterval(-60))],
                capturedAt: current.addingTimeInterval(-5 * 60))
        }
        refreshDerivedState()
    }

    /// Clear a slot back to its disconnected empty state.
    func clearSlot(_ slotID: AccountSlotID) {
        snapshots[slotID] = nil
        setConnected(slotID, false)
        snapshotStore?.remove(slotID: slotID)
    }

    // MARK: - Persistence bridge

    /// Persist one snapshot atomically; a failed write cannot destroy the previous record.
    func storeSnapshot(_ snapshot: UsageSnapshot) {
        do {
            try snapshotStore?.save(snapshot)
            snapshots[snapshot.slotID] = snapshot
            refreshDerivedState()
        } catch {
            NSLog("[AgentUsage] snapshot save failed: \(error)")
        }
    }

    /// Load persisted snapshots at startup, ignoring quarantined records.
    func loadPersistedSnapshots() {
        guard let snapshotStore else { return }
        var loaded: [AccountSlotID: UsageSnapshot] = [:]
        for slot in slots {
            if case let .loaded(snapshot) = snapshotStore.load(slotID: slot.slotID, now: now()) {
                loaded[slot.slotID] = snapshot
            }
        }
        snapshots = loaded
        refreshDerivedState()
    }

    // MARK: - Codex connection (child 03)

    /// Attach Codex connection management. Called after stores resolve; tests
    /// may inject a manager over fakes.
    func attachCodexManager(_ manager: CodexConnectionManager) {
        codexManager = manager
        for slotID in CodexAccountController.managedSlots where manager.isConnected(slotID) {
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
        }
        refreshDerivedState()
    }

    // MARK: - OpenCode connection (child 04)

    func attachOpenCodeManager(_ manager: OpenCodeConnectionManager) {
        openCodeManager = manager
        for slotID in OpenCodeAccountController.managedSlots where manager.isConnected(slotID) {
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
        }
        refreshDerivedState()
    }

    public func connectOpenCodeSlot(
        _ slotID: AccountSlotID,
        file: URL
    ) -> Result<Void, Error> {
        guard let openCodeManager else { return .failure(OpenCodeConnectionManagerError.notConfigured) }
        do {
            try openCodeManager.connect(slotID: slotID, file: file)
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
            persistConnections()
            refreshDerivedState()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    public func connectOpenCodeSlotManually(
        _ slotID: AccountSlotID,
        apiKey: String
    ) -> Result<Void, Error> {
        guard let openCodeManager else { return .failure(OpenCodeConnectionManagerError.notConfigured) }
        do {
            try openCodeManager.connectManually(slotID: slotID, apiKey: apiKey)
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
            persistConnections()
            refreshDerivedState()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    public func disconnectOpenCodeSlot(_ slotID: AccountSlotID) {
        guard let openCodeManager else { return }
        openCodeManager.disconnect(slotID: slotID)
        authenticationRequiredSlots.remove(slotID)
        snapshots[slotID] = nil
        snapshotStore?.remove(slotID: slotID)
        if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
            slots[index].isConnected = false
        }
        persistConnections()
        refreshDerivedState()
    }

    // MARK: - Command Code connection (child 05)

    func attachCommandCodeManager(_ manager: CommandCodeConnectionManager) {
        commandCodeManager = manager
        for slotID in CommandCodeAccountController.managedSlots where manager.isConnected(slotID) {
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
        }
        refreshDerivedState()
    }

    public func connectCommandCodeSlot(
        _ slotID: AccountSlotID, file: URL
    ) -> Result<Void, Error> {
        guard let commandCodeManager else { return .failure(CommandCodeConnectionManagerError.notConfigured) }
        do {
            try commandCodeManager.connect(slotID: slotID, file: file)
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
            persistConnections(); refreshDerivedState()
            return .success(())
        } catch { return .failure(error) }
    }

    public func connectCommandCodeSlotManually(
        _ slotID: AccountSlotID, apiKey: String
    ) -> Result<Void, Error> {
        guard let commandCodeManager else { return .failure(CommandCodeConnectionManagerError.notConfigured) }
        do {
            try commandCodeManager.connectManually(slotID: slotID, apiKey: apiKey)
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
            persistConnections(); refreshDerivedState()
            return .success(())
        } catch { return .failure(error) }
    }

    public func disconnectCommandCodeSlot(_ slotID: AccountSlotID) {
        guard let commandCodeManager else { return }
        commandCodeManager.disconnect(slotID: slotID)
        authenticationRequiredSlots.remove(slotID)
        snapshots[slotID] = nil
        snapshotStore?.remove(slotID: slotID)
        if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
            slots[index].isConnected = false
        }
        persistConnections(); refreshDerivedState()
    }

    // MARK: - Z.ai connection (child 06)

    func attachZaiManager(_ manager: ZaiConnectionManager) {
        zaiManager = manager
        for slotID in ZaiAccountController.managedSlots where manager.isConnected(slotID) {
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) { slots[index].isConnected = true }
        }
        refreshDerivedState()
    }

    public func connectZaiSlot(_ slotID: AccountSlotID, file: URL) -> Result<Void, Error> {
        guard let zaiManager else { return .failure(ZaiConnectionManagerError.notConfigured) }
        do {
            try zaiManager.connect(slotID: slotID, file: file)
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) { slots[index].isConnected = true }
            persistConnections(); refreshDerivedState()
            return .success(())
        } catch { return .failure(error) }
    }

    public func connectZaiSlotManually(_ slotID: AccountSlotID, apiKey: String) -> Result<Void, Error> {
        guard let zaiManager else { return .failure(ZaiConnectionManagerError.notConfigured) }
        do {
            try zaiManager.connectManually(slotID: slotID, apiKey: apiKey)
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) { slots[index].isConnected = true }
            persistConnections(); refreshDerivedState()
            return .success(())
        } catch { return .failure(error) }
    }

    public func disconnectZaiSlot(_ slotID: AccountSlotID) {
        guard let zaiManager else { return }
        zaiManager.disconnect(slotID: slotID)
        authenticationRequiredSlots.remove(slotID)
        snapshots[slotID] = nil; snapshotStore?.remove(slotID: slotID)
        if let index = slots.firstIndex(where: { $0.slotID == slotID }) { slots[index].isConnected = false }
        persistConnections(); refreshDerivedState()
    }

    public func refreshZaiSlot(_ slotID: AccountSlotID) async -> ZaiRefreshOutcome {
        guard let zaiManager else { return .failed }
        let outcome = await zaiManager.refresh(slotID: slotID)
        switch outcome {
        case let .updated(snapshot):
            snapshots[slotID] = snapshot; storeSnapshot(snapshot)
            authenticationRequiredSlots.remove(slotID)
        case .authenticationRequired, .sourceIdentityChanged:
            authenticationRequiredSlots.insert(slotID)
        case .failed: break
        }
        refreshDerivedState()
        return outcome
    }

    public func refreshCommandCodeSlot(_ slotID: AccountSlotID) async -> CommandCodeRefreshOutcome {
        guard let commandCodeManager else { return .failed }
        let outcome = await commandCodeManager.refresh(slotID: slotID)
        switch outcome {
        case let .updated(snapshot):
            snapshots[slotID] = snapshot
            storeSnapshot(snapshot)
            authenticationRequiredSlots.remove(slotID)
        case .unavailable:
            // Legacy: now maps to .authenticationRequired above; treat same.
            fallthrough
        case .authenticationRequired, .sourceIdentityChanged:
            authenticationRequiredSlots.insert(slotID)
        case .failed:
            break
        }
        refreshDerivedState()
        return outcome
    }

    public func refreshOpenCodeSlot(_ slotID: AccountSlotID) async -> OpenCodeRefreshOutcome {
        guard let openCodeManager else { return .failed }
        let outcome = await openCodeManager.refresh(slotID: slotID)
        switch outcome {
        case let .updated(snapshot):
            snapshots[slotID] = snapshot
            storeSnapshot(snapshot)
            authenticationRequiredSlots.remove(slotID)
        case .authenticationRequired, .sourceIdentityChanged:
            authenticationRequiredSlots.insert(slotID)
        case .failed:
            break
        }
        refreshDerivedState()
        return outcome
    }

    /// Connect the GPT Personal slot to the selected Codex profile directory
    /// (explicit consent). Binding is rejected when the directory is already
    /// bound to a Claude slot or holds no usable ChatGPT OAuth material.
    public func connectCodexSlot(
        _ slotID: AccountSlotID,
        directory: URL
    ) -> Result<Void, Error> {
        guard let codexManager else { return .failure(CodexConnectionManagerError.notConfigured) }
        do {
            try codexManager.connect(slotID: slotID, directory: directory)
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
            persistConnections()
            refreshDerivedState()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Disconnect the GPT Personal slot, removing only its app-owned credential,
    /// bookmark record, and snapshot. The user is never logged out of Codex.
    public func disconnectCodexSlot(_ slotID: AccountSlotID) {
        guard let codexManager else { return }
        codexManager.disconnect(slotID: slotID)
        authenticationRequiredSlots.remove(slotID)
        snapshots[slotID] = nil
        snapshotStore?.remove(slotID: slotID)
        if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
            slots[index].isConnected = false
        }
        persistConnections()
        refreshDerivedState()
    }

    /// Refresh the GPT Personal slot through the Codex connection manager.
    ///
    /// Outcomes follow child spec R4 and parent R7/R11: success persists a valid
    /// snapshot; identity loss raises AUTHENTICATION_REQUIRED; every other
    /// failure keeps the last valid snapshot as history without fabricating usage.
    public func refreshCodexSlot(_ slotID: AccountSlotID) async -> CodexRefreshOutcome {
        guard let codexManager else { return .failed }
        let outcome = await codexManager.refresh(slotID: slotID)
        switch outcome {
        case let .updated(snapshot):
            snapshots[slotID] = snapshot
            storeSnapshot(snapshot)
            authenticationRequiredSlots.remove(slotID)
        case .authenticationRequired, .sourceIdentityChanged:
            // Keep the prior snapshot purely as historical context (parent R7/R11).
            authenticationRequiredSlots.insert(slotID)
        case .failed:
            break
        }
        refreshDerivedState()
        return outcome
    }

    // MARK: - Claude connections (child 02)

    /// Attach Claude connection management. Called after stores resolve; tests
    /// may inject a manager over fakes.
    func attachClaudeManager(_ manager: ClaudeConnectionManager) {
        claudeManager = manager
        for slotID in ClaudeAccountController.managedSlots where manager.isConnected(slotID) {
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
        }
        refreshDerivedState()
    }

    /// Connect a Claude slot to the selected profile directory (explicit consent).
    public func connectClaudeSlot(
        _ slotID: AccountSlotID,
        directory: URL
    ) -> Result<Void, Error> {
        guard let claudeManager else { return .failure(ClaudeConnectionError.notConfigured) }
        do {
            try claudeManager.connect(slotID: slotID, directory: directory)
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
                slots[index].isConnected = true
            }
            persistConnections()
            refreshDerivedState()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Disconnect a Claude slot, removing only its app-owned credential,
    /// bookmark record, and snapshot (child spec R8, I2).
    public func disconnectClaudeSlot(_ slotID: AccountSlotID) {
        guard let claudeManager else { return }
        claudeManager.disconnect(slotID: slotID)
        authenticationRequiredSlots.remove(slotID)
        snapshots[slotID] = nil
        snapshotStore?.remove(slotID: slotID)
        if let index = slots.firstIndex(where: { $0.slotID == slotID }) {
            slots[index].isConnected = false
        }
        persistConnections()
        refreshDerivedState()
    }

    /// Refresh one Claude slot through the connection manager.
    ///
    /// Outcomes follow child spec R6/R7 and parent R7/R11: success persists a
    /// complete-or-partial valid snapshot; identity loss raises
    /// AUTHENTICATION_REQUIRED; every other failure keeps the last valid
    /// snapshot as history without fabricating zero usage.
    public func refreshClaudeSlot(_ slotID: AccountSlotID) async -> ClaudeRefreshOutcome {
        guard let claudeManager else { return .failed }
        let outcome = await claudeManager.refresh(slotID: slotID)
        switch outcome {
        case let .updated(snapshot):
            snapshots[slotID] = snapshot
            storeSnapshot(snapshot)
            authenticationRequiredSlots.remove(slotID)
        case .authenticationRequired, .sourceIdentityChanged:
            // Keep the prior snapshot purely as historical context (parent R7/R11).
            authenticationRequiredSlots.insert(slotID)
        case .failed:
            break
        }
        refreshDerivedState()
        return outcome
    }
}
