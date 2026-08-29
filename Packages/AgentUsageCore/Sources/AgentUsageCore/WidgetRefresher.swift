import Foundation

/// In-widget usage refresh: fetches provider data directly from the widget
/// extension process, without launching the app.
///
/// Inputs (all inside the widget extension's own container — the one place
/// its sandbox always reads):
/// - connection records, mirrored by the app;
/// - `credentials.json`, a 0600 mirror of the current credentials (the
///   sandboxed extension cannot read the login Keychain — attempting it
///   surfaced the login-password prompt every few minutes — so the app
///   mirrors tokens to this file instead).
///
/// Outputs: refreshed snapshots, plus a persisted retry map honoring provider
/// rate limits across timeline reloads.
@MainActor
public enum WidgetRefresher {

    public static let sharedKeychainGroup = "Y3DAXDSX2F.com.juanlatorre.agent-usage"

    /// Refresh connected slots whose stored snapshots are older than `maxAge`.
    /// Concurrent by design: WidgetKit kills extensions exceeding a few
    /// seconds of work (sequential 30s fetches got the process killed
    /// mid-run). Returns the slot IDs that produced a fresh snapshot.
    public static func refreshStaleSlots(olderThan maxAge: TimeInterval) async -> [AccountSlotID] {
        guard let base = SharedStoreLocations.widgetContainerDirectory() else { return [] }
        let store = SnapshotStore(baseURL: base.appendingPathComponent("snapshots", isDirectory: true))
        var retryMap = loadRetryMap(base: base)
        let now = Date()

        guard let mirrored = try? CredentialMirror.load(container: base) else {
            NSLog("[AgentUsageWidget] self-heal: no credential mirror yet")
            return []
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)

        struct Due: Sendable {
            let slotID: AccountSlotID
            let fetch: @Sendable () async -> Result<UsageSnapshot, WidgetFetchFailure>
        }
        var due: [Due] = []
        func appendDue(_ slotID: AccountSlotID, credential: MirroredCredential?, fetch: @escaping @Sendable () async -> Result<UsageSnapshot, WidgetFetchFailure>) {
            guard let credential else { return }
            if let retryAt = retryMap[slotID.rawValue], retryAt > now { return }
            if case .loaded(let snap) = store.load(slotID: slotID, now: now),
               now.timeIntervalSince(snap.capturedAt) < maxAge {
                return
            }
            due.append(Due(slotID: slotID, fetch: fetch))
        }

        if let c = mirrored[.claude]?.claudeOAuthJSON,
           let oauth = try? JSONDecoder().decode(ClaudeOAuthCredentials.self, from: c) {
            appendDue(.claude, credential: MirroredCredential(claudeOAuthJSON: c)) {
                do {
                    let result = try await ClaudeUsageProvider(session: session).fetchUsage(credentials: oauth)
                    return .success(UsageSnapshot(slotID: .claude, provider: .claude, windows: result.windows, capturedAt: Date()))
                } catch { return .failure(WidgetFetchFailure(String(describing: error))) }
            }
        }
        if let c = mirrored[.chatGPT]?.codexOAuthJSON,
           let oauth = try? JSONDecoder().decode(CodexOAuthCredentials.self, from: c) {
            appendDue(.chatGPT, credential: MirroredCredential(codexOAuthJSON: c)) {
                do {
                    let result = try await CodexUsageProvider(session: session).fetchUsage(credentials: oauth)
                    return .success(UsageSnapshot(slotID: .chatGPT, provider: .gpt, windows: result.windows, capturedAt: Date()))
                } catch { return .failure(WidgetFetchFailure(String(describing: error))) }
            }
        }
        if let key = mirrored[.openCodeGO]?.apiKey {
            appendDue(.openCodeGO, credential: MirroredCredential(apiKey: key)) {
                do {
                    let result = try await OpenCodeUsageProvider(session: session).fetchUsage(credentials: OpenCodeCredentials(apiKey: key))
                    return .success(UsageSnapshot(slotID: .openCodeGO, provider: .opencode, windows: result.windows, capturedAt: Date()))
                } catch { return .failure(WidgetFetchFailure(String(describing: error))) }
            }
        }
        if let key = mirrored[.commandCodeGOAT]?.apiKey {
            appendDue(.commandCodeGOAT, credential: MirroredCredential(apiKey: key)) {
                do {
                    let result = try await CommandCodeUsageProvider(session: session).fetchUsage(credentials: CommandCodeCredentials(apiKey: key))
                    return .success(UsageSnapshot(slotID: .commandCodeGOAT, provider: .commandCode, windows: result.windows, capturedAt: Date()))
                } catch { return .failure(WidgetFetchFailure(String(describing: error))) }
            }
        }
        if let key = mirrored[.zaiCodingPlan]?.apiKey {
            appendDue(.zaiCodingPlan, credential: MirroredCredential(apiKey: key)) {
                do {
                    let result = try await ZaiUsageProvider(session: session).fetchUsage(credentials: ZaiCredentials(apiKey: key))
                    return .success(UsageSnapshot(slotID: .zaiCodingPlan, provider: .zai, windows: result.windows, capturedAt: Date()))
                } catch { return .failure(WidgetFetchFailure(String(describing: error))) }
            }
        }

        guard !due.isEmpty else {
            saveRetryMap(retryMap, base: base)
            return []
        }
        NSLog("[AgentUsageWidget] self-heal: fetching %d stale slots", due.count)

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
