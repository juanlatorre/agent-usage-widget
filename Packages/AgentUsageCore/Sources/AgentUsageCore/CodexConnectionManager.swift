import Foundation

/// Errors surfaced by Codex connection management in the app layer.
public enum CodexConnectionManagerError: Error, Equatable, Sendable {
    /// The manager was used before stores were attached.
    case notConfigured
}

/// Refresh outcomes for the GPT Personal slot. None of them fabricate usage;
/// the owning model keeps any prior snapshot as historical context itself.
public enum CodexRefreshOutcome: Equatable, Sendable {
    /// A successful fetch. The snapshot may still derive UNAVAILABLE when the
    /// required weekly window was missing from the payload (R2/R4) — that is honest.
    case updated(UsageSnapshot)
    /// Credentials are missing or were rejected (R4 → AUTHENTICATION_REQUIRED).
    case authenticationRequired
    /// The bound directory now holds a different identity; reconnection required.
    case sourceIdentityChanged
    /// Transient failure (transport, 429, 5xx); status stays ERROR/UNAVAILABLE.
    case failed
}

/// App-layer orchestration for the GPT Personal slot: connection lifecycle plus
/// refresh, with identity synchronization on every refresh.
///
/// Threading: mutating calls are expected on the main actor (UI-driven);
/// networking runs through the injected async transport.
@MainActor
public final class CodexConnectionManager {

    private let controller: CodexAccountController
    private let provider: CodexUsageProvider
    private let now: () -> Date

    /// - Parameters:
    ///   - controller: connection lifecycle over Keychain + connections file.
    ///   - provider: usage transport (injectable session for tests).
    ///   - now: injected clock.
    public init(controller: CodexAccountController,
                provider: CodexUsageProvider = CodexUsageProvider(),
                now: @escaping () -> Date = Date.init) {
        self.controller = controller
        self.provider = provider
        self.now = now
    }

    // MARK: - Connection surface

    /// Whether the slot has a persisted connection record.
    public func isConnected(_ slotID: AccountSlotID) -> Bool {
        controller.isConnected(slotID)
    }

    /// Non-secret metadata about the slot's bound source, for display.
    public func connection(_ slotID: AccountSlotID) -> CodexConnection? {
        controller.loadConnections()[slotID]
    }

    /// Connect the slot to a profile directory (explicit consent; imports material).
    public func connect(slotID: AccountSlotID, directory: URL) throws {
        _ = try controller.connect(slotID: slotID, directory: directory, now: now())
    }

    /// Disconnect: removes only this slot's app-owned material (R7).
    public func disconnect(slotID: AccountSlotID) {
        controller.disconnect(slotID: slotID)
    }

    /// Whether the bound source's current identity differs from the imported one.
    ///
    /// Unreadable sources are not treated as identity changes; transport-level
    /// failures surface during refresh instead.
    public func isIdentityStale(_ slotID: AccountSlotID) -> Bool {
        guard let connection = controller.loadConnections()[slotID] else { return false }
        guard let current = try? connection.source.readCredentials() else { return false }
        let currentIdentity = CodexIdentityMetadata(
            accountID: current.accountID,
            fingerprint: CodexProfileSource.fingerprint(current.accessToken))
        return !connection.importedIdentity.matches(currentIdentity)
    }

    // MARK: - Refresh

    /// Refresh the slot: synchronize identity, fetch usage, normalize the weekly
    /// window.
    ///
    /// Identity sync runs first: a changed source stops the refresh before any
    /// network call (R7/AC4) and never overwrites the stored credential.
    public func refresh(slotID: AccountSlotID) async -> CodexRefreshOutcome {
        do {
            _ = try controller.synchronize(slotID: slotID, now: now())
        } catch CodexConnectionError.sourceIdentityChanged {
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
                provider: .gpt,
                windows: result.windows,
                capturedAt: now(),
                provenance: SourceDiagnostics(
                    sourceKind: "codex-oauth-usage",
                    sourceReliability: "undocumented-endpoint",
                    notes: []))
            return .updated(snapshot)
        } catch CodexUsageError.missingCredential, CodexUsageError.unauthorized {
            return .authenticationRequired
        } catch {
            return .failed
        }
    }
}
