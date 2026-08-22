import Foundation

/// A supported Claude Code credential representation imported from a profile directory.
///
/// Only the fields the app needs are decoded; unknown members are tolerated so a
/// minor upstream shape change does not break import. Secret material is never
/// logged or written anywhere outside the Keychain (parent R12).
public struct ClaudeOAuthCredentials: Codable, Equatable, Sendable {
    /// The OAuth access token used as the Bearer credential for usage calls.
    public let accessToken: String
    /// Non-secret identity marker Claude reports for this token, when present.
    public let accountUUID: String?

    public init(accessToken: String, accountUUID: String? = nil) {
        self.accessToken = accessToken
        self.accountUUID = accountUUID
    }
}

/// Parser for Claude Code's `claudeAiOauth` credential file shape.
///
/// Contract (child spec R2):
/// - accepts only well-formed `{"claudeAiOauth": {...}}` documents;
/// - rejects missing or malformed identity/token material instead of guessing;
/// - tolerates unknown extra keys around and inside the OAuth object.
public enum ClaudeCredentialsParser {

    public enum ParseError: Error, Equatable, Sendable {
        /// The file is not valid JSON at all.
        case invalidJSON
        /// Valid JSON, but no recognizable `claudeAiOauth` object.
        case missingClaudeOAuth
        /// The OAuth object exists but carries no usable access token material.
        case missingAccessToken
    }

    /// Decode credentials from raw `.credentials.json` contents.
    public static func parse(data: Data) throws -> ClaudeOAuthCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let document = root as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        guard let oauth = document["claudeAiOauth"] as? [String: Any] else {
            throw ParseError.missingClaudeOAuth
        }

        // The access token is required. Accept both camelCase and snake_case key
        // spellings seen across Claude Code versions; anything else is malformed.
        let token = oauth["accessToken"] as? String ?? oauth["access_token"] as? String
        guard let accessToken = normalizedToken(token) else {
            throw ParseError.missingAccessToken
        }

        // Identity is optional metadata: some installations omit it.
        let uuid = oauth["accountUuid"] as? String ?? oauth["account_uuid"] as? String
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            accountUUID: normalizedIdentity(uuid))
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
