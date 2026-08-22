import Foundation

/// Errors surfaced by connection lifecycle operations.
public enum ConnectionControllerError: Error, Equatable, Sendable {
    /// The selected directory could not be captured as a profile source.
    case selectionFailed(String)
    /// The source has no usable credential material to import.
    case noUsableCredentials
    /// The source directory changed identity since it was bound.
    case sourceIdentityChanged
}

/// Non-secret persisted state for one Claude slot connection.
public struct ClaudeConnection: Codable, Sendable, Equatable {
    /// The bound profile directory (bookmark + non-secret identity). No secrets.
    public var source: ClaudeProfileSource
    /// Last known sanitized identity of the imported credential.
    public var importedIdentity: ClaudeIdentityMetadata
    /// When the credential was last imported into the Keychain.
    public var importedAt: Date

    public init(source: ClaudeProfileSource,
                importedIdentity: ClaudeIdentityMetadata,
                importedAt: Date) {
        self.source = source
        self.importedIdentity = importedIdentity
        self.importedAt = importedAt
    }
}

/// Owns the Claude connection lifecycle: select → inspect → connect → sync → disconnect.
///
/// Contract (child spec R1/R3/R8, parent R13, ADR-0004):
/// - only the user-selected directory is ever read;
/// - import requires an explicit connect call — metadata inspection alone never
///   writes credentials;
/// - the legacy profile and the team use distinct Keychain accounts, bookmarks, and
///   connection records, so neither slot can read or overwrite the other;
/// - an identity mismatch on a later sync stops synchronization without touching
///   the stored Keychain secret;
/// - disconnect deletes only that slot's app-owned material.
public struct ClaudeAccountController: Sendable {

    /// The two Claude slots this controller manages.
    public static let managedSlots: [AccountSlotID] = [.claudeLegacyA, .claudethe team]

    private let keychain: any CredentialStoring
    private let fileURL: URL

    /// - Parameters:
    ///   - keychain: slot-scoped credential store (production: `KeychainStore`).
    ///   - fileURL: non-secret connections JSON file (App Group container or
    ///     Application Support fallback).
    /// - Note: file operations use `FileManager.default`, which is thread-safe;
    ///   it is not stored so the controller remains trivially Sendable.
    public init(keychain: any CredentialStoring, connectionsFileURL fileURL: URL) {
        self.keychain = keychain
        self.fileURL = fileURL
    }

    /// Default non-secret location, with Application Support fallback for
    /// development builds without the App Group entitlement.
    public static func defaultFileURL(appGroupID: String) -> URL? {
        let fileManager = FileManager.default
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("claude-connections.json")
        }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("claude-connections.json")
    }

    // MARK: - Persistence

    /// Load persisted connections; a corrupt record is ignored, not trusted.
    public func loadConnections() -> [AccountSlotID: ClaudeConnection] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let connections = try? JSONDecoder().decode(
                [String: ClaudeConnection].self, from: data) else {
            return [:]
        }
        var result: [AccountSlotID: ClaudeConnection] = [:]
        for (raw, connection) in connections {
            if let slot = AccountSlotID(rawValue: raw) {
                result[slot] = connection
            }
        }
        return result
    }

    /// Persist connections atomically; secrets never enter this file (parent R12).
    public func saveConnections(_ connections: [AccountSlotID: ClaudeConnection]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var encoded: [String: ClaudeConnection] = [:]
        for (slot, connection) in connections {
            encoded[slot.rawValue] = connection
        }
        let data = try JSONEncoder().encode(encoded)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Inspection (pre-consent)

    /// Inspect a candidate directory's non-secret identity metadata.
    ///
    /// Reads sanitized identity only; no credential material is stored anywhere.
    public static func inspectIdentity(of directory: URL) throws -> ClaudeIdentityMetadata {
        let source: ClaudeProfileSource
        do {
            source = try ClaudeProfileSource.selecting(directory: directory)
        } catch {
            throw ConnectionControllerError.selectionFailed(String(describing: error))
        }
        guard let metadata = source.readIdentityMetadata() else {
            throw ConnectionControllerError.noUsableCredentials
        }
        return metadata
    }

    // MARK: - Connection lifecycle

    /// Connect a slot to a profile directory with explicit user consent.
    ///
    /// Imports the current credential material into the slot's own Keychain entry
    /// and persists the binding. Binding one directory to both slots is rejected:
    /// distinct identities per slot are contractual (child spec §6).
    @discardableResult
    public func connect(
        slotID: AccountSlotID,
        directory: URL,
        now: Date = Date()
    ) throws -> ClaudeConnection {
        let source: ClaudeProfileSource
        do {
            source = try ClaudeProfileSource.selecting(directory: directory)
        } catch {
            throw ConnectionControllerError.selectionFailed(String(describing: error))
        }

        // Full credential read happens in memory only; nothing is stored yet.
        let credentials: ClaudeOAuthCredentials
        do {
            credentials = try source.readCredentials()
        } catch {
            throw ConnectionControllerError.noUsableCredentials
        }

        // Reject binding the same directory to a second slot.
        let existing = loadConnections()
        for (otherSlot, connection) in existing where otherSlot != slotID {
            if connection.source.directoryIdentity == source.directoryIdentity {
                throw ConnectionControllerError.selectionFailed("directory already bound to another slot")
            }
        }

        // Every validation passed: import into this slot's Keychain entry only.
        try keychain.saveCredentials(credentials, account: slotID)

        let connection = ClaudeConnection(
            source: source,
            importedIdentity: ClaudeIdentityMetadata(
                accountUUID: credentials.accountUUID,
                fingerprint: ClaudeProfileSource.fingerprint(credentials.accessToken)),
            importedAt: now)
        var updated = existing
        updated[slotID] = connection
        try saveConnections(updated)
        return connection
    }

    /// Synchronize the slot's Keychain credential with its source directory.
    ///
    /// Returns the refreshed connection when the source still holds the bound
    /// identity. Throws `sourceIdentityChanged` when the directory now holds a
    /// different identity; the stored Keychain secret is left untouched (R3/AC4).
    /// Source-resolution failures propagate as `ClaudeProfileError`.
    @discardableResult
    public func synchronize(slotID: AccountSlotID, now: Date = Date()) throws -> ClaudeConnection {
        guard let connection = loadConnections()[slotID] else {
            throw ConnectionControllerError.noUsableCredentials
        }

        let current: ClaudeOAuthCredentials
        do {
            current = try connection.source.readCredentials()
        } catch ClaudeProfileError.credentialsMalformed {
            throw ConnectionControllerError.noUsableCredentials
        }

        let currentIdentity = ClaudeIdentityMetadata(
            accountUUID: current.accountUUID,
            fingerprint: ClaudeProfileSource.fingerprint(current.accessToken))
        guard connection.importedIdentity.matches(currentIdentity) else {
            throw ConnectionControllerError.sourceIdentityChanged
        }

        // Same identity: refresh the stored material (e.g. rotated token).
        try keychain.saveCredentials(current, account: slotID)

        var updated = loadConnections()
        var refreshed = connection
        refreshed.importedIdentity = currentIdentity
        refreshed.importedAt = now
        updated[slotID] = refreshed
        try saveConnections(updated)
        return refreshed
    }

    /// The stored credential for a slot, or nil when not connected.
    public func credential(for slotID: AccountSlotID) -> ClaudeOAuthCredentials? {
        keychain.credentials(account: slotID)
    }

    /// Whether a slot currently has a persisted connection record.
    public func isConnected(_ slotID: AccountSlotID) -> Bool {
        loadConnections()[slotID] != nil
    }

    /// Disconnect: delete only this slot's Keychain entry, bookmark record, and
    /// snapshot ownership; the external profile directory is never modified (R8).
    public func disconnect(slotID: AccountSlotID) {
        keychain.deleteCredentials(account: slotID)
        var connections = loadConnections()
        connections[slotID] = nil
        try? saveConnections(connections)
    }
}
