import Foundation
import CryptoKit

/// Errors and outcomes of Codex profile operations.
public enum CodexProfileError: Error, Equatable, Sendable {
    /// The selected path is not a readable directory.
    case directoryUnreadable
    /// `auth.json` is absent from the profile directory.
    case authFileMissing
    /// `auth.json` exists but holds no usable ChatGPT OAuth token material.
    case credentialsMalformed
}

/// Secret OAuth material imported from a Codex CLI profile (`auth.json`).
///
/// Only the fields the usage transport needs are kept; the token never leaves
/// the Keychain after import (parent R12).
public struct CodexOAuthCredentials: Codable, Equatable, Sendable {
    /// The ChatGPT OAuth access token used as the Bearer credential.
    public let accessToken: String
    /// Non-secret ChatGPT account id sent as `ChatGPT-Account-Id` when present.
    public let accountID: String?

    public init(accessToken: String, accountID: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

/// Non-secret sanitized identity of one Codex credential for change detection.
public struct CodexIdentityMetadata: Codable, Sendable, Equatable {
    /// ChatGPT-reported account id, when present.
    public let accountID: String?
    /// Non-reversible fingerprint of the access token for change detection.
    public let fingerprint: String

    public init(accountID: String?, fingerprint: String) {
        self.accountID = accountID
        self.fingerprint = fingerprint
    }

    /// Identity match rule mirroring the Claude contract: the account id decides
    /// when both sides declare one; otherwise the token fingerprint decides.
    public func matches(_ other: CodexIdentityMetadata) -> Bool {
        if let mine = accountID, let theirs = other.accountID {
            return mine == theirs
        }
        return fingerprint == other.fingerprint
    }
}

/// A user-selected external Codex CLI profile directory bound to exactly one slot.
///
/// Mirrors `ClaudeProfileSource` (child spec R1/R7): only a non-secret
/// security-scoped bookmark plus sanitized identity metadata are stored; the
/// directory is never modified. The default profile home is `~/.codex`.
public struct CodexProfileSource: Codable, Sendable, Equatable {

    /// Stable identity used to detect a swapped directory behind the same slot:
    /// volume ID plus standardized directory path (same rule as Claude sources).
    public let directoryIdentity: String
    /// Display-only last path component at selection time. Never used for access.
    public let directoryName: String
    /// Security-scoped bookmark data resolving the selected directory. Non-secret.
    public let bookmark: Data

    public init(directoryIdentity: String, directoryName: String, bookmark: Data) {
        self.directoryIdentity = directoryIdentity
        self.directoryName = directoryName
        self.bookmark = bookmark
    }

    /// The default Codex CLI profile home (`~/.codex`).
    public static var defaultHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    // MARK: - Selection-time helpers

    /// Build a source from a user-selected directory URL.
    public static func selecting(directory: URL) throws -> CodexProfileSource {
        let bookmark: Data
        do {
            bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
        } catch {
            throw CodexProfileError.directoryUnreadable
        }
        return CodexProfileSource(
            directoryIdentity: Self.identity(of: directory),
            directoryName: directory.lastPathComponent,
            bookmark: bookmark)
    }

    /// Deterministic non-secret identity: volume UUID when available plus path.
    public static func identity(of directory: URL) -> String {
        let path = directory.standardizedFileURL.path
        var volumeID: String?
        if let values = try? directory.resourceValues(forKeys: [.volumeIdentifierKey]),
           let identifier = values.volumeIdentifier {
            volumeID = String(describing: identifier)
        }
        let volumePart = volumeID ?? "unknown-volume"
        return "\(volumePart)|\(path)"
    }

    // MARK: - Resolution

    /// Resolve the stored bookmark to an accessible directory URL.
    ///
    /// Security-scoped access is balanced by the returned scope; callers must
    /// keep it alive while reading from the resolved URL.
    public func resolve() throws -> (url: URL, scope: SecurityScopedResource) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw CodexProfileError.directoryUnreadable
        }
        var statStruct = stat()
        guard lstat(url.path, &statStruct) == 0 else {
            throw CodexProfileError.directoryUnreadable
        }
        guard (statStruct.st_mode & S_IFMT) == S_IFDIR else {
            throw CodexProfileError.directoryUnreadable
        }
        let scope = SecurityScopedResource(url: url)
        scope.start()
        return (url, scope)
    }

    /// Read and parse this source's current credentials.
    public func readCredentials() throws -> CodexOAuthCredentials {
        let (url, scope) = try resolve()
        defer { scope.stop() }
        let authURL = url.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw CodexProfileError.authFileMissing
        }
        guard let data = try? Data(contentsOf: authURL) else {
            throw CodexProfileError.credentialsMalformed
        }
        do {
            return try CodexAuthParser.parse(data: data)
        } catch {
            throw CodexProfileError.credentialsMalformed
        }
    }

    /// Read only non-secret identity metadata without exposing token material.
    ///
    /// Returns nil when the source currently has no usable credentials.
    public func readIdentityMetadata() -> CodexIdentityMetadata? {
        guard let credentials = try? readCredentials() else { return nil }
        return CodexIdentityMetadata(
            accountID: credentials.accountID,
            fingerprint: Self.fingerprint(credentials.accessToken))
    }

    /// Stable non-reversible fingerprint of secret material for identity comparison.
    public static func fingerprint(_ accessToken: String) -> String {
        let digest = SHA256.hash(data: Data(accessToken.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Parser for Codex CLI's `auth.json` ChatGPT OAuth shape.
///
/// Contract (child spec R1):
/// - accepts only well-formed documents with `tokens.access_token`;
/// - rejects missing or malformed token material instead of guessing;
/// - tolerates unknown extra keys around and inside the tokens object;
/// - `tokens.account_id` is optional non-secret identity metadata.
public enum CodexAuthParser {

    public enum ParseError: Error, Equatable, Sendable {
        /// The file is not valid JSON at all.
        case invalidJSON
        /// Valid JSON, but no recognizable usable `tokens` object.
        case missingTokens
        /// The tokens object exists but carries no usable access token material.
        case missingAccessToken
    }

    /// Decode credentials from raw `auth.json` contents.
    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let document = root as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        guard let tokens = document["tokens"] as? [String: Any] else {
            throw ParseError.missingTokens
        }

        // The access token is required. Accept both camelCase and snake_case key
        // spellings seen across Codex CLI versions; anything else is malformed.
        let token = tokens["accessToken"] as? String ?? tokens["access_token"] as? String
        guard let accessToken = normalizedToken(token) else {
            throw ParseError.missingAccessToken
        }

        // Identity is optional metadata: some installations omit it.
        let accountID = tokens["accountId"] as? String ?? tokens["account_id"] as? String
        return CodexOAuthCredentials(
            accessToken: accessToken,
            accountID: normalizedIdentity(accountID))
    }

    // MARK: - Validation

    /// A usable token is a non-empty trimmed string without whitespace or control
    /// characters inside — malformed material must be rejected, not stored.
    private static func normalizedToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return nil
        }
        return trimmed
    }

    /// Identity normalization: non-empty trimmed string, otherwise treated absent.
    private static func normalizedIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
