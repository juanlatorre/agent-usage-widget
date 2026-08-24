import Foundation

public enum ZaiConnectionManagerError: Error, Equatable, Sendable { case notConfigured }

public enum ZaiRefreshOutcome: Equatable, Sendable {
    case updated(UsageSnapshot)
    case authenticationRequired
    case sourceIdentityChanged
    case failed
}

@MainActor
public final class ZaiConnectionManager {

    private let controller: ZaiAccountController
    private let provider: ZaiUsageProvider
    private let now: () -> Date

    public init(controller: ZaiAccountController,
                provider: ZaiUsageProvider = ZaiUsageProvider(),
                now: @escaping () -> Date = Date.init) {
        self.controller = controller; self.provider = provider; self.now = now
    }

    public func isConnected(_ slotID: AccountSlotID) -> Bool { controller.isConnected(slotID) }
    public func connection(_ slotID: AccountSlotID) -> ZaiConnection? { controller.loadConnections()[slotID] }
    public func connect(slotID: AccountSlotID, file: URL) throws { _ = try controller.connect(slotID: slotID, file: file, now: now()) }
    public func connectManually(slotID: AccountSlotID, apiKey: String) throws { _ = try controller.connectManually(slotID: slotID, apiKey: apiKey, now: now()) }
    public func disconnect(slotID: AccountSlotID) { controller.disconnect(slotID: slotID) }

    public func isIdentityStale(_ slotID: AccountSlotID) -> Bool {
        guard let c = controller.loadConnections()[slotID] else { return false }
        if c.source.bookmark.isEmpty { return false }
        guard let current = try? c.source.readCredentials() else { return false }
        return !c.importedIdentity.matches(ZaiIdentityMetadata(fingerprint: ZaiProfileSource.fingerprint(current.apiKey)))
    }

    public func refresh(slotID: AccountSlotID) async -> ZaiRefreshOutcome {
        do { _ = try controller.synchronize(slotID: slotID, now: now()) } catch ZaiConnectionError.sourceIdentityChanged {
            return .sourceIdentityChanged
        } catch { return .failed }
        guard let credentials = controller.credential(for: slotID) else { return .authenticationRequired }
        do {
            let result = try await provider.fetchUsage(credentials: credentials)
            let snapshot = UsageSnapshot(slotID: slotID, provider: .zai, windows: result.windows, capturedAt: now(),
                                         provenance: SourceDiagnostics(sourceKind: "zai-quota", sourceReliability: "official-endpoint", notes: []))
            return .updated(snapshot)
        } catch ZaiUsageError.missingCredential, ZaiUsageError.unauthorized {
            return .authenticationRequired
        } catch { return .failed }
    }
}
