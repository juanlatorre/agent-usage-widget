import Foundation

public protocol ZaiCredentialStoring: Sendable {
    func saveZaiCredentials(_ credentials: ZaiCredentials, account: AccountSlotID) throws
    func zaiCredentials(account: AccountSlotID) -> ZaiCredentials?
    func deleteZaiCredentials(account: AccountSlotID)
}

extension KeychainStore: ZaiCredentialStoring {
    public func saveZaiCredentials(_ credentials: ZaiCredentials, account: AccountSlotID) throws {
        try setJSON(credentials, account: account)
    }
    public func zaiCredentials(account: AccountSlotID) -> ZaiCredentials? {
        json(ZaiCredentials.self, account: account)
    }
    public func deleteZaiCredentials(account: AccountSlotID) { deleteSecret(account: account) }
}

public enum ZaiConnectionError: Error, Equatable, Sendable {
    case selectionFailed(String)
    case noUsableCredentials
    case sourceIdentityChanged
}

public struct ZaiConnection: Codable, Sendable, Equatable {
    public var source: ZaiProfileSource
    public var importedIdentity: ZaiIdentityMetadata
    public var importedAt: Date
    public init(source: ZaiProfileSource, importedIdentity: ZaiIdentityMetadata, importedAt: Date) {
        self.source = source; self.importedIdentity = importedIdentity; self.importedAt = importedAt
    }
}

public struct ZaiAccountController: Sendable {

    public static let managedSlots: [AccountSlotID] = [.zaiCodingPlan]

    private let keychain: any ZaiCredentialStoring
    private let fileURL: URL

    public init(keychain: any ZaiCredentialStoring, connectionsFileURL fileURL: URL) {
        self.keychain = keychain; self.fileURL = fileURL
    }

    public static func defaultFileURL(appGroupID: String) -> URL? {
        let fm = FileManager.default
        if let c = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
           fm.isWritableFile(atPath: c.path) {
            // Verify we can actually write inside the container; after a Team change
            // the directory is revoked/re-created and writes get 513 until relaunch.
            let probe = c.appendingPathComponent(".write-test-\(UUID().uuidString)")
            let canWrite = (try? Data().write(to: probe, options: .atomic)).map { _ in (try? fm.removeItem(at: probe)); return true } ?? false
            // Also verify via direct write test if probe failed, fallback check isWritable
            if canWrite || fm.isWritableFile(atPath: c.path) {
                // Prefer group, but error 513 will be caught below and retried to fallback
                return c.appendingPathComponent("zai-connections.json")
            }
        }
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("zai-connections.json")
    }

    public func loadConnections() -> [AccountSlotID: ZaiConnection] {
        let fm = FileManager.default
        var merged: [AccountSlotID: ZaiConnection] = [:]
        // Primary wins: candidates ordered so the primary location is read last.
        let candidates: [URL] = SharedStoreLocations.mirrorURLs(
            forFileName: fileURL.lastPathComponent, primary: fileURL) + [fileURL]
        for url in candidates {
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let connections = try? JSONDecoder().decode([String: ZaiConnection].self, from: data) else { continue }
            for (raw, c) in connections where AccountSlotID(rawValue: raw) != nil {
                if let slot = AccountSlotID(rawValue: raw) { merged[slot] = c }
            }
        }
        return merged
    }

    public func saveConnections(_ connections: [AccountSlotID: ZaiConnection]) throws {
        var encoded: [String: ZaiConnection] = [:]
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

    public static func inspectIdentity(of file: URL) throws -> ZaiIdentityMetadata {
        let source: ZaiProfileSource
        do { source = try ZaiProfileSource.selecting(file: file) } catch {
            throw ZaiConnectionError.selectionFailed(String(describing: error))
        }
        guard let metadata = source.readIdentityMetadata() else {
            throw ZaiConnectionError.noUsableCredentials
        }
        return metadata
    }

    @discardableResult
    public func connect(slotID: AccountSlotID, file: URL, now: Date = Date()) throws -> ZaiConnection {
        let source: ZaiProfileSource
        do { source = try ZaiProfileSource.selecting(file: file) } catch {
            throw ZaiConnectionError.selectionFailed(String(describing: error))
        }
        let credentials: ZaiCredentials
        do { credentials = try source.readCredentials() } catch {
            throw ZaiConnectionError.noUsableCredentials
        }
        let existing = loadConnections()
        for (other, connection) in existing where other != slotID {
            if connection.source.fileIdentity == source.fileIdentity {
                throw ZaiConnectionError.selectionFailed("file already bound to another slot")
            }
        }
        try keychain.saveZaiCredentials(credentials, account: slotID)
        let connection = ZaiConnection(source: source,
                                       importedIdentity: ZaiIdentityMetadata(fingerprint: ZaiProfileSource.fingerprint(credentials.apiKey)),
                                       importedAt: now)
        var updated = existing; updated[slotID] = connection
        try saveConnections(updated)
        return connection
    }

    /// Sanitize a pasted manual key: trims, handles JSON paste, Bearer prefix,
    /// surrounding quotes/punctuation, and extracts the hex-dot suffix token when
    /// the paste contains surrounding garbage text.
    static func sanitizedApiKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "{" {
            if let data = trimmed.data(using: .utf8),
               let creds = try? ZaiAuthParser.parse(data: data) {
                return creds.apiKey
            }
        }
        var source = trimmed
        if source.lowercased().hasPrefix("bearer ") {
            source = String(source.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty { return nil }
        }
        let containsWhitespace = source.contains(where: { $0.isWhitespace })
        if !containsWhitespace {
            var cleaned = source.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`°,;"))
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip a single trailing period/comma/semicolon that is sentence punctuation,
            // but preserve the internal dot of the token (hex.suffix).
            while let last = cleaned.last, ",;." .contains(last) {
                // Only strip if there are two dots (trailing punctuation) or last char is , ;
                if last == "." {
                    let dots = cleaned.filter { $0 == "." }.count
                    if dots <= 1 { break }
                }
                cleaned = String(cleaned.dropLast())
                if cleaned.isEmpty { return nil }
            }
            guard !cleaned.isEmpty, !cleaned.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
            return cleaned
        }
        let pattern = #"[0-9a-fA-F]{20,}\.[A-Za-z0-9_\-]{5,}"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
           let range = Range(match.range, in: source) {
            return String(source[range])
        }
        return nil
    }

    @discardableResult
    public func connectManually(slotID: AccountSlotID, apiKey: String, now: Date = Date()) throws -> ZaiConnection {
        guard let sanitized = Self.sanitizedApiKey(apiKey) else {
            throw ZaiConnectionError.noUsableCredentials
        }
        let credentials = ZaiCredentials(apiKey: sanitized)
        try keychain.saveZaiCredentials(credentials, account: slotID)
        let synthetic = ZaiProfileSource(fileIdentity: "manual:\(ZaiProfileSource.fingerprint(sanitized))",
                                         fileName: "manual entry", bookmark: Data())
        let connection = ZaiConnection(source: synthetic,
                                       importedIdentity: ZaiIdentityMetadata(fingerprint: ZaiProfileSource.fingerprint(sanitized)),
                                       importedAt: now)
        var updated = loadConnections(); updated[slotID] = connection
        try saveConnections(updated)
        return connection
    }

    @discardableResult
    public func synchronize(slotID: AccountSlotID, now: Date = Date()) throws -> ZaiConnection {
        guard let connection = loadConnections()[slotID] else {
            throw ZaiConnectionError.noUsableCredentials
        }
        if connection.source.bookmark.isEmpty { return connection }
        let current: ZaiCredentials
        do { current = try connection.source.readCredentials() } catch ZaiProfileError.credentialsMalformed {
            throw ZaiConnectionError.noUsableCredentials
        }
        let currentIdentity = ZaiIdentityMetadata(fingerprint: ZaiProfileSource.fingerprint(current.apiKey))
        guard connection.importedIdentity.matches(currentIdentity) else {
            throw ZaiConnectionError.sourceIdentityChanged
        }
        try keychain.saveZaiCredentials(current, account: slotID)
        var updated = loadConnections()
        var refreshed = connection; refreshed.importedIdentity = currentIdentity; refreshed.importedAt = now
        updated[slotID] = refreshed
        try saveConnections(updated)
        return refreshed
    }

    public func credential(for slotID: AccountSlotID) -> ZaiCredentials? { keychain.zaiCredentials(account: slotID) }
    public func isConnected(_ slotID: AccountSlotID) -> Bool { loadConnections()[slotID] != nil }
    public func disconnect(slotID: AccountSlotID) {
        keychain.deleteZaiCredentials(account: slotID)
        var connections = loadConnections(); connections[slotID] = nil
        try? saveConnections(connections)
    }
}
