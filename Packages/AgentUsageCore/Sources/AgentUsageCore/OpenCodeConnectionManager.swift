import Foundation

public enum OpenCodeConnectionManagerError: Error, Equatable, Sendable {
    case notConfigured
}

public enum OpenCodeRefreshOutcome: Equatable, Sendable {
    case updated(UsageSnapshot)
    case authenticationRequired
    case sourceIdentityChanged
    case failed
}

/// App-layer orchestration for the OpenCode GO slot: connection lifecycle plus
/// refresh, with identity synchronization on every refresh.
@MainActor
public final class OpenCodeConnectionManager {

    private let controller: OpenCodeAccountController
    private let provider: OpenCodeUsageProvider
    private let now: () -> Date

    public init(controller: OpenCodeAccountController,
                provider: OpenCodeUsageProvider = OpenCodeUsageProvider(),
                now: @escaping () -> Date = Date.init) {
        self.controller = controller
        self.provider = provider
        self.now = now
    }

    // MARK: - Connection surface

    public func isConnected(_ slotID: AccountSlotID) -> Bool {
        controller.isConnected(slotID)
    }

    public func connection(_ slotID: AccountSlotID) -> OpenCodeConnection? {
        controller.loadConnections()[slotID]
    }

    public func connect(slotID: AccountSlotID, file: URL) throws {
        _ = try controller.connect(slotID: slotID, file: file, now: now())
    }

    public func connectManually(slotID: AccountSlotID, apiKey: String) throws {
        _ = try controller.connectManually(slotID: slotID, apiKey: apiKey, now: now())
    }

    public func disconnect(slotID: AccountSlotID) {
        controller.disconnect(slotID: slotID)
    }

    public func isIdentityStale(_ slotID: AccountSlotID) -> Bool {
        guard let connection = controller.loadConnections()[slotID] else { return false }
        // Manual entries have no file to compare; never stale.
        if connection.source.bookmark.isEmpty { return false }
        guard let current = try? connection.source.readCredentials() else { return false }
        let currentIdentity = OpenCodeIdentityMetadata(
            fingerprint: OpenCodeProfileSource.fingerprint(current.apiKey))
        return !connection.importedIdentity.matches(currentIdentity)
    }

    // MARK: - Refresh

    public func refresh(slotID: AccountSlotID) async -> OpenCodeRefreshOutcome {
        do {
            _ = try controller.synchronize(slotID: slotID, now: now())
        } catch OpenCodeConnectionError.sourceIdentityChanged {
            return .sourceIdentityChanged
        } catch {
            return .failed
        }

        guard let credentials = controller.credential(for: slotID) else {
            return .authenticationRequired
        }

        do {
            let result = try await provider.fetchUsage(credentials: credentials)
            let snapshot = UsageSnapshot(
                slotID: slotID,
                provider: .opencode,
                windows: result.windows,
                capturedAt: now(),
                provenance: SourceDiagnostics(
                    sourceKind: "opencode-go-usage",
                    sourceReliability: "official-endpoint",
                    notes: []))
            return .updated(snapshot)
        } catch OpenCodeUsageError.missingCredential, OpenCodeUsageError.unauthorized {
            return .authenticationRequired
        } catch {
            return .failed
        }
    }
}
