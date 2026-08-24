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
        if let c = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return c.appendingPathComponent("zai-connections.json")
        }
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("zai-connections.json")
    }

    public func loadConnections() -> [AccountSlotID: ZaiConnection] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let connections = try? JSONDecoder().decode([String: ZaiConnection].self, from: data) else { return [:] }
        var result: [AccountSlotID: ZaiConnection] = [:]
        for (raw, c) in connections where AccountSlotID(rawValue: raw) != nil {
            if let slot = AccountSlotID(rawValue: raw) { result[slot] = c }
        }
        return result
    }

    public func saveConnections(_ connections: [AccountSlotID: ZaiConnection]) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var encoded: [String: ZaiConnection] = [:]
        for (slot, c) in connections { encoded[slot.rawValue] = c }
        let data = try JSONEncoder().encode(encoded)
        try data.write(to: fileURL, options: .atomic)
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

    @discardableResult
    public func connectManually(slotID: AccountSlotID, apiKey: String, now: Date = Date()) throws -> ZaiConnection {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ZaiConnectionError.noUsableCredentials
        }
        let credentials = ZaiCredentials(apiKey: trimmed)
        try keychain.saveZaiCredentials(credentials, account: slotID)
        let synthetic = ZaiProfileSource(fileIdentity: "manual:\(ZaiProfileSource.fingerprint(trimmed))",
                                         fileName: "manual entry", bookmark: Data())
        let connection = ZaiConnection(source: synthetic,
                                       importedIdentity: ZaiIdentityMetadata(fingerprint: ZaiProfileSource.fingerprint(trimmed)),
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
