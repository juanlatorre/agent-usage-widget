import Foundation
import CryptoKit

public enum ZaiProfileError: Error, Equatable, Sendable {
    case fileUnreadable
    case authFileMissing
    case credentialsMalformed
}

public struct ZaiCredentials: Codable, Equatable, Sendable {
    public let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }
}

public struct ZaiIdentityMetadata: Codable, Sendable, Equatable {
    public let fingerprint: String
    public init(fingerprint: String) { self.fingerprint = fingerprint }
    public func matches(_ other: ZaiIdentityMetadata) -> Bool { fingerprint == other.fingerprint }
}

/// File-based source for Z.ai API token. Reuses the OpenCode auth file
/// at `~/.local/share/opencode/auth.json` entry `zai-coding-plan` when
/// present (child spec O1), plus a dedicated file fallback. Only a
/// non-secret bookmark + fingerprint are stored.
public struct ZaiProfileSource: Codable, Sendable, Equatable {

    public let fileIdentity: String
    public let fileName: String
    public let bookmark: Data

    public init(fileIdentity: String, fileName: String, bookmark: Data) {
        self.fileIdentity = fileIdentity; self.fileName = fileName; self.bookmark = bookmark
    }

    public static var defaultAuthFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    public static func selecting(file: URL) throws -> ZaiProfileSource {
        let bookmark: Data
        do { bookmark = try file.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) } catch {
            throw ZaiProfileError.fileUnreadable
        }
        return ZaiProfileSource(fileIdentity: Self.identity(of: file), fileName: file.lastPathComponent, bookmark: bookmark)
    }

    public static func identity(of file: URL) -> String {
        let path = file.standardizedFileURL.path
        var volumeID: String?
        if let values = try? file.resourceValues(forKeys: [.volumeIdentifierKey]), let identifier = values.volumeIdentifier {
            volumeID = String(describing: identifier)
        }
        return "\(volumeID ?? "unknown-volume")|\(path)"
    }

    public func resolve() throws -> (url: URL, scope: SecurityScopedResource) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw ZaiProfileError.fileUnreadable
        }
        var statStruct = stat()
        guard lstat(url.path, &statStruct) == 0 else { throw ZaiProfileError.fileUnreadable }
        guard (statStruct.st_mode & S_IFMT) == S_IFREG else { throw ZaiProfileError.fileUnreadable }
        let scope = SecurityScopedResource(url: url)
        scope.start()
        return (url, scope)
    }

    public func readCredentials() throws -> ZaiCredentials {
        let (url, scope) = try resolve()
        defer { scope.stop() }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ZaiProfileError.authFileMissing }
        guard let data = try? Data(contentsOf: url) else { throw ZaiProfileError.credentialsMalformed }
        do { return try ZaiAuthParser.parse(data: data) } catch { throw ZaiProfileError.credentialsMalformed }
    }

    public func readIdentityMetadata() -> ZaiIdentityMetadata? {
        guard let c = try? readCredentials() else { return nil }
        return ZaiIdentityMetadata(fingerprint: Self.fingerprint(c.apiKey))
    }

    public static func fingerprint(_ apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ZaiAuthParser {

    public enum ParseError: Error, Equatable, Sendable {
        case invalidJSON
        case missingZaiEntry
        case missingAPIKey
    }

    /// Parses `~/.local/share/opencode/auth.json` for `zai-coding-plan`.
    /// Shape: `"zai-coding-plan": {"type":"api","key":"..."}` or `{"key":"..."}`
    public static func parse(data: Data) throws -> ZaiCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let document = root as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        // Primary: zai-coding-plan entry (object with key/apiKey)
        if let entry = document["zai-coding-plan"] {
            if let dict = entry as? [String: Any] {
                let raw = dict["key"] as? String ?? dict["apiKey"] as? String ?? dict["api_key"] as? String
                if let key = normalizedKey(raw) { return ZaiCredentials(apiKey: key) }
                throw ParseError.missingAPIKey
            } else if let str = entry as? String, let key = normalizedKey(str) {
                return ZaiCredentials(apiKey: key)
            } else {
                throw ParseError.missingZaiEntry
            }
        }
        throw ParseError.missingZaiEntry
    }

    private static func normalizedKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return trimmed
    }
}
