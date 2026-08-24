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
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let connections = try? JSONDecoder().decode([String: CommandCodeConnection].self, from: data) else {
            return [:]
        }
        var result: [AccountSlotID: CommandCodeConnection] = [:]
        for (raw, c) in connections where AccountSlotID(rawValue: raw) != nil {
            if let slot = AccountSlotID(rawValue: raw) { result[slot] = c }
        }
        return result
    }

    public func saveConnections(_ connections: [AccountSlotID: CommandCodeConnection]) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var encoded: [String: CommandCodeConnection] = [:]
        for (slot, c) in connections { encoded[slot.rawValue] = c }
        let data = try JSONEncoder().encode(encoded)
        try data.write(to: fileURL, options: .atomic)
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

    @discardableResult
    public func connectManually(slotID: AccountSlotID, apiKey: String, now: Date = Date()) throws -> CommandCodeConnection {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw CommandCodeConnectionError.noUsableCredentials
        }
        let credentials = CommandCodeCredentials(apiKey: trimmed)
        try keychain.saveCommandCodeCredentials(credentials, account: slotID)
        let synthetic = CommandCodeProfileSource(
            fileIdentity: "manual:\(CommandCodeProfileSource.fingerprint(trimmed))",
            fileName: "manual entry", bookmark: Data())
        let connection = CommandCodeConnection(
            source: synthetic,
            importedIdentity: CommandCodeIdentityMetadata(fingerprint: CommandCodeProfileSource.fingerprint(trimmed)),
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
        keychain.commandCodeCredentials(account: slotID)
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
