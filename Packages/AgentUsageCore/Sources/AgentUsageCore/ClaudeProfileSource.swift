import Foundation
import CryptoKit

/// Errors and outcomes of Claude profile-directory operations.
public enum ClaudeProfileError: Error, Equatable, Sendable {
    /// The security-scoped bookmark cannot be resolved (moved/deleted source).
    case bookmarkUnresolvable
    /// The resolved path is not a readable directory.
    case directoryUnreadable
    /// The `.credentials.json` file is absent.
    case credentialsFileMissing
    /// The credentials file exists but its content is malformed/unsupported.
    case credentialsMalformed
}

/// A user-selected external Claude Code profile directory bound to exactly one slot.
///
/// The app stores only a non-secret security-scoped bookmark plus sanitized
/// identity metadata; the directory contents are never copied wholesale
/// (child spec R1, parent R13).
public struct ClaudeProfileSource: Codable, Sendable, Equatable {

    /// Stable identity used to detect a swapped directory behind the same slot:
    /// the volume ID plus a stable portion of the directory path.
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

    // MARK: - Selection-time helpers

    /// Build a source from a user-selected directory URL.
    public static func selecting(directory: URL) throws -> ClaudeProfileSource {
        let bookmark: Data
        do {
            bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
        } catch {
            throw ClaudeProfileError.bookmarkUnresolvable
        }
        return ClaudeProfileSource(
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
            throw ClaudeProfileError.bookmarkUnresolvable
        }
        var statStruct = stat()
        guard lstat(url.path, &statStruct) == 0 else {
            throw ClaudeProfileError.bookmarkUnresolvable
        }
        guard (statStruct.st_mode & S_IFMT) == S_IFDIR else {
            throw ClaudeProfileError.directoryUnreadable
        }
        let scope = SecurityScopedResource(url: url)
        scope.start()
        return (url, scope)
    }

    /// Read and parse this source's current credentials.
    public func readCredentials() throws -> ClaudeOAuthCredentials {
        let (url, scope) = try resolve()
        defer { scope.stop() }
        let credentialsURL = url.appendingPathComponent(".credentials.json")
        guard FileManager.default.fileExists(atPath: credentialsURL.path) else {
            throw ClaudeProfileError.credentialsFileMissing
        }
        guard let data = try? Data(contentsOf: credentialsURL) else {
            throw ClaudeProfileError.credentialsMalformed
        }
        do {
            return try ClaudeCredentialsParser.parse(data: data)
        } catch {
            throw ClaudeProfileError.credentialsMalformed
        }
    }

    /// Read only non-secret identity metadata without exposing token material.
    ///
    /// Returns nil when the source currently has no usable credentials.
    public func readIdentityMetadata() -> ClaudeIdentityMetadata? {
        guard let credentials = try? readCredentials() else { return nil }
        return ClaudeIdentityMetadata(
            accountUUID: credentials.accountUUID,
            fingerprint: Self.fingerprint(credentials.accessToken))
    }

    /// Stable non-reversible fingerprint of secret material for identity comparison.
    public static func fingerprint(_ accessToken: String) -> String {
        let digest = SHA256.hash(data: Data(accessToken.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sanitized, non-secret description of the credential material in a profile source.
public struct ClaudeIdentityMetadata: Codable, Sendable, Equatable {
    /// Claude-reported account UUID, when present.
    public let accountUUID: String?
    /// Non-reversible fingerprint of the access token for change detection.
    public let fingerprint: String

    public init(accountUUID: String?, fingerprint: String) {
        self.accountUUID = accountUUID
        self.fingerprint = fingerprint
    }

    /// Identity match rule per child spec R3: UUID must agree when both sides
    /// declare one; otherwise the token fingerprint decides.
    public func matches(_ other: ClaudeIdentityMetadata) -> Bool {
        if let mine = accountUUID, let theirs = other.accountUUID {
            return mine == theirs
        }
        return fingerprint == other.fingerprint
    }
}

/// RAII wrapper around `startAccessingSecurityScopedResource` balancing calls.
public final class SecurityScopedResource: @unchecked Sendable {
    private let url: URL
    private let didStart: Bool
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
    }

    func start() {}

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
