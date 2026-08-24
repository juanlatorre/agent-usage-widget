import Foundation

/// Secret storage abstraction for Codex credential material.
///
/// Mirrors `CredentialStoring`: production uses `KeychainStore`; tests inject
/// fakes. Entries stay isolated per slot and payloads are never logged.
public protocol CodexCredentialStoring: Sendable {
    /// Store credentials for one slot, replacing any previous value atomically.
    func saveCodexCredentials(_ credentials: CodexOAuthCredentials, account: AccountSlotID) throws
    /// Load the stored credentials for one slot, or nil when absent.
    func codexCredentials(account: AccountSlotID) -> CodexOAuthCredentials?
    /// Remove only this slot's entry. Deleting a missing item succeeds.
    func deleteCodexCredentials(account: AccountSlotID)
}

/// Keychain-backed implementation reusing `KeychainStore`'s per-slot service
/// naming (`<prefix>.<slot-id>`), which cannot collide with the Claude entries
/// of other slots. Payloads are opaque JSON data to the Keychain.
extension KeychainStore: CodexCredentialStoring {

    public func saveCodexCredentials(_ credentials: CodexOAuthCredentials, account: AccountSlotID) throws {
        try setJSON(credentials, account: account)
    }

    public func codexCredentials(account: AccountSlotID) -> CodexOAuthCredentials? {
        json(CodexOAuthCredentials.self, account: account)
    }

    public func deleteCodexCredentials(account: AccountSlotID) {
        deleteSecret(account: account)
    }
}

/// Errors surfaced by Codex connection lifecycle operations.
public enum CodexConnectionError: Error, Equatable, Sendable {
    /// The selected directory could not be captured as a profile source.
    case selectionFailed(String)
    /// The source has no usable credential material to import.
    case noUsableCredentials
    /// The source directory changed identity since it was bound.
    case sourceIdentityChanged
}

/// Non-secret persisted state for the GPT Personal slot connection.
public struct CodexConnection: Codable, Sendable, Equatable {
    /// The bound profile directory (bookmark + non-secret identity). No secrets.
    public var source: CodexProfileSource
    /// Last known sanitized identity of the imported credential.
    public var importedIdentity: CodexIdentityMetadata
    /// When the credential was last imported into the Keychain.
    public var importedAt: Date

    public init(source: CodexProfileSource,
                importedIdentity: CodexIdentityMetadata,
                importedAt: Date) {
        self.source = source
        self.importedIdentity = importedIdentity
        self.importedAt = importedAt
    }
}

/// Owns the GPT Personal connection lifecycle: select → inspect → connect → sync → disconnect.
///
/// Contract (child spec R1/R7, parent R12/R13, ADR-0004):
/// - only the user-selected directory is ever read;
/// - import requires an explicit connect call — metadata inspection alone never
///   writes credentials;
/// - an identity mismatch on a later sync stops synchronization without touching
///   the stored Keychain secret;
/// - disconnect deletes only the slot's app-owned material; the user is never
///   logged out of Codex.
public struct CodexAccountController: Sendable {

    /// The single Codex slot this controller manages.
    public static let managedSlots: [AccountSlotID] = [.gptPersonal]

    private let keychain: any CodexCredentialStoring
    private let fileURL: URL

    /// - Parameters:
    ///   - keychain: slot-scoped credential store (production: `KeychainStore`).
    ///   - fileURL: non-secret connections JSON file (App Group container or
    ///     Application Support fallback).
    public init(keychain: any CodexCredentialStoring, connectionsFileURL fileURL: URL) {
        self.keychain = keychain
        self.fileURL = fileURL
    }

    /// Default non-secret location, with Application Support fallback for
    /// development builds without the App Group entitlement.
    public static func defaultFileURL(appGroupID: String) -> URL? {
        let fileManager = FileManager.default
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("codex-connections.json")
        }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("codex-connections.json")
    }

    // MARK: - Persistence

    /// Load persisted connections; a corrupt record is ignored, not trusted.
    public func loadConnections() -> [AccountSlotID: CodexConnection] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let connections = try? JSONDecoder().decode(
                [String: CodexConnection].self, from: data) else {
            return [:]
        }
        var result: [AccountSlotID: CodexConnection] = [:]
        for (raw, connection) in connections {
            if let slot = AccountSlotID(rawValue: raw) {
                result[slot] = connection
            }
        }
        return result
    }

    /// Persist connections atomically; secrets never enter this file (parent R12).
    public func saveConnections(_ connections: [AccountSlotID: CodexConnection]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var encoded: [String: CodexConnection] = [:]
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
    public static func inspectIdentity(of directory: URL) throws -> CodexIdentityMetadata {
        let source: CodexProfileSource
        do {
            source = try CodexProfileSource.selecting(directory: directory)
        } catch {
            throw CodexConnectionError.selectionFailed(String(describing: error))
        }
        guard let metadata = source.readIdentityMetadata() else {
            throw CodexConnectionError.noUsableCredentials
        }
        return metadata
    }

    // MARK: - Connection lifecycle

    /// Connect the slot to a profile directory with explicit user consent.
    ///
    /// Imports the current credential material into the slot's own Keychain entry
    /// and persists the binding. Binding one directory to two slots is rejected:
    /// distinct identities per slot are contractual (child spec §6).
    @discardableResult
    public func connect(
        slotID: AccountSlotID,
        directory: URL,
        now: Date = Date()
    ) throws -> CodexConnection {
        let source: CodexProfileSource
        do {
            source = try CodexProfileSource.selecting(directory: directory)
        } catch {
            throw CodexConnectionError.selectionFailed(String(describing: error))
        }

        // Full credential read happens in memory only; nothing is stored yet.
        let credentials: CodexOAuthCredentials
        do {
            credentials = try source.readCredentials()
        } catch {
            throw CodexConnectionError.noUsableCredentials
        }

        // Reject binding the same directory to a second slot.
        let existing = loadConnections()
        for (otherSlot, connection) in existing where otherSlot != slotID {
            if connection.source.directoryIdentity == source.directoryIdentity {
                throw CodexConnectionError.selectionFailed("directory already bound to another slot")
            }
        }

        // Every validation passed: import into this slot's Keychain entry only.
        try keychain.saveCodexCredentials(credentials, account: slotID)

        let connection = CodexConnection(
            source: source,
            importedIdentity: CodexIdentityMetadata(
                accountID: credentials.accountID,
                fingerprint: CodexProfileSource.fingerprint(credentials.accessToken)),
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
    /// different identity; the stored Keychain secret is left untouched (R7/AC4).
    @discardableResult
    public func synchronize(slotID: AccountSlotID, now: Date = Date()) throws -> CodexConnection {
        guard let connection = loadConnections()[slotID] else {
            throw CodexConnectionError.noUsableCredentials
        }

        let current: CodexOAuthCredentials
        do {
            current = try connection.source.readCredentials()
        } catch CodexProfileError.credentialsMalformed {
            throw CodexConnectionError.noUsableCredentials
        }

        let currentIdentity = CodexIdentityMetadata(
            accountID: current.accountID,
            fingerprint: CodexProfileSource.fingerprint(current.accessToken))
        guard connection.importedIdentity.matches(currentIdentity) else {
            throw CodexConnectionError.sourceIdentityChanged
        }

        // Same identity: refresh the stored material (e.g. rotated token).
        try keychain.saveCodexCredentials(current, account: slotID)

        var updated = loadConnections()
        var refreshed = connection
        refreshed.importedIdentity = currentIdentity
        refreshed.importedAt = now
        updated[slotID] = refreshed
        try saveConnections(updated)
        return refreshed
    }

    /// The stored credential for a slot, or nil when not connected.
    public func credential(for slotID: AccountSlotID) -> CodexOAuthCredentials? {
        keychain.codexCredentials(account: slotID)
    }

    /// Whether a slot currently has a persisted connection record.
    public func isConnected(_ slotID: AccountSlotID) -> Bool {
        loadConnections()[slotID] != nil
    }

    /// Disconnect: delete only this slot's Keychain entry, bookmark record, and
    /// snapshot ownership; the external profile directory is never modified and
    /// the user is not logged out of Codex (R7).
    public func disconnect(slotID: AccountSlotID) {
        keychain.deleteCodexCredentials(account: slotID)
        var connections = loadConnections()
        connections[slotID] = nil
        try? saveConnections(connections)
    }
}
