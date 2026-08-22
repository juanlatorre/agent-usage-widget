import Foundation
import Security

/// Slot-scoped storage abstraction for secret credential material.
///
/// `KeychainStore` is the production implementation; tests inject in-memory
/// fakes. Implementations must keep entries isolated per account (child spec
/// R3/I2) and never log payloads.
public protocol CredentialStoring: Sendable {
    /// Store credentials for one slot, replacing any previous value atomically.
    func saveCredentials(_ credentials: ClaudeOAuthCredentials, account: AccountSlotID) throws
    /// Load the stored credentials for one slot, or nil when absent.
    func credentials(account: AccountSlotID) -> ClaudeOAuthCredentials?
    /// Remove only this slot's entry. Deleting a missing item succeeds.
    func deleteCredentials(account: AccountSlotID)
}

/// Errors surfaced by `KeychainStore` operations.
public enum KeychainStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(String)
    case encodeFailed(String)
}

/// Slot-scoped storage for secret credential material in the macOS Keychain.
///
/// Contract (child spec R3, parent R12):
/// - each slot uses a distinct service/account pair, so entries cannot collide;
/// - stored payloads are opaque data; nothing is ever logged;
/// - lookup/delete affect only the addressed entry (I2 isolation).
public struct KeychainStore: Sendable, CredentialStoring {

    /// Base name combined with the slot ID to form unique per-slot services.
    public let serviceNamePrefix: String

    public init(serviceNamePrefix: String = "com.juanlatorre.agent-usage") {
        self.serviceNamePrefix = serviceNamePrefix
    }

    // MARK: - CredentialStoring conformance

    public func saveCredentials(_ credentials: ClaudeOAuthCredentials, account: AccountSlotID) throws {
        try setJSON(credentials, account: account)
    }

    public func credentials(account: AccountSlotID) -> ClaudeOAuthCredentials? {
        json(ClaudeOAuthCredentials.self, account: account)
    }

    public func deleteCredentials(account: AccountSlotID) {
        deleteSecret(account: account)
    }

    // MARK: - API

    /// Store an opaque secret payload for one slot. Overwrites atomically.
    public func setSecret(_ payload: Data, account: AccountSlotID) throws {
        let query = baseQuery(account: account)
        let attributesToUpdate: [String: Any] = [kSecValueData as String: payload]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = payload
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(describe(addStatus))
            }
        default:
            throw KeychainStoreError.unexpectedStatus(describe(updateStatus))
        }
    }

    /// Load the stored secret payload for one slot, or nil when absent.
    public func secret(account: AccountSlotID) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Remove only this slot's entry. Deleting a missing item succeeds.
    public func deleteSecret(account: AccountSlotID) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        // errSecItemNotFound is a successful delete of nothing; surface neither.
        _ = status
    }

    /// Convenience for JSON-encoded credentials.
    public func setJSON<T: Encodable>(_ value: T, account: AccountSlotID) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw KeychainStoreError.encodeFailed(String(describing: error))
        }
        try setSecret(data, account: account)
    }

    /// Convenience for decoding previously stored JSON credentials.
    public func json<T: Decodable>(_ type: T.Type, account: AccountSlotID) -> T? {
        guard let data = secret(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Plumbing

    private func baseQuery(account: AccountSlotID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(serviceNamePrefix).\(account.rawValue)",
            kSecAttrAccount as String: "oauth-credentials"
        ]
    }

    private func describe(_ status: OSStatus) -> String {
        "SecItem status \(status)"
    }
}
