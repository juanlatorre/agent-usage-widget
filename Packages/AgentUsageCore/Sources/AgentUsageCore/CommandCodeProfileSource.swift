import Foundation
import CryptoKit

public enum CommandCodeProfileError: Error, Equatable, Sendable {
    case fileUnreadable
    case authFileMissing
    case credentialsMalformed
}

public struct CommandCodeCredentials: Codable, Equatable, Sendable {
    public let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }
}

public struct CommandCodeIdentityMetadata: Codable, Sendable, Equatable {
    public let fingerprint: String
    public init(fingerprint: String) { self.fingerprint = fingerprint }
    public func matches(_ other: CommandCodeIdentityMetadata) -> Bool {
        fingerprint == other.fingerprint
    }
}

/// File-based profile source for `~/.commandcode/auth.json`.
///
/// Mirrors `OpenCodeProfileSource`: only a non-secret security-scoped bookmark
/// plus sanitized identity metadata are stored; the file is never modified.
/// Default auth file is `~/.commandcode/auth.json`.
public struct CommandCodeProfileSource: Codable, Sendable, Equatable {

    public let fileIdentity: String
    public let fileName: String
    public let bookmark: Data

    public init(fileIdentity: String, fileName: String, bookmark: Data) {
        self.fileIdentity = fileIdentity
        self.fileName = fileName
        self.bookmark = bookmark
    }

    public static var defaultAuthFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".commandcode/auth.json")
    }

    public static func selecting(file: URL) throws -> CommandCodeProfileSource {
        let bookmark: Data
        do {
            bookmark = try file.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        } catch {
            throw CommandCodeProfileError.fileUnreadable
        }
        return CommandCodeProfileSource(
            fileIdentity: Self.identity(of: file),
            fileName: file.lastPathComponent,
            bookmark: bookmark)
    }

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

    public func resolve() throws -> (url: URL, scope: SecurityScopedResource) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw CommandCodeProfileError.fileUnreadable
        }
        var statStruct = stat()
        guard lstat(url.path, &statStruct) == 0 else {
            throw CommandCodeProfileError.fileUnreadable
        }
        guard (statStruct.st_mode & S_IFMT) == S_IFREG else {
            throw CommandCodeProfileError.fileUnreadable
        }
        let scope = SecurityScopedResource(url: url)
        scope.start()
        return (url, scope)
    }

    public func readCredentials() throws -> CommandCodeCredentials {
        let (url, scope) = try resolve()
        defer { scope.stop() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CommandCodeProfileError.authFileMissing
        }
        guard let data = try? Data(contentsOf: url) else {
            throw CommandCodeProfileError.credentialsMalformed
        }
        do {
            return try CommandCodeAuthParser.parse(data: data)
        } catch {
            throw CommandCodeProfileError.credentialsMalformed
        }
    }

    public func readIdentityMetadata() -> CommandCodeIdentityMetadata? {
        guard let credentials = try? readCredentials() else { return nil }
        return CommandCodeIdentityMetadata(fingerprint: Self.fingerprint(credentials.apiKey))
    }

    public static func fingerprint(_ apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CommandCodeAuthParser {

    public enum ParseError: Error, Equatable, Sendable {
        case invalidJSON
        case missingAPIKey
        case malformedAPIKey
    }

    public static func parse(data: Data) throws -> CommandCodeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let document = root as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        // apiKey is the canonical key; some versions use api_key.
        let raw = document["apiKey"] as? String ?? document["api_key"] as? String
        guard let apiKey = normalizedKey(raw) else {
            // Distinguish missing vs malformed for diagnostics but both map to noUsableCredentials upstream.
            if raw == nil {
                throw ParseError.missingAPIKey
            } else {
                throw ParseError.malformedAPIKey
            }
        }
        return CommandCodeCredentials(apiKey: apiKey)
    }

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
