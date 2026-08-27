import Foundation

/// In-widget usage refresh: fetches provider data directly from the widget
/// extension process, without launching the app.
///
/// This works because (a) the app mirrors connection records and snapshots
/// into the widget extension's own container — the one location its sandbox
/// always reads — and (b) both binaries share a Team-prefixed keychain access
/// group, so the widget reads credentials from the login Keychain without a
/// prompt. Snapshots fetched here are written where both the widget renders
/// and the app reads (the app's SnapshotStore treats this container as a
/// mirror with newest-wins semantics).
///
/// A small persisted retry map honors provider rate limits across timeline
/// reloads so self-healing never hammers a 429'd endpoint.
@MainActor
public enum WidgetRefresher {

    /// The shared access group both binaries carry in their entitlements.
    public static let sharedKeychainGroup = "Y3DAXDSX2F.com.juanlatorre.agent-usage"

    /// Refresh connected slots whose stored snapshots are older than `maxAge`.
    /// Returns the slot IDs that produced a fresh snapshot. Failures are
    /// recorded in the retry map (rate-limited slots wait out their window).
    ///
    /// WidgetKit kills extensions that exceed a few seconds of work, so all
    /// due slots fetch CONCURRENTLY through a short-timeout session and the
    /// retry map is persisted before returning.
    public static func refreshStaleSlots(olderThan maxAge: TimeInterval) async -> [AccountSlotID] {
        guard let base = SharedStoreLocations.widgetContainerDirectory() else { return [] }
        let keychain = KeychainStore(serviceNamePrefix: "com.juanlatorre.agent-usage",
                                      sharedAccessGroup: sharedKeychainGroup)
        let store = SnapshotStore(baseURL: base.appendingPathComponent("snapshots", isDirectory: true))
        var retryMap = loadRetryMap(base: base)
        let now = Date()

        // Short timeouts: the extension's execution budget is seconds, not the
        // providers' default 30s-per-request.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)

        let claude = ClaudeConnectionManager(
            controller: ClaudeAccountController(
                keychain: keychain,
                connectionsFileURL: base.appendingPathComponent("claude-connections.json")),
            provider: ClaudeUsageProvider(session: session))
        let codex = CodexConnectionManager(
            controller: CodexAccountController(
                keychain: keychain,
                connectionsFileURL: base.appendingPathComponent("codex-connections.json")),
            provider: CodexUsageProvider(session: session))
        let openCode = OpenCodeConnectionManager(
            controller: OpenCodeAccountController(
                keychain: keychain,
                connectionsFileURL: base.appendingPathComponent("opencode-connections.json")),
            provider: OpenCodeUsageProvider(session: session))
        let commandCode = CommandCodeConnectionManager(
            controller: CommandCodeAccountController(
                keychain: keychain,
                connectionsFileURL: base.appendingPathComponent("commandcode-connections.json")),
            provider: CommandCodeUsageProvider(session: session))
        let zai = ZaiConnectionManager(
            controller: ZaiAccountController(
                keychain: keychain,
                connectionsFileURL: base.appendingPathComponent("zai-connections.json")),
            provider: ZaiUsageProvider(session: session))

        struct Due {
            let slotID: AccountSlotID
            let fetch: @MainActor () async -> Result<UsageSnapshot, WidgetFetchFailure>
        }
        var due: [Due] = []
        func appendDue(_ slotID: AccountSlotID, connected: Bool, fetch: @escaping @MainActor () async -> Result<UsageSnapshot, WidgetFetchFailure>) {
            guard connected else { return }
            if let retryAt = retryMap[slotID.rawValue], retryAt > now { return }
            if case .loaded(let snap) = store.load(slotID: slotID, now: now),
               now.timeIntervalSince(snap.capturedAt) < maxAge {
                return
            }
            due.append(Due(slotID: slotID, fetch: fetch))
        }
        appendDue(.claude, connected: claude.isConnected(.claude)) { await claude.refresh(slotID: .claude).snapshotResult }
        appendDue(.chatGPT, connected: codex.isConnected(.chatGPT)) { await codex.refresh(slotID: .chatGPT).snapshotResult }
        appendDue(.openCodeGO, connected: openCode.isConnected(.openCodeGO)) { await openCode.refresh(slotID: .openCodeGO).snapshotResult }
        appendDue(.commandCodeGOAT, connected: commandCode.isConnected(.commandCodeGOAT)) { await commandCode.refresh(slotID: .commandCodeGOAT).snapshotResult }
        appendDue(.zaiCodingPlan, connected: zai.isConnected(.zaiCodingPlan)) { await zai.refresh(slotID: .zaiCodingPlan).snapshotResult }

        guard !due.isEmpty else {
            saveRetryMap(retryMap, base: base)
            return []
        }
        NSLog("[AgentUsageWidget] self-heal: fetching %d stale slots", due.count)

        // Concurrent: the extension's execution budget is seconds — five
        // sequential fetches with 30s timeouts got the process killed mid-run
        // (observed live: partial writes, no retry map).
        var outcomes: [AccountSlotID: Result<UsageSnapshot, WidgetFetchFailure>] = [:]
        await withTaskGroup(of: (AccountSlotID, Result<UsageSnapshot, WidgetFetchFailure>).self) { group in
            for item in due {
                group.addTask {
                    await (item.slotID, item.fetch())
                }
            }
            for await (slotID, result) in group {
                outcomes[slotID] = result
            }
        }

        var refreshed: [AccountSlotID] = []
        for (slotID, result) in outcomes {
            switch result {
            case .success(let snapshot):
                try? store.save(snapshot)
                refreshed.append(slotID)
                retryMap.removeValue(forKey: slotID.rawValue)
            case .failure(let failure):
                // Back off modestly; precise server Retry-After is honored by
                // the app's scheduler — this map only protects the widget's
                // ~5-minute timeline cadence.
                NSLog("[AgentUsageWidget] self-heal %@ failed: %@", slotID.rawValue, failure.message)
                retryMap[slotID.rawValue] = now.addingTimeInterval(10 * 60)
            }
        }
        saveRetryMap(retryMap, base: base)
        NSLog("[AgentUsageWidget] self-heal done: %d refreshed", refreshed.count)
        return refreshed
    }

    // MARK: - Retry map persistence

    private static func retryMapURL(_ base: URL) -> URL {
        base.appendingPathComponent("widget-refresh-state.json")
    }

    private static func loadRetryMap(base: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: retryMapURL(base)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    private static func saveRetryMap(_ map: [String: Date], base: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(map) {
            try? data.write(to: retryMapURL(base), options: .atomic)
        }
    }
}

/// Simple failure marker for the widget's in-process fetch results.
public struct WidgetFetchFailure: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Maps per-provider refresh outcomes to (snapshot | failure).
extension ClaudeRefreshOutcome {
    var snapshotResult: Result<UsageSnapshot, WidgetFetchFailure> {
        switch self {
        case .updated(let s): return .success(s)
        case .rateLimited: return .failure(WidgetFetchFailure("rate limited"))
        default: return .failure(WidgetFetchFailure("refresh failed"))
        }
    }
}
extension CodexRefreshOutcome {
    var snapshotResult: Result<UsageSnapshot, WidgetFetchFailure> {
        switch self {
        case .updated(let s): return .success(s)
        case .rateLimited: return .failure(WidgetFetchFailure("rate limited"))
        default: return .failure(WidgetFetchFailure("refresh failed"))
        }
    }
}
extension OpenCodeRefreshOutcome {
    var snapshotResult: Result<UsageSnapshot, WidgetFetchFailure> {
        switch self {
        case .updated(let s): return .success(s)
        case .rateLimited: return .failure(WidgetFetchFailure("rate limited"))
        default: return .failure(WidgetFetchFailure("refresh failed"))
        }
    }
}
extension CommandCodeRefreshOutcome {
    var snapshotResult: Result<UsageSnapshot, WidgetFetchFailure> {
        switch self {
        case .updated(let s): return .success(s)
        case .rateLimited: return .failure(WidgetFetchFailure("rate limited"))
        default: return .failure(WidgetFetchFailure("refresh failed"))
        }
    }
}
extension ZaiRefreshOutcome {
    var snapshotResult: Result<UsageSnapshot, WidgetFetchFailure> {
        switch self {
        case .updated(let s): return .success(s)
        case .rateLimited: return .failure(WidgetFetchFailure("rate limited"))
        default: return .failure(WidgetFetchFailure("refresh failed"))
        }
    }
}
