import Foundation
import CryptoKit

/// Errors and outcomes of OpenCode profile file operations.
public enum OpenCodeProfileError: Error, Equatable, Sendable {
    /// The selected path is not a readable file.
    case fileUnreadable
    /// `auth.json` is absent at the selected location.
    case authFileMissing
    /// The file exists but holds no usable OpenCode credential material.
    case credentialsMalformed
}

/// Secret API-key material imported from an OpenCode auth store (`auth.json`).
///
/// Only the `opencode-go` key is kept; the token never leaves the Keychain
/// after import (parent R12).
public struct OpenCodeCredentials: Codable, Equatable, Sendable {
    /// The OpenCode GO API key used as the Bearer credential.
    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

/// Non-secret sanitized identity of one OpenCode credential for change detection.
public struct OpenCodeIdentityMetadata: Codable, Sendable, Equatable {
    /// Non-reversible fingerprint of the API key for change detection.
    public let fingerprint: String

    public init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    /// Identity match rule: token fingerprint decides.
    public func matches(_ other: OpenCodeIdentityMetadata) -> Bool {
        fingerprint == other.fingerprint
    }
}

/// A user-selected external OpenCode auth file bound to exactly one slot.
///
/// Mirrors `ClaudeProfileSource` / `CodexProfileSource` but for a file rather
/// than a directory: only a non-secret security-scoped bookmark plus sanitized
/// identity metadata are stored; the file is never modified. The default auth
/// store is `~/.local/share/opencode/auth.json`.
public struct OpenCodeProfileSource: Codable, Sendable, Equatable {

    /// Stable identity used to detect a swapped file behind the same slot:
    /// volume ID plus standardized file path (same rule as Claude sources).
    public let fileIdentity: String
    /// Display-only file name at selection time. Never used for access.
    public let fileName: String
    /// Security-scoped bookmark data resolving the selected file. Non-secret.
    public let bookmark: Data

    public init(fileIdentity: String, fileName: String, bookmark: Data) {
        self.fileIdentity = fileIdentity
        self.fileName = fileName
        self.bookmark = bookmark
    }

    /// The default OpenCode auth file (`~/.local/share/opencode/auth.json`).
    public static var defaultAuthFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    // MARK: - Selection-time helpers

    /// Build a source from a user-selected `auth.json` file URL.
    public static func selecting(file: URL) throws -> OpenCodeProfileSource {
        let bookmark: Data
        do {
            bookmark = try file.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        } catch {
            throw OpenCodeProfileError.fileUnreadable
        }
        return OpenCodeProfileSource(
            fileIdentity: Self.identity(of: file),
            fileName: file.lastPathComponent,
            bookmark: bookmark)
    }

    /// Deterministic non-secret identity: volume UUID when available plus path.
    public static func identity(of file: URL) -> String {
        let path = file.standardizedFileURL.path
        var volumeID: String?
        if let values = try? file.resourceValues(forKeys: [.volumeIdentifierKey]),
           let identifier = values.volumeIdentifier {
            volumeID = String(describing: identifier)
        }
        let volumePart = volumeID ?? "unknown-volume"
        return "\(volumePart)|\(path)"
    }

    // MARK: - Resolution

    /// Resolve the stored bookmark to an accessible file URL.
    ///
    /// Security-scoped access is balanced by the returned scope; callers must
    /// keep it alive while reading from the resolved URL.
    public func resolve() throws -> (url: URL, scope: SecurityScopedResource) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw OpenCodeProfileError.fileUnreadable
        }
        var statStruct = stat()
        guard lstat(url.path, &statStruct) == 0 else {
            throw OpenCodeProfileError.fileUnreadable
        }
        guard (statStruct.st_mode & S_IFMT) == S_IFREG else {
            throw OpenCodeProfileError.fileUnreadable
        }
        let scope = SecurityScopedResource(url: url)
        scope.start()
        return (url, scope)
    }

    /// Read and parse this source's current credentials.
    public func readCredentials() throws -> OpenCodeCredentials {
        let (url, scope) = try resolve()
        defer { scope.stop() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OpenCodeProfileError.authFileMissing
        }
        guard let data = try? Data(contentsOf: url) else {
            throw OpenCodeProfileError.credentialsMalformed
        }
        do {
            return try OpenCodeAuthParser.parse(data: data)
        } catch {
            throw OpenCodeProfileError.credentialsMalformed
        }
    }

    /// Read only non-secret identity metadata without exposing key material.
    ///
    /// Returns nil when the source currently has no usable credentials.
    public func readIdentityMetadata() -> OpenCodeIdentityMetadata? {
        guard let credentials = try? readCredentials() else { return nil }
        return OpenCodeIdentityMetadata(fingerprint: Self.fingerprint(credentials.apiKey))
    }

    /// Stable non-reversible fingerprint of secret material for identity comparison.
    public static func fingerprint(_ apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Parser for OpenCode's `auth.json` credential file shape.
///
/// Contract (child spec O1/R6):
/// - accepts only well-formed documents containing `opencode-go` with a usable key;
/// - rejects missing or malformed key material instead of guessing;
/// - tolerates unknown extra keys and provider entries around the `opencode-go` object;
/// - key is found at `opencode-go.key` (preferred) or `opencode-go.apiKey` for resilience.
public enum OpenCodeAuthParser {

    public enum ParseError: Error, Equatable, Sendable {
        /// The file is not valid JSON at all.
        case invalidJSON
        /// Valid JSON, but no `opencode-go` entry exists.
        case missingOpenCodeGO
        /// The entry exists but carries no usable key material.
        case missingAPIKey
    }

    /// Decode credentials from raw `auth.json` contents.
    public static func parse(data: Data) throws -> OpenCodeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let document = root as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        guard let entry = document["opencode-go"] as? [String: Any] else {
            throw ParseError.missingOpenCodeGO
        }

        // The API key is required. Accept both `key` and `apiKey` spellings;
        // anything else is malformed.
        let rawKey = entry["key"] as? String ?? entry["apiKey"] as? String
        guard let apiKey = normalizedKey(rawKey) else {
            throw ParseError.missingAPIKey
        }

        return OpenCodeCredentials(apiKey: apiKey)
    }

    // MARK: - Validation

    /// A usable key is a non-empty trimmed string without whitespace or control
    /// characters inside — malformed material must be rejected, not stored.
    private static func normalizedKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return nil
        }
        return trimmed
    }
}
