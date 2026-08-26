import Foundation

/// Secret storage abstraction for OpenCode credential material.
///
/// Mirrors `CredentialStoring` / `CodexCredentialStoring`. Entries stay isolated
/// per slot and payloads are never logged.
public protocol OpenCodeCredentialStoring: Sendable {
    func saveOpenCodeCredentials(_ credentials: OpenCodeCredentials, account: AccountSlotID) throws
    func openCodeCredentials(account: AccountSlotID) -> OpenCodeCredentials?
    func deleteOpenCodeCredentials(account: AccountSlotID)
}

extension KeychainStore: OpenCodeCredentialStoring {
    public func saveOpenCodeCredentials(_ credentials: OpenCodeCredentials, account: AccountSlotID) throws {
        try setJSON(credentials, account: account)
    }
    public func openCodeCredentials(account: AccountSlotID) -> OpenCodeCredentials? {
        json(OpenCodeCredentials.self, account: account)
    }
    public func deleteOpenCodeCredentials(account: AccountSlotID) {
        deleteSecret(account: account)
    }
}

/// Errors surfaced by OpenCode connection lifecycle operations.
public enum OpenCodeConnectionError: Error, Equatable, Sendable {
    case selectionFailed(String)
    case noUsableCredentials
    case sourceIdentityChanged
}

/// Non-secret persisted state for the OpenCode GO slot connection.
public struct OpenCodeConnection: Codable, Sendable, Equatable {
    public var source: OpenCodeProfileSource
    public var importedIdentity: OpenCodeIdentityMetadata
    public var importedAt: Date

    public init(source: OpenCodeProfileSource,
                importedIdentity: OpenCodeIdentityMetadata,
                importedAt: Date) {
        self.source = source
        self.importedIdentity = importedIdentity
        self.importedAt = importedAt
    }
}

/// Owns the OpenCode GO connection lifecycle: select → inspect → connect → sync → disconnect.
///
/// Contract (child spec R6, parent R12/R13, ADR-0004):
/// - only the user-selected auth file is ever read;
/// - import requires an explicit connect call — metadata inspection alone never writes;
/// - manual entry / replacement is also supported through the Keychain path;
/// - an identity mismatch on a later sync stops synchronization without touching
///   the stored Keychain secret;
/// - disconnect deletes only the slot's app-owned material; the auth.json file
///   is never modified and the user is never logged out of OpenCode.
public struct OpenCodeAccountController: Sendable {

    public static let managedSlots: [AccountSlotID] = [.openCodeGO]

    private let keychain: any OpenCodeCredentialStoring
    private let fileURL: URL

    public init(keychain: any OpenCodeCredentialStoring, connectionsFileURL fileURL: URL) {
        self.keychain = keychain
        self.fileURL = fileURL
    }

    public static func defaultFileURL(appGroupID: String) -> URL? {
        let fileManager = FileManager.default
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("opencode-connections.json")
        }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("opencode-connections.json")
    }

    // MARK: - Persistence

    public func loadConnections() -> [AccountSlotID: OpenCodeConnection] {
        let fm = FileManager.default
        var merged: [AccountSlotID: OpenCodeConnection] = [:]
        // Primary wins: candidates ordered so the primary location is read last.
        let candidates: [URL] = SharedStoreLocations.mirrorURLs(
            forFileName: fileURL.lastPathComponent, primary: fileURL) + [fileURL]
        for url in candidates {
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let connections = try? JSONDecoder().decode([String: OpenCodeConnection].self, from: data) else { continue }
            for (raw, c) in connections where AccountSlotID(rawValue: raw) != nil {
                if let slot = AccountSlotID(rawValue: raw) { merged[slot] = c }
            }
        }
        return merged
    }

    public func saveConnections(_ connections: [AccountSlotID: OpenCodeConnection]) throws {
        var encoded: [String: OpenCodeConnection] = [:]
        for (slot, c) in connections { encoded[slot.rawValue] = c }
        let data = try JSONEncoder().encode(encoded)
        // Primary write plus best-effort mirrors (App Group container) so the
        // sandboxed widget extension observes the same connection state.
        try SharedStoreLocations.writeMirrored(
            data,
            primary: fileURL,
            mirrors: SharedStoreLocations.mirrorURLs(
                forFileName: fileURL.lastPathComponent, primary: fileURL))
    }

    // MARK: - Inspection (pre-consent)

    public static func inspectIdentity(of file: URL) throws -> OpenCodeIdentityMetadata {
        let source: OpenCodeProfileSource
        do {
            source = try OpenCodeProfileSource.selecting(file: file)
        } catch {
            throw OpenCodeConnectionError.selectionFailed(String(describing: error))
        }
        guard let metadata = source.readIdentityMetadata() else {
            throw OpenCodeConnectionError.noUsableCredentials
        }
        return metadata
    }

    // MARK: - Connection lifecycle

    /// Connect the slot to an auth file with explicit user consent.
    @discardableResult
    public func connect(slotID: AccountSlotID, file: URL, now: Date = Date()) throws -> OpenCodeConnection {
        let source: OpenCodeProfileSource
        do {
            source = try OpenCodeProfileSource.selecting(file: file)
        } catch {
            throw OpenCodeConnectionError.selectionFailed(String(describing: error))
        }

        let credentials: OpenCodeCredentials
        do {
            credentials = try source.readCredentials()
        } catch {
            throw OpenCodeConnectionError.noUsableCredentials
        }

        let existing = loadConnections()
        for (otherSlot, connection) in existing where otherSlot != slotID {
            if connection.source.fileIdentity == source.fileIdentity {
                throw OpenCodeConnectionError.selectionFailed("file already bound to another slot")
            }
        }

        try keychain.saveOpenCodeCredentials(credentials, account: slotID)

        let connection = OpenCodeConnection(
            source: source,
            importedIdentity: OpenCodeIdentityMetadata(
                fingerprint: OpenCodeProfileSource.fingerprint(credentials.apiKey)),
            importedAt: now)
        var updated = existing
        updated[slotID] = connection
        try saveConnections(updated)
        return connection
    }

    /// Sanitizes a manually pasted OpenCode credential.
    ///
    /// Users frequently paste the entire settings blob (`{"apiKey":"sk-…"}`),
    /// a `Bearer` header, quoted values, or the key embedded in surrounding
    /// text. All of those previously reached the API verbatim and failed with
    /// 401 UNAUTHORIZED. Mirrors the Z.ai / Command Code manual-entry sanitizer.
    public static func sanitizedApiKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "{", let data = trimmed.data(using: .utf8) {
            // Native auth.json shape (`opencode-go.key`), then flat settings
            // blob (`apiKey` / `api_key` / `key` at the root). Unusable JSON is
            // rejected outright instead of falling through as a literal key.
            var extracted: String?
            if let creds = try? OpenCodeAuthParser.parse(data: data) {
                extracted = creds.apiKey
            } else if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let key = (root["apiKey"] as? String) ?? (root["api_key"] as? String) ?? (root["key"] as? String) {
                let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty, !candidate.contains(where: { $0.isWhitespace || $0.isNewline }) {
                    extracted = candidate
                }
            }
            guard let parsed = extracted else { return nil }
            return parsed
        }
        var source = trimmed
        if source.lowercased().hasPrefix("bearer ") {
            source = String(source.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty { return nil }
        }
        if !source.contains(where: { $0.isWhitespace }) {
            let cleaned = source.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`°,;"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.lowercased() != "bearer" else { return nil }
            return cleaned
        }
        // Key embedded in surrounding text (e.g. `key=sk-… note`).
        let pattern = #"sk-[A-Za-z0-9_\-]{10,}"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
           let range = Range(match.range, in: source) {
            return String(source[range])
        }
        return nil
    }

    /// Connect with a manually entered API key (fallback when no auth file is present).
    ///
    /// The paste is sanitized (whole-JSON blobs, `Bearer` prefixes, quotes, and
    /// surrounding text are reduced to the bare key) and validated for shape
    /// rather than by probing the network. A file-backed identity is synthesized
    /// so sync/disconnect remain uniform; it is never written back to disk.
    @discardableResult
    public func connectManually(slotID: AccountSlotID, apiKey: String, now: Date = Date()) throws -> OpenCodeConnection {
        guard let sanitized = Self.sanitizedApiKey(apiKey) else {
            throw OpenCodeConnectionError.noUsableCredentials
        }
        let credentials = OpenCodeCredentials(apiKey: sanitized)
        try keychain.saveOpenCodeCredentials(credentials, account: slotID)

        // Use a synthetic placeholder source so the rest of the lifecycle
        // (isConnected, disconnect, synchronize-noop) stays uniform without
        // needing a separate "manual" branch. Create a minimal bookmark from
        // a temp file that always resolves to "manual" identity, OR — simpler:
        // encode a sentinel fileIdentity that never matches a real selection.
        // We avoid creating temp files by building a bookmark-less source whose
        // fileIdentity is stable and distinct from any real file.
        let synthetic = OpenCodeProfileSource(
            fileIdentity: "manual:\(OpenCodeProfileSource.fingerprint(sanitized))",
            fileName: "manual entry",
            bookmark: Data())

        let connection = OpenCodeConnection(
            source: synthetic,
            importedIdentity: OpenCodeIdentityMetadata(
                fingerprint: OpenCodeProfileSource.fingerprint(sanitized)),
            importedAt: now)
        var updated = loadConnections()
        updated[slotID] = connection
        try saveConnections(updated)
        return connection
    }

    /// Synchronize the slot's Keychain credential with its source file.
    ///
    /// For manual-entry connections there is no file to sync — returns the
    /// current connection unchanged. For file-bound connections, an identity
    /// mismatch leaves the Keychain secret untouched (R6/AC4).
    @discardableResult
    public func synchronize(slotID: AccountSlotID, now: Date = Date()) throws -> OpenCodeConnection {
        guard let connection = loadConnections()[slotID] else {
            throw OpenCodeConnectionError.noUsableCredentials
        }

        // Manual connections have a synthetic sentinel identity with a
        // zero-length bookmark; skip file sync for them and return as-is.
        if connection.source.bookmark.isEmpty {
            return connection
        }

        let current: OpenCodeCredentials
        do {
            current = try connection.source.readCredentials()
        } catch OpenCodeProfileError.credentialsMalformed {
            throw OpenCodeConnectionError.noUsableCredentials
        }

        let currentIdentity = OpenCodeIdentityMetadata(
            fingerprint: OpenCodeProfileSource.fingerprint(current.apiKey))
        guard connection.importedIdentity.matches(currentIdentity) else {
            throw OpenCodeConnectionError.sourceIdentityChanged
        }

        try keychain.saveOpenCodeCredentials(current, account: slotID)

        var updated = loadConnections()
        var refreshed = connection
        refreshed.importedIdentity = currentIdentity
        refreshed.importedAt = now
        updated[slotID] = refreshed
        try saveConnections(updated)
        return refreshed
    }

    public func credential(for slotID: AccountSlotID) -> OpenCodeCredentials? {
        guard let stored = keychain.openCodeCredentials(account: slotID) else { return nil }
        // Self-heal credentials saved before manual-entry sanitization existed
        // (e.g. a whole `{"apiKey":"sk-…"}` blob pasted as the key, which the
        // API rejects with 401). A well-formed key is returned untouched.
        guard let sanitized = Self.sanitizedApiKey(stored.apiKey),
              sanitized != stored.apiKey else { return stored }
        let healed = OpenCodeCredentials(apiKey: sanitized)
        try? keychain.saveOpenCodeCredentials(healed, account: slotID)
        var connections = loadConnections()
        if connections[slotID] != nil {
            let fingerprint = OpenCodeProfileSource.fingerprint(sanitized)
            connections[slotID]?.importedIdentity = OpenCodeIdentityMetadata(fingerprint: fingerprint)
            connections[slotID]?.source = OpenCodeProfileSource(
                fileIdentity: "manual:\(fingerprint)",
                fileName: "manual entry", bookmark: Data())
            try? saveConnections(connections)
        }
        NSLog("[AgentUsageCore] healed opencode credential for %@", slotID.rawValue)
        return healed
    }

    public func isConnected(_ slotID: AccountSlotID) -> Bool {
        loadConnections()[slotID] != nil
    }

    /// Disconnect: delete only this slot's Keychain entry and bookmark record.
    /// The external auth.json is never modified (R6).
    public func disconnect(slotID: AccountSlotID) {
        keychain.deleteOpenCodeCredentials(account: slotID)
        var connections = loadConnections()
        connections[slotID] = nil
        try? saveConnections(connections)
    }
}
