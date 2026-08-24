import Foundation

public enum CommandCodeConnectionManagerError: Error, Equatable, Sendable {
    case notConfigured
}

public enum CommandCodeRefreshOutcome: Equatable, Sendable {
    /// Successful credits; may carry a metadata warning (R5/AC2).
    case updated(UsageSnapshot)
    case authenticationRequired
    case sourceIdentityChanged
    case unavailable(reason: String)
    case failed
}

@MainActor
public final class CommandCodeConnectionManager {

    private let controller: CommandCodeAccountController
    private let provider: CommandCodeUsageProvider
    private let now: () -> Date

    public init(controller: CommandCodeAccountController,
                provider: CommandCodeUsageProvider = CommandCodeUsageProvider(),
                now: @escaping () -> Date = Date.init) {
        self.controller = controller; self.provider = provider; self.now = now
    }

    public func isConnected(_ slotID: AccountSlotID) -> Bool { controller.isConnected(slotID) }
    public func connection(_ slotID: AccountSlotID) -> CommandCodeConnection? {
        controller.loadConnections()[slotID]
    }
    public func connect(slotID: AccountSlotID, file: URL) throws {
        _ = try controller.connect(slotID: slotID, file: file, now: now())
    }
    public func connectManually(slotID: AccountSlotID, apiKey: String) throws {
        _ = try controller.connectManually(slotID: slotID, apiKey: apiKey, now: now())
    }
    public func disconnect(slotID: AccountSlotID) { controller.disconnect(slotID: slotID) }

    public func isIdentityStale(_ slotID: AccountSlotID) -> Bool {
        guard let c = controller.loadConnections()[slotID] else { return false }
        if c.source.bookmark.isEmpty { return false }
        guard let current = try? c.source.readCredentials() else { return false }
        return !c.importedIdentity.matches(
            CommandCodeIdentityMetadata(fingerprint: CommandCodeProfileSource.fingerprint(current.apiKey)))
    }

    public func refresh(slotID: AccountSlotID) async -> CommandCodeRefreshOutcome {
        do { _ = try controller.synchronize(slotID: slotID, now: now()) } catch CommandCodeConnectionError.sourceIdentityChanged {
            return .sourceIdentityChanged
        } catch { return .failed }

        guard let credentials = controller.credential(for: slotID) else {
            return .authenticationRequired
        }

        do {
            let result = try await provider.fetchUsage(credentials: credentials)
            // Inactive subscription → unavailable even though credits may look present (R4).
            if let warning = result.metadataWarning, warning.contains("subscription status:") {
                // R4: inactive subscription — AUTH or UNAVAILABLE, never available.
                // Map to AUTH so StatusModel keeps history and derives AUTH.
                return .authenticationRequired
            }
            var notes: [String] = []
            if let warning = result.metadataWarning { notes.append(warning) }
            if let label = result.planLabel { notes.append("plan: \(label)") }
            let snapshot = UsageSnapshot(
                slotID: slotID, provider: .commandCode, windows: result.windows,
                capturedAt: now(),
                provenance: SourceDiagnostics(sourceKind: "commandcode-credits",
                                              sourceReliability: "official-endpoint",
                                              notes: notes))
            return .updated(snapshot)
        } catch CommandCodeUsageError.missingCredential, CommandCodeUsageError.unauthorized {
            return .authenticationRequired
        } catch {
            return .failed
        }
    }
}
