import Foundation

/// In-memory credential storage for UI tests and previews.
///
/// Like `FixtureProvider`, this is test/demo infrastructure, never a production
/// path: UI-test launches select it explicitly so automated runs never touch the
/// user's real Keychain. It provides the same per-slot isolation contract as
/// `KeychainStore`.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [AccountSlotID: ClaudeOAuthCredentials] = [:]
    /// Records delete/save calls so tests can assert isolation behavior.
    public private(set) var operationLog: [String] = []

    public init() {}

    public func saveCredentials(_ credentials: ClaudeOAuthCredentials, account: AccountSlotID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = credentials
        operationLog.append("save:\(account.rawValue)")
    }

    public func credentials(account: AccountSlotID) -> ClaudeOAuthCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func deleteCredentials(account: AccountSlotID) {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = nil
        operationLog.append("delete:\(account.rawValue)")
    }

    /// Test helper: whether a slot currently holds any credential.
    public func hasCredential(account: AccountSlotID) -> Bool {
        credentials(account: account) != nil
    }
}

extension InMemoryCredentialStore: ZaiCredentialStoring {
    public func saveZaiCredentials(_ credentials: ZaiCredentials, account: AccountSlotID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = ClaudeOAuthCredentials(accessToken: credentials.apiKey, accountUUID: nil)
        operationLog.append("save:\(account.rawValue)")
    }
    public func zaiCredentials(account: AccountSlotID) -> ZaiCredentials? {
        guard let stored = credentials(account: account) else { return nil }
        return ZaiCredentials(apiKey: stored.accessToken)
    }
    public func deleteZaiCredentials(account: AccountSlotID) {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil; operationLog.append("delete:\(account.rawValue)")
    }
}

extension InMemoryCredentialStore: CommandCodeCredentialStoring {
    public func saveCommandCodeCredentials(_ credentials: CommandCodeCredentials, account: AccountSlotID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = ClaudeOAuthCredentials(accessToken: credentials.apiKey, accountUUID: nil)
        operationLog.append("save:\(account.rawValue)")
    }
    public func commandCodeCredentials(account: AccountSlotID) -> CommandCodeCredentials? {
        guard let stored = credentials(account: account) else { return nil }
        return CommandCodeCredentials(apiKey: stored.accessToken)
    }
    public func deleteCommandCodeCredentials(account: AccountSlotID) {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil; operationLog.append("delete:\(account.rawValue)")
    }
}

extension InMemoryCredentialStore: OpenCodeCredentialStoring {

    public func saveOpenCodeCredentials(_ credentials: OpenCodeCredentials, account: AccountSlotID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = ClaudeOAuthCredentials(
            accessToken: credentials.apiKey,
            accountUUID: nil)
        operationLog.append("save:\(account.rawValue)")
    }

    public func openCodeCredentials(account: AccountSlotID) -> OpenCodeCredentials? {
        guard let stored = credentials(account: account) else { return nil }
        return OpenCodeCredentials(apiKey: stored.accessToken)
    }

    public func deleteOpenCodeCredentials(account: AccountSlotID) {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = nil
        operationLog.append("delete:\(account.rawValue)")
    }
}

extension InMemoryCredentialStore: CodexCredentialStoring {

    public func saveCodexCredentials(_ credentials: CodexOAuthCredentials, account: AccountSlotID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = ClaudeOAuthCredentials(
            accessToken: credentials.accessToken,
            accountUUID: credentials.accountID)
        operationLog.append("save:\(account.rawValue)")
    }

    public func codexCredentials(account: AccountSlotID) -> CodexOAuthCredentials? {
        guard let stored = credentials(account: account) else { return nil }
        return CodexOAuthCredentials(
            accessToken: stored.accessToken,
            accountID: stored.accountUUID)
    }

    public func deleteCodexCredentials(account: AccountSlotID) {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = nil
        operationLog.append("delete:\(account.rawValue)")
    }
}
