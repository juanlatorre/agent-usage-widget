import Foundation

/// Credential mirror for the widget extension's self-healing refresh.
///
/// The sandboxed widget extension cannot read the login Keychain reliably:
/// its process background-prompts and fails (observed: the login-password
/// dialog every few minutes). The workaround is a 0600-permission mirror of
/// the current credentials inside the widget extension's own container — the
/// app (unsandboxed) writes it, the widget reads it. This mirrors the
/// plaintext-token reality of the CLI tools themselves (Claude/Codex keep
/// tokens in ~/.claude / ~/.codex).
///
/// Nothing here is logged. The file is rewritten atomically only when its
/// content actually changes.
@MainActor
public enum CredentialMirror {

    public static let fileName = "credentials.json"

    /// Read the mirrored credentials, or nil when absent/undecodable.
    public static func load(container: URL) -> [AccountSlotID: MirroredCredential]? {
        let url = container.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode([String: MirroredCredential].self, from: data) else {
            return nil
        }
        var out: [AccountSlotID: MirroredCredential] = [:]
        for (key, value) in raw {
            if let slot = AccountSlotID(rawValue: key) ?? AccountSlotID.legacyAliases[key] {
                out[slot] = value
            }
        }
        return out
    }

    /// Write credentials for every connected slot (0600, atomic). Skips the
    /// write when the content is unchanged.
    public static func write(credentials: [AccountSlotID: MirroredCredential], container: URL) throws {
        let fm = FileManager.default
        var raw: [String: MirroredCredential] = [:]
        for (slot, credential) in credentials { raw[slot.rawValue] = credential }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        let url = container.appendingPathComponent(fileName)
        let directory = url.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // The container directory is created 0700 by createDirectory (default
        // umask); credentials.json is written 0600 below.
        if let existing = try? Data(contentsOf: url), existing == data { return }
        do {
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[AgentUsageCore] credential mirror write skipped: %@", String(describing: error))
        }
    }
}

/// One slot's mirrored credential material.
public struct MirroredCredential: Codable, Sendable, Equatable {
    /// Plain API key (OpenCode, Command Code, Z.ai).
    public var apiKey: String?
    /// Claude OAuth payload (access token + account uuid).
    public var claudeOAuthJSON: Data?
    /// Codex OAuth payload (access token + account id).
    public var codexOAuthJSON: Data?

    public init(apiKey: String? = nil, claudeOAuthJSON: Data? = nil, codexOAuthJSON: Data? = nil) {
        self.apiKey = apiKey
        self.claudeOAuthJSON = claudeOAuthJSON
        self.codexOAuthJSON = codexOAuthJSON
    }
}
