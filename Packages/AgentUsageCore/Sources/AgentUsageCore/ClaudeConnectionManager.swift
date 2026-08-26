import Foundation

/// Errors surfaced by Claude connection management in the app layer.
public enum ClaudeConnectionError: Error, Equatable, Sendable {
    /// The manager was used before stores were attached.
    case notConfigured
}

/// Refresh outcomes for one Claude slot. None of them fabricate usage; the
/// owning model keeps any prior snapshot as historical context itself.
public enum ClaudeRefreshOutcome: Equatable, Sendable {
    /// A successful fetch. The snapshot may still derive UNAVAILABLE when a
    /// required window was missing from the payload (R6) — that is honest.
    case updated(UsageSnapshot)
    /// Credentials are missing or were rejected (R7 → AUTHENTICATION_REQUIRED).
    case authenticationRequired
    /// The bound directory now holds a different identity; reconnection required.
    case sourceIdentityChanged
    /// Transient failure (transport, 429, 5xx); status stays ERROR/UNAVAILABLE.
    /// Rate limited by the provider; the server-directed Retry-After must
    /// reach the scheduler verbatim instead of degrading to blind backoff.
    case rateLimited(retryAfter: TimeInterval?)

    case failed
}

/// App-layer orchestration for the two Claude slots: connection lifecycle plus
/// per-slot refresh, with identity synchronization on every refresh.
///
/// Threading: mutating calls are expected on the main actor (UI-driven);
/// networking runs through the injected async transport.
@MainActor
public final class ClaudeConnectionManager {

    private let controller: ClaudeAccountController
    private let provider: ClaudeUsageProvider
    private let now: () -> Date

    /// - Parameters:
    ///   - controller: connection lifecycle over Keychain + connections file.
    ///   - provider: usage transport (injectable session for tests).
    ///   - now: injected clock.
    public init(controller: ClaudeAccountController,
                provider: ClaudeUsageProvider = ClaudeUsageProvider(),
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

    /// Non-secret metadata about a slot's bound source, for display.
    public func connection(_ slotID: AccountSlotID) -> ClaudeConnection? {
        controller.loadConnections()[slotID]
    }

    /// Connect a slot to a profile directory (explicit consent; imports material).
    public func connect(slotID: AccountSlotID, directory: URL) throws {
        _ = try controller.connect(slotID: slotID, directory: directory, now: now())
    }

    public func importDirect(slotID: AccountSlotID, credentials: ClaudeOAuthCredentials, directoryHint: URL?) throws {
        _ = try controller.importDirect(slotID: slotID, credentials: credentials, directoryHint: directoryHint, now: now())
    }

    /// Disconnect: removes only this slot's app-owned material (R8).
    public func disconnect(slotID: AccountSlotID) {
        controller.disconnect(slotID: slotID)
    }

    /// Whether the bound source's current identity differs from the imported one.
    ///
    /// Unreadable sources are not treated as identity changes; transport-level
    /// failures surface during refresh instead.
    public func isIdentityStale(_ slotID: AccountSlotID) -> Bool {
        guard let connection = controller.loadConnections()[slotID] else { return false }
        if connection.source.bookmark.isEmpty { return false }
        guard let current = try? connection.source.readCredentials() else { return false }
        let currentIdentity = ClaudeIdentityMetadata(
            accountUUID: current.accountUUID,
            fingerprint: ClaudeProfileSource.fingerprint(current.accessToken))
        return !connection.importedIdentity.matches(currentIdentity)
    }

    // MARK: - Refresh

    /// Refresh one slot: synchronize identity, fetch usage, normalize windows.
    ///
    /// Identity sync runs first: a changed source stops the refresh before any
    /// network call (R3/AC4) and never overwrites the stored credential.
    public func refresh(slotID: AccountSlotID) async -> ClaudeRefreshOutcome {
        do {
            _ = try controller.synchronize(slotID: slotID, now: now())
        } catch ConnectionControllerError.sourceIdentityChanged {
            return .sourceIdentityChanged
        } catch {
            return .failed
        }

        var credentials = controller.credential(for: slotID)
        if credentials == nil {
            return .authenticationRequired
        }

        do {
            let result = try await provider.fetchUsage(credentials: credentials!)
            return .updated(Self.snapshot(for: slotID, result: result, now: now()))
        } catch ClaudeUsageError.rateLimited(let retryAfter) {
            return .rateLimited(retryAfter: retryAfter)
        } catch ClaudeUsageError.unauthorized {
            // Expired access token on a synthetic Keychain connection: the
            // imported credential carries no refresh token, so re-import the
            // CLI's current token from the Claude Code Keychain entry and
            // retry the fetch once with it.
            let isSynthetic = connection(slotID)?.source.bookmark.isEmpty ?? false
            NSLog("[AgentUsageCore] claude 401 on slot %@ (synthetic=%d) — re-importing", slotID.rawValue, isSynthetic)
            guard isSynthetic,
                  let fresh = ClaudeKeychainImporter.load(),
                  fresh.accessToken != credentials?.accessToken else {
                NSLog("[AgentUsageCore] claude re-import unavailable — auth required")
                return .authenticationRequired
            }
            NSLog("[AgentUsageCore] claude re-imported fresh token, retrying fetch")
            controller.updateCredentials(fresh, for: slotID, now: now())
            do {
                let result = try await provider.fetchUsage(credentials: fresh)
                return .updated(Self.snapshot(for: slotID, result: result, now: now()))
            } catch ClaudeUsageError.rateLimited(let retryAfter) {
                return .rateLimited(retryAfter: retryAfter)
            } catch ClaudeUsageError.missingCredential, ClaudeUsageError.unauthorized {
                return .authenticationRequired
            } catch {
                return .failed
            }
        } catch ClaudeUsageError.missingCredential {
            return .authenticationRequired
        } catch {
            return .failed
        }
    }

    private static func snapshot(for slotID: AccountSlotID, result: ClaudeUsageResult, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            slotID: slotID,
            provider: .claude,
            windows: result.windows,
            capturedAt: now,
            provenance: SourceDiagnostics(
                sourceKind: "claude-oauth-usage",
                sourceReliability: "undocumented-endpoint",
                notes: []))
    }
}
