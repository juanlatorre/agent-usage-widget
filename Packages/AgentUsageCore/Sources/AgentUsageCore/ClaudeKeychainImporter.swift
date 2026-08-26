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
    /// Prefers an active plan (team/max with non-null rateLimitTier) over an empty free tier.
    public static func load() -> ClaudeOAuthCredentials? {
        let all = allIdentities()
        if let preferred = all.first(where: { $0.credentials.accountUUID != nil }) {
            return preferred.credentials
        }
        // Fallback: prefer the service that has a real subscription type in the raw Keychain payload.
        for (service, _) in all {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let str = String(data: data, encoding: .utf8), str.contains("\"subscriptionType\":") {
                if let creds = load(service: service) { return creds }
            }
        }
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            NSLog("[AgentUsageCore] keychain read '%@' failed: %d", service, status)
            return nil
        }
        guard let data = result as? Data else { return nil }
        // Two shapes: either a JSON dict with {"claudeAiOauth": ...} or raw JSON string.
        if let creds = try? ClaudeCredentialsParser.parse(data: data) { return creds }
        // Sometimes the Keychain stores a JSON string that itself encodes the dict.
        if let str = String(data: data, encoding: .utf8),
           let inner = str.data(using: .utf8),
           let creds = try? ClaudeCredentialsParser.parse(data: inner) {
            return creds
        }
        do {
            _ = try ClaudeCredentialsParser.parse(data: data)
        } catch {
            NSLog("[AgentUsageCore] keychain '%@': parse failed (%@), data bytes=%d",
                  service, String(describing: error), data.count)
        }
        return nil
    }

    /// Enumerate all available Claude Keychain identities for the Claude slot.
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
