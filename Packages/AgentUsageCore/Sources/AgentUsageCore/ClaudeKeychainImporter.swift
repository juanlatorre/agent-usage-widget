import Foundation
import Security

/// Reads the user's real Claude Code session directly from the macOS Keychain
/// entry `Claude Code-credentials` (or its suffixed variants). This is the
/// canonical location Claude Code uses — `~/.claude` is just an app directory
/// and does not contain `.credentials.json`. The picker fallback lets a user
/// connect without creating a synthetic profile directory.
public enum ClaudeKeychainImporter: Sendable {

    /// Try the canonical service names Claude Code has used, in priority order.
    public static let candidateServices = [
        "Claude Code-credentials",
        "Claude Code-credentials-0082e382",
    ]

    /// Load credentials from the Keychain Claude entry. Returns nil when absent/unparseable.
    public static func load() -> ClaudeOAuthCredentials? {
        for service in candidateServices {
            if let creds = load(service: service) { return creds }
        }
        return nil
    }

    public static func load(service: String) -> ClaudeOAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        // Two shapes: either a JSON dict with {"claudeAiOauth": ...} or raw JSON string.
        if let creds = try? ClaudeCredentialsParser.parse(data: data) { return creds }
        // Sometimes the Keychain stores a JSON string that itself encodes the dict.
        if let str = String(data: data, encoding: .utf8),
           let inner = str.data(using: .utf8),
           let creds = try? ClaudeCredentialsParser.parse(data: inner) {
            return creds
        }
        return nil
    }

    /// Enumerate all available Claude Keychain identities so the legacy profile vs the team can be disambiguated.
    public static func allIdentities() -> [(service: String, credentials: ClaudeOAuthCredentials)] {
        var out: [(String, ClaudeOAuthCredentials)] = []
        for service in candidateServices {
            if let creds = load(service: service) {
                out.append((service, creds))
            }
        }
        return out
    }
}
