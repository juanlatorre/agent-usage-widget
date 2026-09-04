import SwiftUI
import WidgetKit
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
    /// Per-slot transient failure attempt times; StatusModel keeps the source-of-truth map
    /// and seeds the scheduler's failure store, then drives transientFailureAt into
    /// AvailabilityEngine (07 R5: ERROR before 15m, UNAVAILABLE after).
    @ObservationIgnored private var transientFailureAt: [AccountSlotID: Date] = [:]
    /// Scheduler + failureStore + service wiring for 07 (attached once by AgentUsageApp).
    @ObservationIgnored private var refreshScheduler: RefreshScheduler?
    @ObservationIgnored private var refreshFailureStore: RefreshFailureStore?
    @ObservationIgnored private var refreshService: RefreshService?
    /// Periodic tick that lets due/retry deadlines fire while the app is open.
    @ObservationIgnored private var recoveryTimer: Timer?
    @ObservationIgnored var loginItemController: (any LoginItemControlling)?

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
            authenticationRequired: authenticationRequiredSlots,
            transientFailures: transientFailureAt)
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

    // MARK: - 07 Background refresh helpers

    var connectedSlots: Set<AccountSlotID> {
        Set(slots.filter(\.isConnected).map(\.slotID))
    }

    private static let backgroundOptOutKey = "agentUsage.backgroundRefreshOptOut"

    var isBackgroundRefreshEnabled: Bool { refreshScheduler != nil ? (loginItemController?.isEnabled ?? false) : false }

    func loginItemStatus() -> LoginItemStatus { loginItemController?.status() ?? .notSupported }

    func setBackgroundRefreshEnabled(_ enabled: Bool) {
        guard !connectedSlots.isEmpty else { return }
        // Remember explicit user intent so the default-on logic never fights it.
        UserDefaults.standard.set(!enabled, forKey: Self.backgroundOptOutKey)
        do { try loginItemController?.setEnabled(enabled) } catch { NSLog("[AgentUsage] login item toggle failed: %@", String(describing: error)) }
    }

    /// Background refresh is ON by default: a usage monitor whose widgets go
    /// stale because the login item was never registered is indistinguishable
    /// from a broken app. Registers the main app via SMAppService unless the
    /// user explicitly turned the toggle off. Called at launch and after the
    /// first successful connection.
    func enableBackgroundRefreshByDefault() {
        guard let controller = loginItemController else { return }
        guard !connectedSlots.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: Self.backgroundOptOutKey) { return }
        switch controller.status() {
        case .enabled, .requiresApproval:
            break // already registered or awaiting approval in System Settings
        default:
            do { try controller.setEnabled(true) } catch {
                NSLog("[AgentUsage] default background enable failed: %@", String(describing: error))
            }
        }
    }

    /// Called after first successful connection per R1 lazy registration.
    func ensureBackgroundRefreshAvailableAfterConnect() {
        enableBackgroundRefreshByDefault()
    }

    /// Eagerly touch every connected slot's credential so pre-group items
    /// migrate into the shared keychain access group on first launch after
    /// the update. The widget depends on the grouped items existing.
    func migrateKeychainToSharedGroup(keychain: KeychainStore) {
        var migrated = 0
        for slot in slots where slot.isConnected {
            let had: Bool
            switch slot.slotID {
            case .claude: had = keychain.credentials(account: .claude) != nil
            case .chatGPT: had = keychain.credentials(account: .chatGPT) != nil
            case .openCodeGO: had = keychain.openCodeCredentials(account: .openCodeGO) != nil
            case .commandCodeGOAT: had = keychain.commandCodeCredentials(account: .commandCodeGOAT) != nil
            case .zaiCodingPlan: had = keychain.zaiCredentials(account: .zaiCodingPlan) != nil
            }
            if had { migrated += 1 }
        }
        NSLog("[AgentUsage] keychain shared-group migration: %d slots verified", migrated)
    }

    /// Mirror current credentials for connected slots into the widget
    /// extension's container (0600). The sandboxed widget reads this file to
    /// refresh usage itself — it cannot read the login Keychain.
    func mirrorCredentialsToWidgetContainer(container: URL, keychain: KeychainStore) {
        var credentials: [AccountSlotID: MirroredCredential] = [:]
        if let c = keychain.credentials(account: .claude) {
            credentials[.claude] = MirroredCredential(
                claudeOAuthJSON: try? JSONEncoder().encode(c))
        }
        if let c = keychain.credentials(account: .chatGPT) {
            credentials[.chatGPT] = MirroredCredential(
                codexOAuthJSON: try? JSONEncoder().encode(c))
        }
        if let c = keychain.openCodeCredentials(account: .openCodeGO) {
            credentials[.openCodeGO] = MirroredCredential(apiKey: c.apiKey)
        }
        if let c = keychain.commandCodeCredentials(account: .commandCodeGOAT) {
            credentials[.commandCodeGOAT] = MirroredCredential(apiKey: c.apiKey)
        }
        if let c = keychain.zaiCredentials(account: .zaiCodingPlan) {
            credentials[.zaiCodingPlan] = MirroredCredential(apiKey: c.apiKey)
        }
        // Only slots with real material; drop empties.
        credentials = credentials.filter { entry in
            entry.value.apiKey != nil || entry.value.claudeOAuthJSON != nil || entry.value.codexOAuthJSON != nil
        }
        try? CredentialMirror.write(credentials: credentials, container: container)
    }

    func refreshAllNow() async {
        guard let refreshService else { return }
        await refreshService.triggerGlobal(trigger: .manualGlobal)
    }

    /// URL-triggered refresh (agent-usage://refresh from the widget's Link):
    /// detached so the SwiftUI URL handler can't be cancelled mid-fetch.
    func refreshAllNowDetached() {
        Task { await refreshAllNow() }
    }

    /// Widget refresh button posts this notification; StatusModel responds.
    func startListeningForRefreshRequests() {
        NotificationCenter.default.addObserver(
            forName: .init("AgentUsageForceRefresh"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAllNow()
            }
        }
    }

    /// Listens for widget-initiated refresh requests (URL scheme handler).


    func refreshVisibleSlots(_ slotIDs: [AccountSlotID]) async {
        guard let refreshService else { return }
        await refreshService.triggerSlots(slotIDs, trigger: .widget)
    }

    /// Entry point for SwiftUI lifecycle hooks. Detached by design: the view's
    /// `.task` is cancelled on re-render/navigation — the refresh work itself
    /// must not be (see handleAppActivation()).
    func handleAppActivationDetached() {
        Task { await handleAppActivation() }
    }

    /// App activation trigger (R9).
    func handleAppActivation() async {
        consumeWidgetRefreshRequest()
        guard let refreshService else {
            // Fallback when RefreshService hasn't been wired (pre-07 builds):
            // at least refresh the connected slots directly via their managers.
            await refreshConnectedSlotsDirectly()
            return
        }
        await refreshService.triggerGlobal(trigger: .appActivation)
    }

    /// Consume a pending widget "Refresh Now" request (written by the widget's
    /// RefreshWidgetIntent, which opens the app). Refreshes the requested
    /// slots immediately via the manual per-account trigger (safe override:
    /// non-rate-limit backoff may be bypassed by explicit user intent).
    private func consumeWidgetRefreshRequest() {
        let fm = FileManager.default
        var candidates: [URL] = []
        // The widget's own container — the one place its sandboxed RefreshWidgetIntent
        // can reliably write (group containers are EPERM for it under Developer ID).
        if let widgetContainer = SharedStoreLocations.widgetContainerDirectory() {
            candidates.append(widgetContainer.appendingPathComponent("widget-refresh-request.json"))
        }
        for groupID in [SharedStoreLocations.canonicalAppGroupID] {
            if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
                candidates.append(container.appendingPathComponent("widget-refresh-request.json"))
            }
            let direct = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers", isDirectory: true)
                .appendingPathComponent(groupID, isDirectory: true)
                .appendingPathComponent("widget-refresh-request.json")
            candidates.append(direct)
        }
        for url in candidates where fm.fileExists(atPath: url.path) {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawIDs = payload["slotIDs"] as? [String] else { continue }
            let slotIDs = rawIDs.compactMap { AccountSlotID(rawValue: $0) }
            guard !slotIDs.isEmpty, let refreshService else { continue }
            NSLog("[AgentUsage] consuming widget refresh request for %@", rawIDs.joined(separator: ","))
            Task { @MainActor in
                await refreshService.triggerSlots(slotIDs, trigger: .manualPerAccount)
            }
        }
    }

    private func refreshConnectedSlotsDirectly() async {
        // Fire all connected slots concurrently; each manager handles its own auth/transport.
        await withTaskGroup(of: Void.self) { group in
            for slotID in connectedSlots {
                group.addTask { [self] in
                    switch slotID {
                    case .claude: _ = await self.refreshClaudeSlot(slotID)
                    case .chatGPT: _ = await self.refreshCodexSlot(slotID)
                    case .openCodeGO: _ = await self.refreshOpenCodeSlot(slotID)
                    case .commandCodeGOAT: _ = await self.refreshCommandCodeSlot(slotID)
                    case .zaiCodingPlan: _ = await self.refreshZaiSlot(slotID)
                    }
                }
            }
        }
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
            // Mirror to the App Group container so the sandboxed widget
            // extension derives the same connected/not-connected state.
            try? SharedStoreLocations.writeMirrored(
                data,
                primary: connectionsURL,
                mirrors: SharedStoreLocations.mirrorURLs(
                    forFileName: connectionsURL.lastPathComponent, primary: connectionsURL))
        }
    }

    private static func loadConnections(from url: URL?) -> [AccountSlot] {
        guard let url, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ConnectionState.self, from: data) else {
            return AccountCatalog.slots
        }
        return AccountCatalog.slots.map { slot in
            var copy = slot
            let raw = slot.slotID.rawValue
            let isDirect = state.connectedSlotIDs.contains(raw)
            // Legacy "gpt-personal" → "chatgpt" rename
            let isLegacy = slot.slotID == .chatGPT && state.connectedSlotIDs.contains("gpt-personal")
            copy.isConnected = isDirect || isLegacy
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
            // Widgets render from persisted snapshots; without this they keep
            // showing the previous timeline entry for minutes after new data
            // landed ("the refresh button does nothing" — observed live).
            WidgetCenter.shared.reloadAllTimelines()
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
            transientFailureAt[slotID] = nil
        case .authenticationRequired, .sourceIdentityChanged:
            authenticationRequiredSlots.insert(slotID)
            transientFailureAt[slotID] = nil
        case .rateLimited:
            // The scheduler (via RefreshService) honors the server Retry-After.
            transientFailureAt[slotID] = now()
            break
        case .failed:
            transientFailureAt[slotID] = now()
            break
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
            transientFailureAt[slotID] = nil
        case .unavailable:
            fallthrough
        case .authenticationRequired, .sourceIdentityChanged:
            authenticationRequiredSlots.insert(slotID)
            transientFailureAt[slotID] = nil
        case .rateLimited:
            // The scheduler (via RefreshService) honors the server Retry-After.
            transientFailureAt[slotID] = now()
            break
        case .failed:
            transientFailureAt[slotID] = now()
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
            transientFailureAt[slotID] = nil
        case .authenticationRequired, .sourceIdentityChanged:
            authenticationRequiredSlots.insert(slotID)
            transientFailureAt[slotID] = nil
        case .rateLimited:
            // The scheduler (via RefreshService) honors the server Retry-After.
            transientFailureAt[slotID] = now()
            break
        case .failed:
            transientFailureAt[slotID] = now()
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

    /// One-click connect for the default ~/.codex location.
    /// With app-sandbox enabled, the programmatic ~/.codex path has no security-scoped
    /// access and produces directoryUnreadable → previously shown as "already bound".
    /// Instead, try a direct (no-bookmark) read for the well-known default home; if that
    /// also fails, surface the real error so CodexConnectionSection can hint
    /// “Use Or choose folder”.
    public func connectCodexDefault(_ slotID: AccountSlotID) -> Result<Void, Error> {
        guard let codexManager else { return .failure(CodexConnectionManagerError.notConfigured) }
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        NSLog("[AgentUsage] connectCodexDefault trying %@", defaultDir.path)
        // First attempt: normal bookmark path (works when already granted or non-sandboxed).
        let normal = connectCodexSlot(slotID, directory: defaultDir)
        if case .success = normal {
            NSLog("[AgentUsage] connectCodexDefault normal path succeeded")
            return normal
        }
        if case .failure(let err) = normal {
            NSLog("[AgentUsage] connectCodexDefault normal path failed: %@", String(describing: err))
        }
        // Second attempt: direct read of ~/.codex/auth.json without requiring a bookmark.
        // Only for the exact default home, not for arbitrary user-picked folders.
        let fm = FileManager.default
        let authURL = defaultDir.appendingPathComponent("auth.json")
        NSLog("[AgentUsage] connectCodexDefault fallback: auth exists=%@ path=%@", fm.fileExists(atPath: authURL.path) ? "yes" : "no", authURL.path)
        guard fm.fileExists(atPath: authURL.path) else {
            return normal
        }
        guard let data = try? Data(contentsOf: authURL) else {
            NSLog("[AgentUsage] connectCodexDefault fallback: cannot read data")
            return normal
        }
        guard let creds = try? CodexAuthParser.parse(data: data) else {
            NSLog("[AgentUsage] connectCodexDefault fallback: parse failed")
            return normal
        }
        NSLog("[AgentUsage] connectCodexDefault fallback: parsed accountID=%@", creds.accountID ?? "nil")
        do {
            try codexManager.connectDirect(slotID: slotID, credentials: creds, directory: defaultDir)
            NSLog("[AgentUsage] connectCodexDefault fallback succeeded")
            authenticationRequiredSlots.remove(slotID)
            if let index = slots.firstIndex(where: { $0.slotID == slotID }) { slots[index].isConnected = true }
            persistConnections(); refreshDerivedState()
            return .success(())
        } catch {
            NSLog("[AgentUsage] connectCodexDefault fallback failed: %@", String(describing: error))
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
            transientFailureAt[slotID] = nil
        case .authenticationRequired, .sourceIdentityChanged:
            authenticationRequiredSlots.insert(slotID)
            transientFailureAt[slotID] = nil
        case .rateLimited:
            // The scheduler (via RefreshService) honors the server Retry-After.
            transientFailureAt[slotID] = now()
            break
        case .failed:
            transientFailureAt[slotID] = now()
            break
        }
        refreshDerivedState()
        return outcome
    }

    // MARK: - Claude connections (child 02)

    /// Attach Claude connection management. Called after stores resolve; tests
    /// may inject a manager over fakes.
    // MARK: - 07 Unified refresh wiring

    /// Attach the scheduler + stores backing the RefreshService. Called once by AgentUsageApp
    /// after stores resolve. Hydrates persisted failures (crash/upgrade recovery, §7).
    func attachRefreshService(scheduler: RefreshScheduler, failureStore: RefreshFailureStore, service: RefreshService) {
        self.refreshScheduler = scheduler
        self.refreshFailureStore = failureStore
        self.refreshService = service
        // Seed transient map from persisted failures.
        let records = failureStore.load()
        for (slotID, rec) in records { transientFailureAt[slotID] = rec.attemptAt }
        // If snapshots had expired resets, derive as historical UNAVAILABLE until verified (R8).
        refreshDerivedState()
        startRecoveryTimer()
    }

    /// Drives due/retry deadlines while the app is open. Without this, a slot
    /// whose rate limit expires mid-session (e.g. Claude's Retry-After window)
    /// would stay stale until the next activation — there is no other periodic
    /// trigger in the app. The tick is cheap: the scheduler gates every fetch
    // behind nextRetryAt/nextDueAt, so nothing hits the network until due.
    private func startRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let service = self.refreshService else { return }
                await service.triggerGlobal(trigger: .interval)
            }
        }
    }

    /// Exposed for the helper/background path to drive fetches without duplicating Manager logic.
    var unifiedFetcher: ((AccountSlotID) async -> Result<UsageSnapshot, RefreshFetchError>)?

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
    /// Falls back to the macOS Keychain Claude session when the directory holds no
    /// .credentials.json (modern Claude Code stores in Keychain, not ~/.claude).
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
            // Keychain fallback: many installs never write ~/.claude/.credentials.json.
            // Try importing the real Keychain session before surfacing the file error.
            if let creds = ClaudeKeychainImporter.load() {
                switch connectClaudeDirectly(slotID: slotID, credentials: creds, directoryHint: directory) {
                case .success: return .success(())
                case .failure: break
                }
            }
            return .failure(error)
        }
    }

    /// One-click connect for Claude when the user doesn't have a profile-dir split.
    /// Uses the current Keychain session and a synthetic bookmark so the single Claude slot
    /// remain distinct slots (second call picks the alternate Keychain entry if available).
    public func connectClaudeFromKeychain(_ slotID: AccountSlotID) -> Result<Void, Error> {
        guard let claudeManager else { return .failure(ClaudeConnectionError.notConfigured) }
        let identities = ClaudeKeychainImporter.allIdentities()
        // Prefer an identity not already consumed by the sibling slot when possible.
        let occupied: Set<String> = {
            guard !identities.isEmpty, let connections = claudeManager.connection(.claude).map({ [$0] }) else {
                // Fallback: check both slots explicitly through the manager's connection inspection
                var s = Set<String>()
                for id in ClaudeAccountController.managedSlots {
                    if let c = claudeManager.connection(id) { s.insert(c.importedIdentity.fingerprint) }
                }
                return s
            }
            var s = Set<String>(connections.map(\.importedIdentity.fingerprint))
            for id in ClaudeAccountController.managedSlots where id != .claude {
                if let c = claudeManager.connection(id) { s.insert(c.importedIdentity.fingerprint) }
            }
            return s
        }()
        let pick = identities.first(where: { !occupied.contains(ClaudeProfileSource.fingerprint($0.credentials.accessToken)) }) ?? identities.first
        guard let chosen = pick else { return .failure(ConnectionControllerError.noUsableCredentials) }
        return connectClaudeDirectly(slotID: slotID, credentials: chosen.credentials, directoryHint: nil)
    }

    private func connectClaudeDirectly(slotID: AccountSlotID, credentials: ClaudeOAuthCredentials, directoryHint: URL?) -> Result<Void, Error> {
        guard let claudeManager else { return .failure(ClaudeConnectionError.notConfigured) }
        do {
            try claudeManager.importDirect(slotID: slotID, credentials: credentials, directoryHint: directoryHint)
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
    /// snapshot as history without fabricating zero usage. Transient .failed
    /// records failureAt so AvailabilityEngine derives ERROR before 15m and
    /// UNAVAILABLE after (07 R5).
    public func refreshClaudeSlot(_ slotID: AccountSlotID) async -> ClaudeRefreshOutcome {
        guard let claudeManager else { return .failed }
        let outcome = await claudeManager.refresh(slotID: slotID)
        switch outcome {
        case let .updated(snapshot):
            snapshots[slotID] = snapshot
            storeSnapshot(snapshot)
            authenticationRequiredSlots.remove(slotID)
            transientFailureAt[slotID] = nil
        case .authenticationRequired, .sourceIdentityChanged:
            authenticationRequiredSlots.insert(slotID)
            transientFailureAt[slotID] = nil
        case .rateLimited:
            // The scheduler (via RefreshService) honors the server Retry-After.
            transientFailureAt[slotID] = now()
            break
        case .failed:
            transientFailureAt[slotID] = now()
            break
        }
        refreshDerivedState()
        return outcome
    }
}
