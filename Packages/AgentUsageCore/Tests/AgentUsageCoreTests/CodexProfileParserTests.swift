import Testing
import Foundation
@testable import AgentUsageCore

/// Contract tests for Codex `auth.json` profile parsing (child spec R1).
struct CodexProfileParserTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func parsesChatGPTOAuthShape() throws {
        let json = """
        {"auth_mode":"chatgpt",
         "tokens":{"access_token":"tok-openai","account_id":"acct-123"},
         "last_refresh":"2026-08-01T00:00:00Z"}
        """
        let credentials = try CodexAuthParser.parse(data: Data(json.utf8))
        #expect(credentials.accessToken == "tok-openai")
        #expect(credentials.accountID == "acct-123")
    }

    @Test func acceptsCamelCaseKeySpellings() throws {
        let json = """
        {"tokens":{"accessToken":"tok-camel","accountId":"acct-camel"}}
        """
        let credentials = try CodexAuthParser.parse(data: Data(json.utf8))
        #expect(credentials.accessToken == "tok-camel")
        #expect(credentials.accountID == "acct-camel")
    }

    @Test func toleratesUnknownExtraKeys() throws {
        let json = """
        {"tokens":{"access_token":"tok-x","account_id":"a","refresh_token":"r","id_token":"i","future_field":{"nested":true}},"openai_keys":[1]}
        """
        let credentials = try CodexAuthParser.parse(data: Data(json.utf8))
        #expect(credentials.accessToken == "tok-x")
    }

    @Test func missingTokensObjectIsRejected() {
        let json = #"{"api_key_file":"~/.codex/key"}"#
        #expect(throws: CodexAuthParser.ParseError.missingTokens) {
            try CodexAuthParser.parse(data: Data(json.utf8))
        }
    }

    @Test func invalidJSONIsRejected() {
        #expect(throws: CodexAuthParser.ParseError.invalidJSON) {
            try CodexAuthParser.parse(data: Data("not json".utf8))
        }
    }

    @Test func missingOrBlankTokenIsMalformed() {
        let absent = #"{"auth_mode":"chatgpt","tokens":{}}"#
        #expect(throws: CodexAuthParser.ParseError.missingAccessToken) {
            try CodexAuthParser.parse(data: Data(absent.utf8))
        }
        let blank = #"{"tokens":{"access_token":"   "}}"#
        #expect(throws: CodexAuthParser.ParseError.missingAccessToken) {
            try CodexAuthParser.parse(data: Data(blank.utf8))
        }
        let internalWhitespace = #"{"tokens":{"access_token":"abc def"}}"#
        #expect(throws: CodexAuthParser.ParseError.missingAccessToken) {
            try CodexAuthParser.parse(data: Data(internalWhitespace.utf8))
        }
    }

    @Test func apiKeyOnlyDocumentsAreNotUsable() {
        // A tokens-less API-key auth mode must not be imported as OAuth material.
        let json = #"{"auth_mode":"apikey","OPENAI_API_KEY":null,"tokens":null}"#
        #expect(throws: CodexAuthParser.ParseError.missingTokens) {
            try CodexAuthParser.parse(data: Data(json.utf8))
        }
    }
}

/// Identity matching semantics for Codex credential change detection.
struct CodexIdentityMetadataTests {

    @Test func accountIDDecidesWhenBothPresent() {
        let mine = CodexIdentityMetadata(accountID: "acct-a", fingerprint: "f1")
        let theirs = CodexIdentityMetadata(accountID: "acct-b", fingerprint: "f1")
        #expect(!mine.matches(theirs))
        #expect(mine.matches(CodexIdentityMetadata(accountID: "acct-a", fingerprint: "different")))
    }

    @Test func fingerprintDecidesWhenAccountIDAmbiguous() {
        let mine = CodexIdentityMetadata(accountID: nil, fingerprint: "fp-1")
        #expect(mine.matches(CodexIdentityMetadata(accountID: "anything", fingerprint: "fp-1")))
        #expect(!mine.matches(CodexIdentityMetadata(accountID: nil, fingerprint: "fp-2")))
    }

    @Test func fingerprintIsStableAndNonReversible() {
        let a = CodexProfileSource.fingerprint("token-value")
        let b = CodexProfileSource.fingerprint("token-value")
        #expect(a == b)
        #expect(a.count == 32)
        #expect(!a.contains("token"))
    }
}
