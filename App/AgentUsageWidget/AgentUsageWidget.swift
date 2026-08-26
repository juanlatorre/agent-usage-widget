import WidgetKit
import SwiftUI
import AppIntents
import AgentUsageCore

// MARK: - App Intents

struct SelectAccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select account"
    static var description = IntentDescription("Choose one account to show in this widget.")
    @Parameter(title: "Account", description: "The account to display")
    var account: AccountEntity?
    static var parameterSummary: some ParameterSummary { Summary { \.$account } }
    init(account: AccountEntity?) { self.account = account }
    init() {}
}

struct SelectAccountsIntent: AppIntent, WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select accounts"
    static var description = IntentDescription("Choose up to three accounts to show.")
    @Parameter(title: "Account 1") var account1: AccountEntity?
    @Parameter(title: "Account 2") var account2: AccountEntity?
    @Parameter(title: "Account 3") var account3: AccountEntity?
    init() {}
    init(account1: AccountEntity?, account2: AccountEntity?, account3: AccountEntity?) {
        self.account1 = account1; self.account2 = account2; self.account3 = account3
    }
    var selectedIDs: [AccountSlotID] { [account1, account2, account3].compactMap { $0?.slotID } }
}

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Now"
    static var description = IntentDescription("Refresh the selected accounts.")
    static var openAppWhenRun: Bool = false
    @Parameter(title: "Account IDs") var accountIDs: [String]?
    init(accountIDs: [String]? = nil) { self.accountIDs = accountIDs }
    init() {}
    func perform() async throws -> some IntentResult {
        if let ids = accountIDs, !ids.isEmpty {
            let base = WidgetStore.widgetRefreshRequestURL
            let payload: [String: Any] = ["slotIDs": ids, "requestedAt": ISO8601DateFormatter().string(from: Date())]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                let dir = base.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: base, options: .atomic)
            }
        }
        return .result()
    }
}

// MARK: - AccountEntity

struct AccountEntity: AppEntity, Identifiable {
    var id: String { slotID.rawValue }
    let slotID: AccountSlotID
    let displayName: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(displayName)") }
    static var defaultQuery = AccountQuery()
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        AccountCatalog.slots.filter { identifiers.contains($0.slotID.rawValue) }
            .map { AccountEntity(slotID: $0.slotID, displayName: $0.label) }
    }
    func suggestedEntities() async throws -> [AccountEntity] {
        AccountCatalog.slots.map { AccountEntity(slotID: $0.slotID, displayName: $0.label) }
    }
}

// MARK: - Timeline

struct WidgetStore {
    static var appGroupID: String { "group.com.juanlatorre.agent-usage" }
    static var snapshotBaseURL: URL? { SnapshotStore.defaultBaseURL(appGroupID: appGroupID) }
    static var preferencesFileURL: URL? { PreferencesStore.defaultFileURL(appGroupID: appGroupID) }
    static var connectionsFileURL: URL? {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("connections.json")
        }
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("connections.json")
    }
    static var widgetRefreshRequestURL: URL {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("widget-refresh-request.json")
        }
        return fm.temporaryDirectory.appendingPathComponent("widget-refresh-request.json")
    }
    // Merge Group Container + Application Support fallback — widget must see snapshots written via fallback too
    static func loadSnapshots() -> [AccountSlotID: UsageSnapshot] {
        var result: [AccountSlotID: UsageSnapshot] = [:]
        let fm = FileManager.default
        var bases: [URL] = []
        if let base = snapshotBaseURL { bases.append(base) }
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let fallback = appSupport.appendingPathComponent("AgentUsageWidget", isDirectory: true).appendingPathComponent("snapshots", isDirectory: true)
            if !bases.contains(where: { $0.path == fallback.path }) { bases.append(fallback) }
        }
        for base in bases {
            let store = SnapshotStore(baseURL: base)
            for slot in AccountCatalog.slots where result[slot.slotID] == nil {
                if case .loaded(let snap) = store.load(slotID: slot.slotID) { result[slot.slotID] = snap }
            }
        }
        return result
    }
    static func loadPreferences() -> DisplayPreferences {
        guard let url = preferencesFileURL else { return DisplayPreferences() }
        return PreferencesStore(fileURL: url).load()
    }
    static func loadConnectedSlotIDs() -> Set<AccountSlotID> {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let url = connectionsFileURL { candidates.append(url) }
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let fallback = appSupport.appendingPathComponent("AgentUsageWidget", isDirectory: true).appendingPathComponent("connections.json")
            if !candidates.contains(where: { $0.path == fallback.path }) { candidates.append(fallback) }
        }
        for url in candidates {
            guard fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(ConnectionBox.self, from: data) else { continue }
            var set = Set<AccountSlotID>()
            for rawID in state.connectedSlotIDs {
                if let id = AccountSlotID(rawValue: rawID) { set.insert(id) }
                else if let alias = AccountSlotID.legacyAliases[rawID] { set.insert(alias) }
            }
            if !set.isEmpty { return set }
        }
        return []
    }
    private struct ConnectionBox: Codable { var connectedSlotIDs: Set<String> = [] }
    /// Slots with isConnected patched from connections.json — so the widget never
    /// shows every row as “Not connected” when the app has already connected.
    /// - Parameter preferAvailablePreview: when true (placeholder/gallery), show as-if connected
    ///   so the widget gallery never paints the system yellow error overlay.
    static func catalogSlotsWithConnection(preferAvailablePreview: Bool = false) -> [AccountSlot] {
        let connected = loadConnectedSlotIDs()
        let hasAny = !connected.isEmpty
        return AccountCatalog.slots.map { var s = $0; s.isConnected = preferAvailablePreview ? true : (hasAny ? connected.contains(s.slotID) : false); return s }
    }
}

struct AgentUsageEntry: TimelineEntry {
    let date: Date
    let presentations: [AccountPresentation]
    let displayMode: DisplayPreferences.DisplayMode
    let configuredSlotIDs: [AccountSlotID]
    let family: AgentUsageCore.WidgetFamily?
    let isUnconfigured: Bool
}

// MARK: - Providers

struct SmallProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AgentUsageEntry {
        AgentUsageEntry(date: Date(), presentations: AvailabilityEngine.deriveAll(slots: WidgetStore.catalogSlotsWithConnection(preferAvailablePreview: true), snapshots: [:], now: Date()),
                        displayMode: .remaining, configuredSlotIDs: [], family: .small, isUnconfigured: false)
    }
    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> AgentUsageEntry {
        makeEntry(configured: configuration.account.map { [$0.slotID] } ?? [], family: .small)
    }
    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<AgentUsageEntry> {
        makeTimeline(configured: configuration.account.map { [$0.slotID] } ?? [], family: .small)
    }
    private func makeEntry(configured: [AccountSlotID], family: AgentUsageCore.WidgetFamily?) -> AgentUsageEntry {
        let now = Date()
        let snaps = WidgetStore.loadSnapshots()
        let prefs = WidgetStore.loadPreferences()
        let connected = WidgetStore.loadConnectedSlotIDs()
        let slots = AccountCatalog.slots.map { var s = $0; s.isConnected = connected.contains(s.slotID); return s }
        let failures = loadFailures()
        let transient: [AccountSlotID: Date] = Dictionary(uniqueKeysWithValues: failures.compactMap { (id, rec) in
            guard rec.nextRetryAt != nil else { return nil }
            return (id, rec.attemptAt)
        })
        let derived = AvailabilityEngine.deriveAll(slots: slots, snapshots: snaps, now: now, transientFailures: transient)
        let filtered: [AccountPresentation]
        if configured.isEmpty { filtered = derived } else {
            let set = Set(configured)
            filtered = derived.filter { set.contains($0.slotID) }
        }
        let isUnconfigured = configured.isEmpty
        return AgentUsageEntry(date: now, presentations: filtered.isEmpty ? derived : filtered,
                               displayMode: prefs.displayMode, configuredSlotIDs: configured, family: family, isUnconfigured: isUnconfigured)
    }
    private func makeTimeline(configured: [AccountSlotID], family: AgentUsageCore.WidgetFamily?) -> Timeline<AgentUsageEntry> {
        let now = Date()
        let base = makeEntry(configured: configured, family: family)
        let snaps = WidgetStore.loadSnapshots()
        var boundaries: [Date] = []
        for snap in snaps.values where !snap.windows.isEmpty {
            for w in snap.windows where w.resetAt > now { boundaries.append(w.resetAt) }
            boundaries.append(snap.capturedAt.addingTimeInterval(15 * 60))
        }
        let soonest = boundaries.filter { $0 > now }.min()
        let five: TimeInterval = 5 * 60
        let next: Date
        if let s = soonest, s.timeIntervalSince(now) < five { next = now.addingTimeInterval(five) }
        else if let s = soonest { next = s } else { next = now.addingTimeInterval(five) }
        let nextEntry = AgentUsageEntry(date: next, presentations: base.presentations, displayMode: base.displayMode,
                                        configuredSlotIDs: base.configuredSlotIDs, family: base.family, isUnconfigured: base.isUnconfigured)
        return Timeline(entries: [base, nextEntry], policy: .after(next))
    }
    private func loadFailures() -> [AccountSlotID: RefreshFailureRecord] {
        guard let url = RefreshFailureStore.defaultFileURL(appGroupID: WidgetStore.appGroupID) else { return [:] }
        return RefreshFailureStore(fileURL: url).load()
    }
}

struct MediumProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AgentUsageEntry {
        AgentUsageEntry(date: Date(), presentations: AvailabilityEngine.deriveAll(slots: WidgetStore.catalogSlotsWithConnection(preferAvailablePreview: true), snapshots: [:], now: Date()),
                        displayMode: .remaining, configuredSlotIDs: [], family: .medium, isUnconfigured: false)
    }
    func snapshot(for configuration: SelectAccountsIntent, in context: Context) async -> AgentUsageEntry {
        makeEntry(configured: configuration.selectedIDs, family: .medium)
    }
    func timeline(for configuration: SelectAccountsIntent, in context: Context) async -> Timeline<AgentUsageEntry> {
        makeTimeline(configured: configuration.selectedIDs, family: .medium)
    }
    private func makeEntry(configured: [AccountSlotID], family: AgentUsageCore.WidgetFamily?) -> AgentUsageEntry {
        let now = Date()
        let snaps = WidgetStore.loadSnapshots()
        let prefs = WidgetStore.loadPreferences()
        let connected = WidgetStore.loadConnectedSlotIDs()
        let slots = AccountCatalog.slots.map { var s = $0; s.isConnected = connected.contains(s.slotID); return s }
        let failures = loadFailures()
        let transient: [AccountSlotID: Date] = Dictionary(uniqueKeysWithValues: failures.compactMap { (id, rec) in
            guard rec.nextRetryAt != nil else { return nil }
            return (id, rec.attemptAt)
        })
        let derived = AvailabilityEngine.deriveAll(slots: slots, snapshots: snaps, now: now, transientFailures: transient)
        let filtered: [AccountPresentation]
        if configured.isEmpty { filtered = derived } else {
            let set = Set(configured)
            filtered = derived.filter { set.contains($0.slotID) }
        }
        let isUnconfigured = configured.isEmpty
        return AgentUsageEntry(date: now, presentations: filtered.isEmpty ? derived : filtered,
                               displayMode: prefs.displayMode, configuredSlotIDs: configured, family: family, isUnconfigured: isUnconfigured)
    }
    private func makeTimeline(configured: [AccountSlotID], family: AgentUsageCore.WidgetFamily?) -> Timeline<AgentUsageEntry> {
        let now = Date()
        let base = makeEntry(configured: configured, family: family)
        let snaps = WidgetStore.loadSnapshots()
        var boundaries: [Date] = []
        for snap in snaps.values where !snap.windows.isEmpty {
            for w in snap.windows where w.resetAt > now { boundaries.append(w.resetAt) }
            boundaries.append(snap.capturedAt.addingTimeInterval(15 * 60))
        }
        let soonest = boundaries.filter { $0 > now }.min()
        let five: TimeInterval = 5 * 60
        let next: Date
        if let s = soonest, s.timeIntervalSince(now) < five { next = now.addingTimeInterval(five) }
        else if let s = soonest { next = s } else { next = now.addingTimeInterval(five) }
        let nextEntry = AgentUsageEntry(date: next, presentations: base.presentations, displayMode: base.displayMode,
                                        configuredSlotIDs: base.configuredSlotIDs, family: base.family, isUnconfigured: base.isUnconfigured)
        return Timeline(entries: [base, nextEntry], policy: .after(next))
    }
    private func loadFailures() -> [AccountSlotID: RefreshFailureRecord] {
        guard let url = RefreshFailureStore.defaultFileURL(appGroupID: WidgetStore.appGroupID) else { return [:] }
        return RefreshFailureStore(fileURL: url).load()
    }
}

struct LargeProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentUsageEntry {
        AgentUsageEntry(date: Date(), presentations: AvailabilityEngine.deriveAll(slots: WidgetStore.catalogSlotsWithConnection(preferAvailablePreview: true), snapshots: [:], now: Date()),
                        displayMode: .remaining, configuredSlotIDs: [], family: .large, isUnconfigured: false)
    }
    func getSnapshot(in context: Context, completion: @escaping (AgentUsageEntry) -> Void) {
        let now = Date()
        let snaps = WidgetStore.loadSnapshots()
        let prefs = WidgetStore.loadPreferences()
        let connected = WidgetStore.loadConnectedSlotIDs()
        let slots = AccountCatalog.slots.map { var s = $0; s.isConnected = connected.contains(s.slotID); return s }
        completion(AgentUsageEntry(date: now, presentations: AvailabilityEngine.deriveAll(slots: slots, snapshots: snaps, now: now),
                                   displayMode: prefs.displayMode, configuredSlotIDs: [], family: .large, isUnconfigured: false))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentUsageEntry>) -> Void) {
        let now = Date()
        let snaps = WidgetStore.loadSnapshots()
        let prefs = WidgetStore.loadPreferences()
        let connected = WidgetStore.loadConnectedSlotIDs()
        let slots = AccountCatalog.slots.map { var s = $0; s.isConnected = connected.contains(s.slotID); return s }
        let base = AgentUsageEntry(date: now, presentations: AvailabilityEngine.deriveAll(slots: slots, snapshots: snaps, now: now),
                                   displayMode: prefs.displayMode, configuredSlotIDs: [], family: .large, isUnconfigured: false)
        let next = now.addingTimeInterval(5 * 60)
        let nextEntry = AgentUsageEntry(date: next, presentations: base.presentations, displayMode: base.displayMode,
                                        configuredSlotIDs: [], family: .large, isUnconfigured: false)
        completion(Timeline(entries: [base, nextEntry], policy: .after(next)))
    }
}

// MARK: - Widgets

struct SmallWidget: Widget {
    let kind: String = "AgentUsageSmall"
    var body: some SwiftUI.WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectAccountIntent.self, provider: SmallProvider()) { entry in
            SmallView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Agent Usage")
        .description("One account at a glance.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct MediumWidget: Widget {
    let kind: String = "AgentUsageMedium"
    var body: some SwiftUI.WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectAccountsIntent.self, provider: MediumProvider()) { entry in
            MediumView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Agent Usage")
        .description("Up to three accounts.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct LargeWidget: Widget {
    let kind: String = "AgentUsageLarge"
    var body: some SwiftUI.WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LargeProvider()) { entry in
            LargeView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Agent Usage")
        .description("All six accounts.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct AgentUsageWidgetBundle: WidgetBundle {
    var body: some Widget { SmallWidget(); MediumWidget(); LargeWidget() }
}
