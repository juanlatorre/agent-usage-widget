import Testing
import Foundation
@testable import AgentUsageCore

/// Deterministic in-memory credential store standing in for the Keychain.
///
/// Mirrors the per-slot isolation contract: each account maps to exactly one
/// entry, and operations on one slot cannot touch another (AC1, I2).
final class FakeCredentialStore: CredentialStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [AccountSlotID: ClaudeOAuthCredentials] = [:]
    /// Records operation targets for isolation assertions.
    nonisolated(unsafe) var log: [(op: String, slot: AccountSlotID)] = []
    /// When set, saves for this slot fail with the given error.
    var failureFor: [AccountSlotID: Error] = [:]

    struct InjectedFailure: Error, Equatable {}

    func saveCredentials(_ credentials: ClaudeOAuthCredentials, account: AccountSlotID) throws {
        try lock.withLock {
            log.append(("save", account))
            if let failure = failureFor[account] { throw failure }
            storage[account] = credentials
        }
    }

    func credentials(account: AccountSlotID) -> ClaudeOAuthCredentials? {
        lock.withLock { storage[account] }
    }

    func deleteCredentials(account: AccountSlotID) {
        lock.withLock {
            log.append(("delete", account))
            storage[account] = nil
        }
    }

    /// Test helper: raw entry count.
    var count: Int { lock.withLock { storage.count } }
}

/// Shared fixture machinery for connection/controller tests.
enum ClaudeFixtures {

    static func makeDirectory(name: String, token: String, uuid: String? = nil) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-profile-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var oauth: [String: Any] = ["accessToken": token]
        if let uuid { oauth["accountUuid"] = uuid }
        let document: [String: Any] = ["claudeAiOauth": oauth]
        let data = try JSONSerialization.data(withJSONObject: document)
        try data.write(to: directory.appendingPathComponent(".credentials.json"))
        return directory
    }

    static func connectionsFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-connections-\(UUID().uuidString).json")
    }

    static func makeController(store: FakeCredentialStore = FakeCredentialStore()) -> ClaudeAccountController {
        ClaudeAccountController(keychain: store, connectionsFileURL: connectionsFile())
    }
}
