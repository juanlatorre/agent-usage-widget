import Foundation

public protocol CommandCodeCredentialStoring: Sendable {
    func saveCommandCodeCredentials(_ credentials: CommandCodeCredentials, account: AccountSlotID) throws
    func commandCodeCredentials(account: AccountSlotID) -> CommandCodeCredentials?
    func deleteCommandCodeCredentials(account: AccountSlotID)
}

extension KeychainStore: CommandCodeCredentialStoring {
    public func saveCommandCodeCredentials(_ credentials: CommandCodeCredentials, account: AccountSlotID) throws {
        try setJSON(credentials, account: account)
    }
    public func commandCodeCredentials(account: AccountSlotID) -> CommandCodeCredentials? {
        json(CommandCodeCredentials.self, account: account)
    }
    public func deleteCommandCodeCredentials(account: AccountSlotID) {
        deleteSecret(account: account)
    }
}

public enum CommandCodeConnectionError: Error, Equatable, Sendable {
    case selectionFailed(String)
    case noUsableCredentials
    case sourceIdentityChanged
}

public struct CommandCodeConnection: Codable, Sendable, Equatable {
    public var source: CommandCodeProfileSource
    public var importedIdentity: CommandCodeIdentityMetadata
    public var importedAt: Date
    public init(source: CommandCodeProfileSource,
                importedIdentity: CommandCodeIdentityMetadata,
                importedAt: Date) {
        self.source = source; self.importedIdentity = importedIdentity; self.importedAt = importedAt
    }
}

public struct CommandCodeAccountController: Sendable {

    public static let managedSlots: [AccountSlotID] = [.commandCodeGOAT]

    private let keychain: any CommandCodeCredentialStoring
    private let fileURL: URL

    public init(keychain: any CommandCodeCredentialStoring, connectionsFileURL fileURL: URL) {
        self.keychain = keychain; self.fileURL = fileURL
    }

    public static func defaultFileURL(appGroupID: String) -> URL? {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("commandcode-connections.json")
        }
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("commandcode-connections.json")
    }

    // MARK: - Persistence

    public func loadConnections() -> [AccountSlotID: CommandCodeConnection] {
        let fm = FileManager.default
        var merged: [AccountSlotID: CommandCodeConnection] = [:]
        // Load Application Support fallback first (always writable), then Group Container overwrites.
        // Primary wins: candidates ordered so the primary location is read last.
        let candidates: [URL] = SharedStoreLocations.mirrorURLs(
            forFileName: fileURL.lastPathComponent, primary: fileURL) + [fileURL]
        for url in candidates {
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let connections = try? JSONDecoder().decode([String: CommandCodeConnection].self, from: data) else { continue }
            for (raw, c) in connections where AccountSlotID(rawValue: raw) != nil {
                if let slot = AccountSlotID(rawValue: raw) { merged[slot] = c }
            }
        }
        return merged
    }

    public func saveConnections(_ connections: [AccountSlotID: CommandCodeConnection]) throws {
        var encoded: [String: CommandCodeConnection] = [:]
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

    public static func inspectIdentity(of file: URL) throws -> CommandCodeIdentityMetadata {
        let source: CommandCodeProfileSource
        do { source = try CommandCodeProfileSource.selecting(file: file) } catch {
            throw CommandCodeConnectionError.selectionFailed(String(describing: error))
        }
        guard let metadata = source.readIdentityMetadata() else {
            throw CommandCodeConnectionError.noUsableCredentials
        }
        return metadata
    }

    @discardableResult
    public func connect(slotID: AccountSlotID, file: URL, now: Date = Date()) throws -> CommandCodeConnection {
        let source: CommandCodeProfileSource
        do { source = try CommandCodeProfileSource.selecting(file: file) } catch {
            throw CommandCodeConnectionError.selectionFailed(String(describing: error))
        }
        let credentials: CommandCodeCredentials
        do { credentials = try source.readCredentials() } catch {
            throw CommandCodeConnectionError.noUsableCredentials
        }
        let existing = loadConnections()
        for (other, connection) in existing where other != slotID {
            if connection.source.fileIdentity == source.fileIdentity {
                throw CommandCodeConnectionError.selectionFailed("file already bound to another slot")
            }
        }
        try keychain.saveCommandCodeCredentials(credentials, account: slotID)
        let connection = CommandCodeConnection(
            source: source,
            importedIdentity: CommandCodeIdentityMetadata(
                fingerprint: CommandCodeProfileSource.fingerprint(credentials.apiKey)),
            importedAt: now)
        var updated = existing; updated[slotID] = connection
        try saveConnections(updated)
        return connection
    }

    /// Sanitizes a manually pasted Command Code credential.
    ///
    /// Users frequently paste the entire settings JSON (`{"apiKey":"user_…"}`),
    /// a `Bearer` header, quoted values, or the key embedded in surrounding
    /// text. All of those previously reached the API verbatim and failed with
    /// 401 UNAUTHORIZED, so the slot degraded to history-only. Mirrors the
    /// Z.ai manual-entry sanitizer.
    public static func sanitizedApiKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Whole settings file pasted: extract the key via the auth parser
        // (handles both `apiKey` and legacy `api_key`). Unusable JSON is
        // rejected outright instead of falling through as a literal key.
        if trimmed.first == "{" {
            guard let data = trimmed.data(using: .utf8),
                  let creds = try? CommandCodeAuthParser.parse(data: data) else {
                return nil
            }
            return creds.apiKey
        }
        var source = trimmed
        if source.lowercased().hasPrefix("bearer ") {
            source = String(source.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty { return nil }
        }
        if !source.contains(where: { $0.isWhitespace }) {
            var cleaned = source.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`°,;"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = cleaned.last, ",;".contains(last) {
                cleaned = String(cleaned.dropLast())
                if cleaned.isEmpty { return nil }
            }
            guard !cleaned.isEmpty, cleaned.lowercased() != "bearer" else { return nil }
            return cleaned
        }
        // Key embedded in surrounding text (e.g. `apiKey=user_… here`).
        let pattern = #"user_[A-Za-z0-9_\-]{5,}"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
           let range = Range(match.range, in: source) {
            return String(source[range])
        }
        return nil
    }

    @discardableResult
    public func connectManually(slotID: AccountSlotID, apiKey: String, now: Date = Date()) throws -> CommandCodeConnection {
        guard let sanitized = Self.sanitizedApiKey(apiKey) else {
            throw CommandCodeConnectionError.noUsableCredentials
        }
        let credentials = CommandCodeCredentials(apiKey: sanitized)
        try keychain.saveCommandCodeCredentials(credentials, account: slotID)
        let synthetic = CommandCodeProfileSource(
            fileIdentity: "manual:\(CommandCodeProfileSource.fingerprint(sanitized))",
            fileName: "manual entry", bookmark: Data())
        let connection = CommandCodeConnection(
            source: synthetic,
            importedIdentity: CommandCodeIdentityMetadata(fingerprint: CommandCodeProfileSource.fingerprint(sanitized)),
            importedAt: now)
        var updated = loadConnections(); updated[slotID] = connection
        try saveConnections(updated)
        return connection
    }

    @discardableResult
    public func synchronize(slotID: AccountSlotID, now: Date = Date()) throws -> CommandCodeConnection {
        guard let connection = loadConnections()[slotID] else {
            throw CommandCodeConnectionError.noUsableCredentials
        }
        if connection.source.bookmark.isEmpty { return connection }
        let current: CommandCodeCredentials
        do { current = try connection.source.readCredentials() } catch CommandCodeProfileError.credentialsMalformed {
            throw CommandCodeConnectionError.noUsableCredentials
        }
        let currentIdentity = CommandCodeIdentityMetadata(
            fingerprint: CommandCodeProfileSource.fingerprint(current.apiKey))
        guard connection.importedIdentity.matches(currentIdentity) else {
            throw CommandCodeConnectionError.sourceIdentityChanged
        }
        try keychain.saveCommandCodeCredentials(current, account: slotID)
        var updated = loadConnections()
        var refreshed = connection; refreshed.importedIdentity = currentIdentity; refreshed.importedAt = now
        updated[slotID] = refreshed
        try saveConnections(updated)
        return refreshed
    }

    public func credential(for slotID: AccountSlotID) -> CommandCodeCredentials? {
        guard let stored = keychain.commandCodeCredentials(account: slotID) else { return nil }
        // Self-heal credentials saved before manual-entry sanitization existed
        // (e.g. a whole `{"apiKey":"…"}` settings blob pasted as the key, which
        // the API rejects with 401). A well-formed key is returned untouched.
        guard let sanitized = Self.sanitizedApiKey(stored.apiKey),
              sanitized != stored.apiKey else { return stored }
        let healed = CommandCodeCredentials(apiKey: sanitized)
        try? keychain.saveCommandCodeCredentials(healed, account: slotID)
        var connections = loadConnections()
        if connections[slotID] != nil {
            let fingerprint = CommandCodeProfileSource.fingerprint(sanitized)
            connections[slotID]?.importedIdentity = CommandCodeIdentityMetadata(fingerprint: fingerprint)
            connections[slotID]?.source = CommandCodeProfileSource(
                fileIdentity: "manual:\(fingerprint)",
                fileName: "manual entry", bookmark: Data())
            try? saveConnections(connections)
        }
        NSLog("[AgentUsageCore] healed commandcode credential for %@", slotID.rawValue)
        return healed
    }

    public func isConnected(_ slotID: AccountSlotID) -> Bool {
        loadConnections()[slotID] != nil
    }

    public func disconnect(slotID: AccountSlotID) {
        keychain.deleteCommandCodeCredentials(account: slotID)
        var connections = loadConnections(); connections[slotID] = nil
        try? saveConnections(connections)
    }
}
