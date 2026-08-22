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
